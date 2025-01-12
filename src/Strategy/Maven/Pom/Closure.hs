module Strategy.Maven.Pom.Closure (
  findProjects,
  MavenProjectClosure (..),
  buildProjectClosures,
) where

import Algebra.Graph.AdjacencyMap qualified as AM
import Algebra.Graph.AdjacencyMap.Algorithm qualified as AM
import Control.Algebra
import Control.Carrier.State.Strict
import Control.Effect.Diagnostics
import Data.Foldable (traverse_)
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as S
import Discovery.Walk
import Effect.ReadFS
import Path
import Path.IO qualified as PIO
import Strategy.Maven.Pom.PomFile
import Strategy.Maven.Pom.Resolver

findProjects :: (Has ReadFS sig m, Has Diagnostics sig m) => Path Abs Dir -> m [MavenProjectClosure]
findProjects basedir = do
  pomFiles <- context "Finding pom files" $ findPomFiles basedir
  globalClosure <- context "Building global closure" $ buildGlobalClosure pomFiles
  context "Building project closures" $ pure (buildProjectClosures basedir globalClosure)

findPomFiles :: (Has ReadFS sig m, Has Diagnostics sig m) => Path Abs Dir -> m [Path Abs File]
findPomFiles dir = execState @[Path Abs File] [] $
  flip walk dir $ \_ _ files -> do
    let poms = filter (\file -> "pom.xml" `isSuffixOf` fileName file || ".pom" `isSuffixOf` fileName file) files
    traverse_ (modify . (:)) poms

    pure (WalkSkipSome ["target"])

buildProjectClosures :: Path Abs Dir -> GlobalClosure -> [MavenProjectClosure]
buildProjectClosures basedir global = closures
  where
    closures = map (\(path, (coord, pom)) -> toClosure path coord pom) (M.toList projectRoots)

    toClosure :: Path Abs File -> MavenCoordinate -> Pom -> MavenProjectClosure
    toClosure path coord pom = MavenProjectClosure path coord pom reachableGraph reachablePomMap
      where
        reachableGraph = AM.induce (`S.member` reachablePoms) $ globalGraph global
        reachablePomMap = M.filterWithKey (\k _ -> S.member k reachablePoms) $ globalPoms global
        reachablePoms = bidirectionalReachable coord (globalGraph global)

    projectRoots :: Map (Path Abs File) (MavenCoordinate, Pom)
    projectRoots = determineProjectRoots basedir global graphRoots

    graphRoots :: [MavenCoordinate]
    graphRoots = sourceVertices (globalGraph global)

-- Find reachable nodes both below (children, grandchildren, ...) and above (parents, grandparents) the node
bidirectionalReachable :: Ord a => a -> AM.AdjacencyMap a -> S.Set a
bidirectionalReachable node gr = S.fromList $ AM.reachable node gr ++ AM.reachable node (AM.transpose gr)

sourceVertices :: Ord a => AM.AdjacencyMap a -> [a]
sourceVertices graph = [v | v <- AM.vertexList graph, S.null (AM.preSet v graph)]

determineProjectRoots :: Path Abs Dir -> GlobalClosure -> [MavenCoordinate] -> Map (Path Abs File) (MavenCoordinate, Pom)
determineProjectRoots rootDir closure = go . S.fromList
  where
    go :: Set MavenCoordinate -> Map (Path Abs File) (MavenCoordinate, Pom)
    go coordRoots
      | S.null coordRoots = M.empty
      | otherwise = M.union projects (go frontier)
      where
        inRoot :: Set (MavenCoordinate, Path Abs File, Pom)
        inRoot =
          S.fromList $
            mapMaybe
              ( \coord -> do
                  (abspath, pom) <- M.lookup coord (globalPoms closure)
                  -- This ensures that the absolute path is relative to the root directory
                  _ <- PIO.makeRelative rootDir abspath
                  Just (coord, abspath, pom)
              )
              (S.toList coordRoots)

        inRootCoords :: Set MavenCoordinate
        inRootCoords = S.map (\(c, _, _) -> c) inRoot

        remainingCoords :: Set MavenCoordinate
        remainingCoords = coordRoots S.\\ inRootCoords

        projects :: Map (Path Abs File) (MavenCoordinate, Pom)
        projects = M.fromList $ S.toList $ S.map (\(coord, path, pom) -> (path, (coord, pom))) inRoot

        frontier :: Set MavenCoordinate
        frontier = S.unions $ S.map (\coord -> AM.postSet coord (globalGraph closure)) remainingCoords

data MavenProjectClosure = MavenProjectClosure
  { closurePath :: Path Abs File
  , closureRootCoord :: MavenCoordinate
  , closureRootPom :: Pom
  , closureGraph :: AM.AdjacencyMap MavenCoordinate
  , closurePoms :: Map MavenCoordinate (Path Abs File, Pom)
  }
  deriving (Eq, Ord, Show)
