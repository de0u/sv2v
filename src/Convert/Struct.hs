{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for `struct packed`
 -}

module Convert.Struct (convert) where

import Control.Monad.State
import Control.Monad.Writer
import Data.Hashable (hash)
import Data.List (elemIndex, sortOn)
import Data.Maybe (fromJust, isJust)
import Data.Tuple (swap)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Convert.Traverse
import Language.SystemVerilog.AST

type TypeFunc = [Range] -> Type
type StructInfo = (Type, Map.Map Identifier (Range, Expr))
type Structs = Map.Map TypeFunc StructInfo
type Types = Map.Map Identifier Type
type Idents = Set.Set Identifier

convert :: [AST] -> [AST]
convert = map $ traverseDescriptions convertDescription

convertDescription :: Description -> Description
convertDescription (description @ (Part _ _ _ _ _ _)) =
    traverseModuleItems (traverseTypes $ convertType structs) $
    Part extern kw lifetime name ports (items ++ funcs)
    where
        description' @ (Part extern kw lifetime name ports items) =
            scopedConversion traverseDeclM traverseModuleItemM traverseStmtM
                tfArgTypes description
        -- collect information about this description
        structs = execWriter $ collectModuleItemsM
            (collectTypesM collectStructM) description
        tfArgTypes = execWriter $ collectModuleItemsM collectTFArgsM description
        -- determine which of the packer functions we actually need
        calledFuncs = execWriter $ collectModuleItemsM
            (collectExprsM $ collectNestedExprsM collectCallsM) description'
        packerFuncs = Set.map packerFnName $ Map.keysSet structs
        calledPackedFuncs = Set.intersection calledFuncs packerFuncs
        funcs = map packerFn $ filter isNeeded $ Map.keys structs
        isNeeded tf = Set.member (packerFnName tf) calledPackedFuncs
        -- helpers for the scoped traversal
        traverseModuleItemM :: ModuleItem -> State Types ModuleItem
        traverseModuleItemM item =
            traverseExprsM traverseExprM item >>=
            traverseAsgnsM traverseAsgnM
        traverseStmtM :: Stmt -> State Types Stmt
        traverseStmtM (Subroutine Nothing f args) = do
            stateTypes <- get
            return $ uncurry (Subroutine Nothing) $
                convertCall structs stateTypes f args
        traverseStmtM stmt =
            traverseStmtExprsM traverseExprM stmt >>=
            traverseStmtAsgnsM traverseAsgnM
        traverseExprM =
            traverseNestedExprsM $ stately converter
            where
                converter :: Types -> Expr -> Expr
                converter types expr =
                    snd $ convertAsgn structs types (LHSIdent "", expr)
        traverseAsgnM = stately $ convertAsgn structs
convertDescription other = other

-- write down unstructured versions of packed struct types
collectStructM :: Type -> Writer Structs ()
collectStructM (Struct (Packed sg) fields _) = do
    if canUnstructure
        then tell $ Map.singleton
            (Struct (Packed sg) fields)
            (unstructType, unstructFields)
        else return ()
    where
        zero = Number "0"
        typeRange :: Type -> Range
        typeRange t =
            if null ranges then (zero, zero) else head ranges
            where ranges = snd $ typeRanges t

        -- extract info about the fields
        fieldTypes = map fst fields
        fieldRanges = map typeRange fieldTypes
        fieldSizes = map rangeSize fieldRanges

        -- layout the fields into the unstructured type; note that `scanr` is
        -- used here because SystemVerilog structs are laid out backwards
        fieldLos = map simplify $ tail $ scanr (BinOp Add) (Number  "0") fieldSizes
        fieldHis = map simplify $ init $ scanr (BinOp Add) (Number "-1") fieldSizes

        -- create the mapping structure for the unstructured fields
        unstructOffsets = map simplify $ map snd fieldRanges
        unstructRanges = zip fieldHis fieldLos
        keys = map snd fields
        vals = zip unstructRanges unstructOffsets
        unstructFields = Map.fromList $ zip keys vals

        -- create the unstructured type; result type takes on the signing of the
        -- struct itself to preserve behavior of operations on the whole struct
        structSize = foldl1 (BinOp Add) fieldSizes
        packedRange = (simplify $ BinOp Sub structSize (Number "1"), zero)
        unstructType = IntegerVector TLogic sg [packedRange]

        -- check if this struct can be packed into an integer vector; integer
        -- atoms and non-integers do not have a definitive size, and so cannot
        -- be packed; net types are not permitted as struct fields
        isIntVec :: Type -> Bool
        isIntVec (IntegerVector _ _ _) = True
        isIntVec _ = False
        canUnstructure = all isIntVec fieldTypes

