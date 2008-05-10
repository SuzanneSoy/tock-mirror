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

-- | Utilities for metaprogramming.
module GenNavAST where

import Data.Char
import Data.Generics
import Data.List
import qualified Data.Set as Set

import PregenUtils
import Utils

header :: [String]
header
    = [ "{-# OPTIONS_GHC -Werror -fwarn-overlapping-patterns -fwarn-unused-matches -fwarn-unused-binds -fwarn-incomplete-patterns #-}"
      , "-- | Type class and instances for transformations upon the AST."
      , "--"
      , "-- This was inspired by Neil Mitchell's Biplate class."
      , "--"
      , "-- NOTE: This file is auto-generated by the GenNavAST program, "
      , "-- and should not be edited directly."
      , ""
      , "module NavAST where"
      , ""
      , "import qualified AST"
      , "import qualified Metadata"
      , ""
      , "class Monad m => Polyplate m o o0 t where"
      , "  transformM :: o -> o0 -> Bool -> t -> m t"
      , ""
      ]

-- | Instances for a particular data type (i.e. where that data type is the
-- last argument to 'Polyplate').
instancesFrom :: forall t. Data t => t -> [String]
instancesFrom w
    = baseInst ++
      concat [otherInst c | DataBox c <- justBoxes $ astTypeMap]
  where
    wName = show $ typeOf w
    wKey = typeKey w
    wDType = dataTypeOf w
    wCtrs = if isAlgType wDType then dataTypeConstrs wDType else []

    -- The module prefix of this type, so we can use it in constructor names.
    modPrefix
        = if '.' `elem` (takeWhile (\c -> isAlphaNum c || c == '.') wName)
            then takeWhile (/= '.') wName ++ "."
            else ""

    ctrArgs ctr
        = gmapQ DataBox (fromConstr ctr :: t)
    ctrArgTypes ctr
        = [show $ typeOf w | DataBox w <- ctrArgs ctr]

    -- | An instance that describes what to do when we have no transformations
    -- left to apply.
    baseInst :: [String]
    baseInst
        = [ "instance (" ++ concat (intersperse ", " context) ++ ") =>"
          , "         Polyplate m () o0 (" ++ wName ++ ") where"
          ] ++
          (if isAlgType wDType
            -- An algebraic type: apply to each child if we're following.
            then ["  transformM () _ False v = return v"] ++
                 (concatMap constrCase wCtrs)
            -- A primitive type: just return it.
            else ["  transformM () _ _ v = return v"]) ++
          [""]

    -- | Class context for 'baseInst'.
    -- We need an instance of Polyplate for each of the types contained within
    -- this type, so we can recurse into them.
    context :: [String]
    context
        = ["Monad m"] ++
          ["Polyplate m o0 o0 (" ++ argType ++ ")"
           | argType <- nub $ sort $ concatMap ctrArgTypes wCtrs]

    -- | A 'transformM' case for a particular constructor of this (algebraic)
    -- data type: pull the value apart, apply 'transformM' to each part of it,
    -- then stick it back together.
    constrCase :: Constr -> [String]
    constrCase ctr
        = [ "  transformM () " ++ (if argNums == [] then "_" else "ops") ++
            " True (" ++ ctrInput ++ ")"
          , "    = do"
          ] ++
          [ "         r" ++ show i ++ " <- transformM ops ops False a" ++ show i
           | i <- argNums] ++
          [ "         return (" ++ ctrResult ++ ")"
          ]
      where
        (isTuple, argNums)
          -- FIXME: Should work for 3+-tuples too
          | ctrS == "(,)" = (True, [0 .. 1])
          | otherwise     = (False, [0 .. ((length $ ctrArgs ctr) - 1)])
        ctrS = show ctr
        ctrName = modPrefix ++ ctrS
        makeCtr vs
            = if isTuple
                then "(" ++ (concat $ intersperse ", " vs) ++ ")"
                else ctrName ++ concatMap (" " ++) vs
        ctrInput = makeCtr ["a" ++ show i | i <- argNums]
        ctrResult = makeCtr ["r" ++ show i | i <- argNums]

    containedKeys = Set.fromList [typeKey c
                                  | DataBox c <- justBoxes $ findTypesIn w]

    -- | An instance that describes how to apply -- or not apply -- a
    -- transformation.
    otherInst c
        = [ "instance (Monad m, Polyplate m r o0 (" ++ wName ++ ")) =>"
          , "         Polyplate m ((" ++ cName ++ ") -> m (" ++ cName ++ "), r)"
          , "                   o0 (" ++ wName ++ ") where"
          , impl
          , ""
          ]
      where
        cName = show $ typeOf c
        cKey = typeKey c
        impl
          -- This type matches the transformation: apply it.
          | wKey == cKey
            = "  transformM (f, _) _ _ v = f v"
          -- This type might contain the type that the transformation acts
          -- upon: set the flag to say we need to recurse into it.
          | cKey `Set.member` containedKeys
            = "  transformM (_, rest) ops _ v = transformM rest ops True v"
          -- This type can't contain the transformed type; just move on to the
          -- next transformation.
          | otherwise
            = "  transformM (_, rest) ops b v = transformM rest ops b v"

main :: IO ()
main = putStr $ unlines $ header ++
                          concat [instancesFrom w
                                  | DataBox w <- justBoxes $ astTypeMap]
