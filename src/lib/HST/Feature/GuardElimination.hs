-- | This module contains methods for eliminating guards in modules.
module HST.Feature.GuardElimination ( applyGEModule ) where

import           Data.List           ( zipWith4 )
import           Polysemy            ( Member, Sem )

import           HST.CoreAlgorithm   ( defaultErrorExp )
import           HST.Effect.Fresh
  ( Fresh, freshName, freshNameWithSrcSpan, freshVarPat, freshVarPatWithSrcSpan
  , genericFreshPrefix )
import qualified HST.Frontend.Syntax as S

-- | A pair of patterns to match and a right-hand side to use when all
--   patterns match.
data GExp a = GExp { gExpSrcSpan :: S.SrcSpan a
                   , gExpPats    :: [S.Pat a]
                   , gExpRhs     :: S.Rhs a
                   }

-- | Converts a rule of a function declaration to a 'GExp'.
matchToGExp :: S.Match a -> GExp a
matchToGExp (S.Match s _ _ pats rhs _) = GExp s pats rhs

-- | Converts an alternative of a @case@ expression to a 'GExp'.
altToGExp :: S.Alt a -> GExp a
altToGExp (S.Alt s pat rhs _) = GExp s [pat] rhs

-------------------------------------------------------------------------------
-- @let@ Expressions                                                         --
-------------------------------------------------------------------------------
-- | Converts rules of function definitions or @case@ expression alternatives
--   to @let@ bindings of @case@ and @if@ expressions.
--
--   There is one @let@ binding for each rule or alternative and an additional
--   binding for the error expression. The @i@-th binding uses the @(i + 1)@-th
--   binding as an error expression.
generateLet
  :: Member Fresh r
  => S.SrcSpan a -- ^ The source span of the case expression or function
                 --   definition that is guard-eliminated.
  -> [S.Exp a]   -- ^ Variables to match.
  -> S.Exp a     -- ^ Expression to use if patterns don't match or the guard is
                 --   not satisfied.
  -> [GExp a]    -- ^ Patterns to match and the corresponding right-hand sides.
  -> Sem r (S.Exp a)
generateLet s vs err gExps = do
  let srcSpans = map gExpSrcSpan gExps
  varNames' <- mapM (freshNameWithSrcSpan genericFreshPrefix) srcSpans
  varName <- freshName genericFreshPrefix
  let varNames                    = varNames' ++ [varName]
      startVarExpr : nextVarExprs = map S.var varNames
      ifExprs                     = zipWith (rhsToIf . gExpRhs) gExps
        nextVarExprs
  ifExprs' <- mapM applyGEExp ifExprs
  let exprPats  = map (zip vs . gExpPats) gExps
      caseExprs
        = zipWith4 generateNestedCases srcSpans ifExprs' nextVarExprs exprPats
      decls     = zipWith makeVarBinding varNames (caseExprs ++ [err])
  return $ S.Let s (S.BDecls s decls) startVarExpr

-- | Creates a function declaration for a @let@ binding that binds a variable
--   with the given name to the given expression.
makeVarBinding :: S.Name a -> S.Exp a -> S.Decl a
makeVarBinding name expr
  = let srcSpan = S.getSrcSpan expr
    in S.FunBind srcSpan
       [ S.Match { S.matchSrcSpan = srcSpan
                 , S.matchIsInfix = False
                 , S.matchName    = name
                 , S.matchPats    = []
                 , S.matchRhs     = S.UnGuardedRhs srcSpan expr
                 , S.matchBinds   = Nothing
                 }
       ]

-------------------------------------------------------------------------------
-- @case@ Expressions                                                        --
-------------------------------------------------------------------------------
-- | Generates a nested case expression for each variable and pattern pair.
--
--   @'generateNestedCases' e f [(x₁, p₁), …, (xₙ, pₙ)]@ produces an expression
--   of the following form.
--
--   > case x₁ of { p₁ -> (… case xₙ of { pₙ -> e ; _ -> f }  …) ; _ -> f }
generateNestedCases
  :: S.SrcSpan a          -- ^ The source span to use.
  -> S.Exp a              -- ^ Expression to use if all patterns match.
  -> S.Exp a              -- ^ Expression to use if any pattern does not match.
  -> [(S.Exp a, S.Pat a)] -- ^ Expression/pattern pairs to match.
  -> S.Exp a
