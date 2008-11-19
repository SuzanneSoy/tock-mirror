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

module CheckTest (tests) where

import Test.HUnit

import qualified AST as A
import Check
import CheckFramework
import Metadata
import TestUtils

testUnusedVar :: Test
testUnusedVar = TestList
 [
  test' "No vars" (A.Several emptyMeta [] :: A.AST)
 ,test' "Used var" $ wrapProcSeq $ A.Spec emptyMeta (A.Specification emptyMeta (simpleName
   "x") $ A.Declaration emptyMeta A.Int) $ A.Only emptyMeta $ A.Assign emptyMeta
     [variable "x"] (A.ExpressionList emptyMeta [intLiteral 0])
 ,test "Unused var"
   (wrapProcSeq $ A.Only emptyMeta (A.Skip emptyMeta))
   (wrapProcSeq $ A.Spec emptyMeta (A.Specification emptyMeta (simpleName
     "x") $ A.Declaration emptyMeta A.Int) $ A.Only emptyMeta (A.Skip emptyMeta))
 ,test "Triple Unused var"
   (wrapProcSeq $ A.Only emptyMeta (A.Skip emptyMeta))
   (wrapProcSeq $
     A.Spec emptyMeta
       (A.Specification emptyMeta (simpleName "x") $ A.Declaration emptyMeta A.Int) $
     A.Spec emptyMeta
       (A.Specification emptyMeta (simpleName "y") $ A.Declaration emptyMeta A.Int) $
     A.Spec emptyMeta
       (A.Specification emptyMeta (simpleName "z") $ A.Declaration emptyMeta A.Int) $
     A.Only emptyMeta (A.Skip emptyMeta))
 ,test "Unused var in loop"
   (wrapProcSeq $ A.Only emptyMeta $ A.While emptyMeta (A.True emptyMeta) $ A.Seq
     emptyMeta $ A.Several emptyMeta [A.Only emptyMeta $ A.Skip emptyMeta])
   (wrapProcSeq $ A.Only emptyMeta $ A.While emptyMeta (A.True emptyMeta) $
     A.Seq emptyMeta $
       A.Spec emptyMeta 
         (A.Specification emptyMeta (simpleName "x") $ A.Declaration emptyMeta
           A.Int) $
       A.Several emptyMeta [A.Only emptyMeta $ A.Skip emptyMeta])
 ]
 where
   test' str src = test str src src
   test str exp src = TestCase $ testPass str exp (runChecksPass checkUnusedVar) src (return
     ())

tests :: Test
tests = TestLabel "CheckTest" $ TestList
 [
  testUnusedVar
 ]


