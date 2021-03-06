{-# LANGUAGE TemplateHaskell #-}

module Main where

import           ADiff.Prelude

import           Data.FileEmbed
import qualified Data.Text          as T
import           Data.Text.Encoding (decodeUtf8)
import qualified Docker.Client      as Docker
import qualified RIO.ByteString     as BS
import           Test.Tasty
import           Test.Tasty.HUnit

import           ADiff.Data
import           ADiff.Execute
import           ADiff.Verifier     (allVerifiers)

main :: IO ()
main = defaultMain  $ testGroup "adiff-integration" [testVerifiers]


testVerifiers :: TestTree
testVerifiers = testGroup "verifiers" [testSimple]


testSimple :: TestTree
testSimple = testGroup "unsat" $ map test [ (v, r) | v <- allVerifiers', r <- [Sat, Unsat], v ^. name /= "vim" ]
  where
    satFile       = $(embedFile "assets/test/sat.c")
    unsatFile     = $(embedFile "assets/test/unsat.c")
    allVerifiers' = filter (\v -> v ^. name /= "vim") allVerifiers

    test (v, expected) = testCase (T.unpack (v ^. name) ++ " " ++ show expected) $ do
      logOptions <- logOptionsHandle stderr True
      let logOptions' = setLogMinLevel LevelWarn $ setLogVerboseFormat False logOptions
      withLogFunc  logOptions' $ \lg -> do
        let testFile = if expected == Sat then satFile else unsatFile
        res <- runRIO lg $ executeVerifierInDocker (defaultVerifierResources (fromSeconds 30)) (v ^. name) [] (decodeUtf8 testFile)
        (res ^. verdict) @?= expected