generateNestedCases s successExpr failExpr
  = foldr generateNestedCase successExpr
 where
  {- generateNestedCase :: (S.Exp a, S.Pat a) -> S.Exp a -> S.Exp a -}
  generateNestedCase (v, p) nestedExpr = S.Case s v
    $ [S.alt p nestedExpr, S.alt (S.PWildCard S.NoSrcSpan) failExpr]

-------------------------------------------------------------------------------
-- @if@ Expressions                                                          --
-------------------------------------------------------------------------------
-- | Converts a right-hand side to an @if@ expression.
--
--   Guarded right-hand sides of the form
--
--   > | m₁ -> e₁
--   > | …
--   > | mₙ -> eₙ
--
--   are converted to @if@ expressions of the following form where @f@ is the
--   second argument passed to 'rhsToIf'.
--
--   > if m₁ then e₁
--   >       else … if mₙ then eₙ
--   >                    else f
rhsToIf :: S.Rhs a -- ^ The right-hand side to convert.
        -> S.Exp a -- ^ The next expression if no guard is satisfied.
        -> S.Exp a
rhsToIf (S.UnGuardedRhs _ expr) _   = expr
rhsToIf (S.GuardedRhss _ grhs) next = foldr guardedRhsToIf next grhs

-- | Converts a guarded right-hand side to an @if@ expression.
--
--   The condition of the guard is used as the condition of the @if@
--   expression and the expression on the right-hand side is used as
--   the @then@ branch. The second argument is the @else@ branch.
guardedRhsToIf :: S.GuardedRhs a -> S.Exp a -> S.Exp a
guardedRhsToIf (S.GuardedRhs s e1 e2) = S.If s e1 e2

-------------------------------------------------------------------------------
-- Guard Elimination                                                         --
-------------------------------------------------------------------------------
-- | Applies guard elimination on @case@ expressions in the given expression.
applyGEExp :: Member Fresh r => S.Exp a -> Sem r (S.Exp a)
applyGEExp (S.InfixApp s e1 qop e2)       = do
  e1' <- applyGEExp e1
  e2' <- applyGEExp e2
  return $ S.InfixApp s e1' qop e2'
applyGEExp (S.NegApp s expr)              = do
  expr' <- applyGEExp expr
  return $ S.NegApp s expr'
applyGEExp (S.App s e1 e2)                = do
  e1' <- applyGEExp e1
  e2' <- applyGEExp e2
  return $ S.App s e1' e2'
applyGEExp (S.Lambda s ps e1)             = do
  e' <- applyGEExp e1
  return $ S.Lambda s ps e'
applyGEExp (S.Let s bs e1)                = do
  e' <- applyGEExp e1
  return $ S.Let s bs e'
applyGEExp (S.If s e1 e2 e3)              = do
  e1' <- applyGEExp e1
  e2' <- applyGEExp e2
  e3' <- applyGEExp e3
  return $ S.If s e1' e2' e3'
applyGEExp (S.Case s e1 alts)             = do
  e' <- applyGEExp e1
  alts' <- applyGEAlts s alts
  return $ S.Case s e' alts'
applyGEExp (S.Tuple s boxed es)           = do
  es' <- mapM applyGEExp es
  return $ S.Tuple s boxed es'
applyGEExp (S.List s es)                  = do
  es' <- mapM applyGEExp es
  return $ S.List s es'
applyGEExp (S.Paren s expr)               = do
  expr' <- applyGEExp expr
  return $ S.Paren s expr'
applyGEExp (S.ExpTypeSig s expr typeExpr) = do
  expr' <- applyGEExp expr
  return $ S.ExpTypeSig s expr' typeExpr
-- Variables, constructors and literals remain unchanged.
applyGEExp e@(S.Var _ _)                  = return e
applyGEExp e@(S.Con _ _)                  = return e
applyGEExp e@(S.Lit _ _)                  = return e

