{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# OPTIONS_GHC -fno-warn-orphans   #-}

module Main where

import           ADiff.Prelude

import           Control.Lens.Operators          hiding ((^.))
import qualified Data.List.Key                   as K
import qualified Data.Map                        as Map
import           Data.Maybe                      (fromJust)
import           Data.Ord                        (Down (Down))
import qualified Data.Text                       as T
import qualified Data.Text.IO                    as T
import           Database.Beam
import qualified Database.SQLite.Simple.Extended as SQL
import           Numeric
import qualified Prelude                         as P
import           RIO.List
import           System.Directory                (makeAbsolute)
import           System.Exit
import           System.IO
import qualified Text.PrettyPrint.Tabulate       as Tab

import           ADiff.Application
import           ADiff.Arguments                 as Args hiding (command)
import           ADiff.Data
import           ADiff.Persistence
import qualified ADiff.Query2                    as Q2
import qualified ADiff.Statistics                as Statistics
import qualified ADiff.Util.Tables               as Tbl
import           ADiff.Verifier


data ViewCommand
  = Stats
  | List Q2.Query -- ^ list all findings
  | Count Q2.Query -- ^ count findings
  | DistributionPerFile Q2.Query -- ^ show the distribution
  | GetProgram Text
  | Runs Text
  | MergeOld [FilePath]
  | MergeOldList FilePath
  | MergeNew [FilePath]
  | Verdicts
  | RelativeInclusion Verdict Bool
  | Compare Relatee Relatee

newtype ViewParameters
  = ViewParameters { command :: ViewCommand }


infos = progDesc "viewer for adiff"

main :: IO ()
main = runADiffApp viewParameters infos $ \vp -> executeView (command vp)

instance Tab.CellValueFormatter Text
instance Tab.CellValueFormatter ProgramId
instance Tab.CellValueFormatter Verdict
instance Tab.CellValueFormatter VerifierResult
instance Tab.CellValueFormatter VerifierRun

instance Tab.Tabulate VerifierResult Tab.ExpandWhenNested
instance Tab.Tabulate VerifierRun Tab.ExpandWhenNested

executeView :: (HasMainEnv env) => ViewCommand -> RIO env ()
executeView Stats = do
  stats <- Q2.getStatistics
  liftIO $  Tab.printTable stats
executeView (List q) = do
  rs <- Q2.executeQuerySimple q
  printFindingsTable rs

executeView (Count q) = do
  n <- Q2.executeQueryCount q
  liftIO $ print n
executeView (DistributionPerFile q) = do
  rs <- Q2.executeQuerySimple q
  let grouped = sortOn (Down . length) $ K.group (^. Q2.findingOrigin) $ sortOn (^. Q2.findingOrigin) rs
  let counts = map (\fs -> (P.head fs ^. Q2.findingOrigin, length fs )) grouped
  liftIO $ Tab.printTableWithFlds flds counts
  where
    flds = [ Tab.DFld $ T.unpack . fst
           , Tab.DFld snd
           ]

executeView (GetProgram hsh) = do
  p <- Q2.getProgramByHash hsh
  liftIO $ case p of
    Just p' -> T.putStr (p' ^. source)
    Nothing -> do
      T.hPutStrLn stderr $ "could not find program with hash: " <> hsh
      exitFailure

executeView (Runs hsh) = do
  runs <- Q2.runsByHashR hsh
  liftIO $ Tab.printTableWithFlds flds runs
  where
   flds = [ Tab.DFld (^. runId)
          , Tab.DFld $ T.unpack . (^. verifierName)
          , Tab.DFld (^. (result . verdict))
          , Tab.DFld (^. iteration)
          ]

executeView (MergeOld files) = mergeFiles files

executeView (MergeOldList file) = do
  files <- lines <$> liftIO (readFile file)
  mergeFiles files

executeView Verdicts = do
  stats <- mapM  (\v -> (v ^. name,) <$>  Statistics.verdicts (Just [v ^. name])) allVerifiers
  let tbl = Tbl.table $ Tbl.row ["verifier", "sats", "unsats", "unknown"] : map (Tbl.toRow . (\(x,(a,b,c)) -> (x,a,b,c))) stats
  liftIO $ T.putStr $ Tbl.renderTable tbl

executeView (RelativeInclusion vrd ignoreUnknown) = do
  Q2.ensureConsensusExists defaultWeights
  tbl <- Statistics.overPairsWithConsensus defaultWeights (Statistics.relative vrd ignoreUnknown)
  liftIO $ T.putStr $ Tbl.renderTable $ mkTable tbl
  where
    relatees = [ RelateName (v ^. name) | v <- allVerifiers ] ++ [ConsensusBy defaultWeights]
    mkTable :: Map (Relatee, Relatee) (Integer, Integer) -> Tbl.Table
    mkTable m = Tbl.table $ headers : [mkRow r1 | r1 <- relatees ]
      where
        mkRow r1 = Tbl.row $ printRelatee r1 : [ mkCell r1 r2 | r2 <- relatees]
        mkCell  r1 r2 = formatCorrelation $ fromJust $ Map.lookup (r1, r2) m
        headers = Tbl.row $ "  " : map printRelatee relatees

executeView (Compare v1 v2) = do
  (bigN, tbl) <- Statistics.getBinaryComparison v1 v2
  liftIO $ T.putStr $ Tbl.renderTable $ mkTable bigN tbl
  where
    mkTable bigN m = Tbl.table $ headers : [mkRow bigN vrd1 | vrd1 <- allVerdicts ]
      where
        mkRow bigN vrd1 = Tbl.row $ tshow vrd1 : [ mkCell bigN vrd1 vrd2 | vrd2 <- allVerdicts ]
        mkCell bigN vrd1 vrd2 = let n = fromJust $ Map.lookup (vrd1, vrd2) m
                            in formatCorrelation (n,bigN)
        headers = Tbl.row $ "  " : map tshow allVerdicts
        allVerdicts = [Sat, Unknown, Unsat]


