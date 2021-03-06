{-# LANGUAGE TemplateHaskell, ForeignFunctionInterface, InterruptibleFFI #-}
{-# LANGUAGE ViewPatterns, PatternSynonyms #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  NgxExport
-- Copyright   :  (c) Alexey Radkov 2016-2017
-- License     :  BSD-style
--
-- Maintainer  :  alexey.radkov@gmail.com
-- Stability   :  experimental
-- Portability :  non-portable (requires POSIX)
--
-- Export regular haskell functions for using in directives of
-- <http://github.com/lyokha/nginx-haskell-module nginx-haskell-module>.
--
-----------------------------------------------------------------------------

module NgxExport (
    -- * Exporters
                  ngxExportSS
                 ,ngxExportSSS
                 ,ngxExportSLS
                 ,ngxExportBS
                 ,ngxExportBSS
                 ,ngxExportBLS
                 ,ngxExportYY
                 ,ngxExportBY
                 ,ngxExportIOYY
                 ,ngxExportAsyncIOYY
                 ,ngxExportAsyncOnReqBody
                 ,ngxExportServiceIOYY
                 ,ngxExportHandler
                 ,ngxExportDefHandler
                 ,ngxExportUnsafeHandler
    -- * Re-exported data constructors from /"Foreign.C"/
    --   (for marshalling in foreign calls)
                 ,Foreign.C.CInt (..)
                 ,Foreign.C.CUInt (..)) where

import           Language.Haskell.TH
import           Foreign.C
import           Foreign.Ptr
import           Foreign.StablePtr
import           Foreign.Storable
import           Foreign.Marshal.Alloc
import           Foreign.Marshal.Utils
import           System.IO.Error
import           System.Posix.IO
import           System.Posix.Types
import           System.Posix.Internals
import           Control.Monad
import           Control.Monad.Loops
import qualified Control.Exception as E
import           Control.Exception hiding (Handler)
import           GHC.IO.Exception (ioe_errno)
import           GHC.IO.Device (SeekMode (..))
import           Control.Concurrent.Async
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as C8L
import           Data.Binary.Put
import           Paths_ngx_export (version)
import           Data.Version

#if MIN_VERSION_template_haskell(2,11,0)
#define EXTRA_WILDCARD_BEFORE_CON _
#else
#define EXTRA_WILDCARD_BEFORE_CON
#endif

#if MIN_TOOL_VERSION_ghc(8,0,1)
pattern I :: (Num i, Integral a) => i -> a
#endif
pattern I i <- (fromIntegral -> i)
#if MIN_TOOL_VERSION_ghc(8,2,1)
{-# COMPLETE I :: CInt #-}
#endif

#if MIN_TOOL_VERSION_ghc(8,0,1)
pattern PtrLen :: Num l => Ptr s -> l -> (Ptr s, Int)
#endif
pattern PtrLen s l <- (s, I l)

#if MIN_TOOL_VERSION_ghc(8,0,1)
pattern ToBool :: (Num i, Eq i) => Bool -> i
#endif
pattern ToBool i <- (toBool -> i)
#if MIN_TOOL_VERSION_ghc(8,2,1)
{-# COMPLETE ToBool :: CUInt #-}
#endif

data NgxExport = SS            (String -> String)
               | SSS           (String -> String -> String)
               | SLS           ([String] -> String)
               | BS            (String -> Bool)
               | BSS           (String -> String -> Bool)
               | BLS           ([String] -> Bool)
               | YY            (B.ByteString -> L.ByteString)
               | BY            (B.ByteString -> Bool)
               | IOYY          (B.ByteString -> Bool -> IO L.ByteString)
               | IOYYY         (L.ByteString -> B.ByteString -> IO L.ByteString)
               | Handler       (B.ByteString -> (L.ByteString, String, Int))
               | UnsafeHandler (B.ByteString ->
                                    (B.ByteString, B.ByteString, Int))

let name = mkName "exportType" in do
    TyConI (DataD _ _ _ EXTRA_WILDCARD_BEFORE_CON cs _) <- reify ''NgxExport
    let cons = map (\(NormalC con [(_, typ)]) -> (con, typ)) cs
    sequence $
        [sigD name [t|NgxExport -> IO CInt|],
         funD name $
             map (\(fst -> c, i) ->
                    clause [conP c [wildP]] (normalB [|return i|]) [])
                 (zip cons [1 ..] :: [((Name, Type), Int)])
        ] ++ map (\(c, t) -> tySynD (mkName $ nameBase c) [] $ return t) cons

ngxExport' :: (Name -> Q Exp) -> Name -> Name -> Q Type -> Name -> Q [Dec]
ngxExport' m e h t f = sequence
    [sigD nameFt typeFt,
     funD nameFt $ body [|exportType $cefVar|],
     ForeignD . ExportF CCall ftName nameFt <$> typeFt,
     sigD nameF t,
     funD nameF $ body [|$hVar $efVar|],
     ForeignD . ExportF CCall fName nameF <$> t
    ]
    where hVar   = varE h
          efVar  = m f
          cefVar = conE e `appE` efVar
          fName  = "ngx_hs_" ++ nameBase f
          nameF  = mkName fName
          ftName = "type_" ++ fName
          nameFt = mkName ftName
          typeFt = [t|IO CInt|]
          body b = [clause [] (normalB b) []]

ngxExport :: Name -> Name -> Q Type -> Name -> Q [Dec]
ngxExport = ngxExport' varE

ngxExportC :: Name -> Name -> Q Type -> Name -> Q [Dec]
ngxExportC = ngxExport' $ infixE (Just $ varE 'const) (varE '(.)) . Just . varE

-- | Exports a function of type
-- /'String' -> 'String'/
-- for using in directive /haskell_run/.
ngxExportSS :: Name -> Q [Dec]
ngxExportSS =
    ngxExport 'SS 'sS
    [t|CString -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /'String' -> 'String' -> 'String'/
-- for using in directive /haskell_run/.
ngxExportSSS :: Name -> Q [Dec]
ngxExportSSS =
    ngxExport 'SSS 'sSS
    [t|CString -> CInt -> CString -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /['String'] -> 'String'/
-- for using in directive /haskell_run/.
ngxExportSLS :: Name -> Q [Dec]
ngxExportSLS =
    ngxExport 'SLS 'sLS
    [t|Ptr NgxStrType -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /'String' -> 'Bool'/
-- for using in directive /haskell_run/.
ngxExportBS :: Name -> Q [Dec]
ngxExportBS =
    ngxExport 'BS 'bS
    [t|CString -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /'String' -> 'String' -> 'Bool'/
-- for using in directive /haskell_run/.
ngxExportBSS :: Name -> Q [Dec]
ngxExportBSS =
    ngxExport 'BSS 'bSS
    [t|CString -> CInt -> CString -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /['String'] -> 'Bool'/
-- for using in directive /haskell_run/.
ngxExportBLS :: Name -> Q [Dec]
ngxExportBLS =
    ngxExport 'BLS 'bLS
    [t|Ptr NgxStrType -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /'B.ByteString' -> 'L.ByteString'/
-- for using in directive /haskell_run/.
ngxExportYY :: Name -> Q [Dec]
ngxExportYY =
    ngxExport 'YY 'yY
    [t|CString -> CInt ->
       Ptr (Ptr NgxStrType) -> Ptr CInt ->
       Ptr (StablePtr L.ByteString) -> IO CUInt|]

-- | Exports a function of type
-- /'B.ByteString' -> 'Bool'/
-- for using in directive /haskell_run/.
ngxExportBY :: Name -> Q [Dec]
ngxExportBY =
    ngxExport 'BY 'bY
    [t|CString -> CInt ->
       Ptr CString -> Ptr CInt -> IO CUInt|]

-- | Exports a function of type
-- /'B.ByteString' -> 'IO' 'L.ByteString'/
-- for using in directive /haskell_run/.
ngxExportIOYY :: Name -> Q [Dec]
ngxExportIOYY =
    ngxExportC 'IOYY 'ioyY
    [t|CString -> CInt ->
       Ptr (Ptr NgxStrType) -> Ptr CInt ->
       Ptr (StablePtr L.ByteString) -> IO CUInt|]

-- | Exports a function of type
-- /'B.ByteString' -> 'IO' 'L.ByteString'/
-- for using in directive /haskell_run_async/.
ngxExportAsyncIOYY :: Name -> Q [Dec]
ngxExportAsyncIOYY =
    ngxExportC 'IOYY 'asyncIOYY
    [t|CString -> CInt -> CInt -> CInt -> CUInt -> CUInt ->
       Ptr (Ptr NgxStrType) -> Ptr CInt ->
       Ptr CUInt -> Ptr (StablePtr L.ByteString) -> IO (StablePtr (Async ()))|]

-- | Exports a function of type
-- /'L.ByteString' -> 'B.ByteString' -> 'IO' 'L.ByteString'/
-- for using in directive /haskell_run_async_on_request_body/.
--
-- The first argument of the exported function contains buffers of the client
-- request body.
ngxExportAsyncOnReqBody :: Name -> Q [Dec]
ngxExportAsyncOnReqBody =
    ngxExport 'IOYYY 'asyncIOYYY
    [t|Ptr NgxStrType -> CInt -> CString -> CInt -> CInt -> CUInt ->
       Ptr (Ptr NgxStrType) -> Ptr CInt ->
       Ptr CUInt -> Ptr (StablePtr L.ByteString) -> IO (StablePtr (Async ()))|]

-- | Exports a function of type
-- /'B.ByteString' -> 'Bool' -> 'IO' 'L.ByteString'/
-- for using in directive /haskell_run_service/.
--
-- The boolean argument of the exported function marks that the service is
-- being run for the first time.
ngxExportServiceIOYY :: Name -> Q [Dec]
ngxExportServiceIOYY =
    ngxExport 'IOYY 'asyncIOYY
    [t|CString -> CInt -> CInt -> CInt -> CUInt -> CUInt ->
       Ptr (Ptr NgxStrType) -> Ptr CInt ->
       Ptr CUInt -> Ptr (StablePtr L.ByteString) -> IO (StablePtr (Async ()))|]

-- | Exports a function of type
-- /'B.ByteString' -> ('L.ByteString', 'String', 'Int')/
-- for using in directives /haskell_content/ and /haskell_static_content/.
--
-- The first element in the returned /3-tuple/ of the exported function is
-- the /content/, the second is the /content type/, and the third is the
-- /HTTP status/.
ngxExportHandler :: Name -> Q [Dec]
ngxExportHandler =
    ngxExport 'Handler 'handler
    [t|CString -> CInt -> Ptr (Ptr NgxStrType) -> Ptr CInt ->
       Ptr CString -> Ptr CSize -> Ptr CInt ->
       Ptr (StablePtr L.ByteString) -> IO CUInt|]

-- | Exports a function of type
-- /'B.ByteString' -> 'L.ByteString'/
-- for using in directives /haskell_content/ and /haskell_static_content/.
ngxExportDefHandler :: Name -> Q [Dec]
ngxExportDefHandler =
    ngxExport 'YY 'defHandler
    [t|CString -> CInt ->
       Ptr (Ptr NgxStrType) -> Ptr CInt -> Ptr CString ->
       Ptr (StablePtr L.ByteString) -> IO CUInt|]

-- | Exports a function of type
-- /'B.ByteString' -> ('B.ByteString', 'B.ByteString', 'Int')/
-- for using in directive /haskell_unsafe_content/.
--
-- The first element in the returned /3-tuple/ of the exported function is
-- the /content/, the second is the /content type/, and the third is the
-- /HTTP status/. Both the content and the content type are supposed to be
-- referring to low-level string literals which do not need to be freed upon
-- the request termination and must not be garbage-collected in the Haskell RTS.
ngxExportUnsafeHandler :: Name -> Q [Dec]
ngxExportUnsafeHandler =
    ngxExport 'UnsafeHandler 'unsafeHandler
    [t|CString -> CInt -> Ptr CString -> Ptr CSize ->
       Ptr CString -> Ptr CSize -> Ptr CInt -> IO CUInt|]

data NgxStrType = NgxStrType CSize CString

instance Storable NgxStrType where
    alignment = const $ max (alignment (undefined :: CSize))
                            (alignment (undefined :: CString))
    sizeOf = (2 *) . alignment  -- must always be correct for
                                -- aligned struct ngx_str_t
    peek p = do
        n <- peekByteOff p 0
        s <- peekByteOff p $ alignment (undefined :: NgxStrType)
        return $ NgxStrType n s
    poke p x@(NgxStrType n s) = do
        poke (castPtr p) n
        poke (plusPtr p $ alignment x) s

safeMallocBytes :: Int -> IO (Ptr a)
safeMallocBytes =
    flip catchIOError (const $ return nullPtr) . mallocBytes
{-# INLINE safeMallocBytes #-}

safeNewCStringLen :: String -> IO CStringLen
safeNewCStringLen =
    flip catchIOError (const $ return (nullPtr, -1)) . newCStringLen
{-# INLINE safeNewCStringLen #-}

peekNgxStringArrayLen :: (CStringLen -> IO a) -> Ptr NgxStrType -> Int -> IO [a]
peekNgxStringArrayLen f x = sequence .
    foldr (\k ->
            ((peekElemOff x k >>= (\(NgxStrType (I m) y) -> f (y, m))) :)
          ) [] . flip take [0 ..]
{-# SPECIALIZE INLINE peekNgxStringArrayLen ::
    (CStringLen -> IO String) -> Ptr NgxStrType -> Int ->
        IO [String] #-}
{-# SPECIALIZE INLINE peekNgxStringArrayLen ::
    (CStringLen -> IO B.ByteString) -> Ptr NgxStrType -> Int ->
        IO [B.ByteString] #-}

peekNgxStringArrayLenLS :: Ptr NgxStrType -> Int -> IO [String]
peekNgxStringArrayLenLS =
    peekNgxStringArrayLen peekCStringLen

peekNgxStringArrayLenY :: Ptr NgxStrType -> Int -> IO L.ByteString
peekNgxStringArrayLenY =
    (fmap L.fromChunks .) . peekNgxStringArrayLen B.unsafePackCStringLen

pokeCStringLen :: Storable a => CString -> a -> Ptr CString -> Ptr a -> IO ()
pokeCStringLen x n p s = poke p x >> poke s n
{-# SPECIALIZE INLINE pokeCStringLen ::
    CString -> CInt -> Ptr CString -> Ptr CInt -> IO () #-}
{-# SPECIALIZE INLINE pokeCStringLen ::
    CString -> CSize -> Ptr CString -> Ptr CSize -> IO () #-}

toBuffers :: L.ByteString -> Ptr NgxStrType -> IO (Ptr NgxStrType, Int)
toBuffers (L.null -> True) _ =
    return (nullPtr, 0)
toBuffers s p = do
    let n = L.foldlChunks (const . succ) 0 s
    if n == 1
        then do
            B.unsafeUseAsCStringLen (head $ L.toChunks s) $
                \(x, I l) -> poke p $ NgxStrType l x
            return (p, 1)
        else do
            t <- safeMallocBytes $ n * sizeOf (undefined :: NgxStrType)
            if t == nullPtr
                then return (nullPtr, -1)
                else (,) t <$>
                        L.foldlChunks
                            (\a c -> do
                                off <- a
                                B.unsafeUseAsCStringLen c $
                                    \(x, I l) ->
                                        pokeElemOff t off $ NgxStrType l x
                                return $ off + 1
                            ) (return 0) s

pokeLazyByteString :: L.ByteString ->
    Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr (StablePtr L.ByteString) -> IO ()
pokeLazyByteString s p pl spd = do
    PtrLen t l <- peek p >>= toBuffers s
    when (l /= 1) (poke p t) >> poke pl l
    when (t /= nullPtr) $ newStablePtr s >>= poke spd

safeHandler :: Ptr CString -> Ptr CInt -> IO CUInt -> IO CUInt
safeHandler p pl = handle $ \e -> do
    PtrLen x l <- safeNewCStringLen $ show (e :: SomeException)
    pokeCStringLen x l p pl
    return 1

safeYYHandler :: IO (L.ByteString, (CUInt, Bool)) ->
    IO (L.ByteString, (CUInt, Bool))
safeYYHandler = handle $ \e ->
    return (C8L.pack $ show e,
            (1, case asyncExceptionFromException e of
                    Nothing -> False
                    Just ae -> ae == ThreadKilled
            )
           )
{-# INLINE safeYYHandler #-}

isEINTR :: IOError -> Bool
isEINTR = (Just ((\(Errno i) -> i) eINTR) ==) . ioe_errno
{-# INLINE isEINTR #-}

sS :: SS -> CString -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
sS f x (I n) p pl =
    safeHandler p pl $ do
        PtrLen s l <- f <$> peekCStringLen (x, n)
                        >>= newCStringLen
        pokeCStringLen s l p pl
        return 0

sSS :: SSS -> CString -> CInt -> CString -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
sSS f x (I n) y (I m) p pl =
    safeHandler p pl $ do
        PtrLen s l <- f <$> peekCStringLen (x, n)
                        <*> peekCStringLen (y, m)
                        >>= newCStringLen
        pokeCStringLen s l p pl
        return 0

sLS :: SLS -> Ptr NgxStrType -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
sLS f x (I n) p pl =
    safeHandler p pl $ do
        PtrLen s l <- f <$> peekNgxStringArrayLenLS x n
                        >>= newCStringLen
        pokeCStringLen s l p pl
        return 0

yY :: YY -> CString -> CInt ->
    Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr (StablePtr L.ByteString) -> IO CUInt
yY f x (I n) p pl spd = do
    (s, (r, _)) <- safeYYHandler $ do
        s <- f <$> B.unsafePackCStringLen (x, n)
        fmap (flip (,) (0, False)) $ return $! s
    pokeLazyByteString s p pl spd
    return r

ioyY :: IOYY -> CString -> CInt ->
    Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr (StablePtr L.ByteString) -> IO CUInt
ioyY f x (I n) p pl spd = do
    (s, (r, _)) <- safeYYHandler $ do
        s <- B.unsafePackCStringLen (x, n) >>= flip f False
        fmap (flip (,) (0, False)) $ return $! s
    pokeLazyByteString s p pl spd
    return r

asyncIOFlag1b :: B.ByteString
asyncIOFlag1b = L.toStrict $ runPut $ putInt8 1

asyncIOFlag8b :: B.ByteString
asyncIOFlag8b = L.toStrict $ runPut $ putInt64host 1

asyncIOCommon :: IO (C8L.ByteString, Bool) ->
    CInt -> Bool -> Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr CUInt -> Ptr (StablePtr L.ByteString) -> IO (StablePtr (Async ()))
asyncIOCommon a (I fd) efd p pl pr spd =
    async
    (do
        (s, (r, exiting)) <- safeYYHandler $ do
            (s, exiting) <- a
            fmap (flip (,) (0, exiting)) $ return $! s
        pokeLazyByteString s p pl spd
        poke pr r
        if exiting
            then unless efd closeChannel
            else uninterruptibleMask_ $
                    if efd
                        then writeFlag8b
                        else writeFlag1b >> closeChannel
    ) >>= newStablePtr
    where writeBufN n s = void $
              iterateUntilM (>= n)
              (\w -> (w +) <$>
                  fdWriteBuf fd (plusPtr s $ fromIntegral w) (n - w)
                  `catchIOError`
                  (\e -> return $ if isEINTR e
                                      then 0
                                      else n
                  )
              ) 0
          writeFlag1b = B.unsafeUseAsCString asyncIOFlag1b $ writeBufN 1
          writeFlag8b = B.unsafeUseAsCString asyncIOFlag8b $ writeBufN 8
          closeChannel = closeFd fd `catchIOError` const (return ())

asyncIOYY :: IOYY -> CString -> CInt ->
    CInt -> CInt -> CUInt -> CUInt -> Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr CUInt -> Ptr (StablePtr L.ByteString) -> IO (StablePtr (Async ()))
asyncIOYY f x (I n) fd (I fdlk) (ToBool efd) (ToBool fstRun) =
    asyncIOCommon
    (do
        exiting <- if fstRun && fdlk /= -1
                       then snd <$>
                           iterateUntil ((True ==) . fst)
                           (safeWaitToSetLock fdlk
                                (WriteLock, AbsoluteSeek, 0, 0) >>
                                    return (True, False)
                           )
                           `catches`
                           [E.Handler $ return . flip (,) False . not . isEINTR
                           ,E.Handler $ return . (,) True . (== ThreadKilled)
                           ]
                       else return False
        if exiting
            then return (C8L.empty, True)
            else do
                x' <- B.unsafePackCStringLen (x, n)
                flip (,) False <$> f x' fstRun
    ) fd efd

asyncIOYYY :: IOYYY -> Ptr NgxStrType -> CInt -> CString -> CInt ->
    CInt -> CUInt -> Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr CUInt -> Ptr (StablePtr L.ByteString) -> IO (StablePtr (Async ()))
asyncIOYYY f b (I m) x (I n) fd (ToBool efd) =
    asyncIOCommon
    (do
        b' <- peekNgxStringArrayLenY b m
        x' <- B.unsafePackCStringLen (x, n)
        flip (,) False <$> f b' x'
    ) fd efd

bS :: BS -> CString -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
bS f x (I n) p pl =
    safeHandler p pl $ do
        r <- fromBool . f <$> peekCStringLen (x, n)
        pokeCStringLen nullPtr 0 p pl
        return r

bSS :: BSS -> CString -> CInt -> CString -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
bSS f x (I n) y (I m) p pl =
    safeHandler p pl $ do
        r <- (fromBool .) . f <$> peekCStringLen (x, n)
                              <*> peekCStringLen (y, m)
        pokeCStringLen nullPtr 0 p pl
        return r

bLS :: BLS -> Ptr NgxStrType -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
bLS f x (I n) p pl =
    safeHandler p pl $ do
        r <- fromBool . f <$> peekNgxStringArrayLenLS x n
        pokeCStringLen nullPtr 0 p pl
        return r

bY :: BY -> CString -> CInt ->
    Ptr CString -> Ptr CInt -> IO CUInt
bY f x (I n) p pl =
    safeHandler p pl $ do
        r <- fromBool . f <$> B.unsafePackCStringLen (x, n)
        pokeCStringLen nullPtr 0 p pl
        return r

handler :: Handler -> CString -> CInt -> Ptr (Ptr NgxStrType) -> Ptr CInt ->
    Ptr CString -> Ptr CSize -> Ptr CInt ->
    Ptr (StablePtr L.ByteString) -> IO CUInt
handler f x (I n) p pl pct plct pst spd =
    safeHandler pct pst $ do
        (s, ct, I st) <- f <$> B.unsafePackCStringLen (x, n)
        PtrLen sct lct <- newCStringLen ct
        pokeCStringLen sct lct pct plct >> poke pst st
        pokeLazyByteString s p pl spd
        return 0

defHandler :: YY -> CString -> CInt ->
    Ptr (Ptr NgxStrType) -> Ptr CInt -> Ptr CString ->
    Ptr (StablePtr L.ByteString) -> IO CUInt
defHandler f x (I n) p pl pe spd =
    safeHandler pe pl $ do
        s <- f <$> B.unsafePackCStringLen (x, n)
        pokeLazyByteString s p pl spd
        return 0

unsafeHandler :: UnsafeHandler -> CString -> CInt -> Ptr CString -> Ptr CSize ->
    Ptr CString -> Ptr CSize -> Ptr CInt -> IO CUInt
unsafeHandler f x (I n) p pl pct plct pst =
    safeHandler pct pst $ do
        (s, ct, I st) <- f <$> B.unsafePackCStringLen (x, n)
        PtrLen sct lct <- B.unsafeUseAsCStringLen ct return
        pokeCStringLen sct lct pct plct >> poke pst st
        PtrLen t l <- B.unsafeUseAsCStringLen s return
        pokeCStringLen t l p pl
        return 0

{- SPLICE: safe version of waitToSetLock as defined in System.Posix.IO -}

foreign import ccall interruptible "HsBase.h fcntl"
    safe_c_fcntl_lock :: CInt -> CInt -> Ptr CFLock -> IO CInt

mode2Int :: SeekMode -> CShort
mode2Int AbsoluteSeek = 0
mode2Int RelativeSeek = 1
mode2Int SeekFromEnd  = 2

lockReq2Int :: LockRequest -> CShort
lockReq2Int ReadLock  = 0
lockReq2Int WriteLock = 1
lockReq2Int Unlock    = 2

allocaLock :: FileLock -> (Ptr CFLock -> IO a) -> IO a
allocaLock (lockreq, mode, start, len) io =
    allocaBytes 32 $ \p -> do
        (`pokeByteOff`  0) p (lockReq2Int lockreq)
        (`pokeByteOff`  2) p (mode2Int mode)
        (`pokeByteOff`  8) p start
        (`pokeByteOff` 16) p len
        io p

safeWaitToSetLock :: Fd -> FileLock -> IO ()
safeWaitToSetLock (Fd fd) lock = allocaLock lock $
    \p_flock -> throwErrnoIfMinus1_ "safeWaitToSetLock" $
        safe_c_fcntl_lock fd 7 p_flock

{- SPLICE: END -}

foreign export ccall ngxExportTerminateTask :: StablePtr (Async ()) -> IO ()

ngxExportTerminateTask :: StablePtr (Async ()) -> IO ()
ngxExportTerminateTask = deRefStablePtr >=> cancel

foreign export ccall ngxExportVersion :: Ptr CInt -> CInt -> IO CInt

ngxExportVersion :: Ptr CInt -> CInt -> IO CInt
ngxExportVersion x (I n) = fromIntegral <$>
    foldM (\k (I v) -> pokeElemOff x k v >> return (k + 1)) 0
        (take n $ versionBranch version)

