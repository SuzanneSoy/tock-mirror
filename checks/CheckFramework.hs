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

module CheckFramework (CheckOptM, CheckOptASTM, forAnyASTTopDown, forAnyASTStructTopDown, substitute, restartForAnyAST,
  runChecks, runChecksPass, getFlowGraph, withChild, varsTouchedAfter,
  getCachedAnalysis, getCachedAnalysis',
  forAnyFlowNode, getFlowLabel, getFlowMeta, CheckOptFlowM) where

import Control.Monad.Reader
import Control.Monad.State
import Data.Generics
import Data.Graph.Inductive hiding (apply)
import Data.List
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid
import qualified Data.Set as Set
import GHC.Base (unsafeCoerce#)

import qualified AST as A
import CompState
import Errors
import FlowAlgorithms
import FlowGraph
import FlowUtils
import GenericUtils
import Metadata
import Pass
import Traversal
import UsageCheckUtils
import Utils

-- Temp:
todo = error "TODO"

-- Each data analysis only works on a connected sub-graph.  For forward data flow
-- this begins at the root node (the one with no predecessors, and thus is the
-- direct or indirect predecessor of all nodes it is connected to), for backwards
-- data flow it begins at the terminal node (the one with no successors, and thus
-- is the direct or indirect successor of all nodes it is connected to).
--
-- Each node has a unique corresponding root (the start of the PROC/FUNCTION) and
-- similarly a unique corresponding terminal (the end of the PROC/FUNCTION).  This
-- should be guaranteed by the building of the flow graph.
--
-- Each analysis gives back a map from nodes to some sort of label-value (dependent
-- on the analysis).  This map is calculated for a given connected sub-graph.
-- If the node you are looking for appears in the connected sub-graph (the keys
-- of the map), you use that map.  Since the analyses are run before unnesting
-- takes place, it is possible to descend down the AST into a inner PROC (a different
-- sub-graph) and then back up into the outer PROC.
--
-- To prevent re-running the analysis several times where there is no need, we
-- do the following:
--
-- * Modifying any node invalidates the flow-graph.  We currently calculate
-- the flow-graph for the whole AST at once, but I can't see an easy way to avoid
-- that (a more efficient way would be to just calculate the current connected
-- sub-graph) -- perhaps we could start from the part of the AST corresponding
-- to the root node?  TODO should be possible by using the route to the root node
-- of the current graph
--
-- * Modifying a node (e.g. with substitute or replaceBelow) invalidates all analyses.
-- 
-- I did have an idea that we could invalidate only analyses that contain
-- nodes that have a route that is prefixed by that of the current node.  So
-- for example, if you modify a node with route [1,3,1], we would find all
-- nodes with routes that match (1:3:1:_) and invalidate all currently held
-- analysis results containing any of those nodes.  This would help if for
-- example you do a substitute in an inner PROC, we do not have to invalidate
-- the analysis for the outer PROC.  But this idea DOES NOT WORK because the nodes
-- will change when the flow-graph is rebuilt, so we can't let the results get
-- out of sync with the flow-graph.  Unless in future we decouple the node identifiers
-- from our use of them a bit more (but remember not to use routes, as they are
-- not unique in the flow graph).


data CheckOptData = CheckOptData
 { ast :: A.AST
 , parItems :: Maybe (ParItems ())

 , nextVarsTouched :: Map.Map Node (Set.Set Var)

 , flowGraphRootsTerms :: Maybe (FlowGraph CheckOptM UsageLabel, [Node], [Node])

 , lastValidMeta :: Meta
 }

data FlowGraphAnalysis res = FlowGraphAnalysis
  { getFlowGraphAnalysis :: CheckOptData -> Map.Map Node res
  , addFlowGraphAnalysis :: Map.Map Node res -> CheckOptData -> CheckOptData
  , doFlowGraphAnalysis :: (FlowGraph CheckOptM UsageLabel, Node) -> CheckOptM (Map.Map Node res)
  }

invalidateAll :: (A.AST -> A.AST) -> CheckOptData -> CheckOptData
invalidateAll f d = d { ast = f (ast d), parItems = Nothing, nextVarsTouched = Map.empty,
  flowGraphRootsTerms = Nothing}

newtype CheckOptM a = CheckOptM (StateT CheckOptData PassM a)
  deriving (Monad, MonadIO)

instance Die CheckOptM where
  dieReport = CheckOptM . lift . dieReport

instance MonadState CompState CheckOptM where
  get = CheckOptM $ lift get
  put = CheckOptM . lift . put

instance CSMR CheckOptM where
  getCompState = CheckOptM . lift $ getCompState

instance Warn CheckOptM where
  warnReport = CheckOptM . lift . warnReport

deCheckOptM :: CheckOptM a -> StateT CheckOptData PassM a
deCheckOptM (CheckOptM x) = x

newtype CheckOptASTM' acc t a = CheckOptASTM' (ReaderT (acc, Route t A.AST) (RestartT CheckOptM) (Either t a))

type CheckOptASTM = CheckOptASTM' ()

instance Monad (CheckOptASTM' acc t) where
  return x = CheckOptASTM' (return (Right x))
  (>>=) m f = let (CheckOptASTM' m') = m in CheckOptASTM' $ do
    x <- m'
    case x of
      Left x -> return (Left x)
      Right x -> let CheckOptASTM' m'' = f x in m''

instance MonadIO (CheckOptASTM' acc t) where
  liftIO = CheckOptASTM' . liftM Right . liftIO

instance MonadState CompState (CheckOptASTM' acc t) where
  get = CheckOptASTM' . liftM Right . lift . lift $ get
  put = CheckOptASTM' . liftM Right . lift . lift . put

deCheckOptASTM' :: (t -> CheckOptASTM' acc t ()) -> (t, Route t A.AST, acc) -> RestartT CheckOptM (Either
  t t)
deCheckOptASTM' f (x, r, acc) = do
  x' <- runReaderT (let CheckOptASTM' m = f x in m) (acc, r)
  case x' of
    Left replacement -> return (Left replacement)
    Right _ -> return (Right x)

deCheckOptASTM :: (t -> CheckOptASTM t ()) -> (t, Route t A.AST) -> RestartT CheckOptM (Either
  t t)
deCheckOptASTM f (x, r) = deCheckOptASTM' f (x,r,())


-- | The idea is this: in normal operation you use the Right return value.  When
-- you want to restart the forAnyAST operation from a given point, you use the
-- Left constructor.
data Monad m => RestartT m a = RestartT { getRestartT :: m (Either () a) }

instance Monad m => Monad (RestartT m) where
  return x = RestartT $ return (Right x)
  (>>=) m f = let m' = getRestartT m in RestartT $ do
    x <- m'
    case x of
      Left route -> return (Left route)
      Right x' -> let m'' = getRestartT $ f x' in m''

instance MonadIO m => MonadIO (RestartT m) where
  liftIO f = RestartT $ (liftIO f) >>* Right

instance MonadTrans RestartT where
  lift = RestartT . liftM Right

instance Die m => Die (RestartT m) where
  dieReport = lift . dieReport

instance Die m => Die (ReaderT (Route t outer) m) where
  dieReport = lift . dieReport

instance Die (CheckOptASTM' acc t) where
  dieReport = liftCheckOptM . dieReport

instance Warn (CheckOptASTM' acc t) where
  warnReport = liftCheckOptM . warnReport

instance CSMR (CheckOptASTM' acc t) where
  getCompState = liftCheckOptM getCompState

instance MonadState CompState (CheckOptFlowM t) where
  get = CheckOptFlowM . lift $ get
  put = CheckOptFlowM . lift . put

askRoute :: CheckOptASTM' acc t (Route t A.AST)
askRoute = CheckOptASTM' $ ask >>* snd >>* Right

getCheckOptData :: CheckOptM CheckOptData
getCheckOptData = CheckOptM get

modifyCheckOptData :: (CheckOptData -> CheckOptData) -> CheckOptM ()
modifyCheckOptData = CheckOptM . modify

liftCheckOptM :: CheckOptM a -> CheckOptASTM' acc t a
liftCheckOptM = CheckOptASTM' . liftM Right . lift . lift

-- Could also include the list of connected nodes in the reader monad:
newtype CheckOptFlowM t a = CheckOptFlowM (ReaderT (Node, Map.Map Node t) CheckOptM a)
  deriving (Monad, MonadIO)

instance Die m => Die (ReaderT (Node, Map.Map Node a) m) where
  dieReport = lift . dieReport

instance CSMR (CheckOptFlowM t) where
  getCompState = CheckOptFlowM $ lift getCompState

instance Warn (CheckOptFlowM t) where
  warnReport = CheckOptFlowM . lift . warnReport


forAnyFlowNode :: ((FlowGraph CheckOptM UsageLabel, [Node], [Node]) -> CheckOptM
  (Map.Map Node t)) -> CheckOptFlowM t () -> CheckOptM ()
forAnyFlowNode fgraph (CheckOptFlowM f) =
  do grt@(g,_,_) <- getFlowGraph
     m <- fgraph grt
     sequence_ [runReaderT f (n, m)  | n <- nodes g]

getFlowLabel :: CheckOptFlowM t (UsageLabel, Maybe t)
getFlowLabel = CheckOptFlowM $
  do (n, m) <- ask
     (g,_,_) <- lift getFlowGraph
     l <- checkJust (Nothing, "Label not in flow graph") $ lab g n
     return (getNodeData l, Map.lookup n m)

getFlowMeta :: CheckOptFlowM t Meta
getFlowMeta = CheckOptFlowM $
  do (n, _) <- ask
     (g,_,_) <- lift getFlowGraph
     case lab g n of
       Nothing -> return emptyMeta
       Just l -> return $ getNodeMeta l



forAnyParItems :: (ParItems a -> CheckOptM ()) -> CheckOptM ()
forAnyParItems = undefined


-- Like mkM, but with no return value, and this funny monad with routes, but also
-- we give an error if the plain function is ever triggered (given the typeset
-- stuff, it shouldn't be)
mkMR :: forall a. Data a => TransFunc a -> (forall b. Data b => TransFunc b)
mkMR f = plain `extMR` f
  where
    plain :: (forall c. Data c => TransFunc c)
    plain _ = dieP emptyMeta "Unexpected call of mkMR.plain"

-- Like extM, but with no return value, and this funny monad with routes:
extMR :: forall b. Data b =>
  (forall a. Data a => TransFunc a) ->
  (TransFunc b) ->
  (forall c. Data c => TransFunc c)
extMR generalF specificF (x, r) = case cast x of
  Nothing -> liftM (fromJust . cast) (generalF (x, unsafeCoerce# r))
  Just y -> liftM (fromJust . cast) (specificF (y, unsafeCoerce# r))

-- Like mkM, but with no return value, and this funny monad with routes, but also
-- we give an error if the plain function is ever triggered (given the typeset
-- stuff, it shouldn't be)
mkMRAcc :: forall a acc z. Data a => TransFuncS acc z a -> (forall b. Data b => TransFuncS acc z b)
mkMRAcc f = plain `extMRAcc` f
  where
    plain :: (forall c. Data c => TransFuncS acc z c)
    plain _ = lift $ dieP emptyMeta "Unexpected call of mkMR.plain"

-- Like extM, but with no return value, and this funny monad with routes:
extMRAcc :: forall b acc z. Data b =>
  (forall a. Data a => TransFuncS acc z a) ->
  (TransFuncS acc z b) ->
  (forall c. Data c => TransFuncS acc z c)
extMRAcc generalF specificF (x, r) = case cast x of
  Nothing -> liftM (fromJust . cast) (generalF (x, unsafeCoerce# r))
  Just y -> liftM (fromJust . cast) (specificF (y, unsafeCoerce# r))

-- | This function currently only supports one type
forAnyASTTopDown :: forall a. Data a => (a -> CheckOptASTM a ()) -> CheckOptM ()
forAnyASTTopDown origF = CheckOptM $ do
   tr <- get >>* ast
   doTree typeSet (applyTopDown typeSet (mkMR (deCheckOptASTM origF))) tr
  where
    typeSet :: TypeSet
    typeSet = makeTypeSet [typeKey (undefined :: a)]


forAnyASTStructTopDown :: (forall a. Data a => (A.Structured a -> CheckOptASTM (A.Structured
  a) ())) -> CheckOptM ()
forAnyASTStructTopDown origF = CheckOptM $ do
   tr <- get >>* ast
   doTree typeSet (applyTopDown typeSet allF) tr
  where
    allF :: (forall c. Data c => TransFunc c)
    allF
      = mkMR    (deCheckOptASTM (origF :: A.Structured A.Variant -> CheckOptASTM (A.Structured A.Variant) ()))
        `extMR` (deCheckOptASTM (origF :: A.Structured A.Process -> CheckOptASTM (A.Structured A.Process) ()))
        `extMR` (deCheckOptASTM (origF :: A.Structured A.Option -> CheckOptASTM (A.Structured A.Option) ()))
        `extMR` (deCheckOptASTM (origF :: A.Structured A.ExpressionList -> CheckOptASTM (A.Structured A.ExpressionList) ()))
        `extMR` (deCheckOptASTM (origF :: A.Structured A.Choice -> CheckOptASTM (A.Structured A.Choice) ()))
        `extMR` (deCheckOptASTM (origF :: A.Structured A.Alternative -> CheckOptASTM (A.Structured A.Alternative) ()))
        `extMR` (deCheckOptASTM (origF :: A.Structured () -> CheckOptASTM (A.Structured ()) ()))
    
    typeSet :: TypeSet
    typeSet = makeTypeSet
      [typeKey (undefined :: A.Structured A.Variant)
      ,typeKey (undefined :: A.Structured A.Process)
      ,typeKey (undefined :: A.Structured A.Option)
      ,typeKey (undefined :: A.Structured A.ExpressionList)
      ,typeKey (undefined :: A.Structured A.Choice)
      ,typeKey (undefined :: A.Structured A.Alternative)
      ,typeKey (undefined :: A.Structured ())
      ]

type TransFunc a = (a, Route a A.AST) -> RestartT CheckOptM (Either a a)
type TransFuncAcc acc a = (a, Route a A.AST, acc) -> StateT acc (RestartT CheckOptM) (Either a a)
type TransFuncS acc b a = (a, Route a b) -> StateT acc (RestartT CheckOptM) a

-- | Given a TypeSet, a function to apply to everything of type a, a route
-- location to begin at and an AST, transforms the tree.  Handles any restarts
-- that are requested.
doTree :: TypeSet -> (forall b. Data b => (b, Route b A.AST) -> RestartT CheckOptM b) ->
      A.AST -> StateT CheckOptData PassM ()
           -- This line applies "apply" to the first thing of the right type in
           -- the given AST; from there, apply recurses for itself
doTree typeSet apply tr
      = do x <- deCheckOptM (getRestartT (gmapMForRoute typeSet apply tr >> return ()))
           case x of
             Left _ -> do -- Restart
               tr' <- get >>* ast
               doTree typeSet apply tr'
             Right _ -> return ()

applyAccum :: forall acc t. (Monoid acc, Data t) => (t -> acc) -> [TypeKey] -> (forall a. Data a => TransFuncAcc acc a) ->
             (forall b. Data b => (b, Route b A.AST) -> StateT acc (RestartT CheckOptM) b)
applyAccum accF typeKeysGiven = applyAccum' 
  where
    typeSet = makeTypeSet $ typeKey (undefined :: t) : typeKeysGiven

    extF ::
       (forall a. Data a => TransFuncS acc z a) ->
       (forall c. Data c => TransFuncS acc z c)
    extF = (`extMRAcc` (\(x,_) -> modify (`mappend` accF x) >> return x))
    
    applyAccum' :: (forall a. Data a => TransFuncAcc acc a) ->
           (forall b. Data b => (b, Route b A.AST) -> StateT acc (RestartT CheckOptM) b)
    applyAccum' f (x, route)
      = do when (findMeta x /= emptyMeta) $ lift . lift . CheckOptM $ modify $ \d -> d {lastValidMeta = findMeta x}
           (x', acc) <- lift $ flip runStateT mempty (gmapMForRoute typeSet (extF wrap) x)
           f' (x', route, acc)
      where
        wrap (y, route') = applyAccum' f (y, route @-> route')
        
        -- Keep applying the function while there is a Left return (which indicates
        -- the value was replaced) until there is a Right return
        f' (x, route, acc) = do
          x' <- f (x, route, acc)
          case x' of
            Left y -> f' (y, route, acc {- TODO recalculate from scratch -})
            Right y -> return y

applyTopDown :: TypeSet -> (forall a. Data a => TransFunc a) ->
             (forall b. Data b => (b, Route b A.AST) -> RestartT CheckOptM b)
applyTopDown typeSet f (x, route)
      = do when (findMeta x /= emptyMeta) $ lift . CheckOptM $ modify $ \d -> d {lastValidMeta = findMeta x}
           z <- f' (x, route)
           gmapMForRoute typeSet (\(y, route') -> applyTopDown typeSet f (y, route @-> route')) z
  where
    -- Keep applying the function while there is a Left return (which indicates
    -- the value was replaced) until there is a Right return
    f' (x, route) = do
      x' <- f (x, route)
      case x' of
        Left y -> f' (y, route)
        Right y -> return y        

-- | For both of these functions I'm going to need to mark all analyses as no longer
-- valid, but more difficult will be to maintain the current position (if possible
-- -- should be in substitute, but not necessarily in replace) and continue.

-- | Substitutes the currently examined item for the given item, and continues
-- the traversal from the current point.  That is, the new item is transformed
-- again too.
substitute :: forall a acc. Data a => a -> CheckOptASTM' acc a ()
substitute x = CheckOptASTM' $ do
  r <- ask >>* snd
  lift . lift . CheckOptM $ modify (invalidateAll $ routeSet r x)
  return (Left x)

--replaceBelow :: t -> t -> CheckOptASTM a ()
--replaceEverywhere :: t -> t -> CheckOptASTM a ()
-- TODO think about what this means (replace everywhere, or just children?)

-- Restarts the current forAnyAST from the top of the tree, but keeps all changes
-- made thus far.
restartForAnyAST :: CheckOptASTM' acc a a
restartForAnyAST = CheckOptASTM' . lift . RestartT $ return $ Left ()

runChecks :: CheckOptM () -> A.AST -> PassM A.AST
runChecks (CheckOptM m) x = execStateT m (CheckOptData {ast = x, parItems = Nothing,
  nextVarsTouched = Map.empty, flowGraphRootsTerms = Nothing, lastValidMeta = emptyMeta}) >>* ast

runChecksPass :: CheckOptM () -> Pass
runChecksPass c = pass "<Check>" [] [] (mkM (runChecks c))

--getParItems :: CheckOptM (ParItems ())
--getParItems = CheckOptM (\d -> Right (d, fromMaybe (generateParItems $ ast d) (parItems d)))

getParItems' :: CheckOptASTM t (ParItems ())
getParItems' = todo

generateParItems :: A.AST -> ParItems ()
generateParItems = todo

-- | Performs the given action for the given child.  [0] is the first argument
-- of the current node's constructor, [2,1] is the second argument of the constructor
-- of the third argument of this constructor.  Issuing substitute inside this function
-- will yield an error.
withChild :: forall acc t a. [Int] -> CheckOptASTM' acc t a -> CheckOptASTM' acc t a
withChild ns (CheckOptASTM' m) = askRoute >>= (CheckOptASTM' . lift . inner)
  where
    inner :: Route t A.AST -> RestartT CheckOptM (Either t a)
    inner (Route rId rFunc) = runReaderT m (error "withChild asked for accum",
      Route (rId ++ ns) (error "withChild attempted a substitution"))

-- | Searches forward in the graph from the given node to find all the reachable
-- nodes that have no successors, i.e. the terminal nodes
findTerminals :: Node -> Gr a b -> [Node]
findTerminals n g = nub [x | x <- dfs [n] g, null (suc g x)]

varsTouchedAfter :: FlowGraphAnalysis (Set.Set Var)
varsTouchedAfter = FlowGraphAnalysis
  nextVarsTouched (\x d -> d {nextVarsTouched = x `Map.union` nextVarsTouched d}) $ \(g, startNode) ->
    case findTerminals startNode g of
      [] -> return Map.empty
      [termNode] -> let connNodes = rdfs [termNode] g in
        case flowAlgorithm (funcs g) connNodes (termNode, Set.empty) of
          Left err -> dieP emptyMeta err
          Right nodesToVars -> {-(liftIO $ putStrLn $ "Graph:\n" ++ show g ++ "\n\nNodes:\n"
            ++ show (termNode, connNodes)) >> -}return nodesToVars
      ts -> dieP (fromMaybe emptyMeta $ fmap getNodeMeta $ lab g startNode) $ "Multiple terminal nodes in flow graph"
              ++ show [fmap getNodeMeta (lab g n) | n <- ts]
  where
    funcs :: FlowGraph CheckOptM UsageLabel -> GraphFuncs Node EdgeLabel (Set.Set Var)
    funcs g = GF     
      { nodeFunc = iterate g
      -- Backwards data flow:
      , nodesToProcess = lsuc g
      , nodesToReAdd = lpre g
      , defVal = Set.empty
      , userErrLabel = ("for node at: " ++) . show . fmap getNodeMeta . lab g
      }

    iterate :: FlowGraph CheckOptM UsageLabel ->
      (Node, EdgeLabel) -> Set.Set Var -> Maybe (Set.Set Var) -> Set.Set Var
    iterate g node varsForPrevNode maybeVars = case lab g (fst node) of
      Just ul ->
        let vs = nodeVars $ getNodeData ul
            readFromVars = readVars vs
            writtenToVars = writtenVars vs
            addTo =  fromMaybe Set.empty maybeVars
        in foldl Set.union addTo [varsForPrevNode, readFromVars, Map.keysSet writtenToVars]
      Nothing -> error "Node label not found in calculateUsedAgainAfter"

  

getFlowGraph :: CheckOptM (FlowGraph CheckOptM UsageLabel, [Node], [Node])
getFlowGraph = getCache flowGraphRootsTerms (\x d -> d {flowGraphRootsTerms = Just x, nextVarsTouched
  = Map.empty}) generateFlowGraph

-- Makes sure that only the real last node at the end of a PROC/FUNCTION is a terminator
-- node, by joining any other nodes without successors to this node.  This is a
-- bit hacky, but is needed for some of the backwards flow analysis
correctFlowGraph :: Node -> (FlowGraph CheckOptM UsageLabel, [Node], [Node]) -> FlowGraph CheckOptM UsageLabel
correctFlowGraph curNode (g, roots, terms)
  = case findTerminals curNode g `intersect` terms of
      [] -> empty -- Not a PROC/FUNCTION
      [realTerm] -> foldl (addFakeEdge realTerm) g midTerms
  where
    -- The nodes that have no successors but are not the real terminator
    -- For example, the node after the last condition in an IF, or a STOP node
    midTerms = findTerminals curNode g \\ terms

    addFakeEdge :: Node -> FlowGraph CheckOptM UsageLabel -> Node -> FlowGraph CheckOptM UsageLabel
    addFakeEdge realTerm g n = insEdge (n, realTerm, ESeq Nothing) g

getCache :: (CheckOptData -> Maybe a) -> (a -> CheckOptData -> CheckOptData) -> (A.AST
  -> CheckOptM a) -> CheckOptM a
getCache getF setF genF = getCheckOptData >>= \x -> case getF x of
  Just y -> return y
  Nothing -> do y <- genF (ast x)
                modifyCheckOptData (setF y)
                return y

getCachedAnalysis :: Data t => FlowGraphAnalysis res -> CheckOptASTM t (Maybe res)
getCachedAnalysis = getCachedAnalysis' (const True)

-- Analysis requires the latest flow graph, and uses this to produce a result
getCachedAnalysis' :: Data t => (UsageLabel -> Bool) -> FlowGraphAnalysis res -> CheckOptASTM t (Maybe
  res)
getCachedAnalysis' f an = do
  d <- liftCheckOptM getCheckOptData
  g'@(g,_,_) <- liftCheckOptM getFlowGraph
  r <- askRoute
  -- Find the node that matches our location and the given function:
  case find (\(_,l) -> f (getNodeData l) && (getNodeRouteId l == routeId r)) (labNodes g) of
    Nothing -> {- (liftIO $ putStrLn $ "Could not find node for: " ++ show (lastValidMeta
      d)) >> -} return Nothing
    Just (n, _) ->
      case Map.lookup n (getFlowGraphAnalysis an d) of
        Just y -> return (Just y)
        Nothing -> liftCheckOptM $
                    do z <- doFlowGraphAnalysis an (correctFlowGraph n g', n)
                       CheckOptM $ modify $ addFlowGraphAnalysis an z
                       CheckOptM $ get >>* (Map.lookup n . getFlowGraphAnalysis an)

generateFlowGraph :: A.AST -> CheckOptM (FlowGraph CheckOptM UsageLabel, [Node],
  [Node])
generateFlowGraph x = buildFlowGraph labelUsageFunctions x >>= \g -> case g of
  Left err -> dieP emptyMeta err
  Right grt -> return grt

