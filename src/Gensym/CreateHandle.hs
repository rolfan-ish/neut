module Gensym.CreateHandle (createHandle) where

import Data.IORef
import Gensym.Handle

createHandle :: IO Handle
createHandle = do
  _counterRef <- newIORef 0
  return $ InternalHandle {..}
