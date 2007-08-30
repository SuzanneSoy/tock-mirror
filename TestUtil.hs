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

module TestUtil where

import qualified AST as A
import Metadata (Meta,emptyMeta)
import Monad
import Test.HUnit hiding (State)
import Data.Generics
import Pattern
import TreeUtil
import Control.Monad.State
import Control.Monad.Error
import Pass
import CompState
import Utils
import qualified Data.Map as Map

m :: Meta
m = emptyMeta

--Helper function for creating an A.Name object:
simpleName :: String -> A.Name
simpleName s = A.Name { A.nameName = s , A.nameMeta = emptyMeta , A.nameType = A.VariableName }

procName :: String -> A.Name
procName s = A.Name { A.nameName = s , A.nameMeta = emptyMeta , A.nameType = A.ProcName }

typeName :: String -> A.Name
typeName s = A.Name { A.nameName = s , A.nameMeta = emptyMeta , A.nameType = A.DataTypeName }

simpleNamePattern :: String -> Pattern
simpleNamePattern s = tag3 A.Name DontCare A.VariableName s

procNamePattern :: String -> Pattern
procNamePattern s = tag3 A.Name DontCare A.ProcName s

variable :: String -> A.Variable
variable e = A.Variable emptyMeta $ simpleName e

variablePattern :: String -> Pattern
variablePattern e = tag2 A.Variable DontCare (simpleNamePattern e)

--Helper function for creating a simple variable name as an expression:
exprVariable :: String -> A.Expression
exprVariable e = A.ExprVariable emptyMeta $ variable e

-- | Creates an 'A.Expression' that has the 'A.ExprVariable' constructor with the given 'String' as the variable name in a 'A.DirectedVariable' with the given direction.
exprDirVariable :: A.Direction -> String -> A.Expression
exprDirVariable dir e = A.ExprVariable emptyMeta $ A.DirectedVariable emptyMeta dir $ variable e

exprVariablePattern :: String -> Pattern
exprVariablePattern e = tag2 A.ExprVariable DontCare $ variablePattern e

intLiteral :: Integer -> A.Expression
intLiteral n = A.Literal emptyMeta A.Int $ A.IntLiteral emptyMeta (show n)

intLiteralPattern :: Integer -> Pattern
intLiteralPattern = (stopCaringPattern emptyMeta) . mkPattern . intLiteral

makeNamesWR :: ([String],[String]) -> ([A.Variable],[A.Variable])
makeNamesWR (x,y) = (map variable x,map variable y)

makeSimpleAssign :: String -> String -> A.Process
makeSimpleAssign dest src = A.Assign emptyMeta [A.Variable emptyMeta $ simpleName dest] (A.ExpressionList emptyMeta [exprVariable src])

makeSimpleAssignPattern :: String -> String -> Pattern
makeSimpleAssignPattern lhs rhs = stopCaringPattern emptyMeta $ mkPattern $ makeSimpleAssign lhs rhs

makeSeq :: [A.Process] -> A.Process
makeSeq procList = A.Seq emptyMeta $ A.Several emptyMeta (map (\x -> A.OnlyP emptyMeta x) procList)

makePar :: [A.Process] -> A.Process
makePar procList = A.Par emptyMeta A.PlainPar $ A.Several emptyMeta (map (\x -> A.OnlyP emptyMeta x) procList)

makeRepPar :: A.Process -> A.Process
makeRepPar proc = A.Par emptyMeta A.PlainPar $ A.Rep emptyMeta (A.For emptyMeta (simpleName "i") (intLiteral 0) (intLiteral 3)) (A.OnlyP emptyMeta proc)

makeAssign :: A.Variable -> A.Expression -> A.Process
makeAssign v e = A.Assign emptyMeta [v] $ A.ExpressionList emptyMeta [e]

makeAssignPattern :: Pattern -> Pattern -> Pattern
makeAssignPattern v e = tag3 A.Assign DontCare [v] $ tag2 A.ExpressionList DontCare [e]
 
makeLiteralString :: String -> A.Expression
makeLiteralString str = A.Literal emptyMeta (A.Array [A.Dimension (length str)] A.Byte) (A.ArrayLiteral emptyMeta (map makeLiteralChar str))
  where
    makeLiteralChar :: Char -> A.ArrayElem
    makeLiteralChar c = A.ArrayElemExpr $ A.Literal emptyMeta A.Byte (A.ByteLiteral emptyMeta [c] {-(show (fromEnum c))-})

makeLiteralStringPattern :: String -> Pattern
makeLiteralStringPattern = (stopCaringPattern emptyMeta) . mkPattern . makeLiteralString

