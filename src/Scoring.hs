module Scoring (scoreTypeBinder, scoreValueBinder) where

import Data.Maybe (fromJust)
import Env as E
import Obj
import qualified Set
import Types
import TypesToC

-- | Scoring of types.
-- | The score is used for sorting the bindings before emitting them.
-- | A lower score means appearing earlier in the emitted file.
scoreTypeBinder :: TypeEnv -> Env -> Binder -> (Int, Binder)
scoreTypeBinder typeEnv env b@(Binder _ (XObj (Lst (XObj x _ _ : XObj (Sym _ _) _ _ : _)) _ _)) =
  case x of
    Defalias aliasedType ->
      let selfName = ""
       in -- we add 1 here because deftypes generate aliases that
          -- will at least have the same score as the type, but
          -- need to come after. The increment represents this dependency
          (depthOfType typeEnv Set.empty selfName aliasedType + 1, b)
    Deftype s -> depthOfStruct s
    DefSumtype s -> depthOfStruct s
    ExternalType _ -> (0, b)
    _ -> (500, b)
  where
    depthOfStruct (StructTy (ConcreteNameTy path@(SymPath _ name)) varTys) =
      case E.getTypeBinder typeEnv name <> findTypeBinder env path of
        Right (Binder _ typedef) -> (depthOfDeftype typeEnv Set.empty typedef varTys + 1, b)
        -- TODO: This function should return (Either ScoringError (Int,
        -- Binder)) instead of calling error.
        Left e -> error (show e)
    depthOfStruct _ = error "depthofstruct"
scoreTypeBinder _ _ b@(Binder _ (XObj (Mod _ _) _ _)) =
  (1000, b)
scoreTypeBinder _ _ x = error ("Can't score: " ++ show x)

depthOfDeftype :: TypeEnv -> Set.Set Ty -> XObj -> [Ty] -> Int
depthOfDeftype typeEnv visited (XObj (Lst (_ : XObj (Sym (SymPath path selfName) _) _ _ : rest)) _ _) varTys =
  case concatMap expandCase rest of
    [] -> 100
    xs -> maximum xs
  where
    depthsFromVarTys = map (depthOfType typeEnv visited (concat (path ++ [selfName]))) varTys
    expandCase :: XObj -> [Int]
    expandCase (XObj (Arr arr) _ _) =
      let members = memberXObjsToPairs arr
          depthsFromMembers = map (depthOfType typeEnv visited (concat (path ++ [selfName])) . snd) members
       in depthsFromMembers ++ depthsFromVarTys
    expandCase (XObj (Lst [XObj {}, XObj (Arr sumtypeCaseTys) _ _]) _ _) =
      let depthsFromCaseTys = map (depthOfType typeEnv visited (concat (path ++ [selfName])) . fromJust . xobjToTy) sumtypeCaseTys
       in depthsFromCaseTys ++ depthsFromVarTys
    expandCase (XObj (Sym _ _) _ _) =
      []
    expandCase _ = error "Malformed case in typedef."
depthOfDeftype _ _ xobj _ =
  error ("Can't get dependency depth from " ++ show xobj)

depthOfType :: TypeEnv -> Set.Set Ty -> String -> Ty -> Int
depthOfType typeEnv visited selfName theType =
  if theType `elem` visited
    then 0
    else visitType theType + 1
  where
    visitType :: Ty -> Int
    visitType t@(StructTy _ varTys) = depthOfStructType t varTys
    visitType (FuncTy argTys retTy ltTy) =
      -- trace ("Depth of args of " ++ show argTys ++ ": " ++ show (map (visitType . Just) argTys))
      --
      -- The `+ 1` in the function clause below is an important band-aid.
      -- Here's the issue:
      --   When we resolve declarations, some types may reference other types
      --   that have not been scored yet. When that happens, we add 500 to the
      --   binder to ensure it appears later than the types we'll resolve later
      --   on.
      --
      --   However, this means that function types can be tied w/ such binders
      --   when this case holds since they only took the maximum of their type
      --   members. e.g. both a struct and its functions might be
      --   scored "504" and we might incorrectly emit the functions before the
      --   struct.
      --
      --   Since functions are *always* dependent on the types in their
      --   signature, add 1 to ensure they appear after those types in all
      --   possible scenarios.
      --
      --   TODO: Should we find a more robust solution that explicitly
      --   accounts for unresolved types and scores based on these rather than
      --   relying on our hardcoded adjustments being correct?
      maximum (visitType ltTy : visitType retTy : fmap visitType argTys) + 1
    visitType (PointerTy p) = visitType p
    visitType (RefTy r lt) = max (visitType r) (visitType lt)
    visitType _ = 1
    depthOfStructType :: Ty -> [Ty] -> Int
    depthOfStructType struct varTys =
      1
        + case getStructName struct of
          "Array" -> depthOfVarTys
          _
            | tyToC struct == selfName -> 1
            | otherwise ->
              case E.getTypeBinder typeEnv s of
                Right (Binder _ typedef) -> depthOfDeftype typeEnv (Set.insert theType visited) typedef varTys
                Left _ ->
                  --trace ("Unknown type: " ++ name) $
                  -- Two problems here:
                  --
                  -- 1. generic types don't generate their definition in time
                  -- so we get nothing for those. Instead, let's try the type
                  -- vars.
                  -- 2. If a type wasn't found type may also refer to a type defined in another
                  -- module that's not yet been scored. To be safe, add 500
                  500 + depthOfVarTys
      where
        s = getNameFromStructName (getStructName struct)
        depthOfVarTys =
          case fmap (depthOfType typeEnv visited (getStructName struct)) varTys of
            [] -> 1
            xs -> maximum xs + 1

-- | Scoring of value bindings ('def' and 'defn')
-- | The score is used for sorting the bindings before emitting them.
-- | A lower score means appearing earlier in the emitted file.
scoreValueBinder :: Env -> Set.Set SymPath -> Binder -> (Int, Binder)
scoreValueBinder _ _ binder@(Binder _ (XObj (Lst (XObj (External _) _ _ : _)) _ _)) =
  (0, binder)
scoreValueBinder globalEnv visited binder@(Binder _ (XObj (Lst [XObj Def _ _, XObj (Sym _ Symbol) _ _, body]) _ _)) =
  (scoreBody globalEnv visited body, binder)
scoreValueBinder globalEnv visited binder@(Binder _ (XObj (Lst [XObj (Defn _) _ _, XObj (Sym _ Symbol) _ _, _, body]) _ _)) =
  (scoreBody globalEnv visited body, binder)
scoreValueBinder _ _ binder =
  (0, binder)

scoreBody :: Env -> Set.Set SymPath -> XObj -> Int
scoreBody globalEnv visited = visit
  where
    visit xobj =
      case xobjObj xobj of
        (Lst _) ->
          visitList xobj
        (Arr _) ->
          visitArray xobj
        (Sym path (LookupGlobal _ _)) ->
          if Set.member path visited
            then 0
            else case E.searchValueBinder globalEnv path of
              Right foundBinder ->
                let (score, _) = scoreValueBinder globalEnv (Set.insert path visited) foundBinder
                 in score + 1
              Left e ->
                error (show e)
        _ -> 0
    visitList (XObj (Lst []) _ _) =
      0
    visitList (XObj (Lst xobjs) _ _) =
      maximum (fmap visit xobjs)
    visitList _ = error "visitlist"
    visitArray (XObj (Arr []) _ _) =
      0
    visitArray (XObj (Arr xobjs) _ _) =
      maximum (fmap visit xobjs)
    visitArray _ = error "visitarray"
