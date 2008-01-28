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

-- #ignore-exports

{-| Generate C++ code from the mangled AST that uses the C++CSP2 library.
In order to compile the generated code, you will need:

* A standards-compliant C++98 compiler (GCC or Visual Studio >= 2003, but not Visual Studio 6).
 
* The C++CSP2 library (>= 2.0.2), available from <http://www.cppcsp.net/>, and any appropriate dependencies (e.g. Boost).

For the array handling I am currently using a combination of std::vector and an array view class (tockArrayView) I built myself.

I considered the following options:

1. in-built C arrays

2. boost::array

3. std::vector

4. boost::multi_array

5. Blitz++

6. Roll my own.

Option 1 is what Adam used in GenerateC, but it involves carrying around the array sizes, which is a real pain.
Options 2 and 3 are fairly similar (boost::array is possible because arrays are of constant size in occam) but neither supports multiple dimensions
nor array slicing, so that would have been awkward.
Option 4 does support multiple dimensions and array slicing - but the latter would involve keeping tabs of the dimensions of the *original* array
(that was sliced *from*), even through multiple slices and indexes, which would have been a nightmare.
Option 5 makes slicing nice and simple, and multiple dimensions are easy too.  However, things like retyping are still a big problem, so in the end 
it became untenable.

Therefore the only remaining option was 6.  I use std::vector (although this may become boost::array) to actually store each array, and then
use tockArrayView to work with the array.  tockArrayView represents a view of an array, and never allocates or deallocates any memory.  Thus they
can be passed around freely, which makes them easy to work with.

For the ANY type I am currently using boost::any.  However, this is not a correct solution because the type that occam pulls out is not
necessarily the type that was put in.  Therefore ANY probably needs some serialisation of types (akin to what used to happen in C++CSP.NET)
to work properly.

For the variant protocols I am using boost::variant.  But when there are more than 9 cases, I have to chain several variants together.
This is perfectly legal C++, but I think it is causing excessive memory usage in g++ (or possibly the tuples that work similarly...)

For the sequential protocols (including those after a tag in variant protocols) I am using boost::tuple for convenience (along with the handy
boost::tie function to extract the values).  However I suspect this (or the variants -- see above) is causing a lot of memory usage in g++.  Plus,
when more than 9 items are present in the protocol (including variant-tag) I have to chain the tuples together, which means chaining the tie function
as well.  May be worth changing in future.

Channels of direction 'A.DirUnknown' are passed around as pointers to a One2OneChannel\<\> object.  To read I use the reader() function and to write I use the writer() function.
For channels of direction 'A.DirInput' or 'A.DirOutput' I actually pass the Chanin\<\> and Chanout\<\> objects as you would expect.
-}
module GenerateCPPCSP (generateCPPCSP, cppgenOps, genCPPCSPPasses) where

import Control.Monad.State
import Control.Monad.Writer
import Data.Char
import Data.Generics
import Data.List
import Data.Maybe

import qualified AST as A
import CompState
import Errors
import GenerateC
import Metadata
import Pass
import ShowCode
import TLP
import Types
import Utils

--{{{  generator ops
-- | Operations for the C++CSP backend.
-- Most of this is inherited directly from the C backend in the "GenerateC" module.
cppgenOps :: GenOps
cppgenOps = cgenOps {
    declareArraySizes = cppdeclareArraySizes,
    declareFree = cppdeclareFree,
    declareInit = cppdeclareInit,
    genActual = cppgenActual,
    genActuals = cppgenActuals,
    genAllocMobile = cppgenAllocMobile,
    genAlt = cppgenAlt,
    genArraySizesLiteral = cppgenArraySizesLiteral,
    genArrayStoreName = cppgenArrayStoreName,
    genArraySubscript = cppgenArraySubscript,
    genClearMobile = cppgenClearMobile,
    genDeclType = cppgenDeclType,
    genDeclaration = cppgenDeclaration,
    genDirectedVariable = cppgenDirectedVariable,
    genForwardDeclaration = cppgenForwardDeclaration,
    genGetTime = cppgenGetTime,
    genIf = cppgenIf,
    genInputItem = cppgenInputItem,
    genOutputCase = cppgenOutputCase,
    genOutputItem = cppgenOutputItem,
    genPar = cppgenPar,
    genProcCall = cppgenProcCall,
    genRetypeSizes = cppgenRetypeSizes,
    genSizeSuffix = cppgenSizeSuffix,
    genSlice = cppgenSlice,
    genStop = cppgenStop,
    genTimerRead = cppgenTimerRead,
    genTimerWait = cppgenTimerWait,
    genTopLevel = cppgenTopLevel,
    genType = cppgenType,
    genUnfoldedExpression = cppgenUnfoldedExpression,
    genUnfoldedVariable = cppgenUnfoldedVariable,
    genWait = cppgenWait,
    getScalarType = cppgetScalarType,
    introduceSpec = cppintroduceSpec,
    removeSpec = cppremoveSpec
  }
--}}}

genCPPCSPPasses :: [(String, Pass)]
genCPPCSPPasses =
  [ ("Transform channels to ANY", chansToAny)
  ]

chansToAny :: Data t => t -> PassM t
chansToAny x = do st <- get
                  case csFrontend st of
                    FrontendOccam ->
                      do chansToAnyInCompState
                         everywhereM (mkM $ return . chansToAny') x
                    _ -> return x
  where
    chansToAny' :: A.Type -> A.Type
    chansToAny' c@(A.Chan _ _ (A.UserProtocol {})) = c
    chansToAny' (A.Chan a b _) = A.Chan a b A.Any
    chansToAny' t = t
    
    chansToAnyInCompState :: CSM m => m ()
    chansToAnyInCompState = do st <- get
                               let st' = st {csNames = everywhere (mkT chansToAny') (csNames st)}
                               put st'
                               return ()

