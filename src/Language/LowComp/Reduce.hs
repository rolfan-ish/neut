module Language.LowComp.Reduce
  ( Handle,
    new,
    reduce,
  )
where

import Data.IntMap qualified as IntMap
import Gensym.Handle qualified as Gensym
import Language.Common.CreateSymbol qualified as Gensym
import Language.Common.Ident.Reify qualified as Ident
import Language.LowComp.LowComp qualified as LC
import Language.LowComp.Subst

newtype Handle = Handle
  { gensymHandle :: Gensym.Handle
  }

new :: Gensym.Handle -> Handle
new gensymHandle = do
  Handle {..}

reduce :: Handle -> SubstLowComp -> LC.Comp -> IO LC.Comp
reduce h sub lowComp = do
  reduce' h sub lowComp

reduce' :: Handle -> SubstLowComp -> LC.Comp -> IO LC.Comp
reduce' h sub lowComp = do
  case lowComp of
    LC.Return d ->
      return $ LC.Return $ substLowValue sub d
    LC.Let x op cont ->
      case op of
        LC.Bitcast d from to
          | from == to -> do
              let sub' = IntMap.insert (Ident.toInt x) (substLowValue sub d) sub
              reduce' h sub' cont
        _ -> do
          x' <- Gensym.newIdentFromIdent (gensymHandle h) x
          let sub' = IntMap.insert (Ident.toInt x) (LC.VarLocal x') sub
          cont' <- reduce' h sub' cont
          return $ LC.Let x' (substOp sub op) cont'
    LC.Cont op cont -> do
      let op' = substOp sub op
      cont' <- reduce' h sub cont
      return $ LC.Cont op' cont'
    LC.Switch (d, t) defaultBranch ces (phiList, cont) -> do
      let d' = substLowValue sub d
      let (cs, es) = unzip ces
      defaultBranch' <- reduce' h sub defaultBranch
      es' <- mapM (reduce' h sub) es
      phiList' <- mapM (Gensym.newIdentFromIdent (gensymHandle h)) phiList
      let newSub = IntMap.fromList $ zipWith (\x y -> (Ident.toInt x, LC.VarLocal y)) phiList phiList'
      let sub' = IntMap.union newSub sub
      cont' <- reduce' h sub' cont
      return $ LC.Switch (d', t) defaultBranch' (zip cs es') (phiList', cont')
    LC.TailCall codType d tds -> do
      let d' = substLowValue sub d
      let (ts, ds) = unzip tds
      let ds' = map (substLowValue sub) ds
      return $ LC.TailCall codType d' (zip ts ds')
    LC.Unreachable ->
      return LC.Unreachable
    LC.Phi ds -> do
      let ds' = map (substLowValue sub) ds
      return $ LC.Phi ds'
