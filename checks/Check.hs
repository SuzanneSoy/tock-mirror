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

-- | This code implements various usage checking.  It is designed to work with
-- the control-flow graph stuff, hence the use of functions that match the dictionary
-- of functions in FlowGraph.  This is also why we don't drill down into processes;
-- the control-flow graph means that we only need to concentrate on each node that isn't nested.
module Check (checkInitVarPass, usageCheckPass, checkUnusedVar) where

import Control.Monad.Identity
import Control.Monad.State
import Control.Monad.Trans
import Data.Generics
import Data.Graph.Inductive
import Data.List hiding (union)
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Set as Set

import ArrayUsageCheck
import qualified AST as A
import CheckFramework
import CompState
import Errors
import ExSet
import FlowAlgorithms
import FlowGraph
import FlowUtils
import GenericUtils
import Metadata
import Pass
import ShowCode
import Traversal
import Types
import UsageCheckAlgorithms
import UsageCheckUtils
import Utils

usageCheckPass :: A.AST -> PassM A.AST
usageCheckPass t = do g' <- buildFlowGraph labelUsageFunctions t
                      (g, roots) <- case g' of
                        Left err -> dieP (findMeta t) err
                        Right (g,rs,_) -> return (g,rs)
                      reach <- case mapM (findReachDef g) roots >>* foldl Map.union
                        Map.empty of
                          Left err -> dieP emptyMeta $ "findReachDef: " ++
                            err
                          Right r -> return r
                      cons <- case mapM (findConstraints g) roots
                                     >>* foldl Map.union Map.empty of
                                Left err -> dieP emptyMeta $ "findConstraints:"
                                  ++ err
                                Right c -> return c
                      let g' = labelMapWithNodeId (addBK reach cons g) g
                      checkPar (nodeRep . snd)
                        (joinCheckParFunctions checkArrayUsage checkPlainVarUsage)
                        g'
                      checkParAssignUsage g' t
                      checkProcCallArgsUsage g' t
--                      mapM_ (checkInitVar (findMeta t) g) roots
                      return t

addBK :: Map.Map Node (Map.Map Var (Set.Set (Maybe A.Expression))) ->
  Map.Map Node [A.Expression] -> FlowGraph PassM UsageLabel ->
  Node -> FNode PassM UsageLabel -> FNode PassM (BK, UsageLabel)
addBK mp mp2 g nid n = fmap ((,) $ (map (Map.fromListWith (++)) $ productN $ conBK ++
  repBK ++ values)) n
  where
    nodeInQuestion :: Map.Map Var (Set.Set (Maybe A.Expression))
    nodeInQuestion = fromMaybe Map.empty $ Map.lookup nid mp

    consInQuestion :: [A.Expression]
    consInQuestion = fromMaybe [] $ Map.lookup nid mp2

    conInterMed :: [([Var], [BackgroundKnowledge])]
    conInterMed = map f consInQuestion
      where
        f :: A.Expression -> ([Var], [BackgroundKnowledge])
        f e = (map Var $ listify (const True) e, g e)

        g :: A.Expression -> [BackgroundKnowledge]
        g (A.Dyadic _ op lhs rhs)
          | op == A.And = g lhs ++ g rhs
          | op == A.Eq = [Equal lhs rhs]
          | op == A.LessEq = [LessThanOrEqual lhs rhs]
          | op == A.MoreEq = [LessThanOrEqual rhs lhs]
        g _ = []

    conBK :: [[(Var, [BackgroundKnowledge])]]
    conBK = [ [(v, concatMap snd $ filter (elem v . fst) conInterMed)]
            | v <- nub $ concatMap fst conInterMed]
    
    -- Each list (xs) in the whole thing (xss) relates to a different variable
    -- Each item in a list xs is a different possible constraint on that variable
    -- (effectively joined together by OR)
    -- The items in the list of BackgroundKnowledge are joined together with
    -- AND
    values :: [[(Var, [BackgroundKnowledge])]]
    values = [ [(Var v, maybeToList $ fmap (Equal $ A.ExprVariable (findMeta v)
      v) val)  | val <- Set.toList vals]
             | (Var v, vals) <- Map.toList nodeInQuestion]
    -- Add bk based on replicator bounds
    -- Search for the node containing the replicator definition,
    -- TODO Then use background knowledge related to any variables mentioned in
    -- the bounds *at that node* not at the current node-in-question

    repBK :: [[(Var, [BackgroundKnowledge])]]
    repBK = mapMaybe (fmap mkBK . nodeRep . getNodeData . snd) $ labNodes g
      where
        --TODO only really need consider the connected nodes...

        mkBK :: (A.Name, A.Replicator) -> [(Var, [BackgroundKnowledge])]
        mkBK (n, A.For _ low count _) = [(Var v, bk)]
          where
            m = A.nameMeta n
            v = A.Variable m n
            bk = [ RepBoundsIncl v low (subOne $ A.Dyadic m A.Add low count)]
    
