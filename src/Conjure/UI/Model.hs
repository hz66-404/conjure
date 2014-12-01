{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RecordWildCards #-}

module Conjure.UI.Model
    ( outputModels
    , pickFirst
    , interactive, interactiveFixedQs, interactiveFixedQsAutoA
    , allFixedQs
    , Strategy(..), Config(..), parseStrategy
    ) where

import Conjure.Prelude
import Conjure.Bug
import Conjure.Language.Definition
import Conjure.Language.Domain
import Conjure.Language.Type
import Conjure.Language.Pretty
import Conjure.Language.CategoryOf
import Conjure.Language.TypeOf
import Conjure.Language.DomainOf
import Conjure.Language.Lenses
import Conjure.Language.TH ( essence )
import Conjure.Language.Ops
import Conjure.Language.ModelStats ( modelInfo )
import Conjure.Process.Enums ( removeEnumsFromModel )
import Conjure.Process.Unnameds ( removeUnnamedsFromModel )
import Conjure.Language.NameResolution ( resolveNames, resolveNamesX )

import Conjure.Representations ( downX1, downToX1, downD, reprOptions, getStructurals )

import Conjure.Rules.Definition
import qualified Conjure.Rules.Horizontal.Set as Horizontal.Set
import qualified Conjure.Rules.Horizontal.Function as Horizontal.Function
import qualified Conjure.Rules.Horizontal.Relation as Horizontal.Relation
import qualified Conjure.Rules.Vertical.Tuple as Vertical.Tuple
import qualified Conjure.Rules.Vertical.Matrix as Vertical.Matrix
import qualified Conjure.Rules.Vertical.Set.Explicit as Vertical.Set.Explicit
import qualified Conjure.Rules.Vertical.Set.ExplicitVarSizeWithFlags as Vertical.Set.ExplicitVarSizeWithFlags
import qualified Conjure.Rules.Vertical.Set.ExplicitVarSizeWithMarker as Vertical.Set.ExplicitVarSizeWithMarker
import qualified Conjure.Rules.Vertical.Set.Occurrence as Vertical.Set.Occurrence
import qualified Conjure.Rules.Vertical.Function.Function1D as Vertical.Function.Function1D
import qualified Conjure.Rules.Vertical.Function.Function1DPartial as Vertical.Function.Function1DPartial
import qualified Conjure.Rules.Vertical.Function.FunctionND as Vertical.Function.FunctionND
import qualified Conjure.Rules.Vertical.Function.FunctionNDPartial as Vertical.Function.FunctionNDPartial
import qualified Conjure.Rules.Vertical.Relation.RelationAsMatrix as Vertical.Relation.RelationAsMatrix


-- uniplate
import Data.Generics.Uniplate.Zipper ( Zipper, zipperBi, fromZipper, hole, replaceHole )

-- pipes
import Pipes ( Producer, yield, (>->) )
import qualified Pipes.Prelude as Pipes ( foldM, take )


outputModels
    :: (MonadIO m, MonadFail m, MonadLog m)
    => Config
    -> Model
    -> m ()
outputModels config model = do
    let dir = outputDirectory config
    liftIO $ createDirectoryIfMissing True dir
    let limitModelsIfNeeded = maybe id (\ n gen -> gen >-> Pipes.take n ) (limitModels config)
    let each i logOrModel =
            case logOrModel of
                Left (l,msg) -> do
                    log l msg
                    return i
                Right eprime -> do
                    let filename = dir </> "model" ++ paddedNum i ++ ".eprime"
                    liftIO $ writeFile filename (renderWide eprime)
                    return (i+1)
    Pipes.foldM each
                (return (1 :: Int))
                (const $ return ())
                (limitModelsIfNeeded $ toCompletion config model )


toCompletion
    :: (MonadIO m, MonadFail m)
    => Config
    -> Model
    -> Producer LogOrModel m ()
toCompletion config@Config{..} m = do
    m2 <- prologue m
    logInfo $ modelInfo m2
    loopy m2
    where
        driver = strategyToDriver strategyQ strategyA
        loopy model = do
            qs <- remaining config model
            if null qs
                then do
                    model' <- epilogue model
                    yield (Right model')
                else do
                    nextModels <- driver qs
                    mapM_ loopy nextModels


inAReference :: Zipper a Expression -> Bool
inAReference x = not $ null [ () | Reference{} <- tail (ascendants x) ]


remaining
    :: MonadLog m
    => Config
    -> Model
    -> m [Question]
remaining config model = do
    let freshNames' = freshNames model
    let modelZipper = fromJustNote "Creating the initial zipper." (zipperBi model)
    let
        loopLevels :: Monad m => [m [a]] -> m [a]
        loopLevels [] = return []
        loopLevels (a:as) = do bs <- a
                               if null bs
                                   then loopLevels as
                                   else return bs

        processLevel :: MonadLog m => [Rule] -> m [(Zipper Model Expression, [(Doc, RuleResult m)])]
        processLevel rulesAtLevel =
            fmap catMaybes $ forM (allContexts modelZipper) $ \ x ->
                -- things in a reference should not be rewritten.
                -- specifically, no representation selection for them!
                if inAReference x
                    then return Nothing
                    else do
                        ys <- applicableRules config rulesAtLevel (hole x)
                        return $ if null ys
                                    then Nothing
                                    else Just (x, ys)

    questions <- loopLevels $ map processLevel (allRules config)
    forM (zip allNats questions) $ \ (nQuestion, (focus, answers)) -> do
        answers' <- forM (zip allNats answers) $ \ (nAnswer, (ruleName, (ruleText, ruleResult, hook))) -> do
            let ruleResultExpr = ruleResult freshNames'
            aFullModel' <- hook (fromZipper (replaceHole ruleResultExpr focus))
            return Answer
                { aText = ruleName <> ":" <+> ruleText
                , aAnswer = ruleResultExpr
                , aFullModel = aFullModel'
                                |> addToTrail config
                                            nQuestion [1 .. length questions]
                                            (("Focus:" <+> pretty (hole focus))
                                             : [ nest 4 ("Context #" <> pretty i <> ":" <+> pretty c)
                                               | i <- allNats
                                               | c <- tail (ascendants focus)
                                               ])
                                            nAnswer   [1 .. length answers]
                                            [ruleName <> ":" <+> ruleText]
                }
        return Question
            { qHole = hole focus
            , qAscendants = tail (ascendants focus)
            , qAnswers = answers'
            }


strategyToDriver :: Strategy -> Strategy -> Driver
strategyToDriver strategyQ strategyA questions = do
    let optionsQ =
            [ (doc, q) 
            | (n, q) <- zip allNats questions
            , let doc =
                    vcat $ ("Question" <+> pretty n <> ":" <+> pretty (qHole q))
                         : [ nest 4 ("Context #" <> pretty i <> ":" <+> pretty c)
                           | i <- allNats
                           | c <- qAscendants q
                           ]
            ]
    pickedQs <- executeStrategy optionsQ strategyQ
    fmap concat $ forM pickedQs $ \ pickedQ -> do
        let optionsA =
                [ (doc, a) 
                | (n, a) <- zip allNats (qAnswers pickedQ)
                , let doc =
                        nest 4 $ "Answer" <+> pretty n <> ":" <+> vcat [ pretty (aText a)
                                                                       , pretty (aAnswer a) ]
                ]
        pickedAs <- executeStrategy optionsA strategyA
        return (map aFullModel pickedAs)


executeStrategy :: (MonadIO m, MonadLog m) => [(Doc, a)] -> Strategy -> m [a]
executeStrategy [] _ = bug "executeStrategy: nothing to choose from"
executeStrategy [(doc, option)] (viewAuto -> (_, True)) = do
    logInfo ("Picking the only option:" <+> doc)
    return [option]
executeStrategy options@((doc, option):_) (viewAuto -> (strategy, _)) =
    case strategy of
        Auto _      -> bug "executeStrategy: Auto"
        PickFirst   -> do
            logInfo ("Picking the first option:" <+> doc)
            return [option]
        PickAll     -> return (map snd options)
        Interactive -> do
            pickedIndex <- liftIO $ do
                print (vcat (map fst options))
                putStr "Pick option: "
                readNote "Expecting an integer." <$> getLine
            let picked = snd (at options (pickedIndex - 1))
            return [picked]


addToTrail
    :: Config
    -> Int -> [Int] -> [Doc]
    -> Int -> [Int] -> [Doc]
    -> Model -> Model
addToTrail Config{..}
           nQuestion nQuestions tQuestion
           nAnswer nAnswers tAnswer
           model = model { mInfo = newInfo }
    where
        oldInfo = mInfo model
        newInfo = oldInfo { miTrailCompact = miTrailCompact oldInfo ++ [(nQuestion, nQuestions), (nAnswer, nAnswers)]
                          , miTrailVerbose = if verboseTrail
                                                  then miTrailVerbose oldInfo ++ [theQ, theA]
                                                  else []
                          }
        theQ = Decision
            { dDescription = map (stringToText . renderWide)
                $ ("Question #" <> pretty nQuestion <+> "out of" <+> pretty (length nQuestions))
                : tQuestion
            , dOptions = nQuestions
            , dDecision = nQuestion
            }
        theA = Decision
            { dDescription = map (stringToText . renderWide)
                $ ("Answer #" <> pretty nAnswer <+> "out of" <+> pretty (length nAnswers))
                : tAnswer
            , dOptions = nAnswers
            , dDecision = nAnswer
            }


allFixedQs :: Driver
allFixedQs = strategyToDriver PickFirst PickAll

pickFirst :: Driver
pickFirst = strategyToDriver PickFirst PickFirst

interactive :: Driver
interactive = strategyToDriver Interactive Interactive

interactiveFixedQs :: Driver
interactiveFixedQs = strategyToDriver PickFirst Interactive

interactiveFixedQsAutoA :: Driver
interactiveFixedQsAutoA = strategyToDriver PickFirst (Auto Interactive)



-- | For every parameter and decision variable add a true-constraint.
--   A true-constraint has no effect, other than forcing Conjure to produce a representation.
--   It can be used to make sure that the decision variable doesn't get lost when it isn't mentioned anywhere.
--   It can also be used to produce "extra" representations.
--   Currently this function will add a true for every declaration, no matter if it is mentioned or not.
addTrueConstraints :: Model -> Model
addTrueConstraints m =
    let
        mkTrueConstraint k nm dom = Op $ MkOpTrue $ OpTrue (Reference nm (Just (DeclNoRepr k nm dom)))
        trueConstraints = [ mkTrueConstraint forg nm d
                          | Declaration (FindOrGiven forg nm d) <- mStatements m
                          ]
    in
        m { mStatements = mStatements m ++ [SuchThat trueConstraints] }


oneSuchThat :: Model -> Model
oneSuchThat m =
    let outStatements = transformBi onLocals (mStatements m)
    in  m { mStatements = onStatements outStatements }

    where

        onStatements :: [Statement] -> [Statement]
        onStatements xs =
            let
                (others, suchThats) = xs
                      |> map collect                                            -- separate such thats from the rest
                      |> mconcat
                      |> second (map breakConjunctions)                         -- break top level /\'s
                      |> second mconcat
                      |> second (filter (/= Constant (ConstantBool True)))      -- remove top level true's
                      |> second nub                                             -- uniq
            in
                others ++ [SuchThat (combine suchThats)]

        onLocals :: Expression -> Expression
        onLocals (WithLocals x locals) = WithLocals x (onStatements locals)
        onLocals x = x

        collect :: Statement -> ([Statement], [Expression])
        collect (SuchThat s) = ([], s)
        collect s = ([s], [])

        combine :: [Expression] -> [Expression]
        combine xs = if null xs
                        then [Constant (ConstantBool True)]
                        else xs

        breakConjunctions :: Expression -> [Expression]
        breakConjunctions   (Op (MkOpAnd (OpAnd [ ]))) = bug "empty /\\"
        breakConjunctions x@(Op (MkOpAnd (OpAnd [_]))) = [x]
        breakConjunctions (Op (MkOpAnd (OpAnd xs))) = concatMap breakConjunctions xs
        breakConjunctions x = [x]


inlineDecVarLettings :: Model -> Model
inlineDecVarLettings model =
    let
        inline p@(Reference nm _) = do
            x <- gets (lookup nm)
            return (fromMaybe p x)
        inline p = return p

        statements = catMaybes
                        $ flip evalState []
                        $ forM (mStatements model)
                        $ \ st ->
            case st of
                Declaration (Letting nm x)
                    | categoryOf x == CatDecision
                    -> modify ((nm,x) :) >> return Nothing
                _ -> Just <$> transformBiM inline st
    in
        model { mStatements = statements }


updateDeclarations :: Model -> Model
updateDeclarations model =
    let
        representations = model |> mInfo |> miRepresentations

        statements = concatMap onEachStatement (mStatements model)

        onEachStatement inStatement =
            case inStatement of
                Declaration (FindOrGiven forg nm _) ->
                    case [ d | (n, d) <- representations, n == nm ] of
                        [] -> bug $ "No representation chosen for: " <+> pretty nm
                        domains -> concatMap (onEachDomain forg nm) domains
                Declaration (GivenDomainDefnEnum name) ->
                    [ Declaration (FindOrGiven Given (name `mappend` "_EnumSize") (DomainInt [])) ]
                Declaration LettingDomainDefnEnum{}    -> []
                Declaration LettingDomainDefnUnnamed{} -> []
                _ -> [inStatement]

        onEachDomain forg nm domain =
            case downD (nm, domain) of
                Left err -> bug err
                Right outs -> [Declaration (FindOrGiven forg n (forgetRepr d)) | (n, d) <- outs]

    in
        model { mStatements = statements }


-- | checking whether any `Reference`s with `DeclHasRepr`s are left in the model
checkIfAllRefined :: MonadFail m => Model -> m ()
checkIfAllRefined m = do
    let modelZipper = fromJustNote "checkIfAllRefined: Creating zipper." (zipperBi m)
    fails <- fmap concat $ forM (allContexts modelZipper) $ \ x ->
                case hole x of
                    Reference _ (Just (DeclHasRepr _ _ dom))
                        | not (isPrimitiveDomain dom) ->
                        return $ ""
                               : ("Not refined:" <+> pretty (hole x))
                               : ("Domain     :" <+> pretty dom)
                               : [ nest 4 ("Context #" <> pretty i <> ":" <+> pretty c)
                                 | i <- allNats
                                 | c <- tail (ascendants x)
                                 ]
                    _ -> return []
    unless (null fails) (fail (vcat fails))


prologue :: (MonadFail m, MonadLog m) => Model -> m Model
prologue model = return model
                                    >>= logDebugId "[input]"
    >>= return . initInfo           >>= logDebugId "[initInfo]"
    >>= removeUnnamedsFromModel     >>= logDebugId "[removeUnnamedsFromModel]"
    >>= removeEnumsFromModel        >>= logDebugId "[removeEnumsFromModel]"
    >>= resolveNames                >>= logDebugId "[resolveNames]"
    >>= return . addTrueConstraints >>= logDebugId "[addTrueConstraints]"


epilogue :: MonadFail m => Model -> m Model
epilogue eprime = do
    checkIfAllRefined eprime
    eprime
        |> updateDeclarations
        |> inlineDecVarLettings
        |> oneSuchThat
        |> languageEprime
        |> return


applicableRules
    :: forall m . MonadLog m
    => Config
    -> [Rule]
    -> Expression
    -> m [(Doc, RuleResult m)]
applicableRules Config{..} rulesAtLevel x = do
    let logAttempt = if logRuleAttempts  then logInfo else const (return ())
    let logFail    = if logRuleFails     then logInfo else const (return ())
    let logSuccess = if logRuleSuccesses then logInfo else const (return ())

    mys <- sequence [ do logAttempt ("attempting rule" <+> rName r <+> "on" <+> pretty x)
                         return (rName r, runIdentity $ runExceptT $ rApply r x)
                    | r <- rulesAtLevel ]
    forM_ mys $ \ (rule, my) ->
        case my of
            Left  failed -> unless ("N/A" `isPrefixOf` show failed) $ logFail $ vcat
                [ " rule failed:" <+> rule
                , "          on:" <+> pretty x
                , "     message:" <+> failed
                ]
            Right ys     -> logSuccess $ vcat
                [ "rule applied:" <+> rule
                , "          on:" <+> pretty x
                , "     message:" <+> vcat (map fst3 ys)
                ]
    return [ (name, (msg, out', hook))
           | (name, Right ress) <- mys
           , (msg, out, hook) <- ress
           , let out' fresh = out fresh |> resolveNamesX |> bugFail     -- re-resolving names
           ]


allRules :: Config -> [[Rule]]
allRules config =
    [ [rule_ChooseRepr config]
    , verticalRules
    , horizontalRules
    , otherRules
    ]

verticalRules :: [Rule]
verticalRules =
    [ Vertical.Tuple.rule_Tuple_Eq
    , Vertical.Tuple.rule_Tuple_Leq
    , Vertical.Tuple.rule_Tuple_Lt
    , Vertical.Tuple.rule_Tuple_Index
    , Vertical.Tuple.rule_Tuple_DomainComprehension

    , Vertical.Matrix.rule_Matrix_Eq
    , Vertical.Matrix.rule_Matrix_Leq
    , Vertical.Matrix.rule_Matrix_Lt

    , Vertical.Set.Explicit.rule_Comprehension
    , Vertical.Set.ExplicitVarSizeWithFlags.rule_Comprehension
    , Vertical.Set.ExplicitVarSizeWithMarker.rule_Card
    , Vertical.Set.ExplicitVarSizeWithMarker.rule_Comprehension
    , Vertical.Set.Occurrence.rule_Comprehension
    , Vertical.Set.Occurrence.rule_In

    , Vertical.Function.Function1D.rule_Comprehension
    , Vertical.Function.Function1D.rule_Image

    , Vertical.Function.Function1DPartial.rule_Comprehension
    , Vertical.Function.Function1DPartial.rule_Image
    , Vertical.Function.Function1DPartial.rule_InDefined

    , Vertical.Function.FunctionND.rule_Comprehension
    , Vertical.Function.FunctionND.rule_Image

    , Vertical.Function.FunctionNDPartial.rule_Comprehension
    , Vertical.Function.FunctionNDPartial.rule_Image
    , Vertical.Function.FunctionNDPartial.rule_InDefined

    , Vertical.Relation.RelationAsMatrix.rule_Comprehension
    , Vertical.Relation.RelationAsMatrix.rule_Image
    ]

horizontalRules :: [Rule]
horizontalRules =
    [ Horizontal.Set.rule_Eq
    , Horizontal.Set.rule_Neq
    , Horizontal.Set.rule_Leq
    , Horizontal.Set.rule_Lt
    , Horizontal.Set.rule_Subset
    , Horizontal.Set.rule_SubsetEq
    , Horizontal.Set.rule_Supset
    , Horizontal.Set.rule_SupsetEq
    , Horizontal.Set.rule_In
    , Horizontal.Set.rule_Card
    , Horizontal.Set.rule_Intersect
    , Horizontal.Set.rule_Union
    , Horizontal.Set.rule_MaxMin

    , Horizontal.Function.rule_Eq
    , Horizontal.Function.rule_Neq
    , Horizontal.Function.rule_Leq
    , Horizontal.Function.rule_Lt
    , Horizontal.Function.rule_Comprehension_PreImage

    , Horizontal.Relation.rule_Eq
    , Horizontal.Relation.rule_In
    ]

otherRules :: [Rule]
otherRules = 
    [ rule_TrueIsNoOp
    , rule_ToIntIsNoOp
    , rule_SingletonAnd
    , rule_FlattenOf1D
    , rule_Decompose_AllDiff
    , rule_SumFlatten

    , rule_BubbleUp
    , rule_BubbleToAnd

    , rule_Bool_DontCare
    , rule_Int_DontCare
    , rule_Tuple_DontCare
    , rule_Matrix_DontCare
    , rule_Set_DontCare

    , rule_ComplexAbsPat
    , rule_Set_Comprehension_Literal
    ] ++ rule_InlineFilters


rule_ChooseRepr :: Config -> Rule
rule_ChooseRepr config = Rule "choose-repr" theRule where

    theRule (Reference nm (Just (DeclNoRepr forg _ inpDom))) = do
        let domOpts = reprOptions inpDom
        when (null domOpts) $
            bug $ "No representation matches this beast:" <++> pretty inpDom
        let options =
                [ (msg, const out, hook)
                | dom <- domOpts
                , let msg = "Choosing representation for" <+> pretty nm <> ":" <++> pretty dom
                , let out = Reference nm (Just (DeclHasRepr forg nm dom))
                , let hook = mkHook (channelling config) forg nm dom
                ]
        return $ if forg == Given && parameterRepresentation config == False
                    then take 1 options
                    else options 
    theRule _ = na "rule_ChooseRepr"

    mkHook useChannelling   -- whether to use channelling or not
           forg             -- find or given
           name             -- name of the original declaration
           domain           -- domain with representation selected
           model = do
        let

            freshNames' = freshNames model

            representations = model |> mInfo |> miRepresentations

            usedBefore = (name, domain) `elem` representations

            mstructurals = do
                refs <- downToX1 Find name domain
                gen  <- getStructurals downX1 domain
                gen freshNames' refs >>= mapM resolveNamesX     -- re-resolving names

            structurals = case mstructurals of
                Left err -> bug ("rule_ChooseRepr.hook.structurals" <+> err)
                Right s  -> s

            addStructurals
                | forg == Given = id
                | usedBefore = id
                | null structurals = id
                | otherwise = \ m ->
                    m { mStatements = mStatements m ++ [SuchThat structurals] }

            channels =
                [ make opEq this that
                | (n, d) <- representations
                , n == name
                , let this = Reference name (Just (DeclHasRepr forg name domain))
                , let that = Reference name (Just (DeclHasRepr forg name d))
                ]

            addChannels
                | forg == Given = id
                | usedBefore = id
                | null channels = id
                | otherwise = \ m ->
                    m { mStatements = mStatements m ++ [SuchThat channels] }

            recordThis
                | usedBefore = id
                | otherwise = \ m ->
                let
                    oldInfo = mInfo m
                    newInfo = oldInfo { miRepresentations = miRepresentations oldInfo ++ [(name, domain)] }
                in  m { mInfo = newInfo }

            fixReprForOthers
                | useChannelling = id           -- no-op, if channelling=yes
                | otherwise = \ m ->
                let
                    f (Reference nm (Just DeclNoRepr{})) = Reference nm (Just (DeclHasRepr forg name domain))
                    f x = x
                in
                    m { mStatements = transformBi f (mStatements m) }

        model
            |> addStructurals       -- unless usedBefore: add structurals
            |> addChannels          -- for each in previously recorded representation
            |> recordThis           -- unless usedBefore: record (name, domain) as being used in the model
            |> fixReprForOthers     -- fix the representation of this guy in the whole model, if channelling=no
            |> return


rule_TrueIsNoOp :: Rule
rule_TrueIsNoOp = "true-is-noop" `namedRule` theRule where
    theRule (Op (MkOpTrue (OpTrue ref))) =
        case ref of
            Reference _ (Just DeclHasRepr{}) ->
                return ( "Remove the argument from true."
                       , const $ Constant $ ConstantBool True
                       )
            _ -> fail "The argument of true doesn't have a representation."
    theRule _ = na "rule_TrueIsNoOp"


rule_ToIntIsNoOp :: Rule
rule_ToIntIsNoOp = "toInt-is-noop" `namedRule` theRule where
    theRule p = do
        x <- match opToInt p
        return ( "Remove the toInt wrapper, it is implicit in SR."
               , const x
               )


rule_SingletonAnd :: Rule
rule_SingletonAnd = "singleton-and" `namedRule` theRule where
    theRule p = do
        [x]      <- match opAnd p
        TypeBool <- typeOf x
        return ( "singleton and, removing the wrapper"
               , const x
               )


rule_FlattenOf1D :: Rule
rule_FlattenOf1D = "flatten-of-1D" `namedRule` theRule where
    theRule p = do
        x                   <- match opFlatten p
        TypeMatrix _ xInner <- typeOf x
        case xInner of
            TypeBool{} -> return ()
            TypeInt{}  -> return ()
            _ -> na "rule_FlattenOf1D"
        return ( "1D matrices do not need a flatten."
               , const x
               )


rule_Decompose_AllDiff :: Rule
rule_Decompose_AllDiff = "decompose-allDiff" `namedRule` theRule where
    theRule [essence| allDiff(&m) |] = do
        ty <- typeOf m
        case ty of
            TypeMatrix _ TypeBool -> fail "allDiff can stay"
            TypeMatrix _ TypeInt  -> fail "allDiff can stay"
            TypeMatrix _ _ -> return ()
            _ -> fail "allDiff on something other than a matrix."
        DomainMatrix index _ <- domainOf m
        return
            ( "Decomposing allDiff. Type:" <+> pretty ty
            , \ fresh ->
                    let
                        (iPat, i) = quantifiedVar (fresh `at` 0)
                        (jPat, j) = quantifiedVar (fresh `at` 1)
                    in
                        [essence|
                            and([ &m[&i] != &m[&j]
                                | &iPat : &index
                                , &jPat : &index
                                , &i < &j
                                ])
                        |]
            )
    theRule _ = na "rule_Decompose_AllDiff"


rule_SumFlatten :: Rule
rule_SumFlatten = "sum-flatten" `namedRule` theRule where
    theRule p = do
        [x]                             <- match opSum p
        AbstractLiteral (AbsLitList xs) <- match opFlatten x
        let y = make opSum $ map (make opSum . return) xs
        return ( "Flatten inside a sum."
               , const y
               )


rule_BubbleUp :: Rule
rule_BubbleUp = "bubble-up" `namedRule` theRule where
    theRule (WithLocals (WithLocals x locals1) locals2) =
        return ( "Bubbling up nested bubbles"
               , const $ WithLocals x (locals1 ++ locals2)
               )
    theRule p = do
        (m, x) <- match opIndexing p
        case (m, x) of
            (WithLocals m' locals1, WithLocals x' locals2) ->
                return ( "Bubbling up when the bubble is used to index something (1/3)"
                       , const $ WithLocals (make opIndexing m' x') (locals1 ++ locals2)
                       )
            (WithLocals m' locals1, x') ->
                return ( "Bubbling up when the bubble is used to index something (2/3)"
                       , const $ WithLocals (make opIndexing m' x') locals1
                       )
            (m', WithLocals x' locals2) ->
                return ( "Bubbling up when the bubble is used to index something (3/3)"
                       , const $ WithLocals (make opIndexing m' x') locals2
                       )
            _ -> na "rule_BubbleUp"


rule_BubbleToAnd :: Rule
rule_BubbleToAnd = "bubble-to-and" `namedRule` theRule where
    theRule (WithLocals x []) = return ("Empty bubble is no bubble", const x)
    theRule (WithLocals x locals) = do
        TypeBool <- typeOf x
        cons     <- onlyConstraints locals
        let outs = x:cons
        let out = case outs of
                    [_] -> x
                    _   -> make opAnd outs
        return ( "Converting a bubble into a conjunction."
               , const out
               )
    theRule _ = na "rule_BubbleToAnd"

    onlyConstraints :: MonadFail m => [Statement] -> m [Expression]
    onlyConstraints [] = return []
    onlyConstraints (SuchThat xs:rest) = (xs++) <$> onlyConstraints rest
    onlyConstraints _ = fail "onlyConstraints: not a SuchThat"


rule_Bool_DontCare :: Rule
rule_Bool_DontCare = "dontCare-bool" `namedRule` theRule where
    theRule p = do
        x          <- match opDontCare p
        DomainBool <- domainOf x
        return ( "dontCare value for bools is false."
               , const $ make opEq x (fromBool False)
               )


rule_Int_DontCare :: Rule
rule_Int_DontCare = "dontCare-int" `namedRule` theRule where
    theRule p = do
        x                          <- match opDontCare p
        xDomain@(DomainInt ranges) <- domainOf x
        let raiseBug = bug ("dontCare on domain:" <+> pretty xDomain)
        let val = case ranges of
                [] -> raiseBug
                (r:_) -> case r of
                    RangeOpen -> raiseBug
                    RangeSingle v -> v
                    RangeLowerBounded v -> v
                    RangeUpperBounded v -> v
                    RangeBounded v _ -> v
        return ( "dontCare value for this integer is" <+> pretty val
               , const $ make opEq x val
               )


rule_Tuple_DontCare :: Rule
rule_Tuple_DontCare = "dontCare-tuple" `namedRule` theRule where
    theRule p = do
        x           <- match opDontCare p
        TypeTuple{} <- typeOf x
        xs          <- downX1 x
        return ( "dontCare handling for tuple"
               , const $ make opAnd (map (make opDontCare) xs)
               )


rule_Matrix_DontCare :: Rule
rule_Matrix_DontCare = "dontCare-matrix" `namedRule` theRule where
    theRule p = do
        x                    <- match opDontCare p
        DomainMatrix index _ <- domainOf x
        return ( "dontCare handling for matrix"
               , \ fresh ->
                    let (iPat, i) = quantifiedVar (fresh `at` 0)
                    in  [essence| forAll &iPat : &index . dontCare(&x[&i]) |]
               )


rule_Set_DontCare :: Rule
rule_Set_DontCare = "dontCare-set" `namedRule` theRule where
    theRule p = do
        x         <- match opDontCare p
        TypeSet{} <- typeOf x
        hasRepresentation x
        xs        <- downX1 x
        return ( "dontCare handling for tuple"
               , const $ make opAnd (map (make opDontCare) xs)
               )


rule_ComplexAbsPat :: Rule
rule_ComplexAbsPat = "complex-pattern" `namedRule` theRule where
    theRule (Comprehension body gensOrFilters) = do
        (gofBefore, (pat, domainOrExpr), gofAfter) <- matchFirst gensOrFilters $ \ gof -> case gof of
            Generator (GenDomain pat@AbsPatTuple{} domain) -> return (pat, Left domain)
            Generator (GenInExpr pat@AbsPatTuple{} expr)   -> return (pat, Right expr)
            _ -> na "rule_ComplexAbsPat"
        return
            ( "complex pattern on tuple patterns"
            , \ fresh ->
                    let (iPat, i) = quantifiedVar (fresh `at` 0)
                        replacements = [ (p, make opIndexing' i (map fromInt is))
                                       | (p, is) <- genMappings pat
                                       ]
                        f x@(Reference nm _) = fromMaybe x (lookup nm replacements)
                        f x = x
                    in
                        Comprehension (transform f body)
                            $  gofBefore
                            ++ [ either (\ domain -> Generator (GenDomain iPat domain) )
                                        (\ expr   -> Generator (GenInExpr iPat expr  ) )
                                        domainOrExpr ]
                            ++ transformBi f gofAfter
            )
    theRule _ = na "rule_ComplexAbsPat"

    -- i         --> i -> []
    -- (i,j)     --> i -> [1]
    --               j -> [2]
    -- (i,(j,k)) --> i -> [1]
    --               j -> [2,1]
    --               k -> [2,2]
    genMappings :: AbstractPattern -> [(Name, [Int])]
    genMappings (Single nm) = [(nm, [])]
    genMappings (AbsPatTuple pats)
        = concat
            [ [ (patCore, i:is) | (patCore, is) <- genMappings pat ]
            | (i, pat) <- zip [1..] pats
            ]
    genMappings (AbsPatMatrix pats)
        = concat
            [ [ (patCore, i:is) | (patCore, is) <- genMappings pat ]
            | (i, pat) <- zip [1..] pats
            ]
    genMappings pat = bug ("rule_ComplexLambda.genMappings:" <+> pretty (show pat))


rule_InlineFilters :: [Rule]
rule_InlineFilters =
    [ namedRule "filter-inside-and" $ ruleGen_InlineFilters opAnd opAndSkip
    , namedRule "filter-inside-or"  $ ruleGen_InlineFilters opOr  opOrSkip
    , namedRule "filter-inside-sum" $ ruleGen_InlineFilters opSum opSumSkip
    , namedRule "filter-inside-max" $ ruleGen_InlineFilters opMax opMaxSkip
    , namedRule "filter-inside-min" $ ruleGen_InlineFilters opMin opMinSkip
    ]
    where
        opAndSkip x y = make opImply x y
        opOrSkip  x y = make opAnd [x,y]
        opSumSkip b x = make opTimes (make opToInt b) x
        opMaxSkip b x = [essence| toInt(&b) * &x |]                          -- MININT is 0
        opMinSkip b x = [essence| toInt(&b) * &x + toInt(!&b) * 9999 |]      -- MAXINT is 9999

ruleGen_InlineFilters
    :: MonadFail m
    => (forall m1 . MonadFail m1
            => Proxy (m1 :: * -> *)
            -> ( [Expression] -> Expression , Expression -> m1 [Expression] )
       )
    -> (Expression -> Expression -> Expression)
    -> Expression
    -> m (Doc, [Name] -> Expression)
ruleGen_InlineFilters opQ opSkip p = do
    [Comprehension body gensOrFilters] <- match opQ p
    let (toInline, toKeep) = mconcat
            [ case gof of
                Filter x | categoryOf x == CatDecision -> ([x],[])
                _ -> ([],[gof])
            | gof <- gensOrFilters
            ]
    theGuard <- case toInline of
        []  -> fail "No filter to inline."
        [x] -> return x
        xs  -> return $ make opAnd xs
    return ( "Inlining filters"
           , const $ make opQ $ return $
               Comprehension (opSkip theGuard body) toKeep
           )


-- TODO: convert to multiple generators, if needed
rule_Set_Comprehension_Literal :: Rule
rule_Set_Comprehension_Literal = "set-mapSetLiteral" `namedRule` theRule where
    theRule (Comprehension body [Generator (GenInExpr pat s)]) = do
        elems <- match setLiteral s
        let f = lambdaToFunction pat body
        return ( "Membership on set literals"
               , const $ AbstractLiteral $ AbsLitMatrix
                           (DomainInt [RangeBounded (fromInt 1) (fromInt (length elems))])
                           [ f e
                           | e <- elems
                           ]
               )
    theRule _ = na "rule_Set_Comprehension_Literal"
