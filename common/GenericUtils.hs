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

-- | Utilities for generic operations.
--
-- This code was inspired by Neil Mitchell's Uniplate library.
-- 'typeContains' is faster than PlateData's equivalent at the cost of some
-- flexibility: it'll only work for types that it knows about (which can be
-- added to in the definition of 'contains').
module GenericUtils (
    TypeKey, typeKey
  , TypeSet, makeTypeSet
  , containsTypes
  , gmapMFor
  , gmapMForRoute
  ) where

import Control.Monad.Identity()
import Control.Monad.State
import Data.Generics
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.List
import Data.Typeable
import System.IO.Unsafe

import qualified AST as A
import TreeUtils
import Utils

-- | A type identifier.
type TypeKey = Int

-- | Given a witness for a type, return its 'TypeKey'.
typeKey :: Typeable a => a -> TypeKey
typeKey x = unsafePerformIO $ typeRepKey $ typeOf x

-- | Given a witness for a type, return witnesses for all the types that its
-- constructors take.
constrArgTypes :: (Data a, Typeable a) => a -> [DataBox]
constrArgTypes x = if isAlgType dtype then concatMap f constrs else []
  where
    f constr = gmapQ DataBox (asTypeOf (fromConstr constr) x)
    constrs = dataTypeConstrs dtype
    dtype = dataTypeOf x

-- | Given a witness for a type, return a map from type keys to witnesses for
-- all the types it contains recursively.
containedTypes :: (Data a, Typeable a) => a -> IntMap DataBox
containedTypes start = containedTypes' (DataBox start) IntMap.empty
  where
    containedTypes' :: DataBox -> IntMap DataBox -> IntMap DataBox
    containedTypes' box@(DataBox thisType) seen
        = if thisKey `IntMap.member` seen
            then seen
            else foldl (\s t -> containedTypes' t s)
                       (IntMap.insert thisKey box seen)
                       (constrArgTypes thisType)
      where
        thisKey = typeKey thisType

-- | A map from type keys to the other type keys reachable from them.
type ContainsMap = IntMap IntSet

-- | A map of reachable types.
-- At the moment this only knows about types reachable from the AST.
contains :: ContainsMap
contains = IntMap.fromList [(typeKey t,
                             IntMap.keysSet $ containedTypes t)
                            | DataBox t <- IntMap.elems allTypes]
  where
    allTypes = containedTypes (undefined :: A.AST)

-- | Does a value contain any of the listed types?
-- (A value always contains its own type.)
containsTypes :: Data t => t -> [TypeKey] -> Bool
containsTypes x targets
    = or $ map containsType targets
  where
    start :: TypeKey
    start = typeKey x

    containsType :: TypeKey -> Bool
    containsType target
      | start == target = True
      | otherwise       = case IntMap.lookup start contains of
                            Just set -> target `IntSet.member` set
                            Nothing -> True  -- can't tell, so it might be

-- | A decision about what to do when we find a particular type during a
-- generic operation.
data TypeDecision =
  -- | This is one of the types we're looking for.
  Hit
  -- | This isn't one of the types we're looking for, but it might contain one
  -- of them.
  | Through
  -- | This isn't one of the types we're looking for, and there's no need to
  -- look inside it.
  | Miss

-- | A set of type information for use by 'gmapMFor'.
type TypeSet = IntMap TypeDecision

-- | Make a 'TypeSet' from a list of 'TypeKey's.
makeTypeSet :: [TypeKey] -> TypeSet
makeTypeSet targets
    = IntMap.fromList [(tk, decide tk)
                       | tk <- IntMap.keys contains]
  where
    decide :: TypeKey -> TypeDecision
    decide tk
      | tk `elem` targets             = Hit
      | tk `IntSet.member` allThrough = Through
      | otherwise                     = Miss

    allThrough :: IntSet
    allThrough
        = IntSet.fromList $ filter containsThis $ IntMap.keys contains
      where
        containsThis tk
            = case IntMap.lookup tk contains of
                Just set -> or $ map (`IntSet.member` set) targets
                Nothing -> False

-- | Type-smart generic mapM.
-- This is like 'gmapM', but it only applies the function to arguments that
-- could contain any of the target types.
gmapMFor :: (Monad m, Data t) =>
            TypeSet                           -- ^ Target types
            -> (forall s. Data s => s -> m s) -- ^ Function to apply
            -> (t -> m t)                     -- ^ Generic operation
gmapMFor typeset f = gmapM (each f)
  where
    each :: (Monad m, Data t) =>
            (forall s. Data s => s -> m s) -> (t -> m t)
    each f x
        = case IntMap.lookup (typeKey x) typeset of
            Just Hit -> f x
            Just Through -> gmapM (each f) x
            Just Miss -> return x
            Nothing -> return x

gmapMForRoute :: forall m t. (Monad m, Data t) =>
  TypeSet ->
  (forall s. Data s => (s, (forall n. Monad n => (s -> n s) -> (t -> n t))) -> m s)
  -> (t -> m t)
gmapMForRoute typeset f = gmapMWithRoute (each f)
  where
    each :: Data u => (forall s. Data s => (s, (forall n. Monad n => (s -> n s) -> (t -> n t))) -> m s)
             -> ((u, (forall n. Monad n => (u -> n u) -> (t -> n t))) -> m u)
    each f (x, route)
        = case IntMap.lookup (typeKey x) typeset of
            Just Hit -> f (x, route)
            Just Through -> gmapMWithRoute (\(y, route') -> each f (y, route . route')) x
            Just Miss -> return x
            Nothing -> return x

gmapMWithRoute :: forall a m. (Monad m, Data a) => (forall b. Data b => (b, (forall n. Monad n => (b -> n b) ->
  (a -> n a))) -> m b) -> a -> m a
gmapMWithRoute f = gmapFuncs [GM {unGM = f' n} | n <- [0..]]
  where
    f' :: Int -> (forall b. Data b => b -> m b)
    f' n x = f (x, makeRoute n)

-- Given a number, makes a route function for that child:
makeRoute :: (Data s, Data t, Monad m) => Int -> (s -> m s) -> (t -> m t)
makeRoute target f = gmapFuncs [mkM' (if n == target then f else return) | n <- [0..]]
