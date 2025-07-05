module Kernel.Parse.Move.Internal.Discern.Name
  ( resolveName,
    resolveConstructor,
    resolveLocator,
    interpretGlobalName,
    interpretFoldName,
    resolveDefiniteDescription,
  )
where

import Control.Comonad.Cofree hiding (section)
import Control.Monad
import Control.Monad.Except (liftEither)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Maybe qualified as Maybe
import Data.Text qualified as T
import Error.Move.Run (raiseCritical, raiseError)
import Error.Rule.EIO (EIO)
import Kernel.Common.Move.Handle.Local.Locator qualified as Locator
import Kernel.Common.Move.Handle.Local.Tag qualified as Tag
import Kernel.Common.Rule.Const qualified as C
import Kernel.Common.Rule.GlobalName qualified as GN
import Kernel.Common.Rule.Handle.Global.Env qualified as Env
import Kernel.Common.Rule.ReadableDD
import Kernel.Parse.Move.Internal.Discern.Handle qualified as H
import Kernel.Parse.Move.Internal.Handle.Alias qualified as Alias
import Kernel.Parse.Move.Internal.Handle.NameMap qualified as NameMap
import Kernel.Parse.Move.Internal.Handle.Unused qualified as Unused
import Language.Common.Move.CreateSymbol qualified as Gensym
import Language.Common.Rule.ArgNum qualified as AN
import Language.Common.Rule.Attr.VarGlobal qualified as AttrVG
import Language.Common.Rule.DefiniteDescription qualified as DD
import Language.Common.Rule.Discriminant qualified as D
import Language.Common.Rule.GlobalLocator qualified as GL
import Language.Common.Rule.ImpArgs qualified as ImpArgs
import Language.Common.Rule.IsConstLike
import Language.Common.Rule.LocalLocator qualified as LL
import Language.Common.Rule.Magic qualified as M
import Language.Common.Rule.PiKind qualified as PK
import Language.Common.Rule.PrimNumSize qualified as PNS
import Language.Common.Rule.PrimOp qualified as PO
import Language.Common.Rule.PrimType qualified as PT
import Language.Common.Rule.VariadicKind (VariadicKind)
import Language.RawTerm.Rule.Locator qualified as L
import Language.RawTerm.Rule.Name
import Language.WeakTerm.Move.CreateHole qualified as WT
import Language.WeakTerm.Rule.WeakPrim qualified as WP
import Language.WeakTerm.Rule.WeakPrimValue qualified as WPV
import Language.WeakTerm.Rule.WeakTerm qualified as WT
import Logger.Rule.Hint