-- filter out replicators, leave everything else in:
filterPlain :: CSMR m => m (Var -> Bool)
filterPlain = do defs <- getCompState >>* (Map.map A.ndSpecType . csNames)
                 return $ plain defs
  where
    plain defs (Var v) = all nonRep (listify (const True :: A.Variable -> Bool) v)
      where
        nonRep (A.Variable _ n) = case Map.lookup (A.nameName n) defs of
          Just (A.Rep {}) -> False
          _ -> True
        nonRep _ = True

filterPlain' :: CSMR m => ExSet Var -> m (ExSet Var)
filterPlain' Everything = return Everything
filterPlain' (NormalSet s) = filterPlain >>* flip Set.filter s >>* NormalSet

-- | I am not sure how you could build this out of the standard functions, so I built it myself
--Takes a list (let's say Y), a function that applies to a single item and a list, and then goes through applying the function
--to each item in the list, with the rest of the list Y as a parameter.  Perhaps the code is clearer:
permuteHelper :: (a -> [a] -> b) -> [a] -> [b]
permuteHelper _ [] = []
permuteHelper func (x:xs) = permuteHelper' func [] x xs
  where
    permuteHelper' :: (a -> [a] -> b) -> [a] -> a -> [a] -> [b]
    permuteHelper' func prev cur [] = [func cur prev]
    permuteHelper' func prev cur (next:rest) = (func cur (prev ++ (next:rest))) : (permuteHelper' func (prev ++ [cur]) next rest)

data VarsBK = VarsBK {
  readVarsBK :: Map.Map Var [BK]
  ,writtenVarsBK :: Map.Map Var ([A.Expression], [BK])
}

foldUnionVarsBK :: [VarsBK] -> VarsBK
foldUnionVarsBK = foldl join (VarsBK Map.empty Map.empty)
  where
    join (VarsBK r w) (VarsBK r' w')
      = VarsBK (Map.unionWith (++) r r') (Map.unionWith (\(x,y) (x',y') -> (x++x',y++y')) w w')

