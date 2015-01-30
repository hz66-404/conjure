{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, DeriveFunctor, DeriveTraversable, DeriveFoldable #-}

module Conjure.Language.Ops.Mod where

import Conjure.Prelude
import Conjure.Language.Ops.Common


data OpMod x = OpMod x x
    deriving (Eq, Ord, Show, Data, Functor, Traversable, Foldable, Typeable, Generic)

instance Serialize x => Serialize (OpMod x)
instance Hashable  x => Hashable  (OpMod x)
instance ToJSON    x => ToJSON    (OpMod x) where toJSON = genericToJSON jsonOptions
instance FromJSON  x => FromJSON  (OpMod x) where parseJSON = genericParseJSON jsonOptions

instance BinaryOperator (OpMod x) where
    opLexeme _ = L_Mod

instance TypeOf x => TypeOf (OpMod x) where
    typeOf (OpMod a b) = intToIntToInt a b

instance EvaluateOp OpMod where
    evaluateOp (OpMod x y) = ConstantInt <$> (mod <$> intOut x <*> intOut y)

instance Pretty x => Pretty (OpMod x) where
    prettyPrec prec op@(OpMod a b) = prettyPrecBinOp prec [op] a b