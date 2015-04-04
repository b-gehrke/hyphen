{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}

module HyphenGHC (createGHCSession, importLibModules, importSrcModules, accessBasics,
                  TyNSElt) where

--import Debug.Trace
import Control.Arrow
import Control.Applicative hiding ((<|>))
import Control.Monad
import Control.Monad.State.Strict
import Data.IORef
import Data.Monoid
import Data.Maybe
import Data.Either
import Data.List
import Data.Text                      (Text)
import Data.Set                       (Set)
import Data.Map.Strict                (Map)
import qualified Control.Exception
import qualified Data.Text            as T
import qualified Data.Set             as Set
import qualified Data.Map.Strict      as Map
import qualified Data.HashMap.Strict  as HashMap
import qualified Data.Traversable
import qualified Unsafe.Coerce
import qualified GHC
import qualified GHC.Paths
import qualified StaticFlags as GHCStaticFlags
import qualified SysTools    as GHCSysTools
import qualified TyCon       as GHCTyCon
import qualified OccName     as GHCOccName
import qualified Module      as GHCModule
import qualified Type        as GHCType
import qualified DynFlags    as GHCDynFlags
import qualified HscMain     as GHCHscMain
import qualified MonadUtils  as GHCMonadUtils
import qualified Var         as GHCVar
import qualified Outputable  as GHCOutputable
import qualified ErrUtils    as GHCErrUtils
import qualified Exception   as GHCException
import qualified HscTypes    as GHCHscTypes
import qualified GhcMonad

import HyphenBase
import PythonBase
import HyphenKinds
import HyphenTyCon
import HsType
import HsObjRaw
import HyphenExceptions


ourInitGhcMonad :: (GHC.GhcMonad m) => Maybe FilePath -> m ()
ourInitGhcMonad mb_top_dir = do
  -- initGHCMonad, as defined in the GHC API, annoyingly sets several
  -- totally inappropriate signal handlers, which will completely mess
  -- with Python's signal handlers. So we have to have our own
  -- version. This function, alas, must be kept in sync with the GHC
  -- version of which it is mostly a clone
  GHCMonadUtils.liftIO $ GHCStaticFlags.initStaticOpts

  mySettings <- GHCMonadUtils.liftIO $ GHCSysTools.initSysTools mb_top_dir
  dflags <- GHCMonadUtils.liftIO 
            $ GHCDynFlags.initDynFlags (GHCDynFlags.defaultDynFlags mySettings)
  env <- GHCMonadUtils.liftIO $ GHCHscMain.newHscEnv dflags
  GHC.setSession env

performGHCOps  :: (Maybe String) -> GhcMonad.Session -> GhcMonad.Ghc a -> PythonM a
performGHCOps msgHint sess ghcAct = promoteErr =<< (
  translatingHsExcepts . lift $ flip GhcMonad.reflectGhc sess 
  $ reportingGHCErrors msgHint ghcAct)

reportingGHCErrors :: (Maybe String) -> GhcMonad.Ghc a -> GhcMonad.Ghc (Either ErrMsg a)
reportingGHCErrors msgHint action = do
  logref <- GHCMonadUtils.liftIO $ newIORef ""
  dflags <- GhcMonad.getSessionDynFlags
  let prep  = GHC.setSessionDynFlags $ dflags { GHCDynFlags.log_action = logHandler logref }
      clean = GHC.setSessionDynFlags dflags
      handler :: GHCHscTypes.SourceError -> GhcMonad.Ghc a
      handler ex = GHCMonadUtils.liftIO $ do 
        case msgHint of 
          Just h  -> Control.Exception.throwIO . Control.Exception.AssertionFailed $ 
                     h ++ show ex
          Nothing -> Control.Exception.throwIO ex
        
  result <- GHCException.ghandle handler $ do
    GHCException.gbracket prep (const clean) . const $ do
      action
  problems <- GHCMonadUtils.liftIO $ readIORef logref
  
  return $ if (problems == "") then Right result else report $ hintedWith msgHint problems
 where hintedWith :: (Maybe String) -> String -> String
       hintedWith Nothing  s = s  
       hintedWith (Just h) s = concat [s, "\n(while trying to ", h, ")"]

       logHandler :: IORef String -> GHCDynFlags.LogAction
       logHandler ref dflags severity srcSpan style msg =
           case severity of
             GHCErrUtils.SevError ->  modifyIORef' ref (++ printDoc)
             GHCErrUtils.SevFatal ->  modifyIORef' ref (++ printDoc)
             _                    ->  return () -- ignore the rest
         where cntx = GHCOutputable.initSDocContext dflags style
               locMsg = GHCErrUtils.mkLocMessage severity srcSpan msg
               printDoc = show (GHCOutputable.runSDoc locMsg cntx)

