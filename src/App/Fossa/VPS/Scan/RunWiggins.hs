{-# LANGUAGE RecordWildCards #-}

module App.Fossa.VPS.Scan.RunWiggins (
  execWiggins,
  execWigginsJson,
  generateWigginsScanOpts,
  generateWigginsAOSPNoticeOpts,
  generateVSIStandaloneOpts,
  generateWigginsMonorepoOpts,
  toPathFilters,
  WigginsOpts (..),
  ScanType (..),
  PathFilters (..),
) where

import App.Fossa.EmbeddedBinary
import App.Fossa.VPS.Types (
  FilterExpressions (FilterExpressions),
  NinjaFilePaths (unNinjaFilePaths),
  NinjaScanID (unNinjaScanID),
  encodeFilterExpressions,
 )
import App.Types
import Control.Carrier.Error.Either
import Control.Effect.Diagnostics
import Data.Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Discovery.Filters
import Effect.Exec
import Effect.Logger
import Fossa.API.Types
import Path
import Text.URI

data ScanType = ScanType
  { followSymlinks :: Bool
  , scanSkipIpr :: Bool
  , scanLicenseOnly :: Bool
  }

data WigginsOpts = WigginsOpts
  { scanDir :: Path Abs Dir
  , spectrometerArgs :: [Text]
  }

data PathFilters = PathFilters
  { onlyPaths :: [Path Rel Dir]
  , excludePaths :: [Path Rel Dir]
  }

toText :: Path a b -> Text
toText = T.pack . toFilePath

toPathFilters :: AllFilters -> PathFilters
toPathFilters AllFilters{includeFilters, excludeFilters} = PathFilters (combinedPaths includeFilters) (combinedPaths excludeFilters)

generateWigginsScanOpts :: Path Abs Dir -> Severity -> ProjectRevision -> ScanType -> FilterExpressions -> ApiOpts -> ProjectMetadata -> WigginsOpts
generateWigginsScanOpts scanDir logSeverity projectRevision scanType fileFilters apiOpts metadata =
  WigginsOpts scanDir $ generateSpectrometerScanArgs logSeverity projectRevision scanType fileFilters apiOpts metadata

generateWigginsAOSPNoticeOpts :: Path Abs Dir -> Severity -> ApiOpts -> ProjectRevision -> NinjaScanID -> NinjaFilePaths -> WigginsOpts
generateWigginsAOSPNoticeOpts scanDir logSeverity apiOpts projectRevision ninjaScanId ninjaInputFiles =
  WigginsOpts scanDir $ generateSpectrometerAOSPNoticeArgs logSeverity apiOpts projectRevision ninjaScanId ninjaInputFiles

generateVSIStandaloneOpts :: Path Abs Dir -> PathFilters -> ApiOpts -> WigginsOpts
generateVSIStandaloneOpts scanDir filters apiOpts = WigginsOpts scanDir $ generateVSIStandaloneArgs apiOpts filters

generateWigginsMonorepoOpts :: Path Abs Dir -> MonorepoAnalysisOpts -> PathFilters -> Severity -> ProjectRevision -> ApiOpts -> ProjectMetadata -> WigginsOpts
generateWigginsMonorepoOpts scanDir monorepoAnalysisOpts filters logSeverity projectRevision apiOpts metadata =
  WigginsOpts scanDir $ generateMonorepoArgs monorepoAnalysisOpts filters logSeverity projectRevision apiOpts metadata

generateSpectrometerAOSPNoticeArgs :: Severity -> ApiOpts -> ProjectRevision -> NinjaScanID -> NinjaFilePaths -> [Text]
generateSpectrometerAOSPNoticeArgs logSeverity ApiOpts{..} ProjectRevision{..} ninjaScanId ninjaInputFiles =
  ["aosp-notice-files"]
    ++ optBool "-debug" (logSeverity == SevDebug)
    ++ optMaybeText "-endpoint" (render <$> apiOptsUri)
    ++ ["-fossa-api-key", unApiKey apiOptsApiKey]
    ++ ["-scan-id", unNinjaScanID ninjaScanId]
    ++ ["-name", projectName]
    ++ ["."]
    ++ (T.pack . toFilePath <$> unNinjaFilePaths ninjaInputFiles)

generateVSIStandaloneArgs :: ApiOpts -> PathFilters -> [Text]
generateVSIStandaloneArgs ApiOpts{..} PathFilters{..} =
  "vsi-direct" :
  optMaybeText "-endpoint" (render <$> apiOptsUri)
    ++ ["-fossa-api-key", unApiKey apiOptsApiKey]
    ++ optExplodeText "-only-path" (toText <$> onlyPaths)
    ++ optExplodeText "-exclude-path" (toText <$> excludePaths)
    ++ ["."]

generateMonorepoArgs :: MonorepoAnalysisOpts -> PathFilters -> Severity -> ProjectRevision -> ApiOpts -> ProjectMetadata -> [Text]
generateMonorepoArgs MonorepoAnalysisOpts{..} PathFilters{..} logSeverity ProjectRevision{..} ApiOpts{..} ProjectMetadata{..} =
  "monorepo" :
  optMaybeText "-endpoint" (render <$> apiOptsUri)
    ++ ["-fossa-api-key", unApiKey apiOptsApiKey]
    ++ ["-project", projectName, "-revision", projectRevision]
    ++ optMaybeText "-jira-project-key" projectJiraKey
    ++ optMaybeText "-link" projectLink
    ++ optMaybeText "-policy" projectPolicy
    ++ optMaybeText "-project-url" projectUrl
    ++ optMaybeText "-team" projectTeam
    ++ optMaybeText "-title" projectTitle
    ++ optExplodeText "-only-path" (toText <$> onlyPaths)
    ++ optExplodeText "-exclude-path" (toText <$> excludePaths)
    ++ optBool "-debug" (logSeverity == SevDebug)
    ++ optMaybeText "-type" monorepoAnalysisType
    ++ ["."]

generateSpectrometerScanArgs :: Severity -> ProjectRevision -> ScanType -> FilterExpressions -> ApiOpts -> ProjectMetadata -> [Text]
generateSpectrometerScanArgs logSeverity ProjectRevision{..} ScanType{..} fileFilters ApiOpts{..} ProjectMetadata{..} =
  "analyze" :
  optMaybeText "-endpoint" (render <$> apiOptsUri)
    ++ ["-fossa-api-key", unApiKey apiOptsApiKey]
    ++ ["-name", projectName, "-revision", projectRevision]
    ++ optMaybeText "-jira-project-key" projectJiraKey
    ++ optMaybeText "-link" projectLink
    ++ optMaybeText "-policy" projectPolicy
    ++ optMaybeText "-project-url" projectUrl
    ++ optMaybeText "-team" projectTeam
    ++ optMaybeText "-title" projectTitle
    ++ optBool "-follow" followSymlinks
    ++ optBool "-license-only" scanLicenseOnly
    ++ optBool "-skip-ipr-scan" scanSkipIpr
    ++ optBool "-debug" (logSeverity == SevDebug)
    ++ optFilterExpressions fileFilters
    ++ ["."]

optFilterExpressions :: FilterExpressions -> [Text]
optFilterExpressions (FilterExpressions []) = []
optFilterExpressions expressions = ["-i", encodeFilterExpressions expressions]

optBool :: Text -> Bool -> [Text]
optBool flag True = [flag]
optBool _ False = []

optMaybeText :: Text -> Maybe Text -> [Text]
optMaybeText _ Nothing = []
optMaybeText flag (Just value) = [flag, value]

optExplodeText :: Text -> [Text] -> [Text]
optExplodeText _ [] = []
optExplodeText flag [a] = [flag, a]
optExplodeText flag (a : as) = [flag, a] ++ optExplodeText flag as

execWiggins :: (Has Exec sig m, Has Diagnostics sig m) => BinaryPaths -> WigginsOpts -> m Text
execWiggins binaryPaths opts = decodeUtf8 . BL.toStrict <$> execThrow (scanDir opts) (wigginsCommand binaryPaths opts)

execWigginsJson :: (FromJSON a, Has Exec sig m, Has Diagnostics sig m) => WigginsOpts -> BinaryPaths -> m a
execWigginsJson opts binaryPaths = execJson (scanDir opts) (wigginsCommand binaryPaths opts)

wigginsCommand :: BinaryPaths -> WigginsOpts -> Command
wigginsCommand bin WigginsOpts{..} = do
  Command
    { cmdName = T.pack $ fromAbsFile $ toExecutablePath bin
    , cmdArgs = spectrometerArgs
    , cmdAllowErr = Never
    }