checkPlainVarUsage :: forall m. (MonadIO m, Die m, CSMR m) => (Meta, ParItems (BK, UsageLabel)) -> m ()
checkPlainVarUsage (m, p) = check p
  where
    addBK :: BK -> Vars -> VarsBK
    addBK bk vs = VarsBK (Map.fromAscList $ zip (Set.toAscList $ readVars vs) (repeat [bk]))
                         (Map.map (\me -> (maybeToList me, [bk])) $ writtenVars vs)

    reps (RepParItem r p) = r : reps p
    reps (SeqItems _) = []
    reps (ParItems ps) = concatMap reps ps

    getVars :: ParItems (BK, UsageLabel) -> VarsBK
    getVars (SeqItems ss) = foldUnionVarsBK $ [addBK bk $ nodeVars u | (bk, u) <- ss]
    getVars (ParItems ps) = foldUnionVarsBK $ map getVars ps
    getVars (RepParItem _ p) = getVars p

    getDecl :: ParItems (BK, UsageLabel) -> [Var]
    getDecl (ParItems ps) = concatMap getDecl ps
    getDecl (RepParItem _ p) = getDecl p
    getDecl (SeqItems ss) = mapMaybe
      (fmap (Var . A.Variable emptyMeta . A.Name emptyMeta) . join . fmap getScopeIn . nodeDecl
        . snd) ss
      where
        getScopeIn (ScopeIn _ n) = Just n
        getScopeIn _ = Nothing

    -- Check does not have to descend, because the overall checkPlainVarUsage function
    -- will be called on every single PAR in the whole tree
    check :: ParItems (BK, UsageLabel) -> m ()
    check (SeqItems {}) = return ()
    check (ParItems ps) = sequence_ $ permuteHelper (checkCREW $ concatMap getDecl ps) (map getVars ps)
    check (RepParItem _ p) = check (ParItems [p,p]) -- Easy way to check two replicated branches
    
    checkCREW :: [Var] -> VarsBK -> [VarsBK] -> m ()
    checkCREW decl item rest
      = do sharedNames <- getCompState >>* csNameAttr >>* Map.filter (== NameShared)
             >>* Map.keysSet >>* (Set.map $ UsageCheckUtils.Var . A.Variable emptyMeta . A.Name emptyMeta)
           writtenTwice <- filterPlain >>* flip filterMapByKey
                             ((writtenVarsBK item
                                 `intersect`
                                writtenVarsBK otherVars
                              ) `difference` (Set.fromList decl `Set.union` sharedNames)
                             )
           writtenAndRead <- filterPlain >>* flip filterMapByKey
                               ((writtenVarsBK item
                                    `intersect`
                                 readVarsBK otherVars
                                ) `difference` (Set.fromList decl `Set.union` sharedNames)
                               )
           checkBKReps
               "The following variables are written-to in at least two places inside a PAR: % "
               (Map.map (transformPair snd snd) writtenTwice)
           checkBKReps
               "The following variables are written-to and read-from in separate branches of a PAR: % "
               (Map.map (transformPair snd id) writtenAndRead)
      where
        intersect :: Ord k => Map.Map k v -> Map.Map k v' -> Map.Map k (v, v')
        intersect = Map.intersectionWith (,)
        difference m s = m `Map.difference` (Map.fromAscList $ zip (Set.toAscList
          s) (repeat ()))
        otherVars = foldUnionVarsBK rest

    checkBKReps :: String -> Map.Map Var ([BK], [BK]) -> m ()
    checkBKReps _ vs | Map.null vs = return ()
    checkBKReps msg vs
      = do sols <- if null (reps p)
                     -- If there are no replicators, it's definitely dangerous:
                     then return $ Map.map (const $ [Just ""]) $ vs
                     else mapMapM (mapM (findRepSolutions (reps p)) . map (uncurry (++)) . product2) vs
           case Map.filter (not . null) $ Map.map catMaybes sols of
             vs' | Map.null vs' -> return ()
                 | otherwise -> diePC m $ formatCode (msg ++ concat (concat
                   $ Map.elems vs')) (Map.keysSet vs')

showCodeExSet :: (CSMR m, Ord a, ShowOccam a, ShowRain a) => ExSet a -> m String
showCodeExSet Everything = return "<all-vars>"
showCodeExSet (NormalSet s)
    = do ss <- mapM showCode (Set.toList s)
         return $ "{" ++ concat (intersperse ", " ss) ++ "}"

checkInitVarPass :: Pass
checkInitVarPass = pass "checkInitVar" [] []
  (passOnlyOnAST "checkInitVar" $ runChecks checkInitVar)

-- | Checks that no variable is used uninitialised.  That is, it checks that every variable is written to before it is read.
checkInitVar :: CheckOptM ()
checkInitVar = forAnyFlowNode
  (\(g, roots, _) -> sequence
     [case flowAlgorithm (graphFuncs g) (dfs [r] g) (r, writeNode (fromJust $ lab g r)) of
       Left err -> dieP emptyMeta err
       Right x -> return x
     | r <- roots] >>* foldl Map.union Map.empty)
  checkInitVar'
       -- We check that for every variable read in each node, it has already been written to by then
  where
    -- Gets all variables read-from in a particular node, and the node identifier
    readNode :: UsageLabel -> ExSet Var
    readNode u = NormalSet $ readVars $ nodeVars u
  
    -- Gets all variables written-to in a particular node
    writeNode :: Monad m => FNode m UsageLabel -> ExSet Var
    writeNode nd = NormalSet $ Map.keysSet $ writtenVars $ nodeVars $ getNodeData nd
    
    -- Nothing is treated as if were the set of all possible variables:
    nodeFunction :: Monad m => FlowGraph m UsageLabel -> (Node, EdgeLabel) -> ExSet Var -> Maybe (ExSet Var) -> ExSet Var
    nodeFunction graph (n,_) inputVal Nothing = union inputVal (maybe emptySet writeNode (lab graph n))    
    nodeFunction graph (n, EEndPar _) inputVal (Just prevAgg) = unions [inputVal,prevAgg,maybe emptySet writeNode (lab graph n)]
    nodeFunction graph (n, _) inputVal (Just prevAgg) = intersection prevAgg $ union inputVal (maybe emptySet writeNode (lab graph n))
  
    graphFuncs :: Monad m => FlowGraph m UsageLabel -> GraphFuncs Node EdgeLabel (ExSet Var)
    graphFuncs graph = GF
      {
       nodeFunc = nodeFunction graph
       ,nodesToProcess = lpre graph
       ,nodesToReAdd = lsuc graph
       ,defVal = Everything
       ,userErrLabel = ("for node at: " ++) . show . fmap getNodeMeta . lab graph
      }
      
    checkInitVar' :: CheckOptFlowM (ExSet Var) ()
    checkInitVar'
      = do (v, vs) <- getFlowLabel >>* transformPair readNode (fromMaybe emptySet)
           filtv <- filterPlain' v
           filtvs <- filterPlain' vs
        -- The read-from set should be a subset of the written-to set:
           if filtv `isSubsetOf` filtvs then return () else 
             do vars <- showCodeExSet $ filtv `difference` filtvs
                m <- getFlowMeta
                warnP m WarnUninitialisedVariable $ "Variable(s) read from are not written to before-hand: " ++ vars

findAllProcess :: forall t m a. (Data t, Monad m) =>
  (A.Process -> Bool) -> FlowGraph' m a t -> A.Structured t -> [(A.Process, a)]
findAllProcess f g t = filter (f . fst) $ mapMaybe getProcess $ map snd $ labNodes g
  where
    getProcess :: FNode' t m a -> Maybe (A.Process, a)
    getProcess n = case getNodeFunc n of
      AlterProcess f -> Just (routeGet f t, getNodeData n)
      _ -> Nothing

checkParAssignUsage :: forall m t. (CSMR m, Die m, MonadIO m, Data t) =>
  FlowGraph' m (BK, UsageLabel) t -> A.Structured t -> m ()
checkParAssignUsage g = mapM_ checkParAssign . findAllProcess isParAssign g
  where
    isParAssign :: A.Process -> Bool
    isParAssign (A.Assign _ vs _) = length vs >= 2
    isParAssign _ = False

    -- | Need to check that all the destinations in a parallel assignment
    -- are distinct.  So we check plain variables, and array variables
    checkParAssign :: (A.Process, (BK, UsageLabel)) -> m ()
    checkParAssign (A.Assign m vs _, (bk, _))
      = do checkPlainVarUsage (m, mockedupParItems)
           checkArrayUsage (m, mockedupParItems)
      where
        mockedupParItems :: ParItems (BK, UsageLabel)
        mockedupParItems = fmap ((,) bk) $ ParItems [SeqItems [Usage Nothing Nothing Nothing
          $ processVarW v Nothing] | v <- vs]


checkProcCallArgsUsage :: forall m t. (CSMR m, Die m, MonadIO m, Data t) =>
  FlowGraph' m (BK, UsageLabel) t -> A.Structured t -> m ()
checkProcCallArgsUsage g = mapM_ checkArgs . findAllProcess isProcCall g
  where
    isProcCall :: A.Process -> Bool
    isProcCall (A.ProcCall {}) = True
    isProcCall _ = False

    -- | Need to check that all the destinations in a parallel assignment
    -- are distinct.  So we check plain variables, and array variables
    checkArgs :: (A.Process, (BK, UsageLabel)) -> m ()
    checkArgs (p@(A.ProcCall m _ _), (bk, _))
      = do vars <- getVarProcCall p
           let mockedupParItems = fmap ((,) bk) $
                 ParItems [SeqItems [Usage Nothing Nothing Nothing v]
                          | v <- vars]
           checkPlainVarUsage (m, mockedupParItems)
           checkArrayUsage (m, mockedupParItems)

-- This isn't actually just unused variables, it's all unused names (except PROCs)
checkUnusedVar :: CheckOptM ()
checkUnusedVar = forAnyASTStructBottomUpAccum doSpec
  where
    doSpec :: Data a => A.Structured a -> CheckOptASTM' [A.Name] (A.Structured a) ()
     -- Don't touch PROCs, for now:
    doSpec (A.Spec _ (A.Specification mspec name (A.Proc {})) scope) = return ()
     -- DO NOT remove unused replicators!
    doSpec (A.Spec _ (A.Specification mspec name (A.Rep {})) scope) = return ()      
    doSpec (A.Spec _ (A.Specification mspec name _) scope)
      = do -- We can't remove _sizes arrays because the backend uses them for bounds
           -- checks that are not explicit in the AST.  We'll have to move the
           -- bounds checking forward into the AST before we can remove them.
           -- Making this more general, we don't actually remove any unused nonces.
           nd <- lookupName name
           when (A.ndNameSource nd == A.NameUser) $
            do usedNames <- askAccum >>* delete name
               -- ^ strip off one use of each name, since it's used in the spec
               when (not $ A.nameName name `elem` map A.nameName usedNames) $
                do warnPC mspec WarnUnusedVariable $ formatCode "Unused variable: %" name
                   modify (\st -> st { csNames = Map.delete (A.nameName name) (csNames st) })
                   substitute scope
    doSpec _ = return ()
