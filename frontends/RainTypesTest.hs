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

module RainTypesTest where

import Test.HUnit hiding (State)
import TestUtil
import RainTypes
import TreeUtil
import Pattern
import qualified AST as A
import CompState
import Control.Monad.State
import Control.Monad.Error
import Types
import Pass

constantFoldTest :: Test
constantFoldTest = TestList
 [
  foldVar 0 $ Var "x"
  ,foldVar 1 $ Dy (Var "x") A.Plus (lit 0)
  
  ,foldCon 100 (lit 2) (Dy (lit 1) A.Plus (lit 1))  
  ,foldCon 101 (lit 65537) (Dy (lit 2) A.Plus (lit 65535))
  ,foldCon 102 (lit (- two63)) (Dy (lit $ two63 - 1) A.Plus (lit 1))
  
  ,foldCon 110 (Dy (Var "x") A.Plus (lit 2)) (Dy (Var "x") A.Plus (Dy (lit 1) A.Plus (lit 1)))
 ]
 where
   two63 :: Integer
   two63 = 9223372036854775808
 
   foldVar :: Int -> ExprHelper -> Test
   foldVar n e = TestCase $ testPass ("constantFoldTest " ++ show n) (buildExprPattern e) (constantFoldPass $ buildExpr e) state

   foldCon :: Int -> ExprHelper -> ExprHelper -> Test
   foldCon n exp orig = TestCase $ testPass ("constantFoldTest " ++ show n) (buildExprPattern exp) (constantFoldPass $ buildExpr orig) state

   state :: State CompState ()
   state = return ()

   lit :: Integer -> ExprHelper
   lit n = Lit $ int64Literal n

annotateIntTest :: Test
annotateIntTest = TestList
 [
  failSigned (-9223372036854775809)
  ,signed A.Int64 (-9223372036854775808)
  ,signed A.Int64 (-2147483649)
  ,signed A.Int32 (-2147483648)
  ,signed A.Int32 (-32769)
  ,signed A.Int16 (-32768)
  ,signed A.Int16 (-129)
  ,signed A.Int8 (-128)
  ,signed A.Int8 0
  ,signed A.Int8 127
  ,signed A.Int16 128
  ,signed A.Int16 32767
  ,signed A.Int32 32768
  ,signed A.Int32 2147483647
  ,signed A.Int64 2147483648
  ,signed A.Int64 9223372036854775807
  ,failSigned 9223372036854775808
 ]
 where
  signed :: A.Type -> Integer -> Test
  signed t n = TestCase $ testPass ("annotateIntTest: " ++ show n) (tag3 A.Literal DontCare t $ tag2 A.IntLiteral DontCare (show n)) 
    (annnotateIntLiteralTypes $ int64Literal n) (return ())
  failSigned :: Integer -> Test
  failSigned n = TestCase $ testPassShouldFail ("annotateIntTest: " ++ show n) (annnotateIntLiteralTypes $ int64Literal n) (return ())

