-- | This module contains the actual implementation of the pattern-matching
--   compilation algorithm.
module HST.CoreAlgorithm
  ( match
  , defaultErrorExp
  , Eqs
    -- * Testing interface
  , compareCons
  ) where

import           Control.Monad                  ( replicateM )
import           Data.Function                  ( on )
import           Data.List                      ( groupBy, partition )
import           Polysemy                       ( Members, Sem )

import           HST.Effect.Env                 ( Env )
import           HST.Effect.Fresh
  ( Fresh, freshVarPat, freshVarPatWithSrcSpan, genericFreshPrefix )
import           HST.Effect.GetOpt              ( GetOpt, getOpt )
import           HST.Effect.InputModule         ( ConEntry(..), ConName )
import           HST.Effect.Report
  ( Report, failToReport, reportFatal )
import           HST.Environment.LookupOrReport
  ( lookupConEntriesOrReport, lookupTypeNameOrReport )
import qualified HST.Frontend.Syntax            as S
import           HST.Options                    ( optTrivialCase )
import           HST.Util.Messages
  ( Severity(Error, Internal), message )
import           HST.Util.Predicates            ( isConPat, isVarPat )
import           HST.Util.Selectors
  ( getAltConName, getMaybePatConName, getPatVarName )
import           HST.Util.Subst                 ( applySubst, singleSubst )

-------------------------------------------------------------------------------
-- Equations                                                                 --
-------------------------------------------------------------------------------
-- | A type that represents a single equation of a function declaration.
--
--   An equation is characterized by the argument patterns and the right-hand
--   side.
type Eqs a = ([S.Pat a], S.Exp a)

-- | Gets the first pattern of the pattern list of the given equation.
firstPat :: Eqs a -> S.Pat a
firstPat = head . fst

-------------------------------------------------------------------------------
-- Wadler's Algorithm                                                        --
-------------------------------------------------------------------------------
-- | The default error expression to insert for pattern matching failures.
defaultErrorExp :: S.Exp a
defaultErrorExp = S.Var S.NoSrcSpan
  (S.UnQual S.NoSrcSpan (S.Ident S.NoSrcSpan "undefined"))

