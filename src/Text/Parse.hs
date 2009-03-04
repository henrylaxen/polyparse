module Text.Parse
  ( -- * The Parse class is a replacement for the standard Read class. 
    -- $parser
    TextParser	-- synonym for Parser Char, i.e. string input, no state
  , Parse(..)	-- instances: (), (a,b), (a,b,c), Maybe a, Either a, [a],
		--            Int, Integer, Float, Double, Char, Bool
  , parseByRead	-- :: Read a => String -> TextParser a
    -- ** Combinators specific to string input, lexed haskell-style
  , word	-- :: TextParser String
  , isWord	-- :: String -> TextParser ()
  , optionalParens	-- :: TextParser a -> TextParser a
  , parens	-- :: Bool -> TextParser a -> TextParser a
  , field	-- :: Parse a => String -> TextParser a
  , constructors-- :: [(String,TextParser a)] -> TextParser a
  , enumeration -- :: Show a => String -> [a] -> TextParser a
    -- ** Parsers for literal numerics and characters
  , parseSigned
  , parseInt
  , parseDec
  , parseOct
  , parseHex
  , parseFloat
  , parseLitChar
    -- ** Re-export all the more general combinators from Poly too
  , module Text.ParserCombinators.Poly
  ) where

import Char (isSpace,toLower,isUpper,isDigit,isOctDigit,isHexDigit,digitToInt
            ,ord,chr)
import List (intersperse)
import Ratio
import Text.ParserCombinators.Poly

------------------------------------------------------------------------
-- $parser
-- The Parse class is a replacement for the standard Read class.  It is a
-- specialisation of the (poly) Parser monad for String input.
-- There are instances defined for all Prelude types.
-- For user-defined types, you can write your own instance, or use
-- DrIFT to generate them automatically, e.g. {-! derive : Parse !-}

-- | A synonym for Parser Char, i.e. string input (no state)
type TextParser a = Parser Char a

-- | The class @Parse@ is a replacement for @Read@, operating over String input.
--   Essentially, it permits better error messages for why something failed to
--   parse.  It is rather important that @parse@ can read back exactly what
--   is generated by the corresponding instance of @show@.  To apply a parser
--   to some text, use @runParser@.
class Parse a where
    -- | A straightforward parser for an item.  (A minimal definition of
    --   a class instance requires either |parse| or |parsePrec|.)
    parse     :: TextParser a
    parse       = parsePrec 0
    -- | A straightforward parser for an item, given the precedence of
    --   any surrounding expression.  (Precedence determines whether
    --   parentheses are mandatory or optional.)
    parsePrec :: Int -> TextParser a
    parsePrec _ = parens False parse
    -- | Parsing a list of items by default accepts the [] and comma syntax,
    --   except when the list is really a character string using "".
    parseList :: TextParser [a]	-- only to distinguish [] and ""
    parseList  = do { isWord "[]"; return [] }
                   `onFail`
                 do { isWord "["; isWord "]"; return [] }
                   `onFail`
                 bracketSep (isWord "[") (isWord ",") (isWord "]") parse
                   `adjustErr` ("Expected a list, but\n"++)