--{{{  top-level
-- | Transforms the given AST into a pass that generates C++ code.
generateCPPCSP :: A.Structured -> PassM String
generateCPPCSP = generate cppgenOps

-- | Generates the top-level code for an AST.
cppgenTopLevel :: GenOps -> A.Structured -> CGen ()
cppgenTopLevel ops s
    =  do tell ["#include <tock_support_cppcsp.h>\n"]
          --In future, these declarations could be moved to a header file:
          sequence_ $ map (call genForwardDeclaration ops) (listify (const True :: A.Specification -> Bool) s)
          call genStructured ops s (\s -> tell ["\n#error Invalid top-level item: ",show s])
          (name, chans) <- tlpInterface
          tell ["int main (int argc, char** argv) { csp::Start_CPPCSP();"]
          (chanType,writer) <- 
                      do st <- get
                         case csFrontend st of
                           FrontendOccam -> return ("tockSendableArrayOfBytes","StreamWriterByteArray")
                           _ -> return ("uint8_t","StreamWriter")
          
          tell ["csp::One2OneChannel<",chanType,"> in,out,err;"] --TODO add streamreader          
          tell [" csp::Run( csp::InParallel (new ",writer,"(std::cout,out.reader())) (new ",writer,"(std::cerr,err.reader())) (csp::InSequenceOneThread ( new proc_"]
          genName name 
          tell ["("]
          infixComma $ map (tlpChannel ops) chans
          tell [")) (new csp::common::ChannelPoisoner< csp::Chanout<",chanType,">/**/> (out.writer())) (new csp::common::ChannelPoisoner< csp::Chanout<",chanType,">/**/> (err.writer()))   ) ); csp::End_CPPCSP(); return 0;}"]
  where
    tlpChannel :: GenOps -> (A.Direction,TLPChannel) -> CGen()
    tlpChannel ops (dir,c) = case dir of
                               A.DirUnknown -> tell ["&"] >> chanName
                               A.DirInput -> chanName >> tell [" .reader() "]
                               A.DirOutput -> chanName >> tell [" .writer() "]
                             where
                               chanName = call genTLPChannel ops c

--}}}


-- | CIF has a stop function for stopping processes.
--In C++CSP I use the exception handling to make a stop call throw a StopException,
--and the catch is placed so that catching a stop exception immediately finishes the process
cppgenStop :: GenOps -> Meta -> String -> CGen ()
cppgenStop _ m s 
  = do tell ["throw StopException("]
       genMeta m
       tell [" \"",s,"\");"]

--{{{ Two helper functions to aggregate some common functionality in this file.

-- | Generates code from a channel 'A.Variable' that will be of type Chanin\<\>
genCPPCSPChannelInput :: GenOps -> A.Variable -> CGen()
genCPPCSPChannelInput ops var
  = do t <- typeOfVariable var
       case t of
         (A.Chan A.DirInput _ _) -> call genVariable ops var
         (A.Chan A.DirUnknown _ _) -> do call genVariable ops var
                                         tell ["->reader()"]
         _ -> call genMissing ops $ "genCPPCSPChannelInput used on something which does not support input: " ++ show var

-- | Generates code from a channel 'A.Variable' that will be of type Chanout\<\>
genCPPCSPChannelOutput :: GenOps -> A.Variable -> CGen()
genCPPCSPChannelOutput ops var
  = do t <- typeOfVariable var
       case t of
         (A.Chan A.DirOutput _ _) -> call genVariable ops var
         (A.Chan A.DirUnknown _ _) -> do call genVariable ops var
                                         tell ["->writer()"]
         _ -> call genMissing ops $ "genCPPCSPChannelOutput used on something which does not support output: " ++ show var
--}}}

-- | C++CSP2 returns the number of seconds since the epoch as the time
--Since this is too large to be contained in an int once it has been multiplied,
--the remainder is taken to trim the timer back down to something that will be useful in an int
cppgenTimerRead :: GenOps -> A.Variable -> A.Variable -> CGen ()
cppgenTimerRead ops c v
    =  do tell ["csp::CurrentTime (&"]
          call genVariable ops c
          tell [");\n"]
          call genVariable ops v
          tell [" = (int)(unsigned)remainder(1000000.0 * csp::GetSeconds("]
          call genVariable ops c
          tell ["),4294967296.0);\n"]

cppgenGetTime :: GenOps -> Meta -> A.Variable -> CGen ()
cppgenGetTime ops m v
    =  do tell ["csp::CurrentTime(&"]
          call genVariable ops v
          tell [");"]

cppgenWait :: GenOps -> A.WaitMode -> A.Expression -> CGen ()
cppgenWait ops wm e
    =  do tell [if wm == A.WaitFor then "csp::SleepFor" else "csp::SleepUntil", "("]
          call genExpression ops e
          tell [");"]

{-|
Gets a csp::Time to wait with, given a 32-bit microsecond value (returns the temp variable we have put it in)


Time in occam is in microseconds, and is usually stored in the user's programs as a signed 32-bit integer.  Therefore the timer wraps round 
approx every 72 minutes.  A usual pattern of behaviour might be: 

      TIMER tim:
      INT t:
      SEQ
        tim ? t                 -- read current time
        t := t PLUS us          -- add delay
        tim ? AFTER t           -- wait until time "t"

According to Fred's occam page that I took that from, half of time delays are considered in the past and the other half are considered in the future.

Now consider C++CSP's time.  It typically has a more expressive time - on Linux, time is measured since the epoch.  Since the epoch was more 
than 72 minutes ago, this is problematic when converted to microseconds and stuffed into a 32-bit int.  I'll express C++CSP times as (HIGH, LOW) 
where LOW is the lowest 32 bits, and HIGH is the higher bits.

Getting the time for the occam programmer is quite straightforward - we retrieve the C++CSP time, and hand LOW back to the programmer as 
a 32-bit signed value (LOW is unsigned normally).

The occam programmer will now add some delay to their LOW value, making it LOWalpha.  They then ask to wait until LOWalpha.  We know that 
LOWalpha came from LOW at some point in the past and has been added to.  We need to combine it with some HIGH value, HIGHalpha to form 
(HIGHalpha, LOWalpha), the time to wait until.  So what should HIGHalpha be?

We could say that HIGHalpha = HIGH.  But if the user wrapped around LOWalpha, we actually want: HIGHalpha = HIGH + 1.  So we need to check 
if LOWalpha is a wrapped round version of LOW.  This could be done by checking whether LOWalpha < LOW.  If this is true, it must have wrapped.  
Otherwise, it must not have.
-}
genCPPCSPTime :: GenOps -> A.Expression -> CGen String
genCPPCSPTime ops e
    = do  time <- makeNonce "time_exp"
          tell ["unsigned ",time," = (unsigned)"]
          call genExpression ops e
          tell [" ; "]
          curTime <- makeNonce "time_exp"
          curTimeLow <- makeNonce "time_exp"
          curTimeHigh <- makeNonce "time_exp"
          retTime <- makeNonce "time_exp"
          tell ["double ",curTime," = csp::GetSeconds(csp::CurrentTime());"]
          tell ["unsigned ",curTimeLow," = (unsigned)remainder(1000000.0 * ",curTime,",4294967296.0);"]
          tell ["unsigned ",curTimeHigh," = (unsigned)((1000000.0 * ",curTime,") / 4294967296.0);"]
          --if time is less than curTime, it must have wrapped around so add one:
          tell ["csp::Time ",retTime," = csp::Seconds((((double)(",curTimeHigh," + TimeDiffHelper(",curTimeLow,",",time,")) * 4294967296.0) + (double)",time,") / 1000000.0);"]
          return retTime

