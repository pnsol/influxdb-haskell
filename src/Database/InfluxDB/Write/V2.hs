{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
#if __GLASGOW_HASKELL__ >= 800
{-# OPTIONS_GHC -Wno-missing-signatures #-}
#else
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
#endif
module Database.InfluxDB.Write.V2
  ( -- * Writers
    -- $intro
    write
  , writeBatch
  , writeByteString

  -- * Writer parameters
  , WriteParams (..)
  , Types.server
  , Types.precision
  , Types.manager
) where
import Control.Exception
import Control.Monad
import Data.Maybe

import Debug.Trace (traceM)

import Control.Lens
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Client as HC
import qualified Network.HTTP.Types as HT
import qualified Network.HTTP.Types.Status as HT

import Database.InfluxDB.Line
import Database.InfluxDB.Types as Types
import Database.InfluxDB.JSON

-- | The full set of parameters for the HTTP writer.
data WriteParams = WriteParams
  { writeServer    :: !Server
  , writeBucket    :: !Text
  , writeOrg       :: !(Maybe Text)
  , writeOrgID     :: !(Maybe Text)
  , writePrecision :: !(Precision 'WriteRequest)
  -- ^ Timestamp precision
  --
  -- In the HTTP API, timestamps are scaled by the given precision.
  , writeAuthToken :: !Text
  -- ^ No authentication by default
  , writeManager   :: !(Either HC.ManagerSettings HC.Manager)
  -- ^ HTTP connection manager
  }

-- | Write a 'Line'.
--
-- >>> let p = writeParams "test-db"
-- >>> write p $ Line @UTCTime "room_temp" Map.empty (Map.fromList [("temp", FieldFloat 25.0)]) Nothing
write
  :: Timestamp time
  => WriteParams
  -> Line time
  -> IO ()
write p@WriteParams {writePrecision} =
  writeByteString p . encodeLine (scaleTo writePrecision)

-- | Write multiple 'Line's in a batch.
--
-- This is more efficient than calling 'write' multiple times.
--
-- >>> let p = writeParams "test-db"
-- >>> :{
-- writeBatch p
--   [ Line @UTCTime "temp" (Map.singleton "city" "tokyo") (Map.fromList [("temp", FieldFloat 25.0)]) Nothing
--   , Line @UTCTime "temp" (Map.singleton "city" "osaka") (Map.fromList [("temp", FieldFloat 25.2)]) Nothing
--   ]
-- :}
writeBatch
  :: (Timestamp time, Foldable f)
  => WriteParams
  -> f (Line time)
  -> IO ()
writeBatch p@WriteParams {writePrecision} =
  writeByteString p . encodeLines (scaleTo writePrecision)

-- | Write a raw 'BL.ByteString'
--
-- NB: a successful call does not mean the data was actually written, since
-- writes are asynchronous.
writeByteString :: WriteParams -> BL.ByteString -> IO ()
writeByteString params payload = do
  manager' <- either HC.newManager return $ writeManager params
  response <- HC.httpLbs request manager' `catch` (throwIO . HTTPException)
  let body = HC.responseBody response
      status = HC.responseStatus response
  if HT.statusCode status == 204
  then pure ()
  else do
    let message = B8.unpack $ HT.statusMessage status
    traceM (show response)
    traceM (show body)
    throwIO $ UnexpectedResponse message request body

{-
  else do
    traceM (show response)
    traceM (show body)
    if BL.null body
    then do
      when (HT.statusIsServerError status) $
        throwIO $ ServerError message
      when (HT.statusIsClientError status) $
        throwIO $ ClientError message request
    else case A.eitherDecode' body of
      Left message ->
        throwIO $ UnexpectedResponse message request body
      Right val -> case A.parse parseErrorObject val of
        A.Success err ->
          fail $ "BUG: impossible code path in "
            ++ "Database.InfluxDB.Write.writeByteString: "
            ++ err
        A.Error message -> do
          when (HT.statusIsServerError status) $
            throwIO $ ServerError message
          when (HT.statusIsClientError status) $
            throwIO $ ClientError message request
          throwIO $ UnexpectedResponse
            ("BUG: " ++ message
              ++ " in Database.InfluxDB.Write.writeByteString")
            request
            (A.encode val)
  -}
  where
    request = (writeRequest params)
      { HC.requestBody = HC.RequestBodyLBS payload
      }

writeRequest :: WriteParams -> HC.Request
writeRequest WriteParams {..} =
  HC.setQueryString qs HC.defaultRequest
    { HC.host = TE.encodeUtf8 _host
    , HC.port = fromIntegral _port
    , HC.secure = _ssl
    , HC.method = "POST"
    , HC.path = "/api/v2/write"
    , HC.requestHeaders = [ ("Authorization", TE.encodeUtf8 ("Token " <> writeAuthToken)) ]
    }
  where
    Server {..} = writeServer
    qs = concat
      [ [ ("bucket", Just $ TE.encodeUtf8 writeBucket)
        , ("precision", Just $ TE.encodeUtf8 $ precisionNameV2 writePrecision)
        ]
      ] ++ maybe [] (\org   -> [("org",   Just $ TE.encodeUtf8 org  )]) writeOrg
        ++ maybe [] (\orgID -> [("orgID", Just $ TE.encodeUtf8 orgID)]) writeOrgID
