{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Socket utilities. -}
module OM.Socket (
  -- * Socket Addresses
  AddressDescription(..),
  resolveAddr,

  -- * Ingress-only sockets
  openIngress,

  -- * Egress-only sockets
  openEgress,

  -- * Bidirection request/resposne servers.
  openServer,
  Responded,
  connectServer,
) where


import Control.Applicative (Alternative((<|>)))
import Control.Concurrent (Chan, MVar, forkIO, newChan, newEmptyMVar,
  putMVar, readChan, takeMVar, throwTo, writeChan)
import Control.Concurrent.STM (TVar, atomically, newTVar, readTVar,
  retry, writeTVar)
import Control.Exception (SomeException, bracketOnError, throw)
import Control.Monad (join, void, when)
import Control.Monad.Catch (MonadThrow(throwM), MonadCatch, try)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Logger.CallStack (LoggingT(runLoggingT),
  MonadLoggerIO(askLoggerIO), logDebug, logError, logWarn)
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Binary (Binary(get), encode)
import Data.Binary.Get (Decoder(Done, Fail, Partial), pushChunk,
  runGetIncremental)
import Data.ByteString (ByteString)
import Data.Conduit ((.|), ConduitT, awaitForever, runConduit, transPipe,
  yield)
import Data.Conduit.Network (sinkSocket, sourceSocket)
import Data.Conduit.Serialization.Binary (conduitDecode, conduitEncode)
import Data.Map (Map)
import Data.String (IsString)
import Data.Text (Text)
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Void (Void)
import Data.Word (Word32)
import GHC.Generics (Generic)
import Network.Socket (AddrInfo(addrAddress), Family(AF_INET, AF_INET6,
  AF_UNIX), SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix),
  SocketOption(ReuseAddr), SocketType(Stream), HostName, ServiceName,
  Socket, accept, bind, close, connect, defaultProtocol, getAddrInfo,
  listen, setSocketOption, socket)
import Network.Socket.ByteString (recv)
import Network.Socket.ByteString.Lazy (sendAll)
import Network.TLS (ClientParams, Context, ServerParams, contextNew,
  handshake, recvData, sendData)
import OM.Show (showt)
import Prelude (Applicative(pure), Bool(False, True), Bounded(minBound),
  Either(Left, Right), Enum(succ), Eq((/=)), Functor(fmap), Maybe(Just,
  Nothing), Monad((>>), (>>=), return), MonadFail(fail), Semigroup((<>)),
  Show(show), ($), (++), (.), (=<<), IO, Monoid, Num, Ord, String,
  sequence_, snd, userError)
import Text.Megaparsec (MonadParsec(eof), Parsec, many, oneOf, parse,
  satisfy)
import Text.Megaparsec.Char (char)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Conduit.List as CL
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Text.Megaparsec as M


{-|
  Opens an "ingress" socket, which is a socket that accepts a stream
  of messages without responding. In particular, we listen on a socket,
  accepting new connections, an each connection concurrently reads its
  elements off the socket and pushes them onto the stream.
-}
openIngress
  :: ( Binary i
     , MonadFail m
     , MonadIO m
     )
  => AddressDescription
  -> ConduitT () i m ()
openIngress bindAddr = do
    so <- listenSocket =<< resolveAddr bindAddr
    mvar <- liftIO newEmptyMVar
    void . liftIO . forkIO $ acceptLoop so mvar
    mvarToSource mvar
  where
    mvarToSource
      :: (MonadIO m)
      => MVar a
      -> ConduitT () a m ()
    mvarToSource mvar = do
      liftIO (takeMVar mvar) >>= yield
      mvarToSource mvar

    acceptLoop :: (Binary i) => Socket -> MVar i -> IO ()
    acceptLoop so mvar = do
      (conn, _) <- accept so
      void . forkIO $ feed (runGetIncremental get) conn mvar
      acceptLoop so mvar

    feed
      :: (Binary i)
      => Decoder i
      -> Socket
      -> MVar i
      -> IO ()
    feed (Done leftover _ i) conn mvar = do
      putMVar mvar i
      feed (runGetIncremental get `pushChunk` leftover) conn mvar
    feed (Partial k) conn mvar = do
      bytes <- recv conn 4096
      when (BS.null bytes) (fail "Socket closed by peer.")
      feed (k (Just bytes)) conn mvar
    feed (Fail _ _ err) _conn _chan =
      fail $ "Socket crashed. Decoding error: " ++ show err