checkExpressionTest :: Test
checkExpressionTest = TestList
 [
  --Already same types:
  passSame 0 A.Int64 $ Dy (Var "x") A.Plus (Var "x")
  ,passSame 1 A.Byte $ Dy (Var "xu8") A.Plus (Var "xu8")
  
  --Upcasting:
  ,pass 100 A.Int64 (Dy (Var "x") A.Plus (Cast A.Int64 $ Var "xu8")) (Dy (Var "x") A.Plus (Var "xu8"))
  ,pass 101 A.Int32 (Dy (Cast A.Int32 $ Var "x16") A.Plus (Cast A.Int32 $ Var "xu16")) (Dy (Var "x16") A.Plus (Var "xu16"))
  
  --Upcasting a cast:
  ,pass 200 A.Int64 (Dy (Var "x") A.Plus (Cast A.Int64 $ Cast A.Int32 $ Var "xu8")) (Dy (Var "x") A.Plus (Cast A.Int32 $ Var "xu8"))
  
  --Impossible conversions:
  ,fail 300 $ Dy (Var "x") A.Plus (Var "xu64")
  
  --Integer literals:
  ,pass 400 A.Int16 (Dy (Var "x16") A.Plus (Cast A.Int16 $ int A.Int8 100)) (Dy (Var "x16") A.Plus (int A.Int8 100))
  ,pass 401 A.Int16 (Dy (Cast A.Int16 $ Var "x8") A.Plus (int A.Int16 200)) (Dy (Var "x8") A.Plus (int A.Int16 200))
  --This fails because you are trying to add a signed constant to an unsigned integer that cannot be expanded:
  ,fail 402 $ Dy (Var "xu64") A.Plus (int A.Int64 0)
  
  --Monadic integer operations:
  ,passSame 500 A.Int32 (Mon A.MonadicMinus (Var "x32"))
  ,pass 501 A.Int32 (Mon A.MonadicMinus (Cast A.Int32 $ Var "xu16")) (Mon A.MonadicMinus (Var "xu16"))
  ,fail 502 $ Mon A.MonadicMinus (Var "xu64")
  ,pass 503 A.Int64 (Dy (Var "x") A.Plus (Cast A.Int64 $ Mon A.MonadicMinus (Var "x32"))) (Dy (Var "x") A.Plus (Mon A.MonadicMinus (Var "x32")))
  
  --Mis-matched types (integer/boolean):
  ,fail 600 $ Dy (Var "b") A.Plus (Var "x")
  ,fail 601 $ Mon A.MonadicMinus (Var "b")
  ,fail 602 $ Dy (Var "x") A.Or (Var "x")
  ,fail 603 $ Dy (Var "x") A.Eq (Var "b")
  ,fail 604 $ Dy (Var "b") A.Plus (Var "b")
  ,fail 605 $ Dy (Var "b") A.Less (Var "b")  
  
  --Comparisons between different integer types:
  ,pass 700 A.Bool (Dy (Var "x") A.Eq (Cast A.Int64 $ Var "xu8")) (Dy (Var "x") A.Eq (Var "xu8"))
  ,pass 701 A.Bool (Dy (Cast A.Int32 $ Var "x16") A.Less (Cast A.Int32 $ Var "xu16")) (Dy (Var "x16") A.Less (Var "xu16"))
  ,pass 702 A.Bool (Dy (Var "x") A.More (Cast A.Int64 $ Cast A.Int32 $ Var "xu8")) (Dy (Var "x") A.More (Cast A.Int32 $ Var "xu8"))
  ,fail 703 $ Dy (Var "x") A.Less (Var "xu64")
  ,pass 704 A.Bool (Dy (Var "x16") A.NotEq (Cast A.Int16 $ int A.Int8 100)) (Dy (Var "x16") A.NotEq (int A.Int8 100))
  ,pass 705 A.Bool (Dy (Cast A.Int16 $ Var "x8") A.MoreEq (int A.Int16 200)) (Dy (Var "x8") A.MoreEq (int A.Int16 200))

  
  --Booleans (easy!)
  ,passSame 1000 A.Bool $ Mon A.MonadicNot (Var "b")
  ,passSame 1001 A.Bool $ Dy (Var "b") A.Or (Var "b")
  ,passSame 1002 A.Bool $ Dy (Var "b") A.And (Mon A.MonadicNot $ Var "b")
  
  --Comparison (same types):
  ,passSame 1100 A.Bool $ Dy (Var "b") A.Eq (Var "b")
  ,passSame 1101 A.Bool $ Dy (Var "x") A.Eq (Var "x")
  ,passSame 1102 A.Bool $ Dy (Var "xu8") A.NotEq (Var "xu8")
  ,passSame 1103 A.Bool $ Dy (Var "x") A.Less (Var "x")
  ,passSame 1104 A.Bool $ Dy (Dy (Var "x") A.Eq (Var "x")) A.And (Dy (Var "xu8") A.NotEq (Var "xu8"))
  
  --Invalid casts:
  ,fail 2000 $ Cast A.Bool (Var "x")
  ,fail 2001 $ Cast A.Bool (int A.Int8 0)
  ,fail 2002 $ Cast A.Int8 (Var "b")
  ,fail 2003 $ Cast A.Int8 (Var "x")
  ,fail 2004 $ Cast A.Int8 (Var "xu8")
  ,fail 2005 $ Cast A.Byte (Var "x8")
  ,fail 2006 $ Cast A.UInt64 (Var "x8")
    
  --Valid casts:
  ,passSame 2100 A.Bool $ Cast A.Bool (Var "b")
  ,passSame 2101 A.Int64 $ Cast A.Int64 (Var "x")
  ,passSame 2102 A.Int64 $ Cast A.Int64 (Var "x8")
  ,passSame 2103 A.Int64 $ Cast A.Int64 (Var "xu8")
  ,passSame 2104 A.Int64 $ Cast A.Int64 $ Cast A.Int32 $ Cast A.UInt16 $ Var "xu8"  
  ,passSame 2105 A.UInt64 $ Cast A.UInt64 (Var "xu8")
  
  --Assignments:
  ,passAssignSame 3000 "x" (Var "x")
  ,passAssignSame 3001 "xu8" (Var "xu8")
  ,passAssignSame 3002 "b" (Var "b")
  ,passAssignSame 3003 "x" $ Dy (Var "x") A.Plus (Var "x")
  ,passAssignSame 3004 "b" $ Dy (Var "x8") A.Eq (Var "x8")
  ,passAssignSame 3004 "x" $ Mon A.MonadicMinus (Var "x")

  ,passAssign 3100 "x" (Cast A.Int64 $ Var "xu8") (Var "xu8")
  ,failAssign 3101 "xu8" (Var "x")
  ,failAssign 3102 "x" (Var "b")
  ,failAssign 3103 "b" (Var "x")
  ,failAssign 3104 "x8" (Var "xu8")
  ,failAssign 3105 "xu8" (Var "x8")
 ]
 where
  passAssign :: Int -> String -> ExprHelper -> ExprHelper -> Test
  passAssign n lhs exp src = TestCase $ testPassWithCheck ("checkExpressionTest " ++ show n) 
    (tag3 A.Assign DontCare [variablePattern lhs] $ tag2 A.ExpressionList DontCare [buildExprPattern exp])
    (checkAssignmentTypes $ src')
    state refeed
    where
      src' = A.Assign m [variable lhs] $ A.ExpressionList m [buildExpr src]
    
      refeed :: A.Process -> Assertion
      refeed changed = if (src' /= changed) then testPass ("checkExpressionTest refeed " ++ show n) (mkPattern changed) (checkAssignmentTypes changed) state else return ()
  
  passAssignSame :: Int -> String -> ExprHelper -> Test
  passAssignSame n s e = passAssign n s e e
  
  failAssign :: Int -> String -> ExprHelper -> Test
  failAssign n lhs src = TestCase $ testPassShouldFail ("checkExpressionTest " ++ show n) (checkAssignmentTypes $ A.Assign m [variable lhs] $ A.ExpressionList m [buildExpr src]) state
 
  passSame :: Int -> A.Type -> ExprHelper -> Test
  passSame n t e = pass n t e e
  
  pass :: Int -> A.Type -> ExprHelper -> ExprHelper -> Test
  pass n t exp act = TestCase $ pass' n t (buildExprPattern exp) (buildExpr act)

  --To easily get more tests, we take the result of every successful pass (which must be fine now), and feed it back through
  --the type-checker to check that it is unchanged
  
  pass' :: Int -> A.Type -> Pattern -> A.Expression -> Assertion
  pass' n t exp act = testPassWithCheck ("checkExpressionTest " ++ show n) exp (checkExpressionTypes act) state (check t)   
    where
      check :: A.Type -> A.Expression -> Assertion
      check t e
        = do eot <- errorOrType
             case eot of
               Left err -> assertFailure ("checkExpressionTest " ++ show n ++ " typeOfExpression failed")
               Right t' -> do assertEqual ("checkExpressionTest " ++ show n) t t'
                              --Now feed it through again, to make sure it isn't changed:
                              if (e /= act) then pass' (10000 + n) t (mkPattern e) e else return ()
            where
              errorOrType :: IO (Either String A.Type)
              errorOrType = evalStateT (runErrorT $ typeOfExpression e) (execState state emptyState)
  
  
  fail :: Int -> ExprHelper -> Test
  fail n e = TestCase $ testPassShouldFail ("checkExpressionTest " ++ show n) (checkExpressionTypes $ buildExpr e) state
  
  int :: A.Type -> Integer -> ExprHelper
  int t n = Lit $ A.Literal m t $ A.IntLiteral m (show n)

  defVar :: String -> A.Type -> State CompState ()
  defVar n t = defineName (simpleName n) $ simpleDefDecl n t
  
  state :: State CompState ()
  state = do defVar "x" A.Int64
             defVar "b" A.Bool
             defVar "xu8" A.Byte
             defVar "xu16" A.UInt16
             defVar "xu32" A.UInt32
             defVar "xu64" A.UInt64
             defVar "x32" A.Int32
             defVar "x16" A.Int16
             defVar "x8" A.Int8

tests :: Test
tests = TestList
 [
  constantFoldTest
  ,annotateIntTest
  ,checkExpressionTest
 ]
