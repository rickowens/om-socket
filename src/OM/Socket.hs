{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Socket utilities. -}
module OM.Socket (
  AddressDescription(..),
  openServer,
  connectServer,
  openIngress,
  openEgress,
  resolveAddr,
  loadBalanced,
  loadBalancedDiscovery,
  Endpoint(..),
  TlsConfig(..),
  setWarpEndpoint,
) where


import Control.Applicative ((<|>))
import Control.Concurrent (throwTo, Chan, newChan, writeChan, forkIO,
  readChan, newEmptyMVar, putMVar, takeMVar, MVar)
import Control.Concurrent.LoadDistribution (evenlyDistributed,
  withResource)
import Control.Concurrent.STM (TVar, newTVar, atomically, readTVar,
  writeTVar, retry, newTVar, modifyTVar)
import Control.Exception (SomeException, bracketOnError, throw)
import Control.Monad (void, join, when)
import Control.Monad.Catch (try, MonadCatch, throwM, MonadThrow)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Logger (logWarn, MonadLoggerIO, askLoggerIO,
  runLoggingT, logError, logDebug, logInfo)
import Data.Aeson (FromJSON)
import Data.Binary (Binary, encode, get)
import Data.Binary.Get (Decoder(Fail, Partial, Done), runGetIncremental,
  pushChunk)
import Data.Conduit (Source, awaitForever, yield, runConduit, (.|),
  Sink, transPipe)
import Data.Conduit.Network (sourceSocket, sinkSocket)
import Data.Conduit.Serialization.Binary (conduitDecode, conduitEncode)
import Data.Map (Map)
import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import Data.Set (Set, (\\))
import Data.String (fromString, IsString)
import Data.Text (Text, stripPrefix)
import Data.Time (getCurrentTime, diffUTCTime)
import Data.Void (Void)
import Data.Word (Word32)
import Distribution.Version (VersionRange)
import GHC.Generics (Generic)
import Network.Legion.Discovery.Client (unName, unServiceAddr, Name,
  Discovery)
import Network.Socket (Socket, socket, SocketType(Stream),
  defaultProtocol, setSocketOption, SocketOption(ReuseAddr), bind,
  listen, accept, SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix,
  SockAddrCan), Family(AF_INET, AF_INET6, AF_UNIX, AF_CAN), close,
  connect, getAddrInfo, addrAddress, HostName, ServiceName)
import Network.Socket.ByteString (recv)
import Network.Socket.ByteString.Lazy (sendAll)
import Safe (readMay)
import Text.Megaparsec (parse, Parsec, many, eof)
import Text.Megaparsec.Char (char, satisfy, oneOf)
import qualified Data.ByteString as BS
import qualified Data.Conduit.List as CL
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Network.Legion.Discovery.Client as D
import qualified Network.Wai.Handler.Warp as Warp
import qualified Text.Megaparsec as M


{- |
  Open a "server" socket, which is a socket that accepts incoming requests
  and provides a way to respond to those requests.
-}
openServer :: (
      Binary i,
      Binary o,
      MonadIO m,
      MonadLoggerIO m,
      Show i,
      Show o
    )
  => Endpoint
  -> Source m (i, o -> m ())
