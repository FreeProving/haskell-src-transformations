{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- | This module defines an effect for computations that can use different
--   front ends to parse, transform and pretty-print modules and expressions.
--
--   The actions of the effect are the operations provided by the 'Parsable',
--   'Transformable' and 'PrettyPrintable' type classes. Import this module
--   instead of the modules that define the type classes.
module HST.Effect.WithFrontend
  ( -- * Effect
    WithFrontend(..)
    -- * Actions
  , parseModule
  , transformModule
  , unTransformModule
  , prettyPrintModule
  , parseExp
  , transformExp
  , unTransformExp
  , prettyPrintExp
    -- * Handlers
  , runWithFrontendInstances
  , runWithFrontend
  , runWithAllFrontends
  ) where

import qualified Data.Map                   as Map
import qualified Language.Haskell.Exts      as HSE
import           Polysemy                   ( Members, Sem, interpret, makeSem )

import           HST.Effect.Cancel          ( Cancel )
import           HST.Effect.Report          ( Report )
import           HST.Frontend.GHC.Config    ( GHC )
import           HST.Frontend.HSE.Config    ( HSE )
import           HST.Frontend.Parser        ( Parsable )
import qualified HST.Frontend.Parser
import           HST.Frontend.PrettyPrinter ( PrettyPrintable )
import qualified HST.Frontend.PrettyPrinter
import qualified HST.Frontend.Syntax        as S
import           HST.Frontend.Transformer
  ( ExpType, ModuleType, Transformable )
import qualified HST.Frontend.Transformer
import           HST.Options
  ( Frontend(GHClib, HSE), frontendMap )

-------------------------------------------------------------------------------
-- Effect and Actions                                                        --
-------------------------------------------------------------------------------
-- | An effect for computations that need to use different front ends for
--   parsing, transforming and pretty-printing modules and expressions.
data WithFrontend f m a where
  -- | Action for parsing a module.
  ParseModule :: FilePath -- ^ The name of the input file.
    -> String             -- ^ The contents of the input file.
    -> WithFrontend f m (S.Module f)
  -- | Action for transforming a module to the intermediate syntax.
  TransformModule :: ModuleType f -- ^ The parsed module to transform.
    -> WithFrontend f m (S.Module f)
  -- | Action for transforming a module back.
  UnTransformModule :: S.Module f    -- ^ The module to transform back.
    -> WithFrontend f m (ModuleType f)
  -- | Action for pretty printing a module.
  PrettyPrintModule :: S.Module f -- ^ The module to pretty-print.
    -> WithFrontend f m String
  -- | Action for parsing an expression.
  ParseExp :: String -> WithFrontend f m (S.Exp f)
  -- | Action for transforming an expression to the intermediate syntax.
  TransformExp :: ExpType f -> WithFrontend f m (S.Exp f)
  -- | Action for transforming an expression back.
  UnTransformExp :: S.Exp f -> WithFrontend f m (ExpType f)
  -- | Action for pretty printing an expression.
  PrettyPrintExp :: S.Exp f -> WithFrontend f m String

makeSem ''WithFrontend

-------------------------------------------------------------------------------
-- Interpretations                                                           --
-------------------------------------------------------------------------------
-- | Handles the 'WithFrontend' effect by running the computation with the
--   type class instances for @f@.
runWithFrontendInstances
  :: forall f r a.
  (Parsable f, Transformable f, PrettyPrintable f, Members '[Cancel, Report] r)
  => Sem (WithFrontend f ': r) a
  -> Sem r a
runWithFrontendInstances = interpret \case
  ParseModule inputFile input -> HST.Frontend.Parser.parseModule inputFile input
  TransformModule parsedModule ->
    HST.Frontend.Transformer.transformModule parsedModule
  UnTransformModule transformedModule ->
    HST.Frontend.Transformer.unTransformModule transformedModule
  PrettyPrintModule parsedModule ->
    HST.Frontend.PrettyPrinter.prettyPrintModule parsedModule
  ParseExp input -> HST.Frontend.Parser.parseExp input
  TransformExp parsedExp -> HST.Frontend.Transformer.transformExp parsedExp
  UnTransformExp transformedExp ->
    HST.Frontend.Transformer.unTransformExp transformedExp
  PrettyPrintExp parsedExp ->
    HST.Frontend.PrettyPrinter.prettyPrintExp parsedExp

-- | Handles the 'WithFrontend' effect of a polymorphic computation by running
--   the computation with the type class instances for the configuration data
--   type of the given 'Frontend'.
--
--   Only 'Parsable', 'Transformable' and 'PrettyPrintable' are needed by
--   'runWithFrontendInstances'. The 'S.EqAST' and 'S.ShowAST' type class
--   constraints are included to allow computations that need to show or
--   compare ASTs.
runWithFrontend
  :: Members '[Cancel, Report] r
  => Frontend
  -> (forall f.
      (Parsable f, Transformable f, PrettyPrintable f, S.EqAST f, S.ShowAST f)
      => Sem (WithFrontend f ': r) a)
  -> Sem r a
runWithFrontend HSE    = runWithFrontendInstances @(HSE HSE.SrcSpanInfo)
runWithFrontend GHClib = runWithFrontendInstances @GHC

-- | Handles the 'WithFrontend' effect of a polymorphic computation by running
--   the computation with the type classes for 'GHC' and 'HSE'.
runWithAllFrontends
  :: Members '[Cancel, Report] r
  => (forall f.
      (Parsable f, Transformable f, PrettyPrintable f, S.EqAST f, S.ShowAST f)
      => Sem (WithFrontend f ': r) a)
  -> Sem r ()
runWithAllFrontends comp = mapM_ (`runWithFrontend` comp)
  (Map.elems frontendMap)
