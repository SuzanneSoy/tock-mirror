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

-- #ignore-exports

-- | Tests for the C and C++ backends
--
-- The testing strategy is as follows.  The way we have implemented the C and C++ backends is 
-- to have a dictionary of functions 'GenerateC.GenOps' that is used for (mutually) recursive
-- calls.  We can take advantage of this during testing.  For example, we have a test that
-- tests genArraySubscript directly.  When we test genVariableChecked, we don't want to have
-- to effectively check parts of genArraySubscript again.  So we can \"override\" the
-- genArraySubscript to return a dummy value, and then we are effectively testing 
-- that genVariableChecked calls genArraySubscript at the appropriate point.  This is similar
-- to a testing technique in OOP where one might take a class and override some methods to
-- do a similar trick.
module GenerateCTest (tests) where

import Control.Monad.Error
import Control.Monad.State
import Control.Monad.Writer
import Data.List (isInfixOf, intersperse)
import Data.Maybe (fromMaybe)
import Test.HUnit hiding (State)
import Text.Regex

import qualified AST as A
import CompState
import Errors
import GenerateC
import GenerateCPPCSP
import Metadata
import Pattern
import TestUtil
import TreeUtil

at :: CGen ()
at = tell ["@"]

dollar :: CGen ()
dollar = tell ["$"]

caret :: CGen ()
caret = tell ["^"]

hash :: CGen ()
hash = tell ["#"]

foo :: A.Name
foo = simpleName "foo"

bar:: A.Name
bar = simpleName "bar"

-- | Asserts that the given output of a CGen pass matches the expected value.
assertGen :: String -> String -> IO (Either Errors.ErrorReport [String]) -> Assertion
assertGen n exp act
      = do r <- act 
           case r of 
             Left (_,err) -> assertFailure $ n ++ " pass failed, error: " ++ err
             Right ss -> assertEqual n exp (subRegex (mkRegex "/\\*\\*/") (concat ss) "")

-- | Asserts that the given output of a CGen pass matches the expected regex
assertGenR :: String -> String -> IO (Either Errors.ErrorReport [String]) -> IO [String]
assertGenR n exp act
      = do r <- act 
           case r of 
             Left (_,err) -> (assertFailure $ n ++ " pass failed, error: " ++ err) >> return []
             Right ss ->
               case matchRegex (mkRegex exp) (subRegex (mkRegex "/\\*\\*/") (concat ss) "") of
                 Just matches -> return matches
                 Nothing -> (assertFailure $ n ++ " regex match failed, regex: \"" ++ exp ++ "\" text: " ++ (concat ss)) >> return []


-- | Asserts that the given output of a CGen pass is a failure
assertGenFail :: String -> IO (Either Errors.ErrorReport [String]) -> Assertion
assertGenFail n act
      = do r <- act 
           case r of 
             Left _ -> return ()
             Right ss -> if isInfixOf "#error" (concat ss)
                           then return ()
                           else assertFailure $ n ++ " pass succeeded when expected to fail, output: " ++ (subRegex (mkRegex "/\\*\\*/") (concat ss) "")


testBothS :: 
  String -- ^ Test Name
  -> String -- ^ C expected
  -> String -- ^ C++ expected
  -> (GenOps -> CGen ()) -- ^ Actual
  -> (State CompState ()) -- ^ State transformation  
  -> Test
  
testBothS testName expC expCPP act startState = TestList
   [TestCase $ assertGen (testName ++ "/C") expC $ (evalStateT (runErrorT (execWriterT $ act cgenOps)) state) 
   ,TestCase $ assertGen (testName ++ "/C++") expCPP $ (evalStateT (runErrorT (execWriterT $ act cppgenOps)) state) ]
  where
    state = execState startState emptyState

testBothFailS :: String -> (GenOps -> CGen ()) -> (State CompState ()) -> Test
testBothFailS testName act startState = TestList
   [TestCase $ assertGenFail (testName ++ "/C") (evalStateT (runErrorT (execWriterT $ act cgenOps)) state)
   ,TestCase $ assertGenFail (testName ++ "/C++") (evalStateT (runErrorT (execWriterT $ act cppgenOps)) state) ]
  where
    state = execState startState emptyState

testRS :: String -> String -> CGen () -> State CompState () -> IO [String]
testRS testName exp act startState = assertGenR testName exp (evalStateT (runErrorT (execWriterT act)) state)
  where
    state = execState startState emptyState

-- Tests C output, expects C++ to fail
testCFS :: String -> String -> (GenOps -> CGen ()) -> (State CompState ()) -> Test
testCFS testName expC act startState = TestCase $
  do assertGen (testName ++ "/C") expC $ (evalStateT (runErrorT (execWriterT $ act cgenOps)) state)
     assertGenFail (testName ++ "/C++") (evalStateT (runErrorT (execWriterT $ act cppgenOps)) state)
  where
    state = execState startState emptyState
    
-- Tests C++ output, expects C to fail
testCPPFS :: String -> String -> (GenOps -> CGen ()) -> (State CompState ()) -> Test
testCPPFS testName expCPP act startState = TestCase $
  do assertGenFail (testName ++ "/C") (evalStateT (runErrorT (execWriterT $ act cgenOps)) state)
     assertGen (testName ++ "/C++") expCPP $ (evalStateT (runErrorT (execWriterT $ act cppgenOps)) state)
  where
    state = execState startState emptyState    

testBothSameS :: 
  String    -- ^ Test Name
  -> String -- ^ C and C++ expected
  -> (GenOps -> CGen ()) -- ^ Actual
  -> (State CompState ()) -- ^ State transformation
  -> Test
testBothSameS n e a s = testBothS n e e a s

testBothR :: 
  String    -- ^ Test Name
  -> String -- ^ C expected
  -> String -- ^ C++ expected
  -> (GenOps -> CGen ()) -- ^ Actual
  -> Test
testBothR n eC eCPP a = TestList [TestCase $ (testRS n eC (a cgenOps) (return ())) >> return (), TestCase $ (testRS n eCPP (a cppgenOps) (return ())) >> (return ())]

testBothSameR :: String -> String -> (GenOps -> CGen ()) -> Test
testBothSameR n e a = testBothR n e e a

testBothFail :: String -> (GenOps -> CGen ()) -> Test
testBothFail a b = testBothFailS a b (return ())
  