openServer Endpoint {tls = Just _} = fail "openServer: tls not yet supported."
openServer Endpoint {bindAddr} = do
    so <- listenSocket =<< resolveAddr bindAddr
    requestChan <- liftIO newChan
    logging <- askLoggerIO
    void . liftIO . forkIO . (`runLoggingT` logging) $ acceptLoop so requestChan
    chanToSource requestChan
  where
    acceptLoop :: (
          Binary i,
          Binary o,
          MonadIO m,
          MonadIO n,
          MonadLoggerIO n,
          Show i,
          Show o
        )
      => Socket
      -> Chan (i, o -> m ())
      -> n ()
    acceptLoop so requestChan = do
      (conn, ra) <- liftIO (accept so)
      $(logDebug) . T.pack $ "New connection: " ++  show ra
      responseChan <- liftIO newChan
      logging <- askLoggerIO
      rtid <-
        liftIO
        . forkIO
        . (`runLoggingT` logging)
        $ responderThread responseChan conn
      void . liftIO . forkIO . (`runLoggingT` logging) $ do
        result <- try $ runConduit (
            transPipe liftIO (sourceSocket conn)
            .| conduitDecode
            .| awaitForever (\req@Request {messageId, payload} -> do
                $(logDebug) . T.pack $ "Got request: " ++ show req
                start <- liftIO getCurrentTime
                yield (
                    payload,
                    \res -> do
                      liftIO . writeChan responseChan . Response messageId $ res
                      end <- liftIO getCurrentTime
                      liftIO . (`runLoggingT` logging) . $(logInfo)
                        $ "Responded to " <> showt messageId <> " in ("
                        <> showt (diffUTCTime end start) <> ")"
                  )
              )
            .| CL.mapM_ (liftIO . writeChan requestChan)
          )
        case result of
          Left err -> liftIO $ throwTo rtid (err :: SomeException)
          Right () -> return ()
        $(logDebug) . T.pack $ "Closed connection: " ++  show ra
      acceptLoop so requestChan

    responderThread :: (
          Binary p,
          MonadLoggerIO m,
          MonadThrow m,
          Show p
        )
      => Chan (Response p)
      -> Socket
      -> m ()
    responderThread chan conn = runConduit (
        chanToSource chan
        .| awaitForever (\res@Response {responseTo, response} -> do
            $(logDebug) . T.pack
              $ "Responding to " ++ show responseTo
              ++ " with: " ++ show response
            yield res
          )
        .| conduitEncode
        .| sinkSocket conn
      )


{- |
  Opens an "ingress" socket, which is a socket that accepts a stream of
  messages without responding.
-}
openIngress :: (Binary i, MonadIO m)
  => Endpoint
  -> Source m i
openIngress Endpoint {tls = Just _} = fail "openIngress: tls not yet supported"
openIngress Endpoint {bindAddr} = do
    so <- listenSocket =<< resolveAddr bindAddr
    mvar <- liftIO newEmptyMVar
    void . liftIO . forkIO $ acceptLoop so mvar
    mvarToSource mvar
  where
    mvarToSource :: (MonadIO m) => MVar a -> Source m a
    mvarToSource mvar = do
      liftIO (takeMVar mvar) >>= yield
      mvarToSource mvar

    acceptLoop :: (Binary i) => Socket -> MVar i -> IO ()
    acceptLoop so mvar = do
      (conn, _) <- accept so
      void . forkIO $ feed (runGetIncremental get) conn mvar
      acceptLoop so mvar

    feed :: (Binary i) => Decoder i -> Socket -> MVar i -> IO ()

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
openEgress :: (
      Binary o,
      MonadIO m,
      MonadThrow m
    )
  => AddressDescription
  -> Sink o m ()
openEgress addr = do
  so <- connectSocket =<< resolveAddr addr
  conduitEncode .| sinkSocket so


{- | Connect to a server. -}
connectServer :: (
      Binary i,
      Binary o,
      MonadIO m,
      MonadLoggerIO n,
      Show o
    )
  => AddressDescription
  -> n (i -> m o)
