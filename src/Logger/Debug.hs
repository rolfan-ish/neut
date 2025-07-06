module Logger.Debug (report) where

import Color.Print qualified as Color
import Color.Text qualified as Color
import Control.Monad (when)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Logger.Handle
import System.Console.ANSI

report :: Handle -> T.Text -> IO ()
report h message = do
  when (_enableDebugMode h) $ do
    currentTime <- getCurrentTime
    let elapsedTime = diffUTCTime currentTime (_baseTime h)
    let elapsedTime' = Color.pack [SetColor Foreground Vivid Black] (T.pack $ _formatNominalDiffTime elapsedTime)
    Color.printStdErr (_colorHandle h) $ elapsedTime' <> " " <> Color.pack' message <> "\n"
