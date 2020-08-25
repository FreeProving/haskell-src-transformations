-- | This module contains a type class for finding the names of variables that
--   occur freely in an AST node.
module HST.Util.FreeVars
  ( -- * Free Variables
    FreeVars
  , freeVarSet
  , freeVars
    -- * Bound Variables
  , BoundVars
  , boundVarSet
  , boundVars
  ) where

import           Data.Foldable         ( toList )
import           Data.Functor.Identity ( Identity(..) )
import           Data.Set              ( Set )
import           Data.Set.Ordered      ( (\\), OSet )
import qualified Data.Set.Ordered      as OSet

import qualified HST.Frontend.Syntax   as S

-------------------------------------------------------------------------------
-- Free Variables                                                            --
-------------------------------------------------------------------------------
-- | Type class for AST nodes that can contain free variables.
class FreeVars node where
  -- | Gets an ordered set of names of the variables that occur freely in the
  --   given AST node.
  --
  --   The names are sorted by their first occurrence from left to right.
  freeVarOSet :: node a -> OSet (S.QName a)

-- | Gets the 'unions' of the free variables of the given nodes.
freeVarOSetUnion
  :: (Foldable t, Functor t, FreeVars node) => t (node a) -> OSet (S.QName a)
freeVarOSetUnion = unions . fmap freeVarOSet

-- | Gets a set of names of the variables that occur freely in the given AST
--   node.
freeVarSet :: FreeVars node => node a -> Set (S.QName a)
freeVarSet = OSet.toSet . freeVarOSet

-- | Gets the names of the variables that occur freely in the given AST node.
--
--   The names are sorted by their first occurrence from left to right.
freeVars :: FreeVars node => node a -> [S.QName a]
freeVars = toList . freeVarOSet

-- | Expressions can contain free variables.
instance FreeVars S.Exp where
  freeVarOSet (S.Var _ varName)       = OSet.singleton varName
  -- Lambda abstractions and @let@-expressions and
  freeVarOSet (S.Lambda _ args expr)  = withoutBoundVarsUnion args
    (freeVarOSet expr)
  freeVarOSet (S.Let _ binds expr)    = freeVarOSet binds
    `union` withoutBoundVars binds (freeVarOSet expr)
  -- Find free variables recursively.
  freeVarOSet (S.InfixApp _ e1 op e2)
    = freeVarOSet e1 `union` freeVarOSet op `union` freeVarOSet e2
  freeVarOSet (S.App _ e1 e2)         = freeVarOSet e1 `union` freeVarOSet e2
  freeVarOSet (S.NegApp _ expr)       = freeVarOSet expr
  freeVarOSet (S.If _ e1 e2 e3)
    = freeVarOSet e1 `union` freeVarOSet e2 `union` freeVarOSet e3
  freeVarOSet (S.Case _ expr alts)
    = freeVarOSet expr `union` freeVarOSetUnion alts
  freeVarOSet (S.Tuple _ _ exprs)     = freeVarOSetUnion exprs
  freeVarOSet (S.List _ exprs)        = freeVarOSetUnion exprs
  freeVarOSet (S.Paren _ expr)        = freeVarOSet expr
  freeVarOSet (S.ExpTypeSig _ expr _) = freeVarOSet expr
  -- Constructors and literals do not contain variables.
  freeVarOSet (S.Con _ _)             = OSet.empty
  freeVarOSet (S.Lit _ _)             = OSet.empty

-- | An operator in infix notation is a free variable unless the operator is
--   a constructor.
instance FreeVars S.QOp where
  freeVarOSet (S.QVarOp _ varName) = OSet.singleton varName
  freeVarOSet (S.QConOp _ _)       = OSet.empty

-- | @case@-expression alternatives can contain free variables.
--
--   Variables that are bound by the pattern or local declarations are not
--   free variables of the alternative.
instance FreeVars S.Alt where
  freeVarOSet (S.Alt _ pat rhs mBinds) = withoutBoundVars pat
    (withoutBoundVarsUnion mBinds (freeVarOSet rhs)
     `union` freeVarOSetUnion mBinds)

-- | Local declarations can contain free variables.
--
--   Variables that are bound by any of the local declarations are not free
--   in all declarations.
instance FreeVars S.Binds where
  freeVarOSet (S.BDecls _ decls) = withoutBoundVarsUnion decls
    (freeVarOSetUnion decls)

-- | Declarations can contain free variables.
--
--   Function declarations are the only supported declarations that can
--   contain free variables. Since a function declaration binds the name
--   of the function, the name of the function is not free in recursive
--   functions. However, two function declarations that depend on each
--   other contain free variables for the other function. Thus, bound
--   variables have to be removed explicitly from the 'union' of free
--   variable sets of declarations.
instance FreeVars S.Decl where
  freeVarOSet (S.FunBind _ matches) = freeVarOSetUnion matches
  freeVarOSet (S.DataDecl _ _ _ _)  = OSet.empty
  freeVarOSet (S.OtherDecl _ _)     = OSet.empty

-- | Variables that occur freely on the right-hand side of a function
--   declaration or its @where@-clause are free variables of the function.
--
--   The variables that are bound by the arguments, the local declarations
--   and the function itself are not free.
instance FreeVars S.Match where
  freeVarOSet (S.Match _ name args rhs mBinds)          = withoutBoundVar name
    (withoutBoundVarsUnion args (withoutBoundVarsUnion mBinds (freeVarOSet rhs)
                                 `union` freeVarOSetUnion mBinds))
  freeVarOSet (S.InfixMatch _ arg name args rhs mBinds) = withoutBoundVar name
    (withoutBoundVarsUnion (arg : args)
     (withoutBoundVarsUnion mBinds (freeVarOSet rhs)
      `union` freeVarOSetUnion mBinds))

