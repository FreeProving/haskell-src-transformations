{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

-- | This module defines an effect that allows to get modules and module
--   interfaces by the module name.

module HST.Effect.InputModule
  ( ModuleInterface
  , InputModule
  , runInputModule
  ) where

import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as Map

import Polysemy ( Member, Members, Sem )
import HST.Environment
import qualified HST.Frontend.Syntax as S

type TypeName a = S.QName a
type ConName a = S.QName a

-- | A data type for the module interface.
data ModuleInterface a = ModuleInterface
  { interfaceModName     :: S.ModuleName a             -- ^ The name of the module.
  , interfaceDataCons    :: Map (TypeName) [ConName a] -- ^ A map that maps types to its constructors
  }


data InputModule m a where
  GetInputModule :: S.ModuleName a -> InputModule m (S.Module a)
  GetInputModuleInterface :: S.ModuleName a -> InputModule m (ModuleInterface a)


runInputModuleWithMap :: Map S.ModuleName (S.Module, ModuleInterface) -> Sem (InputModule ': r) a -> Sem r a
runInputModuleWithMap modules = runReader modules . reinterpret \case
  GetInputModule modName -> fst $ asks (lookup modName)
