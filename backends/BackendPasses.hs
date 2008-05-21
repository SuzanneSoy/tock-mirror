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

-- | Passes associated with the backends
module BackendPasses where

import Control.Monad.State
import Data.Generics
import qualified Data.Map as Map

import qualified AST as A
import CompState
import Errors
import Metadata
import Pass
import PrettyShow
import qualified Properties as Prop
import Types
import Utils

squashArrays :: [Pass]
squashArrays = makePassesDep
  [ ("Simplify array slices", simplifySlices, prereq, [Prop.slicesSimplified])
  , ("Declare array-size arrays", declareSizesArray, prereq ++ [Prop.slicesSimplified,
    Prop.arrayConstructorsRemoved], [Prop.arraySizesDeclared])
  , ("Add array-size arrays to PROC headers", addSizesFormalParameters, prereq ++ [Prop.arraySizesDeclared], [])
  , ("Add array-size arrays to PROC calls", addSizesActualParameters, prereq ++ [Prop.arraySizesDeclared], [])
  ]
  where
    prereq = Prop.agg_namesDone ++ Prop.agg_typesDone ++ Prop.agg_functionsGone ++ [Prop.subscriptsPulledUp, Prop.arrayLiteralsExpanded]

transformWaitFor :: Data t => t -> PassM t
transformWaitFor = doGeneric `extM` doAlt
  where
    doGeneric :: Data t => t -> PassM t
    doGeneric = makeGeneric transformWaitFor
  
    doAlt :: A.Process -> PassM A.Process
    doAlt a@(A.Alt m pri s)
      = do (s',(specs,code)) <- runStateT (applyToOnly doWaitFor s) ([],[])
           if (null specs && null code)
             then return a
             else return $ A.Seq m $ foldr addSpec (A.Several m (code ++ [A.Only m $ A.Alt m pri s'])) specs
    doAlt p = doGeneric p
    
    addSpec :: Data a => (A.Structured a -> A.Structured a) -> A.Structured a -> A.Structured a
    addSpec spec inner = spec inner

    doWaitFor :: A.Alternative -> StateT ([A.Structured A.Process -> A.Structured A.Process], [A.Structured A.Process]) PassM A.Alternative
    doWaitFor a@(A.Alternative m cond tim (A.InputTimerFor m' e) p)
      = do (specs, init) <- get
           id <- lift $ makeNonce "waitFor"
           let n = (A.Name m A.VariableName id)
           let var = A.Variable m n
           put (specs ++ [A.Spec m (A.Specification m n (A.Declaration m A.Time))], 
                init ++ [A.Only m $ A.Input m tim
                           (A.InputTimerRead m (A.InVariable m var)),
                         A.Only m $ A.Assign m [var] $ A.ExpressionList m [A.Dyadic m A.Plus (A.ExprVariable m var) e]])
           return $ A.Alternative m cond tim (A.InputTimerAfter m' (A.ExprVariable m' var)) p
               
    doWaitFor a = return a

append_sizes :: A.Name -> A.Name
append_sizes n = n {A.nameName = A.nameName n ++ "_sizes"}


-- | Declares a _sizes array for every array, statically sized or dynamically sized.
-- For each record type it declares a _sizes array too.
declareSizesArray :: Data t => t -> PassM t
declareSizesArray = doGeneric `ext1M` doStructured
  where
    defineSizesName :: Meta -> A.Name -> A.SpecType -> PassM ()
    defineSizesName m n spec
      = defineName n $ A.NameDef {
                         A.ndMeta = m
                        ,A.ndName = A.nameName n
                        ,A.ndOrigName = A.nameName n
                        ,A.ndNameType = A.VariableName
                        ,A.ndType = spec
                        ,A.ndAbbrevMode = A.ValAbbrev
                        ,A.ndPlacement = A.Unplaced}
  
    -- Strips all the array subscripts from a variable:
    findInnerVar :: A.Variable -> (Maybe A.Expression, A.Variable)
    findInnerVar wv@(A.SubscriptedVariable m sub v) = case sub of
      A.SubscriptField {} -> (Nothing, wv)
      A.SubscriptFromFor _ _ for -> (Just for, snd $ findInnerVar v) -- Keep the outer most
      A.Subscript {} -> findInnerVar v
    findInnerVar v = (Nothing, v)

    -- | Generate the @_sizes@ array for a 'Retypes' expression.
    retypesSizes :: Meta -> A.Name -> [A.Dimension] -> A.Type -> A.Variable -> PassM A.Specification
    retypesSizes m n_sizes ds elemT v@(A.Variable _ nSrc)
      =  do biDest <- bytesInType (A.Array ds elemT)
            tSrc <- astTypeOf v
            biSrc <- bytesInType tSrc

            -- Figure out the size of the source.
            srcSize <-
              case (biSrc, tSrc) of
                -- Fixed-size source -- easy.
                (BIJust size, _) -> return size
                -- Variable-size source -- it must be an array, so multiply
                -- together the dimensions.
                (_, A.Array ds t) ->
                    do BIJust elementSize <- bytesInType t
                       return $ foldl mulExprs elementSize dSizes
                  where
                    srcSizes = A.Variable m $ append_sizes nSrc
                    dSizes = [case d of
                                -- Fixed dimension.
                                A.Dimension e -> e
                                -- Variable dimension -- use the corresponding
                                -- element of its _sizes array.
                                A.UnknownDimension ->
                                  A.ExprVariable m $ A.SubscriptedVariable m (A.Subscript m A.NoCheck $ makeConstant m i) srcSizes
                              | (d, i) <- zip ds [0..]]
                _ -> dieP m "Cannot compute size of source type"

            -- Build the _sizes array for the destination.
            sizeSpecType <-
              case biDest of
                -- Destination size is fixed -- so we must know the dimensions.
                BIJust _ ->
                  return $ makeStaticSizeSpec m n_sizes ds
                -- Destination has one free dimension, so we need to compute
                -- it.
                BIOneFree destSize n ->
                  let newDim = A.Dimension $ divExprs srcSize destSize
                      ds' = replaceAt n newDim ds in
                  return $ makeStaticSizeSpec m n_sizes ds'

            defineSizesName m n_sizes sizeSpecType
            return $ A.Specification m n_sizes sizeSpecType

    abbrevVarSizes :: Meta -> A.Name -> [A.Dimension] -> A.Variable -> PassM A.Specification
    abbrevVarSizes m n_sizes ds outerV
      = do -- Find the inner most variable (i.e. strip all the array subscripts)
           let (sliceSize, innerV) = findInnerVar outerV
           -- Figure out the _sizes variable to abbreviate; either the _sizes variable corresponding
           -- to the abbreviation source (for everything but record fields)
           -- or the globally declared record field _sizes constant
           varSrcSizes <- case innerV of
             A.Variable _ srcN -> return (A.Variable m $ append_sizes srcN)
             A.SubscriptedVariable _ (A.SubscriptField _ fieldName) recordV ->
               do A.Record recordName <- astTypeOf recordV
                  return (A.Variable m $ A.Name m A.VariableName $ A.nameName recordName ++ A.nameName fieldName ++ "_sizes")
           -- Get the dimensions of the source variable:
           (A.Array srcDs _) <- astTypeOf innerV
           -- Calculate the correct subscript into the source _sizes variable to get to the dimensions for the destination:
           let sizeDiff = length srcDs - length ds
               subSrcSizeVar = A.SubscriptedVariable m (A.SubscriptFromFor m (makeConstant m sizeDiff) (makeConstant m $ length ds)) varSrcSizes
               sizeType = A.Array [makeDimension m $ length ds] A.Int
               sizeSpecType = case sliceSize of
                 Just exp -> let subDims = [A.SubscriptedVariable m (A.Subscript m A.NoCheck $ makeConstant m n) varSrcSizes | n <- [1 .. (length srcDs - 1)]] in
                   A.IsExpr m A.ValAbbrev sizeType $
                     A.Literal m sizeType $ A.ArrayLiteral m $
                       [A.ArrayElemExpr exp] ++ map (A.ArrayElemExpr . A.ExprVariable m) subDims
                 Nothing -> A.Is m A.ValAbbrev sizeType subSrcSizeVar
           defineSizesName m n_sizes sizeSpecType
           return $ A.Specification m n_sizes sizeSpecType


    doGeneric :: Data t => t -> PassM t
    doGeneric = makeGeneric declareSizesArray

    doStructured :: Data a => A.Structured a -> PassM (A.Structured a)
    doStructured str@(A.Spec m sp@(A.Specification m' n spec) s)
      = do t <- typeOfSpec spec
           case (spec,t) of
             (_,Just (A.Array ds elemT)) -> 
               do sizeSpec <- if elem A.UnknownDimension ds
                    then 
                      -- At least one unknown dimension:
                      case spec of
                        -- TODO I think retyping a channel array ends up here, and probably isn't handled right
                        (A.Retypes _ _ _ v) -> retypesSizes m' (append_sizes n) ds elemT v
                        _ ->
                          let n_sizes = append_sizes n in
                          case spec of
                            A.Is _ _ _ v -> abbrevVarSizes m n_sizes ds v
                            A.IsExpr _ _ _ (A.ExprVariable _ v) -> abbrevVarSizes m n_sizes ds v
                            -- The dimensions in a literal should all be static:
                            A.IsExpr _ _ _ (A.Literal _ (A.Array ds _) _) ->
                              do let sizeSpecType = makeStaticSizeSpec m' n_sizes ds
                                 defineSizesName m' n_sizes sizeSpecType
                                 return $ A.Specification m' n_sizes sizeSpecType
                            _ -> dieP m $ "Could not handle unknown array spec: " ++ pshow spec
                    -- Everything is statically sized:
                    else do let n_sizes = append_sizes n
                                sizeSpecType = makeStaticSizeSpec m' n_sizes ds
                                sizeSpec = A.Specification m' n_sizes sizeSpecType
                            defineSizesName m' n_sizes sizeSpecType
                            return sizeSpec
                  s' <- doStructured s
                  return (A.Spec m sizeSpec $ A.Spec m sp $ s')
             (A.RecordType m _ fs, _) ->
                do s' <- doStructured s
                   fieldDeclarations <- foldM (declareFieldSizes (A.nameName n) m) s' fs
                   return $ A.Spec m sp fieldDeclarations
             _ -> doGeneric str
    doStructured s = doGeneric s

    makeStaticSizeSpec :: Meta -> A.Name -> [A.Dimension] -> A.SpecType
    makeStaticSizeSpec m n ds = makeDynamicSizeSpec m n es
      where
        es = [case d of A.Dimension e -> e | d <- ds]

    makeDynamicSizeSpec :: Meta -> A.Name -> [A.Expression] -> A.SpecType
    makeDynamicSizeSpec m n es = sizeSpecType
      where
        sizeType = A.Array [makeDimension m $ length es] A.Int
        sizeLit = A.Literal m sizeType $ A.ArrayLiteral m $ map A.ArrayElemExpr es
        sizeSpecType = A.IsExpr m A.ValAbbrev sizeType sizeLit

    declareFieldSizes :: Data a => String -> Meta -> A.Structured a -> (A.Name, A.Type) -> PassM (A.Structured a)
    declareFieldSizes prep m inner (n, A.Array ds _)
      = do let n_sizes = n {A.nameName = prep ++ A.nameName n}
               sizeSpecType = makeStaticSizeSpec m n_sizes ds
           defineSizesName m n_sizes sizeSpecType
           return $ A.Spec m (A.Specification m n_sizes sizeSpecType) inner
    declareFieldSizes _ _ s _ = return s

-- | A pass for adding _sizes parameters to PROC arguments
-- TODO in future, only add _sizes for variable-sized parameters
addSizesFormalParameters :: Data t => t -> PassM t
addSizesFormalParameters = doGeneric `extM` doSpecification
  where
    doGeneric :: Data t => t -> PassM t
    doGeneric = makeGeneric addSizesFormalParameters
    
    doSpecification :: A.Specification -> PassM A.Specification
    doSpecification (A.Specification m n (A.Proc m' sm args body))
      = do (args', newargs) <- transformFormals m args
           body' <- doGeneric body
           let newspec = A.Proc m' sm args' body'
           modify (\cs -> cs {csNames = Map.adjust (\nd -> nd { A.ndType = newspec }) (A.nameName n) (csNames cs)})
           mapM_ (recordArg m') newargs
           return $ A.Specification m n newspec
    doSpecification st = doGeneric st
    
    recordArg :: Meta -> A.Formal -> PassM ()
    recordArg m (A.Formal am t n)
      =  defineName n $ A.NameDef {
                         A.ndMeta = m
                        ,A.ndName = A.nameName n
                        ,A.ndOrigName = A.nameName n
                        ,A.ndNameType = A.VariableName
                        ,A.ndType = A.Declaration m t
                        ,A.ndAbbrevMode = A.ValAbbrev
                        ,A.ndPlacement = A.Unplaced}
    
    transformFormals :: Meta -> [A.Formal] -> PassM ([A.Formal], [A.Formal])
    transformFormals _ [] = return ([],[])
    transformFormals m ((f@(A.Formal am t n)):fs)
      = case t of
          A.Array ds _ -> do let sizeType = A.Array [makeDimension m $ length ds] A.Int
                             let newf = A.Formal A.ValAbbrev sizeType (append_sizes n)
                             (rest, moreNew) <- transformFormals m fs
                             return (f : newf : rest, newf : moreNew)
          _ -> do (rest, new) <- transformFormals m fs
                  return (f : rest, new)

-- | A pass for adding _sizes parameters to actuals in PROC calls
addSizesActualParameters :: Data t => t -> PassM t
addSizesActualParameters = doGeneric `extM` doProcess
  where
    doGeneric :: Data t => t -> PassM t
    doGeneric = makeGeneric addSizesActualParameters
    
    doProcess :: A.Process -> PassM A.Process
    doProcess (A.ProcCall m n params) = concatMapM transformActual params >>* A.ProcCall m n
    doProcess p = doGeneric p
    
    transformActual :: A.Actual -> PassM [A.Actual]
    transformActual a@(A.ActualVariable v)
      = transformActualVariable a v
    transformActual a@(A.ActualExpression (A.ExprVariable _ v))
      = transformActualVariable a v
    transformActual a = return [a]

    transformActualVariable :: A.Actual -> A.Variable -> PassM [A.Actual]
    transformActualVariable a v@(A.Variable m n)
      = do t <- astTypeOf v
           case t of
             A.Array ds _ ->
               return [a, A.ActualVariable a_sizes]
             _ -> return [a]
      where
        a_sizes = A.Variable m (append_sizes n)
    transformActualVariable a _ = return [a]

-- | Transforms all slices into the FromFor form.
simplifySlices :: Data t => t -> PassM t
simplifySlices = doGeneric `extM` doVariable
  where
    doGeneric :: Data t => t -> PassM t
    doGeneric = makeGeneric simplifySlices
    
    -- We recurse into the subscripts in case they contain subscripts:    
    doVariable :: A.Variable -> PassM A.Variable
    doVariable (A.SubscriptedVariable m (A.SubscriptFor m' for) v)
      = do for' <- doGeneric for
           v' <- doGeneric v
           return (A.SubscriptedVariable m (A.SubscriptFromFor m' (makeConstant m' 0) for') v')
    doVariable (A.SubscriptedVariable m (A.SubscriptFrom m' from) v)
      = do v' <- doGeneric v
           A.Array (d:_) _ <- astTypeOf v'
           limit <- case d of
             A.Dimension n -> return n
             A.UnknownDimension -> return $ A.SizeVariable m' v'
           from' <- doGeneric from
           return (A.SubscriptedVariable m (A.SubscriptFromFor m' from' (A.Dyadic m A.Subtr limit from')) v')
    -- We must recurse, to handle nested variables, and variables inside subscripts!
    doVariable v = doGeneric v
