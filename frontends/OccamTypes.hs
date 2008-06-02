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

-- | The occam typechecker.
module OccamTypes (inferTypes, checkTypes) where

import Control.Monad.State
import Data.Generics
import Data.List

import qualified AST as A
import CompState
import Errors
import EvalConstants
import Intrinsics
import Metadata
import Pass
import qualified Properties as Prop
import ShowCode
import Traversal
import Types
import Utils

-- | A successful check.
ok :: PassM ()
ok = return ()

--{{{  type checks

-- | Are two types the same?
sameType :: A.Type -> A.Type -> PassM Bool
sameType (A.Array (A.Dimension e1 : ds1) t1)
         (A.Array (A.Dimension e2 : ds2) t2)
    =  do n1 <- evalIntExpression e1
          n2 <- evalIntExpression e2
          same <- sameType (A.Array ds1 t1) (A.Array ds2 t2)
          return $ (n1 == n2) && same
sameType (A.Array (A.UnknownDimension : ds1) t1)
         (A.Array (A.UnknownDimension : ds2) t2)
    = sameType (A.Array ds1 t1) (A.Array ds2 t2)
sameType a b = return $ a == b

-- | Check that the second dimension can be used in a context where the first
-- is expected.
isValidDimension :: A.Dimension -> A.Dimension -> PassM Bool
isValidDimension A.UnknownDimension A.UnknownDimension = return True
isValidDimension A.UnknownDimension (A.Dimension _) = return True
isValidDimension (A.Dimension e1) (A.Dimension e2)
    =  do n1 <- evalIntExpression e1
          n2 <- evalIntExpression e2
          return $ n1 == n2
isValidDimension _ _ = return False

-- | Check that the second second of dimensions can be used in a context where
-- the first is expected.
areValidDimensions :: [A.Dimension] -> [A.Dimension] -> PassM Bool
areValidDimensions [] [] = return True
areValidDimensions (d1:ds1) (d2:ds2)
    = do valid <- isValidDimension d1 d2
         if valid
           then areValidDimensions ds1 ds2
           else return False
areValidDimensions _ _ = return False

-- | Check that a type we've inferred matches the type we expected.
checkType :: Meta -> A.Type -> A.Type -> PassM ()
checkType m et rt
    = case (et, rt) of
        (A.Infer, _) -> ok
        ((A.Array ds t), (A.Array ds' t')) ->
          do valid <- areValidDimensions ds ds'
             if valid
               then checkType m t t'
               else bad
        _ ->
          do same <- sameType rt et
             when (not same) $ bad
  where
    bad :: PassM ()
    bad = diePC m $ formatCode "Type mismatch: found %, expected %" rt et

-- | Check a type against a predicate.
checkTypeClass :: (A.Type -> Bool) -> String -> Meta -> A.Type -> PassM ()
checkTypeClass f adjective m rawT
    =  do t <- underlyingType m rawT
          if f t
            then ok
            else diePC m $ formatCode ("Expected " ++ adjective ++ " type; found %") t

-- | Check that a type is numeric.
checkNumeric :: Meta -> A.Type -> PassM ()
checkNumeric = checkTypeClass isNumericType "numeric"

-- | Check that a type is integral.
checkInteger :: Meta -> A.Type -> PassM ()
checkInteger = checkTypeClass isIntegerType "integer"

-- | Check that a type is case-selectable.
checkCaseable :: Meta -> A.Type -> PassM ()
checkCaseable = checkTypeClass isCaseableType "case-selectable"

-- | Check that a type is scalar.
checkScalar :: Meta -> A.Type -> PassM ()
checkScalar = checkTypeClass isScalarType "scalar"

-- | Check that a type is usable as a 'DataType'
checkDataType :: Meta -> A.Type -> PassM ()
checkDataType = checkTypeClass isDataType "data"

-- | Check that a type is communicable.
checkCommunicable :: Meta -> A.Type -> PassM ()
checkCommunicable m (A.Counted ct rawAT)
    =  do checkInteger m ct
          at <- resolveUserType m rawAT
          case at of
            A.Array (A.UnknownDimension:ds) t ->
               do checkCommunicable m t
                  mapM_ (checkFullDimension m) ds
            _ -> dieP m "Expected array type with unknown first dimension"
checkCommunicable m A.Any = ok
checkCommunicable m t = checkTypeClass isCommunicableType "communicable" m t

-- | Check that a type is a sequence.
checkSequence :: Meta -> A.Type -> PassM ()
checkSequence = checkTypeClass isSequenceType "array or list"

-- | Check that a type is an array.
checkArray :: Meta -> A.Type -> PassM ()
checkArray m rawT
    =  do t <- resolveUserType m rawT
          case t of
            A.Array _ _ -> ok
            _ -> diePC m $ formatCode "Expected array type; found %" t

-- | Check that a dimension isn't unknown.
checkFullDimension :: Meta -> A.Dimension -> PassM ()
checkFullDimension m A.UnknownDimension
    = dieP m $ "Type contains unknown dimensions"
checkFullDimension _ _ = ok

-- | Check that a type is a list.
checkList :: Meta -> A.Type -> PassM ()
checkList m rawT
    =  do t <- resolveUserType m rawT
          case t of
            A.List _ -> ok
            _ -> diePC m $ formatCode "Expected list type; found %" t

-- | Check the type of an expression.
checkExpressionType :: A.Type -> A.Expression -> PassM ()
checkExpressionType et e = astTypeOf e >>= checkType (findMeta e) et

-- | Check that an expression is of integer type.
checkExpressionInt :: Check A.Expression
checkExpressionInt e = checkExpressionType A.Int e

-- | Check that an expression is of boolean type.
checkExpressionBool :: Check A.Expression
checkExpressionBool e = checkExpressionType A.Bool e

-- | Pick the more specific of a pair of types.
betterType :: A.Type -> A.Type -> A.Type
betterType t1 t2
    = case betterType' t1 t2 of
        Left () -> t1
        Right () -> t2
  where
    betterType' :: A.Type -> A.Type -> Either () ()
    betterType' A.Infer t = Right ()
    betterType' t A.Infer = Left ()
    betterType' t@(A.UserDataType _) _ = Left ()
    betterType' _ t@(A.UserDataType _) = Right ()
    betterType' t1@(A.Array ds1 et1) t2@(A.Array ds2 et2)
      | length ds1 == length ds2 = betterType' et1 et2
      | length ds1 < length ds2  = Left ()
    betterType' t _ = Left ()

--}}}
--{{{  more complex checks

-- | Check that an array literal's length matches its type.
checkArraySize :: Meta -> A.Type -> Int -> PassM ()
checkArraySize m rawT want
    =  do t <- resolveUserType m rawT
          case t of
            A.Array (A.UnknownDimension:_) _ -> ok
            A.Array (A.Dimension e:_) _ ->
               do n <- evalIntExpression e
                  when (n /= want) $
                    dieP m $ "Array literal has wrong number of elements: found " ++ show n ++ ", expected " ++ show want
            _ -> checkArray m t

-- | Check that a record field name is valid.
checkRecordField :: Meta -> A.Type -> A.Name -> PassM ()
checkRecordField m t n
    =  do rfs <- recordFields m t
          let validNames = map fst rfs
          when (not $ n `elem` validNames) $
            diePC m $ formatCode "Invalid field name % in record type %" n t

-- | Check a subscript.
checkSubscript :: Meta -> A.Subscript -> A.Type -> PassM ()
checkSubscript m s rawT
    =  do -- Check the type of the thing being subscripted.
          t <- resolveUserType m rawT
          case s of
            -- A record subscript.
            A.SubscriptField m n ->
              checkRecordField m t n
            -- A sequence subscript.
            A.Subscript _ _ _ -> checkSequence m t
            -- An array slice.
            _ -> checkArray m t

          -- Check the subscript itself.
          case s of
            A.Subscript m _ e -> checkExpressionInt e
            A.SubscriptFromFor m _ e f ->
              checkExpressionInt e >> checkExpressionInt f
            A.SubscriptFrom m _ e -> checkExpressionInt e
            A.SubscriptFor m _ e -> checkExpressionInt e
            _ -> ok

-- | Classes of operators.
data OpClass = NumericOp | IntegerOp | ShiftOp | BooleanOp | ComparisonOp
               | ListOp

-- | Figure out the class of a monadic operator.
classifyMOp :: A.MonadicOp -> OpClass
classifyMOp A.MonadicSubtr = NumericOp
classifyMOp A.MonadicMinus = NumericOp
classifyMOp A.MonadicBitNot = IntegerOp
classifyMOp A.MonadicNot = BooleanOp

-- | Figure out the class of a dyadic operator.
classifyOp :: A.DyadicOp -> OpClass
classifyOp A.Add = NumericOp
classifyOp A.Subtr = NumericOp
classifyOp A.Mul = NumericOp
classifyOp A.Div = NumericOp
classifyOp A.Rem = NumericOp
classifyOp A.Plus = NumericOp
classifyOp A.Minus = NumericOp
classifyOp A.Times = NumericOp
classifyOp A.BitAnd = IntegerOp
classifyOp A.BitOr = IntegerOp
classifyOp A.BitXor = IntegerOp
classifyOp A.LeftShift = ShiftOp
classifyOp A.RightShift = ShiftOp
classifyOp A.And = BooleanOp
classifyOp A.Or = BooleanOp
classifyOp A.Eq = ComparisonOp
classifyOp A.NotEq = ComparisonOp
classifyOp A.Less = ComparisonOp
classifyOp A.More = ComparisonOp
classifyOp A.LessEq = ComparisonOp
classifyOp A.MoreEq = ComparisonOp
classifyOp A.After = ComparisonOp
classifyOp A.Concat = ListOp

-- | Check a monadic operator.
checkMonadicOp :: A.MonadicOp -> A.Expression -> PassM ()
checkMonadicOp op e
    =  do t <- astTypeOf e
          let m = findMeta e
          case classifyMOp op of
            NumericOp -> checkNumeric m t
            IntegerOp -> checkInteger m t
            BooleanOp -> checkType m A.Bool t

-- | Check a dyadic operator.
checkDyadicOp :: A.DyadicOp -> A.Expression -> A.Expression -> PassM ()
checkDyadicOp op l r
    =  do lt <- astTypeOf l
          let lm = findMeta l
          rt <- astTypeOf r
          let rm = findMeta r
          case classifyOp op of
            NumericOp ->
              checkNumeric lm lt >> checkNumeric rm rt >> checkType rm lt rt
            IntegerOp ->
              checkInteger lm lt >> checkInteger rm rt >> checkType rm lt rt
            ShiftOp ->
              checkNumeric lm lt >> checkType rm A.Int rt
            BooleanOp ->
              checkType lm A.Bool lt >> checkType rm A.Bool rt
            ComparisonOp ->
              checkScalar lm lt >> checkScalar rm rt >> checkType rm lt rt
            ListOp ->
              checkList lm lt >> checkList rm rt >> checkType rm lt rt

-- | Check an abbreviation.
-- Is the second abbrev mode a valid abbreviation of the first?
checkAbbrev :: Meta -> A.AbbrevMode -> A.AbbrevMode -> PassM ()
checkAbbrev m orig new
    = case (orig, new) of
        (_, A.Original) -> bad
        (A.ValAbbrev, A.ValAbbrev) -> ok
        (A.ValAbbrev, _) -> bad
        _ -> ok
  where
    bad :: PassM ()
    bad = dieP m $ "You can't abbreviate " ++ showAM orig ++ " as " ++ showAM new

    showAM :: A.AbbrevMode -> String
    showAM A.Original = "an original declaration"
    showAM A.Abbrev = "a reference abbreviation"
    showAM A.ValAbbrev = "a value abbreviation"

-- | Check a list of actuals is the right length for a list of formals.
checkActualCount :: Meta -> A.Name -> [A.Formal] -> [a] -> PassM ()
checkActualCount m n fs as
    =  do when (length fs /= length as) $
            diePC m $ formatCode ("% called with wrong number of arguments; found " ++ (show $ length as) ++ ", expected " ++ (show $ length fs)) n

-- | Check a set of actuals against the formals they're meant to match.
checkActuals :: Meta -> A.Name -> [A.Formal] -> [A.Actual] -> PassM ()
checkActuals m n fs as
    =  do checkActualCount m n fs as
          sequence_ [checkActual f a
                     | (f, a) <- zip fs as]

-- | Check an actual against its matching formal.
checkActual :: A.Formal -> A.Actual -> PassM ()
checkActual (A.Formal newAM et _) a
    =  do rt <- case a of
                  A.ActualVariable v -> astTypeOf v
                  A.ActualExpression e -> astTypeOf e
          checkType (findMeta a) et rt
          origAM <- case a of
                      A.ActualVariable v -> abbrevModeOfVariable v
                      A.ActualExpression _ -> return A.ValAbbrev
          checkAbbrev (findMeta a) origAM newAM

-- | Check a function exists.
checkFunction :: Meta -> A.Name -> PassM ([A.Type], [A.Formal])
checkFunction m n
    =  do st <- specTypeOfName n
          case st of
            A.Function _ _ rs fs _ -> return (rs, fs)
            _ -> diePC m $ formatCode "% is not a function" n

-- | Check a 'Proc' exists.
checkProc :: Meta -> A.Name -> PassM [A.Formal]
checkProc m n
    =  do st <- specTypeOfName n
          case st of
            A.Proc _ _ fs _ -> return fs
            _ -> diePC m $ formatCode "% is not a procedure" n

-- | Check a function call.
checkFunctionCall :: Meta -> A.Name -> [A.Expression] -> PassM [A.Type]
checkFunctionCall m n es
    =  do (rs, fs) <- checkFunction m n
          checkActuals m n fs (map A.ActualExpression es)
          return rs

-- | Check an intrinsic function call.
checkIntrinsicFunctionCall :: Meta -> String -> [A.Expression] -> PassM ()
checkIntrinsicFunctionCall m n es
    = case lookup n intrinsicFunctions of
        Just (rs, args) ->
           do when (length rs /= 1) $
                dieP m $ "Function " ++ n ++ " used in an expression returns more than one value"
              let fs = [A.Formal A.ValAbbrev t (A.Name m s)
                        | (t, s) <- args]
              checkActuals m (A.Name m n)
                           fs (map A.ActualExpression es)
        Nothing -> dieP m $ n ++ " is not an intrinsic function"

-- | Check a mobile allocation.
checkAllocMobile :: Meta -> A.Type -> Maybe A.Expression -> PassM ()
checkAllocMobile m rawT me
    =  do t <- resolveUserType m rawT
          case t of
            A.Mobile innerT ->
               do case innerT of
                    A.Array ds _ -> mapM_ (checkFullDimension m) ds
                    _ -> ok
                  case me of
                    Just e ->
                       do et <- astTypeOf e
                          checkType (findMeta e) innerT et
                    Nothing -> ok
            _ -> diePC m $ formatCode "Expected mobile type in allocation; found %" t

-- | Check that a variable is writable.
checkWritable :: Check A.Variable
checkWritable v
    =  do am <- abbrevModeOfVariable v
          case am of
            A.ValAbbrev -> dieP (findMeta v) $ "Expected a writable variable"
            _ -> ok

-- | Check that is a variable is a channel that can be used in the given
-- direction.
-- If the direction passed is 'DirUnknown', no direction or sharedness checks
-- will be performed.
-- Return the type carried by the channel.
checkChannel :: A.Direction -> A.Variable -> PassM A.Type
checkChannel wantDir c
    =  do -- Check it's a channel.
          t <- astTypeOf c >>= resolveUserType m
          case t of
            A.Chan dir (A.ChanAttributes ws rs) innerT ->
               do -- Check the direction is appropriate 
                  case (wantDir, dir) of
                    (A.DirUnknown, _) -> ok
                    (_, A.DirUnknown) -> ok
                    (a, b) -> when (a /= b) $
                                dieP m $ "Channel directions do not match"

                  -- Check it's not shared in the direction we're using.
                  case (ws, rs, wantDir) of
                    (False, _, A.DirOutput) -> ok
                    (_, False, A.DirInput) -> ok
                    (_, _, A.DirUnknown) -> ok
                    _ -> dieP m $ "Shared channel must be claimed before use"

                  return innerT
            _ -> diePC m $ formatCode "Expected channel; found %" t
  where
    m = findMeta c

-- | Check that a variable is a timer.
-- Return the type of the timer's value.
checkTimer :: A.Variable -> PassM A.Type
checkTimer tim
    =  do t <- astTypeOf tim >>= resolveUserType m
          case t of
            A.Timer A.OccamTimer -> return A.Int
            A.Timer A.RainTimer -> return A.Time
            _ -> diePC m $ formatCode "Expected timer; found %" t
  where
    m = findMeta tim

-- | Return the list of types carried by a protocol.
-- For a variant protocol, the second argument should be 'Just' the tag.
-- For a non-variant protocol, the second argument should be 'Nothing'.
protocolTypes :: Meta -> A.Type -> Maybe A.Name -> PassM [A.Type]
protocolTypes m t tag
    = case t of
        -- A user-defined protocol.
        A.UserProtocol n ->
           do st <- specTypeOfName n
              case (st, tag) of
                -- A simple protocol.
                (A.Protocol _ ts, Nothing) -> return ts
                (A.Protocol _ _, Just tagName) ->
                  diePC m $ formatCode "Tag % specified for non-variant protocol %" tagName n
                -- A variant protocol.
                (A.ProtocolCase _ ntss, Just tagName) ->
                  case lookup tagName ntss of
                    Just ts -> return ts
                    Nothing -> diePC m $ formatCode "Tag % not found in protocol %; expected one of %" tagName n (map fst ntss)
                (A.ProtocolCase _ ntss, Nothing) ->
                  diePC m $ formatCode "No tag specified for variant protocol %; expected one of %" n (map fst ntss)
                -- Not actually a protocol.
                _ -> diePC m $ formatCode "% is not a protocol" n
        -- Not a protocol (e.g. CHAN INT); just return it.
        _ -> return [t]

-- | Check a protocol communication.
-- Figure out the types of the items that should be involved in a protocol
-- communication, and run the supplied check against each item with its type.
checkProtocol :: Meta -> A.Type -> Maybe A.Name
                 -> [t] -> (A.Type -> t -> PassM ()) -> PassM ()
checkProtocol m t tag items doItem
    =  do its <- protocolTypes m t tag
          when (length its /= length items) $
            dieP m $ "Wrong number of items in protocol communication; found "
                     ++ (show $ length items) ++ ", expected "
                     ++ (show $ length its)
          sequence_ [doItem it item
                     | (it, item) <- zip its items]

-- | Check an 'ExpressionList' matches a set of types.
checkExpressionList :: [A.Type] -> A.ExpressionList -> PassM ()
checkExpressionList ets el
    = case el of
        A.FunctionCallList m n es ->
           do rs <- checkFunctionCall m n es
              when (length ets /= length rs) $
                diePC m $ formatCode ("Function % has wrong number of return values; found " ++ (show $ length rs) ++ ", expected " ++ (show $ length ets)) n
              sequence_ [checkType m et rt
                         | (et, rt) <- zip ets rs]
        A.ExpressionList m es ->
           do when (length ets /= length es) $
                dieP m $ "Wrong number of items in expression list; found "
                         ++ (show $ length es) ++ ", expected "
                         ++ (show $ length ets)
              sequence_ [do rt <- astTypeOf e
                            checkType (findMeta e) et rt
                         | (e, et) <- zip es ets]

-- | Check a set of names are distinct.
checkNamesDistinct :: Meta -> [A.Name] -> PassM ()
checkNamesDistinct m ns
    = when (dupes /= []) $
        diePC m $ formatCode "List contains duplicate names: %" dupes
  where
    dupes :: [A.Name]
    dupes = nub (ns \\ nub ns)

-- | Check a 'Structured', applying the given check to each item found inside
-- it. This assumes that processes and specifications will be checked
-- elsewhere.
checkStructured :: Data t => Check t -> Check (A.Structured t)
checkStructured doInner s = transformOnly checkInner s >> return ()
  where
    checkInner m v
      =  do doInner v
            return $ A.Only m v

--}}}
--{{{  retyping checks

-- | Check that one type can be retyped to another.
checkRetypes :: Meta -> A.Type -> A.Type -> PassM ()
checkRetypes m fromT toT
    =  do (fromBI, fromN) <- evalBytesInType fromT
          (toBI, toN) <- evalBytesInType toT
          case (fromBI, toBI, fromN, toN) of
            (_, BIManyFree, _, _) ->
              dieP m "Multiple free dimensions in retype destination type"
            (BIJust _, BIJust _, Just a, Just b) ->
              when (a /= b) $
                dieP m "Sizes do not match in retype"
            (BIJust _, BIOneFree _ _, Just a, Just b) ->
              when (not ((b <= a) && (a `mod` b == 0))) $
                dieP m "Sizes do not match in retype"
            (BIOneFree _ _, BIJust _, Just a, Just b) ->
              when (not ((a <= b) && (b `mod` a == 0))) $
                dieP m "Sizes do not match in retype"
            -- Otherwise we must do a runtime check.
            _ -> return ()

-- | Evaluate 'BytesIn' for a type.
-- If the size isn't known at compile type, return 'Nothing'.
evalBytesInType :: A.Type -> PassM (BytesInResult, Maybe Int)
evalBytesInType t
    =  do bi <- bytesInType t
          n <- case bi of
                 BIJust e -> foldEval e
                 BIOneFree e _ -> foldEval e
                 _ -> return Nothing
          return (bi, n)
  where
    foldEval :: A.Expression -> PassM (Maybe Int)
    foldEval e
        =  do (e', isConst, _) <- constantFold e
              if isConst
                then evalIntExpression e' >>* Just
                else return Nothing

--}}}
--{{{  type context management

-- | Run an operation in a given type context.
inTypeContext :: Maybe A.Type -> PassM a -> PassM a
inTypeContext ctx body
    =  do pushTypeContext (case ctx of
                             Just A.Infer -> Nothing
                             _ -> ctx)
          v <- body
          popTypeContext
          return v

-- | Run an operation in the type context 'Nothing'.
noTypeContext :: PassM a -> PassM a
noTypeContext = inTypeContext Nothing

-- | Run an operation in the type context that results from subscripting
-- the current type context.
-- If the current type context is 'Nothing', the resulting one will be too.
inSubscriptedContext :: Meta -> PassM a -> PassM a
inSubscriptedContext m body
    =  do ctx <- getTypeContext
          subCtx <- case ctx of
                      Just t@(A.Array _ _) ->
                        trivialSubscriptType m t >>* Just
                      Just t -> diePC m $ formatCode "Attempting to subscript non-array type %" t
                      Nothing -> return Nothing
          inTypeContext subCtx body

--}}}

--{{{  inferTypes

-- | Infer types.
inferTypes :: Pass
inferTypes = occamOnlyPass "Infer types"
  []
  [Prop.inferredTypesRecorded]
  $ recurse
  where
    ops :: Ops
    ops = baseOp
          `extOp` doExpression
          `extOp` doDimension
          `extOp` doSubscript
          `extOp` doArrayConstr
          `extOp` doReplicator
          `extOp` doAlternative
          `extOp` doInputMode
          `extOp` doSpecification
          `extOp` doProcess
          `extOp` doVariable

    recurse :: Recurse
    recurse = makeRecurse ops
    descend :: Descend
    descend = makeDescend ops

    doExpression :: Transform A.Expression
    doExpression outer
        = case outer of
            -- Literals are what we're really looking for here.
            A.Literal m t lr ->
               do t' <- recurse t
                  ctx <- getTypeContext
                  let wantT = case (ctx, t') of
                                -- No type specified on the literal,
                                -- but there's a context, so use that.
                                (Just ct, A.Infer) -> ct
                                -- Use the explicit type of the literal, or the
                                -- default.
                                _ -> t'
                  (realT, realLR) <- doLiteral (wantT, lr)
                  return $ A.Literal m realT realLR

            -- Expressions that aren't literals, but that modify the type
            -- context.
            A.Dyadic m op le re ->
              let -- Both types are the same.
                  bothSame
                    =  do lt <- recurse le >>= astTypeOf
                          rt <- recurse re >>= astTypeOf
                          inTypeContext (Just $ betterType lt rt) $
                            descend outer
                  -- The RHS type is always A.Int.
                  intOnRight
                    =  do le' <- recurse le
                          re' <- inTypeContext (Just A.Int) $ recurse re
                          return $ A.Dyadic m op le' re'
              in case classifyOp op of
                   ComparisonOp -> noTypeContext $ bothSame
                   ShiftOp -> intOnRight
                   _ -> bothSame
            A.SizeExpr _ _ -> noTypeContext $ descend outer
            A.Conversion _ _ _ _ -> noTypeContext $ descend outer
            A.FunctionCall m n es ->
               do es' <- doFunctionCall m n es
                  return $ A.FunctionCall m n es'
            A.IntrinsicFunctionCall _ _ _ -> noTypeContext $ descend outer
            A.SubscriptedExpr m s e ->
               do ctx <- getTypeContext
                  ctx' <- case ctx of
                            Just t -> unsubscriptType s t >>* Just
                            Nothing -> return Nothing
                  e' <- inTypeContext ctx' $ recurse e
                  t <- astTypeOf e'
                  s' <- recurse s >>= fixSubscript t
                  return $ A.SubscriptedExpr m s' e'
            A.BytesInExpr _ _ -> noTypeContext $ descend outer
            -- FIXME: ExprConstr
            -- FIXME: AllocMobile

            -- Other expressions don't modify the type context.
            _ -> descend outer

    doFunctionCall :: Meta -> A.Name -> Transform [A.Expression]
    doFunctionCall m n es
        =  do (_, fs) <- checkFunction m n
              doActuals m n fs es

    doActuals :: Data a => Meta -> A.Name -> [A.Formal] -> Transform [a]
    doActuals m n fs as
        =  do checkActualCount m n fs as
              sequence [inTypeContext (Just t) $ recurse a
                        | (A.Formal _ t _, a) <- zip fs as]

    doDimension :: Transform A.Dimension
    doDimension dim = inTypeContext (Just A.Int) $ descend dim

    doSubscript :: Transform A.Subscript
    doSubscript s = inTypeContext (Just A.Int) $ descend s

    -- FIXME: RepConstr shouldn't contain the type -- and this won't fill it in.
    -- (That is, it should just be a kind of literal.)
    doArrayConstr :: Transform A.ArrayConstr
    doArrayConstr ac
        = case ac of
            A.RangeConstr m t _ _ -> inSubscriptedContext m $ descend ac
            A.RepConstr m t _ _ -> inSubscriptedContext m $ descend ac

    doExpressionList :: [A.Type] -> Transform A.ExpressionList
    doExpressionList ts el
        = case el of
            A.FunctionCallList m n es ->
               do es' <- doFunctionCall m n es
                  return $ A.FunctionCallList m n es'
            A.ExpressionList m es ->
               do es' <- sequence [inTypeContext (Just t) $ recurse e
                                   | (t, e) <- zip ts es]
                  return $ A.ExpressionList m es'

    doReplicator :: Transform A.Replicator
    doReplicator rep
        = case rep of
            A.For _ _ _ _ -> inTypeContext (Just A.Int) $ descend rep
            A.ForEach _ _ _ -> noTypeContext $ descend rep

    doAlternative :: Transform A.Alternative
    doAlternative a = inTypeContext (Just A.Bool) $ descend a

    doInputMode :: Transform A.InputMode
    doInputMode im = inTypeContext (Just A.Int) $ descend im

    -- FIXME: This should be shared with foldConstants.
    doSpecification :: Transform A.Specification
    doSpecification s@(A.Specification m n st)
        =  do st' <- doSpecType st
              -- Update the definition of each name after we handle it.
              modifyName n (\nd -> nd { A.ndSpecType = st' })
              return $ A.Specification m n st'

    doSpecType :: Transform A.SpecType
    doSpecType st
        = case st of
            A.Place _ _ -> inTypeContext (Just A.Int) $ descend st
            A.Is m am t v ->
               do am' <- recurse am
                  t' <- recurse t
                  v' <- inTypeContext (Just t') $ recurse v
                  t'' <- case t' of
                           A.Infer -> astTypeOf v'
                           _ -> return t'
                  return $ A.Is m am' t'' v'
            A.IsExpr m am t e ->
               do am' <- recurse am
                  t' <- recurse t
                  e' <- inTypeContext (Just t') $ recurse e
                  t'' <- case t' of
                           A.Infer -> astTypeOf e'
                           _ -> return t'
                  return $ A.IsExpr m am' t'' e'
            A.IsChannelArray m t vs ->
               -- No expressions in this -- but we may need to infer the type
               -- of the variable if it's something like "cs IS [c]:".
               do t' <- recurse t
                  vs' <- mapM recurse vs
                  let dim = makeDimension m $ length vs'
                  t'' <- case (t', vs') of
                           (A.Infer, (v:_)) ->
                             do elemT <- astTypeOf v
                                return $ addDimensions [dim] elemT
                           (A.Infer, []) ->
                             dieP m "Cannot infer type of empty channel array"
                           _ -> return $ applyDimension dim t'
                  return $ A.IsChannelArray m t'' vs'
            A.Function m sm ts fs (Left sel) ->
               do sm' <- recurse sm
                  ts' <- recurse ts
                  fs' <- recurse fs
                  sel' <- doFuncDef ts sel
                  return $ A.Function m sm' ts' fs' (Left sel')
            A.RetypesExpr _ _ _ _ -> noTypeContext $ descend st
            _ -> descend st
      where
        -- | This is a bit ugly: walk down a Structured to find the single
        -- ExpressionList that must be in there.
        -- (This can go away once we represent all functions in the new Process
        -- form.)
        doFuncDef :: [A.Type] -> Transform (A.Structured A.ExpressionList)
        doFuncDef ts (A.Spec m spec s)
            =  do spec' <- recurse spec
                  s' <- doFuncDef ts s
                  return $ A.Spec m spec' s'
        doFuncDef ts (A.ProcThen m p s)
            =  do p' <- recurse p
                  s' <- doFuncDef ts s
                  return $ A.ProcThen m p' s'
        doFuncDef ts (A.Only m el)
            =  do el' <- doExpressionList ts el
                  return $ A.Only m el'

    doProcess :: Transform A.Process
    doProcess p
        = case p of
            A.Assign m vs el ->
               do vs' <- recurse vs
                  ts <- mapM astTypeOf vs'
                  el' <- doExpressionList ts el
                  return $ A.Assign m vs' el'
            A.Output m v ois ->
               do v' <- recurse v
                  -- At this point we must resolve the "c ! x" ambiguity:
                  -- we definitely know what c is, and we must know what x is
                  -- before trying to infer its type.
                  tagged <- isTagged v'
                  if tagged
                    -- Tagged protocol -- convert (wrong) variable to tag.
                    then case ois of
                           ((A.OutExpression _ (A.ExprVariable _ (A.Variable _ wrong))):ois) ->
                             do tag <- nameToUnscoped wrong
                                ois' <- doOutputItems m v' (Just tag) ois
                                return $ A.OutputCase m v' tag ois'
                           _ -> diePC m $ formatCode "This channel carries a variant protocol; expected a list starting with a tag, but found %" ois
                    -- Regular protocol -- proceed as before.
                    else do ois' <- doOutputItems m v' Nothing ois
                            return $ A.Output m v' ois'
            A.OutputCase m v tag ois ->
               do v' <- recurse v
                  ois' <- doOutputItems m v' (Just tag) ois
                  return $ A.OutputCase m v' tag ois'
            A.If _ _ -> inTypeContext (Just A.Bool) $ descend p
            A.Case m e so ->
               do e' <- recurse e
                  t <- astTypeOf e'
                  so' <- inTypeContext (Just t) $ recurse so
                  return $ A.Case m e' so'
            A.While _ _ _ -> inTypeContext (Just A.Bool) $ descend p
            A.Processor _ _ _ -> inTypeContext (Just A.Int) $ descend p
            A.ProcCall m n as ->
               do fs <- checkProc m n
                  as' <- doActuals m n fs as
                  return $ A.ProcCall m n as'
            A.IntrinsicProcCall _ _ _ -> noTypeContext $ descend p
            _ -> descend p
      where
        -- | Does a channel carry a tagged protocol?
        isTagged :: A.Variable -> PassM Bool
        isTagged c
            =  do protoT <- checkChannel A.DirOutput c
                  case protoT of
                    A.UserProtocol n ->
                       do st <- specTypeOfName n
                          case st of
                            A.ProtocolCase _ _ -> return True
                            _ -> return False
                    _ -> return False

        doOutputItems :: Meta -> A.Variable -> Maybe A.Name
                         -> Transform [A.OutputItem]
        doOutputItems m v tag ois
            =  do chanT <- checkChannel A.DirOutput v
                  ts <- protocolTypes m chanT tag
                  sequence [doOutputItem t oi | (t, oi) <- zip ts ois]

        doOutputItem :: A.Type -> Transform A.OutputItem
        doOutputItem (A.Counted ct at) (A.OutCounted m ce ae)
            =  do ce' <- inTypeContext (Just ct) $ recurse ce
                  ae' <- inTypeContext (Just at) $ recurse ae
                  return $ A.OutCounted m ce' ae'
        doOutputItem A.Any o = noTypeContext $ recurse o
        doOutputItem t o = inTypeContext (Just t) $ recurse o

    doVariable :: Transform A.Variable
    doVariable (A.SubscriptedVariable m s v)
        =  do v' <- recurse v
              t <- astTypeOf v'
              s' <- recurse s >>= fixSubscript t
              return $ A.SubscriptedVariable m s' v'
    doVariable v = descend v

    -- | Resolve the @v[s]@ ambiguity: this takes the type that @v@ is, and
    -- returns the correct 'Subscript'.
    fixSubscript :: A.Type -> A.Subscript -> PassM A.Subscript
    fixSubscript t s@(A.Subscript m _ (A.ExprVariable _ (A.Variable _ wrong)))
        =  do underT <- resolveUserType m t
              case underT of
                A.Record _ ->
                  do n <- nameToUnscoped wrong
                     return $ A.SubscriptField m n
                _ -> return s
    fixSubscript _ s = return s

    -- | Given a name that should really have been a tag, make it one.
    nameToUnscoped :: A.Name -> PassM A.Name
    nameToUnscoped n@(A.Name m _)
        =  do nd <- lookupName n
              findUnscopedName (A.Name m (A.ndOrigName nd))

    -- | Process a 'LiteralRepr', taking the type it's meant to represent or
    -- 'Infer', and returning the type it really is.
    doLiteral :: Transform (A.Type, A.LiteralRepr)
    doLiteral (wantT, lr)
        = case lr of
            A.ArrayLiteral m aes ->
               do (t, A.ArrayElemArray aes') <-
                    doArrayElem wantT (A.ArrayElemArray aes)
                  lr' <- buildTable t aes'
                  return (t, lr')
            _ ->
               do lr' <- descend lr
                  (defT, isT) <-
                    case lr' of
                      A.RealLiteral _ _ -> return (A.Real32, isRealType)
                      A.IntLiteral _ _ -> return (A.Int, isIntegerType)
                      A.HexLiteral _ _ -> return (A.Int, isIntegerType)
                      A.ByteLiteral _ _ -> return (A.Byte, isIntegerType)
                      _ -> dieP m $ "Unexpected LiteralRepr: " ++ show lr'
                  underT <- resolveUserType m wantT
                  case (wantT, isT underT) of
                    (A.Infer, _) -> return (defT, lr')
                    (_, True) -> return (wantT, lr')
                    (_, False) -> diePC m $ formatCode "Literal of default type % is not valid for type %" defT wantT
      where
        m = findMeta lr

        doArrayElem :: A.Type -> A.ArrayElem -> PassM (A.Type, A.ArrayElem)
        -- A table: this could be an array or a record.
        doArrayElem wantT (A.ArrayElemArray aes)
            =  do underT <- resolveUserType m wantT
                  case underT of
                    A.Array _ _ ->
                       do subT <- trivialSubscriptType m underT
                          (elemT, aes') <- doElems subT aes
                          let dim = makeDimension m (length aes)
                          return (applyDimension dim wantT,
                                  A.ArrayElemArray aes')
                    A.Record _ ->
                       do nts <- recordFields m underT
                          aes <- sequence [doArrayElem t ae >>* snd
                                           | ((_, t), ae) <- zip nts aes]
                          return (wantT, A.ArrayElemArray aes)
                    -- If we don't know, assume it's an array.
                    A.Infer ->
                       do (elemT, aes') <- doElems A.Infer aes
                          when (elemT == A.Infer) $
                            dieP m "Cannot infer type of (empty?) array"
                          let dims = [makeDimension m (length aes)]
                          return (addDimensions dims elemT,
                                  A.ArrayElemArray aes')
                    _ -> diePC m $ formatCode "Table literal is not valid for type %" wantT
          where
            doElems :: A.Type -> [A.ArrayElem] -> PassM (A.Type, [A.ArrayElem])
            doElems t aes
                =  do ts <- mapM (\ae -> doArrayElem t ae >>* fst) aes
                      let bestT = foldl betterType t ts
                      aes' <- mapM (\ae -> doArrayElem bestT ae >>* snd) aes
                      return (bestT, aes')
        -- An expression: descend into it with the right context.
        doArrayElem wantT (A.ArrayElemExpr e)
            =  do e' <- inTypeContext (Just wantT) $ doExpression e
                  t <- astTypeOf e'
                  checkType (findMeta e') wantT t
                  return (t, A.ArrayElemExpr e')

        -- | Turn a raw table literal into the appropriate combination of
        -- arrays and records.
        buildTable :: A.Type -> [A.ArrayElem] -> PassM A.LiteralRepr
        buildTable t aes
            =  do underT <- resolveUserType m t
                  case underT of
                    A.Array _ _ ->
                       do elemT <- trivialSubscriptType m t
                          aes' <- mapM (buildElem elemT) aes
                          return $ A.ArrayLiteral m aes'
                    A.Record _ ->
                       do nts <- recordFields m underT
                          aes' <- sequence [buildExpr elemT ae
                                            | ((_, elemT), ae) <- zip nts aes]
                          return $ A.RecordLiteral m aes'
          where
            buildExpr :: A.Type -> A.ArrayElem -> PassM A.Expression
            buildExpr t (A.ArrayElemArray aes)
                =  do lr <- buildTable t aes
                      return $ A.Literal m t lr
            buildExpr _ (A.ArrayElemExpr e) = return e

            buildElem :: A.Type -> A.ArrayElem -> PassM A.ArrayElem
            buildElem t ae
                =  do underT <- resolveUserType m t
                      case (underT, ae) of
                        (A.Array _ _, A.ArrayElemArray aes) ->
                           do A.ArrayLiteral _ aes' <- buildTable t aes
                              return $ A.ArrayElemArray aes'
                        (A.Record _, A.ArrayElemArray _) ->
                           do e <- buildExpr t ae
                              return $ A.ArrayElemExpr e
                        (_, A.ArrayElemExpr _) -> return ae

--}}}
--{{{  checkTypes

-- | Check the AST for type consistency.
-- This is actually a series of smaller passes that check particular types
-- inside the AST, but it doesn't really make sense to split it up.
checkTypes :: Pass
checkTypes = occamOnlyPass "Check types"
  [Prop.inferredTypesRecorded, Prop.ambiguitiesResolved]
  [Prop.expressionTypesChecked, Prop.processTypesChecked,
    Prop.functionTypesChecked, Prop.retypesChecked]
  $ checkVariables >.>
    checkExpressions >.>
    checkSpecTypes >.>
    checkProcesses >.>
    checkReplicators

--{{{  checkVariables

checkVariables :: PassType
checkVariables = checkDepthM doVariable
  where
    doVariable :: Check A.Variable
    doVariable (A.SubscriptedVariable m s v)
        =  do t <- astTypeOf v
              checkSubscript m s t
    doVariable (A.DirectedVariable m _ v)
        =  do t <- astTypeOf v >>= resolveUserType m
              case t of
                A.Chan _ _ _ -> ok
                _ -> dieP m $ "Direction applied to non-channel variable"
    doVariable (A.DerefVariable m v)
        =  do t <- astTypeOf v >>= resolveUserType m
              case t of
                A.Mobile _ -> ok
                _ -> dieP m $ "Dereference applied to non-mobile variable"
    doVariable _ = ok

--}}}
--{{{  checkExpressions

checkExpressions :: PassType
checkExpressions = checkDepthM doExpression
  where
    doExpression :: Check A.Expression
    doExpression (A.Monadic _ op e) = checkMonadicOp op e
    doExpression (A.Dyadic _ op le re) = checkDyadicOp op le re
    doExpression (A.MostPos m t) = checkNumeric m t
    doExpression (A.MostNeg m t) = checkNumeric m t
    doExpression (A.SizeType m t) = checkSequence m t
    doExpression (A.SizeExpr m e)
        =  do t <- astTypeOf e
              checkSequence m t
    doExpression (A.SizeVariable m v)
        =  do t <- astTypeOf v
              checkSequence m t
    doExpression (A.Conversion m _ t e)
        =  do et <- astTypeOf e
              checkScalar m t >> checkScalar (findMeta e) et
    doExpression (A.Literal m t lr) = doLiteralRepr t lr
    doExpression (A.FunctionCall m n es)
        =  do rs <- checkFunctionCall m n es
              when (length rs /= 1) $
                diePC m $ formatCode "Function % used in an expression returns more than one value" n
    doExpression (A.IntrinsicFunctionCall m s es)
        = checkIntrinsicFunctionCall m s es
    doExpression (A.SubscriptedExpr m s e)
        =  do t <- astTypeOf e
              checkSubscript m s t
    doExpression (A.OffsetOf m rawT n)
        =  do t <- resolveUserType m rawT
              checkRecordField m t n
    doExpression (A.AllocMobile m t me) = checkAllocMobile m t me
    doExpression _ = ok

    doLiteralRepr :: A.Type -> A.LiteralRepr -> PassM ()
    doLiteralRepr t (A.ArrayLiteral m aes)
        = doArrayElem m t (A.ArrayElemArray aes)
    doLiteralRepr t (A.RecordLiteral m es)
        =  do rfs <- resolveUserType m t >>= recordFields m
              when (length es /= length rfs) $
                dieP m $ "Record literal has wrong number of fields: found " ++ (show $ length es) ++ ", expected " ++ (show $ length rfs)
              sequence_ [checkExpressionType ft fe
                         | ((_, ft), fe) <- zip rfs es]
    doLiteralRepr _ _ = ok

    doArrayElem :: Meta -> A.Type -> A.ArrayElem -> PassM ()
    doArrayElem m t (A.ArrayElemArray aes)
        =  do checkArraySize m t (length aes)
              t' <- subscriptType (A.Subscript m A.NoCheck undefined) t
              sequence_ $ map (doArrayElem m t') aes
    doArrayElem _ t (A.ArrayElemExpr e) = checkExpressionType t e

--}}}
--{{{  checkSpecTypes

checkSpecTypes :: PassType
checkSpecTypes = checkDepthM doSpecType
  where
    doSpecType :: Check A.SpecType
    doSpecType (A.Place _ e) = checkExpressionInt e
    doSpecType (A.Declaration _ _) = ok
    doSpecType (A.Is m am t v)
        =  do tv <- astTypeOf v
              checkType (findMeta v) t tv
              when (am /= A.Abbrev) $ unexpectedAM m
              amv <- abbrevModeOfVariable v
              checkAbbrev m amv am
    doSpecType (A.IsExpr m am t e)
        =  do te <- astTypeOf e
              checkType (findMeta e) t te
              when (am /= A.ValAbbrev) $ unexpectedAM m
              checkAbbrev m A.ValAbbrev am
    doSpecType (A.IsChannelArray m rawT cs)
        =  do t <- resolveUserType m rawT
              case t of
                A.Array [d] et@(A.Chan _ _ _) ->
                   do sequence_ [do rt <- astTypeOf c
                                    checkType (findMeta c) et rt
                                    am <- abbrevModeOfVariable c
                                    checkAbbrev m am A.Abbrev
                                 | c <- cs]
                      case d of
                        A.UnknownDimension -> ok
                        A.Dimension e ->
                           do v <- evalIntExpression e
                              when (v /= length cs) $
                                dieP m $ "Wrong number of elements in channel array abbreviation: found " ++ (show $ length cs) ++ ", expected " ++ show v
                _ -> dieP m "Expected 1D channel array type"
    doSpecType (A.DataType m t)
        = checkDataType m t
    doSpecType (A.RecordType m _ nts)
        =  do sequence_ [checkDataType (findMeta n) t
                         | (n, t) <- nts]
              checkNamesDistinct m (map fst nts)
    doSpecType (A.Protocol m ts)
        =  do when (length ts == 0) $
                dieP m "A protocol cannot be empty"
              mapM_ (checkCommunicable m) ts
    doSpecType (A.ProtocolCase m ntss)
        =  do sequence_ [mapM_ (checkCommunicable (findMeta n)) ts
                         | (n, ts) <- ntss]
              checkNamesDistinct m (map fst ntss)
    doSpecType (A.Proc m _ fs _)
        = sequence_ [when (am == A.Original) $ unexpectedAM m
                     | A.Formal am _ n <- fs]
    doSpecType (A.Function m _ rs fs body)
        =  do when (length rs == 0) $
                dieP m "A function must have at least one return type"
              sequence_ [do when (am /= A.ValAbbrev) $
                              diePC (findMeta n) $ formatCode "Argument % is not a value abbreviation" n
                            checkDataType (findMeta n) t
                         | A.Formal am t n <- fs]
              -- FIXME: Run this test again after free name removal
              doFunctionBody rs body
      where
        doFunctionBody :: [A.Type]
                          -> Either (A.Structured A.ExpressionList) A.Process
                          -> PassM ()
        doFunctionBody rs (Left s) = checkStructured (checkExpressionList rs) s
        -- FIXME: Need to know the name of the function to do this
        doFunctionBody rs (Right p) = dieP m "Cannot check function process body"
    doSpecType (A.Retypes m _ t v)
        =  do fromT <- astTypeOf v
              checkRetypes m fromT t
    doSpecType (A.RetypesExpr m _ t e)
        =  do fromT <- astTypeOf e
              checkRetypes m fromT t

    unexpectedAM :: Check Meta
    unexpectedAM m = dieP m "Unexpected abbreviation mode"

--}}}
--{{{  checkProcesses

checkProcesses :: PassType
checkProcesses = checkDepthM doProcess
  where
    doProcess :: Check A.Process
    doProcess (A.Assign m vs el)
        -- We ignore dimensions here because we do the check at runtime.
        -- (That is, [2]INT := []INT is legal.)
        =  do vts <- sequence [astTypeOf v >>* removeFixedDimensions
                               | v <- vs]
              mapM_ checkWritable vs
              checkExpressionList vts el
    doProcess (A.Input _ v im) = doInput v im
    doProcess (A.Output m v ois) = doOutput m v ois
    doProcess (A.OutputCase m v tag ois) = doOutputCase m v tag ois
    doProcess (A.ClearMobile _ v)
        =  do t <- astTypeOf v
              case t of
                A.Mobile _ -> ok
                _ -> diePC (findMeta v) $ formatCode "Expected mobile type; found %" t
              checkWritable v
    doProcess (A.Skip _) = ok
    doProcess (A.Stop _) = ok
    doProcess (A.Seq _ s) = checkStructured (\p -> ok) s
    doProcess (A.If _ s) = checkStructured doChoice s
    doProcess (A.Case _ e s)
        =  do t <- astTypeOf e
              checkCaseable (findMeta e) t
              checkStructured (doOption t) s
    doProcess (A.While _ e _) = checkExpressionBool e
    doProcess (A.Par _ _ s) = checkStructured (\p -> ok) s
    doProcess (A.Processor _ e _) = checkExpressionInt e
    doProcess (A.Alt _ _ s) = checkStructured doAlternative s
    doProcess (A.ProcCall m n as)
        =  do fs <- checkProc m n
              checkActuals m n fs as
    doProcess (A.IntrinsicProcCall m n as)
        = case lookup n intrinsicProcs of
            Just args ->
              do let fs = [A.Formal am t (A.Name m s)
                           | (am, t, s) <- args]
                 checkActuals m (A.Name m n) fs as
            Nothing -> dieP m $ n ++ " is not an intrinsic procedure"

    doAlternative :: Check A.Alternative
    doAlternative (A.Alternative m e v im p)
        =  do checkExpressionBool e
              case im of
                A.InputTimerRead _ _ ->
                  dieP m $ "Timer read not permitted as alternative"
                _ -> doInput v im
    doAlternative (A.AlternativeSkip _ e _)
        = checkExpressionBool e

    doChoice :: Check A.Choice
    doChoice (A.Choice _ e _) = checkExpressionBool e

    doInput :: A.Variable -> A.InputMode -> PassM ()
    doInput c (A.InputSimple m iis)
        =  do t <- checkChannel A.DirInput c
              checkProtocol m t Nothing iis doInputItem
    doInput c (A.InputCase _ s)
        =  do t <- checkChannel A.DirInput c
              checkStructured (doVariant t) s
      where
        doVariant :: A.Type -> A.Variant -> PassM ()
        doVariant t (A.Variant m tag iis _)
            = checkProtocol m t (Just tag) iis doInputItem
    doInput c (A.InputTimerRead m ii)
        =  do t <- checkTimer c
              doInputItem t ii
    doInput c (A.InputTimerAfter m e)
        =  do t <- checkTimer c
              et <- astTypeOf e
              checkType (findMeta e) t et
    doInput c (A.InputTimerFor m e)
        =  do t <- checkTimer c
              et <- astTypeOf e
              checkType (findMeta e) t et

    doInputItem :: A.Type -> A.InputItem -> PassM ()
    doInputItem (A.Counted wantCT wantAT) (A.InCounted m cv av)
        =  do ct <- astTypeOf cv
              checkType (findMeta cv) wantCT ct
              checkWritable cv
              at <- astTypeOf av
              checkType (findMeta cv) wantAT at
              checkWritable av
    doInputItem t@(A.Counted _ _) (A.InVariable m v)
        = diePC m $ formatCode "Expected counted item of type %; found %" t v
    doInputItem wantT (A.InVariable _ v)
        =  do t <- astTypeOf v
              case wantT of
                A.Any -> checkCommunicable (findMeta v) t
                _ -> checkType (findMeta v) wantT t
              checkWritable v

    doOption :: A.Type -> A.Option -> PassM ()
    doOption et (A.Option _ es _)
        = sequence_ [do rt <- astTypeOf e
                        checkType (findMeta e) et rt
                     | e <- es]
    doOption _ (A.Else _ _) = ok

    doOutput :: Meta -> A.Variable -> [A.OutputItem] -> PassM ()
    doOutput m c ois
        =  do t <- checkChannel A.DirOutput c
              checkProtocol m t Nothing ois doOutputItem

    doOutputCase :: Meta -> A.Variable -> A.Name -> [A.OutputItem] -> PassM ()
    doOutputCase m c tag ois
        =  do t <- checkChannel A.DirOutput c
              checkProtocol m t (Just tag) ois doOutputItem

    doOutputItem :: A.Type -> A.OutputItem -> PassM ()
    doOutputItem (A.Counted wantCT wantAT) (A.OutCounted m ce ae)
        =  do ct <- astTypeOf ce
              checkType (findMeta ce) wantCT ct
              at <- astTypeOf ae
              checkType (findMeta ae) wantAT at
    doOutputItem t@(A.Counted _ _) (A.OutExpression m e)
        = diePC m $ formatCode "Expected counted item of type %; found %" t e
    doOutputItem wantT (A.OutExpression _ e)
        =  do t <- astTypeOf e
              case wantT of
                A.Any -> checkCommunicable (findMeta e) t
                _ -> checkType (findMeta e) wantT t

--}}}
--{{{  checkReplicators

checkReplicators :: PassType
checkReplicators = checkDepthM doReplicator
  where
    doReplicator :: Check A.Replicator
    doReplicator (A.For _ _ start count)
        =  do checkExpressionInt start
              checkExpressionInt count
    doReplicator (A.ForEach _ _ e)
        =  do t <- astTypeOf e
              checkSequence (findMeta e) t

--}}}

--}}}
