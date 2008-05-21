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

-- | Simplify types in the AST.
module SimplifyTypes (simplifyTypes) where

import Control.Monad.State
import Data.Generics
import qualified Data.Set as Set

import qualified AST as A
import Metadata
import Pass
import qualified Properties as Prop
import Types

simplifyTypes :: [Pass]
simplifyTypes = [resolveAllNamedTypes]

resolveAllNamedTypes :: Pass
resolveAllNamedTypes = Pass
  {passCode = \t -> (get >>= resolveNamedTypes >>= put) >> resolveNamedTypes t
  ,passName = "Resolve types in AST and state"
  ,passPre = Set.fromList $ Prop.agg_namesDone ++ [Prop.expressionTypesChecked, Prop.processTypesChecked]
  ,passPost = Set.fromList [Prop.typesResolvedInAST, Prop.typesResolvedInState]
  ,passEnabled = const True}

-- | Turn named data types into their underlying types.
resolveNamedTypes :: Data t => t -> PassM t
resolveNamedTypes = doGeneric `extM` doType
  where
    doGeneric :: Data t => t -> PassM t
    doGeneric = makeGeneric resolveNamedTypes

    doType :: A.Type -> PassM A.Type
    doType t@(A.UserDataType _) = underlyingType emptyMeta t
    doType t = doGeneric t
