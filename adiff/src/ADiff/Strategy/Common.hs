{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE MultiWayIf                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE ScopedTypeVariables       #-}

-- | common things that are necessary to implement strategies.
module ADiff.Strategy.Common
  ( module ADiff.Strategy.Common
  , module ADiff.Strategy.Common.ConstantPool
  , Ident
  , Type
  ) where

import           Control.Lens
import           Control.Monad.State
import qualified Data.Map                                 as Map
import qualified Data.Text                                as T
import           Database.Beam
import           Database.Beam.Backend.SQL.BeamExtensions
import           Language.C
import           Language.C.Analysis.SemRep               hiding (Stmt)
import           Language.C.Analysis.TypeUtils
import qualified Prelude                                  as P
import           Safe
import           System.IO                                (hPutStr)
import           System.Random
import           Text.PrettyPrint.HughesPJ                (render)
import           ADiff.Data
import           ADiff.Execute
import           ADiff.Instrumentation
import           ADiff.Instrumentation.Reads
import           ADiff.Persistence
import           ADiff.Prelude
import qualified ADiff.Query2                             as Q2
import           ADiff.Strategy.Common.Budget
import           ADiff.Strategy.Common.ConstantPool
import           ADiff.Util.ResourcePool

class (HasTranslationUnit env, HasLogFunc env, HasDiffParameters env) => StrategyEnv env


-- | This verify runs inside a 'MonadBudget' environment and will automatically
-- decrement its budget. Also, it has access to the iteration count through the
-- strategy env.
verifyB :: (IsStrategyEnv env, MonadReader env m, MonadIO m, MonadBudget m)
  => CTranslationUnit SemPhase
  -> m ([VerifierRun], Conclusion)
verifyB tu = do
  completeBudget <- view initialBudget
  currentBudget <- getBudget
  let n = completeBudget - currentBudget
  budgeted (verify n tu)


verify :: (IsStrategyEnv env, MonadReader env m, MonadIO m)
  => Int -- ^ iteration count
  -> CTranslationUnit SemPhase -- ^ translation unit
  -> m ([VerifierRun], Conclusion)
verify n tu = do
  (prog, res) <- verify' n tu
  let conclusion = conclude res
  case conclusion of
    Unsoundness _ -> logInfo $ "found unsoundness with program " <> display (prog ^. hash)
    Incompleteness _ -> logInfo $ "found incompleteness with program " <> display (prog ^. hash)
    _ -> return ()
  return (res, conclusion)

verify' :: (IsStrategyEnv env, MonadReader env m, MonadIO m)
  => Int -- ^ iteration count
  -> CTranslationUnit SemPhase -- ^ translation unit
  -> m (Program, [VerifierRun])
verify' n tu = do
  vs <- view (diffParameters . verifiers)
  resources <- view (diffParameters . verifierResources)
  originalFileName <- view (diffParameters . inputFile)
  env <- ask
  let content = render . pretty $ tu
      program' = mkProgram originalFileName content
  runRIO env $ Q2.storeProgram program'

  runs <- runRIO env $ verifyParallel resources vs program' n
  return (program', runs)

verifyParallel :: (IsStrategyEnv env)
  => [VerifierResources]
  -> [(VerifierName, [Text], Maybe VerifierName)]
  -> Program -- ^ the program source
  -> Int -- ^ iteration counter
  -> RIO env [VerifierRun]
verifyParallel resources verifiers program n = do
  pool <- newResourcePool resources
  withResourcePool pool $ flip map verifiers $ \(vn, flags, newVn) r -> do
      let name = fromMaybe vn newVn
      -- check if we have already some result for this
      Q2.lookupRun name (program ^. hash) >>= \case
        Just r -> do
          logInfo "using cached verifier result"
          when (r ^. iteration == -1) $ Q2.updateRun ((iteration .~ n) r)
          return r
        Nothing -> do
          -- Okay, we actually have to run the verifier
          res <- executeVerifierInDocker r vn flags (program ^. source)
          run <- Q2.storeRunFreshId $ VerifierRun 0 name (pk program) res n
          unless (null flags) $
            Q2.tagRun (pk run) [("flags", T.intercalate "," flags)]
          return run

conclude :: [VerifierRun] -> Conclusion
conclude  rs = if
  | all (\r -> r ^. (result . verdict) == Sat) rs                  -> StrongAgreement Sat
  | all (\r -> r ^. (result . verdict) == Unsat) rs                -> StrongAgreement Unsat
  | all (\r -> r ^. (result . verdict) `elem` [Sat, Unknown]) rs   -> WeakAgreement Sat
  | all (\r -> r ^. (result . verdict) `elem` [Unsat, Unknown]) rs -> WeakAgreement Unsat
  | length sats > length unsats && not (null unsats)                  -> Unsoundness unsats
  | length unsats > length sats && not (null sats)                    -> Incompleteness sats
  | otherwise -> Disagreement
  where
    sats,unsats :: [Text]
    unsats = [ r ^. verifierName | r <- rs, r ^. (result . verdict) == Unsat ]
    sats =   [ r ^. verifierName | r <- rs, r ^. (result . verdict) == Sat ]



mkRandomAssertion :: (MonadRandom m)  => CExpression SemPhase -> m Stmt
mkRandomAssertion e = do
      let ty = getType e
      constv <-mkRandomConstant ty
      let constant'  = CConst constv
          expression = CBinary CNeqOp e constant' (undefNode, boolType)
      return (assertStmt expression)

mkAssertionFromPool :: (MonadRandom m) => CExpression SemPhase -> ConstantPool -> m (Maybe Stmt)
mkAssertionFromPool e pool = do
  let ty = getType e
  let cs = lookupPool ty pool
  chooseOneOf cs >>= \case
    Nothing -> return Nothing
    Just c' -> do
      let cnst = CConst c'
          expr = CBinary CNeqOp e cnst (undefNode, voidType)
      return $ Just $ assertStmt expr


mkRandomConstant :: (MonadRandom m) => Type -> m (CConstant SemPhase)
mkRandomConstant ty
  | ty `sameType` integral TyChar = do
      (b :: Word8) <- getRandom -- a C 'char' is only a Word8
      let c = P.toEnum $ P.fromEnum b
      return $ CCharConst (CChar c False) (undefNode, ty)

  | ty `sameType` integral TyBool = do
    (b :: Bool) <- getRandom
    let v = if b then 1 else 0
    return $ CIntConst (cInteger v) (undefNode, ty)

  | ty `sameType` integral TyUInt = do
      (v :: Int32) <- uniformLengthInt
      return $ CIntConst (cInteger $ fromIntegral (abs v))  (undefNode, ty)

  | otherwise = do
      (v :: Int32) <- uniformLengthInt
      return $ CIntConst (cInteger $ fromIntegral v) (undefNode, ty)

-- | produces a random int32, where the bitwidth is uniformly distributed between 0 and 32
uniformLengthInt :: (MonadRandom m) => m Int32
uniformLengthInt = do
  width <- getRandomR (1,32)
  bits <- take width <$> getRandoms
  return $ bitsToNum $! bits
  where
    bitsToNum :: [Bool] -> Int32
    bitsToNum = foldl' f 0
    f n False = 2 * n
    f n True  = 2 * n + 1

assertStmt :: CExpression SemPhase -> CStatement SemPhase
assertStmt expr = CExpr (Just $ CCall identifier [expr] (undefNode, voidType)) (undefNode, voidType)
  where
    identifier = CVar (builtinIdent "__VERIFIER_assert") (undefNode,voidType)

-- | assertUnequal e c results in an AST fragment with the assertion @e != c@
assertUnequal :: CExpression SemPhase -> CConstant SemPhase -> CStatement SemPhase
assertUnequal expr c = assertStmt $ expr `unequalC` CConst c


-- | assertUnequals e c1, c2,.. results in an AST fragment with the assertion @e
-- != c1 && e != c2 ...@
assertUnequals :: CExpression SemPhase -> [CConstant SemPhase] -> CStatement SemPhase
assertUnequals expr []     = assertStmt constantTrue
assertUnequals expr (c:cs) = assertStmt $ foldl' f (expr `unequalC` CConst c) cs
  where
    f e c            = e `andC` CBinary CNeqOp expr (CConst c) (undefNode, boolType)



-- | a simple 'assert(false)' statement
assertFalse :: CStatement SemPhase
assertFalse = assertStmt constantFalse

constantTrue = CConst $ CIntConst (cInteger 0) (undefNode, voidType)
constantFalse = CConst $ CIntConst (cInteger 1) (undefNode, voidType)

-- little shortcuts
andC, unequalC :: CExpression SemPhase -> CExpression SemPhase -> CExpression SemPhase
e1 `andC` e2     = CBinary CLndOp e1 e2 (undefNode, boolType)
e1 `unequalC` e2 = CBinary CNeqOp e1 e2 (undefNode, boolType)


currentReads :: (MonadBrowser m, MonadReader env m, HasDiffParameters env) => m [CExpression SemPhase]
currentReads = do
  m <- view (diffParameters . searchMode)
  stmt <- currentStmt
  return $ readStatement m stmt