connectServer addr = do
    logging <- askLoggerIO
    liftIO $ do
      so <- connectSocket =<< resolveAddr addr
      state <- atomically (newTVar ClientState {
          csAlive = True,
          csConn = so,
          csResponders = Map.empty,
          csMessageId = minBound,
          csMessageQueue = []
        })
      void . forkIO $ (`runLoggingT` logging) (requestThread state)
      void . forkIO $ (`runLoggingT` logging) (responseThread state)
      return (\i -> liftIO $ do
          mvar <- newEmptyMVar
          join . atomically $
            readTVar state >>= \case
              ClientState {csAlive = False} -> return $
                throwM (userError "Server connection died.")
              s@ClientState {csMessageQueue} -> do
                writeTVar state s {
                    csMessageQueue = csMessageQueue ++ [(i, putMVar mvar)]
                  }
                return (takeMVar mvar)
        )
  where
    {- | Receive requests and send them to the server. -}
    requestThread :: (
          Binary i,
          MonadCatch m,
          MonadLoggerIO m
        )
      => TVar (ClientState i o)
      -> m ()
    requestThread state = join . liftIO . atomically $
      readTVar state >>= \case
        ClientState {csAlive = False} -> return (return ())
        ClientState {csMessageQueue = []} -> retry
        s@ClientState {
              csMessageQueue = (m, r):remaining,
              csResponders,
              csMessageId,
              csConn
            }
          -> do
            writeTVar state s {
                csMessageQueue = remaining,
                csResponders = Map.insert csMessageId r csResponders,
                csMessageId = succ csMessageId
              }
            return $ do
              liftIO $ sendAll csConn (encode (Request csMessageId m))
              requestThread state

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
      => TVar (ClientState i o)
      -> m ()
    responseThread state = do
      so <- liftIO (atomically (csConn <$> readTVar state))
      (try . runConduit) (
          sourceSocket so
          .| conduitDecode
          .| CL.mapM_ (\r@Response {responseTo, response} ->
              join . liftIO . atomically $
                readTVar state >>= \ ClientState {csResponders} ->
                  case Map.lookup responseTo csResponders of
                    Nothing -> return $
                      $(logWarn) . T.pack
                        $ "Unexpected server response: " ++ show r
                    Just respond -> return $ liftIO (respond response)
            )
        ) >>= \case
          Left err ->
            $(logError) . T.pack
              $ "Socket receive error: "
              ++ show (err :: SomeException)
          Right () -> return ()
      join . liftIO . atomically $
        readTVar state >>= \s@ClientState {csResponders, csMessageQueue} -> do
          writeTVar state s {csAlive = False}
          return . liftIO . sequence_ $ [
              r (throw (userError "Remote connection died."))
              | r <-
                  fmap snd (Map.toList csResponders)
                  ++ fmap snd csMessageQueue
            ]


{- | Client connection state. -}
data ClientState i o = ClientState {
    csAlive :: Bool,
    csConn :: Socket,
    csResponders :: Map MessageId (o -> IO ()),
    csMessageId :: MessageId,
    csMessageQueue :: [(i, o -> IO ())]
  }


{- | A Request message type. -}
data Request p = Request {
    messageId :: MessageId,
      payload :: p
  }
  deriving (Generic, Show)
instance (Binary p) => Binary (Request p)


{- | Response to a request. -}
data Response p = Response {
    responseTo :: MessageId,
      response :: p
  }
  deriving (Generic, Show)
instance (Binary p) => Binary (Response p)


{- | A message identifier. -}
newtype MessageId = MessageId {
    _unMessageId :: Word32
  }
  deriving (Binary, Num, Bounded, Eq, Ord, Show, Enum)


{- | Guess the family of a `SockAddr`. -}
fam :: SockAddr -> Family
fam SockAddrInet {} = AF_INET
fam SockAddrInet6 {} = AF_INET6
fam SockAddrUnix {} = AF_UNIX
fam SockAddrCan {} = AF_CAN


{- | Construct a coundiut source by reading forever from a 'Chan'. -}
chanToSource :: (MonadIO m) => Chan a -> Source m a
chanToSource chan = do
  yield =<< liftIO (readChan chan)
  chanToSource chan


{- | Resolve a host:port address into a 'SockAddr'. -}
resolveAddr :: (MonadIO m) => AddressDescription -> m SockAddr
resolveAddr addr = do
  (host, port) <- parseAddr addr
  liftIO (getAddrInfo Nothing (Just host) (Just port)) >>= \case
    [] -> fail "Address not found: (host, port)"
    sa:_ -> return (addrAddress sa)


{- | Parse a host:port address. -}
parseAddr :: (Monad m) => AddressDescription -> m (HostName, ServiceName)
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


{- | Create a load-balanced client by querying legion-discovery. -}
loadBalancedDiscovery :: (
      Binary i,
      Binary o,
      MonadLoggerIO m,
      Show o
    )
  => Name
  -> VersionRange
  -> Discovery
  -> IO (i -> m o)