{- |
  Open an "egress" socket, which is a socket that sends a stream of messages
  without receiving responses.
-}
openEgress
  :: ( Binary o
     , MonadFail m
     , MonadIO m
     , MonadThrow m
     )
  => AddressDescription
  -> ConduitT o Void m ()
openEgress addr = do
  so <- connectSocket =<< resolveAddr addr
  conduitEncode .| sinkSocket so


{- | Guess the family of a `SockAddr`. -}
fam :: SockAddr -> Family
fam SockAddrInet {} = AF_INET
fam SockAddrInet6 {} = AF_INET6
fam SockAddrUnix {} = AF_UNIX


{- | Resolve a host:port address into a 'SockAddr'. -}
resolveAddr :: (MonadIO m, MonadFail m) => AddressDescription -> m SockAddr
resolveAddr addr = do
  (host, port) <- parseAddr addr
  liftIO (getAddrInfo Nothing (Just host) (Just port)) >>= \case
    [] -> fail "Address not found: (host, port)"
    sa:_ -> return (addrAddress sa)


{- | Parse a host:port address. -}
parseAddr :: (MonadFail m) => AddressDescription -> m (HostName, ServiceName)
parseAddr addr =
    case parse parser "$" (unAddressDescription addr) of
      Left err -> fail (show err)
      Right (host, port) -> return (host, port)
  where
    parser :: Parsec Void Text (HostName, ServiceName)
    parser = do
      host <- M.try ipv6 <|> ipv4
      void $ char ':'
      port <- many (oneOf ("0123456789" :: String))
      eof
      return (host, port)

    ipv6 :: Parsec Void Text HostName
    ipv6 = do
      void $ char '['
      host <- many (satisfy (/= ']'))
      void $ char ']'
      return host

    ipv4 :: Parsec Void Text HostName
    ipv4 = many (satisfy (/= ':'))


{- | Create a connected socket. -}
connectSocket :: (MonadIO m) => SockAddr -> m Socket
connectSocket addr = liftIO $
  {-
    Make sure to close the socket if an error happens during
    connection, because if not, we could easily run out of file
    descriptors in the case where we rapidly try to send thousands
    of message to the same peer, which could happen when one object
    is a hotspot.
  -}
  bracketOnError
    (socket (fam addr) Stream defaultProtocol)
    close
    (\so -> connect so addr >> return so)


{- | Create a listening socket. -}
listenSocket :: (MonadIO m) => SockAddr -> m Socket
listenSocket addr = liftIO $ do
  so <- socket (fam addr) Stream defaultProtocol
  setSocketOption so ReuseAddr 1
  bind so addr
  listen so 5
  return so


{- |
  Open a "server" socket, which is a socket that accepts incoming requests
  and provides a way to respond to those requests.
-}
openServer
  :: ( Binary request
     , Binary response
     , MonadFail m
     , MonadLoggerIO m
     , Show request
     , Show response
     )
  => AddressDescription
  -> Maybe (IO ServerParams)
  -> ConduitT Void (request, response -> m Responded) m ()
