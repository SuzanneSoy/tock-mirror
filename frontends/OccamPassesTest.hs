{-
Tock: a compiler for parallel languages
Copyright (C) 2008  University of Kent

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

-- | Tests for 'OccamPasses'.

module OccamPassesTest (tests) where

import Control.Monad.State
import Data.Generics
import Test.HUnit hiding (State)

import qualified AST as A
import CompState
import Metadata
import qualified OccamPasses
import TestUtils

m :: Meta
m = emptyMeta

-- | Initial state for the tests.
startState :: State CompState ()
startState
    =  do defineConst "const" A.Int (intLiteral 2)
          defineConst "someInt" A.Int (intLiteral 42)
          defineConst "someByte" A.Byte (byteLiteral 24)
          defineConst "someInts" (A.Array [A.UnknownDimension] A.Int)
                                 undefined
          defineConst "someBytes" (A.Array [A.UnknownDimension] A.Byte)
                                  undefined

-- | Test 'OccamPasses.foldConstants'.
testFoldConstants :: Test
testFoldConstants = TestList
    [
    -- Trivial stuff
      testSame 0 one
    , testSame 1 var

    -- Things that shouldn't fold
    , testSame 10 (add var one)
    , testSame 11 (add one var)
    , testSame 12 (add var (add one var))
    , testSame 13 (add one (add var one))
    , testSame 14 (add var (add one var))

    -- Things that should fold
    , test 20 (add one one) two
    , test 21 (add one (add one one)) three
    , test 22 (add (add one one) one) three
    , test 23 (add one two) three
    , test 24 (add one (add one (add one one))) four
    , test 25 (add (add one (add one one)) one) four
    , test 26 (add (add (add one one) one) one) four

    -- Folding subexpressions of a non-constant expression
    , test 30 (add var (add one one)) (add var two)
    , test 31 (add (add one one) var) (add two var)
    , test 32 (add var (add var (add one one))) (add var (add var two))

    -- Folding existing constant variables
    , test 40 const two
    , test 41 (add const (add one one)) four
    , test 42 (add (add one one) const) four
    , test 43 (add const (add const (add one one))) six
    , test 44 (add var const) (add var two)
    , test 45 (add const var) (add two var)
    , test 46 (add const const) four
    , test 47 (add const (add var one)) (add two (add var one))
    , test 48 (add var (add const one)) (add var three)
    ]
  where
    test :: Data a => Int -> a -> a -> Test
    test n orig exp = TestCase $ testPass ("testFoldConstants" ++ show n)
                                          exp (OccamPasses.foldConstants orig)
                                          startState

    testSame :: Int -> A.Expression -> Test
    testSame n orig = test n orig orig

    add e f = A.Dyadic m A.Add e f
    var = exprVariable "var"
    const = exprVariable "const"
    one = intLiteral 1
    two = intLiteral 2
    three = intLiteral 3
    four = intLiteral 4
    six = intLiteral 6

-- | Test 'OccamPasses.checkConstants'.
testCheckConstants :: Test
testCheckConstants = TestList
    [
    -- Valid dimensions in array types
      testOK 0 (A.Int)
    , testOK 1 (A.Array [dim10] A.Int)
    , testOK 2 (A.Array [dimU] A.Int)
    , testOK 3 (A.Array [dim10, dim10] A.Int)
    , testOK 4 (A.Array [dim10, dimU] A.Int)

    -- Invalid dimensions in array types
    , testFail 10 (A.Array [dimVar] A.Int)
    , testFail 11 (A.Array [dimVar, dimVar] A.Int)
    , testFail 12 (A.Array [dim10, dimVar] A.Int)
    , testFail 13 (A.Array [dimU, dimVar] A.Int)
    , testFail 14 (A.Array [dim10, dim10, dimU, dimU, dimVar] A.Int)

    -- Valid Case options
    , testOK 20 (A.Option m [lit10] skip)
    , testOK 21 (A.Option m [lit10, lit10] skip)
    , testOK 22 (A.Option m [lit10, lit10, lit10] skip)

    -- Invalid Case options
    , testFail 30 (A.Option m [var] skip)
    , testFail 31 (A.Option m [lit10, var] skip)
    , testFail 32 (A.Option m [var, lit10] skip)
    , testFail 33 (A.Option m [lit10, lit10, lit10, var] skip)
    ]
  where
    testOK :: (Show a, Data a) => Int -> a -> Test
    testOK n orig
        = TestCase $ testPass ("testCheckConstants" ++ show n)
                              orig (OccamPasses.checkConstants orig)
                              (return ())

    testFail :: (Show a, Data a) => Int -> a -> Test
    testFail n orig
        = TestCase $ testPassShouldFail ("testCheckConstants" ++ show n)
                                        (OccamPasses.checkConstants orig)
                                        (return ())

    dim10 = A.Dimension $ intLiteral 10
    dimU = A.UnknownDimension
    dimVar = A.Dimension $ exprVariable "var"

    lit10 = intLiteral 10
    var = exprVariable "var"
    skip = A.Skip m

-- | Test 'OccamPasses.checkRetypes'.
testCheckRetypes :: Test
testCheckRetypes = TestList
    [
    -- Definitely OK at compile time
      testOK 0 $ retypesV A.Int intV
    , testOK 1 $ retypesE A.Int intE
    , testOK 2 $ retypesV A.Byte byteV
    , testOK 3 $ retypesE A.Byte byteE
    , testOK 4 $ retypesV known1 intV
    , testOK 5 $ retypesV known2 intV
    , testOK 6 $ retypesV both intV
    , testOK 7 $ retypesV unknown1 intV

    -- Definitely wrong at compile time
    , testFail 100 $ retypesV A.Byte intV
    , testFail 101 $ retypesV A.Int byteV
    , testFail 102 $ retypesV unknown2 intV
    , testFail 103 $ retypesV unknown2 intsV
    , testFail 104 $ retypesV A.Byte intsV

    -- Can't tell; need a runtime check
    , testOK 200 $ retypesV unknown1 intsV
    , testOK 201 $ retypesV A.Int intsV
    , testOK 202 $ retypesV known2 intsV
    , testOK 203 $ retypesV unknown1 bytesV
    ]
  where
    testOK :: (Show a, Data a) => Int -> a -> Test
    testOK n orig
        = TestCase $ testPass ("testCheckRetypes" ++ show n)
                              orig (OccamPasses.checkRetypes orig)
                              startState

    testFail :: (Show a, Data a) => Int -> a -> Test
    testFail n orig
        = TestCase $ testPassShouldFail ("testCheckRetypes" ++ show n)
                                        (OccamPasses.checkRetypes orig)
                                        startState

    retypesV = A.Retypes m A.ValAbbrev
    retypesE = A.RetypesExpr m A.ValAbbrev

    intV = variable "someInt"
    intE = intLiteral 42
    byteV = variable "someByte"
    byteE = byteLiteral 42
    intsV = variable "someInts"
    bytesV = variable "someBytes"
    known1 = A.Array [dimension 4] A.Byte
    known2 = A.Array [dimension 2, dimension 2] A.Byte
    both = A.Array [dimension 2, A.UnknownDimension] A.Byte
    unknown1 = A.Array [A.UnknownDimension] A.Int
    unknown2 = A.Array [A.UnknownDimension, A.UnknownDimension] A.Int

tests :: Test
tests = TestLabel "OccamPassesTest" $ TestList
    [ testFoldConstants
    , testCheckConstants
    , testCheckRetypes
    ]