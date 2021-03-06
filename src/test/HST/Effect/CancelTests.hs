-- | This module contains tests for "HST.Effect.Cancel".
module HST.Effect.CancelTests ( testCancelEffect ) where

import           Data.IORef        ( modifyIORef, newIORef, readIORef )
import           Polysemy          ( Member, Members, Sem, run, runM )
import           Polysemy.Embed    ( Embed, embed )
import           Polysemy.Writer   ( Writer, runWriter, tell )
import           System.Exit       ( ExitCode )
import           Test.Hspec        ( Expectation, Spec, context, describe, it
                                   , shouldBe, shouldReturn, shouldThrow )

import           HST.Effect.Cancel ( Cancel, cancel, cancelToExit, runCancel )

-- | Sets the expectation that the given 'IO' action terminates the program.
shouldExit :: IO a -> Expectation
shouldExit = flip shouldThrow (const True :: ExitCode -> Bool)

-- | Test group for interpreters of the 'HST.Effect.Cancel.Cancel' effect.
testCancelEffect :: Spec
testCancelEffect = describe "HST.Effect.Cancel" $ do
  testRunCancel
  testCancelToExit

-- | Test group for 'runCancel' tests.
testRunCancel :: Spec
testRunCancel = context "runCancel" $ do
  it "returns Just a value if the computation is not canceled" $ do
    let comp :: Member Cancel r => Sem r Int
        comp = return 42
    run (runCancel comp) `shouldBe` Just 42
  it "returns Nothing if the computation is canceled" $ do
    let comp :: Member Cancel r => Sem r Int
        comp = cancel >> return 42
    run (runCancel comp) `shouldBe` Nothing
  it "cancels the computation prematurely" $ do
    let comp :: Members '[Cancel, Writer [Bool]] r => Sem r Int
        comp = tell [True] >> cancel >> tell [False] >> return 42
    run (runWriter (runCancel comp)) `shouldBe` ([True], Nothing)

-- | Test group for 'cancelToExit' tests.
testCancelToExit :: Spec
testCancelToExit = context "cancelToExit" $ do
  it "returns a value if the computation is not canceled" $ do
    let comp :: Member Cancel r => Sem r Int
        comp = return 42
    runM (cancelToExit comp) `shouldReturn` 42
  it "returns Nothing if the computation is canceled" $ do
    let comp :: Member Cancel r => Sem r Int
        comp = cancel >> return 42
    shouldExit $ runM (cancelToExit comp)
  it "cancels the embedded IO action prematurely" $ do
    ref <- newIORef (0 :: Int)
    let inc :: Member (Embed IO) r => Sem r ()
        inc = embed (modifyIORef ref (+ 1))
        comp :: Members '[Cancel, Embed IO] r => Sem r Int
        comp = inc >> cancel >> inc >> return 42
    shouldExit $ runM (cancelToExit comp)
    readIORef ref `shouldReturn` 1
  it "cancels the computation prematurely" $ do
    -- This test tests whether 'runM' runs the embedded IO action before
    -- 'runWriter' interprets the 'tell' effect.
    let comp :: Members '[Cancel, Embed IO, Writer [Bool]] r => Sem r Int
        comp = cancel >> tell undefined >> return 42
    shouldExit $ runM (runWriter (cancelToExit comp))