testBoth :: String -> String -> String -> (GenOps -> CGen ()) -> Test
testBoth a b c d = testBothS a b c d (return ())

testBothSame :: String -> String -> (GenOps -> CGen ()) -> Test
testBothSame a b c = testBothSameS a b c (return ())
  
testCF :: String -> String -> (GenOps -> CGen ()) -> Test
testCF a b c = testCFS a b c (return ())

testCPPF :: String -> String -> (GenOps -> CGen ()) -> Test
testCPPF a b c = testCPPFS a b c (return ())
  
tcall :: (GenOps -> GenOps -> a -> b) -> a -> (GenOps -> b)
tcall f x = (\o -> f o o x)

tcall2 :: (GenOps -> GenOps -> a0 -> a1 -> b) -> a0 -> a1 -> (GenOps -> b)
tcall2 f x y = (\o -> f o o x y)

tcall3 :: (GenOps -> GenOps -> a0 -> a1 -> a2 -> b) -> a0 -> a1 -> a2 -> (GenOps -> b)
tcall3 f x y z = (\o -> f o o x y z)

-- | Overrides a specified function in GenOps to return the given value
override1 ::
  b -- ^ The value to return for the overridden function
  -> (GenOps -> a -> b) -- ^ The resulting overriden function
override1 val = (\_ _ -> val)

override2 :: b -> (GenOps -> a0 -> a1 -> b)
override2 val = (\_ _ _ -> val)

override3 :: b -> (GenOps -> a0 -> a1 -> a2 -> b)
override3 val = (\_ _ _ _ -> val)

testGenType :: Test
testGenType = TestList 
 [
  testBothSame "GenType 0" "uint8_t" (tcall genType A.Byte) 
  ,testBothSame "GenType 1" "uint16_t" (tcall genType A.UInt16) 
  ,testBothSame "GenType 2" "uint32_t" (tcall genType A.UInt32) 
  ,testBothSame "GenType 3" "uint64_t" (tcall genType A.UInt64) 
  ,testBothSame "GenType 4" "int8_t" (tcall genType A.Int8) 
  ,testBothSame "GenType 5" "int16_t" (tcall genType A.Int16) 
  ,testBothSame "GenType 6" "int32_t" (tcall genType A.Int32) 
  ,testBothSame "GenType 7" "int64_t" (tcall genType A.Int64) 
  ,testBothSame "GenType 8" "int" (tcall genType A.Int) 
  ,testBoth "GenType 9" "bool" "tockBool" (tcall genType A.Bool) 
  ,testBothSame "GenType 10" "float" (tcall genType A.Real32) 
  ,testBothSame "GenType 11" "double" (tcall genType A.Real64) 
  ,testBoth "GenType 100" "int*" "tockArrayView<int,1>" (tcall genType $ A.Array [A.Dimension 5] A.Int) 
  ,testBoth "GenType 101" "int*" "tockArrayView<int,3>" (tcall genType $ A.Array [A.Dimension 5, A.Dimension 2, A.Dimension 9] A.Int) 
  ,testBoth "GenType 102" "int*" "tockArrayView<int,2>" (tcall genType $ A.Array [A.Dimension 5, A.UnknownDimension] A.Int) 
  ,testBothSame "GenType 103" "foo" (tcall genType $ A.Record (simpleName "foo")) 
  ,testBoth "GenType 200" "Time" "csp::Time" (tcall genType A.Time) 
  ,testBoth "GenType 201" "Time" "csp::Time" (tcall genType A.Timer) 

  ,testBoth "GenType 300" "Channel" "csp::One2OneChannel<int>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int) 
  ,testBoth "GenType 301" "Channel" "csp::One2AnyChannel<int>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes False True) A.Int) 
  ,testBoth "GenType 302" "Channel" "csp::Any2OneChannel<int>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes True False) A.Int) 
  ,testBoth "GenType 303" "Channel" "csp::Any2AnyChannel<int>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes True True) A.Int) 
  
  ,testBoth "GenType 400" "Channel*" "csp::Chanin<int>" (tcall genType $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int) 
  ,testBoth "GenType 401" "Channel*" "csp::Chanin<int>" (tcall genType $ A.Chan A.DirInput (A.ChanAttributes False True) A.Int) 

  ,testBoth "GenType 402" "Channel*" "csp::Chanout<int>" (tcall genType $ A.Chan A.DirOutput (A.ChanAttributes False False) A.Int) 
  ,testBoth "GenType 403" "Channel*" "csp::Chanout<int>" (tcall genType $ A.Chan A.DirOutput (A.ChanAttributes True False) A.Int) 
  
  --ANY and protocols cannot occur outside channels in C++ or C, they are tested here:
  ,testBothFail "GenType 500" (tcall genType $ A.Any) 
  ,testBothFail "GenType 600" (tcall genType $ A.UserProtocol (simpleName "foo")) 
  ,testBothFail "GenType 650" (tcall genType $ A.Counted A.Int A.Int) 
   
  ,testBoth "GenType 700" "Channel*" "tockArrayView<csp::One2OneChannel<int>,1>" (tcall genType $ A.Array [A.Dimension 5] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int)
  ,testBoth "GenType 701" "Channel**" "tockArrayView<csp::Chanin<int>,1>" (tcall genType $ A.Array [A.Dimension 5] $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int)
  
  --Test types that can only occur inside channels:
  --ANY:
  ,testBoth "GenType 800" "Channel" "csp::One2OneChannel<tockSendableArrayOfBytes>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Any)
  --Protocol:
  ,testBoth "GenType 900" "Channel" "csp::One2OneChannel<tockSendableArrayOfBytes>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes False False) $ A.UserProtocol (simpleName "foo"))
  --Counted:
  ,testBoth "GenType 1000" "Channel" "csp::One2OneChannel<tockSendableArrayOfBytes>" (tcall genType $ A.Chan A.DirUnknown (A.ChanAttributes False False) $ A.Counted A.Int A.Int)

 ]

testStop :: Test
testStop =
  testBoth "Stop" "occam_stop(\"foo:4:9\",\"bar\");" "throw StopException(\"foo:4:9\" \"bar\");" (tcall2 genStop (Meta (Just "foo") 4 9) "bar") 

