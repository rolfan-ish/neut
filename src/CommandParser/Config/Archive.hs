module CommandParser.Config.Archive (Config (..)) where

import Data.Text qualified as T

newtype Config = Config
  { getArchiveName :: Maybe T.Text
  }
