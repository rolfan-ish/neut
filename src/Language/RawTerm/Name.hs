module Language.RawTerm.Name
  ( Name (..),
    showName,
    isConsName,
  )
where

import Data.Char
import Data.Text qualified as T
import Language.RawTerm.Locator qualified as L
import Language.RawTerm.RawIdent

data Name
  = Var RawIdent
  | Locator L.Locator
  deriving (Show)

showName :: Name -> T.Text
showName consName =
  case consName of
    Var value ->
      value
    Locator l ->
      L.reify l

isConsName :: T.Text -> Bool
isConsName name = do
  case T.uncons (T.dropWhile (== '_') name) of
    Just (c, _)
      | isUpper c ->
          True
    _ ->
      False
