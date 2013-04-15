{-# LANGUAGE QuasiQuotes, ViewPatterns, OverloadedStrings  #-}
--{-# OPTIONS_GHC -fno-warn-unused-binds #-}


module Language.E.Up.EvaluateTree2 (
     evalTree
) where

import Language.E

import Language.E.Up.Data
import Language.E.Up.Common(transposeE,matrixToTuple,unwrapMatrix,wrapInMatrix)
import Language.E.Up.Debug
import Language.E.Up.Representations

import Data.Map(Map)
import qualified Data.Map as M
import Data.Set(Set)
import qualified Data.Set as S

type VarMap             = Map String VarData
type IsTuplesOfMatrixes = Set [String]

evalTree ::VarMap -> IsTuplesOfMatrixes -> Tree String  -> (String,E)
evalTree mapping set (Branch name arr) =
    (name, evalTree' mapping set [] [name] (repSelector arr))
    `_g` ("evalTree name", name)

evalTree mapping set tree@(Leaf name) =
    (name,  evalTree' mapping set [] []  tree)

evalTree _ _ _ = _bugg "evalTree no match"


evalTree' :: VarMap -> IsTuplesOfMatrixes -> [(Before,After)] -> [String] -> Tree String  -> E
evalTree' mapping set fs prefix (Leaf part) =
   let leafFunc = leafRep part
         `_p` ("leaf \n" ++ name, [vdata] )
         `_g` ("leaf_prefix +n",prefix ++ [name] )
         `_g` ("leaf_func",length fs )


       res     = runBranchFuncs (reverse fs) vdata leafFunc
   in  vEssence res

     

    where
    name    = intercalate "_" (prefix ++ [part])
    lookUpE = fromMaybe (_bugg "fromMaybe: lookUpE evalTree'")  . flip M.lookup mapping
    vdata   = lookUpE  name

evalTree' mapping set fs prefix (Tuple arr) =
    let items =  map ( evalTree' mapping set fs prefix ) arr
        tuple = [xMake| value.tuple.values := items |]
        res   = handleTuplesOfMatrixes tuple
    in  res

     `_p` ("res",[res] )
     `_p` ("ans",[tuple] )
     `_g` ("prefix_tuple",prefix )


    where
    handleTuplesOfMatrixes :: E -> E
    handleTuplesOfMatrixes f | prefix `S.member` set = reverseTuplesOfMatrixes f
    handleTuplesOfMatrixes f = f


evalTree' mapping set fs prefix (Branch part@"ExplicitVarSize" arr) =
    error . show $  (pretty . groom) prefix  <+> (pretty . groom) mapping  <+>  (pretty . groom) arr

evalTree' mapping set fs prefix (Branch name arr) =
    evalTree' mapping set fs' (prefix ++ [name])  (repSelector arr)

    where
    fs' :: [(Before,After)]
    fs' = getBranch name ++ fs

repSelector :: [Tree String] -> Tree String
repSelector arr = arr !! (length arr -1)

reverseTuplesOfMatrixes ::  E -> E


reverseTuplesOfMatrixes [xMatch| vs  := value.tuple.values 
                               | fvs := value.tuple.values.value.function|] | all isFunc vs =
    let ((dom:_),range) =unzip $ map (unzip . map splitMapping .  unwrapValues) fvs 
        range2   = (map wrapInMatrix range)
        range3   = transposeE range2
        range'   = map matrixToTuple range3
        mapping' = zipWith makeMapping dom range'

    in wrapInFunction mapping'

    where

    makeMapping :: E -> E -> E
    makeMapping f g =  [xMake| mapping := [f, g] |]

    splitMapping [xMatch| [a,b] := mapping |] = (a,b)

    isFunc :: E -> Bool
    isFunc [xMatch| _ := value.function.values |] = True
    isFunc _ = False  

reverseTuplesOfMatrixes [xMatch| vs := value.tuple.values |] =
    tracer "reverseTuplesOfMatrixes result" $
    wrapInMatrix . map matrixToTuple $ transposeE (tracer "reverseTuplesOfMatrixes vs\n" vs)



reverseTuplesOfMatrixes e = bug $ "reverseTuplesOfMatrixes called on " <+> pretty e


_bug :: String -> [E] -> t
_bug  s = upBug  ("EvaluateTree: " ++ s)
_bugi :: (Show a) => String -> (a, [E]) -> t
_bugi s = upBugi ("EvaluateTree: " ++ s )
_bugg :: String -> t
_bugg s = _bug s []

unwrapValues ::  E -> [E]
unwrapValues  (Tagged "values" vs) =  vs
unwrapValues e = _bug "unwrapValues failed" [e]

wrapInFunction :: [E] -> E
wrapInFunction es = [xMake| value.function.values := es |]