testArraySizes :: Test
testArraySizes = TestList
 [
  testBoth "genArraySizesLiteral 0" "{3}" "tockArrayView<int,1>(foo_actual,tockDims(3))" (tcall2 genArraySizesLiteral foo $ A.Array [A.Dimension 3] A.Int) 
  ,testBoth "genArraySizesLiteral 1" "{3,6,8}" "tockArrayView<int,3>(foo_actual,tockDims(3,6,8))" (tcall2 genArraySizesLiteral foo $ A.Array [A.Dimension 3, A.Dimension 6, A.Dimension 8] A.Int) 
  ,testBothFail "genArraySizesLiteral 2" (tcall2 genArraySizesLiteral foo $ A.Array [A.Dimension 6, A.UnknownDimension] A.Int) 
  ,testBothSame "genArraySize 0" "const int*foo_sizes=@;" (tcall3 genArraySize True at foo)
  ,testBothSame "genArraySize 1" "const int foo_sizes[]=@;" (tcall3 genArraySize False at foo)
  ,testBothSame "genArrayLiteralElems 0" "$" $ (tcall genArrayLiteralElems [A.ArrayElemExpr undefined]) . unfolded
  ,testBothSame "genArrayLiteralElems 1" "$,$,$" $ (tcall genArrayLiteralElems [A.ArrayElemExpr undefined, A.ArrayElemExpr undefined, A.ArrayElemExpr undefined]) . unfolded
  ,testBothSame "genArrayLiteralElems 2" "$,$,$" $ (tcall genArrayLiteralElems [A.ArrayElemExpr undefined, A.ArrayElemArray [A.ArrayElemExpr undefined, A.ArrayElemExpr undefined]]) . unfolded
 ]
 where
  unfolded = (\ops -> ops {genUnfoldedExpression = override1 dollar})

testActuals :: Test
testActuals = TestList
 [
  -- C adds a prefix comma (to follow Process* me) but C++ does not:
  testBoth "genActuals 0" ",@,@" "@,@" $ (tcall genActuals [undefined, undefined]) . (\ops -> ops {genActual = override1 at})
  ,testBothSame "genActuals 1" "" $ (tcall genActuals [])
  
  --For expressions, genExpression should be called:
  ,testBothSame "genActual 0" "$" $ (tcall genActual $ A.ActualExpression A.Bool (A.True undefined)) . over
  
  --For abbreviating arrays, C++ should call genExpression/genVariable, whereas C should do its foo,foo_sizes thing:
  ,testBoth "genActual 1" "@,@_sizes" "$" $ (tcall genActual $ A.ActualExpression (A.Array undefined undefined) (A.ExprVariable undefined $ A.Variable undefined foo)) . over
  ,testBoth "genActual 2" "@,@_sizes" "@" $ (tcall genActual $ A.ActualVariable A.Abbrev (A.Array undefined undefined) (A.Variable undefined foo)) . over
 ]
 where
   over = (\ops -> ops {genVariable = override1 at, genExpression = override1 dollar})
   
testArraySubscript :: Test
testArraySubscript = TestList
 [
  testBothS "genArraySubscript 0" "[5*foo_sizes[1]*foo_sizes[2]]" "[5]"
    (tcall3 genArraySubscript False (A.Variable emptyMeta foo) [intLiteral 5]) stateTrans
  ,testBothS "genArraySubscript 1" "[5*foo_sizes[1]*foo_sizes[2]+6*foo_sizes[2]]" "[5][6]"
    (tcall3 genArraySubscript False (A.Variable emptyMeta foo) [intLiteral 5, intLiteral 6]) stateTrans
  ,testBothS "genArraySubscript 2" "[5*foo_sizes[1]*foo_sizes[2]+6*foo_sizes[2]+7]" "[5][6][7].access()"
    (tcall3 genArraySubscript False (A.Variable emptyMeta foo) [intLiteral 5, intLiteral 6, intLiteral 7]) stateTrans
  
  ,testBothS "genArraySubscript 3" ("[occam_check_index(5,foo_sizes[0]," ++ m ++ ")*foo_sizes[1]*foo_sizes[2]]") ("[occam_check_index(5,foo.extent(0)," ++ m ++ ")]")
    (tcall3 genArraySubscript True (A.Variable emptyMeta foo) [intLiteral 5]) stateTrans
  ,testBothS "genArraySubscript 4"
    ("[occam_check_index(5,foo_sizes[0]," ++ m ++ ")*foo_sizes[1]*foo_sizes[2]+occam_check_index(6,foo_sizes[1]," ++ m ++ ")*foo_sizes[2]]")
    ("[occam_check_index(5,foo.extent(0)," ++ m ++ ")][occam_check_index(6,foo.extent(1)," ++ m ++ ")]")
    (tcall3 genArraySubscript True (A.Variable emptyMeta foo) [intLiteral 5, intLiteral 6]) stateTrans
  ,testBothS "genArraySubscript 5"
    ("[occam_check_index(5,foo_sizes[0]," ++ m ++ ")*foo_sizes[1]*foo_sizes[2]+occam_check_index(6,foo_sizes[1]," ++ m ++ ")*foo_sizes[2]+occam_check_index(7,foo_sizes[2]," ++ m ++ ")]")
    ("[occam_check_index(5,foo.extent(0)," ++ m ++ ")][occam_check_index(6,foo.extent(1)," ++ m ++ ")][occam_check_index(7,foo.extent(2)," ++ m ++ ")].access()")
    (tcall3 genArraySubscript True (A.Variable emptyMeta foo) [intLiteral 5, intLiteral 6, intLiteral 7]) stateTrans
    
 ]
 where
   stateTrans = defineName (simpleName "foo") $ simpleDefDecl "foo" (A.Array [A.Dimension 7,A.Dimension 8,A.Dimension 8] A.Int)
   m = "\"" ++ show emptyMeta ++ "\""