loadBalancedDiscovery name versions discovery = 
    loadBalanced (unName name) source
  where
    source :: IO (Set AddressDescription)
    source = do
      addrs <- D.query name versions discovery
      return
        . Set.fromList
        . fmap AddressDescription
        . mapMaybe (unScheme . unServiceAddr)
        . Set.toList
        $ addrs

    unScheme :: Text -> Maybe Text
    unScheme = stripPrefix "tcp://"


{- | Create a load-balanced client. -}
loadBalanced :: (
      Binary i,
      Binary o,
      MonadLoggerIO m,
      Show o
    )
  => Text
  -> IO (Set AddressDescription)
  -> IO (i -> m o)
loadBalanced name source = do
  cacheT <- atomically (newTVar Nothing)
  connsT <- atomically (newTVar mempty)
  lastUpdatedT <- atomically . newTVar =<< getCurrentTime
  let
    fillCache :: IO (Set AddressDescription)
    fillCache = do
      vals <- source
      now <- getCurrentTime
      atomically $ do
        writeTVar cacheT (Just vals)
        conns <- readTVar connsT
        writeTVar connsT (foldr Map.delete conns (Map.keysSet conns \\ vals))
        writeTVar lastUpdatedT now
        return vals
    clearCache :: IO ()
    clearCache = atomically (writeTVar cacheT Nothing)

  lb <- evenlyDistributed (
      atomically (readTVar cacheT) >>= \case
        Nothing -> fillCache
        Just vals -> return vals
    )
  return $ \req -> do
    now <- liftIO getCurrentTime
    lastUpdated <- liftIO $ atomically (readTVar lastUpdatedT)
    when (diffUTCTime now lastUpdated > 10) . liftIO $
      atomically (writeTVar cacheT Nothing)
    logging <- askLoggerIO
    liftIO . withResource lb $ (`runLoggingT` logging) . \case
      Nothing -> fail $ "No backing instances of: " ++ T.unpack name
      Just sa -> do
        conn <- Map.lookup sa <$> liftIO (atomically (readTVar connsT)) >>= \case
          Nothing -> do
            conn <- connectServer sa
            liftIO $ atomically (modifyTVar connsT (Map.insert sa conn))
            return conn
          Just conn -> return conn
        try (conn req) >>= \case
          Left err -> do
            liftIO $ atomically (modifyTVar connsT (Map.delete sa))
            liftIO clearCache
            throwM (err :: SomeException)
          Right res -> return res


{- | Like `show`, but for 'Text'. -}
showt :: (Show a) => a -> Text
showt a = T.pack (show a)


{- | A server endpoint configuration. -}
data Endpoint = Endpoint {
    bindAddr :: AddressDescription,
         tls :: Maybe TlsConfig
  }
  deriving (Generic, Show, Eq, Ord)
instance FromJSON Endpoint


{- | Tls configuration. -}
data TlsConfig = TlsConfig {
    cert :: FilePath,
     key :: FilePath
  }
  deriving (Generic, Show, Eq, Ord)
instance FromJSON TlsConfig


{- |
  Sets the port and bind address in the warp settings to run on the indicated
  endpoint.
-}
setWarpEndpoint :: Endpoint -> Warp.Settings  -> Warp.Settings
setWarpEndpoint Endpoint {bindAddr, tls = Nothing} =
  case parseAddr bindAddr of
    Nothing -> error $ "Invalid address: " ++ show bindAddr
    Just (host, serviceAddress) ->
      case readMay serviceAddress of
        Nothing -> error $ "Invalid port: " ++ show serviceAddress
        Just port ->
          Warp.setHost (fromString host) . Warp.setPort port

setWarpEndpoint Endpoint {tls = Just _} = error "TLS not yet supported."


{- |
  A description of a socket address used to represent the address on
  which a socket is or should be listening. Used instead of a strict
  `SockAddr`. This adds a level of abstraction on top of raw `SockAddr`s,
  because some environments (such as docker) may introduce a level of
  network proxying or vitalization. Use a description instead of the raw
  address gives an opportunity for name resolution which can surmount
  the network-level translations.
-}
newtype AddressDescription = AddressDescription {
    unAddressDescription :: Text
  }
  deriving (IsString, Binary, Eq, Ord, FromJSON)
instance Show AddressDescription where
  show = T.unpack . unAddressDescription