-- | If there already exists a Read instance for a type, then we can make
--   a Parser for it, but with only poor error-reporting.  The string argument
--   is the expected type or value (for error-reporting only).
parseByRead :: Read a => String -> TextParser a
parseByRead name =
    P (\s-> case reads s of
                []       -> (Left (False,"no parse, expected a "++name), s)
                [(a,s')] -> (Right a, s')
                _        -> (Left (False,"ambiguous parse, expected a "++name), s)
      )

-- | One lexical chunk (Haskell-style lexing).
word :: TextParser String
word = P (\s-> case lex s of
                   []         -> (Left (False,"no input? (impossible)"), s)
                   [("","")]  -> (Left (False,"no input?"), "")
                   [("",s')]  -> (Left (False,"lexing failed?"), s')
                   ((x,s'):_) -> (Right x, s') )

-- | Ensure that the next input word is the given string.  (Note the input
--   is lexed as haskell, so wordbreaks at spaces, symbols, etc.)
isWord :: String -> TextParser String
isWord w = do { w' <- word
              ; if w'==w then return w else fail ("expected "++w++" got "++w')
              }

-- | Allow true string parens around an item.
optionalParens :: TextParser a -> TextParser a
optionalParens p = bracket (isWord "(") (isWord ")") p `onFail` p

-- | Allow nested parens around an item (one set required when Bool is True).
parens :: Bool -> TextParser a -> TextParser a
parens True  p = bracket (isWord "(") (isWord ")") (parens False p)
parens False p = parens True p `onFail` p

-- | Deal with named field syntax.  The string argument is the field name,
--   and the parser returns the value of the field.
field :: Parse a => String -> TextParser a
field name = do { isWord name; commit $ do { isWord "="; parse } }

-- | Parse one of a bunch of alternative constructors.  In the list argument,
--   the first element of the pair is the constructor name, and
--   the second is the parser for the rest of the value.  The first matching
--   parse is returned.
constructors :: [(String,TextParser a)] -> TextParser a
constructors cs = oneOf' (map cons cs)
    where cons (name,p) =
               ( name
               , do { isWord name
                    ; p `adjustErrBad` (("got constructor, but within "
                                        ++name++",\n")++)
                    }
               )

-- | Parse one of the given nullary constructors (an enumeration).
--   The string argument is the name of the type, and the list argument
--   should contain all of the possible enumeration values.
enumeration :: (Show a) => String -> [a] -> TextParser a
enumeration typ cs = oneOf (map (\c-> do { isWord (show c); return c }) cs)
                         `adjustErr`
                     (++("\n  expected "++typ++" value ("++e++")"))
    where e = concat (intersperse ", " (map show (init cs)))
              ++ ", or " ++ show (last cs)

------------------------------------------------------------------------
-- Instances for all the Standard Prelude types.

-- Numeric types
parseSigned :: Real a => TextParser a -> TextParser a
parseSigned p = do '-' <- next; commit (fmap negate p)
                `onFail`
                do p

parseInt :: (Integral a) => String ->
                            a -> (Char -> Bool) -> (Char -> Int) ->
                            a -> TextParser a
parseInt base radix isDigit digitToInt n = go n
  where go acc = do cs <- many1 (satisfy isDigit)
                    return (foldl1 (\n d-> n*radix+d)
                                   (map (fromIntegral.digitToInt) cs))
                 `adjustErr` (++("\nexpected one or more "++base++" digits"))
parseDec, parseOct, parseHex :: (Integral a) => a -> TextParser a
parseDec = parseInt "decimal" 10 Char.isDigit    Char.digitToInt
parseOct = parseInt "octal"    8 Char.isOctDigit Char.digitToInt
parseHex = parseInt "hex"     16 Char.isHexDigit Char.digitToInt

parseFloat :: (RealFrac a) => TextParser a
parseFloat = do ds <- many1 (satisfy isDigit)
                frac <- (do '.' <- next
                            many (satisfy isDigit)
                              `adjustErrBad` (++"expected digit after .")
                         `onFail` return [] )
                exp  <- (do 'e' <- fmap toLower next
                            commit (do '+' <- next; parseDec 0
                                    `onFail`
                                    parseSigned (parseDec 0) ))
                ( return . fromRational . (* (10^^(exp - length frac)))
                  . (%1) .  (\ (Right x)->x) . fst
                  . runParser (parseDec 0) ) (ds++frac)
             `onFail`
             do w <- many (satisfy (not.isSpace))
                case map toLower w of
                  "nan"      -> return (0/0)
                  "infinity" -> return (1/0)
                  _          -> fail "expected a floating point number"

parseLitChar :: TextParser Char
parseLitChar = do '\'' <- next `adjustErr` (++"expected a literal char")
                  c <- next
                  char <- case c of
                            '\\' -> next >>= escape
                            '\'' -> fail "expected a literal char, got ''"
                            _    -> return c
                  '\'' <- next `adjustErrBad` (++"literal char has no final '")
                  return char
  where
    escape 'a'  = return '\a'
    escape 'b'  = return '\b'
    escape 'f'  = return '\f'
    escape 'n'  = return '\n'
    escape 'r'  = return '\r'
    escape 't'  = return '\t'
    escape 'v'  = return '\v'
    escape '\\' = return '\\'
    escape '"'  = return '"'
    escape '\'' = return '\''
    escape '^'  = do ctrl <- next
                     if ctrl >= '@' && ctrl <= '_'
                       then return (chr (ord ctrl - ord '@'))
                       else fail ("literal char ctrl-escape malformed: \\^"
                                   ++[ctrl])
    escape d | isDigit d
                = fmap chr $  parseDec (Char.digitToInt d)
    escape 'o'  = fmap chr $  parseOct 0
    escape 'x'  = fmap chr $  parseHex 0
    escape c | isUpper c
                = mnemonic c
    escape c    = fail ("unrecognised escape sequence in literal char: \\"++[c])

    mnemonic 'A' = do 'C' <- next; 'K' <- next; return '\ACK'
                   `wrap` "'\\ACK'"
    mnemonic 'B' = do 'E' <- next; 'L' <- next; return '\BEL'
                   `onFail`
                   do 'S' <- next; return '\BS'
                   `wrap` "'\\BEL' or '\\BS'"
    mnemonic 'C' = do 'R' <- next; return '\CR'
                   `onFail`
                   do 'A' <- next; 'N' <- next; return '\CAN'
                   `wrap` "'\\CR' or '\\CAN'"
    mnemonic 'D' = do 'E' <- next; 'L' <- next; return '\DEL'
                   `onFail`
                   do 'L' <- next; 'E' <- next; return '\DLE'
                   `onFail`
                   do 'C' <- next; ( do '1' <- next; return '\DC1'
                                     `onFail`
                                     do '2' <- next; return '\DC2'
                                     `onFail`
                                     do '3' <- next; return '\DC3'
                                     `onFail`
                                     do '4' <- next; return '\DC4' )
                   `wrap` "'\\DEL' or '\\DLE' or '\\DC[1..4]'"
    mnemonic 'E' = do 'T' <- next; 'X' <- next; return '\ETX'
                   `onFail`
                   do 'O' <- next; 'T' <- next; return '\EOT'
                   `onFail`
                   do 'N' <- next; 'Q' <- next; return '\ENQ'
                   `onFail`
                   do 'T' <- next; 'B' <- next; return '\ETB'
                   `onFail`
                   do 'M' <- next; return '\EM'
                   `onFail`
                   do 'S' <- next; 'C' <- next; return '\ESC'
                   `wrap` "one of '\\ETX' '\\EOT' '\\ENQ' '\\ETB' '\\EM' or '\\ESC'"
    mnemonic 'F' = do 'F' <- next; return '\FF'
                   `onFail`
                   do 'S' <- next; return '\FS'
                   `wrap` "'\\FF' or '\\FS'"
    mnemonic 'G' = do 'S' <- next; return '\GS'
                   `wrap` "'\\GS'"
    mnemonic 'H' = do 'T' <- next; return '\HT'
                   `wrap` "'\\HT'"
    mnemonic 'L' = do 'F' <- next; return '\LF'
                   `wrap` "'\\LF'"
    mnemonic 'N' = do 'U' <- next; 'L' <- next; return '\NUL'
                   `onFail`
                   do 'A' <- next; 'K' <- next; return '\NAK'
                   `wrap` "'\\NUL' or '\\NAK'"
    mnemonic 'R' = do 'S' <- next; return '\RS'
                   `wrap` "'\\RS'"
    mnemonic 'S' = do 'O' <- next; 'H' <- next; return '\SOH'
                   `onFail`
                   do 'O' <- next; return '\SO'
                   `onFail`
                   do 'T' <- next; 'X' <- next; return '\STX'
                   `onFail`
                   do 'I' <- next; return '\SI'
                   `onFail`
                   do 'Y' <- next; 'N' <- next; return '\SYN'
                   `onFail`
                   do 'U' <- next; 'B' <- next; return '\SUB'
                   `onFail`
                   do 'P' <- next; return '\SP'
                   `wrap` "'\\SOH' '\\SO' '\\STX' '\\SI' '\\SYN' '\\SUB' or '\\SP'"
    mnemonic 'U' = do 'S' <- next; return '\US'
                   `wrap` "'\\US'"
    mnemonic 'V' = do 'T' <- next; return '\VT'
                   `wrap` "'\\VT'"
    wrap p s = p `onFail` fail ("expected literal char "++s)

-- Basic types
instance Parse Int where
 -- parse = parseByRead "Int"	-- convert from Integer, deals with minInt
    parse = fmap fromInteger $
              do many (satisfy isSpace); parseSigned (parseDec 0)
instance Parse Integer where
 -- parse = parseByRead "Integer"
    parse = do many (satisfy isSpace); parseSigned (parseDec 0)
instance Parse Float where
 -- parse = parseByRead "Float"
    parse = do many (satisfy isSpace); parseSigned parseFloat
instance Parse Double where
 -- parse = parseByRead "Double"
    parse = do many (satisfy isSpace); parseSigned parseFloat
instance Parse Char where
--  parse = parseByRead "Char"
    parse = do many (satisfy isSpace); parseLitChar
 -- parse = do { w <- word; if head w == '\'' then readLitChar (tail w)
 --                                           else fail "expected a char" }
 -- parseList = bracket (isWord "\"") (satisfy (=='"'))
 --                     (many (satisfy (/='"')))
	-- not totally correct for strings...
    parseList = do { w <- word; if head w == '"' then return (init (tail w))
                                else fail "not a string" }

instance Parse Bool where
    parse = enumeration "Bool" [False,True]

instance Parse Ordering where
    parse = enumeration "Ordering" [LT,EQ,GT]

-- Structural types
instance Parse () where
    parse = P p
      where p []       = (Left (False,"no input: expected a ()"), [])
            p ('(':cs) = case dropWhile isSpace cs of
                             (')':s) -> (Right (), s)
                             _       -> (Left (False,"Expected ) after ("), cs)
            p (c:cs) | isSpace c = p cs
                     | otherwise = ( Left (False,"Expected a (), got "++show c)
                                     , (c:cs))

instance (Parse a, Parse b) => Parse (a,b) where
    parse = do{ isWord "(" `adjustErr` ("Opening a 2-tuple\n"++)
              ; x <- parse `adjustErr` ("In 1st item of a 2-tuple\n"++)
              ; isWord "," `adjustErr` ("Separating a 2-tuple\n"++)
              ; y <- parse `adjustErr` ("In 2nd item of a 2-tuple\n"++)
              ; isWord ")" `adjustErr` ("Closing a 2-tuple\n"++)
              ; return (x,y) }

instance (Parse a, Parse b, Parse c) => Parse (a,b,c) where
    parse = do{ isWord "(" `adjustErr` ("Opening a 3-tuple\n"++)
              ; x <- parse `adjustErr` ("In 1st item of a 3-tuple\n"++)
              ; isWord "," `adjustErr` ("Separating(1) a 3-tuple\n"++)
              ; y <- parse `adjustErr` ("In 2nd item of a 3-tuple\n"++)
              ; isWord "," `adjustErr` ("Separating(2) a 3-tuple\n"++)
              ; z <- parse `adjustErr` ("In 3rd item of a 3-tuple\n"++)
              ; isWord ")" `adjustErr` ("Closing a 3-tuple\n"++)
              ; return (x,y,z) }

instance Parse a => Parse (Maybe a) where
    parsePrec p =
            parens False (do { isWord "Nothing"; return Nothing })
            `onFail`
            parens (p>9) (do { isWord "Just"
                               ; fmap Just $ parsePrec 10
                                     `adjustErrBad` ("but within Just, "++) })
            `adjustErr` (("expected a Maybe (Just or Nothing)\n"++).indent 2)

instance (Parse a, Parse b) => Parse (Either a b) where
    parsePrec p =
            parens (p>9) $
            constructors [ ("Left",  do { fmap Left  $ parsePrec 10 } )
                         , ("Right", do { fmap Right $ parsePrec 10 } )
                         ]

instance Parse a => Parse [a] where
    parse = parseList

------------------------------------------------------------------------
