module Language.WeakTerm.WeakTerm.Holes (holes) where

import Control.Comonad.Cofree
import Data.Maybe
import Data.Set qualified as S
import Language.Common.Annotation qualified as AN
import Language.Common.Attr.Lam qualified as AttrL
import Language.Common.Binder
import Language.Common.DecisionTree qualified as DT
import Language.Common.HoleID
import Language.Common.ImpArgs qualified as ImpArgs
import Language.WeakTerm.WeakTerm qualified as WT

holes :: WT.WeakTerm -> S.Set HoleID
holes term =
  case term of
    _ :< WT.Tau ->
      S.empty
    _ :< WT.Var {} ->
      S.empty
    _ :< WT.VarGlobal {} ->
      S.empty
    _ :< WT.Pi _ impArgs expArgs t -> do
      let impBinders = map fst impArgs
      holes' (impBinders ++ expArgs) (holes t)
    _ :< WT.PiIntro k impArgs expArgs e ->
      holes' (map fst impArgs ++ expArgs ++ catMaybes [AttrL.fromAttr k]) (holes e)
    _ :< WT.PiElim _ e impArgs expArgs ->
      S.unions $ map holes $ e : (ImpArgs.extract impArgs ++ expArgs)
    _ :< WT.PiElimExact e ->
      holes e
    _ :< WT.Data _ _ es ->
      S.unions $ map holes es
    _ :< WT.DataIntro _ _ dataArgs consArgs -> do
      S.unions $ map holes $ dataArgs ++ consArgs
    m :< WT.DataElim _ oets decisionTree -> do
      let (os, es, ts) = unzip3 oets
      let xs1 = S.unions $ map holes es
      let binder = zipWith (\o t -> (m, o, t)) os ts
      let xs2 = holes' binder (holesDecisionTree decisionTree)
      S.union xs1 xs2
    _ :< WT.Box t ->
      holes t
    _ :< WT.BoxNoema t ->
      holes t
    _ :< WT.BoxIntro letSeq e -> do
      let (xts, es) = unzip letSeq
      holes' xts (S.unions $ map holes $ e : es)
    _ :< WT.BoxIntroQuote e ->
      holes e
    _ :< WT.BoxElim castSeq mxt e1 uncastSeq e2 -> do
      let (xts, es) = unzip $ castSeq ++ [(mxt, e1)] ++ uncastSeq
      holes' xts (S.unions $ map holes $ es ++ [e2])
    _ :< WT.Actual e ->
      holes e
    _ :< WT.Let _ mxt e1 e2 -> do
      let set1 = holes e1
      let set2 = holes' [mxt] (holes e2)
      S.union set1 set2
    _ :< WT.Hole h es ->
      S.insert h $ S.unions $ map holes es
    _ :< WT.Prim prim ->
      foldMap holes prim
    _ :< WT.Magic der ->
      foldMap holes der
    _ :< WT.Annotation _ annot e -> do
      let xs1 = holes e
      case annot of
        AN.Type t -> do
          let xs2 = holes t
          S.union xs1 xs2
    _ :< WT.Resource _ _ unitType discarder copier typeTag -> do
      S.unions $ map holes [unitType, discarder, copier, typeTag]
    _ :< WT.Void ->
      S.empty

holes' :: [BinderF WT.WeakTerm] -> S.Set HoleID -> S.Set HoleID
holes' binder zs =
  case binder of
    [] ->
      zs
    ((_, _, t) : xts) -> do
      let set1 = holes t
      let set2 = holes' xts zs
      S.union set1 set2

holesDecisionTree :: DT.DecisionTree WT.WeakTerm -> S.Set HoleID
holesDecisionTree tree =
  case tree of
    DT.Leaf _ letSeq e -> do
      holes $ WT.fromLetSeq letSeq e
    DT.Unreachable ->
      S.empty
    DT.Switch (_, cursor) caseList ->
      S.union (holes cursor) (holesCaseList caseList)

holesCaseList :: DT.CaseList WT.WeakTerm -> S.Set HoleID
holesCaseList (fallbackClause, clauseList) = do
  let xs1 = holesDecisionTree fallbackClause
  let xs2 = S.unions $ map holesCase clauseList
  S.union xs1 xs2

holesCase :: DT.Case WT.WeakTerm -> S.Set HoleID
holesCase decisionCase = do
  case decisionCase of
    DT.LiteralCase _ _ cont -> do
      holesDecisionTree cont
    DT.ConsCase (DT.ConsCaseRecord {..}) -> do
      let (dataTerms, dataTypes) = unzip dataArgs
      S.unions $ holes' consArgs (holesDecisionTree cont) : map holes dataTerms ++ map holes dataTypes
