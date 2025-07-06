module Language.Common.Ident.Reify
  ( toText,
    toText',
    toInt,
  )
where

import Data.Text qualified as T
import Language.Common.Ident

toText :: Ident -> T.Text
toText (I (s, _)) =
  s

{-# INLINE toText' #-}
toText' :: Ident -> T.Text
toText' (I (s, i)) =
  s <> "-" <> T.pack (show i)

toInt :: Ident -> Int
toInt (I (_, i)) =
  i
