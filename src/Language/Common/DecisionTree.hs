module Language.Common.DecisionTree
  ( DecisionTree (..),
    CaseList,
    ConsCaseRecord (..),
    Case (..),
    getConstructors,
    isUnreachable,
    findCase,
    getCont,
  )
where

import Data.Binary
import Data.Maybe (catMaybes)
import GHC.Generics (Generic)
import Language.Common.Binder
import Language.Common.DefiniteDescription qualified as DD
import Language.Common.Discriminant qualified as D
import Language.Common.Ident
import Language.Common.IsConstLike
import Language.Common.Literal qualified as L
import Logger.Hint

data DecisionTree a
  = Leaf [Ident] [(BinderF a, a)] a
  | Unreachable
  | Switch (Ident, a) (CaseList a)
  deriving (Show, Generic)

type CaseList a = (DecisionTree a, [Case a])

data ConsCaseRecord a = ConsCaseRecord
  { mCons :: Hint,
    consDD :: DD.DefiniteDescription,
    isConstLike :: IsConstLike,
    disc :: D.Discriminant,
    dataArgs :: [(a, a)],
    consArgs :: [BinderF a],
    cont :: DecisionTree a
  }
  deriving (Show, Generic)

data Case a
  = ConsCase (ConsCaseRecord a)
  | LiteralCase Hint L.Literal (DecisionTree a)
  deriving (Show, Generic)

instance (Binary a) => Binary (ConsCaseRecord a)

instance (Binary a) => Binary (DecisionTree a)

instance (Binary a) => Binary (Case a)

getConstructors :: [Case a] -> [(DD.DefiniteDescription, IsConstLike)]
getConstructors clauseList = do
  catMaybes $ flip map clauseList $ \c -> do
    case c of
      ConsCase (ConsCaseRecord {..}) ->
        Just (consDD, isConstLike)
      LiteralCase {} ->
        Nothing

isUnreachable :: DecisionTree a -> Bool
isUnreachable tree =
  case tree of
    Unreachable ->
      True
    _ ->
      False

findCase :: D.Discriminant -> Case a -> Maybe ([(Ident, a)], DecisionTree a)
findCase consDisc decisionCase =
  case decisionCase of
    LiteralCase {} ->
      Nothing
    ConsCase (ConsCaseRecord {..}) -> do
      if consDisc == disc
        then return (map (\(_, x, t) -> (x, t)) consArgs, cont)
        else Nothing

getCont :: Case a -> DecisionTree a
getCont c =
  case c of
    ConsCase (ConsCaseRecord {..}) ->
      cont
    LiteralCase _ _ cont ->
      cont
