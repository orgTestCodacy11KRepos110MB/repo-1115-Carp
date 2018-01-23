module Deftype (moduleForDeftype, bindingsForRegisteredType) where

import qualified Data.Map as Map
import Data.Maybe
import Debug.Trace

import Obj
import Types
import Util
import Template
import Infer
import Concretize
import Polymorphism
import ArrayTemplates

data AllocationMode = StackAlloc | HeapAlloc

{-# ANN module "HLint: ignore Reduce duplication" #-}
-- | This function creates a "Type Module" with the same name as the type being defined.
--   A type module provides a namespace for all the functions that area automatically
--   generated by a deftype.
moduleForDeftype :: TypeEnv -> Env -> [String] -> String -> [Ty] -> [XObj] -> Maybe Info -> Either String (String, XObj, [XObj])
moduleForDeftype typeEnv env pathStrings typeName typeVariables rest i =
  let typeModuleName = typeName
      emptyTypeModuleEnv = Env (Map.fromList []) (Just env) (Just typeModuleName) [] ExternalEnv
      -- The variable 'insidePath' is the path used for all member functions inside the 'typeModule'.
      -- For example (module Vec2 [x Float]) creates bindings like Vec2.create, Vec2.x, etc.
      insidePath = pathStrings ++ [typeModuleName]
  in case validateMembers typeEnv typeVariables rest of
       Left err ->
         Left err
       Right _ ->
         case
           do let structTy = StructTy typeName typeVariables
              okInit <- templateForInit insidePath structTy rest
              okNew <- templateForNew insidePath structTy rest
              (okStr, strDeps) <- templateForStr typeEnv env insidePath structTy rest
              (okDelete, deleteDeps) <- templateForDelete typeEnv env insidePath structTy rest
              (okCopy, copyDeps) <- templateForCopy typeEnv env insidePath structTy rest
              (okMembers, membersDeps) <- templatesForMembers typeEnv env insidePath structTy rest
              let funcs = okInit : okNew : okStr : okDelete : okCopy : okMembers
                  moduleEnvWithBindings = addListOfBindings emptyTypeModuleEnv funcs
                  typeModuleXObj = XObj (Mod moduleEnvWithBindings) i (Just ModuleTy)
                  deps = deleteDeps ++ membersDeps ++ copyDeps ++ strDeps
              return (typeModuleName, typeModuleXObj, deps)
         of
           Just x -> Right x
           Nothing -> Left "Something's wrong with the templates..." -- TODO: Better messages here, should come from the template functions!

{-# ANN validateMembers "HLint: ignore Eta reduce" #-}
-- | Make sure that the member declarations in a type definition
-- | Follow the pattern [<name> <type>, <name> <type>, ...]
-- | TODO: What a mess this function is, clean it up!
validateMembers :: TypeEnv -> [Ty] -> [XObj] -> Either String ()
validateMembers typeEnv typeVariables rest = mapM_ validateOneCase rest
  where
    validateOneCase :: XObj -> Either String ()
    validateOneCase (XObj (Arr arr) _ _) =
      if length arr `mod` 2 == 0
      then mapM_ (okXObjForType . snd) (pairwise arr)
      else Left "Uneven nr of members / types."
    validateOneCase XObj {} =
      Left "Type members must be defined using array syntax: [member1 type1 member2 type2 ...]"

    okXObjForType :: XObj -> Either String ()
    okXObjForType xobj =
      case xobjToTy xobj of
        Just t -> okMemberType t
        Nothing -> Left ("Can't interpret this as a type: " ++ pretty xobj)

    okMemberType :: Ty -> Either String ()
    okMemberType t = case t of
                       IntTy    -> return ()
                       FloatTy  -> return ()
                       DoubleTy -> return ()
                       LongTy   -> return ()
                       BoolTy   -> return ()
                       StringTy -> return ()
                       CharTy   -> return ()
                       PointerTy inner -> do _ <- okMemberType inner
                                             return ()
                       StructTy "Array" [inner] -> do _ <- okMemberType inner
                                                      return ()
                       StructTy name tyVars ->
                         case lookupInEnv (SymPath [] name) (getTypeEnv typeEnv) of
                           Just _ -> return ()
                           Nothing -> Left ("Can't find '" ++ name ++ "' among registered types.")
                       VarTy _ -> if t `elem` typeVariables
                                  then return ()
                                  else Left ("Invalid type variable as member type: " ++ show t)
                       _ -> Left ("Invalid member type: " ++ show t)

-- | Helper function to create the binder for the 'init' template.
templateForInit :: [String] -> Ty -> [XObj] -> Maybe (String, Binder)
templateForInit insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  Just $ instanceBinder (SymPath insidePath "init")
                        (FuncTy (initArgListTypes membersXObjs) structTy)
                        (templateInit StackAlloc structTy membersXObjs)
templateForInit _ _ _ = Nothing

-- | Helper function to create the binder for the 'new' template.
templateForNew :: [String] -> Ty -> [XObj] -> Maybe (String, Binder)
templateForNew insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  Just $ instanceBinder (SymPath insidePath "new")
                        (FuncTy (initArgListTypes membersXObjs) (PointerTy structTy))
                        (templateInit HeapAlloc structTy membersXObjs)
templateForNew _ _ _ = Nothing

-- | Helper function to create the binder for the 'str' template.
templateForStr :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ((String, Binder), [XObj])
templateForStr typeEnv env insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  Just (instanceBinderWithDeps (SymPath insidePath "str")
                               (FuncTy [RefTy structTy] StringTy)
                               (templateStr typeEnv env structTy (memberXObjsToPairs membersXObjs)))
templateForStr _ _ _ _ _ = Nothing

-- | Generate a list of types from a deftype declaration.
initArgListTypes :: [XObj] -> [Ty]
initArgListTypes xobjs = map (\(_, x) -> fromJust (xobjToTy x)) (pairwise xobjs)

-- | Helper function to create the binder for the 'delete' template.
templateForDelete :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ((String, Binder), [XObj])
templateForDelete typeEnv env insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  Just (instanceBinderWithDeps (SymPath insidePath "delete")
                               (FuncTy [structTy] UnitTy)
                               (templateDelete typeEnv env (memberXObjsToPairs membersXObjs)))
templateForDelete _ _ _ _ _ = Nothing

-- | Helper function to create the binder for the 'copy' template.
templateForCopy :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ((String, Binder), [XObj])
templateForCopy typeEnv env insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  Just (instanceBinderWithDeps (SymPath insidePath "copy")
                               (FuncTy [RefTy structTy] (StructTy typeName []))
                               (templateCopy typeEnv env (memberXObjsToPairs membersXObjs)))
templateForCopy _ _ _ _ _ = Nothing

-- | Get a list of pairs from a deftype declaration.
memberXObjsToPairs :: [XObj] -> [(String, Ty)]
memberXObjsToPairs xobjs = map (\(n, t) -> (mangle (getName n), fromJust (xobjToTy t))) (pairwise xobjs)

-- | Generate all the templates for ALL the member variables in a deftype declaration.
templatesForMembers :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ([(String, Binder)], [XObj])
templatesForMembers typeEnv env insidePath structTy [XObj (Arr membersXobjs) _ _] =
  let bindersAndDeps = concatMap (templatesForSingleMember typeEnv env insidePath structTy) (pairwise membersXobjs)
  in  Just (map fst bindersAndDeps, concatMap snd bindersAndDeps)
templatesForMembers _ _ _ _ _ = error "Can't create member functions for type with more than one case (yet)."

-- | Generate the templates for a single member in a deftype declaration.
templatesForSingleMember :: TypeEnv -> Env -> [String] -> Ty -> (XObj, XObj) -> [((String, Binder), [XObj])]
templatesForSingleMember typeEnv env insidePath structTy@(StructTy typeName _) (nameXObj, typeXObj) =
  let Just t = xobjToTy typeXObj
      p = StructTy typeName []
      memberName = getName nameXObj
      fixedMemberTy = if isManaged typeEnv t then RefTy t else t
  in [instanceBinderWithDeps (SymPath insidePath memberName) (FuncTy [RefTy p] fixedMemberTy) (templateGetter (mangle memberName) fixedMemberTy)
     ,instanceBinderWithDeps (SymPath insidePath ("set-" ++ memberName)) (FuncTy [p, t] p) (templateSetter typeEnv env (mangle memberName) t)
     ,instanceBinderWithDeps (SymPath insidePath ("set-" ++ memberName ++ "!")) (FuncTy [RefTy (p), t] UnitTy) (templateSetterRef typeEnv env (mangle memberName) t)
     ,instanceBinderWithDeps (SymPath insidePath ("update-" ++ memberName))
                                                            (FuncTy [p, FuncTy [t] t] p)
                                                            (templateUpdater (mangle memberName))]

-- | The template for the 'init' and 'new' functions for a deftype.
templateInit :: AllocationMode -> Ty -> [XObj] -> Template
templateInit allocationMode structTy@(StructTy typeName typeVariables) memberXObjs =
  let members = memberXObjsToPairs memberXObjs
  in
  Template
    (FuncTy (map snd members) (VarTy "p"))
    (const (toTemplate $ "$p $NAME(" ++ joinWithComma (map memberArg members) ++ ")"))
    (const (toTemplate $ unlines [ "$DECL {"
                                 , case allocationMode of
                                     StackAlloc -> "    $p instance;"
                                     HeapAlloc ->  "    $p instance = CARP_MALLOC(sizeof(" ++ typeName ++ "));"
                                 , joinWith "\n" (map (memberAssignment allocationMode) members)
                                 , "    return instance;"
                                 , "}"]))
    (\(FuncTy _ t) -> instantiateGenericStructType (unifySignatures structTy t) t memberXObjs)

instantiateGenericType :: Map.Map String Ty -> Ty -> [XObj]
instantiateGenericType mappings arrayTy@(StructTy "Array" _) =
  [defineArrayTypeAlias arrayTy]
instantiateGenericType mappings structTy@(StructTy _ _) =
  let memberXObjs = []
  in instantiateGenericStructType mappings structTy memberXObjs
instantiateGenericType _ _ =
  [] -- ignore all other types

instantiateGenericStructType :: Map.Map String Ty -> Ty -> [XObj] -> [XObj]
instantiateGenericStructType mappings structTy@(StructTy _ _) memberXObjs =
  -- Turn (deftype (A a) [x a, y a]) into (deftype (A Int) [x Int, y Int])
  let concretelyTypedMembers = concatMap (\(v, t) -> [v, replaceGenericTypeSymbols mappings t]) (pairwise memberXObjs)
  in  [ XObj (Lst (XObj (Typ structTy) Nothing Nothing :
                  XObj (Sym (SymPath [] (tyToC structTy)) Symbol) Nothing Nothing :
                   [(XObj (Arr concretelyTypedMembers) Nothing Nothing)])
            ) (Just dummyInfo) (Just TypeTy)
      ]
      ++ concatMap (\(v, tyXObj) -> case (xobjToTy tyXObj) of
                                      Just okTy -> instantiateGenericType mappings okTy
                                      Nothing -> error ("Failed to convert " ++ pretty tyXObj ++ "to a type."))
      (pairwise memberXObjs)

replaceGenericTypeSymbols :: Map.Map String Ty -> XObj -> XObj
replaceGenericTypeSymbols mappings xobj@(XObj (Sym (SymPath pathStrings name) _) i t) =
  case Map.lookup name mappings of
    Just found -> tyToXObj found
    Nothing -> error ("Failed to concretize member '" ++ name ++ "' at " ++ prettyInfoFromXObj xobj)
replaceGenericTypeSymbols _ xobj = xobj

tyToXObj :: Ty -> XObj
tyToXObj (StructTy n vs) = XObj (Lst ((XObj (Sym (SymPath [] n) Symbol) Nothing Nothing) : (map tyToXObj vs))) Nothing Nothing
tyToXObj x = XObj (Sym (SymPath [] (show x)) Symbol) Nothing Nothing



-- | The template for the 'str' function for a deftype.
templateStr :: TypeEnv -> Env -> Ty -> [(String, Ty)] -> Template
templateStr typeEnv env t@(StructTy typeName _) members =
  Template
    (FuncTy [RefTy t] StringTy)
    (\(FuncTy [RefTy structTy] StringTy) -> (toTemplate $ "string $NAME(" ++ tyToC structTy ++ " *p)"))
    (\(FuncTy [RefTy structTy@(StructTy _ concreteMemberTys)] StringTy) ->
       let correctedMembers = correctMemberTys members concreteMemberTys
       in (toTemplate $ unlines [ "$DECL {"
                                , "  // convert members to string here:"
                                , "  string temp = NULL;"
                                , "  int tempsize = 0;"
                                , calculateStructStrSize typeEnv env correctedMembers structTy
                                , "  string buffer = CARP_MALLOC(size);"
                                , "  string bufferPtr = buffer;"
                                , ""
                                , "  snprintf(bufferPtr, size, \"(%s \", \"" ++ tyToC structTy ++ "\");"
                                , "  bufferPtr += strlen(\"" ++ tyToC structTy ++ "\") + 2;\n"
                                , "  // Concrete member tys: " ++ show concreteMemberTys
                                , joinWith "\n" (map (memberStr typeEnv env) correctedMembers)
                                , "  bufferPtr--;"
                                , "  snprintf(bufferPtr, size, \")\");"
                                , "  return buffer;"
                                , "}"]))
    (\(ft@(FuncTy [RefTy structTy@(StructTy _ concreteMemberTys)] StringTy)) ->
       concatMap (depsOfPolymorphicFunction typeEnv env [] "str" . typesStrFunctionType typeEnv)
                 (filter (\t -> (not . isExternalType typeEnv) t && (not . isFullyGenericType) t)
                  (map snd (correctMemberTys members concreteMemberTys)))
       ++
       (if typeIsGeneric structTy then [] else [defineFunctionTypeAlias ft])
    )

correctMemberTys members concreteMemberTys =
  case concreteMemberTys of
    [] -> members -- Not a generic type, leave members as-is.
    _ -> zipWith replaceGenericMemberTy members concreteMemberTys -- Concretization of generic type, use concrete types.

replaceGenericMemberTy :: (String, Ty) -> Ty -> (String, Ty)
replaceGenericMemberTy (memberName, memberTy) concreteTy =
  if areUnifiable memberTy concreteTy
  then (memberName, concreteTy)
  else (memberName, memberTy)

calculateStructStrSize :: TypeEnv -> Env -> [(String, Ty)] -> Ty -> String
calculateStructStrSize typeEnv env members structTy =
  "  int size = snprintf(NULL, 0, \"(%s )\", \"" ++ tyToC structTy ++ "\");\n" ++
    unlines (map memberStrSize members)
  where memberStrSize (memberName, memberTy) =
          let refOrNotRefType = if isManaged typeEnv memberTy then RefTy memberTy else memberTy
              maybeTakeAddress = if isManaged typeEnv memberTy then "&" else ""
              strFuncType = FuncTy [refOrNotRefType] StringTy
           in case nameOfPolymorphicFunction typeEnv env strFuncType "str" of
                Just strFunctionPath ->
                  unlines ["  temp = " ++ pathToC strFunctionPath ++ "(" ++ maybeTakeAddress ++ "p->" ++ memberName ++ ");"
                          , "  size += snprintf(NULL, 0, \"%s \", temp);"
                          , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                          ]
                Nothing ->
                  if isExternalType typeEnv memberTy
                  then unlines [ "  size +=  snprintf(NULL, 0, \"%p \", p->" ++ memberName ++ ");"
                               , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                               ]
                  else "  // Failed to find str function for " ++ memberName ++ " : " ++ show memberTy ++ "\n"


-- | Generate C code for converting a member variable to a string and appending it to a buffer.
memberStr :: TypeEnv -> Env -> (String, Ty) -> String
memberStr typeEnv env (memberName, memberTy) =
  let refOrNotRefType = if isManaged typeEnv memberTy then RefTy memberTy else memberTy
      maybeTakeAddress = if isManaged typeEnv memberTy then "&" else ""
      strFuncType = FuncTy [refOrNotRefType] StringTy
   in case nameOfPolymorphicFunction typeEnv env strFuncType "str" of
        Just strFunctionPath ->
          unlines ["  temp = " ++ pathToC strFunctionPath ++ "(" ++ maybeTakeAddress ++ "p->" ++ memberName ++ ");"
                  , "  snprintf(bufferPtr, size, \"%s \", temp);"
                  , "  bufferPtr += strlen(temp) + 1;"
                  , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                  ]
        Nothing ->
          if isExternalType typeEnv memberTy
          then unlines [ "  tempsize = snprintf(NULL, 0, \"%p\", p->" ++ memberName ++ ");"
                       , "  temp = malloc(tempsize);"
                       , "  snprintf(temp, tempsize, \"%p\", p->" ++ memberName ++ ");"
                       , "  snprintf(bufferPtr, size, \"%s \", temp);"
                       , "  bufferPtr += strlen(temp) + 1;"
                       , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                       ]
          else "  // Failed to find str function for " ++ memberName ++ " : " ++ show memberTy ++ "\n"

-- | Creates the C code for an arg to the init function.
-- | i.e. "(deftype A [x Int])" will generate "int x" which
-- | will be used in the init function like this: "A_init(int x)"
memberArg :: (String, Ty) -> String
memberArg (memberName, memberTy) =
  templitizeTy memberTy ++ " " ++ memberName

-- | Generate C code for assigning to a member variable.
-- | Needs to know if the instance is a pointer or stack variable.
memberAssignment :: AllocationMode -> (String, Ty) -> String
memberAssignment allocationMode (memberName, _) = "    instance" ++ sep ++ memberName ++ " = " ++ memberName ++ ";"
  where sep = case allocationMode of
                StackAlloc -> "."
                HeapAlloc -> "->"

-- | The template for getters of a deftype.
templateGetter :: String -> Ty -> Template
templateGetter member fixedMemberTy =
  let maybeAmpersand = case fixedMemberTy of
                         RefTy _ -> "&"
                         _ -> ""
  in
  Template
    (FuncTy [RefTy (VarTy "p")] (VarTy "t"))
    (const (toTemplate "$t $NAME($(Ref p) p)"))
    (const (toTemplate ("$DECL { return " ++ maybeAmpersand ++ "(p->" ++ member ++ "); }\n")))
    (const [])

-- | The template for setters of a deftype.
templateSetter :: TypeEnv -> Env -> String -> Ty -> Template
templateSetter typeEnv env memberName memberTy =
  let callToDelete = memberDeletion typeEnv env (memberName, memberTy)
  in
  Template
    (FuncTy [VarTy "p", VarTy "t"] (VarTy "p"))
    (const (toTemplate "$p $NAME($p p, $t newValue)"))
    (const (toTemplate (unlines ["$DECL {"
                                ,callToDelete
                                ,"    p." ++ memberName ++ " = newValue;"
                                ,"    return p;"
                                ,"}\n"])))
    (\_ -> if isManaged typeEnv memberTy
           then depsOfPolymorphicFunction typeEnv env [] "delete" (typesDeleterFunctionType memberTy)
           else [])

-- | The template for setters of a deftype.
templateSetterRef :: TypeEnv -> Env -> String -> Ty -> Template
templateSetterRef typeEnv env memberName memberTy =
  Template
    (FuncTy [RefTy (VarTy "p"), VarTy "t"] UnitTy)
    (const (toTemplate "void $NAME($p* pRef, $t newValue)"))
    (const (toTemplate (unlines ["$DECL {"
                                ,"    pRef->" ++ memberName ++ " = newValue;"
                                ,"}\n"])))
    (\_ -> if isManaged typeEnv memberTy
           then depsOfPolymorphicFunction typeEnv env [] "delete" (typesDeleterFunctionType memberTy)
           else [])


-- | The template for updater functions of a deftype
-- | (allows changing a variable by passing an transformation function).
templateUpdater :: String -> Template
templateUpdater member =
  Template
    (FuncTy [VarTy "p", FuncTy [VarTy "t"] (VarTy "t")] (VarTy "p"))
    (const (toTemplate "$p $NAME($p p, $(Fn [t] t) updater)"))
    (const (toTemplate (unlines ["$DECL {"
                                ,"    p." ++ member ++ " = updater(p." ++ member ++ ");"
                                ,"    return p;"
                                ,"}\n"])))
    (\(FuncTy [_, t@(FuncTy [_] fRetTy)] _) ->
       if isFullyGenericType fRetTy
       then []
       else [defineFunctionTypeAlias t])

-- | The template for the 'delete' function of a deftype.
templateDelete :: TypeEnv -> Env -> [(String, Ty)] -> Template
templateDelete typeEnv env members =
  Template
   (FuncTy [VarTy "p"] UnitTy)
   (const (toTemplate "void $NAME($p p)"))
   (const (toTemplate $ unlines [ "$DECL {"
                                , joinWith "\n" (map (memberDeletion typeEnv env) members)
                                , "}"]))
   (\_ -> concatMap (depsOfPolymorphicFunction typeEnv env [] "delete" . typesDeleterFunctionType)
                    (filter (isManaged typeEnv) (map snd members)))

-- | Generate the C code for deleting a single member of the deftype.
-- | TODO: Should return an Either since this can fail!
memberDeletion :: TypeEnv -> Env -> (String, Ty) -> String
memberDeletion typeEnv env (memberName, memberType) =
  case findFunctionForMember typeEnv env "delete" (typesDeleterFunctionType memberType) (memberName, memberType) of
    FunctionFound functionFullName -> "    " ++ functionFullName ++ "(p." ++ memberName ++ ");"
    FunctionNotFound msg -> error msg
    FunctionIgnored -> "    /* Ignore non-managed member '" ++ memberName ++ "' */"

-- | The template for the 'copy' function of a deftype.
templateCopy :: TypeEnv -> Env -> [(String, Ty)] -> Template
templateCopy typeEnv env members =
  Template
   (FuncTy [RefTy (VarTy "p")] (VarTy "p"))
   (const (toTemplate "$p $NAME($p* pRef)"))
   (const (toTemplate $ unlines [ "$DECL {"
                                , "    $p copy = *pRef;"
                                , joinWith "\n" (map (memberCopy typeEnv env) members)
                                , "    return copy;"
                                , "}"]))
   (\_ -> concatMap (depsOfPolymorphicFunction typeEnv env [] "copy" . typesCopyFunctionType)
                    (filter (isManaged typeEnv) (map snd members)))

-- | Generate the C code for copying the member of a deftype.
-- | TODO: Should return an Either since this can fail!
memberCopy :: TypeEnv -> Env -> (String, Ty) -> String
memberCopy typeEnv env (memberName, memberType) =
  case findFunctionForMember typeEnv env "copy" (typesCopyFunctionType memberType) (memberName, memberType) of
    FunctionFound functionFullName ->
      "    copy." ++ memberName ++ " = " ++ functionFullName ++ "(&(pRef->" ++ memberName ++ "));"
    FunctionNotFound msg -> error msg
    FunctionIgnored -> "    /* Ignore non-managed member '" ++ memberName ++ "' */"


-- | Will generate getters/setters/updaters when registering external types
-- | i.e. (register-type VRUnicornData [hp Int, magic Float])
bindingsForRegisteredType :: TypeEnv -> Env -> [String] -> String -> [XObj] -> Maybe Info -> Either String (String, XObj, [XObj])
bindingsForRegisteredType typeEnv env pathStrings typeName rest i =
  let typeModuleName = typeName
      emptyTypeModuleEnv = Env (Map.fromList []) (Just env) (Just typeModuleName) [] ExternalEnv
      insidePath = pathStrings ++ [typeModuleName]
  in case validateMembers typeEnv [] rest of
       Left err -> Left err
       Right _ ->
         case
           do let structTy = StructTy typeName []
              okInit <- templateForInit insidePath structTy rest
              okNew <- templateForNew insidePath structTy rest
              (okStr, strDeps) <- templateForStr typeEnv env insidePath structTy rest
              (binders, deps) <- templatesForMembers typeEnv env insidePath structTy rest
              let moduleEnvWithBindings = addListOfBindings emptyTypeModuleEnv (okInit : okNew : okStr : binders)
                  typeModuleXObj = XObj (Mod moduleEnvWithBindings) i (Just ModuleTy)
              return (typeModuleName, typeModuleXObj, deps ++ strDeps)
         of
           Just ok ->
             Right ok
           Nothing ->
             Left "Something's wrong with the templates..." -- TODO: Better messages here!

-- | If the type is just a type variable; create a template type variable by appending $ in front of it's name
templitizeTy :: Ty -> String
templitizeTy t =
  (if isFullyGenericType t then "$" else "") ++ tyToC t
