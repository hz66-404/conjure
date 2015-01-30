{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, DeriveFunctor, DeriveTraversable, DeriveFoldable #-}

module Conjure.Language.Ops.Neq where

import Conjure.Prelude
import Conjure.Language.Ops.Common


data OpNeq x = OpNeq x x
    deriving (Eq, Ord, Show, Data, Functor, Traversable, Foldable, Typeable, Generic)

instance Serialize x => Serialize (OpNeq x)
instance Hashable  x => Hashable  (OpNeq x)
instance ToJSON    x => ToJSON    (OpNeq x) where toJSON = genericToJSON jsonOptions
instance FromJSON  x => FromJSON  (OpNeq x) where parseJSON = genericParseJSON jsonOptions

instance BinaryOperator (OpNeq x) where
    opLexeme _ = L_Neq

instance (TypeOf x, Pretty x) => TypeOf (OpNeq x) where
    typeOf (OpNeq a b) = sameToSameToBool a b

instance EvaluateOp OpNeq where
    evaluateOp (OpNeq x y) = return $ ConstantBool $ normaliseConstant x /= normaliseConstant y

instance Pretty x => Pretty (OpNeq x) where
    prettyPrec prec op@(OpNeq a b) = prettyPrecBinOp prec [op] a b