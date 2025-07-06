module CodeParser.Parse
  ( runParser,
    spaceConsumer,
    lexeme,
    delimiter,
    string,
    symbol,
    symbol',
  )
where

import CodeParser.Parser
import Control.Monad
import Control.Monad.Error.Class (MonadError (throwError))
import Data.Set qualified as S
import Data.Text qualified as T
import Error.EIO (EIO)
import Path
import SyntaxTree.C
import Text.Megaparsec hiding (runParser)
import Text.Megaparsec.Char (char)
import Text.Megaparsec.Char.Lexer qualified as L

type MustParseWholeFile =
  Bool

runParser :: Path Abs File -> T.Text -> MustParseWholeFile -> Parser a -> EIO (C, a)
runParser filePath fileContent mustParseWholeFile parser = do
  let fileParser = do
        leadingComments <- spaceConsumer
        value <- parser
        when mustParseWholeFile eof
        return (leadingComments, value)
  let path = toFilePath filePath
  result <- runParserT fileParser path fileContent
  case result of
    Right v ->
      return v
    Left errorBundle ->
      throwError $ createParseError errorBundle

skipSpace :: Parser ()
skipSpace =
  L.space asciiSpaceOrNewLine1 empty empty

skipSpaceWithoutNewline :: Parser ()
skipSpaceWithoutNewline =
  void $ takeWhileP (Just "space") (== ' ')

comment :: CommentType -> Parser Comment
comment commentType = do
  chunk "//"
  text <- takeWhileP (Just "character") (/= '\n')
  return $ Comment commentType text

lineComment :: Parser Comment
lineComment = do
  skipSpace
  comment LineComment

{-# INLINE spaceConsumer #-}
spaceConsumer :: Parser C
spaceConsumer =
  hidden $ do
    skipSpaceWithoutNewline
    maybeInlineComment <- optional (comment InlineComment)
    skipSpace
    lineComments <- many (lineComment <* skipSpace)
    case maybeInlineComment of
      Nothing ->
        return lineComments
      Just ic ->
        return (ic : lineComments)

{-# INLINE asciiSpaceOrNewLine1 #-}
asciiSpaceOrNewLine1 :: Parser ()
asciiSpaceOrNewLine1 =
  void $ takeWhile1P (Just "space or newline") isAsciiSpaceOrNewLine

{-# INLINE isAsciiSpaceOrNewLine #-}
isAsciiSpaceOrNewLine :: Char -> Bool
isAsciiSpaceOrNewLine c =
  c == ' ' || c == '\n'

{-# INLINE lexeme #-}
lexeme :: Parser a -> Parser (a, C)
lexeme p = do
  v <- p
  c <- spaceConsumer
  return (v, c)

delimiter :: T.Text -> Parser C
delimiter expected = do
  fmap snd $ lexeme $ void $ chunk expected

symbol :: Parser (T.Text, C)
symbol = do
  lexeme $ takeWhile1P Nothing (`S.notMember` nonSymbolCharSet)

symbol' :: Parser (T.Text, C)
symbol' = do
  lexeme $ takeWhileP Nothing (`S.notMember` nonSymbolCharSet)

string :: Parser (T.Text, C)
string =
  lexeme $ do
    _ <- char '"'
    stringInner []

stringInner :: [Char] -> Parser T.Text
stringInner acc = do
  c <- anySingle
  case c of
    '\\' -> do
      c' <- anySingle
      stringInner (c' : '\\' : acc)
    '"' ->
      return $ T.pack $ Prelude.reverse acc
    _ ->
      stringInner (c : acc)
