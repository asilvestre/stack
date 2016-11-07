{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
module Stack.Upgrade (upgrade) where

import           Control.Monad               (when)
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Data.Foldable               (forM_)
import qualified Data.Map                    as Map
import           Data.Maybe                  (isNothing)
import           Data.Monoid.Extra
import qualified Data.Text as T
import           Lens.Micro                  (set)
import           Path
import           Path.IO
import qualified Paths_stack as Paths
import           Stack.Build
import           Stack.Config
import           Stack.Fetch
import           Stack.PackageIndex
import           Stack.Setup
import           Stack.Types.PackageIdentifier
import           Stack.Types.PackageName
import           Stack.Types.Version
import           Stack.Types.Config
import           Stack.Types.Internal
import           Stack.Types.Resolver
import           Stack.Types.StackT
import           System.Process              (readProcess)
import           System.Process.Run

upgrade :: (StackM env m, HasConfig env)
        => ConfigMonoid
        -> Maybe String -- ^ git repository to use
        -> Maybe AbstractResolver
        -> Maybe String -- ^ git hash at time of building, if known
        -> m ()
upgrade gConfigMonoid gitRepo mresolver builtHash =
  withSystemTempDir "stack-upgrade" $ \tmp -> do
    menv <- getMinimalEnvOverride
    mdir <- case gitRepo of
      Just repo -> do
        remote <- liftIO $ readProcess "git" ["ls-remote", repo, "master"] []
        let latestCommit = head . words $ remote
        when (isNothing builtHash) $
            $logWarn $ "Information about the commit this version of stack was "
                    <> "built from is not available due to how it was built. "
                    <> "Will continue by assuming an upgrade is needed "
                    <> "because we have no information to the contrary."
        if builtHash == Just latestCommit
            then do
                $logInfo "Already up-to-date, no upgrade required"
                return Nothing
            else do
                $logInfo "Cloning stack"
                -- NOTE: "--recursive" was added after v1.0.0 (and before the
                -- next release).  This means that we can't use submodules in
                -- the stack repo until we're comfortable with "stack upgrade
                -- --git" not working for earlier versions.
                let args = [ "clone", repo , "stack", "--depth", "1", "--recursive"]
                runCmd (Cmd (Just tmp) "git" menv args) Nothing
                return $ Just $ tmp </> $(mkRelDir "stack")
      Nothing -> do
        updateAllIndices menv
        caches <- getPackageCaches
        let latest = Map.fromListWith max
                   $ map toTuple
                   $ Map.keys

                   -- Mistaken upload to Hackage, just ignore it
                   $ Map.delete (PackageIdentifier
                        $(mkPackageName "stack")
                        $(mkVersion "9.9.9"))

                     caches
        case Map.lookup $(mkPackageName "stack") latest of
            Nothing -> error "No stack found in package indices"
            Just version | version <= fromCabalVersion Paths.version -> do
                $logInfo "Already at latest version, no upgrade required"
                return Nothing
            Just version -> do
                let ident = PackageIdentifier $(mkPackageName "stack") version
                paths <- unpackPackageIdents menv tmp Nothing
                    -- accept latest cabal revision by not supplying a Git SHA
                    $ Map.singleton ident Nothing
                case Map.lookup ident paths of
                    Nothing -> error "Stack.Upgrade.upgrade: invariant violated, unpacked directory not found"
                    Just path -> return $ Just path

    forM_ mdir $ \dir -> do
        lc <- loadConfig
            gConfigMonoid
            mresolver
            (Just $ dir </> $(mkRelFile "stack.yaml"))
        bconfig <- lcLoadBuildConfig lc Nothing
        envConfig1 <- runInnerStackT bconfig $ setupEnv $ Just $
            "Try rerunning with --install-ghc to install the correct GHC into " <>
            T.pack (toFilePath (configLocalPrograms (getConfig bconfig)))
        runInnerStackT (set (envConfigBuildOpts.buildOptsInstallExes) True envConfig1) $
            build (const $ return ()) Nothing defaultBuildOptsCLI
                { boptsCLITargets = ["stack"]
                }