cppgenTimerWait :: GenOps -> A.Expression -> CGen ()
cppgenTimerWait ops e
    =  do 
          time <- genCPPCSPTime ops e
          tell ["csp::SleepUntil(",time,");"]

cppgenInputItem :: GenOps -> A.Variable -> A.InputItem -> CGen ()
cppgenInputItem ops c dest
  = case dest of
      (A.InCounted m cv av) -> 
        do call genInputItem ops c (A.InVariable m cv)
           recvBytes av (
             do call genVariable ops cv
                tell ["*"]
                t <- typeOfVariable av
                subT <- trivialSubscriptType m t
                call genBytesIn ops m subT (Right av)
             )
      (A.InVariable m v) ->
        do ct <- typeOfVariable c
           t <- typeOfVariable v
           case (byteArrayChan ct,t) of
             (True,_)-> recvBytes v (call genBytesIn ops m t (Right v))
             (False,A.Array {}) -> do tell ["tockRecvArray("]
                                      chan'
                                      tell [","]
                                      call genVariable ops v
                                      tell [");"]
             (False,_) -> do chan'
                             tell [">>"]
                             genNonPoint ops v
                             tell [";"]
  where
    chan' = genCPPCSPChannelInput ops c
    recvBytes :: A.Variable -> CGen () -> CGen ()
    recvBytes v b = do tell ["tockRecvArrayOfBytes("]
                       chan'
                       tell [",tockSendableArrayOfBytes("]
                       b
                       tell [","]
                       genPoint ops v
                       tell ["));"]

cppgenOutputItem :: GenOps -> A.Variable -> A.OutputItem -> CGen ()
cppgenOutputItem ops chan item
  = case item of
      (A.OutCounted m (A.ExprVariable _ cv) (A.ExprVariable _ av)) -> (sendBytes cv) >> (sendBytes av)
      (A.OutExpression _ (A.ExprVariable _ sv)) ->
       do t <- typeOfVariable chan
          tsv <- typeOfVariable sv
          case (byteArrayChan t,tsv) of
            (True,_) -> sendBytes sv
            (False,A.Array {}) -> do tell ["tockSendArray("]
                                     chan'
                                     tell [","]
                                     call genVariable ops sv
                                     tell [");"]
            (False,_) -> do chan'
                            tell ["<<"]
                            genNonPoint ops sv
                            tell [";"]
  where
    chan' = genCPPCSPChannelOutput ops chan
    
    sendBytes v = do chan'
                     tell ["<<tockSendableArrayOfBytes("]
                     genPoint ops v
                     tell [");"]

byteArrayChan :: A.Type -> Bool
byteArrayChan (A.Chan _ _ (A.UserProtocol _)) = True
byteArrayChan (A.Chan _ _ A.Any) = True
byteArrayChan (A.Chan _ _ (A.Counted _ _)) = True
byteArrayChan _ = False

genPoint :: GenOps -> A.Variable -> CGen()
genPoint ops v = do t <- typeOfVariable v
                    when (not $ isPoint t) $ tell ["&"]
                    call genVariable ops v
genNonPoint :: GenOps -> A.Variable -> CGen()
genNonPoint ops v = do t <- typeOfVariable v
                       when (isPoint t) $ tell ["*"]
                       call genVariable ops v                    
isPoint :: A.Type -> Bool
isPoint (A.Record _) = True
isPoint (A.Array _ _) = True
isPoint _ = False

-- FIXME Should be a generic helper somewhere (along with the others from GenerateC)
-- | Helper function to place a comma between items, but not before or after
infixComma :: [CGen ()] -> CGen ()
infixComma (c0:cs) = c0 >> sequence_ [genComma >> c | c <- cs]
infixComma [] = return ()

cppgenOutputCase :: GenOps -> A.Variable -> A.Name -> [A.OutputItem] -> CGen ()
cppgenOutputCase ops c tag ois 
    =  do t <- typeOfVariable c
          let proto = case t of A.Chan _ _ (A.UserProtocol n) -> n
          tell ["tockSendInt("]
          genCPPCSPChannelOutput ops c
          tell [","]
          genName tag
          tell ["_"]
          genName proto
          tell [");"]
          call genOutput ops c ois


