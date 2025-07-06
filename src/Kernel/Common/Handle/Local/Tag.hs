module Kernel.Common.Handle.Local.Tag
  ( Handle (..),
    new,
    get,
    insertFileLoc,
    insertLocalVar,
    insertGlobalVar,
    insertBinder,
    insertLocator,
    insertExternalName,
  )
where

import Control.Monad (unless, when)
import Data.IORef
import Data.Text qualified as T
import Kernel.Common.LocationTree qualified as LT
import Language.Common.Binder
import Language.Common.DefiniteDescription qualified as DD
import Language.Common.ExternalName qualified as EN
import Language.Common.Ident
import Language.Common.IsConstLike
import Logger.Hint
import Prelude hiding (lookup, read)

newtype Handle = Handle
  { _tagMapRef :: IORef LT.LocationTree
  }

new :: IO Handle
new = do
  _tagMapRef <- newIORef LT.empty
  return $ Handle {..}

get :: Handle -> IO LT.LocationTree
get h =
  readIORef $ _tagMapRef h

insertFileLoc :: Handle -> Hint -> Int -> Hint -> IO ()
insertFileLoc h mUse nameLength mDef = do
  when (metaShouldSaveLocation mUse) $ do
    let (l, c) = metaLocation mUse
    modifyIORef' (_tagMapRef h) $ LT.insert LT.FileLoc (l, (c, c + nameLength)) mDef

insertLocalVar :: Handle -> Hint -> Ident -> Hint -> IO ()
insertLocalVar h mUse ident@(I (var, varID)) mDef = do
  unless (isHole ident) $ do
    let nameLength = T.length var
    let symbolLoc = LT.SymbolLoc (LT.Local varID nameLength)
    insert h mUse symbolLoc nameLength mDef

insertBinder :: Handle -> BinderF a -> IO ()
insertBinder h (m, ident, _) =
  insertLocalVar h m ident m

insertGlobalVar :: Handle -> Hint -> DD.DefiniteDescription -> IsConstLike -> Hint -> IO ()
insertGlobalVar h mUse dd isConstLike mDef = do
  let nameLength = T.length (DD.localLocator dd)
  let symbolLoc = LT.SymbolLoc (LT.Global dd isConstLike)
  insert h mUse symbolLoc nameLength mDef

insert :: Handle -> Hint -> LT.LocType -> Int -> Hint -> IO ()
insert h mUse locType nameLength mDef = do
  when (metaShouldSaveLocation mUse) $ do
    let (l, c) = metaLocation mUse
    modifyIORef' (_tagMapRef h) $ LT.insert locType (l, (c, c + nameLength)) mDef

insertLocator :: Handle -> Hint -> DD.DefiniteDescription -> IsConstLike -> Int -> Hint -> IO ()
insertLocator h mUse dd isConstLike nameLength mDef = do
  insert h mUse (LT.SymbolLoc (LT.Global dd isConstLike)) nameLength mDef

insertExternalName :: Handle -> Hint -> EN.ExternalName -> Hint -> IO ()
insertExternalName h mUse externalName mDef = do
  let symbolLoc = LT.SymbolLoc (LT.Foreign externalName)
  let nameLength = T.length $ EN.reify externalName
  insert h mUse symbolLoc nameLength mDef
