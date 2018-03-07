module Verifier.Util
  ( Types.Verifier(..)
  , System.Exit.ExitCode(..)
  , VerifierResult(..)
  , def
  , withSystemTempFile
  , hFlush
  , embedFile
  , module System.Process
  , withSpec
  , reachSafety
  )

where

import           Types

import           Data.Default   (def)
import           System.Exit
import           System.IO
import           System.IO.Temp
import           System.Process
import           Data.FileEmbed

withSpec :: Property -> (FilePath -> IO a) -> IO a
withSpec p f = withSystemTempFile "spec.prp" $ \fp hndl -> do
  hPutStr hndl p
  hFlush hndl
  f fp

reachSafety :: Property
reachSafety = "CHECK( init(main()), LTL(G ! call(__VERIFIER_error())) )"