testOverArray :: Test
testOverArray = TestList $ map testOverArray'
  [(cSize,cIndex,"",cgenOps)
  ,((\n -> "\\.extent\\(" ++ show n ++ "\\)"),cppIndex,"\\.access\\(\\)",cppgenOps)
  ]
  where
    cSize n = "_sizes\\[" ++ show n ++ "\\]"

    cppIndex = concat . (map cppIndex')
    cppIndex' :: (String,[Int]) -> String
    cppIndex' (s,_) = "\\[" ++ s ++ "\\]"

    cIndex x = "\\[" ++ concat (intersperse "\\+" $ map cIndex' x) ++ "\\]"
    cIndex' :: (String,[Int]) -> String
    cIndex' (s,ns) = s ++ concat (map (\n -> "\\*foo" ++ cSize n) ns)

    testOverArray' :: ((Int -> String),[(String,[Int])] -> String,String,GenOps) -> Test
    testOverArray' (sz,f',suff,ops) = TestCase $
      do testRS "testOverArray'" rx1 (tcall3 genOverArray emptyMeta (A.Variable emptyMeta foo) func ops) state1
         testRS "testOverArray'" rx3 (tcall3 genOverArray emptyMeta (A.Variable emptyMeta foo) func ops) state3
         return ()
      where
        func f = Just $ call genVariableUnchecked ops (f $ A.Variable emptyMeta foo) >> tell [";"]
        rx1 = "^for\\(int ([[:alnum:]_]+)=0;\\1<foo" ++ sz 0 ++ ";\\1\\+\\+)\\{foo\\[\\1\\]" ++ suff ++ ";\\}$"
        rx3 = "^for\\(int ([[:alnum:]_]+)=0;\\1<foo" ++ sz 0 ++ ";\\1\\+\\+)\\{" ++
              "for\\(int ([[:alnum:]_]+)=0;\\2<foo" ++ sz 1 ++ ";\\2\\+\\+)\\{" ++
              "for\\(int ([[:alnum:]_]+)=0;\\3<foo" ++ sz 2 ++ ";\\3\\+\\+)\\{" ++
              "foo" ++ (f' [("\\1",[1,2]),("\\2",[2]),("\\3",[])]) ++ suff ++ ";\\}\\}\\}$"
        state1 = defineName (simpleName "foo") $ simpleDefDecl "foo" (A.Array [A.Dimension 7] A.Int)
        state3 = defineName (simpleName "foo") $ simpleDefDecl "foo" (A.Array [A.Dimension 7, A.Dimension 8, A.Dimension 9] A.Int)

testReplicator :: Test
testReplicator = TestList
 [
  testBothSame "testReplicator 0" "for(int foo=0;foo<10;foo++){@}" (tcall2 genReplicator (A.For emptyMeta foo (intLiteral 0) (intLiteral 10)) at)
  ,testBothSameR "testReplicator 1" "for\\(int ([[:alnum:]_]+)=10,foo=1;\\1>0;\\1--,foo\\+\\+\\)\\{@\\}" (tcall2 genReplicator (A.For emptyMeta foo (intLiteral 1) (intLiteral 10)) at)
 ]

testDeclaration :: Test
testDeclaration = TestList
 [
  --Simple: 
  testBothSame "genDeclaration 0" "int foo;" (tcall3 genDeclaration A.Int foo False)
  
  --Channels and channel-ends:
  ,testBoth "genDeclaration 1" "Channel foo;" "csp::One2OneChannel<int> foo;" (tcall3 genDeclaration (A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int) foo False)
  ,testBoth "genDeclaration 2" "Channel foo;" "csp::Any2OneChannel<int> foo;" (tcall3 genDeclaration (A.Chan A.DirUnknown (A.ChanAttributes True False) A.Int) foo False)
  ,testBoth "genDeclaration 3" "Channel foo;" "csp::One2AnyChannel<int> foo;" (tcall3 genDeclaration (A.Chan A.DirUnknown (A.ChanAttributes False True) A.Int) foo False)
  ,testBoth "genDeclaration 4" "Channel foo;" "csp::Any2AnyChannel<int> foo;" (tcall3 genDeclaration (A.Chan A.DirUnknown (A.ChanAttributes True True) A.Int) foo False)
  ,testBoth "genDeclaration 5" "Channel* foo;" "csp::Chanin<int> foo;" (tcall3 genDeclaration (A.Chan A.DirInput (A.ChanAttributes False False) A.Int) foo False)
  ,testBoth "genDeclaration 6" "Channel* foo;" "csp::Chanin<int> foo;" (tcall3 genDeclaration (A.Chan A.DirInput (A.ChanAttributes False True) A.Int) foo False)
  ,testBoth "genDeclaration 7" "Channel* foo;" "csp::Chanout<int> foo;" (tcall3 genDeclaration (A.Chan A.DirOutput (A.ChanAttributes False False) A.Int) foo False)
  ,testBoth "genDeclaration 8" "Channel* foo;" "csp::Chanout<int> foo;" (tcall3 genDeclaration (A.Chan A.DirOutput (A.ChanAttributes True False) A.Int) foo False)  
  
  --Arrays (of simple):
  ,testBoth "genDeclaration 100" "int foo[8];const int foo_sizes[]={8};" "int foo_actual[8];const tockArrayView<int,1> foo=tockArrayView<int,1>(foo_actual,tockDims(8));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8] A.Int) foo False)
  ,testBoth "genDeclaration 101" "int foo[8*9];const int foo_sizes[]={8,9};" "int foo_actual[8*9];const tockArrayView<int,2> foo=tockArrayView<int,2>(foo_actual,tockDims(8,9));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8,A.Dimension 9] A.Int) foo False)
  ,testBoth "genDeclaration 102" "int foo[8*9*10];const int foo_sizes[]={8,9,10};" "int foo_actual[8*9*10];const tockArrayView<int,3> foo=tockArrayView<int,3>(foo_actual,tockDims(8,9,10));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8,A.Dimension 9,A.Dimension 10] A.Int) foo False)

  --Arrays (of simple) inside records:
  ,testBoth "genDeclaration 110" "int foo[8];int foo_sizes[1];" "int foo_actual[8];tockArrayView<int,1> foo;"
    (tcall3 genDeclaration (A.Array [A.Dimension 8] A.Int) foo True)
  ,testBoth "genDeclaration 111" "int foo[8*9];int foo_sizes[2];" "int foo_actual[8*9];tockArrayView<int,2> foo;"
    (tcall3 genDeclaration (A.Array [A.Dimension 8,A.Dimension 9] A.Int) foo True)
  ,testBoth "genDeclaration 112" "int foo[8*9*10];int foo_sizes[3];" "int foo_actual[8*9*10];tockArrayView<int,3> foo;"
    (tcall3 genDeclaration (A.Array [A.Dimension 8,A.Dimension 9,A.Dimension 10] A.Int) foo True)
  
  --Arrays of channels and channel-ends:
  ,testBoth "genDeclaration 200" "Channel foo[8];const int foo_sizes[]={8};"
    "csp::One2OneChannel<int> foo_actual[8];const tockArrayView<csp::One2OneChannel<int>,1> foo=tockArrayView<csp::One2OneChannel<int>,1>(foo_actual,tockDims(8));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int) foo False)

  ,testBoth "genDeclaration 201" "Channel foo[8*9];const int foo_sizes[]={8,9};"
    "csp::One2OneChannel<int> foo_actual[8*9];const tockArrayView<csp::One2OneChannel<int>,2> foo=tockArrayView<csp::One2OneChannel<int>,2>(foo_actual,tockDims(8,9));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8, A.Dimension 9] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int) foo False)
    
  ,testBoth "genDeclaration 202" "Channel* foo[8];const int foo_sizes[]={8};"
    "csp::Chanin<int> foo_actual[8];const tockArrayView<csp::Chanin<int>,1> foo=tockArrayView<csp::Chanin<int>,1>(foo_actual,tockDims(8));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8] $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int) foo False)

  ,testBoth "genDeclaration 203" "Channel* foo[8*9];const int foo_sizes[]={8,9};"
    "csp::Chanout<int> foo_actual[8*9];const tockArrayView<csp::Chanout<int>,2> foo=tockArrayView<csp::Chanout<int>,2>(foo_actual,tockDims(8,9));"
    (tcall3 genDeclaration (A.Array [A.Dimension 8, A.Dimension 9] $ A.Chan A.DirOutput (A.ChanAttributes False False) A.Int) foo False)
    
    
  --Records of simple:
  ,testBothSameS "genDeclaration 300" "REC foo;" (tcall3 genDeclaration (A.Record $ simpleName "REC") foo False) (stateR A.Int)
  
  --Records of arrays of int (the sizes are set by declareInit):
  ,testBothSameS "genDeclaration 400" "REC foo;" (tcall3 genDeclaration (A.Record $ simpleName "REC") foo False) (stateR $ A.Array [A.Dimension 8] A.Int)
 ]
 where
   stateR t = defRecord "REC" "bar" t

testDeclareInitFree :: Test
testDeclareInitFree = TestList
 [
  -- Plain type:
  testAllSame 0 ("","") A.Int
  
  -- Channel types:
  ,testAll 1 ("ChanInit((&foo));","") ("","") $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int
  ,testAllSame 2 ("","") $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int
  
  -- Plain arrays:
  ,testAllSame 3 ("","") $ A.Array [A.Dimension 4] A.Int
  
  -- Channel arrays:
  ,testAll 4 ("^ChanInit((&foo[0]));^","") ("","") $ A.Array [A.Dimension 4] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int
  ,testAllSame 5 ("","") $ A.Array [A.Dimension 4] $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int
  
  -- Plain records:
  ,testAllR 100 ("","") ("","") A.Int
  -- Records containing an array:
  ,testAllR 101 ("(&foo)->bar_sizes[0]=4;(&foo)->bar_sizes[1]=5;","") ("(&foo)->bar=tockArrayView((&foo)->bar_actual,tockDims(4,5));","") $ A.Array [A.Dimension 4,A.Dimension 5] A.Int
  -- Arrays of records containing an array:
  ,testAllRA 200 ("^(&foo[0])->bar_sizes[0]=4;(&foo[0])->bar_sizes[1]=5;^","") ("^(&foo[0].access())->bar=tockArrayView((&foo[0].access())->bar_actual,tockDims(4,5));^","") $ A.Array [A.Dimension 4,A.Dimension 5] A.Int
 ]
 where
   testAll :: Int -> (String,String) -> (String,String) -> A.Type -> Test
   testAll n eC eCPP t = testAll' n eC eCPP t (defineName (simpleName "foo") $ simpleDefDecl "foo" t)
   
   testAllR :: Int -> (String,String) -> (String,String) -> A.Type -> Test
   testAllR n eC eCPP t = testAll' n eC eCPP (A.Record $ simpleName "REC") $ (defRecord "REC" "bar" t) >> (defineName (simpleName "foo") $ simpleDefDecl "foo" $ A.Record (simpleName "REC"))

   testAllRA :: Int -> (String,String) -> (String,String) -> A.Type -> Test
   testAllRA n eC eCPP t = testAll' n eC eCPP (A.Array [A.Dimension 5] $ A.Record $ simpleName "REC") $ (defRecord "REC" "bar" t) >> (defineName (simpleName "foo") $ simpleDefDecl "foo" $ A.Array [A.Dimension 5] $ A.Record (simpleName "REC"))

   testAll' :: Int -> (String,String) -> (String,String) -> A.Type -> State CompState () -> Test
   testAll' n (iC,fC) (iCPP,fCPP) t state = TestList
    [
     testBothS ("testDeclareInitFree/a" ++ show n) ("@" ++ iC) ("@" ++ iCPP) ((tcall introduceSpec $ A.Specification emptyMeta foo (A.Declaration emptyMeta t)) . over) state
     ,testBothS ("testDeclareInitFree/b" ++ show n) iC iCPP ((fromMaybe (return ())) . (tcall3 declareInit emptyMeta t (A.Variable emptyMeta foo)) . over) state
     ,testBothS ("testDeclareInitFree/c" ++ show n) fC fCPP ((tcall removeSpec $ A.Specification emptyMeta foo (A.Declaration emptyMeta t)) . over) state
     ,testBothS ("testDeclareInitFree/d" ++ show n) fC fCPP ((fromMaybe (return ())) . (tcall3 declareFree emptyMeta t (A.Variable emptyMeta foo)) . over) state
    ]
     where
       overArray _ _ v f = case f (\v -> A.SubscriptedVariable emptyMeta (A.Subscript emptyMeta $ intLiteral 0) v) of
         Just p -> caret >> p >> caret
         Nothing -> return ()
       over ops = ops {genDeclaration = override3 at, genOverArray = overArray}

   testAllSame :: Int -> (String,String) -> A.Type -> Test
   testAllSame n e t = testAll n e e t

testSpec :: Test
testSpec = TestList
 [
  --Declaration:
  testAllSame 0 ("#ATION_False#INIT","#FREE") $ A.Declaration emptyMeta A.Int
  ,testAllSame 1 ("#ATION_False#INIT","#FREE") $ A.Declaration emptyMeta $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int
  ,testAllSame 2 ("#ATION_False#INIT","#FREE") $ A.Declaration emptyMeta $ A.Array [A.Dimension 3] A.Int
  ,testAllSame 3 ("#ATION_False#INIT","#FREE") $ A.Declaration emptyMeta $ A.Array [A.Dimension 3] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int

  --Empty/failure cases:
  ,testAllSame 100 ("","") $ A.DataType undefined undefined
  ,testBothFail "testAllSame 200" (tcall introduceSpec $ A.Specification emptyMeta foo $ A.RetypesExpr emptyMeta A.Original A.Int (A.True emptyMeta))
  ,testBothFail "testAllSame 300" (tcall introduceSpec $ A.Specification emptyMeta foo $ A.Place emptyMeta (A.True emptyMeta))
  ,testAllSame 350 ("","") $ A.Protocol emptyMeta undefined

  --Record types:
  ,testAllSame 400 ("typedef struct{#ATION_True}foo;","") $ A.RecordType emptyMeta False [(bar,A.Int)] 
  ,testAllSame 401 ("typedef struct{#ATION_True#ATION_True} occam_struct_packed foo;","") $ A.RecordType emptyMeta True [(bar,A.Int),(bar,A.Int)] 
  ,testAll 402 ("typedef struct{#ATION_True}foo;","") ("typedef struct{#ATION_True}foo;","")$ A.RecordType emptyMeta False [(bar,A.Array [A.Dimension 6, A.Dimension 7] A.Int)]

  --IsChannelArray:
  ,testAll 500 
    ("$(" ++ show chanInt ++ ")*foo[]={@,@};const int foo_sizes[]={2};","")
    ("$(" ++ show chanInt ++ ")*foo_actual[]={@,@};const $(" ++ show (A.Array [A.Dimension 2] $ chanInt) ++ ") foo=$("
      ++  show (A.Array [A.Dimension 2] $ chanInt) ++ ")(foo_actual,tockDims(2));","")
    $ A.IsChannelArray emptyMeta (A.Array [A.Dimension 2] $ chanInt) 
    [A.Variable undefined undefined,A.Variable undefined undefined]

  --Is:
  
  -- Plain types require you to take an address to get the pointer:
  ,testAllSameForTypes 600 (\t -> ("$(" ++ show t ++ ")*const foo=&@;","")) (\t -> A.Is emptyMeta A.Abbrev t (A.Variable undefined undefined)) [A.Int,A.Time]
  -- Arrays and records are already pointers, so no need to take the address:
  ,testAllSameForTypes 610 (\t -> ("$(" ++ show t ++ ")*const foo=@;","")) (\t -> A.Is emptyMeta A.Abbrev t (A.Variable undefined undefined)) [chanInt,A.Record foo]
  --Abbreviations of channel-ends in C++ should just copy the channel-end, rather than trying to take the address of the temporary returned by writer()/reader()
  --C abbreviations will be of type Channel*, so they can just copy the channel address.
  ,testAllSameForTypes 620 (\t -> ("$(" ++ show t ++ ") foo=@;","")) (\t -> A.Is emptyMeta A.Abbrev t (A.Variable undefined undefined)) [chanIntIn,chanIntOut]
  
  ,testAllSameForTypes 700 (\t -> ("const $(" ++ show t ++ ") foo=@;","")) (\t -> A.Is emptyMeta A.ValAbbrev t (A.Variable undefined undefined)) [A.Int,A.Time]
  ,testAllSameForTypes 710 (\t -> ("const $(" ++ show t ++ ")*const foo=@;","")) (\t -> A.Is emptyMeta A.ValAbbrev t (A.Variable undefined undefined)) [A.Record foo]
  -- I don't think ValAbbrev of channels/channel-ends makes much sense (occam doesn't support it, certainly) so they are not tested here.
  
  --TODO test Is more (involving subscripts, arrays and slices)

  --ProtocolCase:
  ,testAllSame 800 ("typedef enum{empty_protocol_foo}foo;","") $ A.ProtocolCase emptyMeta []
  ,testAllSame 801 ("typedef enum{bar_foo}foo;","") $ A.ProtocolCase emptyMeta [(bar,[])]
  ,testAllSame 802 ("typedef enum{bar_foo,wibble_foo}foo;","") $ A.ProtocolCase emptyMeta [(bar,[]),(simpleName "wibble",[])]
  
  
  --TODO IsExpr
  --TODO Proc
  --TODO Retypes
 ]
  where
    testAllSameForTypes :: Int -> (A.Type -> (String, String)) -> (A.Type -> A.SpecType) -> [A.Type] -> Test
    testAllSameForTypes n te spec ts = TestList [testAllSame (n+i) (te t) (spec t) | (i,t) <- zip [0..] ts]
  
    chanInt = A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int
    chanIntIn = A.Chan A.DirInput (A.ChanAttributes False False) A.Int
    chanIntOut = A.Chan A.DirOutput (A.ChanAttributes False False) A.Int
  
    testAll :: Int -> (String,String) -> (String,String) -> A.SpecType -> Test
    testAll n (eCI,eCR) (eCPPI,eCPPR) spec = TestList
     [
      testBoth ("testSpec " ++ show n) eCI eCPPI ((tcall introduceSpec $ A.Specification emptyMeta foo spec) . over)
      ,testBoth ("testSpec " ++ show n) eCR eCPPR ((tcall removeSpec $ A.Specification emptyMeta foo spec) . over)
     ]
    testAllSame n e s = testAll n e e s
    over ops = ops {genDeclaration = override2 (tell . (\x -> ["#ATION_",show x]))
                   ,declareInit = (override3 (Just $ tell ["#INIT"])), declareFree = override3 (Just $ tell ["#FREE"])
                   ,genType = (\_ x -> tell ["$(",show x,")"])
                   ,genVariable = override1 at
                   }


defRecord :: String -> String -> A.Type -> State CompState ()
defRecord rec mem t = defineName (simpleName rec) $ A.NameDef emptyMeta rec rec A.RecordName (A.RecordType emptyMeta False [(simpleName mem,t)]) A.Original A.Unplaced

testGenVariable :: Test
testGenVariable = TestList
 [
  -- Various types, unsubscripted:
  testSameA 0 ("foo","(*foo)","foo") id A.Int
  ,testSameA 10 ("(&foo)","foo","foo") id (A.Record bar)
  ,testSameA2 20 ("(&foo)","foo") id (A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int)
  ,testSameA2 30 ("foo","foo") id (A.Chan A.DirInput (A.ChanAttributes False False) A.Int)
  
  -- Arrays of the previous types, unsubscripted:
  ,testSameA 100 ("foo","foo","foo") id (A.Array [A.Dimension 8] A.Int)
  ,testSameA 110 ("foo","foo","foo") id (A.Array [A.Dimension 8] $ A.Record bar)
  ,testSameA2 120 ("foo","foo") id (A.Array [A.Dimension 8] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int)
  ,testSameA2 130 ("foo","foo") id (A.Array [A.Dimension 8] $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int)
  
  -- Subscripted record:
  ,testSameA 200 ("(&foo)->x","foo->x","foo->x") fieldX (A.Record bar)
  
  -- Fully subscripted array:
  ,testAC 300 ("foo@C4","foo@U4") (sub 4) (A.Array [A.Dimension 8] A.Int)
  ,testAC 305 ("foo@C4,5,6","foo@U4,5,6") ((sub 6) . (sub 5) . (sub 4)) (A.Array [A.Dimension 8,A.Dimension 9,A.Dimension 10] A.Int)
  ,testAC 310 ("(&foo@C4)","(&foo@U4)") (sub 4) (A.Array [A.Dimension 8] $ A.Record bar)
  -- Original channel arrays are Channel[], but abbreviated channel arrays are Channel*[]:
  ,testAC2 320 ("(&foo@C4)","(&foo@U4)") ("foo@C4","foo@U4") (sub 4) (A.Array [A.Dimension 8] $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int)
  ,testAC 330 ("foo@C4","foo@U4") (sub 4) (A.Array [A.Dimension 8] $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int)
  
  -- Fully subscripted array, and record field reference:
  ,testAC 400 ("(&foo@C4)->x","(&foo@U4)->x") (fieldX . (sub 4)) (A.Array [A.Dimension 8] $ A.Record bar)
  -- As above, but then with an index too:
  ,testAC 410 ("(&foo@C4)->x@C4","(&foo@U4)->x@U4") ((sub 4) . fieldX . (sub 4)) (A.Array [A.Dimension 8] $ A.Record bar)
  
  --TODO come back to slices later
 ]
 where
   fieldX = A.SubscriptedVariable emptyMeta (A.SubscriptField emptyMeta $ simpleName "x")
   sub n = A.SubscriptedVariable emptyMeta (A.Subscript emptyMeta $ intLiteral n)
 
   test :: Int -> (String,String) -> (String,String) -> (A.Variable -> A.Variable) -> A.AbbrevMode -> A.Type -> Test
   test n (eC,eUC) (eCPP,eUCPP) sub am t = TestList
    [
     testBothS ("testGenVariable/checked" ++ show n) eC eCPP ((tcall genVariable $ sub $ A.Variable emptyMeta foo) . over) state
     ,testBothS ("testGenVariable/unchecked" ++ show n) eUC eUCPP ((tcall genVariableUnchecked $ sub $ A.Variable emptyMeta foo) . over) state
    ]
     where
       state = do defineName (simpleName "foo") $ A.NameDef emptyMeta "foo" "foo" A.VariableName (A.Declaration emptyMeta t) am A.Unplaced
                  defRecord "bar" "x" $ A.Array [A.Dimension 7] A.Int
       over ops = ops {genArraySubscript = (\_ b _ subs -> at >> (tell [if b then "C" else "U"]) >> (seqComma $ map (call genExpression ops) subs))}
   
   testA :: Int -> (String,String) -> (String,String) -> (A.Variable -> A.Variable) -> A.Type -> Test
   testA n eC eCPP sub t = TestList [test n eC eCPP sub A.Original t, test (n+1) eC eCPP sub A.Abbrev t, test (n+2) eC eCPP sub A.ValAbbrev t]
   
   -- | Tests that the given (checked,unchecked) expected values occur in both C and C++
   testAC :: Int -> (String,String) -> (A.Variable -> A.Variable) -> A.Type -> Test
   testAC n e sub t = testA n e e sub t

   -- | Tests that the given (checked,unchecked) expected values (for Original and Abbrev modes) occur in both C and C++
   testAC2 :: Int -> (String,String) -> (String,String) -> (A.Variable -> A.Variable) -> A.Type -> Test
   testAC2 n e e' sub t = TestList [test n e e sub A.Original t, test (n+1) e' e' sub A.Abbrev t]
   
   testSame :: Int -> String -> (A.Variable -> A.Variable) -> A.AbbrevMode -> A.Type -> Test
   testSame n e sub am t = test n (e,e) (e,e) sub am t
   
   testSameA :: Int -> (String,String,String) -> (A.Variable -> A.Variable) -> A.Type -> Test
   testSameA n (eO,eA,eVA) sub t = TestList [testSame n eO sub A.Original t,testSame (n+1) eA sub A.Abbrev t,testSame (n+2) eVA sub A.ValAbbrev t]

   testSameA2 :: Int -> (String,String) -> (A.Variable -> A.Variable) -> A.Type -> Test
   testSameA2 n (eO,eA) sub t = TestList [testSame n eO sub A.Original t,testSame (n+1) eA sub A.Abbrev t]

testAssign :: Test
testAssign = TestList
 [
  testBothSameS "testAssign 0" "@=$;" ((tcall3 genAssign emptyMeta [A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e])) . over) (state A.Int)
  ,testBothSameS "testAssign 1" "@=$;" ((tcall3 genAssign emptyMeta [A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e])) . over) (state A.Time)
  ,testBothSameS "testAssign 2" "@=$;" ((tcall3 genAssign emptyMeta [A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e])) . over)
    (state $ A.Chan A.DirInput (A.ChanAttributes False False) A.Int)

  -- Fail because genAssign only handles one destination and one source:
  ,testBothFail "testAssign 100" (tcall3 genAssign emptyMeta [A.Variable emptyMeta foo,A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e]))
  ,testBothFail "testAssign 101" (tcall3 genAssign emptyMeta [A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e,e]))
  ,testBothFail "testAssign 102" (tcall3 genAssign emptyMeta [A.Variable emptyMeta foo,A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e, e]))
  
  -- Fail because assignment can't be done with these types (should have already been transformed away):
  ,testBothFailS "testAssign 200" ((tcall3 genAssign emptyMeta [A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e])) . over)
    (state $ A.Chan A.DirUnknown (A.ChanAttributes False False) A.Int)
  ,testBothFailS "testAssign 201" ((tcall3 genAssign emptyMeta [A.Variable emptyMeta foo] (A.ExpressionList emptyMeta [e])) . over)
    (state $ A.Record bar)
 ]
 where
   --The expression won't be examined so we can use what we like:
   e = A.True emptyMeta
   state t = defineName (simpleName "foo") $ simpleDefDecl "foo" t
   over ops = ops {genVariable = override1 at, genExpression = override1 dollar}

