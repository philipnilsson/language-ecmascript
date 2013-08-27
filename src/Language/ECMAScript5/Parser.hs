{-# LANGUAGE Rank2Types, ImpredicativeTypes #-}

module Language.ECMAScript5.Parser (parse
                                   , PosParser
                                   , Parser
                                   , ParseError
                                   , SourcePos
                                   , SourceSpan
                                   , Positioned
                                   , expression
                                   , statement
                                   , program
                                   , parseFromString
                                   , parseFromFile
                                   ) where


import System.IO.Unsafe
import Data.Monoid (mempty)

import Language.ECMAScript5.Syntax
import Language.ECMAScript5.Syntax.Annotations
import Language.ECMAScript5.Parser.Util
import Language.ECMAScript5.Parser.Unicode
import Data.Default.Class
import Data.Default.Instances.Base
import Text.Parsec hiding (parse, spaces)
import Text.Parsec.Char (char, string, satisfy, oneOf, noneOf, hexDigit, anyChar)
import Text.Parsec.Char as ParsecChar hiding (spaces)
import Text.Parsec.Combinator
import Text.Parsec.Prim hiding (parse)
import Text.Parsec.Pos
import Text.Parsec.Expr

import Control.Monad(liftM,liftM2)
import Control.Monad.Trans (MonadIO,liftIO)
import Control.Monad.Error.Class

import Numeric(readDec,readOct,readHex)
import Data.Char
import Control.Monad.Identity
import Data.Maybe (isJust, isNothing, fromMaybe, maybeToList)
import Control.Applicative ((<$>), (<*), (*>), (<*>), (<$))
import Control.Arrow

type Parser a = forall s. Stream s Identity Char => ParsecT s ParserState Identity a

-- the statement label stack
type ParserState = (Bool, [String])

data SourceSpan = SourceSpan (SourcePos, SourcePos)
type Positioned x = x SourceSpan
type PosParser x = Parser (Positioned x)

instance Default SourcePos where
  def = initialPos ""

instance Default SourceSpan where
  def = SourceSpan def

instance Show SourceSpan where
  show (SourceSpan (p1,p2)) = let
    l1 = show $ sourceLine p1
    c1 = show $ sourceColumn p1
    l2 = show $ sourceLine p2
    c2 = show $ sourceColumn p2
    s1 = l1 ++ "-" ++ c1
    s2 = l2 ++ "-" ++ c2
    in "(" ++ show (s1 ++ "/" ++ s2) ++ ")"

-- for parsers that have with/without in-clause variations
type InParser a =  forall s. Stream s Identity Char
                 => ParsecT s (Bool, ParserState) Identity a
type PosInParser x = InParser (Positioned x)
liftIn :: Parser a -> InParser a
liftIn p = changeState (\s -> (True, s)) snd p

withIn, withNoIn :: InParser a -> Parser a
withIn   p = changeState snd (\s -> (True, s)) p
withNoIn p = changeState snd (\s -> (False, s)) p

changeState
  :: forall m s u v a . (Functor m, Monad m)
  => (u -> v)
  -> (v -> u)
  -> ParsecT s u m a
  -> ParsecT s v m a
changeState forward backward = mkPT . transform . runParsecT
  where
    mapState f st = st { stateUser = f (stateUser st) }
    mapReply f (Ok a st err) = Ok a (mapState f st) err
    mapReply _ (Error e) = Error e
    transform p st = (fmap . fmap . fmap) (mapReply forward) (p (mapState backward st))

initialParserState :: ParserState
initialParserState = (False, [])

-- | checks if the label is not yet on the stack, if it is -- throws
-- an error; otherwise it pushes it onto the stack
pushLabel :: String -> Parser ()
pushLabel lab = do (nl, labs) <- getState
                   pos <- getPosition
                   if lab `elem` labs
                     then fail $ "Duplicate label at " ++ show pos
                     else putState (nl, lab:labs)

popLabel :: Parser ()
popLabel = modifyState (second safeTail)
  where safeTail [] = []
        safeTail (_:xs) = xs

clearLabels :: ParserState -> ParserState
clearLabels = second (const [])

withFreshLabelStack :: Parser a -> Parser a
withFreshLabelStack p = do oldState <- getState
                           putState $ clearLabels oldState
                           a <- p
                           putState oldState
                           return a

-- was newline consumed? keep as parser state set in 'ws' parser

setNewLineState :: [Bool] -> Parser Bool
setNewLineState wsConsumed =
  let consumedNewLine = any id wsConsumed in do
    modifyState (first $ const $ consumedNewLine)
    return consumedNewLine

hadNewLine :: Parser ()
hadNewLine = fst <$> getState >>= guard

hadNoNewLine :: Parser()
hadNoNewLine = fst <$> getState >>= guard.not

-- a convenience wrapper to take care of the position, "with position"
withPos   :: (HasAnnotation x, Stream s Identity Char) => ParsecT s u Identity (Positioned x) -> ParsecT s u Identity (Positioned x)
withPos p = do start <- getPosition
               result <- p
               end <- getPosition
               return $ setAnnotation (SourceSpan (start, end)) result

-- Below "x.y.z" are references to ECMAScript 5 spec chapters that discuss the corresponding grammar production
--7.2

lexeme :: Show a => Parser a -> Parser a
lexeme p = p <* ws

ws :: Parser Bool
ws = many (False <$ whiteSpace <|> False <$ comment <|> True <$ lineTerminator) >>= setNewLineState
  where whiteSpace :: Parser ()
        whiteSpace = forget $ choice [uTAB, uVT, uFF, uSP, uNBSP, uBOM, uUSP]

--7.3
uCRalone :: Parser Char
uCRalone = do uCR <* notFollowedBy uLF

lineTerminator :: Parser ()
lineTerminator = forget (uLF <|> uCR <|> uLS <|> uPS)
lineTerminatorSequence  :: Parser ()
lineTerminatorSequence = forget (uLF <|> uCRalone <|> uLS <|> uPS ) <|> forget uCRLF

--7.4
comment :: Parser String
comment = try multiLineComment <|> try singleLineComment

singleLineCommentChar :: Parser Char
singleLineCommentChar  = notFollowedBy lineTerminator *> noneOf ""

multiLineComment :: Parser String
multiLineComment = string "/*" *> (concat <$> many insideMultiLineComment) <* string "*/"

singleLineComment :: Parser String
singleLineComment = string "//" >> many singleLineCommentChar

insideMultiLineComment :: Parser [Char]
insideMultiLineComment = noAsterisk <|> try asteriskInComment
 where
  noAsterisk =
    stringify $ noneOf "*"
  asteriskInComment =
    (:) <$> char '*' <*> (stringify (noneOf "/*") <|> "" <$ lookAhead (char '*') )

--7.5
--token = identifierName <|> punctuator <|> numericLiteral <|> stringLiteral

--7.6
identifier :: PosParser Expression
identifier = withPos $ do name <- identifierName
                          return $ VarRef def name

identifierName :: PosParser Id
identifierName = lexeme $ withPos $ flip butNot reservedWord $ fmap (Id def) $
                 (:)
                 <$> identifierStart
                 <*> many identifierPart
identifierStart :: Parser Char
identifierStart = unicodeLetter <|> char '$' <|> char '_' <|> unicodeEscape

unicodeEscape :: Parser Char
unicodeEscape = char '\\' >> unicodeEscapeSequence

identifierPart :: Parser Char
identifierPart = identifierStart <|> unicodeCombiningMark <|> unicodeDigit <|>
                 unicodeConnectorPunctuation <|> uZWNJ <|> uZWJ

--7.6.1
reservedWord :: Parser ()
reservedWord = choice [forget keyword, forget futureReservedWord, forget nullLiteral, forget booleanLiteral]

andThenNot :: Show q => Parser a -> Parser q -> Parser a
andThenNot p q = try (p <* notFollowedBy q)

makeKeyword :: String -> Parser Bool
makeKeyword word = try (string word `andThenNot` identifierPart) *> ws

--7.6.1.1
keyword :: Parser Bool
keyword = choice [kbreak, kcase, kcatch, kcontinue, kdebugger, kdefault, kdelete,
                  kdo, kelse, kfinally, kfor, kfunction, kif, kin, kinstanceof, knew,
                  kreturn, kswitch, kthis, kthrow, ktry, ktypeof, kvar, kvoid, kwhile, kwith]

-- ECMAScript keywords
kbreak, kcase, kcatch, kcontinue, kdebugger, kdefault, kdelete,
  kdo, kelse, kfinally, kfor, kfunction, kif, kin, kinstanceof, knew,
  kreturn, kswitch, kthis, kthrow, ktry, ktypeof, kvar, kvoid, kwhile, kwith
  :: Parser Bool
kbreak      = makeKeyword "break"
kcase       = makeKeyword "case"
kcatch      = makeKeyword "catch"
kcontinue   = makeKeyword "continue"
kdebugger   = makeKeyword "debugger"
kdefault    = makeKeyword "default"
kdelete     = makeKeyword "delete"
kdo         = makeKeyword "do"
kelse       = makeKeyword "else"
kfinally    = makeKeyword "finally"
kfor        = makeKeyword "for"
kfunction   = makeKeyword "function"
kif         = makeKeyword "if"
kin         = makeKeyword "in"
kinstanceof = makeKeyword "instanceof"
knew        = makeKeyword "new"
kreturn     = makeKeyword "return"
kswitch     = makeKeyword "switch"
kthis       = makeKeyword "this"
kthrow      = makeKeyword "throw"
ktry        = makeKeyword "try"
ktypeof     = makeKeyword "typeof"
kvar        = makeKeyword "var"
kvoid       = makeKeyword "void"
kwhile      = makeKeyword "while"
kwith       = makeKeyword "with"

--7.6.1.2
futureReservedWord :: Parser Bool
futureReservedWord = choice [kclass, kconst, kenum, kexport, kextends, kimport, ksuper]

kclass, kconst, kenum, kexport, kextends, kimport, ksuper :: Parser Bool
kclass   = makeKeyword "class"
kconst   = makeKeyword "const"
kenum    = makeKeyword "enum"
kexport  = makeKeyword "export"
kextends = makeKeyword "extends"
kimport  = makeKeyword "import"
ksuper   = makeKeyword "super"

--7.7
punctuator :: Parser ()
punctuator = choice [ passignadd, passignsub, passignmul, passignmod,
                      passignshl, passignshr,
                      passignushr, passignband, passignbor, passignbxor,
                      pshl, pshr, pushr,
                      pleqt, pgeqt,
                      plbrace, prbrace, plparen, prparen, plbracket,
                      prbracket, pdot, psemi, pcomma,
                      plangle, prangle, pseq, peq, psneq, pneq,
                      pplusplus, pminusminus,
                      pplus, pminus, pmul,
                      pand, por,
                      pmod, pband, pbor, pbxor, pnot, pbnot,
                      pquestion, pcolon, passign ]
plbrace :: Parser ()
plbrace = forget $ lexeme $ char '{'
prbrace :: Parser ()
prbrace = forget $ lexeme $ char '}'
plparen :: Parser ()
plparen = forget $ lexeme $ char '('
prparen :: Parser ()
prparen = forget $ lexeme $ char ')'
plbracket :: Parser ()
plbracket = forget $ lexeme $ char '['
prbracket :: Parser ()
prbracket = forget $ lexeme $ char ']'
pdot :: Parser ()
pdot = forget $ lexeme $ char '.'
psemi :: Parser ()
psemi = forget $ lexeme $ char ';'
pcomma :: Parser ()
pcomma = forget $ lexeme $ char ','
plangle :: Parser ()
plangle = lexeme $ char '<' *> notFollowedBy (oneOf "=<")
prangle :: Parser ()
prangle = lexeme $ char '>' *> notFollowedBy (oneOf "=>")
pleqt :: Parser ()
pleqt = forget $ lexeme $ string "<="
pgeqt :: Parser ()
pgeqt = forget $ lexeme $ string ">="
peq :: Parser ()
peq  = forget $ lexeme $ string "==" *> notFollowedBy (char '=')
pneq :: Parser ()
pneq = forget $ lexeme $ string "!=" *> notFollowedBy (char '=')
pseq :: Parser ()
pseq = forget $ lexeme $ string "==="
psneq :: Parser ()
psneq = forget $ lexeme $ string "!=="
pplus :: Parser ()
pplus = forget $ lexeme $ do char '+' *> notFollowedBy (oneOf "=+")
pminus :: Parser ()
pminus = forget $ lexeme $ do char '-' *> notFollowedBy (oneOf "=-")
pmul :: Parser ()
pmul = forget $ lexeme $ do char '*' *> notFollowedBy (char '=')
pmod :: Parser ()
pmod = forget $ lexeme $ do char '%' *> notFollowedBy (char '=')
pplusplus :: Parser ()
pplusplus = forget $ lexeme $ string "++"
pminusminus :: Parser ()
pminusminus = forget $ lexeme $ string "--"
pshl :: Parser ()
pshl = forget $ lexeme $ string "<<" *> notFollowedBy (char '=')
pshr :: Parser ()
pshr = forget $ lexeme $ string ">>" *> notFollowedBy (oneOf ">=")
pushr :: Parser ()
pushr = forget $ lexeme $ string ">>>" *> notFollowedBy (char '=')
pband :: Parser ()
pband = forget $ lexeme $ do char '&' *> notFollowedBy (oneOf "&=")
pbor :: Parser ()
pbor = forget $ lexeme $ do char '|' *> notFollowedBy (oneOf "|=")
pbxor :: Parser ()
pbxor = forget $ lexeme $ do char '^' *> notFollowedBy (char '=')
pnot :: Parser ()
pnot = forget $ lexeme $ do char '!' *> notFollowedBy (char '=')
pbnot :: Parser ()
pbnot = forget $ lexeme $ char '~'
pand :: Parser ()
pand = forget $ lexeme $ string "&&"
por :: Parser ()
por = forget $ lexeme $ string "||"
pquestion :: Parser ()
pquestion = forget $ lexeme $ char '?'
pcolon :: Parser ()
pcolon = forget $ lexeme $ char ':'
passign :: Parser ()
passign = lexeme $ char '=' *> notFollowedBy (char '=')
passignadd :: Parser ()
passignadd = forget $ lexeme $ string "+="
passignsub :: Parser ()
passignsub = forget $ lexeme $ string "-="
passignmul :: Parser ()
passignmul = forget $ lexeme $ string "*="
passignmod :: Parser ()
passignmod = forget $ lexeme $ string "%="
passignshl :: Parser ()
passignshl = forget $ lexeme $ string "<<="
passignshr :: Parser ()
passignshr = forget $ lexeme $ string ">>="
passignushr :: Parser ()
passignushr = forget $ lexeme $ string ">>>="
passignband :: Parser ()
passignband = forget $ lexeme $ string "&="
passignbor :: Parser ()
passignbor = forget $ lexeme $ string "|="
passignbxor :: Parser ()
passignbxor = forget $ lexeme $ string "^="
divPunctuator :: Parser ()
divPunctuator = choice [ passigndiv, pdiv ]

passigndiv :: Parser ()
passigndiv = forget $ lexeme $ string "/="
pdiv :: Parser ()
pdiv = forget $ lexeme $ do char '/' *> notFollowedBy (char '=')

--7.8
literal :: PosParser Expression
literal = choice [nullLiteral, booleanLiteral, numericLiteral, stringLiteral, regularExpressionLiteral]

--7.8.1
nullLiteral :: PosParser Expression
nullLiteral = withPos (makeKeyword "null" >> return (NullLit def))

--7.8.2
booleanLiteral :: PosParser Expression
booleanLiteral = withPos $ BoolLit def
                 <$> (True <$ makeKeyword "true" <|> False <$ makeKeyword "false")

--7.8.3
numericLiteral :: PosParser Expression
numericLiteral = hexIntegerLiteral <|> decimalLiteral

-- Creates a decimal value from a whole, fractional and exponent parts.
mkDecimal :: Integer -> Integer -> Integer -> Integer -> Double
mkDecimal whole frac fracLen exp =
  ((fromInteger whole) + ((fromInteger frac) * (10 ^^ (-fracLen)))) * (10 ^^ exp)

-- Creates an integer value from a whole and exponent parts.
mkInteger :: Integer -> Integer -> Int
mkInteger whole exp = fromInteger $ whole * (10 ^ exp)

decimalLiteral :: PosParser Expression
decimalLiteral = lexeme $ withPos $
  (do whole <- decimalInteger
      mfraclen <- optionMaybe (pdot >> decimalDigitsWithLength)
      mexp  <- optionMaybe exponentPart
      if (mfraclen == Nothing && mexp == Nothing)
        then return $ NumLit def $ Left $ fromInteger whole
        else let (frac, flen) = fromMaybe (0, 0) mfraclen
                 exp          = fromMaybe 0 mexp
             in  return $ NumLit def $ Right $ mkDecimal whole frac flen exp)
  <|>
  (do (frac, flen) <- pdot >> decimalDigitsWithLength
      exp <- option 0 exponentPart
      return $ NumLit def $ Right $ mkDecimal 0 frac flen exp)

decimalDigitsWithLength :: Parser (Integer, Integer)
decimalDigitsWithLength = do digits <- many decimalDigit
                             return $ digits2NumberAndLength digits

digits2NumberAndLength :: [Integer] -> (Integer, Integer)
digits2NumberAndLength is =
  let (_, n, l) = foldr (\d (pow, acc, len) -> (pow*10, acc + d*pow, len+1))
                        (1, 0, 0) is
  in (n, l)

decimalIntegerLiteral :: PosParser Expression
decimalIntegerLiteral = lexeme $ withPos $ decimalInteger >>=
                        \i -> return $ NumLit def $ Left $ fromInteger i

decimalInteger :: Parser Integer
decimalInteger = (char '0' >> return 0)
              <|>(do d  <- nonZeroDecimalDigit
                     ds <- many decimalDigit
                     return $ fst $ digits2NumberAndLength (d:ds))

-- the spec says that decimalDigits should be intead of decimalIntegerLiteral, but that seems like an error
signedInteger :: Parser Integer
signedInteger = (char '+' >> decimalInteger) <|>
                (char '-' >> negate <$> decimalInteger) <|>
                decimalInteger

decimalDigit :: Parser Integer
decimalDigit  = do c <- decimalDigitChar
                   return $ toInteger $ ord c - ord '0'

decimalDigitChar :: Parser Char
decimalDigitChar = rangeChar '0' '9'

nonZeroDecimalDigit :: Parser Integer
nonZeroDecimalDigit  = do c <- rangeChar '1' '9'
                          return $ toInteger $ ord c - ord '0'

--hexDigit = ParsecChar.hexDigit

exponentPart :: Parser Integer
exponentPart = (char 'e' <|> char 'E') >> signedInteger


fromHex digits = do [(hex,"")] <- return $ Numeric.readHex digits
                    return hex

fromDecimal digits = do [(hex,"")] <- return $ Numeric.readDec digits
                        return hex
hexIntegerLiteral :: PosParser Expression
hexIntegerLiteral = lexeme $ withPos $ do
  try (char '0' >> (char 'x' <|> char 'X'))
  digits <- many1 hexDigit
  n <- fromHex digits
  return $ NumLit def $ Left $ fromInteger n

--7.8.4
dblquote :: Parser Char
dblquote = char '"'
quote :: Parser Char
quote = char '\''
backslash :: Parser Char
backslash = char '\\'
inDblQuotes :: Parser a -> Parser a
inDblQuotes x = between dblquote dblquote x
inQuotes :: Parser a -> Parser a
inQuotes x = between quote quote x
inParens :: Parser a -> Parser a
inParens x = between plparen prparen x
inBrackets :: Parser a -> Parser a
inBrackets x = between plbracket prbracket x
inBraces :: Parser a -> Parser a
inBraces x = between plbrace prbrace x

stringLiteral :: PosParser (Expression)
stringLiteral =  lexeme $ withPos $
                 do s <- ((inDblQuotes $ concatM $ many doubleStringCharacter)
                          <|>
                          (inQuotes $ concatM $ many singleStringCharacter))
                    return $ StringLit def s

doubleStringCharacter :: Parser String
doubleStringCharacter =
  stringify ((anyChar `butNot` choice[forget dblquote, forget backslash, lineTerminator])
             <|> backslash *> escapeSequence)
  <|> lineContinuation

singleStringCharacter :: Parser String
singleStringCharacter =
  stringify ((anyChar `butNot` choice[forget quote, forget backslash, forget lineTerminator])
             <|> backslash *> escapeSequence)
  <|> lineContinuation

lineContinuation :: Parser String
lineContinuation = backslash >> lineTerminatorSequence >> return ""

escapeSequence :: Parser Char
escapeSequence = characterEscapeSequence
              <|>(char '0' >> notFollowedBy decimalDigitChar >> return cNUL)
              <|>hexEscapeSequence
              <|>unicodeEscapeSequence

characterEscapeSequence :: Parser Char
characterEscapeSequence = singleEscapeCharacter <|> nonEscapeCharacter

singleEscapeCharacter :: Parser Char
singleEscapeCharacter = choice $ map (\(ch, cod) -> (char ch >> return cod))
                        [('b', cBS), ('t', cHT), ('n', cLF), ('v', cVT),
                         ('f', cFF), ('r', cCR), ('"', '"'), ('\'', '\''),
                         ('\\', '\\')]

nonEscapeCharacter :: Parser Char
nonEscapeCharacter = anyChar `butNot` (forget escapeCharacter <|> lineTerminator)

escapeCharacter :: Parser Char
escapeCharacter = singleEscapeCharacter
               <|>decimalDigitChar
               <|>char 'x'
               <|>char 'u'

hexEscapeSequence :: Parser Char
hexEscapeSequence =  do digits <- (char 'x' >> count 2 hexDigit)
                        hex <- fromHex digits
                        return $ chr hex

unicodeEscapeSequence :: Parser Char
unicodeEscapeSequence = do digits <- char 'u' >> count 4 hexDigit
                           hex <- fromHex digits
                           return $ chr hex

--7.8.5 and 15.10.4.1
regularExpressionLiteral :: PosParser Expression
regularExpressionLiteral =
    lexeme $ withPos $ do
      body <- between pdiv pdiv regularExpressionBody
      (g, i, m) <- regularExpressionFlags
      return $ RegexpLit def body g i m

-- TODO: The spec requires the parser to make sure the body is a valid
-- regular expression; were are not doing it at present.
regularExpressionBody :: Parser String
regularExpressionBody = do c <- regularExpressionFirstChar
                           cs <- concatM regularExpressionChars
                           return (c++cs)

regularExpressionChars :: Parser [String]
regularExpressionChars = many regularExpressionChar

regularExpressionFirstChar :: Parser String
regularExpressionFirstChar =
  choice [
    stringify $ regularExpressionNonTerminator `butNot` oneOf ['*', '\\', '/', '[' ],
    regularExpressionBackslashSequence,
    regularExpressionClass ]

regularExpressionChar :: Parser String
regularExpressionChar =
  choice [
    stringify $ regularExpressionNonTerminator `butNot` oneOf ['\\', '/', '[' ],
    regularExpressionBackslashSequence,
    regularExpressionClass ]

regularExpressionBackslashSequence :: Parser String
regularExpressionBackslashSequence = do c <-char '\\'
                                        e <- regularExpressionNonTerminator
                                        return (c:[e])

regularExpressionNonTerminator :: Parser Char
regularExpressionNonTerminator = anyChar `butNot` lineTerminator

regularExpressionClass :: Parser String
regularExpressionClass = do l <- char '['
                            rc <- concatM $ many regularExpressionClassChar
                            r <- char ']'
                            return (l:(rc++[r]))

regularExpressionClassChar :: Parser String
regularExpressionClassChar =
  stringify (regularExpressionNonTerminator `butNot` oneOf [']', '\\'])
  <|> regularExpressionBackslashSequence

regularExpressionFlags :: Parser (Bool, Bool, Bool) -- g, i, m
regularExpressionFlags = regularExpressionFlags' (False, False, False)

regularExpressionFlags' :: (Bool, Bool, Bool) -> Parser (Bool, Bool, Bool)
regularExpressionFlags' (g, i, m) =
    (char 'g' >> (if not g then regularExpressionFlags' (True, i, m) else unexpected "duplicate 'g' in regular expression flags")) <|>
    (char 'i' >> (if not i then regularExpressionFlags' (g, True, m) else unexpected "duplicate 'i' in regular expression flags")) <|>
    (char 'm' >> (if not m then regularExpressionFlags' (g, i, True) else unexpected "duplicate 'm' in regular expression flags")) <|>
    return (g, i, m)

-- | 7.9 || TODO: write tests based on examples from Spec 7.9.2, once I
-- get the parser finished! Automatic Semicolon Insertion algorithm,
-- rule 1; to be used in place of `semi` in parsers for
-- emptyStatement, variableStatement, expressionStatement,
-- doWhileStatement, continuteStatement, breakStatement,
-- returnStatement and throwStatement.
autoSemi :: Parser ()
autoSemi = psemi <|> hadNewLine <|> lookAhead prbrace <|> eof

-- 11.1
-- primary expressions
primaryExpression :: PosParser Expression
primaryExpression = choice [ withPos $ ThisRef def <$ kthis
                           , identifier
                           , literal
                           , arrayLiteral
                           , objectLiteral
                           , parenExpression]

parenExpression :: PosParser Expression
parenExpression = withPos $ inParens expression

-- 11.1.4
arrayLiteral :: PosParser Expression
arrayLiteral = withPos $
               ArrayLit def
               <$> inBrackets elementsListWithElision

elementsListWithElision :: Parser [Maybe (Positioned Expression)]
elementsListWithElision = optionMaybe assignmentExpression `sepBy` pcomma

-- 11.1.5
objectLiteral :: PosParser Expression
objectLiteral = withPos $
                ObjectLit def
                <$> inBraces (
                  propertyAssignment `sepBy` pcomma <* optional pcomma)


propertyAssignment :: Parser (Positioned PropAssign)
propertyAssignment = withPos $
                     (do try (makeKeyword "get" <* notFollowedBy pcolon)
                         pname <- propertyName
                         prparen
                         plparen
                         body <- inBraces functionBody
                         return $ PGet def pname body)
                  <|>(do try (makeKeyword "set" <* notFollowedBy pcolon)
                         pname <- propertyName
                         param <- inParens identifierName
                         body <- inBraces functionBody
                         return $ PSet def pname param body)
                  <|>(do pname <- propertyName
                         pcolon
                         e <- assignmentExpression
                         return $ PExpr def pname e)

propertyName :: Parser (Positioned Prop)
propertyName = withPos $
               (identifierName >>= id2Prop)
            <|>(stringLiteral >>= string2Prop)
            <|>(numericLiteral >>= num2Prop)
  where id2Prop (Id a s) = return $ PropId a s
        string2Prop (StringLit a s) = return $ PropString a s
        num2Prop (NumLit a i) = return $ PropNum a i

bracketed, dotref, called :: Parser (Positioned Expression -> Positioned Expression)
bracketed = flip (BracketRef def) <$> inBrackets expression
dotref    = flip (DotRef def)     <$  pdot <*> identifierName
called    = flip (CallExpr def)   <$> arguments

newExpression :: PosParser Expression
newExpression =
  withPostfix [bracketed, dotref] $
    NewExpr def <$ knew <*> newExpression <*> option [] arguments
    <|> primaryExpression
    <|> functionExpression

-- 11.2

arguments :: Parser [Positioned Expression]
arguments = inParens $ assignmentExpression `sepBy` pcomma

leftHandSideExpression :: PosParser Expression
leftHandSideExpression = withPostfix [bracketed, dotref, called] newExpression

functionExpression :: PosParser Expression
functionExpression = withPos $
  FuncExpr def
  <$  kfunction
  <*> optionMaybe identifierName
  <*> inParens formalParameterList
  <*> inBraces functionBody

type InOp s = Operator s (Bool, ParserState) Identity (Positioned Expression)

mkOp :: Show a => Parser a -> InParser a
mkOp p = liftIn $ try $ p

makeInfixExpr :: Stream s Identity Char => Parser () -> InfixOp -> InOp s
makeInfixExpr str constr = 
  Infix (InfixExpr def constr <$ mkOp str) AssocLeft 
      
makeAssignExpr :: Stream s Identity Char => Parser () -> AssignOp -> InOp s
makeAssignExpr str constr = 
  Infix (AssignExpr def constr <$ mkOp str) AssocLeft 

makePostfixExpr :: Stream s Identity Char => Parser () -> UnaryAssignOp -> InOp s
makePostfixExpr str constr =
  Postfix $ UnaryAssignExpr def constr <$ (liftIn hadNoNewLine >> mkOp str)

makePrefixExpr :: Stream s Identity Char => Parser () -> UnaryAssignOp -> InOp s
makePrefixExpr str constr =
  Prefix $ UnaryAssignExpr def constr <$ mkOp str

makeUnaryExpr pfxs =
  let mkPrefix :: (Parser (), PrefixOp) -> InParser (Positioned Expression -> Positioned Expression)
      mkPrefix (p, op) = PrefixExpr def op <$ mkOp p
  in  
    Prefix $ makePrefix (map mkPrefix pfxs)

exprTable:: Stream s Identity Char => [[InOp s]]
exprTable =
  [ [ makePostfixExpr pplusplus PostfixInc
    , makePostfixExpr pminusminus PostfixDec
    ]
  , [ makePrefixExpr  pplusplus PrefixInc
    , makePrefixExpr  pminusminus PrefixDec
    , makeUnaryExpr [ (pnot     , PrefixLNot)
                    , (pbnot     , PrefixBNot)
                    , (pplus     , PrefixPlus)
                    , (pminus    , PrefixMinus)
                    , (forget ktypeof, PrefixTypeof)
                    , (forget kvoid  , PrefixVoid)
                    , (forget kdelete, PrefixDelete)
                    ]
    ]
  , [ makeInfixExpr pmul OpMul
    , makeInfixExpr pdiv OpDiv
    , makeInfixExpr pmod OpMod
    ]
  , [ makeInfixExpr pplus OpAdd
    , makeInfixExpr pminus OpSub
    ]
  , [ makeInfixExpr pushr OpZfRShift
    , makeInfixExpr pshr  OpSpRShift
    , makeInfixExpr pshl  OpLShift
    ]
  , [ makeInfixExpr pleqt OpLEq
    , makeInfixExpr plangle OpLT
    , makeInfixExpr pgeqt OpGEq
    , makeInfixExpr prangle  OpGT
    , makeInfixExpr (forget kinstanceof) OpInstanceof
    , makeInfixExpr (forget kin) OpIn
    ]
  , [ makeInfixExpr pseq OpStrictEq
    , makeInfixExpr psneq OpStrictNEq
    , makeInfixExpr peq  OpEq
    , makeInfixExpr pneq  OpNEq
    ]
  , [ makeInfixExpr pband  OpBAnd ]
  , [ makeInfixExpr pbxor  OpBXor ]
  , [ makeInfixExpr pbor  OpBOr ]
  , [ makeInfixExpr pand OpLAnd ]
  , [ makeInfixExpr por OpLOr ]
  
  , [ makeAssignExpr passign OpAssign
    , makeAssignExpr passignadd OpAssignAdd
    , makeAssignExpr passignsub OpAssignSub
    , makeAssignExpr passignmul OpAssignMul
    , makeAssignExpr passigndiv OpAssignDiv
    , makeAssignExpr passignmod OpAssignMod
    , makeAssignExpr passignshl OpAssignLShift
    , makeAssignExpr passignshr OpAssignSpRShift
    , makeAssignExpr passignushr OpAssignZfRShift
    , makeAssignExpr passignbor OpAssignBAnd
    , makeAssignExpr passignbxor OpAssignBXor
    , makeAssignExpr passignbor OpAssignBOr
    ]
  ]


assignmentExpressionGen :: PosInParser Expression
assignmentExpressionGen =
  buildExpressionParser exprTable (liftIn leftHandSideExpression) <?> "simple expression"

assignmentExpression, assignmentExpressionNoIn :: PosParser Expression
assignmentExpression     = withIn assignmentExpressionGen
assignmentExpressionNoIn = withNoIn assignmentExpressionGen

-- avoid putting comma expression on everything
-- probably should be binary op in the table
makeExpression [x] = x
makeExpression xs = CommaExpr def xs

-- | A parser that parses ECMAScript expressions
expression, expressionNoIn :: PosParser Expression
expression     = withPos $ makeExpression <$> assignmentExpression     `sepBy1` pcomma
expressionNoIn = withPos $ makeExpression <$> assignmentExpressionNoIn `sepBy1` pcomma

functionBody :: Parser [Positioned Statement]
functionBody = option [] sourceElements

sourceElements :: Parser [Positioned Statement]
sourceElements = many1 sourceElement

sourceElement :: PosParser Statement
sourceElement = functionDeclaration <|> parseStatement

functionDeclaration :: PosParser Statement
functionDeclaration = withPos $
  FunctionStmt def
  <$  kfunction
  <*> identifierName
  <*> inParens formalParameterList
  <*> inBraces functionBody

formalParameterList :: Parser [Positioned Id]
formalParameterList =
  withPos identifierName `sepBy` pcomma

parseStatement :: PosParser Statement
parseStatement =
  choice
  [ parseBlock
  , variableStatement
  , expressionStatement
  , ifStatement
  , iterationStatement
  , continueStatement
  , breakStatement
  , returnStatement
  , withStatement
  , labelledStatement
  , switchStatement
  , throwStatement
  , tryStatement
  , debuggerStatement
  , emptyStatement ]

statementList :: Parser [Positioned Statement]
statementList = many1 (withPos parseStatement)

parseBlock :: PosParser Statement
parseBlock =
  withPos $ inBraces $
  BlockStmt def <$> option [] statementList

variableStatement :: PosParser Statement
variableStatement =
  withPos $
  VarDeclStmt def
  <$  kvar
  <*> variableDeclarationList
  <*  autoSemi

variableDeclarationList :: Parser [Positioned VarDecl]
variableDeclarationList =
  variableDeclaration `sepBy` pcomma

variableDeclaration :: PosParser VarDecl
variableDeclaration =
  withPos $ VarDecl def <$> identifierName <*> optionMaybe initializer

initializer :: PosParser Expression
initializer =
  passign *> assignmentExpression

variableDeclarationListNoIn :: Parser [Positioned VarDecl]
variableDeclarationListNoIn =
  variableDeclarationNoIn `sepBy` pcomma

variableDeclarationNoIn :: PosParser VarDecl
variableDeclarationNoIn =
  withPos $ VarDecl def <$> identifierName  <*> optionMaybe initalizerNoIn

initalizerNoIn :: PosParser Expression
initalizerNoIn =
  passign *> assignmentExpressionNoIn

emptyStatement :: PosParser Statement
emptyStatement =
  withPos $ EmptyStmt def <$ psemi

expressionStatement :: PosParser Statement
expressionStatement =
  withPos $
  notFollowedBy (plbrace <|> forget kfunction)
   >> ExprStmt def
  <$> expression
  <*  autoSemi

ifStatement :: PosParser Statement
ifStatement =
  withPos $
  IfStmt def
  <$  kif
  <*> inParens expression
  <*> parseStatement
  <*> option (EmptyStmt def) (kelse *> parseStatement)

iterationStatement :: PosParser Statement
iterationStatement = doStatement <|> whileStatement <|> forStatement

doStatement :: PosParser Statement
doStatement =
  withPos $
  DoWhileStmt def
  <$  kdo
  <*> parseStatement
  <*  kwhile
  <*> inParens expression
  <*  autoSemi

whileStatement :: PosParser Statement
whileStatement =
  withPos $
  WhileStmt def
  <$  kwhile
  <*> inParens expression
  <*> parseStatement

forStatement :: PosParser Statement
forStatement =
  withPos $
  kfor
   >> inParens (forStmt <|> forInStmt)
  <*> parseStatement
  where
    forStmt :: Parser (Positioned Statement -> Positioned Statement)
    forStmt =
      ForStmt def
      <$> try (choice [ VarInit <$> (kvar *> variableDeclarationListNoIn)
                 , ExprInit <$> expressionNoIn
                 , return NoInit ]
      <* psemi) <*> optionMaybe expression
      <* psemi <*> optionMaybe expression
    forInStmt :: Parser (Positioned Statement -> Positioned Statement)
    forInStmt =
      ForInStmt def
      <$> (ForInVar <$> (kvar *> variableDeclarationNoIn) <|>
           ForInExpr <$> leftHandSideExpression )
      <* kin
      <*> expression

restricted :: (HasAnnotation e)
           =>  Parser Bool -> (SourceSpan -> a -> e SourceSpan) -> Parser a -> Parser a -> Parser (e SourceSpan)
restricted keyword constructor null parser =
  withPos $
  do consumedNewLine <- keyword 
     rest <- if consumedNewLine 
       then null
       else parser
     autoSemi
     return (constructor def rest)
     

continueStatement :: PosParser Statement
continueStatement =
  restricted kcontinue ContinueStmt (return Nothing) (optionMaybe identifierName)

breakStatement :: PosParser Statement
breakStatement =
  restricted kbreak BreakStmt (return Nothing) (optionMaybe identifierName)

throwStatement :: PosParser Statement
throwStatement =
  restricted kthrow ThrowStmt (fail "Illegal newline after throw") expression

returnStatement :: PosParser Statement
returnStatement =
  restricted kreturn ReturnStmt (return Nothing) (optionMaybe expression)

withStatement :: PosParser Statement
withStatement =
  withPos $
  WithStmt def
  <$  kwith
  <*> inParens expression
  <*> parseStatement

-- TODO: push statements I suppose
labelledStatement :: PosParser Statement
labelledStatement =
  withPos $
  LabelledStmt def
  <$> identifierName
  <*  pcolon
  <*> parseStatement

switchStatement :: PosParser Statement
switchStatement =
  SwitchStmt def
  <$  kswitch
  <*> inParens expression
  <*> caseBlock
  where
    makeCaseClauses cs d cs2 = cs ++ maybeToList d ++ cs2
    caseBlock =
      inBraces $
      makeCaseClauses
      <$> option [] caseClauses
      <*> optionMaybe defaultClause
      <*> option [] caseClauses
    caseClauses :: Parser [Positioned CaseClause]
    caseClauses =
      many1 caseClause
    caseClause :: Parser (Positioned CaseClause)
    caseClause =
      withPos $
      CaseClause def
      <$  kcase
      <*> expression <* pcolon
      <*> option [] statementList
    defaultClause :: Parser (Positioned CaseClause)
    defaultClause =
      withPos $
      kdefault <* pcolon
       >> CaseDefault def
      <$> option [] statementList

tryStatement :: PosParser Statement
tryStatement =
  withPos $
  TryStmt def
  <$  ktry
  <*> block
  <*> optionMaybe catch
  <*> optionMaybe finally
  where
    catch :: Parser (Positioned CatchClause)
    catch = withPos $
            CatchClause def
            <$  kcatch
            <*> inParens identifierName
            <*> block
    finally :: PosParser Statement
    finally = withPos $
              kfinally *>
              block

block :: PosParser Statement
block = withPos $ BlockStmt def <$> inBraces (option [] statementList)

debuggerStatement :: PosParser Statement
debuggerStatement =
  withPos $ DebuggerStmt def <$ kdebugger <* autoSemi

-- | A parser that parses ECMAScript statements
statement :: PosParser Statement
statement = parseStatement

-- | A parser that parses an ECMAScript program.
program :: PosParser Program
program = ws *> withPos (Program def <$> many sourceElement) <* eof

-- | Parse from a stream given a parser, same as 'Text.Parsec.parse'
-- in Parsec. We can use this to parse expressions or statements
-- alone, not just programs.
parse :: Stream s Identity Char
      => PosParser x -- ^ The parser to use
      -> SourceName -- ^ Name of the source file
      -> s -- ^ The stream to parse, usually a 'String' or a 'ByteString'
      -> Either ParseError (x SourceSpan)
parse p = runParser p initialParserState

-- | A convenience function that takes a filename and tries to parse
-- the file contents an ECMAScript program, it fails with an error
-- message if it can't.
parseFromFile :: (Error e, MonadIO m, MonadError e m) => String -- ^ file name
              -> m (Program SourceSpan)
parseFromFile fname =
  liftIO (readFile fname) >>= \source ->
  case parse program fname source of
    Left err -> throwError $ strMsg $ show err
    Right js -> return js

-- | A convenience function that takes a 'String' and tries to parse
-- it as an ECMAScript program:
--
-- > parseFromString = parse program ""
parseFromString :: String -- ^ JavaScript source to parse
                -> Either ParseError (Program SourceSpan)
parseFromString s = parse program "" s