-- | Applies guard elimination on @case@ expression alternatives.
applyGEAlts :: Member Fresh r => S.SrcSpan a -> [S.Alt a] -> Sem r [S.Alt a]
applyGEAlts s alts
  | any hasGuardsAlt alts = do
    let gexps = map altToGExp alts
    newVar' <- freshVarPat genericFreshPrefix
    e <- generateLet s [S.patToExp newVar'] defaultErrorExp gexps
    return [S.Alt s newVar' (S.UnGuardedRhs (S.getSrcSpan e) e) Nothing]
  | otherwise = return alts

-- | Applies guard elimination to function declarations in the given module.
applyGEModule :: Member Fresh r => S.Module a -> Sem r (S.Module a)
applyGEModule (S.Module s origModuleHead moduleName imports decls) = do
  decls' <- mapM applyGEDecl decls
  return $ S.Module s origModuleHead moduleName imports decls'

-- | Applies guard elimination to a declaration.
--
--   Non-function declarations are returned unchanged.
applyGEDecl :: Member Fresh r => S.Decl a -> Sem r (S.Decl a)
applyGEDecl (S.FunBind s ms)          = do
  ms' <- applyGEMatches s ms
  return (S.FunBind s ms')
applyGEDecl decl@(S.DataDecl _ _ _ _) = return decl
applyGEDecl decl@(S.OtherDecl _ _)    = return decl

-- | Applies guard elimination to the rules of a function declaration.
--
--   If no rule of the function has guards and there are no subexpressions
--   with guards, the function is left unchanged.
--
--   TODO only apply to the parts with guards (not on matches if in case)
--        not false by semantics
applyGEMatches
  :: Member Fresh r => S.SrcSpan a -> [S.Match a] -> Sem r [S.Match a]
applyGEMatches s ms | any hasGuards ms = return <$> applyGE s ms
                    | otherwise = return ms

-- | Applies guard elimination to the rules of a function declaration.
applyGE :: Member Fresh r => S.SrcSpan a -> [S.Match a] -> Sem r (S.Match a)
applyGE s ms = do
  let name     = S.matchName (head ms)
      gexps    = map matchToGExp ms
      srcSpans = map S.getSrcSpan (gExpPats (head gexps))
  varPats <- mapM (freshVarPatWithSrcSpan genericFreshPrefix) srcSpans
  expr' <- generateLet s (map S.patToExp varPats) defaultErrorExp gexps
  return
    $ S.Match { S.matchSrcSpan = s
              , S.matchIsInfix = False
              , S.matchName    = name
              , S.matchPats    = varPats
              , S.matchRhs     = S.UnGuardedRhs s expr'
              , S.matchBinds   = Nothing
              }

-------------------------------------------------------------------------------
-- Predicates                                                                --
-------------------------------------------------------------------------------
-- | Tests whether the given rule of a function declaration uses
--   guards or contains an expression with guards.
hasGuards :: S.Match a -> Bool
hasGuards = hasGuardsRhs . S.matchRhs

-- | Tests whether the given right-hand side of a function rule has a guard
--   itself or contains an expression that has subexpressions with guarded
--   right-hand sides.
hasGuardsRhs :: S.Rhs a -> Bool
hasGuardsRhs (S.GuardedRhss _ _)  = True
hasGuardsRhs (S.UnGuardedRhs _ e) = hasGuardsExp e

-- | Tests whether the given expression has a subexpression with guarded
--   right-hand sides.
hasGuardsExp :: S.Exp a -> Bool
hasGuardsExp (S.InfixApp _ e1 _ e2) = hasGuardsExp e1 || hasGuardsExp e2
hasGuardsExp (S.NegApp _ e')        = hasGuardsExp e'
hasGuardsExp (S.App _ e1 e2)        = hasGuardsExp e1 || hasGuardsExp e2
hasGuardsExp (S.Lambda _ _ e')      = hasGuardsExp e'
hasGuardsExp (S.Let _ _ e')         = hasGuardsExp e'
hasGuardsExp (S.If _ e1 e2 e3)      = any hasGuardsExp [e1, e2, e3]
hasGuardsExp (S.Case _ e' alts)     = hasGuardsExp e' || any hasGuardsAlt alts
hasGuardsExp (S.Tuple _ _ es)       = any hasGuardsExp es
hasGuardsExp (S.List _ es)          = any hasGuardsExp es
hasGuardsExp (S.Paren _ e')         = hasGuardsExp e'
hasGuardsExp (S.ExpTypeSig _ e' _)  = hasGuardsExp e'
-- Variables, constructors and literals contain no guards.
hasGuardsExp (S.Var _ _)            = False
hasGuardsExp (S.Con _ _)            = False
hasGuardsExp (S.Lit _ _)            = False

-- | Tests whether the right-hand side of the given alternative of a @case@
--   expression has a guard or a subexpression with guards.
hasGuardsAlt :: S.Alt a -> Bool
hasGuardsAlt (S.Alt _ _ rhs _) = hasGuardsRhs rhs