testCase :: Test
testCase = TestList
 [
  testBothSame "testCase 0" "switch($){default:^}" ((tcall3 genCase emptyMeta e (A.Several emptyMeta [])) . over)
  ,testBothSame "testCase 1" "switch($){default:{@}break;}" ((tcall3 genCase emptyMeta e (A.OnlyO emptyMeta $ A.Else emptyMeta p)) . over)
  ,testBothSame "testCase 2" "switch($){default:{#@}break;}" ((tcall3 genCase emptyMeta e (spec $ A.OnlyO emptyMeta $ A.Else emptyMeta p)) . over)
  
  ,testBothSame "testCase 10" "switch($){case $:{@}break;default:^}" ((tcall3 genCase emptyMeta e (A.OnlyO emptyMeta $ A.Option emptyMeta [intLiteral 0] p)) . over)

  ,testBothSame "testCase 20" "switch($){case $:case $:{#@}break;default:{@}break;case $:{@}break;}" ((tcall3 genCase emptyMeta e $ A.Several emptyMeta
      [spec $ A.OnlyO emptyMeta $ A.Option emptyMeta [e, e] p
      ,A.OnlyO emptyMeta $ A.Else emptyMeta p
      ,A.OnlyO emptyMeta $ A.Option emptyMeta [e] p]
    ) . over)
 ]
  where
    --The expression and process won't be used so we can use what we like:
    e = A.True emptyMeta
    p = A.Skip emptyMeta
    spec = A.Spec emptyMeta undefined
    over ops = ops {genExpression = override1 dollar, genProcess = override1 at, genStop = override2 caret, genSpec = override2 hash}

