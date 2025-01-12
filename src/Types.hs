{-# LANGUAGE RecordWildCards #-}

module Types (
  DiscoveredProject (..),
  FoundTargets (..),
  BuildTarget (..),
  LicenseResult (..),
  License (..),
  LicenseType (..),
  module DepTypes,
  TargetFilter (..),
) where

import Data.Aeson (
  FromJSON (parseJSON),
  KeyValue ((.=)),
  ToJSON (toJSON),
  object,
  withObject,
  (.:),
  (.:?),
 )

import Data.Aeson.Types (Parser)
import Data.Set.NonEmpty (NonEmptySet)
import Data.Text (Text)
import Data.Text qualified as T
import DepTypes (
  DepEnvironment (..),
  DepType (..),
  Dependency (..),
  VerConstraint (..),
  insertEnvironment,
  insertLocation,
  insertTag,
 )
import Graphing (Graphing)
import Path (Abs, Dir, Path, Rel, parseRelDir)

-- TODO: results should be within a graph of build targets && eliminate SubprojectType

data FoundTargets = ProjectWithoutTargets | FoundTargets (NonEmptySet BuildTarget)
  deriving (Eq, Ord, Show)

instance Semigroup FoundTargets where
  a <> ProjectWithoutTargets = a
  ProjectWithoutTargets <> a = a
  (FoundTargets a) <> (FoundTargets b) = FoundTargets (a <> b)

instance Monoid FoundTargets where
  mempty = ProjectWithoutTargets

-- | A project found during project discovery, parameterized by the monad
-- used to perform dependency analysis
data DiscoveredProject m = DiscoveredProject
  { projectType :: Text
  , projectPath :: Path Abs Dir
  , projectBuildTargets :: FoundTargets
  , projectDependencyGraph :: FoundTargets -> m (Graphing Dependency)
  , projectLicenses :: m [LicenseResult]
  }

newtype BuildTarget = BuildTarget {unBuildTarget :: Text}
  deriving (Eq, Ord, Show)

{-
  The following filters separate the difference between the following filters:
    gomod -> TypeTarget
    mvn@foo/ -> TypeDirTarget
    gradle@./::test-benchmark -> TypeDirTargetTarget

  The majority of build targets consist of a strategy type and a directory.
  However, many Gradle targets consist of a strategy type, a directory,
  and an exact gradle target.
-}
data TargetFilter = TypeTarget Text | TypeDirTarget Text (Path Rel Dir) | TypeDirTargetTarget Text (Path Rel Dir) BuildTarget
  deriving (Eq, Ord, Show)

instance FromJSON TargetFilter where
  parseJSON = withObject "TargetFilter" $ \obj -> do
    tool <- obj .: "type"
    ts <- obj .:? "path" >>= traverse pathParser
    case ts of
      Nothing -> pure $ TypeTarget tool
      Just path -> do
        targetField <- obj .:? "target"
        case targetField of
          Nothing -> pure $ TypeDirTarget tool path
          Just targetFound -> pure $ TypeDirTargetTarget tool path (BuildTarget targetFound)

pathParser :: Text -> Parser (Path Rel Dir)
pathParser input = do
  case parseRelDir (T.unpack input) of
    Left err -> fail (show err)
    Right value -> pure value

data LicenseResult = LicenseResult
  { licenseFile :: FilePath
  , licensesFound :: [License]
  }
  deriving (Eq, Ord, Show)

data License = License
  { licenseType :: LicenseType
  , licenseValue :: Text
  }
  deriving (Eq, Ord, Show)

data LicenseType
  = LicenseURL
  | LicenseFile
  | LicenseSPDX
  | UnknownType
  deriving (Eq, Ord, Show)

instance ToJSON License where
  toJSON License{..} =
    object
      [ "type" .= textType licenseType
      , "value" .= licenseValue
      ]
    where
      textType :: LicenseType -> Text
      textType = \case
        LicenseURL -> "url"
        LicenseFile -> "file"
        LicenseSPDX -> "spdx"
        UnknownType -> "unknown"

instance ToJSON LicenseResult where
  toJSON LicenseResult{..} =
    object
      [ "filepath" .= licenseFile
      , "licenses" .= licensesFound
      ]
