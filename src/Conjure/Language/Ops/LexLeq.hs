{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, DeriveFunctor, DeriveTraversable, DeriveFoldable #-}

module Conjure.Language.Ops.LexLeq where

import Conjure.Prelude
import Conjure.Language.Ops.Common


data OpLexLeq x = OpLexLeq x x
    deriving (Eq, Ord, Show, Data, Functor, Traversable, Foldable, Typeable, Generic)

instance Serialize x => Serialize (OpLexLeq x)
instance Hashable  x => Hashable  (OpLexLeq x)
instance ToJSON    x => ToJSON    (OpLexLeq x) where toJSON = genericToJSON jsonOptions
instance FromJSON  x => FromJSON  (OpLexLeq x) where parseJSON = genericParseJSON jsonOptions

instance BinaryOperator (OpLexLeq x) where
    opLexeme _ = L_LexLeq

instance TypeOf x => TypeOf (OpLexLeq x) where
    typeOf (OpLexLeq a b) = do
        TypeMatrix{} <- typeOf a
        TypeMatrix{} <- typeOf b
        return TypeBool

instance EvaluateOp OpLexLeq where
    evaluateOp (OpLexLeq (ConstantAbstract (AbsLitMatrix _ xs)) (ConstantAbstract (AbsLitMatrix _ ys))) =
        return $ ConstantBool $ xs <= ys
    evaluateOp op = na $ "evaluateOp{OpLexLeq}:" <++> pretty (show op)

instance Pretty x => Pretty (OpLexLeq x) where
    prettyPrec prec op@(OpLexLeq a b) = prettyPrecBinOp prec [op] a b