testGetTime :: Test
testGetTime = testBoth "testGetTime 0" "ProcTime(&@);" "csp::CurrentTime(&@);" ((tcall2 genGetTime emptyMeta undefined) . over)
  where
    over ops = ops {genVariable = override1 at}

testWait :: Test
testWait = TestList
 [
  testBoth "testWait 0" "ProcTimeAfter($);" "csp::SleepUntil($);" ((tcall2 genWait A.WaitUntil undefined) . over)
  ,testBoth "testWait 1" "ProcAfter($);" "csp::SleepFor($);" ((tcall2 genWait A.WaitFor undefined) . over)
 ]
 where
   over ops = ops {genExpression = override1 dollar}

testIf :: Test
testIf = TestList
 [
  testBothR "testIf 0" "/\\*([[:alnum:]_]+)\\*/\\^\\1:;" "class ([[:alnum:]_]+)\\{\\};try\\{\\^\\}catch\\(\\1\\)\\{\\}"
    ((tcall2 genIf emptyMeta (A.Several emptyMeta [])) . over)
  ,testBothR "testIf 1" "/\\*([[:alnum:]_]+)\\*/if\\(\\$\\)\\{@goto \\1;\\}\\^\\1:;" 
    "class ([[:alnum:]_]+)\\{\\};try\\{if\\(\\$\\)\\{@throw \\1\\(\\);\\}\\^\\}catch\\(\\1\\)\\{\\}"
    ((tcall2 genIf emptyMeta (A.OnlyC emptyMeta $ A.Choice emptyMeta e p)) . over)
 ]
 where
   e :: A.Expression
   e = undefined
   p :: A.Process
   p = undefined 
   over ops = ops {genExpression = override1 dollar, genProcess = override1 at, genStop = override2 caret, genSpec = override2 hash}

