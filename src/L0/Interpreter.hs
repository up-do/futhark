{-# LANGUAGE GeneralizedNewtypeDeriving, ScopedTypeVariables #-}
module L0.Interpreter
  ( runFun
  , runFunNoTrace
  , Trace
  , InterpreterError(..) )
where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Error

import Data.Array
import Data.Bits
import Data.List
import Data.Loc
import qualified Data.Map as M

import L0.AbSyn
-- import L0.Parser

data InterpreterError = MissingEntryPoint Name
                      | InvalidFunctionArguments Name (Maybe [Type]) [Type]
                      | IndexOutOfBounds SrcLoc Int Int
                      -- ^ First @Int@ is array size, second is attempted index.
                      | NegativeIota SrcLoc Int
                      | NegativeReplicate SrcLoc Int
                      | ReadError SrcLoc Type String
                      | InvalidArrayShape SrcLoc [Int] [Int]
                      -- ^ First @Int@ is old shape, second is attempted new shape.
                      | ZipError SrcLoc [Int]
                      | TypeError SrcLoc String

instance Show InterpreterError where
  show (MissingEntryPoint fname) =
    "Program entry point '" ++ nameToString fname ++ "' not defined."
  show (InvalidFunctionArguments fname Nothing got) =
    "Function '" ++ nameToString fname ++ "' did not expect argument(s) of type " ++
    intercalate ", " (map ppType got) ++ "."
  show (InvalidFunctionArguments fname (Just expected) got) =
    "Function '" ++ nameToString fname ++ "' expected argument(s) of type " ++
    intercalate ", " (map ppType expected) ++
    " but got argument(s) of type " ++
    intercalate ", " (map ppType got) ++ "."
  show (IndexOutOfBounds pos arrsz i) =
    "Array index " ++ show i ++ " out of bounds of array size " ++ show arrsz ++ " at " ++ locStr pos ++ "."
  show (NegativeIota pos n) =
    "Argument " ++ show n ++ " to iota at " ++ locStr pos ++ " is negative."
  show (NegativeReplicate pos n) =
    "Argument " ++ show n ++ " to replicate at " ++ locStr pos ++ " is negative."
  show (TypeError pos s) =
    "Type error at " ++ locStr pos ++ " in " ++ s ++ " during interpretation.  This implies a bug in the type checker."
  show (ReadError pos t s) =
    "Read error while trying to read " ++ ppType t ++ " at " ++ locStr pos ++ ".  Input line was: " ++ s
  show (InvalidArrayShape pos shape newshape) =
    "Invalid array reshaping at " ++ locStr pos ++ ", from " ++ show shape ++ " to " ++ show newshape
  show (ZipError pos lengths) =
    "Array arguments to zip must have same length, but arguments at " ++
    locStr pos ++ " have lenghts " ++ intercalate ", " (map show lengths) ++ "."

instance Error InterpreterError where
  strMsg = TypeError noLoc

data L0Env = L0Env { envVtable  :: M.Map Name Value
                   , envFtable  :: M.Map Name ([Value] -> L0M Value)
                   }

type Trace = [(SrcLoc, String)]

newtype L0M a = L0M (ReaderT L0Env
                     (ErrorT InterpreterError
                      (Writer Trace)) a)
  deriving (MonadReader L0Env, MonadWriter Trace, Monad, Applicative, Functor)

runL0M :: L0M a -> L0Env -> (Either InterpreterError a, Trace)
runL0M (L0M m) env = runWriter $ runErrorT $ runReaderT m env

bad :: InterpreterError -> L0M a
bad = L0M . throwError

bindVar :: L0Env -> (Ident Type, Value) -> L0Env
bindVar env (Ident name _ _,val) =
  env { envVtable = M.insert name val $ envVtable env }

bindVars :: L0Env -> [(Ident Type, Value)] -> L0Env
bindVars = foldl bindVar

binding :: [(Ident Type, Value)] -> L0M a -> L0M a
binding bnds = local (`bindVars` bnds)

lookupVar :: Name -> L0M Value
lookupVar vname = do
  val <- asks $ M.lookup vname . envVtable
  case val of Just val' -> return val'
              Nothing   -> bad $ TypeError noLoc $ "lookupVar " ++ nameToString vname

lookupFun :: Name -> L0M ([Value] -> L0M Value)
lookupFun fname = do
  fun <- asks $ M.lookup fname . envFtable
  case fun of Just fun' -> return fun'
              Nothing   -> bad $ TypeError noLoc $ "lookupFun " ++ nameToString fname

arrToList :: SrcLoc -> Value -> L0M [Value]
arrToList _ (ArrayVal l _) = return $ elems l
arrToList loc _ = bad $ TypeError loc "arrToList"

tupToList :: SrcLoc -> Value -> L0M [Value]
tupToList _ (TupVal l) = return l
tupToList loc _ = bad $ TypeError loc "tupToList"

--------------------------------------------------
------- Interpreting an arbitrary function -------
--------------------------------------------------

runFunNoTrace :: Name -> [Value] -> Prog Type -> Either InterpreterError Value
runFunNoTrace = ((.) . (.) . (.)) fst runFun -- I admit this is just for fun.

runFun :: Name -> [Value] -> Prog Type -> (Either InterpreterError Value, Trace)
runFun fname mainargs prog = do
  let ftable = foldl expand builtins prog
      l0env = L0Env { envVtable = M.empty
                    , envFtable = ftable
                    }
      runmain = case (funDecByName fname prog, M.lookup fname ftable) of
                  (Nothing, Nothing) -> bad $ MissingEntryPoint fname
                  (Just (_,rettype,fparams,_,_), _)
                    | map typeOf mainargs == map identType fparams ->
                      evalExp (Apply fname (map (`Literal` noLoc) mainargs) rettype noLoc)
                    | otherwise ->
                      bad $ InvalidFunctionArguments fname
                            (Just (map identType fparams))
                            (map typeOf mainargs)
                  (_ , Just fun) -> -- It's a builtin function, it'll
                                    -- do its own error checking.
                    fun mainargs
  runL0M runmain l0env
  where
    -- We assume that the program already passed the type checker, so
    -- we don't check for duplicate definitions.
    expand ftable (name,_,params,body,_) =
      let fun args = binding (zip params args) $ evalExp body
      in M.insert name fun ftable


--------------------------------------------
--------------------------------------------
------------- BUILTIN FUNCTIONS ------------
--------------------------------------------
--------------------------------------------

builtins :: M.Map Name ([Value] -> L0M Value)
builtins = M.mapKeys nameFromString $
           M.fromList [("toReal", builtin "toReal")
                      ,("trunc", builtin "trunc")
                      ,("sqrt", builtin "sqrt")
                      ,("log", builtin "log")
                      ,("exp", builtin "exp")
                      ,("op not", builtin "op not")
                      ,("op ~", builtin "op ~")]

builtin :: String -> [Value] -> L0M Value
builtin "toReal" [IntVal x] = return $ RealVal (fromIntegral x)
builtin "trunc" [RealVal x] = return $ IntVal (truncate x)
builtin "sqrt" [RealVal x] = return $ RealVal (sqrt x)
builtin "log" [RealVal x] = return $ RealVal (log x)
builtin "exp" [RealVal x] = return $ RealVal (exp x)
builtin "op not" [LogVal b] = return $ LogVal (not b)
builtin "op ~" [RealVal b] = return $ RealVal (-b)
builtin fname args = bad $ InvalidFunctionArguments (nameFromString fname) Nothing $ map typeOf args

--------------------------------------------
--------------------------------------------
--------------------------------------------
--------------------------------------------


evalExp :: Exp Type -> L0M Value
evalExp (Literal val _) = return val
evalExp (TupLit es _) =
  TupVal <$> mapM evalExp es
evalExp (ArrayLit es rt _) =
  arrayVal <$> mapM evalExp es <*> pure rt
evalExp (BinOp Plus e1 e2 (Elem Int) pos) = evalIntBinOp (+) e1 e2 pos
evalExp (BinOp Plus e1 e2 (Elem Real) pos) = evalRealBinOp (+) e1 e2 pos
evalExp (BinOp Minus e1 e2 (Elem Int) pos) = evalIntBinOp (-) e1 e2 pos
evalExp (BinOp Minus e1 e2 (Elem Real) pos) = evalRealBinOp (-) e1 e2 pos
evalExp (BinOp Pow e1 e2 (Elem Int) pos) = evalIntBinOp (^) e1 e2 pos
evalExp (BinOp Pow e1 e2 (Elem Real) pos) = evalRealBinOp (**) e1 e2 pos
evalExp (BinOp Times e1 e2 (Elem Int) pos) = evalIntBinOp (*) e1 e2 pos
evalExp (BinOp Times e1 e2 (Elem Real) pos) = evalRealBinOp (*) e1 e2 pos
evalExp (BinOp Divide e1 e2 (Elem Int) pos) = evalIntBinOp div e1 e2 pos
evalExp (BinOp Mod e1 e2 (Elem Int) pos) = evalIntBinOp mod e1 e2 pos
evalExp (BinOp Divide e1 e2 (Elem Real) pos) = evalRealBinOp (/) e1 e2 pos
evalExp (BinOp ShiftR e1 e2 _ pos) = evalIntBinOp shiftR e1 e2 pos
evalExp (BinOp ShiftL e1 e2 _ pos) = evalIntBinOp shiftL e1 e2 pos
evalExp (BinOp Band e1 e2 _ pos) = evalIntBinOp (.&.) e1 e2 pos
evalExp (BinOp Xor e1 e2 _ pos) = evalIntBinOp xor e1 e2 pos
evalExp (BinOp Bor e1 e2 _ pos) = evalIntBinOp (.|.) e1 e2 pos
evalExp (BinOp LogAnd e1 e2 _ pos) = evalBoolBinOp (&&) e1 e2 pos
evalExp (BinOp LogOr e1 e2 _ pos) = evalBoolBinOp (||) e1 e2 pos
evalExp (BinOp Equal e1 e2 _ _) = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  return $ LogVal (v1==v2)
evalExp (BinOp Less e1 e2 _ _) = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  return $ LogVal (v1<v2)
evalExp (BinOp Leq e1 e2 _ _) = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  return $ LogVal (v1<=v2)
evalExp (BinOp _ _ _ _ pos) = bad $ TypeError pos "evalExp Binop"
evalExp (And e1 e2 pos) = do
  v1 <- evalExp e1
  case v1 of LogVal True  -> evalExp e2
             LogVal False -> return v1
             _            -> bad $ TypeError pos "evalExp And"
evalExp (Or e1 e2 pos) = do
  v1 <- evalExp e1
  case v1 of LogVal True  -> return v1
             LogVal False -> evalExp e2
             _            -> bad $ TypeError pos "evalExp Or"
evalExp (Not e pos) = do
  v <- evalExp e
  case v of LogVal b -> return $ LogVal (not b)
            _        -> bad $ TypeError pos "evalExp Not"
evalExp (Negate e _ pos) = do
  v <- evalExp e
  case v of IntVal x  -> return $ IntVal (-x)
            RealVal x -> return $ RealVal (-x)
            _         -> bad $ TypeError pos "evalExp Negate"
evalExp (If e1 e2 e3 _ pos) = do
  v <- evalExp e1
  case v of LogVal True  -> evalExp e2
            LogVal False -> evalExp e3
            _            -> bad $ TypeError pos "evalExp If"
evalExp (Var (Ident name _ _)) =
  lookupVar name
evalExp (Apply fname [arg] _ loc)
  | "trace" <- nameToString fname = do
  arg' <- evalExp arg
  tell [(loc, ppValue arg')]
  return arg'
evalExp (Apply fname args _ loc)
  | "assertZip" <- nameToString fname = do
  args' <- mapM evalExp args
  szs   <- mapM getArrSize args'
  case szs of
    n:ns | not $ all (==n) ns ->
      bad $ TypeError loc $
            "assertZip failed! args: " ++ intercalate ", " (map ppValue args')
    _ -> return $ LogVal True
  where
    getArrSize :: Value -> L0M Int
    getArrSize aa@(ArrayVal {}) = return $ arraySize aa
    getArrSize _ = bad $ TypeError loc "one of assertZip args not an array val!"
evalExp (Apply fname args _ _) = do
  fun <- lookupFun fname
  args' <- mapM evalExp args
  fun args'
evalExp (LetPat pat e body pos) = do
  v <- evalExp e
  case evalPattern pat v of
    Nothing   -> bad $ TypeError pos "evalExp Let pat"
    Just bnds -> local (`bindVars` bnds) $ evalExp body
evalExp (LetWith name src idxs ve body pos) = do
  v <- lookupVar $ identName src
  idxs' <- mapM evalExp idxs
  vev <- evalExp ve
  v' <- change v idxs' vev
  binding [(name, v')] $ evalExp body
  where change _ [] to = return to
        change (ArrayVal arr t) (IntVal i:rest) to
          | i >= 0 && i <= upper = do
            let x = arr ! i
            x' <- change x rest to
            return $ ArrayVal (arr // [(i, x')]) t
          | otherwise = bad $ IndexOutOfBounds pos (upper+1) i
          where upper = snd $ bounds arr
        change _ _ _ = bad $ TypeError pos "evalExp Let Id"
evalExp (Index (Ident name _ _) idxs _ _ pos) = do
  v <- lookupVar name
  idxs' <- mapM evalExp idxs
  foldM idx v idxs'
  where idx (ArrayVal arr _) (IntVal i)
          | i >= 0 && i <= upper = return $ arr ! i
          | otherwise             = bad $ IndexOutOfBounds pos (upper+1) i
          where upper = snd $ bounds arr
        idx _ _ = bad $ TypeError pos "evalExp Index"
evalExp (Iota e pos) = do
  v <- evalExp e
  case v of
    IntVal x
      | x >= 0    -> return $ arrayVal (map IntVal [0..x-1]) $ Elem Int
      | otherwise -> bad $ NegativeIota pos x
    _ -> bad $ TypeError pos "evalExp Iota"
evalExp (Size e _) = do
  v <- evalExp e
  return $ IntVal $ arraySize v
evalExp (Replicate e1 e2 pos) = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  case v1 of
    IntVal x
      | x >= 0    -> return $ ArrayVal (listArray (0,x-1) $ repeat v2) $ typeOf v2
      | otherwise -> bad $ NegativeReplicate pos x
    _   -> bad $ TypeError pos "evalExp Replicate"
evalExp re@(Reshape shapeexp arrexp pos) = do
  shape <- mapM (asInt <=< evalExp) shapeexp
  arr <- evalExp arrexp
  let rt = stripArray 1 $ typeOf re
      reshape (n:rest) vs
        | length vs `mod` n == 0 =
          arrayVal <$> mapM (reshape rest) (chunk (length vs `div` n) vs)
                   <*> pure rt
        | otherwise = bad $ InvalidArrayShape pos (arrayShape arr) shape
      reshape [] [v] = return v
      reshape _ _ = bad $ TypeError pos "evalExp Reshape reshape"
  reshape shape $ flatten arr
  where flatten (ArrayVal arr _) = concatMap flatten $ elems arr
        flatten t = [t]
        chunk _ [] = []
        chunk i l = let (a,b) = splitAt i l
                    in a : chunk i b
        asInt (IntVal x) = return x
        asInt _ = bad $ TypeError pos "evalExp Reshape int"
evalExp (Transpose arrexp pos) = do
  v <- evalExp arrexp
  case v of
    ArrayVal inarr et -> do
      let arr el = arrayVal el et
      els' <- map arr <$> transpose <$> mapM (arrToList pos) (elems inarr)
      return $ arrayVal els' et
    _ -> bad $ TypeError pos "evalExp Transpose"
evalExp (Map fun e _ pos) = do
  vs <- arrToList pos =<< evalExp e
  vs' <- mapM (applyLambda fun . (:[])) vs
  return $ arrayVal vs' $ typeOf fun
evalExp (Reduce fun accexp arrexp _ loc) = do
  startacc <- evalExp accexp
  vs <- arrToList loc =<< evalExp arrexp
  let foldfun acc x = applyLambda fun [acc, x]
  foldM foldfun startacc vs
evalExp (Zip arrexps pos) = do
  arrs <- mapM ((arrToList pos <=< evalExp) . fst) arrexps
  let zipit ls
        | all null ls = return []
        | otherwise = case unzip <$> mapM split ls of
                        Just (hds, tls) -> do
                          ls' <- zipit tls
                          return $ TupVal hds : ls'
                        Nothing -> bad $ ZipError pos (map length arrs)
  arrayVal <$> zipit arrs <*> pure (Elem $ Tuple $ map snd arrexps)
  where split []     = Nothing
        split (x:xs) = Just (x, xs)
evalExp (Unzip e ts pos) = do
  arr <- mapM (tupToList pos) =<< arrToList pos =<< evalExp e
  return $ TupVal (zipWith arrayVal (transpose arr) ts)
-- scan * e {x1,..,xn} = {e*x1, e*x1*x2, ..., e*x1*x2*...*xn}
-- we can change this definition of scan if deemed not suitable
evalExp (Scan fun startexp arrexp _ pos) = do
  startval <- evalExp startexp
  vals <- arrToList pos =<< evalExp arrexp
  (acc, vals') <- foldM scanfun (startval, []) vals
  return $ arrayVal (reverse vals') $ typeOf acc
    where scanfun (acc, l) x = do
            acc' <- applyLambda fun [acc, x]
            return (acc', acc' : l)
evalExp (Filter fun arrexp outtype pos) = do
  vs <- filterM filt =<< arrToList pos =<< evalExp arrexp
  return $ arrayVal vs outtype
  where filt x = do res <- applyLambda fun [x]
                    case res of (LogVal True) -> return True
                                _             -> return False
evalExp (Mapall fun arrexp _ _ _) =
  mapall =<< evalExp arrexp
    where mapall (ArrayVal arr et) = do
            els' <- mapM mapall $ elems arr
            return $ arrayVal els' et
          mapall v = applyLambda fun [v]
evalExp (Redomap redfun mapfun accexp arrexp _ _ pos) = do
  startacc <- evalExp accexp
  vs <- arrToList pos =<< evalExp arrexp
  vs' <- mapM (applyLambda mapfun . (:[])) vs
  let foldfun acc x = applyLambda redfun [acc, x]
  foldM foldfun startacc vs'
evalExp (Split splitexp arrexp intype pos) = do
  split <- evalExp splitexp
  vs <- arrToList pos =<< evalExp arrexp
  case split of
    IntVal i
      | i <= length vs ->
        let (bef,aft) = splitAt i vs
        in return $ TupVal [arrayVal bef intype, arrayVal aft intype]
      | otherwise        -> bad $ IndexOutOfBounds pos (length vs) i
    _ -> bad $ TypeError pos "evalExp Split"
evalExp (Concat arr1exp arr2exp pos) = do
  elems1 <- arrToList pos =<< evalExp arr1exp
  elems2 <- arrToList pos =<< evalExp arr2exp
  return $ arrayVal (elems1 ++ elems2) $ stripArray 1 $ typeOf arr1exp
evalExp (Copy e _) = evalExp e
evalExp (DoLoop mergepat mergeexp loopvar boundexp loopbody letbody pos) = do
  bound <- evalExp boundexp
  mergestart <- evalExp mergeexp
  case bound of
    IntVal n -> do loopresult <- foldM iteration mergestart [0..n-1]
                   evalExp $ LetPat mergepat (Literal loopresult pos) letbody pos
    _ -> bad $ TypeError pos "evalExp DoLoop"
  where iteration mergeval i =
          binding [(loopvar, IntVal i)] $
            evalExp $ LetPat mergepat (Literal mergeval pos) loopbody pos

----------------------------
--- Begin SOAC2 (Cosmin) ---
----------------------------

evalExp (Map2 fun es intype outtype pos) = do
    let e' = case es of [e] -> e
                        _   ->  Zip (map (\x -> (x, typeOf x)) es) pos
    let e_map = Map fun e' intype pos
    let res = case outtype of
                Elem (Tuple ts) -> Unzip e_map ts pos
                _ -> e_map
    evalExp res

evalExp (Scan2 fun startexp arrs tp pos) = do
    let arr' = case arrs of [arr] -> arr
                            _     -> Zip (map (\x -> (x, typeOf x)) arrs) pos
    let e_scan = Scan fun startexp arr' tp pos
    let res = case tp of
                Elem (Tuple ts) -> Unzip e_scan ts pos
                _ -> e_scan
    evalExp res

evalExp (Filter2 fun arrs tp pos) = do
    res <- case arrs of
             [arr] -> return $ Filter fun arr tp pos
             _ ->  do let e_zip = Zip (map (\x -> (x, typeOf x)) arrs) pos
                      let e_filt= Filter fun e_zip tp pos
                      case tp of
                        Elem (Tuple ts) -> return $ Unzip e_filt ts pos
                        _ -> bad $ TypeError pos ("evalExp Filter2: elem type not a tuple!"++
                                                  " array list: "++ intercalate ", " (map (ppExp 0) arrs) )
    evalExp res

evalExp (Reduce2 fun accexp arrs tp pos) = do
    let arr' = case arrs of [arr] -> arr
                            _     ->  Zip (map (\x -> (x, typeOf x)) arrs) pos
    evalExp $ Reduce fun accexp arr' tp pos

evalExp (Redomap2 redfun mapfun accexp arrs intp outtp pos) = do
    let arr' = case arrs of [arr] -> arr
                            _     -> Zip (map (\x -> (x, typeOf x)) arrs) pos
    evalExp $ Redomap redfun mapfun accexp arr' intp outtp pos

evalExp (Mapall2 _ _ _ _ pos) =
    bad $ TypeError pos "evalExp Mapall2: not implemented yet!!!"

----------------------------
--- End   SOAC2 (Cosmin) ---
----------------------------


evalIntBinOp :: (Int -> Int -> Int) -> Exp Type -> Exp Type -> SrcLoc -> L0M Value
evalIntBinOp op e1 e2 loc = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  case (v1, v2) of
    (IntVal x, IntVal y) -> return $ IntVal (op x y)
    _                    -> bad $ TypeError loc "evalIntBinOp"

evalRealBinOp :: (Double -> Double -> Double) -> Exp Type -> Exp Type -> SrcLoc -> L0M Value
evalRealBinOp op e1 e2 loc = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  case (v1, v2) of
    (RealVal x, RealVal y) -> return $ RealVal (op x y)
    _                      -> bad $ TypeError loc $ "evalRealBinOp " ++ ppValue v1 ++ " " ++ ppValue v2

evalBoolBinOp :: (Bool -> Bool -> Bool) -> Exp Type -> Exp Type -> SrcLoc -> L0M Value
evalBoolBinOp op e1 e2 loc = do
  v1 <- evalExp e1
  v2 <- evalExp e2
  case (v1, v2) of
    (LogVal x, LogVal y) -> return $ LogVal (op x y)
    _                    -> bad $ TypeError loc $ "evalBoolBinOp " ++ ppValue v1 ++ " " ++ ppValue v2

evalPattern :: TupIdent Type -> Value -> Maybe [(Ident Type, Value)]
evalPattern (Id ident) v = Just [(ident, v)]
evalPattern (TupId pats _) (TupVal vs)
  | length pats == length vs =
    concat <$> zipWithM evalPattern pats vs
evalPattern _ _ = Nothing

applyLambda :: Lambda Type -> [Value] -> L0M Value
applyLambda (AnonymFun params body _ _) args =
  binding (zip params args) $ evalExp body
applyLambda (CurryFun name curryargs _ _) args = do
  curryargs' <- mapM evalExp curryargs
  fun <- lookupFun name
  fun $ curryargs' ++ args
