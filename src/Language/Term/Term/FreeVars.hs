module Language.Term.Term.FreeVars (freeVars) where

import Control.Comonad.Cofree
import Data.Maybe
import Data.Set qualified as S
import Language.Common.Attr.Lam qualified as AttrL
import Language.Common.Binder
import Language.Common.DecisionTree qualified as DT
import Language.Common.Ident
import Language.Term.Prim qualified as P
import Language.Term.PrimValue qualified as PV
import Language.Term.Term qualified as TM

freeVars :: TM.Term -> S.Set Ident
freeVars term =
  case term of
    _ :< TM.Tau ->
      S.empty
    _ :< TM.Var x ->
      S.singleton x
    _ :< TM.VarGlobal {} ->
      S.empty
    _ :< TM.Pi _ impArgs expArgs t -> do
      let impBinders = map fst impArgs
      freeVars' (impBinders ++ expArgs) (freeVars t)
    _ :< TM.PiIntro k impArgs expArgs e ->
      freeVars' (map fst impArgs ++ expArgs ++ catMaybes [AttrL.fromAttr k]) (freeVars e)
    _ :< TM.PiElim _ e impArgs expArgs -> do
      let xs = freeVars e
      let ys1 = S.unions $ map freeVars impArgs
      let ys2 = S.unions $ map freeVars expArgs
      S.unions [xs, ys1, ys2]
    _ :< TM.Data _ _ es ->
      S.unions $ map freeVars es
    _ :< TM.DataIntro _ _ dataArgs consArgs -> do
      S.unions $ map freeVars $ dataArgs ++ consArgs
    m :< TM.DataElim _ oets decisionTree -> do
      let (os, es, ts) = unzip3 oets
      let xs1 = S.unions $ map freeVars es
      let binder = zipWith (\o t -> (m, o, t)) os ts
      let xs2 = freeVars' binder (freeVarsDecisionTree decisionTree)
      S.union xs1 xs2
    _ :< TM.Box t ->
      freeVars t
    _ :< TM.BoxNoema t ->
      freeVars t
    _ :< TM.BoxIntro letSeq e -> do
      let (xts, es) = unzip letSeq
      freeVars' xts (S.unions $ map freeVars (e : es))
    _ :< TM.BoxElim castSeq mxt e1 uncastSeq e2 -> do
      let (xts, es) = unzip $ castSeq ++ [(mxt, e1)] ++ uncastSeq
      freeVars' xts (S.unions $ map freeVars $ es ++ [e2])
    _ :< TM.Let _ mxt e1 e2 -> do
      let set1 = freeVars e1
      let set2 = freeVars' [mxt] (freeVars e2)
      S.union set1 set2
    _ :< TM.Prim prim ->
      case prim of
        P.Value (PV.StaticText t _) ->
          freeVars t
        _ ->
          S.empty
    _ :< TM.Magic der ->
      foldMap freeVars der
    _ :< TM.Resource _ _ unitType discarder copier typeTag -> do
      let xs1 = freeVars unitType
      let xs2 = freeVars discarder
      let xs3 = freeVars copier
      let xs4 = freeVars typeTag
      S.unions [xs1, xs2, xs3, xs4]
    _ :< TM.Void ->
      S.empty

freeVars' :: [BinderF TM.Term] -> S.Set Ident -> S.Set Ident
freeVars' binder zs =
  case binder of
    [] ->
      zs
    ((_, x, t) : xts) -> do
      let hs1 = freeVars t
      let hs2 = freeVars' xts zs
      S.union hs1 $ S.filter (/= x) hs2

freeVarsDecisionTree :: DT.DecisionTree TM.Term -> S.Set Ident
freeVarsDecisionTree tree =
  case tree of
    DT.Leaf _ letSeq e ->
      freeVars (TM.fromLetSeq letSeq e)
    DT.Unreachable ->
      S.empty
    DT.Switch (_, cursor) caseList ->
      S.union (freeVars cursor) (freeVarsCaseList caseList)

freeVarsCaseList :: DT.CaseList TM.Term -> S.Set Ident
freeVarsCaseList (fallbackClause, clauseList) = do
  let xs1 = freeVarsDecisionTree fallbackClause
  let xs2 = S.unions $ map freeVarsCase clauseList
  S.union xs1 xs2

freeVarsCase :: DT.Case TM.Term -> S.Set Ident
freeVarsCase decisionCase = do
  case decisionCase of
    DT.LiteralCase _ _ cont -> do
      freeVarsDecisionTree cont
    DT.ConsCase (DT.ConsCaseRecord {..}) -> do
      let (dataTerms, dataTypes) = unzip dataArgs
      S.unions $ freeVars' consArgs (freeVarsDecisionTree cont) : map freeVars dataTerms ++ map freeVars dataTypes