-- | Compiles the given equations of a function declaration to a single
--   expression that performs explicit pattern matching using @case@
--   expressions.
--
--   All equations must have the same number of patterns as the given list
--   of fresh variable patterns.
match :: (Members '[Env a, Fresh, GetOpt, Report] r, S.EqAST a)
      => S.SrcSpan a -- ^ The source span of the declaration that is matched.
      -> [S.Pat a]   -- ^ Fresh variable patterns.
      -> [Eqs a]     -- ^ The equations of the function declaration.
      -> S.Exp a     -- ^ The error expression for pattern-matching failures.
      -> Sem r (S.Exp a)
match _ [] (([], e) : _) _   = return e  -- Rule 3a: All patterns matched.
match _ [] [] er             = return er -- Rule 3b: Pattern-matching failure.
match s vars@(x : xs) eqs er
  |
    -- Rule 1: Pattern list of all equations starts with a variable pattern.
    allVarPats eqs = do
      eqs' <- mapM (substVars s x) eqs
      match s xs eqs' er
  |
    -- Rule 2: Pattern lists of all equations starts with a constructor pattern.
    allConPats eqs = makeRhs s x xs eqs er
  |
    -- Rule 4: Pattern lists of some equations start with a variable pattern
    -- and others start with a constructor pattern.
    --
    -- If all patterns are in the same group (i.e., there is only one group),
    -- the recursive call to 'match' in 'createRekMatch' would cause an
    -- infinite loop. An internal error is reported in this case to ensure
    -- termination.
    otherwise = let groups = groupByFirstPatType eqs
                in if length groups == 1
                     then reportFatal
                       $ message Internal s
                       $ "Failed to group equations by pattern type. "
                       ++ "All patterns are in the same group."
                     else createRekMatch s vars er groups
match s [] _ _               = reportFatal
  $ message Error s
  $ "Equations have different number of arguments."

-- | Substitutes all occurrences of the variable bound by the first pattern
--   (must be a variable or wildcard pattern) of the given equation by the
--   fresh variable bound by the given variable pattern on the right-hand side
--   of the equation.
substVars :: Members '[Fresh, Report] r
          => S.SrcSpan a
          -> S.Pat a
          -> Eqs a
          -> Sem r (Eqs a)
substVars _ varPat' (p : ps, e) = do
  varName <- getPatVarName p
  let varExp' = S.patToExp varPat'
      subst   = singleSubst (S.unQual varName) varExp'
  return (ps, applySubst subst e)
substVars s _ ([], _)           = reportFatal
  $ message Internal s
  $ "Expected equation with at least one pattern."

-- | Applies 'match' to every group of equations where the error expression
--   is the 'match' result of the next group.
createRekMatch
  :: (Members '[Env a, Fresh, GetOpt, Report] r, S.EqAST a)
  => S.SrcSpan a -- ^ The source span of the corresponding function definition.
  -> [S.Pat a]   -- ^ Fresh variable patterns.
  -> S.Exp a     -- ^ The error expression for pattern-matching failures.
  -> [[Eqs a]]   -- ^ Groups of equations (see 'groupByFirstPatType').
  -> Sem r (S.Exp a)
createRekMatch s vars er = foldr (\eqs mrhs -> mrhs >>= match s vars eqs)
  (return er)

-- | Creates a case expression that performs pattern matching on the variable
--   bound by the given variable pattern.
makeRhs :: (Members '[Env a, Fresh, GetOpt, Report] r, S.EqAST a)
        => S.SrcSpan a -- ^ The source span of the corresponding definition.
        -> S.Pat a     -- ^ The fresh variable pattern to match.
        -> [S.Pat a]   -- ^ The remaining fresh variable patterns.
        -> [Eqs a]     -- ^ The equations.
        -> S.Exp a     -- ^ The error expression for pattern-matching failures.
        -> Sem r (S.Exp a)
makeRhs s x xs eqs er = do
  alts <- computeAlts s x xs eqs er
  return (S.Case s (S.patToExp x) alts)

-- | Generates @case@ expression alternatives for the given equations.
--
--   If there are missing constructors and trivial case completion is enabled,
--   an alternative with an wildcard pattern is added.
--   If trivial case completion is not enabled, one alternative is added for
--   every missing constructor.
computeAlts
  :: (Members '[Env a, Fresh, GetOpt, Report] r, S.EqAST a)
  => S.SrcSpan a -- ^ The source span of the corresponding definition.
  -> S.Pat a     -- ^ The variable pattern that binds the matched variable.
  -> [S.Pat a]   -- ^ The remaining fresh variable patterns.
  -> [Eqs a]     -- ^ The equations to generate alternatives for.
  -> S.Exp a     -- ^ The error expression for pattern-matching failures.
  -> Sem r [S.Alt a]
computeAlts s x xs eqs er = do
  alts <- mapM (computeAlt s x xs er) (groupByCons eqs)
  missingCons <- identifyMissingCons s alts
  if null missingCons then return alts else do
    b <- getOpt optTrivialCase
    if b
      then 
        -- TODO is 'defaultErrorExp' correct? Why not 'er'?
        return $ alts ++ [S.alt (S.PWildCard S.NoSrcSpan) defaultErrorExp]
      else do
        z <- createAltsForMissingCons x missingCons er
        -- TODO currently not sorted (reversed)
        return $ alts ++ z

-------------------------------------------------------------------------------
-- Case Completion                                                           --
-------------------------------------------------------------------------------
-- | Looks up the constructors of the data type that is matched by the given
--   @case@ expression alternatives for which there are no alternatives already.
identifyMissingCons :: Members '[Env a, Report] r
                    => S.SrcSpan a
                    -> [S.Alt a]
                    -> Sem r [ConEntry a]
identifyMissingCons s []   = reportFatal
  $ message Error s
  $ "Could not identify missing constructors: "
  ++ "Empty case expressions are not supported."
identifyMissingCons _ alts = do
  matchedConNames <- mapM getAltConName alts
  conEntries <- findConEntries (head matchedConNames)
  return
    $ filter (not . flip any matchedConNames . S.eqUnQual . conEntryName)
    conEntries

-- | Looks up the data constructor entries of the data type that the given data
--   constructor name belongs to in the current environment.
findConEntries :: Members '[Env a, Report] r => ConName a -> Sem r [ConEntry a]
findConEntries conName
  = lookupTypeNameOrReport conName >>= lookupConEntriesOrReport

-- TODO refactor with smartcons
-- | Creates new @case@ expression alternatives for the given missing
--   constructors.
createAltsForMissingCons
  :: (Members '[Fresh, Report] r, S.EqAST a)
  => S.Pat a         -- ^ The fresh variable matched by the @case@ expression.
  -> [ConEntry a]    -- ^ The missing constructors to generate alternatives for.
  -> S.Exp a         -- ^ The error expression for pattern-matching failures.
  -> Sem r [S.Alt a]
createAltsForMissingCons x cs er = mapM (createAltForMissingCon x er) cs
 where
  createAltForMissingCon
    :: (Members '[Fresh, Report] r, S.EqAST a)
    => S.Pat a
    -> S.Exp a
    -> ConEntry a
    -> Sem r (S.Alt a)
  createAltForMissingCon varPat e conEntry = do
    conPatArgs <- replicateM (conEntryArity conEntry)
      (freshVarPat genericFreshPrefix)
    varName <- getPatVarName varPat
    let conPat  | conEntryIsInfix conEntry = S.PInfixApp (S.getSrcSpan varPat)
                  (head conPatArgs) (conEntryName conEntry) (conPatArgs !! 1)
                | otherwise = S.PApp (S.getSrcSpan varPat)
                  (conEntryName conEntry) conPatArgs
        conExpr = S.patToExp conPat
        subst   = singleSubst (S.unQual varName) conExpr
        e'      = applySubst subst e
    return (S.alt conPat e')

-------------------------------------------------------------------------------
-- Grouping                                                                  --
-------------------------------------------------------------------------------
-- | Groups the given equations based on the type of their first pattern.
--
--   The order of the equations is not changed, i.e., concatenation of the
--   resulting groups yields the original list of equations.
--   Two equations are in the same group only if their pattern lists both
--   start with a variable pattern or both start with a constructor pattern.
groupByFirstPatType :: [Eqs a] -> [[Eqs a]]
groupByFirstPatType = groupBy ordPats
 where
  ordPats (ps, _) (qs, _) = isVarPat (head ps) && isVarPat (head qs)

-- | Groups the given equations based on the constructor matched by their
--   first pattern.
--
--   The order of equations that match the same constructor (i.e., within
--   groups) is preserved.
groupByCons :: [Eqs a] -> [[Eqs a]]
groupByCons = groupBy2 startWithSameCons

-- | A version of 'groupBy' that produces only one group for all
--   elements that are equivalent under the given predicate.
--
--   For example
--
--   > groupBy2 ((==) `on` fst)
--   >          [('a', 1), ('a', 2), ('b', 3), ('a', 4), ('b', 5)]
--
--   yields the following groups
--
--   > [[('a',1),('a',2),('a',4)],[('b',3),('b',5)]]
--
--   whereas 'groupBy' would have returned the following.
--
--   > [[('a',1),('a',2)],[('b',3)],[('a',4)],[('b',5)]]
--
--   This function is stable as the order of elements within each group
--   is preserved.
groupBy2 :: (a -> a -> Bool) -> [a] -> [[a]]
groupBy2 = groupBy2' []
 where
  groupBy2' :: [[a]] -> (a -> a -> Bool) -> [a] -> [[a]]
  groupBy2' acc _ []          = reverse acc -- TODO makes acc redundant.. refactor
  groupBy2' acc comp (x : xs) = let (ys, zs) = partition (comp x) xs
                                in groupBy2' ((x : ys) : acc) comp zs

-- | Tests whether the pattern lists of the given equations start with the same
--   constructor.
startWithSameCons :: Eqs a -> Eqs a -> Bool
startWithSameCons (ps, _) (qs, _) = compareCons (head ps) (head qs)

-- | Tests whether the given patterns match the same constructor or both match
--   the wildcard pattern.
compareCons :: S.Pat a -> S.Pat a -> Bool
compareCons = (==) `on` getMaybePatConName

-------------------------------------------------------------------------------
-- Code Generation                                                           --
-------------------------------------------------------------------------------
-- | Creates an alternative for a @case@ expression for the given group of
--   equations whose first pattern matches the same constructor.
--
--   The variable matched by the case expression is substituted by the
--   expression that corresponds to the pattern of the alternative
--   in order to preserve "linearity". This is an optimization that was
--   originally implemented for the free-compiler to compensate the
--   lack of sharing. This optimization turned out to confuse the
--   termination check of the free-compiler and can probably be removed
--   once sharing is implemented.
computeAlt
  :: (Members '[Env a, Fresh, GetOpt, Report] r, S.EqAST a)
  => S.SrcSpan a -- ^ The source span of the corresponding definition.
  -> S.Pat a     -- ^ The variable pattern that binds the matched variable.
  -> [S.Pat a]   -- ^ The remaining fresh variable patterns.
  -> S.Exp a     -- ^ The error expression for pattern-matching failures.
  -> [Eqs a]     -- ^ A group of equations (see 'groupByCons').
  -> Sem r (S.Alt a)
computeAlt s pat pats er prps@(p : _) = do
  -- oldpats need to be computed for each pattern
  (capp, nvars, _) <- decomposeConPat (firstPat p)
  nprps <- mapM f prps
  patName <- getPatVarName pat
  let subst = singleSubst (S.unQual patName) (S.patToExp capp)
      -- TODO is it actually needed to apply the substitution to the error
      -- expression separately when the substitution is applied to the entire
      -- result anyway?
      er'   = applySubst subst er
  res <- match s (nvars ++ pats) nprps er'
  let res' = applySubst subst res
  return (S.alt capp res')
 where
  f :: Members '[Fresh, Report] r => Eqs a -> Sem r (Eqs a)
  f ([], r)     = return ([], r) -- potentially unused
  f (v : vs, r) = do
    (_, _, oldpats) <- decomposeConPat v
    return (oldpats ++ vs, r)
computeAlt s _ _ _ [] = reportFatal
  $ message Internal s
  $ "Expected at least one pattern in group."

-- TODO refactor into 2 functions. one for the capp and nvars and one for the
--      oldpats
-- | Replaces the child patterns of a pattern with fresh variable patterns.
--
--   Returns the pattern with replaced child patterns and a list of new and
--   old child patterns.
decomposeConPat :: Members '[Fresh, Report] r
                => S.Pat a
                -> Sem r (S.Pat a, [S.Pat a], [S.Pat a])
decomposeConPat (S.PApp s qname ps)         = do
  let srcSpans = map S.getSrcSpan ps
  nvars <- mapM (freshVarPatWithSrcSpan genericFreshPrefix) srcSpans
  return (S.PApp s qname nvars, nvars, ps)
decomposeConPat (S.PInfixApp s p1 qname p2) = failToReport $ do
  let spans = [S.getSrcSpan p1, S.getSrcSpan p2]
  nvars@[nv1, nv2] <- mapM (freshVarPatWithSrcSpan genericFreshPrefix) spans
  let ps = [p1, p2]
  return (S.PInfixApp s nv1 qname nv2, nvars, ps)
-- Decompose patterns with special syntax.
decomposeConPat (S.PList s ps)
  | null ps = return (S.PList s [], [], [])
  | otherwise = do
    let (n : nv) = ps
        listCon  = S.Special s $ S.ConsCon s
    decomposeConPat (S.PInfixApp s n listCon (S.PList s nv))
decomposeConPat (S.PTuple s bxd ps)         = do
  let srcSpans = map S.getSrcSpan ps
  nvars <- mapM (freshVarPatWithSrcSpan genericFreshPrefix) srcSpans
  return (S.PTuple s bxd nvars, nvars, ps)
-- Decompose patterns with parentheses recursively.
decomposeConPat (S.PParen _ p)              = decomposeConPat p
-- Variable and wildcard patterns don't contain child patterns.
decomposeConPat (S.PWildCard s)             = return (S.PWildCard s, [], [])
decomposeConPat (S.PVar s name)             = return (S.PVar s name, [], [])

-------------------------------------------------------------------------------
-- Predicates                                                                --
-------------------------------------------------------------------------------
-- | Tests whether the pattern lists of all given equations starts with a
--   variable pattern.
allVarPats :: [Eqs a] -> Bool
allVarPats = all (isVarPat . firstPat)

-- | Tests whether the pattern lists of all given equations starts with a
--   constructor pattern.
allConPats :: [Eqs a] -> Bool
allConPats = all (isConPat . firstPat)
