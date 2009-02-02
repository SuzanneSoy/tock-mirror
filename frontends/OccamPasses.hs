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

-- | The occam-specific frontend passes.
module OccamPasses (occamPasses, foldConstants, checkConstants) where

import Control.Monad.State
import Data.Generics

import qualified AST as A
import CompState
import EvalConstants
import EvalLiterals
import Metadata
import OccamTypes
import Pass
import qualified Properties as Prop
import ShowCode
import Traversal
import Types
import Utils

-- | Occam-specific frontend passes.
occamPasses :: [Pass]
occamPasses =
    [ occamOnlyPass "Dummy occam pass" [] (Prop.agg_namesDone ++ [Prop.mainTagged]) return
    , inferTypes
    , foldConstants
--    , fixConstructorTypes
    , checkConstants
    , resolveAmbiguities
    , checkTypes
    ]

-- | Fixed the types of array constructors according to the replicator count
fixConstructorTypes :: Pass
fixConstructorTypes = occamOnlyPass "Fix the types of array constructors"
  [Prop.constantsFolded]
  [Prop.arrayConstructorTypesDone]
  (applyDepthM doExpression)
  where
    doExpression :: A.Expression -> PassM A.Expression
    doExpression (A.Literal m prevT lit@(A.ArrayListLiteral _ expr))
      = do t' <- doExpr (Left $ getDims prevT) expr
           return $ A.Literal m t' lit
      where
        getEither = either id id
        addRight x = Right . either (const [x]) (++[x])

        getDims :: A.Type -> [A.Dimension]
        getDims (A.Array ds _) = ds
        getDims t = error $ "Cannot deduce dimensions of array constructor: " ++ show t

        -- Left means previous guess (to be used if there's no replicator)
        -- Right means current accumulation
        doExpr :: Either [A.Dimension] [A.Dimension] -> A.Structured A.Expression -> PassM A.Type
        doExpr dims (A.Several m ss@(s:_))
          = doExpr (addRight (A.Dimension $ makeConstant m $ length ss) dims) s
        doExpr dims (A.Only _ e)
          = astTypeOf e >>* A.Array (getEither dims)
        doExpr dims (A.ProcThen _ _ e) = doExpr dims e
        doExpr dims (A.Spec _ (A.Specification _ _ (A.Rep _ rep)) body)
          = doExpr (addRight count dims) body
          where
            count = A.Dimension $ countReplicator rep

    doExpression e = return e

-- | Handle ambiguities in the occam syntax that the parser can't resolve.
resolveAmbiguities :: Pass
resolveAmbiguities = occamOnlyPass "Resolve ambiguities"
  [Prop.inferredTypesRecorded]
  [Prop.ambiguitiesResolved]
  (applyDepthM doExpressionList)
  where
    doExpressionList :: Transform A.ExpressionList
    -- A single function call inside an ExpressionList is actually a
    -- FunctionCallList, since it can have multiple results.
    doExpressionList (A.ExpressionList _ [A.FunctionCall m n es])
        = return $ A.FunctionCallList m n es
    doExpressionList (A.ExpressionList _ [A.IntrinsicFunctionCall m n es])
        = return $ A.IntrinsicFunctionCallList m n es
    doExpressionList e = return e

-- | Fold constant expressions.
foldConstants :: Pass
foldConstants = occamOnlyPass "Fold constants"
  [Prop.inferredTypesRecorded]
  [Prop.constantsFolded]
  (applyDepthM2 doExpression doSpecification)
  where
    -- Try to fold all expressions we encounter. Since we've recursed into the
    -- expression first, this'll also fold subexpressions of non-constant
    -- expressions.
    doExpression :: A.Expression -> PassM A.Expression
    doExpression e
        =  do (e', _, _) <- constantFold e
              return e'

    -- After we're done folding a specification, update its definition.
    -- (Even if it isn't an expression itself, it might have others inside it,
    -- so we just update them all.)
    doSpecification :: A.Specification -> PassM A.Specification
    doSpecification s@(A.Specification _ n st)
        =  do modifyName n (\nd -> nd { A.ndSpecType = st })
              return s

-- | Check that things that must be constant are.
checkConstants :: Pass
checkConstants = occamOnlyPass "Check mandatory constants"
  [Prop.constantsFolded, Prop.arrayConstructorTypesDone]
  [Prop.constantsChecked]
  (applyDepthM2 doDimension doOption)
  where
    -- Check array dimensions are constant.
    doDimension :: A.Dimension -> PassM A.Dimension
    doDimension d@(A.Dimension e)
        =  do when (not $ isConstant e) $
                diePC (findMeta e) $ formatCode "Array dimension must be constant: %" e
              return d
    doDimension d = return d

    -- Check case options are constant.
    doOption :: A.Option -> PassM A.Option
    doOption o@(A.Option _ es _)
        =  do sequence_ [when (not $ isConstant e) $
                           diePC (findMeta e) $ formatCode "Case option must be constant: %" e
                         | e <- es]
              return o
    doOption o = return o