openServer bindAddr tls = do
    so <- listenSocket =<< resolveAddr bindAddr
    requestChan <- liftIO newChan
    logging <- askLoggerIO
    void . liftIO . forkIO . (`runLoggingT` logging) $ acceptLoop so requestChan
    chanToSource requestChan
  where
    acceptLoop
      :: ( Binary i
         , Binary o
         , MonadIO m
         , MonadLoggerIO n
         , Show i
         , Show o
         )
      => Socket
      -> Chan (i, o -> m Responded)
      -> n ()
    acceptLoop so requestChan = do
      (conn, ra) <- liftIO (accept so)
      (inputSource, outputSink) <- prepareConnection conn
      logDebug $ "New connection: " <>  showt ra
      responseChan <- liftIO newChan
      logging <- askLoggerIO
      rtid <-
        liftIO
        . forkIO
        . (`runLoggingT` logging)
        $ responderThread responseChan outputSink
      void . liftIO . forkIO . (`runLoggingT` logging) $ do
        result <- try $ runConduit (
            pure ()
            .| transPipe liftIO inputSource
            .| conduitDecode
            .| awaitForever (\req@Request {messageId, payload} -> do
                logDebug $ showt ra <> ": Got request: " <> showt req
                start <- liftIO getCurrentTime
                yield (
                    payload,
                    \res -> do
                      liftIO . writeChan responseChan . Response messageId $ res
                      end <- liftIO getCurrentTime
                      liftIO . (`runLoggingT` logging) . logDebug
                        $ showt ra <> ": Responded to " <> showt messageId <> " in ("
                        <> showt (diffUTCTime end start) <> ")"
                      pure Responded
                  )
              )
            .| CL.mapM_ (liftIO . writeChan requestChan)
          )
        case result of
          Left err -> liftIO $ throwTo rtid (err :: SomeException)
          Right () -> return ()
        logDebug $ "Closed connection: " <>  showt ra
      acceptLoop so requestChan

    prepareConnection
      :: (MonadIO m)
      => Socket
      -> m (ConduitT Void ByteString IO (), ConduitT ByteString Void IO ())
    prepareConnection conn =
        case tls of
          Nothing -> pure (sourceSocket conn, sinkSocket conn)
          Just getParams ->
            liftIO $ do
              ctx <- contextNew conn =<< getParams
              handshake ctx
              pure (input ctx, output ctx)
      where
        output :: Context -> ConduitT ByteString Void IO ()
        output ctx = awaitForever (sendData ctx . BSL.fromStrict)

        input :: Context -> ConduitT Void ByteString IO ()
        input ctx = do
          bytes <- recvData ctx
          if BS.null bytes then
            pure ()
          else do
            yield bytes
            input ctx

    responderThread :: (
          Binary p,
          MonadLoggerIO m,
          MonadThrow m,
          Show p
        )
      => Chan (Response p)
      -> ConduitT ByteString Void IO ()
      -> m ()
    responderThread chan outputSink = runConduit (
        pure ()
        .| chanToSource chan
        .| awaitForever (\res@Response {responseTo, response} -> do
            logDebug
              $ "Responding to " <> showt responseTo
              <> " with: " <> showt response
            yield res
          )
        .| conduitEncode
        .| transPipe liftIO outputSink
      )


{- |
  Connect to a server. Returns a function in 'MonadIO' that can be used
  to submit requests to (and returns the corresponding response from)
  the server.
-}
connectServer
  :: ( Binary request
     , Binary response
     , MonadIO m
     , MonadLoggerIO n
     , Show response
     )
  => AddressDescription
  -> Maybe ClientParams
  -> n (request -> m response)
