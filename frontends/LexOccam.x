{ {-# OPTIONS_GHC -fno-warn-unused-imports -fno-warn-missing-signatures #-}
{-
Tock: a compiler for parallel languages
Copyright (C) 2007  University of Kent

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program.  If not, see <http://www.gnu.org/licenses/>.
-}

-- | Lexically analyse occam code.
module LexOccam where

import Data.Generics

import Errors
import Metadata
import Pass
}

%wrapper "posn"

$decimalDigit = [0-9]
$hexDigit = [0-9 a-f A-F]

$horizSpace = [\ \t]
$vertSpace = [\r\n]

@directive = "COMMENT" | "ELSE" | "ENDIF" | "IF" | "INCLUDE"
           | "OPTION" | "PRAGMA" | "RELAX" | "USE"

@preprocessor = "#" @directive [^\n]*

@reserved = "[" | "]" | "(" | ")"
          | "::" | ":=" | ":" | "," | ";" | "&"
          | "?" | "!" | "="
          | "\" | "/\" | "\/"
          | "+" | "-" | "*" | "/"
          | "><" | "<<" | ">>" | "<>"
          | ">=" | "<="
          | "<" | ">"
          | "~"
          | "##"
          | "AFTER" | "ALT" | "AND" | "ANY" | "AT"
          | "BITAND" | "BITNOT" | "BITOR" | "BOOL" | "BYTE" | "BYTESIN"
          | "CASE" | "CHAN"
          | "DATA"
          | "ELSE"
          | "FALSE" | "FOR" | "FROM" | "FUNCTION"
          | "IF" | "IN" | "INITIAL" | "INLINE" | "INT" | "INT16" | "INT32" | "INT64"
          | "IS"
          | "MINUS" | "MOSTNEG" | "MOSTPOS"
          | "NOT"
          | "OF" | "OFFSETOF" | "OR"
          | "PACKED" | "PAR" | "PLACE" | "PLACED" | "PLUS" | "PORT"
          | "PRI" | "PROC" | "PROCESSOR" | "PROTOCOL"
          | "REAL32" | "REAL64" | "RECORD" | "REM" | "RESHAPES"
          | "RESULT" | "RETYPES" | "ROUND"
          | "SEQ" | "SIZE" | "SKIP" | "STOP"
          | "TIMER" | "TIMES" | "TRUE" | "TRUNC" | "TYPE"
          | "VAL" | "VALOF"
          | "WHILE" | "WORKSPACE"
          | "VECSPACE"
          | ".STATIC" | ".VSPTR" | ".WSSIZE"

@identifier = [a-z A-Z] [a-z A-Z 0-9 \.]*

@hexEscape = \# $hexDigit $hexDigit
@escape = \* ( @hexEscape | [^\#\n] )

@charLiteral = \' ( @escape | [^\'\*] ) \'
@stringBody = ( @escape | [^\"\*] )*
@fullString = \" @stringBody \"
@startString = \" @stringBody \* \n
@contString = \* @stringBody \* \n
@endString = \* @stringBody \"

-- Note that occam number literals don't include their signs -- if you say
-- "-3", then that's the operator "-" applied to the literal "3".
@intLiteral = $decimalDigit+
@hexLiteral = "#" $hexDigit+
@exponent = ("+" | "-") $decimalDigit+
@realLiteral = ( $decimalDigit+ "." $decimalDigit+ "E" @exponent )
             | ( $decimalDigit+ "." $decimalDigit+ )

occam :-

-- In state 0, we're consuming the horizontal space at the start of a line.
-- In state one, we're reading the first thing on a line.
-- In state two, we're reading the rest of the line.
-- In state three, we're in the middle of a multi-line string.

<0>           $horizSpace*   { mkState one }

<one>         @preprocessor  { mkToken TokPreprocessor 0 }
<one, two>    "--" [^\n]*    { mkState 0 }
<one, two>    $vertSpace+    { mkState 0 }

<one, two>    @reserved      { mkToken TokReserved two }
<one, two>    @identifier    { mkToken TokIdentifier two }

<one, two>    @charLiteral   { mkToken TokCharLiteral two }
<one, two>    @fullString    { mkToken TokStringLiteral two }
<one, two>    @startString   { mkToken TokStringCont three }

<three>       $horizSpace+   { mkState three }
<three>       @contString    { mkToken TokStringCont three }
<three>       @endString     { mkToken TokStringLiteral two }

<one, two>    @intLiteral    { mkToken TokIntLiteral two }
<one, two>    @hexLiteral    { mkToken TokHexLiteral two }
<one, two>    @realLiteral   { mkToken TokRealLiteral two }

<two>         $horizSpace+   { mkState two }

{
-- | An occam source token and its position.
type Token = (Meta, TokenType)

-- | An occam source token.
-- Only `Token` is generated by the lexer itself; the others are added later
-- once the indentation has been analysed.
data TokenType =
  TokReserved String                   -- ^ A reserved word or symbol
  | TokIdentifier String
  | TokStringCont String               -- ^ A continued string literal.
  | TokStringLiteral String            -- ^ (The end of) a string literal.
  | TokCharLiteral String
  | TokIntLiteral String
  | TokHexLiteral String
  | TokRealLiteral String
  | TokPreprocessor String
  | IncludeFile String                 -- ^ Include a file
  | Indent                             -- ^ Indentation increase
  | Outdent                            -- ^ Indentation decrease
  | EndOfLine                          -- ^ End of line
  deriving (Show, Eq, Typeable, Data)

-- | Build a lexer rule for a token.
mkToken :: (String -> TokenType) -> Int -> AlexPosn -> String -> (Maybe Token, Int)
mkToken cons code _ s = (Just (emptyMeta, cons s), code)

-- | Just switch state.
mkState :: Int -> AlexPosn -> String -> (Maybe Token, Int)
mkState code _ s = (Nothing, code)

-- | Run the lexer, returning a list of tokens.
-- (This is based on the `alexScanTokens` function that Alex provides.)
runLexer :: String -> String -> PassM [Token]
runLexer filename str = go (alexStartPos, '\n', str) 0
  where
    go inp@(pos@(AlexPn _ line col), _, str) code =
         case alexScan inp code of
           AlexEOF -> return []
           AlexError _ -> dieP meta "Unrecognised token"
           AlexSkip inp' len -> go inp' code
           AlexToken inp' len act ->
             do let (t, code) = act pos (take len str)
                ts <- go inp' code
                return $ case t of
                           Just tok -> (meta, snd tok) : ts
                           Nothing -> ts

      where
        meta = emptyMeta {
                 metaFile = Just filename,
                 metaLine = line,
                 metaColumn = col
               }
}