mergeFiles :: (HasMainEnv env) => [FilePath] -> RIO env ()
mergeFiles files =
  -- loop over the given databases
  forM_ files $ \f -> do
    logInfo $ "merging file " <> display (tshow f)
    -- collect some data for the tags
    absFn <- liftIO $ makeAbsolute f
    now <- nowISO
    let tags = [ ("metadata.merge.database",  T.pack absFn)
               , ("metadata.merge.date", now)]


    SQL.withConnection f $ \conn -> do
      logInfo "merging programs"

      SQL.fold_ conn "SELECT code_hash,origin,content FROM programs" (0::Int) $ \counter prg -> do
        let (hsh, origin, src) = prg :: (Text,Text,Text)
        let p = Program  hsh origin src :: Program
        Q2.storeProgram p
        Q2.tagProgram (toProgramId hsh) tags
        when (counter `mod` 10 == 0) $ logSticky $ "number of transferred programs: " <> display counter
        return (counter + 1)

      logInfo "merging runs"

      SQL.fold_ conn "SELECT run_id,verifier_name,result,time,memory,code_hash FROM runs;" (0::Int) $ \counter row -> do
        let (_ :: Integer, vn :: Text, vd :: Verdict, time :: Maybe Double, mem :: Maybe Int, hsh :: Text ) = row
        r <- Q2.storeRunFreshId $ VerifierRun (-1) vn (toProgramId hsh) (VerifierResult time mem vd ) (-1)
        Q2.tagRun (primaryKey r) tags
        when (counter `mod` 10 == 0) $ logSticky $ "number of transferred runs: " <> display counter
        return (counter + 1)



viewParameters :: Parser ViewParameters
viewParameters = ViewParameters <$> viewCommand
  where
    viewCommand = asum [ listCmd
                       , countCmd
                       , programCmd
                       , mergeOldCmd
                       , mergeOldListCmd
                       , runsCmd
                       , distributionCmd
                       , statCmd
                       , verdictsCmd
                       , relativeInclusionCmd
                       , compareCmd
                       ]

statCmd, listCmd, countCmd, programCmd, mergeOldCmd, mergeOldListCmd, runsCmd, verdictsCmd  :: Parser ViewCommand
statCmd = switch options $> Stats
  where options = mconcat [ long "stat"
                          , short 's'
                          , help "print basic statistics about this database"
                          ]

listCmd = switch options $> List <*> parseQuery2
  where options = mconcat [ long "list"
                          , short 'l'
                          , help "prints a list"
                          ]

countCmd = switch options $> Count <*> parseQuery2
  where options = mconcat [ long "count"
                          , help "returns the number of findings"
                          ]

programCmd = GetProgram <$> option str options
  where options = mconcat [ long "hash"
                          , help "returns the source code of a program with the given hash"
                          , metavar "HASH"
                          ]

mergeOldCmd = switch options $>  MergeOld <*> many someFile
  where options = mconcat [ long "merge-old"
                          , help "merge database files into one"]


mergeOldListCmd = switch options $>  MergeOldList <*> someFile
  where options = mconcat [ long "merge-old-list"
                          , help "merge database files into one"]

runsCmd = Runs <$> option str options
  where options = mconcat [ long "runs"
                          , help "shows all runs using the program with the given hash"
                          , metavar "HASH"
                          ]

distributionCmd = switch options $> DistributionPerFile <*> parseQuery2
  where options = mconcat [ long "per-file"
                          , help "shows the number of findings per file" ]

verdictsCmd = switch options $> Verdicts
  where options = long "verdicts" <> help "counts the frequency of each verdict for the given verifiers"

relativeInclusionCmd = switch (long "relative-soundness")    $> RelativeInclusion Sat   True <|>
                       switch (long "relative-completeness") $> RelativeInclusion Unsat True <|>
                       switch (long "relative-recall")       $> RelativeInclusion Sat   False <|>
                       switch (long "relative-precision")    $> RelativeInclusion Unsat False

compareCmd :: Parser ViewCommand
compareCmd = switch options $> Compare <*> Args.relatee <*> Args.relatee
  where options = long "compare"

parseFocus :: Parser [VerifierName]
parseFocus = map (\(vn,_,_)-> vn) <$> Args.verifiers

parseQuery2 :: Parser Q2.Query
parseQuery2 = everything <|> unsound <|> incomplete
  where
    everything = switch (long "everything") $> Q2.Everything
    unsound = switch (long "unsound") $> Q2.Query Q2.SuspicionUnsound  Nothing <*> parseAccordingTo
    incomplete = switch (long "incomplete") $> Q2.Query Q2.SuspicionIncomplete Nothing <*> parseAccordingTo
    parseAccordingTo :: Parser Relatee
    parseAccordingTo =  asum [ RelateName <$> option str (long "according-to")
                             , pure (ConsensusBy defaultWeights)
                             ]
    listOfVerifierNames = map T.strip . T.splitOn "," <$>  str


printFindingsTable :: (MonadIO m) => [Q2.Finding] -> m ()
printFindingsTable rs = liftIO $ Tab.printTableWithFlds dspls rs
  where
    dspls = [ Tab.DFld (T.unpack . T.take 12 .  programIdToHash . (^. Q2.findingProgramId))
            , Tab.DFld (T.unpack . (^. Q2.findingOrigin))
            , Tab.DFld (T.unpack . T.intercalate "," . (^. Q2.findingSatVerifiers))
            , Tab.DFld (T.unpack . T.intercalate "," . (^. Q2.findingUnsatVerifiers))
            ]
