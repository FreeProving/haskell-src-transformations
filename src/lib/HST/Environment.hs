-- | This module contains an abstract data type for the pattern matching
--   compiler's state.

module HST.Environment
  ( -- * Environment Entries
    ConEntry(..)
  , DataEntry(..)
    -- * Environment
  , Environment
  , emptyEnv
    -- * Lookup
  , lookupConEntry
  , lookupDataEntry
    -- * Insertion
  , insertConEntry
  , insertDataEntry
  )
where

import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import qualified Language.Haskell.Exts.Syntax  as S

-------------------------------------------------------------------------------
-- Aliases for Names in the Environment                                      --
-------------------------------------------------------------------------------

-- | The name of a data type.
type TypeName = String

-- | The name of a data constructor.
type ConName = S.QName ()

-- | The name of a variable.
type VarName = S.QName ()

-------------------------------------------------------------------------------
-- Environment Entries                                                       --
-------------------------------------------------------------------------------

-- | An entry of the 'Environment' for a data constructor that is in scope.
data ConEntry = ConEntry
  { conEntryName    :: ConName
    -- ^ The name of the constructor.
  , conEntryArity   :: Int
    -- ^ The number of fields of the constructor.
  , conEntryIsInfix :: Bool
    -- ^ Whether the constructor should be written in infix notation or not.
  , conEntryType    ::  TypeName
    -- ^ The name of the data type that the constructor belongs to.
  }

-- | An entry of the 'Environment' for a data type whose constructors are in
--   scope.
data DataEntry = DataEntry
  { dataEntryName :: TypeName
    -- ^ The name of the data type.
  , dataEntryCons :: [ConName]
    -- ^ The names of the data type's constructors.
  }

-------------------------------------------------------------------------------
-- Environment                                                               --
-------------------------------------------------------------------------------

-- | A data type for the state of the pattern matching compiler.
data Environment = Environment
  { envConEntries  :: Map ConName ConEntry
    -- ^ Maps names of constructors to their 'ConEntry's.
  , envDataEntries :: Map TypeName DataEntry
    -- ^ Maps names of data types to their 'DataEntry's.
  , envMatchedPats :: Map VarName (S.Pat ())
    -- ^ Maps names of local variables to patterns they have been matched
    --   against.
  }

-- | An empty 'Environment'.
emptyEnv :: Environment
emptyEnv = Environment { envConEntries  = Map.empty
                       , envDataEntries = Map.empty
                       , envMatchedPats = Map.empty
                       }

-------------------------------------------------------------------------------
-- Lookup                                                                    --
-------------------------------------------------------------------------------

-- | Looks up the entry of a data constructor with the given name in the
--   environment.
--
--   Returns @Nothing@ if the data constructor is not in scope.
lookupConEntry :: ConName -> Environment -> Maybe ConEntry
lookupConEntry name = Map.lookup name . envConEntries

-- | Looks up the entry of a data type with the given name in the environment.
--
--   Returns @Nothing@ if the data type is not in scope.
lookupDataEntry :: TypeName -> Environment -> Maybe DataEntry
lookupDataEntry name = Map.lookup name . envDataEntries

-------------------------------------------------------------------------------
-- Insertion                                                                 --
-------------------------------------------------------------------------------

-- | Inserts the given entry for a data constructor into the environment.
insertConEntry :: ConEntry -> Environment -> Environment
insertConEntry entry env = env
  { envConEntries = Map.insert (conEntryName entry) entry (envConEntries env)
  }

-- | Inserts the given entry for a data type into the environment.
insertDataEntry :: DataEntry -> Environment -> Environment
insertDataEntry entry env = env
  { envDataEntries = Map.insert (dataEntryName entry) entry (envDataEntries env)
  }