-- | A right-hand side contains the free variables of the expression and
--   guards.
instance FreeVars S.Rhs where
  freeVarOSet (S.UnGuardedRhs _ expr) = freeVarOSet expr
  freeVarOSet (S.GuardedRhss _ grhss) = freeVarOSetUnion grhss

-- | A guarded right-hand side contains the free variables of the guards and
--   of the guarded expression.
instance FreeVars S.GuardedRhs where
  freeVarOSet (S.GuardedRhs _ e1 e2) = freeVarOSet e1 `union` freeVarOSet e2

-- | The free variables of a module are the names of functions that are used
--   by the module but not defined in the module itself.
instance FreeVars S.Module where
  freeVarOSet (S.Module _ _ _ decls) = withoutBoundVarsUnion decls
    (freeVarOSetUnion decls)

-------------------------------------------------------------------------------
-- Bound Variables                                                           --
-------------------------------------------------------------------------------
-- | Type class for AST nodes that bind variables.
class BoundVars node where
  -- | Gets an ordered set of names of the variables that are bound by the
  --   given AST node.
  --
  --   The names are sorted by their first occurrence from left to right.
  boundVarOSet :: node a -> OSet (S.Name a)

-- | Gets the 'unions' of the bound variables of the given nodes.
boundVarOSetUnion
  :: (Foldable t, Functor t, BoundVars node) => t (node a) -> OSet (S.Name a)
boundVarOSetUnion = unions . fmap boundVarOSet

-- | Gets a set of names of the variables that occur freely in the given AST
--   node.
boundVarSet :: BoundVars node => node a -> Set (S.Name a)
boundVarSet = OSet.toSet . boundVarOSet

-- | Gets the names of the variables that occur freely in the given AST node.
--
--   The names are sorted by their first occurrence from left to right.
boundVars :: BoundVars node => node a -> [S.Name a]
boundVars = toList . boundVarOSet

-- | Variables are bound by variable patterns.
instance BoundVars S.Pat where
  boundVarOSet (S.PVar _ varName)      = OSet.singleton varName
  boundVarOSet (S.PInfixApp _ p1 _ p2)
    = boundVarOSet p1 `union` boundVarOSet p2
  boundVarOSet (S.PApp _ _ pats)       = boundVarOSetUnion pats
  boundVarOSet (S.PTuple _ _ pats)     = boundVarOSetUnion pats
  boundVarOSet (S.PParen _ pat)        = boundVarOSet pat
  boundVarOSet (S.PList _ pats)        = boundVarOSetUnion pats
  boundVarOSet (S.PWildCard _)         = OSet.empty

-- | Local declarations can bind variables.
instance BoundVars S.Binds where
  boundVarOSet (S.BDecls _ decls) = boundVarOSetUnion decls

-- | Declarations can bind variables.
--
--   Function declarations are the only supported declarations that can bind
--   variables.
instance BoundVars S.Decl where
  boundVarOSet (S.FunBind _ matches) = boundVarOSetUnion matches
  boundVarOSet (S.DataDecl _ _ _ _)  = OSet.empty
  boundVarOSet (S.OtherDecl _ _)     = OSet.empty

-- | Function declarations bind the name of the declared function.
--
--   The arguments and local declarations of the function are not visible to
--   the outside and thus, not considered to be bound by the function.
instance BoundVars S.Match where
  boundVarOSet (S.Match _ name _ _ _)        = OSet.singleton name
  boundVarOSet (S.InfixMatch _ _ name _ _ _) = OSet.singleton name

-------------------------------------------------------------------------------
-- Utility functions                                                         --
-------------------------------------------------------------------------------
-- | When a variable is an element of two sets of free variables, the indices
--   of the first set take precedence in the union of both sets.
--
--   If both the left and right subtree of an expression contain the same
--   free variable, we sort the variable from the left subtree before the
--   variables from the right subtree such that free variables are extracted
--   in left to right order.
union :: Ord a => OSet a -> OSet a -> OSet a
union = (OSet.|<>)

-- | Calculates the union of the given ordered sets using 'union'.
unions :: (Foldable t, Ord a) => t (OSet a) -> OSet a
unions = foldr union OSet.empty

-- | Removes the variable with the given name from the given set of free
--   variables.
withoutBoundVar :: S.Name a -> OSet (S.QName a) -> OSet (S.QName a)
withoutBoundVar boundVar fvs = fvs \\ OSet.singleton (S.unQual boundVar)

-- | Removes the variables that are bound by the given node from the given set
--   of free variables.
withoutBoundVars
  :: BoundVars node => node a -> OSet (S.QName a) -> OSet (S.QName a)
withoutBoundVars = withoutBoundVarsUnion . Identity

-- | Removes the variables that are bound by the given nodes from the given set
--   of free variables.
withoutBoundVarsUnion :: (Foldable t, BoundVars node)
                      => t (node a)
                      -> OSet (S.QName a)
                      -> OSet (S.QName a)
withoutBoundVarsUnion binders fvs = foldr OSet.delete fvs
  $ map S.unQual (concatMap boundVars binders)
