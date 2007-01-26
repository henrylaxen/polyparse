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
  , field	-- :: Parse a => String -> TextParser a
  , constructors-- :: [(String,TextParser a)] -> TextParser a
  , enumeration -- :: Show a => String -> [a] -> TextParser a
    -- ** Re-export all the more general combinators from Poly too
  , module Text.ParserCombinators.Poly
  ) where

import Char (isSpace)
import List (intersperse)
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
    parse     :: TextParser a
    parseList :: TextParser [a]	-- only to distinguish [] and ""
    parseList  = do { isWord "[]"; return [] }
                   `onFail`
                 do { isWord "["; isWord "]"; return [] }
                   `onFail`
                 bracketSep (isWord "[") (isWord ",") (isWord "]") parse
                   `adjustErr` ("Expected a list, but\n"++)

-- | If there already exists a Read instance for a type, then we can make
--   a Parser for it, but with only poor error-reporting.
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
                   [("",s')]  -> (Left (False,"no input?"), s')
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

-- Basic types
instance Parse Int where
    parse = parseByRead "Int"
instance Parse Integer where
    parse = parseByRead "Integer"
instance Parse Float where
    parse = parseByRead "Float"
instance Parse Double where
    parse = parseByRead "Double"
instance Parse Char where
    parse = parseByRead "Char"
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
    parse = do { isWord "Nothing"; return Nothing }
              `onFail`
            do { isWord "Just"
               ; fmap Just $ optionalParens parse
                     `adjustErrBad` ("but within Just, "++)
               }
              `adjustErr` (("expected a Maybe (Just or Nothing)\n"++).indent 2)

instance (Parse a, Parse b) => Parse (Either a b) where
    parse = constructors [ ("Left",  do { fmap Left  $ optionalParens parse } )
                         , ("Right", do { fmap Right $ optionalParens parse } )
                         ]

instance Parse a => Parse [a] where
    parse = parseList

------------------------------------------------------------------------
