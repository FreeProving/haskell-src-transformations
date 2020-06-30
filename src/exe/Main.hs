-- | This module contains the command line interface for the
--   @haskell-src-transformations@ package.

module Main
  ( main
  )
where

import           Control.Monad                  ( void )
import qualified Language.Haskell.Exts         as HSE
import           Polysemy                       ( Member
                                                , Members
                                                , Sem
                                                , runM
                                                )
import           Polysemy                       ( Embed
                                                , embed
                                                )
import           System.Console.GetOpt          ( OptDescr(Option)
                                                , ArgDescr(NoArg, ReqArg)
                                                , ArgOrder(Permute)
                                                , getOpt
                                                , usageInfo
                                                )
import           System.Environment             ( getArgs )
import           System.IO                      ( stderr )

import           HST.Application                ( processModule
                                                , specialCons
                                                )
import           HST.Effect.Report              ( Message(Message)
                                                , Report
                                                , Severity(Error)
                                                , report
                                                , reportFatal
                                                , reportToHandleOrCancel
                                                )
import           HST.Effect.Cancel              ( cancelToExit )
import           HST.Environment.FreshVars      ( PMState(PMState)
                                                , nextId
                                                , constrMap
                                                , matchedPat
                                                , trivialCC
                                                , opt
                                                , debugOutput
                                                , evalPM
                                                )

-- | A data type that contains the parsed command line options.
data Options = Options
  { showHelp     :: Bool
    -- ^ Flag that indicates whether to show the usage information.
  , inputFile    :: FilePath
    -- ^ The name of the input file.
  , outputDir    :: Maybe FilePath
    -- ^ The name of the output file or @Nothing@ if output should be printed
    --   to the console.
  , enableDebug  :: Bool
    -- ^ Flag that indicates whether to print debugging messages to the console.
  , trivialCase  :: Bool
    -- ^ Flag that indicates whether to enable trivial case completion or not.
  , optimizeCase :: Bool
    -- ^ Flag that indicates whether optimization for case expressions is
    --   enabled or not.
  }

-- | The options to use by default if there are no command line arguments.
defaultOptions :: Options
defaultOptions = Options { showHelp     = False
                         , inputFile    = error "Loading File failed"
                         , outputDir    = Nothing
                         , enableDebug  = False
                         , trivialCase  = False
                         , optimizeCase = True
                         }

-- | Descriptors for the supported command line options.
--
--   The descriptors specify the name, alias and help message for the option
--   as well as a function that adds the flag or value to the 'Options'.
options :: [OptDescr (Options -> Options)]
options =
  [ Option ['h', '?']
           ["help"]
           (NoArg (\opts -> opts { showHelp = True }))
           "Show help"
  , Option ['d']
           ["debug"]
           (NoArg (\opts -> opts { enableDebug = True }))
           "Prints all Debug messages generated during the Phases"
  , Option ['t']
           ["trivialCC"]
           (NoArg (\opts -> opts { trivialCase = True }))
           "Enables trivial Case Completion"
  , Option ['n']
           ["noOptimization"]
           (NoArg (\opts -> opts { optimizeCase = False }))
           "Disables optimization for case expressions"
  , Option ['I']
           ["Input"]
           (ReqArg (\fp opts -> opts { inputFile = fp }) "DIR")
           "input DIR" -- TODO this should be @"input FILE"@!
  , Option ['o']
           ["output"]
           (ReqArg (\m opts -> opts { outputDir = Just m }) "DIR")
           "output DIR"
  ]

-- | Parses the given command line arguments.
--
--   Returns the recognized 'Options' and a list of non-options (i.e., input
--   file names). The 'non-options' are not actually used by the command line
--   interface. Input file names are specified using the @--Input@ option.
parseArgs :: Member Report r => [String] -> Sem r (Options, [String])
parseArgs args
  | null errors = return (foldr ($) defaultOptions optSetters, nonOpts)
  | otherwise = do
    mapM_ (report . Message Error) errors
    reportFatal
      $  Message Error
      $  "Failed to parse command line arguments.\n"
      ++ "Use '--help' for usage information."
 where
  optSetters :: [Options -> Options]
  nonOpts :: [String]
  errors :: [String]
  (optSetters, nonOpts, errors) = getOpt Permute options args

-- | Creates the initial 'PMState' from the given command line options.
transformOptions :: Options -> PMState
transformOptions opts = PMState { nextId      = 0
                                , constrMap   = specialCons
                                , matchedPat  = []
                                , trivialCC   = trivialCase opts
                                , opt         = optimizeCase opts
                                , debugOutput = ""
                                }

-- | The main function of the command line interface.
--
--   Runs the 'application' and interprets all unhandled effects.
main :: IO ()
main = runM . cancelToExit . reportToHandleOrCancel stderr $ application

-- | The main computation of the command line interface.
--
--   Parses the command line arguments and input file. The transformation is
--   applied on the parsed input module and a state constructed from the
--   command line arguments. The output is either printed to the console
--   or a file.
application :: Members '[Report, Embed IO] r => Sem r ()
application = do
  args      <- embed getArgs
  (opts, _) <- parseArgs args
  embed $ if not (showHelp opts)
    then do
      let state = transformOptions opts
      input <- readFile $ inputFile opts
      let x = HSE.fromParseResult (HSE.parseModule input)
          m = evalPM (processModule (void x)) state
      case outputDir opts of
        Just out -> do
          -- TODO this looks to me as if 'outputDir' is named incorrectly.
          -- It is not an output directory but the name of the output file.
          writeFile out (pPrint m)
          printDebug (enableDebug opts) state
        Nothing -> do
          putStr $ pPrint m
          printDebug (enableDebug opts) state
    else putStr (usageInfo "" options)

-- | Prints the 'debugOutput' from the given 'PMState' to the console if
--   the first argument is set to @True@.
printDebug :: Bool -> PMState -> IO ()
printDebug b s | b         = print $ "DebugOutput:" ++ debugOutput s
               | -- TODO pretty debug
                 otherwise = return ()

-- | Pretty prints the given Haskell module.
pPrint :: HSE.Module () -> String
pPrint = HSE.prettyPrintStyleMode
  (HSE.Style { HSE.mode           = HSE.PageMode
             , HSE.lineLength     = 120
             , HSE.ribbonsPerLine = 1.5
             }
  )
  HSE.defaultMode