connectServer addr tls = do
    logging <- askLoggerIO
    liftIO $ do
      so <- connectSocket =<< resolveAddr addr
      state <- atomically (newTVar ClientState {
          csAlive = True,
          csResponders = Map.empty,
          csMessageId = minBound,
          csMessageQueue = []
        })
      (send, reqSource) <- prepareConnection so
      void . forkIO $ (`runLoggingT` logging) (requestThread send state)
      void . forkIO $ (`runLoggingT` logging) (responseThread reqSource state)
      return (\i -> liftIO $ do
          mvar <- newEmptyMVar
          join . atomically $
            readTVar state >>= \case
              ClientState {csAlive = False} -> return $
                throwM (userError "Server connection died.")
              s@ClientState {csMessageQueue} -> do
                writeTVar state s {
                    csMessageQueue = csMessageQueue <> [(i, putMVar mvar)]
                  }
                return (takeMVar mvar)
        )
  where
    {- |
      Returns the (output, input) communication channels, either prepared
      for TSL or not depending on the configuration.
    -}
    prepareConnection
      :: (MonadIO m, MonadIO f)
      => Socket
      -> f (BSL.ByteString -> IO (), ConduitT Void ByteString m ())
    prepareConnection so =
        case tls of
          Nothing -> pure (sendAll so, sourceSocket so)
          Just params -> do
            ctx <- contextNew so params
            handshake ctx
            pure (send ctx, reqSource ctx)
      where
        send :: Context -> BSL.ByteString -> IO ()
        send = sendData

        reqSource :: (MonadIO m) => Context -> ConduitT Void ByteString m ()
        reqSource ctx = do
          bytes <- recvData ctx
          if BS.null bytes
            then pure ()
            else do
              yield bytes
              reqSource ctx

    {- | Receive requests and send them to the server. -}
    requestThread :: (
          Binary i,
          MonadCatch m,
          MonadLoggerIO m
        )
      => (BSL.ByteString -> IO ())
      -> TVar (ClientState i o)
      -> m ()
    requestThread send state =
      join . liftIO . atomically $
        readTVar state >>= \case
          ClientState {csAlive = False} -> pure (pure ())
          ClientState {csMessageQueue = []} -> retry
          s@ClientState {
                csMessageQueue = (m, r):remaining,
                csResponders,
                csMessageId
              }
            -> do
              writeTVar state s {
                  csMessageQueue = remaining,
                  csResponders = Map.insert csMessageId r csResponders,
                  csMessageId = succ csMessageId
                }
              pure $ do
                liftIO $ send (encode (Request csMessageId m))
                requestThread send state

    {- |
      Receive responses from the server and send then them back to the
      client responder.
    -}
    responseThread :: (
          Binary o,
          MonadLoggerIO m,
          MonadCatch m,
          Show o
        )
      => ConduitT Void ByteString m ()
      -> TVar (ClientState i o)
      -> m ()
    responseThread reqSource state = do
      (try . runConduit) (
          pure ()
          .| reqSource
          .| conduitDecode
          .| CL.mapM_ (\r@Response {responseTo, response} ->
              join . liftIO . atomically $
                readTVar state >>= \ ClientState {csResponders} ->
                  case Map.lookup responseTo csResponders of
                    Nothing -> return $
                      logWarn $ "Unexpected server response: " <> showt r
                    Just respond -> return $ liftIO (respond response)
            )
        ) >>= \case
          Left err ->
            logError
              $ "Socket receive error: "
              <> showt (err :: SomeException)
          Right () -> return ()
      join . liftIO . atomically $
        readTVar state >>= \s@ClientState {csResponders, csMessageQueue} -> do
          writeTVar state s {csAlive = False}
          return . liftIO . sequence_ $ [
              r (throw (userError "Remote connection died."))
              | r <-
                  fmap snd (Map.toList csResponders)
                  <> fmap snd csMessageQueue
            ]


{- | A server endpoint configuration. -}
data Endpoint = Endpoint {
    bindAddr :: AddressDescription,
         tls :: Maybe (IO ServerParams)
  }
  deriving stock (Generic)


{- | Response to a request. -}
data Response p = Response {
    responseTo :: MessageId,
      response :: p
  }
  deriving stock (Generic, Show)
instance (Binary p) => Binary (Response p)


{- |
  A description of a socket address on which a socket is or should be
  listening. Supports both IPv4 and IPv6.

  Examples:

  > AddressDescription "[::1]:80" -- IPv6 localhost, port 80
  > AddressDescription "127.0.0.1:80" -- IPv4 localhost, port 80
  > AddressDescription "somehost:80" -- IPv4 or IPv6 (depending on what name resolution returns), port 80
-}
newtype AddressDescription = AddressDescription {
    unAddressDescription :: Text
  }
  deriving stock (Generic)
  deriving newtype
    ( Binary
    , Eq
    , FromJSON
    , FromJSONKey
    , IsString
    , Monoid
    , Ord
    , Semigroup
    , ToJSON
    , ToJSONKey
    )
instance Show AddressDescription where
  show = T.unpack . unAddressDescription


{- | Client connection state. -}
data ClientState i o = ClientState {
    csAlive :: Bool,
    csResponders :: Map MessageId (o -> IO ()),
    csMessageId :: MessageId,
    csMessageQueue :: [(i, o -> IO ())]
  }


{- | A Request message type. -}
data Request p = Request {
    messageId :: MessageId,
      payload :: p
  }
  deriving stock (Generic, Show)
instance (Binary p) => Binary (Request p)


{- | A message identifier. -}
newtype MessageId = MessageId {
    _unMessageId :: Word32
  }
  deriving newtype (Binary, Num, Bounded, Eq, Ord, Show, Enum)


{- | Construct a coundiut source by reading forever from a 'Chan'. -}
chanToSource :: (MonadIO m) => Chan a -> ConduitT Void a m ()
chanToSource chan = do
  yield =<< liftIO (readChan chan)
  chanToSource chan


{- |
  Proof that a response function was called on the server. Mainly
  useful for including in a type signature somewhere in your server
  implementation to help ensure that you actually responded to the
  request in all cases.
-}
data Responded = Responded


