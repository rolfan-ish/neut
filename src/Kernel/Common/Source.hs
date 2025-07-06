module Kernel.Common.Source
  ( Source (..),
    getRelPathFromSourceDir,
    getBaseReadableLocator,
    attachExtension,
    isCompilationSkippable,
  )
where

import Control.Monad.Catch
import Data.Maybe
import Data.Text qualified as T
import Kernel.Common.Artifact qualified as A
import Kernel.Common.Module qualified as M
import Kernel.Common.OutputKind qualified as OK
import Language.Common.Const
import Logger.Hint
import Path

data Source = Source
  { sourceFilePath :: Path Abs File,
    sourceModule :: M.Module,
    sourceHint :: Maybe Hint
  }
  deriving (Show)

getRelPathFromSourceDir :: (MonadThrow m) => Source -> m (Path Rel File)
getRelPathFromSourceDir source = do
  M.getRelPathFromSourceDir (sourceModule source) (sourceFilePath source)

getBaseReadableLocator :: (MonadThrow m) => Source -> m T.Text
getBaseReadableLocator source = do
  relPath <- getRelPathFromSourceDir source
  (relPathWithoutExtension, _) <- splitExtension relPath
  return $ T.replace "/" nsSep $ T.pack $ toFilePath relPathWithoutExtension

attachExtension :: (MonadThrow m) => Path Abs File -> OK.OutputKind -> m (Path Abs File)
attachExtension file kind =
  case kind of
    OK.LLVM -> do
      addExtension ".ll" file
    OK.Object -> do
      addExtension ".o" file

isCompilationSkippable ::
  A.ArtifactTime ->
  [OK.OutputKind] ->
  Bool
isCompilationSkippable artifactTime outputKindList =
  case outputKindList of
    [] ->
      True
    kind : rest -> do
      case kind of
        OK.LLVM -> do
          let b1 = isJust $ A.llvmTime artifactTime
          let b2 = isCompilationSkippable artifactTime rest
          b1 && b2
        OK.Object -> do
          let b1 = isJust $ A.objectTime artifactTime
          let b2 = isCompilationSkippable artifactTime rest
          b1 && b2
