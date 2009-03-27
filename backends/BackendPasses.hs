{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008  University of Kent

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
module BackendPasses (addSizesActualParameters, addSizesFormalParameters, declareSizesArray, simplifySlices, backendPasses, transformWaitFor) where

import Control.Monad.State
import Data.Generics
import Data.List
import qualified Data.Map as Map
import Data.Maybe

import qualified AST as A
import CompState
import Errors
import EvalConstants
import Metadata
import Pass
import PrettyShow
import qualified Properties as Prop
import ShowCode
import Traversal
import Types
import Utils

backendPasses :: [Pass]
backendPasses =
    -- Note that removeDirections is only for C, whereas removeUnneededDirections
    -- is for all backends
  [ removeDirectionsForC
  , removeUnneededDirections
  , simplifySlices
  , declareSizesArray
  , addSizesFormalParameters
  , addSizesActualParameters
  , fixMinInt
-- This is not needed unless forking:
--  , mobileReturn
  ]

prereq :: [Property]
prereq = Prop.agg_namesDone ++ Prop.agg_typesDone ++ Prop.agg_functionsGone ++ [Prop.subscriptsPulledUp, Prop.arrayLiteralsExpanded]

-- | Remove all variable directions for the C backend.
-- They're unimportant in occam code once the directions have been checked,
-- and this somewhat simplifies the work of the later passes.
removeDirectionsForC :: Pass
removeDirectionsForC
    = occamAndCOnlyPass "Remove variable directions"
                    prereq
                    [Prop.directionsRemoved]
                    (applyDepthM (return . doVariable))
  where
    doVariable :: A.Variable -> A.Variable
    doVariable (A.DirectedVariable _ _ v) = v
    doVariable v = v

-- | Remove variable directions that are superfluous.  This prevents confusing
-- later passes, where the user has written something like:
-- []CHAN INT da! IS ...:
-- foo(da!)
--
-- The second direction specifier is unneeded, and will confuse passes such as
-- those adding sizes parameters (which looks for plain variables, since directed
-- arrays should already have been pulled up).
removeUnneededDirections :: Pass
removeUnneededDirections
  = occamOnlyPass "Remove unneeded variable directions"
                  prereq
                  []
                  (applyDepthM doVariable)
  where
    doVariable :: Transform (A.Variable)
    doVariable whole@(A.DirectedVariable m dir v)
       = do t <- astTypeOf v
            case t of
              A.Chan {} -> return whole
              A.Array _ (A.Chan {}) -> return whole
              A.ChanEnd chanDir _ _ | dir == chanDir -> return v
              A.Array _ (A.ChanEnd chanDir _ _) | dir == chanDir -> return v
              _ -> diePC m $ formatCode "Direction applied to non-channel type: %" t
    doVariable v = return v

-- | Turns any literals equivalent to a MOSTNEG back into a MOSTNEG
-- The reason for doing this is that C (and presumably C++) don't technically (according
-- to the standard) allow you to write INT_MIN directly as a constant.  GCC certainly
-- warns about it.  So this pass takes any MOSTNEG-equivalent values (that will have been
-- converted to constants in the constant folding earlier) and turns them back
-- into MOSTNEG, for which the C backend uses INT_MIN and similar, which avoid
-- this problem.
fixMinInt :: Pass
fixMinInt
  = cOrCppOnlyPass "Turn any literals that are equal to MOSTNEG INT back into MOSTNEG INT"
                   prereq
                   []
                   (applyDepthM doExpression)
  where
    doExpression :: Transform (A.Expression)
    doExpression l@(A.Literal m t (A.IntLiteral m' s))
      = do folded <- constantFold (A.MostNeg m t)
           case folded of
             (A.Literal _ _ (A.IntLiteral _ s'), _, _)
               -> if (s == s')
                    then return $ A.MostNeg m t
                    else return l
             _ -> return l -- This can happen as some literals retain the Infer
                           -- type which fails the constant folding
    doExpression e = return e

transformWaitFor :: Pass
transformWaitFor = cOnlyPass "Transform wait for guards into wait until guards"
  []
  [Prop.waitForRemoved]
  (applyDepthM doAlt)
  where
    doAlt :: A.Process -> PassM A.Process
    doAlt a@(A.Alt m pri s)
      = do (s',(specs,code)) <- runStateT (transformOnly doWaitFor s) ([],[])
           if (null specs && null code)
             then return a
             else return $ A.Seq m $ foldr addSpec (A.Several m (code ++ [A.Only m $ A.Alt m pri s'])) specs
    doAlt p = return p
    
    addSpec :: Data a => (A.Structured a -> A.Structured a) -> A.Structured a -> A.Structured a
    addSpec spec inner = spec inner

    doWaitFor :: Meta -> A.Alternative -> StateT ([A.Structured A.Process -> A.Structured A.Process], [A.Structured A.Process]) PassM (A.Structured A.Alternative)
    doWaitFor m'' a@(A.Alternative m cond tim (A.InputTimerFor m' e) p)
      = do (specs, init) <- get
           id <- lift $ makeNonce "waitFor"
           let n = A.Name m id
           let var = A.Variable m n
           put (specs ++ [A.Spec m (A.Specification m n (A.Declaration m A.Time))], 
                init ++ [A.Only m $ A.Input m tim
                           (A.InputTimerRead m (A.InVariable m var)),
                         A.Only m $ A.Assign m [var] $ A.ExpressionList m [A.Dyadic m A.Plus (A.ExprVariable m var) e]])
           return $ A.Only m'' $ A.Alternative m cond tim (A.InputTimerAfter m' (A.ExprVariable m' var)) p
               
    doWaitFor m a = return $ A.Only m a

append_sizes :: A.Name -> A.Name
append_sizes n = n {A.nameName = A.nameName n ++ "_sizes"}


-- | Declares a _sizes array for every array, statically sized or dynamically sized.
-- For each record type it declares a _sizes array too.
declareSizesArray :: Pass
declareSizesArray = occamOnlyPass "Declare array-size arrays"
  (prereq ++ [Prop.slicesSimplified, Prop.arrayConstructorsRemoved])
  [Prop.arraySizesDeclared]
  (applyDepthSM doStructured)
  where
    defineSizesName :: Meta -> A.Name -> A.SpecType -> PassM ()
    defineSizesName m n spec
      = defineName n $ A.NameDef { A.ndMeta = m
                                 , A.ndName = A.nameName n
                                 , A.ndOrigName = A.nameName n
                                 , A.ndSpecType = spec
                                 , A.ndAbbrevMode = A.ValAbbrev
                                 , A.ndNameSource = A.NameNonce
                                 , A.ndPlacement = A.Unplaced
                                 }

    -- Strips all the array subscripts from a variable:
    findInnerVar :: A.Variable -> (Maybe A.Expression, A.Variable)
    findInnerVar wv@(A.SubscriptedVariable m sub v) = case sub of
      A.SubscriptField {} -> (Nothing, wv)
      A.SubscriptFromFor _ _ _ for -> (Just for, snd $ findInnerVar v) -- Keep the outer most
      A.Subscript {} -> findInnerVar v
    findInnerVar (A.DirectedVariable _ _ v) = findInnerVar v
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
             A.Variable _ srcN -> return (A.ExprVariable m $ A.Variable m $ append_sizes srcN)
             A.SubscriptedVariable _ (A.SubscriptField _ fieldName) recordV ->
               do A.Record recordName <- astTypeOf recordV
                  return (A.ExprVariable m $ A.Variable m $ A.Name m $ A.nameName recordName ++ A.nameName fieldName ++ "_sizes")
             A.DirectedVariable _ _ (A.Variable _ srcN) -> return (A.ExprVariable
               m $ A.Variable m $ append_sizes srcN)
             _ -> return $ A.AllSizesVariable m innerV
           -- Get the dimensions of the source variable:
           innerVT <- astTypeOf innerV
           srcDs <- case innerVT of
                      (A.Array srcDs _) -> return srcDs
                      _ -> diePC m $ formatCode ("Unexpected type in abbrev var"
                               ++ " (%) in declareSizesArray: %") innerV innerVT
           -- Calculate the correct subscript into the source _sizes variable to get to the dimensions for the destination:
           let sizeDiff = length srcDs - length ds
               subSrcSizeVar = A.SubscriptedExpr m (A.SubscriptFromFor m A.NoCheck (makeConstant m sizeDiff) (makeConstant m $ length ds)) varSrcSizes
               sizeType = A.Array [makeDimension m $ length ds] A.Int
               sizeExpr = case sliceSize of
                 Just exp -> let subDims = [A.SubscriptedExpr m (A.Subscript m A.NoCheck $ makeConstant m n) varSrcSizes | n <- [1 .. (length srcDs - 1)]] in
                   A.Literal m sizeType $ A.ArrayListLiteral m $ A.Several m $
                     A.Only m exp : map (A.Only m) subDims
                 Nothing -> subSrcSizeVar
               sizeSpecType = A.Is m A.ValAbbrev sizeType (A.ActualExpression sizeExpr)
           defineSizesName m n_sizes sizeSpecType
           return $ A.Specification m n_sizes sizeSpecType

    doStructured :: Data a => A.Structured a -> PassM (A.Structured a)
    doStructured str@(A.Spec m sp@(A.Specification m' n spec) s)
      = do t <- typeOfSpec spec
           case (spec, t) of
             (_, Just (A.Array ds elemT)) ->
               do let n_sizes = append_sizes n
                  let defineStaticSizes ds
                        = do let st = makeStaticSizeSpec m' n_sizes ds
                             defineSizesName m' n_sizes st
                             return $ A.Specification m' n_sizes st
                  sizeSpec <-
                    if elem A.UnknownDimension ds
                      -- At least one unknown dimension:
                      then case spec of
                             -- TODO I think retyping a channel array ends up
                             -- here, and probably isn't handled right
                             A.Retypes _ _ _ v ->
                               retypesSizes m' n_sizes ds elemT v
                             A.Is _ _ _ (A.ActualVariable v) ->
                               abbrevVarSizes m n_sizes ds v
                             A.Is _ _ _ (A.ActualChannelArray vs) ->
                               defineStaticSizes [makeDimension m' (length vs)]
                             A.Is _ _ _ (A.ActualExpression (A.ExprVariable _ v)) ->
                               abbrevVarSizes m n_sizes ds v
                             -- The dimensions in a literal should all be
                             -- static:
                             A.Is _ _ _ (A.ActualExpression (A.Literal _ (A.Array ds' _) _)) ->
                               defineStaticSizes ds'
                             _ ->
                               dieP m $ "Could not handle unknown array spec: "
                                        ++ pshow spec
                      -- Everything is statically sized:
                      else defineStaticSizes ds
                  return (A.Spec m sizeSpec $ A.Spec m sp $ s)
             (A.RecordType m _ fs, _) ->
               do fieldDeclarations <-
                    foldM (declareFieldSizes (A.nameName n) m) s fs
                  return $ A.Spec m sp fieldDeclarations
             _ -> return str
    doStructured s = return s

    makeStaticSizeSpec :: Meta -> A.Name -> [A.Dimension] -> A.SpecType
    makeStaticSizeSpec m n ds = makeDynamicSizeSpec m n es
      where
        es = [case d of A.Dimension e -> e | d <- ds]

    makeDynamicSizeSpec :: Meta -> A.Name -> [A.Expression] -> A.SpecType
    makeDynamicSizeSpec m n es = sizeSpecType
      where
        sizeType = A.Array [makeDimension m $ length es] A.Int
        sizeLit = A.Literal m sizeType $ A.ArrayListLiteral m $ A.Several m $ map (A.Only m) es
        sizeSpecType = A.Is m A.ValAbbrev sizeType $ A.ActualExpression sizeLit

    declareFieldSizes :: Data a => String -> Meta -> A.Structured a -> (A.Name, A.Type) -> PassM (A.Structured a)
    declareFieldSizes prep m inner (n, A.Array ds _)
      = do let n_sizes = n {A.nameName = prep ++ A.nameName n}
               sizeSpecType = makeStaticSizeSpec m n_sizes ds
           defineSizesName m n_sizes sizeSpecType
           return $ A.Spec m (A.Specification m n_sizes sizeSpecType) inner
    declareFieldSizes _ _ s _ = return s

-- | A pass for adding _sizes parameters to PROC arguments
-- TODO in future, only add _sizes for variable-sized parameters
addSizesFormalParameters :: Pass
addSizesFormalParameters = occamOnlyPass "Add array-size arrays to PROC headers"
  (prereq ++ [Prop.arraySizesDeclared])
  []
  (\t -> do t' <- applyDepthM (doSpecification False) t
            cs <- getCompState
            sequence_ [doSpecification True $ A.Specification emptyMeta (A.Name emptyMeta n)
                         (A.Proc emptyMeta (A.PlainSpec, A.PlainRec)
                           fs (A.Skip emptyMeta))
                      | (n, fs) <- csExternals cs]
            return t')
  where
    doSpecification :: Bool -> A.Specification -> PassM A.Specification
    doSpecification ext (A.Specification m n (A.Proc m' sm args body))
      = do (args', newargs) <- transformFormals ext m args
           let newspec = A.Proc m' sm args' body
           modify (\cs -> cs {csNames = Map.adjust (\nd -> nd { A.ndSpecType = newspec }) (A.nameName n) (csNames cs)})
           mapM_ (recordArg m') newargs
           return $ A.Specification m n newspec
    doSpecification _ st = return st
    
    recordArg :: Meta -> A.Formal -> PassM ()
    recordArg m (A.Formal am t n)
      =  defineName n $ A.NameDef {
                         A.ndMeta = m
                        ,A.ndName = A.nameName n
                        ,A.ndOrigName = A.nameName n
                        ,A.ndSpecType = A.Declaration m t
                        ,A.ndAbbrevMode = A.ValAbbrev
                        ,A.ndNameSource = A.NameNonce
                        ,A.ndPlacement = A.Unplaced}
    
    transformFormals :: Bool -> Meta -> [A.Formal] -> PassM ([A.Formal], [A.Formal])
    transformFormals _ _ [] = return ([],[])
    transformFormals ext m ((f@(A.Formal am t n)):fs)
      = case (t, ext) of
          (A.Array ds _, False) ->
                          do let sizeType = A.Array [makeDimension m $ length ds] A.Int
                             let newf = A.Formal A.ValAbbrev sizeType (append_sizes n)
                             (rest, moreNew) <- transformFormals ext m fs
                             return (f : newf : rest, newf : moreNew)
          (A.Array ds _, True) ->
                          do params <- replicateM (length ds) $ makeNonce "ext_size"
                             let newfs = map (A.Formal A.ValAbbrev A.Int . A.Name m) params
                             (rest, moreNew) <- transformFormals ext m fs
                             return (f : newfs ++ rest, newfs ++ moreNew)
          _ -> do (rest, new) <- transformFormals ext m fs
                  return (f : rest, new)

-- | A pass for adding _sizes parameters to actuals in PROC calls
addSizesActualParameters :: Pass
addSizesActualParameters = occamOnlyPass "Add array-size arrays to PROC calls"
  (prereq ++ [Prop.arraySizesDeclared])
  []
  (applyDepthM doProcess)
  where
    doProcess :: A.Process -> PassM A.Process
    doProcess (A.ProcCall m n params)
      = do ext <- getCompState >>* csExternals >>* lookup (A.nameName n) >>* isJust
           concatMapM (transformActual ext) params >>* A.ProcCall m n
    doProcess p = return p

    transformActual :: Bool -> A.Actual -> PassM [A.Actual]
    transformActual ext a@(A.ActualVariable v)
      = transformActualVariable ext a v
    transformActual ext a@(A.ActualExpression (A.ExprVariable _ v))
      = transformActualVariable ext a v
    transformActual _ a = return [a]

    transformActualVariable :: Bool -> A.Actual -> A.Variable -> PassM [A.Actual]
    transformActualVariable ext a v
      = do t <- astTypeOf v
           case (t, ext) of
             (A.Array ds _, False) ->
                return [a, A.ActualExpression $ sizes v]
             (A.Array ds _, True) ->
                let acts = map sub [0 .. (length ds - 1)]
                in return $ a : acts
             _ -> return [a]
      where
        sizes v@(A.Variable m _) = A.AllSizesVariable m v
        sizes (A.DerefVariable _ v) = sizes v
        sizes (A.DirectedVariable _ _ v) = sizes v
        sizes (A.SubscriptedVariable _ _ v) = sizes v

        m = findMeta v

        sub n = A.ActualExpression $ A.SubscriptedExpr m
          (A.Subscript m A.NoCheck $ makeConstant m n)
          (sizes v)

-- | Transforms all slices into the FromFor form.
simplifySlices :: Pass
simplifySlices = occamOnlyPass "Simplify array slices"
  prereq
  [Prop.slicesSimplified]
  (applyDepthM doVariable)
  where
    doVariable :: A.Variable -> PassM A.Variable
    doVariable (A.SubscriptedVariable m (A.SubscriptFor m' check for) v)
      = return (A.SubscriptedVariable m (A.SubscriptFromFor m' check (makeConstant m' 0) for) v)
    doVariable (A.SubscriptedVariable m (A.SubscriptFrom m' check from) v)
      = do A.Array (d:_) _ <- astTypeOf v
           limit <- case d of
             A.Dimension n -> return n
             A.UnknownDimension -> return $ A.SizeVariable m' v
           return (A.SubscriptedVariable m (A.SubscriptFromFor m' check from (A.Dyadic m A.Subtr limit from)) v)
    doVariable v = return v

-- | Finds all processes that have a MOBILE parameter passed in Abbrev mode, and
-- add the communication back at the end of the process.
mobileReturn :: Pass
mobileReturn = cOnlyPass "Add MOBILE returns" [] [] recurse
  where
    ops = baseOp `extOpS` doStructured `extOp` doProcess

    descend, recurse :: Data a => Transform a
    descend = makeDescend ops
    recurse = makeRecurse ops

    ignoreProc :: A.Name -> PassM Bool
    ignoreProc n
      = do nd <- lookupName n
           return $ "copy_" `isPrefixOf` A.ndOrigName nd -- Bit of a hard-hack

    doProcess :: Transform A.Process
    doProcess (A.ProcCall m n as)
      = do sp <- specTypeOfName n
           fs <- case sp of
             A.Proc _ _ fs _ -> return fs
             _ -> dieP m "PROC with unknown spec-type"
           ig <- ignoreProc n
           if ig
             then return $ A.ProcCall m n as
             else do (surr, as') <- addChansAct m $ zip fs as
                     return $ surr $ A.ProcCall m n as'
    doProcess p = descend p

    chanT t = A.Chan (A.ChanAttributes A.Unshared A.Unshared) t

    addChansAct :: Meta -> [(A.Formal, A.Actual)] -> PassM (A.Process -> A.Process, [A.Actual])
    addChansAct _ [] = return (id, [])
    addChansAct m ((A.Formal am t n, a):fas)
      = do isMobile <- isMobileType t
           (recF, recAS) <- addChansAct m fas
           case (am, isMobile) of
             (A.Abbrev, True)
               -> do sp@(A.Specification _ c _) <- defineNonce m (A.nameName n)
                       (A.Declaration m $ chanT t) A.Original
                     let av = getV a
                     return (\p -> A.Seq m $ A.Spec m sp $ A.Several m
                               [A.Only m (recF p)
                               ,A.Only m $ A.Input m (A.Variable m c) $
                                 A.InputSimple m [A.InVariable m av]]
                            , a : A.ActualVariable (A.Variable m c) : recAS)
             _ -> return (recF, a : recAS)

    getV (A.ActualVariable v) = v
    getV (A.ActualExpression (A.ExprVariable _ v)) = v

    addChansForm :: Meta -> [A.Formal] -> PassM ([A.Process], [A.Formal])
    addChansForm _ [] = return ([], [])
    addChansForm m (f@(A.Formal am t n):fs)
      = do (ps, fs') <- addChansForm m fs
           isMobile <- isMobileType t
           case (am, isMobile) of
             (A.Abbrev, True)
               -> do A.Specification _ c _ <- defineNonce m (A.nameName n)
                       (A.Declaration m $ chanT t) A.Abbrev
                     modifyName n $ \nd -> nd {A.ndAbbrevMode = A.Original}
                     return ( ps ++ [A.Output m (A.Variable m c)
                                      [A.OutExpression m
                                         $ A.ExprVariable m $ A.Variable m n]]
                            , A.Formal A.Original t n : A.Formal A.Abbrev (chanT t) c : fs')
             _ -> return (ps, f : fs')

    doStructured :: Data a => Transform (A.Structured a)
    doStructured s@(A.Spec msp (A.Specification m n (A.Proc m' sm fs pr)) scope)
      = do pr' <- recurse pr
           -- We do the scope first, so that all the callers are updated before
           -- we fix our state:
           scope' <- recurse scope
           ig <- ignoreProc n
           if ig
             then return $ A.Spec msp (A.Specification m n (A.Proc m' sm fs pr')) scope'
             else do (ps, fs') <- addChansForm m fs
                     let newSpec = A.Proc m' sm fs' (A.Seq m' $ A.Several m' $
                                            map (A.Only m') $ pr' : ps)
                     modifyName n (\nd -> nd {A.ndSpecType = newSpec})
                     return $ A.Spec msp (A.Specification m n newSpec) scope'
    doStructured s = descend s
