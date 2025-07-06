module Kernel.Clarify.Internal.Linearize
  ( Handle (..),
    new,
    linearize,
    linearizeDuplicatedVariables,
  )
where

import Control.Monad
import Control.Monad.IO.Class
import Gensym.Handle qualified as Gensym
import Kernel.Clarify.Internal.Utility qualified as Utility
import Language.Common.CreateSymbol qualified as Gensym
import Language.Common.Ident
import Language.Common.Ident.Reify
import Language.Common.Magic qualified as M
import Language.Comp.Comp qualified as C

type Occurrence = Ident

data Handle = Handle
  { gensymHandle :: Gensym.Handle,
    utilityHandle :: Utility.Handle
  }

new :: Gensym.Handle -> Utility.Handle -> Handle
new gensymHandle utilityHandle = do
  Handle {..}

linearize ::
  Handle ->
  [(Ident, C.Comp)] -> -- [(x1, t1), ..., (xn, tn)]  (closed chain)
  C.Comp -> -- a term that can contain non-linear occurrences of xi
  IO C.Comp -- a term in which all the variables in the closed chain occur linearly
linearize h binder e =
  case binder of
    [] ->
      return e
    (x, t) : xts -> do
      e' <- linearize h xts e
      (newNameList, e'') <- distinguishComp h x e'
      case newNameList of
        [] -> do
          hole <- liftIO $ Gensym.newIdentFromText (gensymHandle h) "unit"
          discardUnusedVar <- Utility.toAffineApp (utilityHandle h) (C.VarLocal x) t
          return $ C.UpElim True hole discardUnusedVar e''
        [z] ->
          return $ C.UpElim True z (C.UpIntro (C.VarLocal x)) e''
        z : zs -> do
          localName <- liftIO $ Gensym.newIdentFromText (gensymHandle h) $ toText x <> "-local"
          e''' <- insertHeader h localName z zs t e''
          return $ C.UpElim False localName (C.UpIntro (C.VarLocal x)) e'''

linearizeDuplicatedVariables ::
  Handle ->
  [(Ident, C.Comp)] ->
  C.Comp ->
  IO C.Comp
linearizeDuplicatedVariables h binder e =
  case binder of
    [] ->
      return e
    (x, t) : xts -> do
      e' <- linearizeDuplicatedVariables h xts e
      (newNameList, e'') <- distinguishComp h x e'
      case newNameList of
        [] -> do
          return e''
        [z] ->
          return $ C.UpElim True z (C.UpIntro (C.VarLocal x)) e''
        z : zs -> do
          localName <- liftIO $ Gensym.newIdentFromText (gensymHandle h) $ toText x <> "-local"
          e''' <- insertHeader h localName z zs t e''
          return $ C.UpElim False localName (C.UpIntro (C.VarLocal x)) e'''

insertHeader ::
  Handle ->
  Ident ->
  Occurrence ->
  [Occurrence] ->
  C.Comp ->
  C.Comp ->
  IO C.Comp
insertHeader h localName z1 zs t e = do
  case zs of
    [] ->
      return $ C.UpElim True z1 (C.UpIntro (C.VarLocal localName)) e
    z2 : rest -> do
      e' <- insertHeader h localName z2 rest t e
      copyRelevantVar <- Utility.toRelevantApp (utilityHandle h) (C.VarLocal localName) t
      return $ C.UpElim True z1 copyRelevantVar e'

