module Kernel.Common.RuleHandle.Local.Locator
  ( Handle (..),
  )
where

import Data.HashMap.Strict qualified as Map
import Data.IORef
import Data.Text qualified as T
import Kernel.Common.Handle.Global.Env qualified as Env
import Kernel.Common.Handle.Local.Tag qualified as Tag
import Language.Common.DefiniteDescription qualified as DD
import Language.Common.LocalLocator qualified as LL
import Language.Common.StrictGlobalLocator qualified as SGL
import Path

-- the structure of a name of a global variable:
--
--     some.path.to.item.some-function
--     ----------------- -------------
--     ↑ global locator  ↑ local locator
--     ------------------------------------------------
--     ↑ the definite description of a global variable `some-function` (up-to module alias)

data Handle = Handle
  { _tagHandle :: Tag.Handle,
    _envHandle :: Env.Handle,
    _activeDefiniteDescriptionListRef :: IORef (Map.HashMap LL.LocalLocator DD.DefiniteDescription),
    _activeStaticFileListRef :: IORef (Map.HashMap T.Text (Path Abs File, T.Text)),
    _activeGlobalLocatorList :: [SGL.StrictGlobalLocator],
    _currentGlobalLocator :: SGL.StrictGlobalLocator
  }
