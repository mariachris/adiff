{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Strategy.Random (randomStrategy) where

import qualified Prelude                       as P
import           RIO

import           Control.Lens.Getter           (use)
import           Control.Lens.Operators
import           Control.Monad.State
import           Language.C
import           Language.C.Analysis.SemRep    hiding (Stmt)
import           Language.C.Analysis.TypeUtils
import           Language.C.Data.Lens
import           System.Random

import           Data
import           Instrumentation
import           Types

import           Strategy.Util


type RandomM env a = StateT RandomState (RIO env) a

-- does not terminate
randomStrategy :: (HasLogFunc env, HasTranslationUnit env, HasDiffParameters env) => RIO env ()
randomStrategy = do
  tu <- view translationUnit
  let (Just bdy) = tu ^? (ix "main" . functionDefinition . body)
  gen <- liftIO getStdGen
  let st = RandomState (mkZipper bdy) [0] gen
  (_,_t) <- runStateT randomStrategy' st
  return ()


randomStrategy' :: (HasLogFunc env, HasTranslationUnit env, HasDiffParameters env) => RandomM env ()
randomStrategy' = do
  randomStep
  vars <- findReads
  if null vars
    then randomStrategy' -- start over
    else tryout $ do
      (v,ty) <- chooseOneOf vars
      asrt <- mkAssertion v ty
      insertBefore asrt
      tu <- buildTranslationUnit
      (res :: [VerifierRun]) <- lift $ verify tu
      logInfo $ "results: " <> display (tshow res)
  -- iterate
  randomStrategy'



-- -- | state for our algorithm
data RandomState = RandomState
  { _stmtZipper   :: StmtZipper
  , _stmtPosition :: [Int]
  , _randomGen    :: StdGen
  }
class HasRandomGen st where
  randomGen :: Lens' st StdGen

instance ZipperState RandomState where
  stmtZipper = lens _stmtZipper (\s z -> s { _stmtZipper = z})
  stmtPosition = lens _stmtPosition (\s i -> s { _stmtPosition = i})

instance HasRandomGen RandomState where
  randomGen = lens _randomGen $ \s g -> s {_randomGen = g}


chooseOneOf :: (HasRandomGen st, MonadState st m) => [a] ->  m a
chooseOneOf options = do
  g <- use randomGen
  let (i, g') = randomR (0, length options - 1) g
  randomGen .= g'
  return (options P.!! i)

choose :: (HasRandomGen st, MonadState st m, Random a) => m a
choose = do
  g <- use randomGen
  let (i, g') = random g
  randomGen .= g'
  return i


-- | walks a random step in the ast
randomStep :: (HasLogFunc env) => StateT RandomState (RIO env) ()
randomStep = do
  d <- chooseOneOf [Up, Down, Next, Prev]
  success <- go d
  if success
    then logDebug $ "one step " <> display (tshow d)
    else randomStep

type UInt = Int32 -- TODO: this is not true

-- |
buildTranslationUnit :: (HasTranslationUnit env) => StateT RandomState (RIO env)  (CTranslationUnit SemPhase)
buildTranslationUnit = do
  z <- use stmtZipper
  let stmt = fromZipper z
  tu <- view translationUnit
  let modif = (ix "main" . functionDefinition . body) .~ stmt
  return $ modif tu

mkAssertion :: (HasRandomGen st, MonadState st m) => Ident -> Type -> m Stmt
mkAssertion varName ty = do
      constv <- if | ty `sameType` integral TyChar -> do
                      (c :: Char) <- choose
                      return $ CCharConst (CChar c False) (undefNode, ty)
                   | ty `sameType` integral TyBool -> do
                      (b :: Bool) <- choose
                      let v = if b then 1 else 0
                      return $ CIntConst (cInteger v) (undefNode, ty)
                   | ty `sameType` integral TyUInt -> do
                      (v :: Int32) <- choose
                      return $ CIntConst (cInteger $ fromIntegral v) (undefNode, ty)
                   | otherwise -> do
                      (v :: Int32) <- choose
                      return $ CIntConst (cInteger $ fromIntegral v) (undefNode, ty)
      let  constant'   = CConst constv
           var        = CVar varName (undefNode, ty)
           identifier = CVar (builtinIdent "__VERIFIER_assert") (undefNode,voidType)
           expression = CBinary CNeqOp var constant' (undefNode, boolType)
           stmt       = CExpr (Just $ CCall identifier [expression] (undefNode, voidType)) (undefNode, voidType)
      return stmt