{-# INLINE resolveName #-}
resolveName :: H.Handle -> Hint -> Name -> EIO (DD.DefiniteDescription, (Hint, GN.GlobalName))
resolveName h m name = do
  nameOrErr <- resolveNameOrError h m name
  case nameOrErr of
    Left err ->
      raiseError m err
    Right pair ->
      return pair

{-# INLINE resolveNameOrError #-}
resolveNameOrError :: H.Handle -> Hint -> Name -> EIO (Either T.Text (DD.DefiniteDescription, (Hint, GN.GlobalName)))
resolveNameOrError h m name =
  case name of
    Var var -> do
      resolveVarOrErr h m var
    Locator l -> do
      Right <$> resolveLocator h m l True

resolveVarOrErr :: H.Handle -> Hint -> T.Text -> EIO (Either T.Text (DD.DefiniteDescription, (Hint, GN.GlobalName)))
resolveVarOrErr h m name = do
  localLocator <- liftEither $ LL.reflect m name
  candList <- liftIO $ Locator.getPossibleReferents (H.locatorHandle h) localLocator
  candList' <- mapM (NameMap.lookup (H.nameMapHandle h) m) candList
  let foundNameList = Maybe.mapMaybe candFilter $ zip candList candList'
  case foundNameList of
    [] ->
      return $ Left $ "Undefined symbol: " <> name
    [globalVar@(dd, (mDef, gn))] -> do
      liftIO $ Tag.insertGlobalVar (H.tagHandle h) m dd (GN.getIsConstLike gn) mDef
      liftIO $ Unused.deleteLocalLocator (H.unusedHandle h) localLocator
      return $ Right globalVar
    _ -> do
      let mainModule = Env.getMainModule (H.envHandle h)
      let foundNameList' = map (readableDD mainModule . fst) foundNameList
      let candInfo = T.concat $ map ("\n- " <>) foundNameList'
      return $ Left $ "This `" <> name <> "` is ambiguous since it could refer to:" <> candInfo

resolveLocator ::
  H.Handle ->
  Hint ->
  L.Locator ->
  Bool ->
  EIO (DD.DefiniteDescription, (Hint, GN.GlobalName))
resolveLocator h m (gl, ll) shouldInsertTag = do
  sgl <- Alias.resolveAlias (H.aliasHandle h) m gl
  let cand = DD.new sgl ll
  cand' <- NameMap.lookup (H.nameMapHandle h) m cand
  let foundName = candFilter (cand, cand')
  case foundName of
    Nothing ->
      raiseError m $ "Undefined constant: " <> L.reify (gl, ll)
    Just globalVar@(dd, (mDef, gn)) -> do
      when shouldInsertTag $ do
        let glLen = T.length $ GL.reify gl
        let llLen = T.length $ LL.reify ll
        let sepLen = T.length C.nsSep
        liftIO $ Tag.insertLocator (H.tagHandle h) m dd (GN.getIsConstLike gn) (glLen + llLen + sepLen) mDef
      return globalVar

resolveDefiniteDescription ::
  H.Handle ->
  Hint ->
  DD.DefiniteDescription ->
  EIO GN.GlobalName
resolveDefiniteDescription h m dd = do
  cand' <- NameMap.lookup (H.nameMapHandle h) m dd
  let foundName = candFilter (dd, cand')
  case foundName of
    Nothing ->
      raiseCritical m $ "Undefined definite description: " <> DD.reify dd
    Just (_, (_, gn)) -> do
      return gn

resolveConstructor ::
  H.Handle ->
  Hint ->
  Name ->
  EIO (DD.DefiniteDescription, AN.ArgNum, AN.ArgNum, D.Discriminant, IsConstLike, Maybe GN.GlobalName)
resolveConstructor h m s = do
  (dd, (_, gn)) <- resolveName h m s
  case resolveConstructorMaybe dd gn of
    Just v ->
      return v
    Nothing ->
      raiseError m $ "`" <> DD.reify dd <> "` is not a constructor"

resolveConstructorMaybe ::
  DD.DefiniteDescription ->
  GN.GlobalName ->
  Maybe (DD.DefiniteDescription, AN.ArgNum, AN.ArgNum, D.Discriminant, IsConstLike, Maybe GN.GlobalName)
resolveConstructorMaybe dd gn = do
  case gn of
    GN.DataIntro dataArgNum consArgNum disc isConstLike ->
      Just (dd, dataArgNum, consArgNum, disc, isConstLike, Nothing)
    _ ->
      Nothing

interpretGlobalName :: H.Handle -> Hint -> DD.DefiniteDescription -> GN.GlobalName -> EIO WT.WeakTerm
interpretGlobalName h m dd gn = do
  case gn of
    GN.TopLevelFunc argNum isConstLike ->
      return $ interpretTopLevelFunc m dd argNum isConstLike
    GN.Data argNum _ isConstLike ->
      return $ interpretTopLevelFunc m dd argNum isConstLike
    GN.DataIntro dataArgNum consArgNum _ isConstLike -> do
      let argNum = AN.add dataArgNum consArgNum
      let attr = AttrVG.Attr {..}
      return $ m :< WT.PiElim False (m :< WT.VarGlobal attr dd) ImpArgs.Unspecified []
    GN.PrimType primNum ->
      return $ m :< WT.Prim (WP.Type primNum)
    GN.PrimOp primOp ->
      case primOp of
        PO.PrimCmpOp {} ->
          castFromIntToBool h $ m :< WT.Prim (WP.Value (WPV.Op primOp)) -- i1 to bool
        _ ->
          return $ m :< WT.Prim (WP.Value (WPV.Op primOp))
    GN.Fold _ ->
      raiseError m $ "`" <> DD.reify dd <> "` must be used with arguments"

interpretFoldName :: Hint -> DD.DefiniteDescription -> GN.GlobalName -> EIO VariadicKind
interpretFoldName m dd gn = do
  case gn of
    GN.Fold kind ->
      return kind
    _ -> do
      raiseError m $ "`" <> DD.reify dd <> "` is not a macro"

interpretTopLevelFunc ::
  Hint ->
  DD.DefiniteDescription ->
  AN.ArgNum ->
  IsConstLike ->
  WT.WeakTerm
interpretTopLevelFunc m dd argNum isConstLike = do
  let attr = AttrVG.Attr {..}
  if isConstLike
    then m :< WT.PiElim False (m :< WT.VarGlobal attr dd) ImpArgs.Unspecified []
    else m :< WT.VarGlobal attr dd

castFromIntToBool :: H.Handle -> WT.WeakTerm -> EIO WT.WeakTerm
castFromIntToBool h e@(m :< _) = do
  let i1 = m :< WT.Prim (WP.Type (PT.Int PNS.IntSize1))
  l <- liftEither $ DD.getLocatorPair m C.coreBool
  (dd, (_, gn)) <- resolveLocator h m l False
  bool <- interpretGlobalName h m dd gn
  t <- liftIO $ WT.createHole (H.gensymHandle h) m []
  x1 <- liftIO $ Gensym.newIdentFromText (H.gensymHandle h) "arg"
  x2 <- liftIO $ Gensym.newIdentFromText (H.gensymHandle h) "arg"
  let cmpOpType cod = m :< WT.Pi PK.normal [] [(m, x1, t), (m, x2, t)] cod
  return $ m :< WT.Magic (M.WeakMagic $ M.Cast (cmpOpType i1) (cmpOpType bool) e)

candFilter :: (a, Maybe b) -> Maybe (a, b)
candFilter (from, mTo) =
  fmap (from,) mTo
