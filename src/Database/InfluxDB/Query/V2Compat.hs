{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
module Database.InfluxDB.Query.V2Compat
  ( QueryParams (..)
  , queryParams

  , query
  , withQueryResponse
  ) where

import Control.Exception
import Data.Aeson
import qualified Data.Aeson.Parser as A
import qualified Data.Aeson.Types as A
import qualified Data.Attoparsec.ByteString as AB
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Proxy
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Vector (Vector)
import qualified Network.HTTP.Client as HC
import qualified Network.HTTP.Types as HT

import Database.InfluxDB.JSON
import Database.InfluxDB.Types as Types
import qualified Database.InfluxDB.Format as F
import qualified Database.InfluxDB.Query as Q

-- | Like Database.InfluxDB.Query.QueryParams but with support for giving a
-- retention policy, and using an auth token.
data QueryParams = QueryParams
  { queryServer :: !Server
  , queryDatabase :: !Database
  , queryRetentionPolicy :: !(Maybe Text)
  , queryPrecision :: !(Precision 'QueryRequest)
  , queryAuthentication :: !(Either Text (Maybe Credentials))
  , queryManager :: !(Either HC.ManagerSettings HC.Manager)
  , queryDecoder :: Decoder
  }

-- | Smart constructor for 'QueryParams'.
--
-- Default parameters:
--
--   ['server'] 'defaultServer'
--   ['retentionPolicy'] 'Nothing'
--   ['precision'] 'RFC3339'
--   ['authentication'] @'Right' 'Nothing'@
--   ['manager'] @'Left' 'HC.defaultManagerSettings'@
--   ['decoder'] @'strictDecoder'@
queryParams :: Database -> QueryParams
queryParams queryDatabase = QueryParams
  { queryServer = defaultServer
  , queryDatabase = queryDatabase
  , queryRetentionPolicy = Nothing
  , queryPrecision = RFC3339
  , queryAuthentication = Right Nothing
  , queryManager = Left HC.defaultManagerSettings
  , queryDecoder = strictDecoder
  }

query :: forall a . Q.QueryResults a => QueryParams -> Q.Query -> IO (Vector a)
query params q = withQueryResponse params q go
  where
    go request response = do
      chunks <- HC.brConsume $ HC.responseBody response
      let body = BL.fromChunks chunks
      case eitherDecode' body of
        Left message -> do
          throwIO $ UnexpectedResponse message request body
        Right val -> do
          let parser = Q.parseQueryResultsWith
                (fromMaybe
                  (queryDecoder params)
                  (Q.coerceDecoder (Proxy :: Proxy a)))
                (queryPrecision params)
          case A.parse parser val of
            A.Success vec -> return vec
            A.Error message -> do
              Q.errorQuery message request response val

withQueryResponse
  :: QueryParams
  -> Q.Query
  -> (HC.Request -> HC.Response HC.BodyReader -> IO r)
  -> IO r
withQueryResponse params q f = do
    manager' <- either HC.newManager return $ queryManager params
    HC.withResponse request manager' (f request)
      `catch` (throwIO . HTTPException)
  where
    request = queryRequest params q

queryRequest :: QueryParams -> Q.Query -> HC.Request
queryRequest QueryParams {..} q = HC.urlEncodedBody bodyParams $ applyAuth $ HC.defaultRequest
    { HC.host = TE.encodeUtf8 _host
    , HC.port = fromIntegral _port
    , HC.secure = _ssl
    , HC.method = "POST"
    , HC.path = "/query"
    , HC.responseTimeout = HC.responseTimeoutNone
    , HC.requestHeaders = [("Accept", "application/json")]
    }

  where

    Server {..} = queryServer

    applyAuth = case queryAuthentication of
      Left tok -> \req -> req
        { HC.requestHeaders = ("Authorization", TE.encodeUtf8 ("Token " <> tok)) : HC.requestHeaders req }
      Right Nothing -> id
      Right (Just (Credentials {..})) ->
        HC.applyBasicAuth (TE.encodeUtf8 _user) (TE.encodeUtf8 _password)

    bodyParams =
      [ ("q",  F.fromQuery q)
      , ("db", TE.encodeUtf8 (databaseName queryDatabase))
      ] ++ case queryRetentionPolicy of
             Nothing -> []
             Just rp -> [ ("rp", TE.encodeUtf8 rp) ]