distinguishVar :: Handle -> Ident -> Ident -> IO ([Occurrence], Ident)
distinguishVar h z x =
  if x /= z
    then return ([], x)
    else do
      x' <- Gensym.newIdentFromIdent (gensymHandle h) x
      return ([x'], x')

distinguishValue :: Handle -> Ident -> C.Value -> IO ([Occurrence], C.Value)
distinguishValue h z term =
  case term of
    C.VarLocal x -> do
      (vs, x') <- distinguishVar h z x
      return (vs, C.VarLocal x')
    C.SigmaIntro ds -> do
      (vss, ds') <- mapAndUnzipM (distinguishValue h z) ds
      return (concat vss, C.SigmaIntro ds')
    _ ->
      return ([], term)

distinguishComp :: Handle -> Ident -> C.Comp -> IO ([Occurrence], C.Comp)
distinguishComp h z term =
  case term of
    C.Primitive theta -> do
      (vs, theta') <- distinguishPrimitive h z theta
      return (vs, C.Primitive theta')
    C.PiElimDownElim d ds -> do
      (vs, d') <- distinguishValue h z d
      (vss, ds') <- mapAndUnzipM (distinguishValue h z) ds
      return (concat $ vs : vss, C.PiElimDownElim d' ds')
    C.SigmaElim shouldDeallocate xs d e -> do
      (vs1, d') <- distinguishValue h z d
      if z `elem` xs
        then return (vs1, C.SigmaElim shouldDeallocate xs d' e)
        else do
          (vs2, e') <- distinguishComp h z e
          return (vs1 ++ vs2, C.SigmaElim shouldDeallocate xs d' e')
    C.UpIntro d -> do
      (vs, d') <- distinguishValue h z d
      return (vs, C.UpIntro d')
    C.UpElim isReducible x e1 e2 -> do
      (vs1, e1') <- distinguishComp h z e1
      if z == x
        then return (vs1, C.UpElim isReducible x e1' e2)
        else do
          (vs2, e2') <- distinguishComp h z e2
          return (vs1 ++ vs2, C.UpElim isReducible x e1' e2')
    C.EnumElim fvInfo d defaultBranch branchList phiVarList cont -> do
      let (vs, ds) = unzip fvInfo
      (vss, ds') <- mapAndUnzipM (distinguishValue h z) ds
      let fvInfo' = zip vs ds'
      (vs1, d') <- distinguishValue h z d
      if z `elem` phiVarList
        then return (concat vss ++ vs1, C.EnumElim fvInfo' d' defaultBranch branchList phiVarList cont)
        else do
          (vs2, cont') <- distinguishComp h z cont
          return (concat vss ++ vs1 ++ vs2, C.EnumElim fvInfo' d' defaultBranch branchList phiVarList cont')
    C.Free x size cont -> do
      (vs1, x') <- distinguishValue h z x
      (vs2, cont') <- distinguishComp h z cont
      return (vs1 ++ vs2, C.Free x' size cont')
    C.Unreachable ->
      return ([], term)
    C.Phi ds -> do
      (vss, ds') <- mapAndUnzipM (distinguishValue h z) ds
      return (concat vss, C.Phi ds')

distinguishPrimitive :: Handle -> Ident -> C.Primitive -> IO ([Occurrence], C.Primitive)
distinguishPrimitive h z term =
  case term of
    C.PrimOp op ds -> do
      (vss, ds') <- mapAndUnzipM (distinguishValue h z) ds
      return (concat vss, C.PrimOp op ds')
    C.ShiftPointer v size index -> do
      (vs, v') <- distinguishValue h z v
      return (vs, C.ShiftPointer v' size index)
    C.Magic magic -> do
      case magic of
        M.Cast from to value -> do
          (vs1, from') <- distinguishValue h z from
          (vs2, to') <- distinguishValue h z to
          (vs3, value') <- distinguishValue h z value
          return (vs1 <> vs2 <> vs3, C.Magic (M.Cast from' to' value'))
        M.Store lt unit value pointer -> do
          (vs1, unit') <- distinguishValue h z unit
          (vs2, value') <- distinguishValue h z value
          (vs3, pointer') <- distinguishValue h z pointer
          return (vs1 <> vs2 <> vs3, C.Magic (M.Store lt unit' value' pointer'))
        M.Load lt pointer -> do
          (vs, pointer') <- distinguishValue h z pointer
          return (vs, C.Magic (M.Load lt pointer'))
        M.Alloca lt num -> do
          return ([], C.Magic (M.Alloca lt num))
        M.External domList cod extFunName args varArgAndTypeList -> do
          (vss, args') <- mapAndUnzipM (distinguishValue h z) args
          let (varArgs, varTypes) = unzip varArgAndTypeList
          (vss2, varArgs') <- mapAndUnzipM (distinguishValue h z) varArgs
          return (concat vss ++ concat vss2, C.Magic (M.External domList cod extFunName args' (zip varArgs' varTypes)))
        M.Global name lt -> do
          return ([], C.Magic (M.Global name lt))
        M.OpaqueValue e -> do
          (vs, e') <- distinguishValue h z e
          return (vs, C.Magic (M.OpaqueValue e'))
        M.CallType func arg1 arg2 -> do
          (vs1, func') <- distinguishValue h z func
          (vs2, arg1') <- distinguishValue h z arg1
          (vs3, arg2') <- distinguishValue h z arg2
          return (vs1 <> vs2 <> vs3, C.Magic (M.CallType func' arg1' arg2'))