testWhile :: Test
testWhile = testBothSame "testWhile 0" "while($){@}" ((tcall2 genWhile undefined undefined) . over)
  where
    over ops = ops {genExpression = override1 dollar, genProcess = override1 at}

testOutput :: Test
testOutput = TestList
 [
  testBothSame "testOutput 0" "" ((tcall2 genOutput undefined []) . overOutputItem)
  ,testBothSame "testOutput 1" "^" ((tcall2 genOutput undefined [undefined]) . overOutputItem)
  ,testBothSame "testOutput 2" "^^^" ((tcall2 genOutput undefined [undefined,undefined,undefined]) . overOutputItem)
 
  ,testBothS "testOutput 100" "ChanOutInt(@,bar_foo);^" "tockSendInt(@->writer(),bar_foo);^" ((tcall3 genOutputCase (A.Variable emptyMeta chan) bar []) . overOutput) state
  ,testBothS "testOutput 101" "ChanOutInt(@,bar_foo);^" "tockSendInt(@,bar_foo);^" ((tcall3 genOutputCase (A.Variable emptyMeta chanOut) bar []) . overOutput) state
 ]
 where
   chan = simpleName "c"
   chanOut = simpleName "cOut"
   state = do defineName chan $ simpleDefDecl "c" (A.Chan A.DirUnknown (A.ChanAttributes False False) $ A.UserProtocol foo)
              defineName chanOut $ simpleDefDecl "cOut" (A.Chan A.DirOutput (A.ChanAttributes False False) $ A.UserProtocol foo)
   overOutput ops = ops {genVariable = override1 at, genOutput = override2 caret}
   overOutputItem ops = ops {genOutputItem = override2 caret}

---Returns the list of tests:
tests :: Test
tests = TestList
 [
   testActuals
   ,testArraySizes
   ,testArraySubscript
   ,testAssign
   ,testCase
   ,testDeclaration
   ,testDeclareInitFree
   ,testGenType
   ,testGenVariable
   ,testGetTime
   ,testIf
   ,testOutput
   ,testOverArray
   ,testReplicator
   ,testSpec
   ,testStop
   ,testWait
   ,testWhile
 ]