createGHCSession :: PythonM GhcMonad.Session
createGHCSession = do
  ref <- lift $ newIORef (error "Empty session")
  let session = GhcMonad.Session ref
  translatingHsExcepts . lift . flip GhcMonad.reflectGhc session $
    ourInitGhcMonad (Just GHC.Paths.libdir)
  performGHCOps Nothing session (
    ensureModulesInContext $ Set.fromList [T.pack "Prelude"])
  return session

unpackGHCKind :: GHC.Kind -> Maybe Kind
unpackGHCKind k 
  | GHCType.isFunTy k   = do (Kind ks') <- unpackGHCKind $ GHCType.funResultTy k
                             (Kind . (: ks')) <$> unpackGHCKind (GHCType.funArgTy k)
  | otherwise           = do (kcon, _) <- GHCType.splitTyConApp_maybe k
                             guard (kcon == GHCType.liftedTypeKindTyCon) >> (Just $ Kind [])

type PreObj    = (Text, HsType)
type TyNSElt   = Either TyCon HsType
data PreTycLoc = PreTycLoc Text Bool [Int]

finalizePreTycLoc :: Int -> PreTycLoc -> Maybe TyCLocation
finalizePreTycLoc i (PreTycLoc n ivt locs) 
  | n /= T.pack "" = Just $ ImplicitlyVia n ivt (reverse $ i:locs)
  | otherwise      = Nothing

transformGHCTyc :: Maybe TyCLocation -> GHC.TyCon -> Maybe TyCon
transformGHCTyc loc tyc = do
  let ghcName = GHC.getName tyc
      modl    = GHC.nameModule ghcName
      pckg    = T.pack . GHCModule.packageIdString $ GHC.modulePackageId modl
      mname   = T.pack . GHC.moduleNameString $ GHC.moduleName modl
      oname   = T.pack . GHCOccName.occNameString $ GHC.getOccName ghcName
      loc'    = fromMaybe (InExplicitModuleNamed mname) loc
  kind <- unpackGHCKind $ GHCTyCon.tyConKind tyc
  return $ mkTyCon pckg mname oname loc' kind (GHC.isClassTyCon tyc)

transformGHCTyNSElt :: Text -> GHC.TyCon -> Maybe (Text, TyNSElt)
transformGHCTyNSElt import_module tyc = let
  ghcName      = GHC.getName tyc
  oname        = T.pack . GHCOccName.occNameString $ GHC.getOccName ghcName
  fullname     = T.concat [import_module, T.pack ".", oname]
  args         = [ Var . (T.append $ T.pack "arg_") . T.pack . show $ i
                 | i <- [1..GHCTyCon.tyConArity tyc]] :: [Var]
  in case GHCTyCon.tcExpandTyCon_maybe tyc args of
    Nothing -> do
      tyc' <- transformGHCTyc (Just $ InExplicitModuleNamed import_module) tyc
      return (oname, Left tyc')
    Just (assigs, expansion, leftoverVars) -> case leftoverVars of
      (_:_) -> error "transformGHCTyNSElt: unexpected leftover vars"
      []    -> do let doAssig (tyv, var) = do (tyv', k) <- transformGHCTyVar tyv
                                              return (tyv', mkHsType (Right (var, k)) [])
                  assigs'      <- mapM doAssig assigs
                  let substMap  = Map.fromList assigs'
                  hst          <- transformGHCType fullname True expansion
                  return (oname, Right $ transformType substMap hst)

transformGHCType :: Text -> Bool -> GHC.Type -> Maybe HsType
transformGHCType n ivt = transformGHCType' (PreTycLoc n ivt []). GHCType.expandTypeSynonyms

transformGHCTypes :: PreTycLoc -> [GHC.Type] -> Maybe [HsType]
transformGHCTypes (PreTycLoc mn on sf) tys = let
  subLocs = map ((PreTycLoc mn on) . (:sf)) [0..]
  in sequence . reverse $ zipWith transformGHCType' subLocs (reverse tys)

transformGHCType' :: PreTycLoc -> GHC.Type -> Maybe HsType
transformGHCType' locSoFar typ 
  = let (vars,   rest)  = GHC.splitForAllTys typ
    in case splitConstraint rest of
      (Just c, rest') -> transformGHCType' locSoFar rest'
      (Nothing, _)    -> case GHCType.splitTyConApp_maybe rest of
        Just (tyc, args) -> do 
          unpackGHCKind $ GHCType.typeKind rest -- check result type is of a kind we support 
                                                -- (lifted, etc.)
          args' <- transformGHCTypes locSoFar args
          tyc'  <- transformGHCTyc (finalizePreTycLoc (length args) locSoFar) tyc
          return $ mkHsType (Left tyc') args'
        Nothing          -> 
          let (head, args) = GHCType.splitAppTys rest in case GHCType.getTyVar_maybe head of
            Just tyv        -> do
              tyv'  <- transformGHCTyVar tyv
              args' <- transformGHCTypes locSoFar args
              return $ mkHsType (Right tyv') args'
            Nothing         -> Nothing


transformGHCTyVar :: GHC.TyVar -> Maybe (Var, Kind) 
transformGHCTyVar tyv = do
  k     <- unpackGHCKind $ GHCVar.tyVarKind tyv
  let n  = Var . T.pack . GHCOccName.occNameString . GHC.getOccName $ GHCVar.tyVarName tyv
  return (n, k)
              
splitConstraint :: GHC.Type -> (Maybe GHC.Type, GHC.Type)
splitConstraint ty = case GHCType.splitFunTy_maybe ty of
  Nothing          -> (Nothing, ty)
  Just (src, dest) -> case GHCType.splitTyConApp_maybe (GHCType.typeKind src) of
    Nothing -> (Nothing, ty)
    Just (tyc, _) -> if tyc == GHCType.constraintKindTyCon
                     then (Just src, dest) else (Nothing, ty)

createObj :: GhcMonad.Session -> PreObj -> PythonM Obj
createObj sess (code, orig_type) = do
  memoTable <- lift $ newIORef HashMap.empty
  let core :: HsType -> PythonM Obj
      core hst = do
        curMemoTable <- lift $ readIORef memoTable
        hobj <- case HashMap.lookup hst curMemoTable of
          Just found -> return found
          Nothing    -> do
            let to_eval = T.unpack . T.concat $ [
                  T.pack "(", makeTypeForcer hst, T.pack " (", code, T.pack "))"]
            made <- performGHCOps (Just $ "evaluate " ++ to_eval) sess (
              GHC.compileExpr to_eval)
            lift . atomicModifyIORef memoTable $ \oldTable ->
              (HashMap.insert hst made oldTable, ())
            return made
        return $ MonoObj hst (Unsafe.Coerce.unsafeCoerce hobj)
  tryMakeMonomorphic $ PolyObj orig_type orig_type (PolyObjCore core) []

transformGHCId :: Text -> GHC.Id -> Maybe (Text, PreObj)
transformGHCId import_module i = do
  let ghcName = GHC.getName i
      oname   = T.pack . GHCOccName.occNameString $ GHC.getOccName ghcName
      fullN   = T.concat [import_module, T.pack ".", oname]
  hst <- transformGHCType fullN False $ GHC.idType i
  return (oname, (fullN, hst))

dataConSpecials :: Map Text (Text, Text)
dataConSpecials = Map.fromList $ map (T.pack *** (T.pack *** T.pack)) $ [
  ("GHC.Tuple.()"                ,("()",                "(:[])")),
  ("GHC.Tuple.(,)"               ,("(,)",               "(:[])")),
  ("GHC.Tuple.(,,)"              ,("(,,)",              "(:[])")),
  ("GHC.Tuple.(,,,)"             ,("(,,,)",             "(:[])")),
  ("GHC.Tuple.(,,,,)"            ,("(,,,,)",            "(:[])")),
  ("GHC.Tuple.(,,,,,)"           ,("(,,,,,)",           "(:[])")),
  ("GHC.Tuple.(,,,,,,)"          ,("(,,,,,,)",          "(:[])")),
  ("GHC.Tuple.(,,,,,,,)"         ,("(,,,,,,,)",         "(:[])")),
  ("GHC.Tuple.(,,,,,,,,)"        ,("(,,,,,,,,)",        "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,)"       ,("(,,,,,,,,,)",       "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,,)"      ,("(,,,,,,,,,,)",      "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,,,)"     ,("(,,,,,,,,,,,)",     "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,,,,)"    ,("(,,,,,,,,,,,,)",    "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,,,,,)"   ,("(,,,,,,,,,,,,,)",   "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,,,,,,)"  ,("(,,,,,,,,,,,,,,)",  "(:[])")),
  ("GHC.Tuple.(,,,,,,,,,,,,,,,)" ,("(,,,,,,,,,,,,,,,)", "(:[])"))
  ]

transformGHCDataCon :: Text -> GHC.DataCon -> [] (Text, PreObj)
transformGHCDataCon import_module dc = fromMaybe [] $ do
  let ghcName = GHC.getName dc
      oname   = T.pack . GHCOccName.occNameString $ GHC.getOccName ghcName
      fullnam = T.concat [import_module, T.pack ".", oname]
  dctyp       <- transformGHCType fullnam False $ GHC.dataConType dc
  let (types, resultType) = breakFnTypeRec dctyp
      ntypes  = length types
      ntypes' = min 50 ntypes
      tupTyp  = if ntypes == 1 then head types 
                else mkHsType (Left . tupleTyCon $ ntypes') (take ntypes' types)
      codctyp = mkHsType (Left fnTyCon) [
        resultType, mkHsType (Left listTyCon) [tupTyp]]
      vars    = [T.pack ("a" ++ show i) | i <- [0..ntypes-1]]
      commaVars = T.intercalate (T.pack ", ") $ take ntypes' vars
      spaceVars = T.unwords vars
  return $ case Map.lookup fullnam dataConSpecials of 
    Nothing -> [
      (oname, (fullnam, dctyp)), 
      (T.concat [T.pack "*co-", oname], (T.concat [
         T.pack "(\\ x -> [(", commaVars, T.pack ") | ", fullnam, T.pack " ", spaceVars, 
         T.pack " <- [x]])"] , codctyp))]
    Just (code, cocode) -> [(oname, (code, dctyp)), 
                            (T.concat [T.pack "*co-", oname], (cocode, codctyp))]

transformGHCTyThing :: Text -> GHC.TyThing -> ([(Text, PreObj)], [(Text, TyNSElt)])
transformGHCTyThing im (GHCType.AnId     id) = (maybeToList $ transformGHCId      im id, [])
transformGHCTyThing im (GHCType.ADataCon dc) = (transformGHCDataCon im dc,               [])
transformGHCTyThing im (GHCType.ATyCon   tc) = ([], maybeToList (transformGHCTyNSElt im tc))
transformGHCTyThing _  _                     = ([],                                      [])

makePreModule :: Text -> [GHC.TyThing] -> (Map Text PreObj, Map Text TyNSElt)
makePreModule im tyths = let
  (objs, tynselts) = mconcat (map (transformGHCTyThing im) tyths)
  in (Map.fromList objs, Map.fromList tynselts)

createModule :: GhcMonad.Session -> (Map Text PreObj, Map Text TyNSElt) -> 
              PythonM (Map Text Obj, Map Text TyNSElt)
createModule sess (preobjs, tynselts) = do
  objs <- Data.Traversable.mapM (createObj sess) preobjs
  return (objs, tynselts)

readGHCModule :: Text -> GhcMonad.Ghc [GHC.TyThing]
readGHCModule name = do
  mod        <- GHC.findModule (GHC.mkModuleName $ T.unpack name) Nothing
  mi         <- GHC.getModuleInfo mod
  infos      <- mapM GHC.getInfo $ maybe [] GHC.modInfoExports mi
  return [a |  Just (a, _, _) <- infos]

readGHCModuleTycCanon :: Text -> GhcMonad.Ghc (Map TyCon TyCon, Maybe Text)
readGHCModuleTycCanon mname = GHCException.ghandle handler $ do
  result <- reportingGHCErrors Nothing $ do
    tyths      <- readGHCModule mname
    let nselts  = mapMaybe (transformGHCTyNSElt mname) [tc | GHCType.ATyCon tc <- tyths]
        tycons  = lefts $ map snd nselts
    return . Map.fromList $ zip tycons tycons
  return $ case result of
    Left errmsg  -> (Map.empty, Nothing)
    Right answer -> (answer,    Just mname)
  where handler :: (Monad m) => Control.Exception.SomeException -> m (
          Map TyCon TyCon, Maybe Text)
        handler _ = return (Map.empty, Nothing)

----

modAncestry :: Text -> [Text]
modAncestry = map (T.intercalate dot) . drop 1 . inits . T.splitOn dot
  where dot       = T.singleton '.'

tyConOtherModsOfInterest :: TyCon -> Set Text
tyConOtherModsOfInterest tyc = Set.fromList . modAncestry . tyConModule $ tyc

hsTypeOtherModsOfInterest :: HsType -> Set Text
hsTypeOtherModsOfInterest hst = let
  headPart = either tyConOtherModsOfInterest (const Set.empty) (typeHead hst)
  in mconcat (headPart : map hsTypeOtherModsOfInterest (typeTail hst))

preModuleOtherModsOfInterest :: (Map Text PreObj, Map Text TyNSElt) -> Set Text
preModuleOtherModsOfInterest (preobjs, tynselts) 
  = mconcat . map hsTypeOtherModsOfInterest $ (
    (map snd $ Map.elems preobjs) ++ (rights $ Map.elems tynselts))

----

canonicalizePreModuleTycs :: Map TyCon TyCon -> (Map Text PreObj, Map Text TyNSElt)
                             -> (Map Text PreObj, Map Text TyNSElt)
canonicalizePreModuleTycs canonMap (preobjs, tynselts)
  = let canonicalizePreObj (code, hst) = (code, canonicalizeHsType hst)
        canonicalizeTyNSElt = either Left (Right . canonicalizeHsType)
        
        canonicalizeHsType :: HsType -> HsType
        canonicalizeHsType (HsType _ (Left tyc) tail _ _ _)
         = mkHsType (Left $ canonicalizeTyc tyc) (map canonicalizeHsType tail)
        canonicalizeHsType (HsType _ (Right vk) tail _ _ _)
         = mkHsType (Right vk)                   (map canonicalizeHsType tail)
        canonicalizeTyc tyc = Map.findWithDefault tyc tyc canonMap
    in (Map.map canonicalizePreObj preobjs, Map.map canonicalizeTyNSElt tynselts)

----

ensureModulesInContext :: Set Text -> GhcMonad.Ghc ()
ensureModulesInContext toEnsure = do
  curiis <- GHC.getContext
  let curImps = Set.fromList [
        T.pack . GHC.moduleNameString . GHC.unLoc $ GHC.ideclName decl
        | GHC.IIDecl decl <- curiis]
      newImps  = toEnsure `Set.difference` curImps
  GHC.setContext $ [
    (GHC.IIDecl $ (GHC.simpleImportDecl . GHC.mkModuleName . T.unpack $ modName)  {
        GHC.ideclQualified = True})
    | modName <- Set.toList newImps] ++ curiis 

mkTupStr :: Int -> Int -> String
mkTupStr low high = "(" ++ intercalate "," (map (('x':) . show) [low..high]) ++ ")"

basicsByName = (
  [("[]", "[]"), ("()", "()"), ("(:)", "(:)")] ++ 
  [(a,a) | a <- ["(" ++ replicate n ',' ++ ")" | n<-[1..15]]] ++
  [("tup" ++ show n ++ "head", "\\ " ++ mkTupStr 1 n ++ " -> x1") | n<-[2..15]] ++
  [("tup" ++ show n ++ "tail", "\\ " ++ mkTupStr 1 n ++ " -> " ++ mkTupStr 2 n)
  | n<-[2..15]])

accessBasics :: GhcMonad.Session -> PythonM (Map Text Obj)
accessBasics sess = do
  let evalToPreObj :: (String, String) -> GhcMonad.Ghc (Maybe (Text, PreObj))
      evalToPreObj (name, expr) = do
        exprTy <- GHC.exprType expr
        return $ do
          hst <- transformGHCType (T.pack "") False exprTy
          return (T.pack name, (T.pack expr, hst))
  preobjs <- performGHCOps (Just "access primitive operations") sess $ do
    maybePreobjs <- mapM evalToPreObj basicsByName
    return . Map.fromList . catMaybes $ maybePreobjs
  Data.Traversable.mapM (createObj sess) preobjs

importLibModules :: GhcMonad.Session -> [Text] -> PythonM (
  Map Text (Map Text Obj, Map Text TyNSElt))
importLibModules sess names = do
  preModules <- performGHCOps Nothing sess $ do
    modContents        <- mapM readGHCModule names
    let preModules0     = zipWith makePreModule names modContents
        additionalMods  = mconcat (map preModuleOtherModsOfInterest preModules0)
    (canonMaps, okMds) <- unzip <$> mapM readGHCModuleTycCanon (Set.toList additionalMods)
    ensureModulesInContext (Set.fromList $ names ++ catMaybes okMds)
    let canonMap0       = foldr (Map.unionWith pickBestTyc) Map.empty canonMaps
        canonMap        = Map.insert listTyCon listTyCon canonMap0
    return $ fmap (canonicalizePreModuleTycs canonMap) preModules0
  modules     <- mapM (createModule sess) preModules
  return . Map.fromList $ zip names modules

importSrcModules :: GhcMonad.Session -> [Text] -> PythonM (
  Map Text (Map Text Obj, Map Text TyNSElt))
importSrcModules names = tbd{-do
  logref <- liftIO $ newIORef ""
  dflags <- getSessionDynFlags
  setSessionDynFlags $ dflags { hscTarget = HscInterpreted
                              , ghcLink   = LinkInMemory
                              , log_action = logHandler logref
                              }
  defaultCleanupHandler dflags $ do
    setTargets =<< sequence [guessTarget "test.hs" Nothing]
    load LoadAllTargets
    -- Bringing the module into the context
    setContext [IIModule $ mkModuleName "Test"]
    GHC.setContext [ 
      GHC.IIDecl $ (
         (GHC.simpleImportDecl . GHC.mkModuleName $ name) {GHC.ideclQualified = True}) 
      | name <- names]
    
    mapM GHC.getInfo =<< GHC.getNamesInScope
    
    GHC.compileExpr "Prelude.filter"
    
 where logHandler :: IORef String -> LogAction
       logHandler ref dflags severity srcSpan style msg =
           case severity of
             SevError ->  modifyIORef' ref (++ printDoc)
             SevFatal ->  modifyIORef' ref (++ printDoc)
             _        ->  return () -- ignore the rest
         where cntx = initSDocContext dflags style
               locMsg = mkLocMessage severity srcSpan msg
               printDoc = show (runSDoc locMsg cntx)
       onlyTycs :: [Maybe (TyThing, Fixity, [ClsInst])] -> [TyCon]
       onlyTycs infos = [ t | Just (ATyCon t, _, _) <- infos]

       onlyIDs :: [Maybe (TyThing, Fixity, [ClsInst])] -> [Id]
       onlyIDs infos = [ i | Just (AnId i, _, _) <- infos ]

       onlyDaCons :: [Maybe (TyThing, Fixity, [ClsInst])] -> [DataCon]
       onlyDaCons infos = [ i | Just (ADataCon i, _, _) <- infos ]-}

