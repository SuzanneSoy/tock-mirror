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
module Check (checkInitVar, usageCheckPass) where

import Control.Monad.Identity
import Control.Monad.Trans
import Data.Generics
import Data.Graph.Inductive
import Data.List hiding (union)
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Set as Set

import ArrayUsageCheck
import qualified AST as A
import CompState
import Errors
import FlowAlgorithms
import FlowGraph
import Metadata
import Pass
import ShowCode
import UsageCheckAlgorithms
import UsageCheckUtils
import Utils

usageCheckPass :: A.AST -> PassMR A.AST
usageCheckPass t = do g' <- buildFlowGraph labelFunctions t
                      (g, roots) <- case g' of
                        Left err -> dieP (findMeta t) err
                        Right (g,rs) -> return (g,rs)
                      checkPar nodeRep (joinCheckParFunctions checkArrayUsage checkPlainVarUsage) g
                      checkParAssignUsage t
                      checkProcCallArgsUsage t
                      mapM_ (checkInitVar (findMeta t) g) roots
                      return t

filterPlain :: Set.Set Var -> Set.Set Var
filterPlain = Set.filter plain
  where
    plain (Var (A.Variable {})) = True
    plain _ = False

filterPlain' :: ExSet Var -> ExSet Var
filterPlain' Everything = Everything
filterPlain' (NormalSet s) = NormalSet $ filterPlain s

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

checkPlainVarUsage :: forall m. (Die m, CSMR m) => (Meta, ParItems UsageLabel) -> m ()
checkPlainVarUsage (m, p) = check p
  where
    getVars :: ParItems UsageLabel -> Vars
    getVars (SeqItems ss) = foldUnionVars $ map nodeVars ss
    getVars (ParItems ps) = foldUnionVars $ map getVars ps
    getVars (RepParItem _ p) = getVars p
      
    check :: ParItems UsageLabel -> m ()
    check (SeqItems {}) = return ()
    check (ParItems ps) = sequence_ $ permuteHelper checkCREW (map getVars ps)
    check (RepParItem _ p) = check (ParItems [p,p]) -- Easy way to check two replicated branches
    
    checkCREW :: Vars -> [Vars] -> m ()
    checkCREW item rest
      = do when (not $ Set.null writtenTwice) $
             diePC m $ formatCode
               "The following variables are written-to in at least two places inside a PAR: %" writtenTwice
           when (not $ Set.null writtenAndRead) $
             diePC m $ formatCode
               "The following variables are written-to and read-from in separate branches of a PAR: %" writtenAndRead
      where
        writtenTwice = filterPlain $ writtenVars item `Set.intersection` writtenVars otherVars
        writtenAndRead = filterPlain $ writtenVars item `Set.intersection` readVars otherVars
        otherVars = foldUnionVars rest

-- | A custom Set wrapper that allows for easy representation of the "everything" set.
-- In most instances, we could actually build the everything set, but
-- representing it this way is easier, more efficient, and more readable.
-- As you would expect, Everything `intersection` x = x, and Everything `union` x = Everything.
data Ord a => ExSet a = Everything | NormalSet (Set.Set a) deriving (Eq, Show)

intersection :: Ord a => ExSet a -> ExSet a -> ExSet a
intersection Everything x = x
intersection x Everything = x
intersection (NormalSet a) (NormalSet b) = NormalSet (Set.intersection a b)

union :: Ord a => ExSet a -> ExSet a -> ExSet a
union Everything _ = Everything
union _ Everything = Everything
union (NormalSet a) (NormalSet b) = NormalSet (Set.union a b)

unions :: Ord a => [ExSet a] -> ExSet a
unions [] = emptySet
unions ss = foldl1 union ss

emptySet :: Ord a => ExSet a
emptySet = NormalSet (Set.empty)

isSubsetOf :: Ord a => ExSet a -> ExSet a -> Bool
-- Clause order is important here.  Everything is a subset of Everything so this must come first:
isSubsetOf _ Everything = True
isSubsetOf Everything _ = False
isSubsetOf (NormalSet a) (NormalSet b) = Set.isSubsetOf a b

difference :: Ord a => ExSet a -> ExSet a -> ExSet a
difference _ Everything = NormalSet Set.empty
difference Everything _ = Everything
difference (NormalSet a) (NormalSet b) = NormalSet $ Set.difference a b

showCodeExSet :: (CSMR m, Ord a, ShowOccam a, ShowRain a) => ExSet a -> m String
showCodeExSet Everything = return "<all-vars>"
showCodeExSet (NormalSet s)
    = do ss <- mapM showCode (Set.toList s)
         return $ "{" ++ concat (intersperse ", " ss) ++ "}"

