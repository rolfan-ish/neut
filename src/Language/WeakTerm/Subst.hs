module Language.WeakTerm.Subst
  ( Handle,
    new,
    subst,
    subst',
    substWithMaybeType',
    substDecisionTree,
  )
where

import Control.Comonad.Cofree
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.IntMap qualified as IntMap
import Data.Maybe (mapMaybe)
import Data.Set qualified as S
import Gensym.Gensym qualified as Gensym
import Gensym.Handle qualified as Gensym
import Language.Common.Annotation qualified as AN
import Language.Common.Attr.Lam qualified as AttrL
import Language.Common.Binder
import Language.Common.CreateSymbol qualified as Gensym
import Language.Common.DecisionTree qualified as DT
import Language.Common.Ident
import Language.Common.Ident.Reify qualified as Ident
import Language.Common.ImpArgs qualified as ImpArgs
import Language.Common.LamKind qualified as LK
import Language.WeakTerm.FreeVars qualified as WT
import Language.WeakTerm.WeakTerm qualified as WT

newtype Handle = Handle
  { gensymHandle :: Gensym.Handle
  }

new :: Gensym.Handle -> Handle
new gensymHandle = do
  Handle {..}

subst :: Handle -> WT.SubstWeakTerm -> WT.WeakTerm -> IO WT.WeakTerm
subst h sub term =
  case term of
    _ :< WT.Tau ->
      return term
    m :< WT.Var x
      | Just varOrTerm <- IntMap.lookup (Ident.toInt x) sub ->
          case varOrTerm of
            Left x' ->
              return $ m :< WT.Var x'
            Right e ->
              return e
      | otherwise ->
          return term
    _ :< WT.VarGlobal {} ->
      return term
    m :< WT.Pi piKind impArgs expArgs t -> do
      (impArgs', sub') <- substWithMaybeType h sub impArgs
      (expArgs', sub'') <- subst' h sub' expArgs
      t' <- subst h sub'' t
      return $ m :< WT.Pi piKind impArgs' expArgs' t'
    m :< WT.PiIntro (AttrL.Attr {lamKind}) impArgs expArgs e -> do
      let fvs = S.map Ident.toInt $ WT.freeVars term
      let subDomSet = S.fromList $ IntMap.keys sub
      if S.intersection fvs subDomSet == S.empty
        then return term
        else do
          newLamID <- liftIO $ Gensym.newCount (gensymHandle h)
          case lamKind of
            LK.Fix xt -> do
              (impArgs', sub') <- substWithMaybeType' h sub impArgs
              (expArgs', sub'') <- subst' h sub' expArgs
              ([xt'], sub''') <- subst' h sub'' [xt]
              e' <- subst h sub''' e
              let fixAttr = AttrL.Attr {lamKind = LK.Fix xt', identity = newLamID}
              return (m :< WT.PiIntro fixAttr impArgs' expArgs' e')
            LK.Normal mName codType -> do
              (impArgs', sub') <- substWithMaybeType' h sub impArgs
              (expArgs', sub'') <- subst' h sub' expArgs
              codType' <- subst h sub'' codType
              e' <- subst h sub'' e
              let lamAttr = AttrL.Attr {lamKind = LK.Normal mName codType', identity = newLamID}
              return (m :< WT.PiIntro lamAttr impArgs' expArgs' e')
    m :< WT.PiElim b e impArgs expArgs -> do
      e' <- subst h sub e
      impArgs' <- ImpArgs.traverseImpArgs (subst h sub) impArgs
      expArgs' <- mapM (subst h sub) expArgs
      return $ m :< WT.PiElim b e' impArgs' expArgs'
    m :< WT.PiElimExact e -> do
      e' <- subst h sub e
      return $ m :< WT.PiElimExact e'
    m :< WT.Data name consNameList es -> do
      es' <- mapM (subst h sub) es
      return $ m :< WT.Data name consNameList es'
    m :< WT.DataIntro attr consName dataArgs consArgs -> do
      dataArgs' <- mapM (subst h sub) dataArgs
      consArgs' <- mapM (subst h sub) consArgs
      return $ m :< WT.DataIntro attr consName dataArgs' consArgs'
    m :< WT.DataElim isNoetic oets decisionTree -> do
      let (os, es, ts) = unzip3 oets
      es' <- mapM (subst h sub) es
      let binder = zipWith (\o t -> (m, o, t)) os ts
      (binder', decisionTree') <- subst''' h sub binder decisionTree
      let (_, os', ts') = unzip3 binder'
      return $ m :< WT.DataElim isNoetic (zip3 os' es' ts') decisionTree'
    m :< WT.Box t -> do
      t' <- subst h sub t
      return $ m :< WT.Box t'
    m :< WT.BoxNoema t -> do
      t' <- subst h sub t
      return $ m :< WT.BoxNoema t'
    m :< WT.BoxIntro letSeq e -> do
      (letSeq', sub') <- substLetSeq h sub letSeq
      e' <- subst h sub' e
      return $ m :< WT.BoxIntro letSeq' e'
    m :< WT.BoxIntroQuote e -> do
      e' <- subst h sub e
      return $ m :< WT.BoxIntroQuote e'
    m :< WT.BoxElim castSeq mxt e1 uncastSeq e2 -> do
      (castSeq', sub1) <- substLetSeq h sub castSeq
      ((mxt', e1'), sub2) <- substLet h sub1 (mxt, e1)
      (uncastSeq', sub3) <- substLetSeq h sub2 uncastSeq
      e2' <- subst h sub3 e2
      return $ m :< WT.BoxElim castSeq' mxt' e1' uncastSeq' e2'
    m :< WT.Actual e -> do
      e' <- subst h sub e
      return $ m :< WT.Actual e'
    m :< WT.Let opacity mxt e1 e2 -> do
      e1' <- subst h sub e1
      (mxt', _, e2') <- subst'' h sub mxt [] e2
      return $ m :< WT.Let opacity mxt' e1' e2'
    m :< WT.Prim prim -> do
      prim' <- mapM (subst h sub) prim
      return $ m :< WT.Prim prim'
    m :< WT.Hole holeID args -> do
      args' <- mapM (subst h sub) args
      return $ m :< WT.Hole holeID args'
    m :< WT.Magic der -> do
      der' <- mapM (subst h sub) der
      return $ m :< WT.Magic der'
    m :< WT.Annotation logLevel annot e -> do
      e' <- subst h sub e
      case annot of
        AN.Type t -> do
          t' <- subst h sub t
          return $ m :< WT.Annotation logLevel (AN.Type t') e'
    m :< WT.Resource dd resourceID unitType discarder copier typeTag -> do
      unitType' <- subst h sub unitType
      discarder' <- subst h sub discarder
      copier' <- subst h sub copier
      typeTag' <- subst h sub typeTag
      return $ m :< WT.Resource dd resourceID unitType' discarder' copier' typeTag'
    _ :< WT.Void ->
      return term

substBinder ::
  Handle ->
  WT.SubstWeakTerm ->
  [BinderF WT.WeakTerm] ->
  WT.WeakTerm ->
  IO ([BinderF WT.WeakTerm], WT.WeakTerm)
substBinder h sub binder e =
  case binder of
    [] -> do
      e' <- subst h sub e
      return ([], e')
    ((m, x, t) : xts) -> do
      t' <- subst h sub t
      x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
      let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
      (xts', e') <- substBinder h sub' xts e
      return ((m, x', t') : xts', e')

subst' ::
  Handle ->
  WT.SubstWeakTerm ->
  [BinderF WT.WeakTerm] ->
  IO ([BinderF WT.WeakTerm], WT.SubstWeakTerm)
subst' h sub binder =
  case binder of
    [] -> do
      return ([], sub)
    ((m, x, t) : xts) -> do
      t' <- subst h sub t
      x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
      let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
      (xts', sub'') <- subst' h sub' xts
      return ((m, x', t') : xts', sub'')

substWithMaybeType' ::
  Handle ->
  WT.SubstWeakTerm ->
  [(BinderF WT.WeakTerm, Maybe WT.WeakTerm)] ->
  IO ([(BinderF WT.WeakTerm, Maybe WT.WeakTerm)], WT.SubstWeakTerm)
substWithMaybeType' h sub binderList =
  case binderList of
    [] -> do
      return ([], sub)
    (((m, x, t), maybeType) : xts) -> do
      t' <- subst h sub t
      maybeType' <- traverse (subst h sub) maybeType
      x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
      let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
      (xts', sub'') <- substWithMaybeType' h sub' xts
      return (((m, x', t'), maybeType') : xts', sub'')

subst'' ::
  Handle ->
  WT.SubstWeakTerm ->
  BinderF WT.WeakTerm ->
  [BinderF WT.WeakTerm] ->
  WT.WeakTerm ->
  IO (BinderF WT.WeakTerm, [BinderF WT.WeakTerm], WT.WeakTerm)
subst'' h sub (m, x, t) binder e = do
  t' <- subst h sub t
  x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
  let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
  (xts', e') <- substBinder h sub' binder e
  return ((m, x', t'), xts', e')

subst''' ::
  Handle ->
  WT.SubstWeakTerm ->
  [BinderF WT.WeakTerm] ->
  DT.DecisionTree WT.WeakTerm ->
  IO ([BinderF WT.WeakTerm], DT.DecisionTree WT.WeakTerm)
subst''' h sub binder decisionTree =
  case binder of
    [] -> do
      decisionTree' <- substDecisionTree h sub decisionTree
      return ([], decisionTree')
    ((m, x, t) : xts) -> do
      t' <- subst h sub t
      x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
      let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
      (xts', e') <- subst''' h sub' xts decisionTree
      return ((m, x', t') : xts', e')

substLet ::
  Handle ->
  WT.SubstWeakTerm ->
  (BinderF WT.WeakTerm, WT.WeakTerm) ->
  IO ((BinderF WT.WeakTerm, WT.WeakTerm), WT.SubstWeakTerm)
substLet h sub ((m, x, t), e) = do
  e' <- subst h sub e
  t' <- subst h sub t
  x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
  let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
  return (((m, x', t'), e'), sub')

substLetSeq ::
  Handle ->
  WT.SubstWeakTerm ->
  [(BinderF WT.WeakTerm, WT.WeakTerm)] ->
  IO ([(BinderF WT.WeakTerm, WT.WeakTerm)], WT.SubstWeakTerm)
substLetSeq h sub letSeq = do
  case letSeq of
    [] ->
      return ([], sub)
    letPair : rest -> do
      (letPair', sub') <- substLet h sub letPair
      (rest', sub'') <- substLetSeq h sub' rest
      return (letPair' : rest', sub'')

substDecisionTree ::
  Handle ->
  WT.SubstWeakTerm ->
  DT.DecisionTree WT.WeakTerm ->
  IO (DT.DecisionTree WT.WeakTerm)
substDecisionTree h sub tree =
  case tree of
    DT.Leaf xs letSeq e -> do
      let xs' = mapMaybe (substLeafVar sub) xs
      (letSeq', sub') <- substLetSeq h sub letSeq
      e' <- subst h sub' e
      return $ DT.Leaf xs' letSeq' e'
    DT.Unreachable ->
      return tree
    DT.Switch (cursorVar, cursor) caseList -> do
      let cursorVar' = substVar sub cursorVar
      cursor' <- subst h sub cursor
      caseList' <- substCaseList h sub caseList
      return $ DT.Switch (cursorVar', cursor') caseList'

substCaseList ::
  Handle ->
  WT.SubstWeakTerm ->
  DT.CaseList WT.WeakTerm ->
  IO (DT.CaseList WT.WeakTerm)
substCaseList h sub (fallbackClause, clauseList) = do
  fallbackClause' <- substDecisionTree h sub fallbackClause
  clauseList' <- mapM (substCase h sub) clauseList
  return (fallbackClause', clauseList')

substCase ::
  Handle ->
  WT.SubstWeakTerm ->
  DT.Case WT.WeakTerm ->
  IO (DT.Case WT.WeakTerm)
substCase h sub decisionCase = do
  case decisionCase of
    DT.LiteralCase mPat i cont -> do
      cont' <- substDecisionTree h sub cont
      return $ DT.LiteralCase mPat i cont'
    DT.ConsCase record@(DT.ConsCaseRecord {..}) -> do
      let (dataTerms, dataTypes) = unzip dataArgs
      dataTerms' <- mapM (subst h sub) dataTerms
      dataTypes' <- mapM (subst h sub) dataTypes
      (consArgs', cont') <- subst''' h sub consArgs cont
      return $
        DT.ConsCase
          record
            { DT.dataArgs = zip dataTerms' dataTypes',
              DT.consArgs = consArgs',
              DT.cont = cont'
            }

substLeafVar :: WT.SubstWeakTerm -> Ident -> Maybe Ident
substLeafVar sub leafVar =
  case IntMap.lookup (Ident.toInt leafVar) sub of
    Just (Left leafVar') ->
      return leafVar'
    Just (Right _) ->
      Nothing
    Nothing ->
      return leafVar

substWithMaybeType ::
  Handle ->
  WT.SubstWeakTerm ->
  [(BinderF WT.WeakTerm, Maybe WT.WeakTerm)] ->
  IO ([(BinderF WT.WeakTerm, Maybe WT.WeakTerm)], WT.SubstWeakTerm)
substWithMaybeType h sub binderList =
  case binderList of
    [] -> do
      return ([], sub)
    (((m, x, t), maybeType) : rest) -> do
      t' <- subst h sub t
      maybeType' <- traverse (subst h sub) maybeType
      x' <- liftIO $ Gensym.newIdentFromIdent (gensymHandle h) x
      let sub' = IntMap.insert (Ident.toInt x) (Left x') sub
      (rest', sub'') <- substWithMaybeType h sub' rest
      return (((m, x', t'), maybeType') : rest', sub'')

substVar :: WT.SubstWeakTerm -> Ident -> Ident
substVar sub x =
  case IntMap.lookup (Ident.toInt x) sub of
    Just (Left x') ->
      x'
    _ ->
      x
