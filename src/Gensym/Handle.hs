module Gensym.Handle (Handle (..)) where

import Data.IORef

newtype Handle = InternalHandle
  { _counterRef :: IORef Int
  }