-- | We use the process wrappers here, in order to execute the functions in parallel.
--We use forking instead of Run\/InParallelOneThread, because it is easier to use forking with replication.
cppgenPar :: GenOps -> A.ParMode -> A.Structured -> CGen ()
cppgenPar ops _ s
  = do forking <- makeNonce "forking"
       tell ["{ csp::ScopedForking ",forking," ; "]
       call genStructured ops s (genPar' forking)
       tell [" }"]
       where
         genPar' :: String -> A.Structured -> CGen ()
         genPar' forking (A.OnlyP _ p) 
           = case p of 
             A.ProcCall _ n as -> 
               do tell [forking," .forkInThisThread(new proc_"]
                  genName n
                  tell ["("]
                  call genActuals ops as
                  tell [" ) ); "] 
             _ -> error ("trying to run something other than a process in parallel")
      


-- | Changed to use C++CSP's Alternative class:
cppgenAlt :: GenOps -> Bool -> A.Structured -> CGen ()
cppgenAlt ops _ s 
  = do guards <- makeNonce "alt_guards"
       tell ["std::list< csp::Guard* > ", guards, " ; "]
       initAltGuards guards s
       alt <- makeNonce "alt"
       tell ["csp::Alternative ",alt, " ( ", guards, " ); "]

       id <- makeNonce "alt_id"
       tell ["int ", id, " = 0;\n"]
       fired <- makeNonce "alt_fired"
       tell ["int ", fired, " = ", alt, " .priSelect();"]
       label <- makeNonce "alt_end"
       tell ["{\n"]
       genAltProcesses id fired label s
       tell ["}\n"]
       tell [label, ":\n;\n"]
  where
    --This function is like the enable function in GenerateC, but this one merely builds a list of guards.  It does not do anything other than add to the guard list
    initAltGuards :: String -> A.Structured -> CGen ()
    initAltGuards guardList s = call genStructured ops s doA
      where
        doA (A.OnlyA _ alt)
            = case alt of
                A.Alternative _ c im _ -> doIn c im
                A.AlternativeCond _ e c im _ -> withIf ops e $ doIn c im
                A.AlternativeSkip _ e _ -> withIf ops e $ tell [guardList, " . push_back( new csp::SkipGuard() );\n"]
                A.AlternativeWait _ wm e _ -> 
                  do tell [guardList, " . push_back( new ", if wm == A.WaitUntil then "csp::TimeoutGuard (" else "csp::RelTimeoutGuard("]
                     call genExpression ops e
                     tell ["));"]

        doIn c im
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing ops "timer read in ALT"
                   A.InputTimerAfter _ time ->
                     do timeVal <- genCPPCSPTime ops time
                        tell [guardList, " . push_back( new csp::TimeoutGuard (",timeVal,"));\n"]
                   _ ->
                     do tell [guardList, " . push_back( "]
                        genCPPCSPChannelInput ops c
                        tell [" . inputGuard());\n"]

    -- This is the same as GenerateC for now -- but it's not really reusable
    -- because it's so closely tied to how ALT is implemented in the backend.
    genAltProcesses :: String -> String -> String -> A.Structured -> CGen ()
    genAltProcesses id fired label s = call genStructured ops s doA
      where
        doA (A.OnlyA _ alt)
            = case alt of
                A.Alternative _ c im p -> doIn c im p
                A.AlternativeCond _ e c im p -> withIf ops e $ doIn c im p
                A.AlternativeSkip _ e p -> withIf ops e $ doCheck (call genProcess ops p)
                A.AlternativeWait _ _ _ p -> doCheck (call genProcess ops p)

        doIn c im p
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing ops "timer read in ALT"
                   A.InputTimerAfter _ _ -> doCheck (call genProcess ops p)
                   _ -> doCheck (call genInput ops c im >> call genProcess ops p)

        doCheck body
            = do tell ["if (", id, "++ == ", fired, ") {\n"]
                 body
                 tell ["goto ", label, ";\n"]
                 tell ["}\n"]


-- | In GenerateC this uses prefixComma (because "Process * me" is always the first argument), but here we use infixComma.
cppgenActuals :: GenOps -> [A.Actual] -> CGen ()
cppgenActuals ops as = infixComma (map (call genActual ops) as)

-- | In GenerateC this has special code for passing array sizes around, which we don't need.
cppgenActual :: GenOps -> A.Actual -> CGen ()
cppgenActual ops actual
    = case actual of
        A.ActualExpression t e -> call genExpression ops e
        A.ActualVariable am t v -> cppabbrevVariable ops am t v

-- | The only change from GenerateC is that passing "me" is not necessary in C++CSP
cppgenProcCall :: GenOps -> A.Name -> [A.Actual] -> CGen ()
cppgenProcCall ops n as 
    = do genName n
         tell ["("]
         call genActuals ops as
         tell [");"]


-- | Removed the channel part from GenerateC (not necessary in C++CSP, I think), and also changed the arrays.
--An array is actually stored as a std::vector, but an array-view object is automatically created with the array
--The vector has the suffix _actual, whereas the array-view is what is actually used in place of the array
--I think it may be possible to use boost::array instead of std::vector (which would be more efficient),
--but I will worry about that later
cppgenDeclaration :: GenOps -> A.Type -> A.Name -> Bool -> CGen ()
cppgenDeclaration ops arrType@(A.Array ds t) n False
    =  do call genType ops t
          tell [" "]
          case t of
            A.Chan A.DirUnknown _ _ ->
              do genName n
                 tell ["_storage"]
                 call genFlatArraySize ops ds
                 tell [";"]
                 call genType ops t
                 tell ["* "]
            _ -> return ()
          call genArrayStoreName ops n
          call genFlatArraySize ops ds
          tell [";"]
          call declareArraySizes ops arrType n
cppgenDeclaration ops arrType@(A.Array ds t) n True
    =  do call genType ops t
          tell [" "]
          call genArrayStoreName ops n
          call genFlatArraySize ops ds
          tell [";"]
          call genType ops arrType
          tell [" "]
          genName n;
          tell [";"]
cppgenDeclaration ops t n _
    =  do call genType ops t
          tell [" "]
          genName n
          tell [";"]

cppdeclareArraySizes :: GenOps -> A.Type -> A.Name -> CGen ()
cppdeclareArraySizes ops arrType@(A.Array ds _) n = do
          tell ["const "]
          call genType ops arrType
          tell [" "]
          genName n
          tell ["="]
          call genArraySizesLiteral ops n arrType
          tell [";"]

cppgenArraySizesLiteral :: GenOps -> A.Name -> A.Type -> CGen ()
cppgenArraySizesLiteral ops n t@(A.Array ds _) = 
  do call genType ops t
     tell ["("]
     genName n
     tell ["_actual,tockDims("]
     seqComma dims
     tell ["))"]
  where
    dims :: [CGen ()]
    dims = [case d of
              A.Dimension n -> tell [show n]
              _ -> dieP (findMeta n) "unknown dimension in array type"
            | d <- ds]

-- | Changed because we initialise channels and arrays differently in C++
cppdeclareInit :: GenOps -> Meta -> A.Type -> A.Variable -> Maybe A.Expression -> Maybe (CGen ())
cppdeclareInit ops m t@(A.Array ds t') var _
    = Just $ do init <- return (\sub -> call declareInit ops m t' (sub var) Nothing)
                call genOverArray ops m var init
                case t' of
                  A.Chan A.DirUnknown _ _ ->
                    do tell ["tockInitChanArray("]
                       call genVariableUnchecked ops var
                       tell ["_storage,"]
                       call genVariableUnchecked ops var
                       tell ["_actual,"]
                       sequence_ $ intersperse (tell ["*"]) [case dim of A.Dimension d -> tell [show d] | dim <- ds]
                       tell [");"]
                  _ -> return ()
cppdeclareInit ops m rt@(A.Record _) var _
    = Just $ do fs <- recordFields m rt
                sequence_ [initField t (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
  where
    initField :: A.Type -> A.Variable -> CGen ()
    -- An array as a record field; we must initialise the sizes.
    initField t@(A.Array ds _) v
        =  do call genVariableUnchecked ops v
              tell ["=tockArrayView("]
              call genVariableUnchecked ops v
              tell ["_actual,tockDims("]
              infixComma [tell [show n] | (A.Dimension n) <- ds]
              tell ["));"]
              doMaybe $ call declareInit ops m t v Nothing
    initField t v = doMaybe $ call declareInit ops m t v Nothing
cppdeclareInit ops m _ v (Just e)
    = Just $ call genAssign ops m [v] $ A.ExpressionList m [e]
cppdeclareInit _ _ _ _ _ = Nothing

-- | Changed because we don't need any de-initialisation in C++, regardless of whether C does.
cppdeclareFree :: GenOps -> Meta -> A.Type -> A.Variable -> Maybe (CGen ())
cppdeclareFree _ _ _ _ = Nothing

-- | Changed to work properly with declareFree to free channel arrays.
cppremoveSpec :: GenOps -> A.Specification -> CGen ()
cppremoveSpec ops (A.Specification m n (A.Declaration _ t _))
    = do case call declareFree ops m t var of
               Just p -> p
               Nothing -> return ()
  where
    var = A.Variable m n
cppremoveSpec _ _ = return ()


cppgenArrayStoreName :: GenOps -> A.Name -> CGen()
cppgenArrayStoreName ops n = genName n >> tell ["_actual"]

--Changed from GenerateC because we don't need the extra code for array sizes
cppabbrevExpression :: GenOps -> A.AbbrevMode -> A.Type -> A.Expression -> CGen ()
cppabbrevExpression ops am t@(A.Array _ _) e
    = case e of
        A.ExprVariable _ v -> cppabbrevVariable ops am t v
        A.Literal _ (A.Array ds _) r -> call genExpression ops e
        _ -> bad
  where
    bad = call genMissing ops "array expression abbreviation"
cppabbrevExpression ops am _ e = call genExpression ops e

-- | Takes a list of dimensions and outputs a comma-seperated list of the numerical values
--Unknown dimensions have value 0 (which is treated specially by the tockArrayView class)
genDims:: [A.Dimension] -> CGen()
genDims dims = infixComma $ map genDim dims
  where
    genDim :: A.Dimension -> CGen()
    genDim (A.Dimension n) = tell [show n]
    genDim (A.UnknownDimension) = tell ["0"]

--Changed from GenerateC to add a name function (to allow us to use the same function for doing function parameters as constructor parameters)
--and also changed to use infixComma.
--Therefore these functions are not part of GenOps.  They are called directly by cppgenForwardDeclaration and cppintroduceSpec.
--To use for a constructor list, pass prefixUnderscore as the function, otherwise pass the identity function
cppgenFormals :: GenOps -> (A.Name -> A.Name) -> [A.Formal] -> CGen ()
cppgenFormals ops nameFunc list = infixComma (map (cppgenFormal ops nameFunc) list)

--Changed as genFormals
cppgenFormal :: GenOps -> (A.Name -> A.Name) -> A.Formal -> CGen ()
cppgenFormal ops nameFunc (A.Formal am t n) = call genDecl ops am t (nameFunc n)

cppgenForwardDeclaration :: GenOps -> A.Specification -> CGen()
cppgenForwardDeclaration ops (A.Specification _ n (A.Proc _ sm fs _))
    =  do --Generate the "process" as a C++ function:
          call genSpecMode ops sm
          tell ["void "]
          name 
          tell [" ("]
          cppgenFormals ops (\x -> x) fs
          tell [");"]

          --And generate its CSProcess wrapper:
          tell ["class proc_"]
          name
          tell [" : public csp::CSProcess {private:"]
          genClassVars fs
          tell ["public:inline proc_"]
          name
          tell ["("]
          cppgenFormals ops prefixUnderscore fs
          -- One of the cgtests declares an array of 200*100*sizeof(csp::Time).  
          -- Assuming csp::Time could be up to 16 bytes, we need half a meg stack: 
          tell [") : csp::CSProcess(524288)"]
          genConstructorList fs
          tell ["{} protected: virtual void run(); };"]
  where
    name = genName n

    --A simple function for generating declarations of class variables
    genClassVar :: A.Formal -> CGen()
    genClassVar (A.Formal am t n) 
        = do call genDecl ops am t n
             tell[";"]

    --Generates the given list of class variables
    genClassVars :: [A.Formal] -> CGen ()
    genClassVars fs = mapM_ genClassVar fs

    --A helper function for generating the initialiser list in a process wrapper constructor
    genConsItem :: A.Formal -> CGen()
    genConsItem (A.Formal am t n)
        = do tell[","]
             genName n
             tell["(_"]
             genName n
             tell[")"]

    --A function for generating the initialiser list in a process wrapper constructor
    genConstructorList :: [A.Formal] -> CGen ()
    genConstructorList fs = mapM_ genConsItem fs

cppgenForwardDeclaration _ _ = return ()

cppintroduceSpec :: GenOps -> A.Specification -> CGen ()
--I generate process wrappers for all functions by default:
cppintroduceSpec ops (A.Specification _ n (A.Proc _ sm fs p))
    =  do --Generate the "process" as a C++ function:
          call genSpecMode ops sm
          tell ["void "]
          name 
          tell [" ("]
          cppgenFormals ops (\x -> x) fs
          tell [") {\n"]
          call genProcess ops p
          tell ["}\n"]                                                                          

          --And generate its CSProcess wrapper:
          tell ["void proc_"]
          name
          tell ["::run() { try {"]
          name
          tell [" ( "]
          genParamList fs
          tell [" ); } catch (StopException e) {std::cerr << \"Stopped because: \" << e.reason << std::endl; } }"]
  where
    name = genName n

    --A helper function for calling the wrapped functions:
    genParam :: A.Formal -> CGen()
    genParam (A.Formal _ _ n) = genName n

    --A helper function for calling the wrapped functions:
    genParamList :: [A.Formal] -> CGen()
    genParamList fs = infixComma $ map genParam fs

-- Changed because we use cppabbrevVariable instead of abbrevVariable:
cppintroduceSpec ops (A.Specification _ n (A.Is _ am t v))
    =  do let rhs = cppabbrevVariable ops am t v
          call genDecl ops am t n
          tell ["="]
          rhs
          tell [";"]
--Clause only changed to use C++ rather than C arrays:
cppintroduceSpec ops (A.Specification _ n (A.IsExpr _ am t e))
    =  do let rhs = cppabbrevExpression ops am t e
          case (am, t, e) of
            (A.ValAbbrev, A.Array _ ts, A.Literal _ (A.Array dims _)  _) ->
              -- For "VAL []T a IS [vs]:", we have to use [] rather than * in the
              -- declaration, since you can't say "int *foo = {vs};" in C.
              do tmp <- makeNonce "array_literal"
                 tell ["const "]
                 call genType ops ts
                 tell [" ",tmp, " [] = "]
                 rhs
                 tell [" ; "]
                 tell ["const tockArrayView< const "]
                 call genType ops ts
                 tell [" , ",show (length dims)," /**/>/**/ "]
                 genName n
                 tell ["(("]
                 call genType ops ts 
                 tell [" *)",tmp,",tockDims("]
                 genDims dims
                 tell ["));\n"]
            (A.ValAbbrev, A.Record _, A.Literal _ _ _) ->
              -- Record literals are even trickier, because there's no way of
              -- directly writing a struct literal in C that you can use -> on.
              do tmp <- makeNonce "record_literal"
                 tell ["const "]
                 call genType ops t
                 tell [" ", tmp, " = "]
                 rhs
                 tell [";\n"]
                 call genDecl ops am t n
                 tell [" = &", tmp, ";\n"]
            _ ->
              do call genDecl ops am t n
                 tell [" = "]
                 rhs
                 tell [";\n"]

--This clause was simplified, because we don't need separate array sizes in C++:
cppintroduceSpec ops (A.Specification _ n (A.RecordType _ b fs))
    =  do tell ["typedef struct{"]
          sequence_ [call genDeclaration ops t n True
                     | (n, t) <- fs]
          tell ["}"]
          when b $ tell [" occam_struct_packed "]
          genName n
          tell [";"]
--Clause changed to handle array retyping
cppintroduceSpec ops (A.Specification _ n (A.Retypes m am t v))
    =  do origT <- typeOfVariable v
          let rhs = cppabbrevVariable ops A.Abbrev origT v
          call genDecl ops am t n
          tell ["="]
          case t of 
            (A.Array dims _) ->
              --Arrays need to be handled differently because we need to feed the sizes in, not just perform a straight cast
              do call genDeclType ops am t
                 tell ["(tockDims("]
                 genDims dims
                 tell ["),"]
                 rhs
                 tell [");"]
            _ ->      
              -- For scalar types that are VAL abbreviations (e.g. VAL INT64),
              -- we need to dereference the pointer that cppabbrevVariable gives us.
              do let deref = case (am, t) of
                               (_, A.Chan A.DirUnknown _ _) -> False
                               (_, A.Record {}) -> False
                               (A.ValAbbrev, _) -> True
                               _ -> False
                 when deref $ tell ["*"]
                 tell ["("]
                 call genDeclType ops am t
                 when deref $ tell ["*"]
                 tell [")"]
                 case origT of 
                     --We must be retyping from an array, but not to an array (so to a primitive type or something):
                   (A.Array _ _) -> tell ["("] >> rhs >> tell [".data())"]
                   _ -> rhs
                 tell [";"]
          call genRetypeSizes ops m t n origT v
--For all other cases, use the C implementation:
cppintroduceSpec ops n = cintroduceSpec ops n

cppgenSizeSuffix :: GenOps -> String -> CGen ()
cppgenSizeSuffix _ dim = tell [".extent(", dim, ")"]
--}}}


--{{{  types
-- | If a type maps to a simple C type, return Just that; else return Nothing.
--Changed from GenerateC to change the A.Timer type to use C++CSP time.
--Also changed the bool type, because vector<bool> in C++ is odd, so we hide it from the compiler.
cppgetScalarType :: GenOps -> A.Type -> Maybe String
cppgetScalarType _ A.Bool = Just "bool"
cppgetScalarType _ A.Byte = Just "uint8_t"
cppgetScalarType _ A.UInt16 = Just "uint16_t"
cppgetScalarType _ A.UInt32 = Just "uint32_t"
cppgetScalarType _ A.UInt64 = Just "uint64_t"
cppgetScalarType _ A.Int8 = Just "int8_t"
cppgetScalarType _ A.Int = Just "int"
cppgetScalarType _ A.Int16 = Just "int16_t"
cppgetScalarType _ A.Int32 = Just "int32_t"
cppgetScalarType _ A.Int64 = Just "int64_t"
cppgetScalarType _ A.Real32 = Just "float"
cppgetScalarType _ A.Real64 = Just "double"
cppgetScalarType _ A.Timer = Just "csp::Time"
cppgetScalarType _ A.Time = Just "csp::Time"
cppgetScalarType _ _ = Nothing

-- | Generates an array type, giving the Blitz++ array the correct dimensions
cppgenArrayType :: GenOps -> Bool -> A.Type -> Int -> CGen ()
cppgenArrayType ops const (A.Array dims t) rank
    =  cppgenArrayType ops const t (rank + (max 1 (length dims)))
cppgenArrayType ops const t rank
    =  do tell ["tockArrayView<"]
          when (const) (tell ["const "])
          call genType ops t
          case t of
            A.Chan A.DirUnknown _ _ -> tell ["*"]
            _ -> return ()
          tell [",",show rank, ">/**/"]
    
-- | Changed from GenerateC to change the arrays and the channels
--Also changed to add counted arrays and user protocols
cppgenType :: GenOps -> A.Type -> CGen ()
cppgenType ops arr@(A.Array _ _)
    =  cppgenArrayType ops False arr 0    
cppgenType _ (A.Record n) = genName n
cppgenType ops (A.Chan dir attr t)
    = do let chanType = case dir of
                          A.DirInput -> "csp::Chanin"
                          A.DirOutput -> "csp::Chanout"
                          A.DirUnknown ->
                            case (A.caWritingShared attr,A.caReadingShared attr) of
                              (False,False) -> "csp::One2OneChannel"
                              (False,True)  -> "csp::One2AnyChannel"
                              (True,False)  -> "csp::Any2OneChannel"
                              (True,True)   -> "csp::Any2AnyChannel"
         tell [chanType,"<"]
         cppTypeInsideChannel ops t
         tell [">/**/"]
  where
    cppTypeInsideChannel :: GenOps -> A.Type -> CGen ()
    cppTypeInsideChannel ops A.Any = tell ["tockSendableArrayOfBytes"]
    cppTypeInsideChannel ops (A.Counted _ _) = tell ["tockSendableArrayOfBytes"]
    cppTypeInsideChannel ops (A.UserProtocol _) = tell ["tockSendableArrayOfBytes"]
    cppTypeInsideChannel ops (A.Array ds t)
      = do tell ["tockSendableArray<"]
           call genType ops t
           tell [","]
           tell $ intersperse "*" [case d of A.Dimension n -> show n | d <- ds]
           tell [">/**/"]
    cppTypeInsideChannel ops t = call genType ops t
cppgenType ops (A.Mobile t@(A.Array {})) = call genType ops t
cppgenType ops (A.Mobile t@(A.List {})) = call genType ops t
cppgenType ops (A.Mobile t) = call genType ops t >> tell ["*"]
cppgenType ops (A.List t) = tell ["tockList<"] >> call genType ops t >> tell [">/**/"]
cppgenType ops t
    = case call getScalarType ops t of
        Just s -> tell [s]
        Nothing -> call genMissingC ops $ formatCode "genType %" t


-- | Helper function for prefixing an underscore to a name.
prefixUnderscore :: A.Name -> A.Name
prefixUnderscore n = n { A.nameName = "_" ++ A.nameName n }


-- | Generate the right-hand side of an abbreviation of a variable.
--Changed from GenerateC because we no longer need the A.Name -> CGen() function returned that dealt with array sizes
--I also pass the type of the array through to cppgenSlice
cppabbrevVariable :: GenOps -> A.AbbrevMode -> A.Type -> A.Variable -> CGen ()
cppabbrevVariable ops am (A.Array _ _) v@(A.SubscriptedVariable _ (A.Subscript _ _) _)
    = call genVariable ops v
cppabbrevVariable ops am ty@(A.Array ds _) v@(A.SubscriptedVariable _ (A.SubscriptFromFor _ start count) _)
    = fst (cppgenSlice ops v start count ds)
cppabbrevVariable ops am ty@(A.Array ds _) v@(A.SubscriptedVariable m (A.SubscriptFrom _ start) v')
    = fst (cppgenSlice ops v start (A.Dyadic m A.Minus (A.SizeExpr m (A.ExprVariable m v')) start) ds)
cppabbrevVariable ops am ty@(A.Array ds _) v@(A.SubscriptedVariable m (A.SubscriptFor _ count) _)
    = fst (cppgenSlice ops v (makeConstant m 0) count ds)
cppabbrevVariable ops am (A.Array _ _) v
    = call genVariable ops v
cppabbrevVariable ops am (A.Chan {}) v
    = call genVariable ops v
cppabbrevVariable ops am (A.Record _) v
    = call genVariable ops v
cppabbrevVariable ops am t v
    = call genVariableAM ops v am


-- | Use C++ array slices:
--TODO put index checking back:
cppgenSlice :: GenOps -> A.Variable -> A.Expression -> A.Expression -> [A.Dimension] -> (CGen (), A.Name -> CGen ())
cppgenSlice ops (A.SubscriptedVariable _ _ v) start count ds
       -- We need to disable the index check here because we might be taking
       -- element 0 of a 0-length array -- which is valid.
    = (do call genVariableUnchecked ops v
          tell [".sliceFromFor("]
          genStart
          tell [",occam_check_slice("]
          genStart
          tell [","]
          call genExpression ops count
          tell [","]
          call genVariableUnchecked ops v
          call genSizeSuffix ops "0"
          tell [","]
          genMeta (findMeta count)
          tell ["))"]
      , const (return ())
      )
  where
    genStart = call genExpression ops start
         
-- | Changed from GenerateC to use multiple subscripting (e.g. [1][2][3]) rather than the combined indexing of the C method (e.g. [1*x*y+2*y+3])
cppgenArraySubscript :: GenOps -> Bool -> A.Variable -> [A.Expression] -> CGen ()
cppgenArraySubscript ops checkValid v es
    =  do t <- typeOfVariable v
          let numDims = case t of A.Array ds _ -> length ds
          sequence_ $ genPlainSub v es [0..(numDims - 1)]
          --To index an actual element of an array we must use the .access() function
          --Only needed when we have applied enough subscripts to get out an element:
          when (numDims == (length es)) (tell [".access()"])          
  where
    -- | Generate the individual offsets that need adding together to find the
    -- right place in the array.
    -- FIXME This is obviously not the best way to factor this, but I figure a
    -- smart C compiler should be able to work it out...
    
    --Subtly changed this function so that empty dimensions have blitz::Range::all() in the C++ version:
    --TODO doc
    
    genPlainSub :: A.Variable -> [A.Expression] -> [Int] -> [CGen ()]
    genPlainSub _ _ [] = []
    genPlainSub v [] (sub:subs) = (return ()) : (genPlainSub v [] subs)
    genPlainSub v (e:es) (sub:subs)
        = (tell ["["] >> genSub >> tell ["]"]) : genPlainSub v es subs
      where
        genSub
            = if checkValid
                then do tell ["occam_check_index("]
                        call genExpression ops e
                        tell [","]
                        call genVariable ops v
                        call genSizeSuffix ops (show sub)
                        tell [","]
                        genMeta (findMeta e)
                        tell [")"]
                else call genExpression ops e
--}}}

-- | Changed to remove array size:
cppgenUnfoldedExpression :: GenOps -> A.Expression -> CGen ()
cppgenUnfoldedExpression ops (A.Literal _ t lr)
    =  call genLiteralRepr ops lr
cppgenUnfoldedExpression ops (A.ExprVariable m var) = call genUnfoldedVariable ops m var
cppgenUnfoldedExpression ops e = call genExpression ops e

-- | Changed to remove array size:
cppgenUnfoldedVariable :: GenOps -> Meta -> A.Variable -> CGen ()
cppgenUnfoldedVariable ops m var
    =  do t <- typeOfVariable var
          case t of
            A.Array ds _ ->
              do genLeftB
                 unfoldArray ds var
                 genRightB
            A.Record _ ->
              do genLeftB
                 fs <- recordFields m t
                 seqComma [call genUnfoldedVariable ops m (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
                 genRightB
            -- We can defeat the usage check here because we know it's safe; *we're*
            -- generating the subscripts.
            -- FIXME Is that actually true for something like [a[x]]?
            _ -> call genVariableUnchecked ops var
  where
    unfoldArray :: [A.Dimension] -> A.Variable -> CGen ()
    unfoldArray [] v = call genUnfoldedVariable ops m v
    unfoldArray (A.Dimension n:ds) v
      = seqComma $ [unfoldArray ds (A.SubscriptedVariable m (A.Subscript m $ makeConstant m i) v)
                    | i <- [0..(n - 1)]]
    unfoldArray _ _ = dieP m "trying to unfold array with unknown dimension"


--{{{  if
-- | Changed to throw a nonce-exception class instead of the goto, because C++ doesn't allow gotos to cross class initialisations (such as arrays)

cppgenIf :: GenOps -> Meta -> A.Structured -> CGen ()
cppgenIf ops m s
    =  do ifExc <- makeNonce "if_exc"
          tell ["class ",ifExc, "{};try{"]
          genIfBody ifExc s
          call genStop ops m "no choice matched in IF process"
          tell ["}catch(",ifExc,"){}"]
  where
    genIfBody :: String -> A.Structured -> CGen ()
    genIfBody ifExc s = call genStructured ops s doC
      where
        doC (A.OnlyC m (A.Choice m' e p))
            = do tell ["if("]
                 call genExpression ops e
                 tell ["){"]
                 call genProcess ops p
                 tell ["throw ",ifExc, "();}"]
--}}}


-- | Changed to make array VAL abbreviations have constant data:
cppgenDeclType :: GenOps -> A.AbbrevMode -> A.Type -> CGen ()
cppgenDeclType ops am t
    =  do case t of
            A.Array _ _ -> cppgenArrayType ops (am == A.ValAbbrev) t 0
            _ ->
              do when (am == A.ValAbbrev) $ tell ["const "]
                 call genType ops t
                 case t of
                   A.Chan A.DirInput _ _ -> return ()
                   A.Chan A.DirOutput _ _ -> return ()
                   A.Record _ -> tell ["*const"]
                   _ -> when (am == A.Abbrev) $ tell ["*const"]

-- | Changed because C++CSP has channel-ends as concepts (whereas CCSP does not)
cppgenDirectedVariable :: GenOps -> CGen () -> A.Direction -> CGen ()
cppgenDirectedVariable ops v A.DirInput = tell ["(("] >> v >> tell [")->reader())"]
cppgenDirectedVariable ops v A.DirOutput = tell ["(("] >> v >> tell [")->writer())"]
cppgenDirectedVariable ops v dir = call genMissing ops $ "Cannot direct variable to direction: " ++ show dir

-- | Generate the size part of a RETYPES\/RESHAPES abbrevation of a variable.
cppgenRetypeSizes :: GenOps -> Meta -> A.Type -> A.Name -> A.Type -> A.Variable -> CGen ()
cppgenRetypeSizes _ _ (A.Chan {}) _ (A.Chan {}) _ = return ()
cppgenRetypeSizes ops m destT destN srcT srcV
    =     let checkSize 
                   = do tell ["if(occam_check_retype("]
                        call genBytesIn ops m srcT (Right srcV)
                        tell [","]
                        call genBytesIn ops m destT (Left True)
                        tell [","]
                        genMeta m
                        tell [")!=1){"] 
                        call genStop ops m "size mismatch in RETYPES"
                        tell ["}"] in
          case destT of
            -- An array -- figure out the genMissing dimension, if there is one.
            A.Array destDS _ ->
                case (indexOfFreeDimensions destDS) of
                   -- No free dimensions; check the complete array matches in size.
                   [] -> checkSize
                   -- Free dimensions; tockArrayView will check at run-time instead
                   _ -> return ()
            -- Not array; just check the size is 1.
            _ -> checkSize
              

cppgenAllocMobile :: GenOps -> Meta -> A.Type -> Maybe A.Expression -> CGen ()
cppgenAllocMobile ops m (A.Mobile t) me
  = do tell ["new "]
       call genType ops t 
       case me of
         Just e -> tell ["("] >> call genExpression ops e >> tell [")"]
         Nothing -> return ()

cppgenClearMobile :: GenOps -> Meta -> A.Variable -> CGen ()
cppgenClearMobile ops _ v
  = do tell ["if("]
       genVar
       tell ["!=NULL){delete "]
       genVar
       tell [";"]
       genVar
       tell ["=NULL;}"]
  where
    genVar = call genVariable ops v
