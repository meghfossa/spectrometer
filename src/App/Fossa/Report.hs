module App.Fossa.Report (
  reportMain,
  ReportType (..),
) where

import App.Fossa.API.BuildWait
import App.Fossa.FossaAPIV1 qualified as Fossa
import App.Fossa.ProjectInference
import App.Types
import Control.Carrier.Diagnostics
import Control.Carrier.StickyLogger (logSticky, runStickyLogger)
import Data.Aeson qualified as Aeson
import Data.Functor (void)
import Data.String.Conversion (decodeUtf8)
import Data.Text (Text)
import Data.Text.IO (hPutStrLn)
import Effect.Logger
import Effect.ReadFS
import Fossa.API.Types (ApiOpts)
import System.Exit (exitFailure)
import System.IO (stderr)

data ReportType
  = AttributionReport

reportName :: ReportType -> Text
reportName r = case r of
  AttributionReport -> "attribution"

reportMain ::
  BaseDir ->
  ApiOpts ->
  Severity ->
  -- | timeout (seconds)
  Int ->
  ReportType ->
  OverrideProject ->
  IO ()
reportMain (BaseDir basedir) apiOpts logSeverity timeoutSeconds reportType override = do
  -- TODO: refactor this code duplicate from `fossa test`
  {-
  Most of this module (almost everything below this line) has been copied
  from App.Fossa.Test.  I wanted to push this out sooner, and refactoring
  everything right away was not appropriate for the timing of this command.

  Main points of refactor:
  * Waiting for builds and issue scans (separately, but also together)
    * Above includes errors, types, and scaffolding
  * Timeout over `IO a` (easy to move, but where do we move it?)
  * CLI command refactoring as laid out in https://github.com/fossas/issues/issues/129
  -}
  void . timeout timeoutSeconds . withDefaultLogger logSeverity . runStickyLogger SevInfo $
    logWithExit_ . runReadFSIO $ do
      revision <- mergeOverride override <$> (inferProjectFromVCS basedir <||> inferProjectCached basedir <||> inferProjectDefault basedir)

      logInfo ""
      logInfo ("Using project name: `" <> pretty (projectName revision) <> "`")
      logInfo ("Using revision: `" <> pretty (projectRevision revision) <> "`")

      logSticky "[ Waiting for build completion... ]"

      waitForBuild apiOpts revision <||> waitForMonorepoScan apiOpts revision

      logSticky "[ Waiting for issue scan completion... ]"

      _ <- waitForIssues apiOpts revision

      logSticky $ "[ Fetching " <> reportName reportType <> " report... ]"

      jsonValue <- case reportType of
        AttributionReport ->
          Fossa.getAttribution apiOpts revision

      logStdout . decodeUtf8 $ Aeson.encode jsonValue

  hPutStrLn stderr "Timed out while waiting for build/issues scan"
  exitFailure
