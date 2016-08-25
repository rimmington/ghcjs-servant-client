{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE CPP                  #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE MagicHash            #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE FlexibleInstances    #-}

module Servant.Common.Req (
  module Servant.Common.Req, module JavaScript.FormData
  ) where

import JavaScript.FormData

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif
import Control.Exception
import Control.Monad
import Control.Monad.Catch (MonadThrow)
import Control.Monad.IO.Class
import Control.Monad.Trans.Either
import Data.ByteString.Lazy hiding (pack, filter, map, null, elem, unpack)
import Data.ByteString.Char8 (unpack, pack)
import qualified Data.ByteString as BS
import Data.IORef
import Data.String
import Data.String.Conversions
import Data.Proxy
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import Data.Typeable
import Data.Primitive.ByteArray
import           Data.Primitive.Addr
import           Data.ByteString.Unsafe (unsafePackAddressLen)
import Network.HTTP.Media
import Network.HTTP.Types
import qualified Network.HTTP.Types.Header   as HTTP
import Network.URI
import Servant.API.ContentTypes
import Servant.Common.BaseUrl
import Servant.Common.Text
import System.IO.Unsafe
import GHCJS.Foreign (jsTrue)
import GHCJS.Foreign.Callback (Callback (..)
                              , OnBlocked(..)
                              , syncCallback)

import Data.JSString (JSString)
import qualified Data.JSString as JSString

import GHCJS.Marshal
import GHCJS.Prim --hiding (fromJSString, toJSString)
import Control.Concurrent.MVar
import Data.List.Split
import Data.Maybe
import Data.CaseInsensitive
import Data.Char
import Unsafe.Coerce

data ServantError
  = FailureResponse
    { responseStatus            :: Status
    , responseContentType       :: MediaType
    , responseBody              :: ByteString
    }
  | DecodeFailure
    { decodeError               :: String
    , responseContentType       :: MediaType
    , responseBody              :: ByteString
    }
  | UnsupportedContentType
    { responseContentType       :: MediaType
    , responseBody              :: ByteString
    }
  | InvalidContentTypeHeader
    { responseContentTypeHeader :: ByteString
    , responseBody              :: ByteString
    }
  deriving (Show, Typeable)

instance Exception ServantError

data ForeignRetention
  = NeverRetain                   -- ^ do not retain data unless the callback is directly
                                  --   referenced by a Haskell thread.
  | AlwaysRetain                  -- ^ retain references indefinitely, until `freeCallback`
                                  --   is called (the callback will be kept in memory until it's freed)
  | DomRetain JSVal               -- ^ retain data as long as the `JSVal` is a DOM element in
                                  --   `window.document` or in a DOM tree referenced by a Haskell
                                  --    thread.

data Req = Req
  { reqPath   :: String
  , qs        :: QueryText
  , reqBody   :: CReqBody
  , reqAccept :: [MediaType]
  , headers   :: [(String, Text)]
  }

data CReqBody = NoBody
              | ByteBody ByteString MediaType
              | FormBody [FormDataProp]

defReq :: Req
defReq = Req "" [] NoBody [] []

appendToPath :: String -> Req -> Req
appendToPath p req =
  req { reqPath = reqPath req ++ "/" ++ p }

appendToMatrixParams :: String
                     -> Maybe String
                     -> Req
                     -> Req
appendToMatrixParams pname pvalue req =
  req { reqPath = reqPath req ++ ";" ++ pname ++ maybe "" ("=" ++) pvalue }

appendToQueryString :: Text       -- ^ param name
                    -> Maybe Text -- ^ param value
                    -> Req
                    -> Req
appendToQueryString pname pvalue req =
  req { qs = qs req ++ [(pname, pvalue)]
      }

addHeader :: ToText a => String -> a -> Req -> Req
addHeader name val req = req { headers = headers req
                                      ++ [(name, toText val)]
                             }

setRQBody :: ByteString -> MediaType -> Req -> Req
setRQBody b t req = req { reqBody = ByteBody b t }

setRQFormData :: [FormDataProp] -> Req -> Req
setRQFormData fd req = req { reqBody = FormBody fd }

displayHttpRequest :: Method -> String
displayHttpRequest httpmethod = "HTTP " ++ cs httpmethod ++ " request"

performRequest :: Method -> Req -> (Int -> Bool) -> Maybe BaseUrl
               -> EitherT ServantError IO ( Int, ByteString, MediaType
                                          , [HTTP.Header])
performRequest reqMethod req isWantedStatus reqHost = do
  eResp <- liftIO $ makeRequest reqMethod req isWantedStatus reqHost
  case eResp of
    (Left err) -> left err
    (Right (status_code, hrds, body)) -> do
      ct <- case lookup "Content-Type" hrds of
                 Nothing -> pure $ "application"//"octet-stream"
                 Just t -> case parseAccept t of
                   Nothing -> left $ InvalidContentTypeHeader (cs t) $ fromStrict body
                   Just t' -> pure t'
      return (status_code, fromStrict body, ct, hrds)


performRequestCT :: MimeUnrender ct result =>
  Proxy ct -> Method -> Req -> [Int] -> Maybe BaseUrl -> EitherT ServantError IO ([HTTP.Header], result)
performRequestCT ct reqMethod req wantedStatus reqHost = do
  let acceptCT = contentType ct
  (_status, respBody, respCT, hrds) <-
    performRequest reqMethod (req { reqAccept = [acceptCT] }) (`elem` wantedStatus) reqHost
  unless (matches respCT (acceptCT)) $ left $ UnsupportedContentType respCT respBody
  case mimeUnrender ct respBody of
    Left err -> left $ DecodeFailure err respCT respBody
    Right val -> return (hrds, val)

performRequestNoBody :: Method -> Req -> [Int] -> Maybe BaseUrl -> EitherT ServantError IO ()
performRequestNoBody reqMethod req wantedStatus reqHost = do
  _ <- performRequest reqMethod req (`elem` wantedStatus) reqHost
  return ()


--data XMLHttpRequest

-- foreign import javascript unsafe "new XMLHttpRequest()"
--   jsXhrRequest :: IO JSRef
-- foreign import javascript unsafe "new XMLHttpRequest()"
--   jsXhrRequestString :: IO JSString
-- foreign import javascript unsafe "$1.open($2, $3, $4)"
--   jsXhrOpen :: JSRef -> JSRef -> JSRef -> JSRef -> IO ()
-- foreign import javascript unsafe "$1.send()"
--   jsXhrSend :: JSRef ->  IO ()
-- foreign import javascript unsafe "$1.send($2)"
--   jsXhrSendWith :: JSRef -> JSRef -> IO ()
-- foreign import javascript unsafe "$1.onreadystatechange = $2"
--   jsXhrOnReadyStateChange:: JSRef -> Callback (IO ()) -> IO ()
-- foreign import javascript unsafe "$1.readyState"
--   jsXhrReadyState:: JSRef -> IO JSRef
-- foreign import javascript unsafe "$1.responseText"
--   jsXhrResponseText:: JSRef -> IO JSString
-- foreign import javascript unsafe "$1.response"
--   jsXhrResponse:: JSRef -> IO JSRef
-- foreign import javascript unsafe "$1.responseType = $2"
--   jsXhrResponseType:: JSRef -> JSString -> IO ()
-- foreign import javascript unsafe "$1.status"
--   jsXhrStatus:: JSRef -> IO JSRef
-- foreign import javascript unsafe "$1.getAllResponseHeaders()"
--   jsXhrResponseHeaders :: JSString -> IO JSRef
-- foreign import javascript unsafe "$1.setRequestHeader($2, $3)"
--   jsXhrSetRequestHeader :: JSRef -> JSString -> JSString -> IO ()
-- foreign import javascript unsafe "$1.statusText"
--   jsXhrGetStatusText :: JSRef -> IO JSString
-- foreign import javascript unsafe "xh = $1"
--   jsDebugXhr :: JSRef -> IO ()
foreign import javascript unsafe "new XMLHttpRequest()"
  jsXhrRequest :: IO JSVal
foreign import javascript unsafe "$1.open($2, $3, $4)"
  jsXhrOpen :: JSVal -> JSString -> JSString -> JSVal -> IO ()
foreign import javascript unsafe "$1.send()"
  jsXhrSend :: JSVal -> IO ()
foreign import javascript unsafe "$1.send($2)"
  jsXhrSendWith :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe "$1.onreadystatechange = $2"
  jsXhrOnReadyStateChange:: JSVal -> Callback (IO ()) -> IO ()
foreign import javascript unsafe "$1.readyState"
  jsXhrReadyState:: JSVal -> IO JSVal
foreign import javascript unsafe "$1.responseText"
  jsXhrResponseText:: JSVal -> IO JSString
foreign import javascript unsafe "$1.response"
  jsXhrResponse:: JSVal -> IO JSVal
foreign import javascript unsafe "$1.responseType = $2"
  jsXhrResponseType:: JSVal -> JSString -> IO ()
foreign import javascript unsafe "$1.status"
  jsXhrStatus:: JSVal -> IO JSVal
foreign import javascript unsafe "$1.getAllResponseHeaders()"
  jsXhrResponseHeaders :: JSVal -> IO JSString
foreign import javascript unsafe "$1.setRequestHeader($2, $3)"
  jsXhrSetRequestHeader :: JSVal -> JSString -> JSString -> IO ()
foreign import javascript unsafe "$1.statusText"
  jsXhrGetStatusText :: JSVal -> IO JSString
foreign import javascript unsafe "xh = $1"
  jsDebugXhr :: JSVal -> IO ()
foreign import javascript safe "h$wrapBuffer($3, true, $1, $2)"
  js_wrapBuffer :: Int -> Int -> JSVal -> IO JSVal
foreign import javascript unsafe "h$release($1)"
  js_release :: Callback (IO ()) -> IO ()

xhrResponseHeaders :: JSVal -> IO [HTTP.Header]
xhrResponseHeaders jReq = do
  (headers :: JSString) <- jsXhrResponseHeaders jReq
  let headersStrings = T.lines . T.pack . JSString.unpack $ headers
  return $ catMaybes $ buildHeader <$> headersStrings


buildHeader :: Text -> Maybe HTTP.Header
buildHeader xs = parseXs $ splitStr xs
  where splitStr = T.splitOn (":")
        parseXs :: [Text] -> Maybe HTTP.Header
        parseXs (c:cs) = Just (mk $ encodeUtf8 $ T.strip c, encodeUtf8 $ T.strip $ T.concat cs)
        parseXs _ = Nothing

bufferByteString :: Int        -- ^ offset from the start in bytes
                 -> Int        -- ^ length in bytes (use zero or a negative number to get the whole ArrayBuffer)
                 -> JSVal
                 -> IO BS.ByteString
bufferByteString offset length buf = do
  (ByteArray ba) <- wrapBuffer offset length buf
  byteArrayByteString ba

byteArrayByteString :: ByteArray# -> IO BS.ByteString
byteArrayByteString arr =
#ifdef ghcjs_HOST_OS
  let ba        = ByteArray arr
      !(Addr a) = byteArrayContents ba
  in  unsafePackAddressLen (sizeofByteArray ba) a
#else
  error "GHCJS.Foreign.byteArrayToByteString: not JS"
#endif

wrapBuffer :: Int          -- ^ offset from the start in bytes, if this is not a multiple of 8,
                           --   not all types can be read from the ByteArray#
           -> Int          -- ^ length in bytes (use zero or a negative number to use the whole ArrayBuffer)
           -> JSVal        -- ^ JavaScript ArrayBuffer object
           -> IO ByteArray -- ^ result
wrapBuffer offset size buf = unsafeCoerce <$> js_wrapBuffer offset size buf
{-# INLINE wrapBuffer #-}

makeRequest :: Method -> Req -> (Int -> Bool) -> Maybe BaseUrl -> IO (Either ServantError (Int, [HTTP.Header], BS.ByteString))
makeRequest method req isWantedStatus bUrl = do
  jRequest <- jsXhrRequest
  let url = JSString.pack . show  $ buildUrl req bUrl
      methodText = JSString.pack $ unpack method
  jsXhrOpen jRequest methodText url jsTrue
  jsXhrResponseType jRequest "arraybuffer"
  resp <- newEmptyMVar
  cb <- syncCallback ThrowWouldBlock $ do
    r <- jsXhrReadyState jRequest :: IO JSVal
    state <- fromJSVal r
    when ((state :: Maybe Int) == Just 4) $ do
      statusCode <- fromMaybe (-1) <$> (fromJSVal =<< jsXhrStatus jRequest)
      if (statusCode >= 200 && statusCode < 300)
        then do
          bsResp <- bufferByteString 0 0 =<< jsXhrResponse jRequest
          headers <- xhrResponseHeaders jRequest
          putMVar resp $ Right (statusCode, headers, bsResp)
        else do
          bsStatusText <- jsXhrGetStatusText jRequest
          bsResp <- bufferByteString 0 0 =<< jsXhrResponse jRequest

          putMVar resp $ Left $ FailureResponse (mkStatus statusCode .
                                                       pack . JSString.unpack $ bsStatusText)
                                                ("unknown" // "unknown")
                                                (fromStrict bsResp)


  jsXhrOnReadyStateChange jRequest cb
  case reqBody req of
    NoBody -> jsXhrSend jRequest
    ByteBody body mediaType -> do
      jsXhrSetRequestHeader jRequest "Content-Type" $ JSString.pack $ show mediaType
      b <- toJSVal (decodeUtf8 $ toStrict body)
      jsXhrSendWith jRequest b
    FormBody fs -> do
      fd <- newFormData
      mapM_ (appendFormData fd) fs
      jsXhrSendWith jRequest $ unFormData fd
  res <- takeMVar resp
  release cb
  return res

release :: Callback (IO ()) -- ^ the callback
                 -> IO ()
release = js_release

buildUrl :: Req -> Maybe BaseUrl -> URI
buildUrl req@(Req path qText mBody rAccept hs) baseurl =
  (baseURI baseurl){uriPath = path, uriQuery = query}
  where
    query = unpack $ renderQuery True $ queryTextToQuery qText
    baseURI Nothing = nullURI
    baseURI (Just (BaseUrl scheme host port)) =
      nullURI {
        uriScheme = schemeText,
        uriAuthority = Just $ URIAuth "" host portText
      }
      where
        portText = ":" <> (show port)
        schemeText = case scheme of
                            Http -> "http:"
                            Https -> "https:"