collectStructM _ = return ()

-- convert a struct type to its unstructured equivalent
convertType :: Structs -> Type -> Type
convertType structs t1 =
    case Map.lookup tf1 structs of
        Nothing -> t1
        Just (t2, _) -> tf2 (rs1 ++ rs2)
            where (tf2, rs2) = typeRanges t2
    where (tf1, rs1) = typeRanges t1

-- writes down the names of called functions
collectCallsM :: Expr -> Writer Idents ()
collectCallsM (Call Nothing f _) = tell $ Set.singleton f
collectCallsM _ = return ()

collectTFArgsM :: ModuleItem -> Writer Types ()
collectTFArgsM (MIPackageItem item) = do
    _ <- case item of
        Function _ t f decls _ -> do
            tell $ Map.singleton f t
            mapM (collect f) (zip [0..] decls)
        Task     _   f decls _ ->
            mapM (collect f) (zip [0..] decls)
        _ -> return []
    return ()
    where
        collect :: Identifier -> (Int, Decl) -> Writer Types ()
        collect f (idx, (Variable _ t x _ _)) = do
            tell $ Map.singleton (f ++ ":" ++ show idx) t
            tell $ Map.singleton (f ++ ":" ++ x) t
        collect _ _ = return ()
collectTFArgsM _ = return ()

-- write down the types of declarations
traverseDeclM :: Decl -> State Types Decl
traverseDeclM origDecl = do
    case origDecl of
        Variable _ t x a _ -> do
            let (tf, rs) = typeRanges t
            modify $ Map.insert x (tf $ a ++ rs)
        Parameter  t x _   -> modify $ Map.insert x t
        Localparam t x _   -> modify $ Map.insert x t
    return origDecl

-- produces a function which packs the components of a struct literal
packerFn :: TypeFunc -> ModuleItem
packerFn structTf =
    MIPackageItem $
    Function Nothing (structTf []) fnName decls [retStmt]
    where
        Struct (Packed _) fields [] = structTf []
        toInput (t, x) = Variable Input t x [] Nothing
        decls = map toInput fields
        retStmt = Return $ Concat $ map (Ident . snd) fields
        fnName = packerFnName structTf

-- returns a "unique" name for the packer for a given struct type
packerFnName :: TypeFunc -> Identifier
packerFnName structTf =
    "sv2v_pack_struct_" ++ str
    where
        val = hash $ show structTf
        str = tail $ show val