-- | Checks that no variable is used uninitialised.  That is, it checks that every variable is written to before it is read.
checkInitVar :: forall m. (Monad m, Die m, Warn m, CSMR m) => Meta -> FlowGraph m UsageLabel -> Node -> m ()
checkInitVar m graph startNode
  = do startLabel <- checkJust (Just m, "Could not find starting node in the control-flow graph")
         (lab graph startNode) >>* writeNode
       vwb <- case flowAlgorithm graphFuncs connectedNodes (startNode, startLabel) of
         Left err -> dieP m $ "Error building control-flow graph: " ++ err
         Right x -> return x
       -- Label the connected nodes:
       -- We should always be able to find the labels for the graphs, but we still use checkJust rather than fromJust
       labelledConnectedNodes <- flip mapM connectedNodes (\n -> seqPair (return n,
         checkJust (Just m, "Could not find label for node in checkInitVar") (lab graph n)))
       -- vwb is a map from Node to a set of Vars that have been written by that point
       -- Now we check that for every variable read in each node, it has already been written to by then
       mapM_ (checkInitVar' vwb) (map readNode labelledConnectedNodes)
  where
    connectedNodes = dfs [startNode] graph

    -- Gets all variables read-from in a particular node, and the node identifier
    readNode :: (Node, FNode m UsageLabel) -> (Node, ExSet Var)
    readNode (n, nd) = (n,NormalSet $ readVars $ nodeVars $ getNodeData nd)
  
    -- Gets all variables written-to in a particular node
    writeNode :: FNode m UsageLabel -> ExSet Var
    writeNode nd = NormalSet $ writtenVars $ nodeVars $ getNodeData nd
    
    -- Nothing is treated as if were the set of all possible variables:
    nodeFunction :: (Node, EdgeLabel) -> ExSet Var -> Maybe (ExSet Var) -> ExSet Var
    nodeFunction (n,_) inputVal Nothing = union inputVal (maybe emptySet writeNode (lab graph n))    
    nodeFunction (n, EEndPar _) inputVal (Just prevAgg) = unions [inputVal,prevAgg,maybe emptySet writeNode (lab graph n)]
    nodeFunction (n, _) inputVal (Just prevAgg) = intersection prevAgg $ union inputVal (maybe emptySet writeNode (lab graph n))
  
    graphFuncs :: GraphFuncs Node EdgeLabel (ExSet Var)
    graphFuncs = GF
      {
       nodeFunc = nodeFunction
       ,nodesToProcess = lpre graph
       ,nodesToReAdd = lsuc graph
       ,defVal = Everything
       ,userErrLabel = show
      }
      
    getMeta :: Node -> Meta
    getMeta n = case lab graph n of
      Just nd -> getNodeMeta nd
      _ -> emptyMeta
        
    checkInitVar' :: Map.Map Node (ExSet Var) -> (Node, ExSet Var) -> m ()
    checkInitVar' writtenMap (n,v)
      = let vs = fromMaybe emptySet (Map.lookup n writtenMap) in
        -- The read-from set should be a subset of the written-to set:
        if filterPlain' v `isSubsetOf` filterPlain' vs then return () else 
          do vars <- showCodeExSet $ filterPlain' v `difference` filterPlain' vs
             addWarning (getMeta n) $ "Variable(s) read from are not written to before-hand: " ++ vars

checkParAssignUsage :: forall m t. (CSMR m, Die m, MonadIO m, Data t) => t -> m ()
checkParAssignUsage = mapM_ checkParAssign . listify isParAssign
  where
    isParAssign :: A.Process -> Bool
    isParAssign (A.Assign _ vs _) = length vs >= 2
    isParAssign _ = False

    -- | Need to check that all the destinations in a parallel assignment
    -- are distinct.  So we check plain variables, and array variables
    checkParAssign :: A.Process -> m ()
    checkParAssign (A.Assign m vs _)
      = do checkPlainVarUsage (m, mockedupParItems)
           checkArrayUsage (m, mockedupParItems)
      where
        mockedupParItems :: ParItems UsageLabel
        mockedupParItems = ParItems [SeqItems [Usage Nothing Nothing $ processVarW v] | v <- vs]


checkProcCallArgsUsage :: forall m t. (CSMR m, Die m, MonadIO m, Data t) => t -> m ()
checkProcCallArgsUsage = mapM_ checkArgs . listify isProcCall
  where
    isProcCall :: A.Process -> Bool
    isProcCall (A.ProcCall {}) = True
    isProcCall _ = False

    -- | Need to check that all the destinations in a parallel assignment
    -- are distinct.  So we check plain variables, and array variables
    checkArgs :: A.Process -> m ()
    checkArgs p@(A.ProcCall m _ _)
      = do vars <- getVarProcCall p
           let mockedupParItems = ParItems [SeqItems [Usage Nothing Nothing v]
                                            | v <- vars]
           checkPlainVarUsage (m, mockedupParItems)
           checkArrayUsage (m, mockedupParItems)
