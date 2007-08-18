module RainPasses where

import TestUtil
import qualified AST as A
import Pass
import Data.Generics
import Types
import CompState

--TODO add passes for:
--  Typing the variables
--  Resolving (and uniquifying) names


rainPasses :: A.Process -> PassM A.Process
rainPasses = runPasses passes
  where
    passes = 
     [ ("Uniquify variable declarations",uniquifyVars)
       ,("Convert seqeach/pareach loops into classic replicated SEQ/PAR",transformEach)
     ]

uniquifyVars :: Data t => t -> PassM t
uniquifyVars = everywhereM (mkM uniquifyVars')
  where
    uniquifyVars' :: A.Specification -> PassM A.Specification
    uniquifyVars' (A.Specification m n decl@(A.Declaration _ _)) 
      = do n' <- makeNonce $ A.nameName n
           return (A.Specification m n {A.nameName = n'} decl)
    uniquifyVars' s = return s

transformEach :: Data t => t -> PassM t
transformEach = everywhereM (mkM transformEach')
  where
    transformEach' :: A.Structured -> PassM A.Structured
    transformEach' (A.Rep m (A.ForEach m' loopVar loopExp) s)
      = do (spec,var) <- case loopExp of
             (A.ExprVariable _ v) -> return (id,v)
             _ -> do t <- typeOfExpression loopExp
                     spec@(A.Specification _ n' _) <- makeNonceIsExpr "loopVar" m t loopExp 
                     return (A.Spec m spec,A.Variable m n')
           --spec is a function A.Structured -> A.Structured, var is an A.Variable
           
           loopVarType <- typeOfName loopVar
           loopIndex <- makeNonce "loopIndex"
           let newRep = A.For m' (simpleName loopIndex) (intLiteral 0) (A.SizeVariable m' var)
           let s' = A.Spec m'
                 (A.Specification m' loopVar
                   (A.Is m' A.Abbrev loopVarType
                     (A.SubscriptedVariable m' (A.Subscript m' (A.ExprVariable m' (variable loopIndex)))  var)
                   )
                 )
                 s
           return (spec (A.Rep m newRep s'))
    transformEach' s = return s