assertCompareCustom :: (Show a) => String -> (a -> a -> Bool) -> a -> a -> Assertion
assertCompareCustom  preface cmp expected actual =
  unless (cmp actual expected) (assertFailure msg)
 where msg = (if null preface then "" else preface ++ "\n") ++
             "expected: " ++ show expected ++ "\n*** got: " ++ show actual

assertNotEqual :: (Show a,Eq a) => String -> a -> a -> Assertion
assertNotEqual msg = assertCompareCustom msg (/=)

-- | Helper function that checks two items in the Items set (by two given keys) are not the same
assertItemNotSame :: String -> Items -> String -> String -> Assertion
assertItemNotSame msg items key0 key1 = assertNotEqual msg ((Map.lookup key0 items) :: Maybe AnyDataItem) ((Map.lookup key1 items) :: Maybe AnyDataItem)

-- | Helper function that checks if a looked-up value is what was expected
assertItemNotEqual :: Data a => String -> a -> Maybe AnyDataItem -> Assertion
assertItemNotEqual msg _ Nothing = assertFailure $ msg ++ " item not matched!"
--Putting x into ADI wrapper and using the Eq instance for AnyDataItem is easier than taking y out and checking the data types match:
assertItemNotEqual msg exp (Just act) = assertNotEqual msg (ADI exp) act

testPassGetItems :: (Data a, Data b) => String -> a -> PassM b -> (State CompState ()) -> IO (CompState, Either Assertion Items)
testPassGetItems testName expected actualPass startStateTrans = 
       --passResult :: Either String b
    do passResult <- runPass actualPass startState
       case passResult of
         (st,Left err) -> return (st, Left $ assertFailure (testName ++ "; pass actually failed: " ++ err) )
         (st,Right resultItem) -> return (st, transformEither (sequence_ . map (assertFailure . ((++) testName))) (id) $ getMatchedItems expected resultItem )
       where
         startState :: CompState
         startState = execState startStateTrans emptyState

runPass :: PassM b -> CompState -> IO (CompState, Either String b)
runPass actualPass startState = (liftM (\(x,y) -> (y,x))) (runStateT (runErrorT actualPass) startState)

testPass :: (Data a, Data b) => String -> a -> PassM b -> (State CompState ()) -> Test
--If Items are returned by testPassGetItems we return () [i.e. give an empty assertion], otherwise give back the assertion:
testPass w x y z = TestCase $ join $ liftM (either (id) (\x -> return ())) $ (liftM snd) $ (testPassGetItems w x y z)

testPassWithCheck :: (Data a, Data b) => String -> a -> PassM b -> (State CompState ()) -> (Items -> Assertion) -> Test
testPassWithCheck testName expected actualPass startStateTrans checkFunc = TestCase $
  ((liftM snd) (testPassGetItems testName expected actualPass startStateTrans))
  >>= (\res ->
    case res of 
      Left assert -> assert
      Right items -> checkFunc items
  )

testPassWithStateCheck :: (Data a, Data b) => String -> a -> PassM b -> (State CompState ()) -> (CompState -> Assertion) -> Test
testPassWithStateCheck testName expected actualPass startStateTrans checkFunc = TestCase $
  (testPassGetItems testName expected actualPass startStateTrans)
  >>= (\x ->
    case x of 
      (_,Left assert) -> assert
      (st,Right _) -> checkFunc st
  )

testPassWithItemsStateCheck :: (Data a, Data b) => String -> a -> PassM b -> (State CompState ()) -> ((Items,CompState) -> Assertion) -> Test
testPassWithItemsStateCheck testName expected actualPass startStateTrans checkFunc = TestCase $
  (testPassGetItems testName expected actualPass startStateTrans)
  >>= (\x ->
    case x of 
      (_,Left assert) -> assert
      (st,Right items) -> checkFunc (items,st)
  )
  
testPassShouldFail :: (Show b, Data b) => String -> PassM b -> (State CompState ()) -> Test
testPassShouldFail testName actualPass startStateTrans = TestCase $
    do ret <- runPass actualPass (execState startStateTrans emptyState)
       case ret of
         (_,Left err) -> return ()
         _ -> assertFailure $ testName ++ " pass succeeded when expected to fail, data: " ++ (show ret)


assertVarDef :: Data a => String -> CompState -> String -> a -> Assertion
assertVarDef prefix state varName varDef 
  = case (Map.lookup varName (csNames state)) of
      Nothing -> assertFailure $ prefix ++ " variable was not recorded: " ++ varName
      Just actVarDef -> assertPatternMatch (prefix ++ " variable definition not as expected for " ++ varName) varDef actVarDef