-- This is where the magic happens. This is responsible for converting struct
-- accesses, assignments, and literals, given appropriate information about the
-- structs and the current declaration context. The general strategy involves
-- looking at the innermost type of a node to convert outer uses of fields, and
-- then using the outermost type to figure out the corresponding struct
-- definition for struct literals that are encountered.
convertAsgn :: Structs -> Types -> (LHS, Expr) -> (LHS, Expr)
convertAsgn structs types (lhs, expr) =
    (lhs', expr')
    where
        (typ, lhs') = convertLHS lhs
        expr' = snd $ convertSubExpr $ convertExpr typ expr

        -- converting LHSs by looking at the innermost types first
        convertLHS :: LHS -> (Type, LHS)
        convertLHS (LHSIdent  x) =
            case Map.lookup x types of
                Nothing -> (Implicit Unspecified [], LHSIdent x)
                Just t -> (t, LHSIdent x)
        convertLHS (LHSBit l e) =
            case l' of
                LHSRange lInner NonIndexed (_, loI) ->
                    (t', LHSBit lInner (simplify $ BinOp Add loI e))
                LHSRange lInner IndexedPlus (baseI, _) ->
                    (t', LHSBit lInner (simplify $ BinOp Add baseI e))
                _ -> (t', LHSBit l' e)
            where
                (t, l') = convertLHS l
                t' = case typeRanges t of
                    (_, []) -> Implicit Unspecified []
                    (tf, rs) -> tf $ tail rs
        convertLHS (LHSRange lOuter NonIndexed rOuter) =
            case lOuter' of
                LHSRange lInner NonIndexed (_, loI) ->
                    (t, LHSRange lInner NonIndexed (simplify hi, simplify lo))
                    where
                        lo = BinOp Add loI loO
                        hi = BinOp Add loI hiO
                LHSRange lInner IndexedPlus (baseI, _) ->
                    (t, LHSRange lInner IndexedPlus (simplify base, simplify len))
                    where
                        base = BinOp Add baseI loO
                        len = rangeSize rOuter
                _ -> (t, LHSRange lOuter' NonIndexed rOuter)
            where
                (hiO, loO) = rOuter
                (t, lOuter') = convertLHS lOuter
        convertLHS (LHSRange l m r) =
            (t', LHSRange l' m r)
            where
                (t, l') = convertLHS l
                t' = case typeRanges t of
                    (_, []) -> Implicit Unspecified []
                    (tf, rs) -> tf $ tail rs
        convertLHS (LHSDot    l x ) =
            case t of
                InterfaceT _ _ _ -> (Implicit Unspecified [], LHSDot l' x)
                Struct _ _ _ -> case Map.lookup structTf structs of
                    Nothing -> (fieldType, LHSDot l' x)
                    Just (structT, m) -> (tf [tr], LHSRange l' NonIndexed r)
                        where
                            (tf, _) = typeRanges structT
                            (r @ (hi, lo), base) = m Map.! x
                            hi' = BinOp Add base $ BinOp Sub hi lo
                            lo' = base
                            tr = (simplify hi', simplify lo')
                Implicit sg _ -> (Implicit sg [], LHSDot l' x)
                _ -> error $ "convertLHS encountered dot for bad type: " ++ show (t, l, x)
            where
                (t, l') = convertLHS l
                Struct p fields [] = t
                structTf = Struct p fields
                fieldType = lookupFieldType fields x
        convertLHS (LHSConcat lhss) =
            (Implicit Unspecified [], LHSConcat $ map (snd . convertLHS) lhss)

        -- try expression conversion by looking at the *outermost* type first
        convertExpr :: Type -> Expr -> Expr
        -- TODO: This is really a conversion for using default patterns to
        -- populate arrays. Maybe this should be somewhere else?
        convertExpr (IntegerVector t sg (r:rs)) (Pattern [(Just "default", e)]) =
            Repeat (rangeSize r) [e']
            where e' = convertExpr (IntegerVector t sg rs) e
        convertExpr (Struct (Packed sg) fields (_:rs)) (Bit e _) =
            convertExpr (Struct (Packed sg) fields rs) e
        convertExpr (Struct (Packed sg) fields rs) (Pattern [(Just "default", e)]) =
            if Map.notMember structTf structs then
                Pattern [(Just "default", e)]
            else if null rs then
                expanded
            else
                Repeat (dimensionsSize rs) [expanded]
            where
                structTf = Struct (Packed sg) fields
                expanded = convertExpr (structTf []) $ Pattern $
                    take (length fields) (repeat (Nothing, e))
        convertExpr (Struct (Packed sg) fields []) (Pattern itemsOrig) =
            if length items /= length fields then
                error $ "struct pattern " ++ show items ++
                    " doesn't have the same # of items as " ++ show structTf
            else if itemsFieldNames /= fieldNames then
                error $ "struct pattern " ++ show items ++ " has fields " ++
                    show itemsFieldNames ++ ", but struct type has fields " ++
                    show fieldNames
            else if Map.notMember structTf structs then
                Pattern items
            else
                Call Nothing fnName $ Args (map (Just . snd) items) []
            where
                subMap = \(Just ident, subExpr) ->
                    (Just ident, convertExpr (lookupFieldType fields ident) subExpr)
                structTf = Struct (Packed sg) fields
                itemsNamed =
                    -- if the pattern does not use identifiers, use the
                    -- identifiers from the struct type definition in order
                    if not (all (isJust . fst) itemsOrig)
                        then zip (map (Just. snd) fields) (map snd itemsOrig)
                        else itemsOrig
                items = sortOn itemPosition $ map subMap itemsNamed
                fieldNames = map snd fields
                itemsFieldNames = map (fromJust . fst) items
                itemPosition = \(Just x, _) -> fromJust $ elemIndex x fieldNames
                fnName = packerFnName structTf
        convertExpr _ other = other

        -- try expression conversion by looking at the *innermost* type first
        convertSubExpr :: Expr -> (Type, Expr)
        convertSubExpr (Ident x) =
            case Map.lookup x types of
                Nothing -> (Implicit Unspecified [], Ident x)
                Just t -> (t, Ident x)
        convertSubExpr (Dot e x) =
            case subExprType of
                Struct _ _ _ ->
                    if Map.notMember structTf structs
                        then (fieldType, Dot e' x)
                        else (fieldType, Range  e' NonIndexed r)
                _ -> (Implicit Unspecified [], Dot e' x)
            where
                (subExprType, e') = convertSubExpr e
                Struct p fields [] = subExprType
                structTf = Struct p fields
                fieldType = lookupFieldType fields x
                r = lookupUnstructRange structTf x
        convertSubExpr (Range eOuter NonIndexed (rOuter @ (hiO, loO))) =
            -- VCS doesn't allow ranges to be cascaded, so we need to combine
            -- nested Ranges into a single range. My understanding of the
            -- semantics are that a range returns a new, zero-indexed sub-range.
            case eOuter' of
                Range eInner NonIndexed (_, loI) ->
                    (t, Range eInner NonIndexed (simplify hi, simplify lo))
                    where
                        lo = BinOp Add loI loO
                        hi = BinOp Add loI hiO
                Range eInner IndexedPlus (baseI, _) ->
                    (t, Range eInner IndexedPlus (simplify base, simplify len))
                    where
                        base = BinOp Add baseI loO
                        len = rangeSize rOuter
                _ -> (t, Range eOuter' NonIndexed rOuter)
            where (t, eOuter') = convertSubExpr eOuter
        convertSubExpr (Range e m r) =
            (t', Range e' m r)
            where
                (t, e') = convertSubExpr e
                t' = case typeRanges t of
                    (_, []) -> Implicit Unspecified []
                    (tf, rs) -> tf $ tail rs
        convertSubExpr (Concat exprs) =
            (Implicit Unspecified [], Concat $ map (snd . convertSubExpr) exprs)
        convertSubExpr (BinOp op e1 e2) =
            (Implicit Unspecified [], BinOp op e1' e2')
            where
                (_, e1') = convertSubExpr e1
                (_, e2') = convertSubExpr e2
        convertSubExpr (Bit e i) =
            case e' of
                Range eInner NonIndexed (_, loI) ->
                    (t', Bit eInner (simplify $ BinOp Add loI i'))
                Range eInner IndexedPlus (baseI, _) ->
                    (t', Bit eInner (simplify $ BinOp Add baseI i'))
                _ -> (t', Bit e' i')
            where
                (t, e') = convertSubExpr e
                t' = case typeRanges t of
                    (_, []) -> Implicit Unspecified []
                    (tf, rs) -> tf $ tail rs
                (_, i') = convertSubExpr i
        convertSubExpr (Call Nothing f args) =
            (retType, uncurry (Call Nothing) $ convertCall structs types f args)
            where
                retType = case Map.lookup f types of
                    Nothing -> Implicit Unspecified []
                    Just t -> t
        -- TODO: There are other expression cases that we probably need to
        -- recurse into. That said, it's not clear to me how much we really
        -- expect to see things like concatenated packed structs, for example.
        convertSubExpr other = (Implicit Unspecified [], other)

        -- lookup the range of a field in its unstructured type
        lookupUnstructRange :: TypeFunc -> Identifier -> Range
        lookupUnstructRange structTf fieldName =
            fieldRangeMap Map.! fieldName
            where fieldRangeMap = Map.map fst $ snd $ structs Map.! structTf

        -- lookup the type of a field in the given field list
        lookupFieldType :: [(Type, Identifier)] -> Identifier -> Type
        lookupFieldType fields fieldName = fieldMap Map.! fieldName
            where fieldMap = Map.fromList $ map swap fields

-- attempts to convert based on the assignment-like contexts of TF arguments
convertCall :: Structs -> Types -> Identifier -> Args -> (Identifier, Args)
convertCall structs types f (Args pnArgs kwArgs) =
    (f, args)
    where
        idxs = map show ([0..] :: [Int])
        args = Args
            (map snd $ map convertArg $ zip idxs pnArgs)
            (map convertArg kwArgs)
        convertArg :: (Identifier, Maybe Expr) -> (Identifier, Maybe Expr)
        convertArg (x, Nothing) = (x, Nothing)
        convertArg (x, Just e ) = (x, Just e')
            where
                (_, e') = convertAsgn structs types
                    (LHSIdent $ f ++ ":" ++ x, e)

