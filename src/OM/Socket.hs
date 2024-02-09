{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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


import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar,
  retry, writeTVar)
import Control.Exception (SomeException, bracketOnError, throw)
import Control.Monad (when)
import Control.Monad.Catch (MonadThrow(throwM), MonadCatch, try)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Logger.CallStack (LoggingT(runLoggingT),
  MonadLoggerIO(askLoggerIO), NoLoggingT(runNoLoggingT), MonadLogger,
  logDebug, logError, logWarn)
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Binary (Binary(get), encode)
import Data.Binary.Get (Decoder(Done, Fail, Partial), pushChunk,
  runGetIncremental)
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Map (Map)
import Data.String (IsString)
import Data.Text (Text)
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
import OM.Fork (Race, race)
import OM.Show (showt)
import Prelude (Applicative(pure), Bool(False, True), Bounded(minBound),
  Either(Left, Right), Enum(succ), Eq((/=)), Functor(fmap), Maybe(Just,
  Nothing), Monad((>>), (>>=), return), MonadFail(fail), Monoid(mempty),
  Semigroup((<>)), Show(show), ($), (++), (.), (=<<), IO, Num, Ord,
  String, flip, snd, userError)
import Streaming (Alternative((<|>)), MFunctor(hoist), MonadIO(liftIO),
  MonadTrans(lift), Of, Stream, join, void)
import Streaming.Binary (decoded)
import Streaming.ByteString (ByteStream, reread)
import Text.Megaparsec (MonadParsec(eof), Parsec, many, oneOf, parse,
  satisfy)
import Text.Megaparsec.Char (char)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import qualified Text.Megaparsec as M


{-|
  Opens an "ingress" socket, which is a socket that accepts a stream
  of messages without responding. In particular, we listen on a socket,
  accepting new connections, an each connection concurrently reads its
  elements off the socket and pushes them onto the stream.
-}
openIngress
  :: forall i m never_returns.
     ( Binary i
     , MonadFail m
     , MonadIO m
     , Race
     )
  => AddressDescription
  -> Stream (Of i) m never_returns
openIngress bindAddr = do
    so <- listenSocket =<< resolveAddr bindAddr
    mvar <- liftIO newEmptyMVar
    liftIO
      . runNoLoggingT
      . race "ingress accept loop"
      . liftIO
      $ acceptLoop so mvar
    mvarToStream mvar
  where
    acceptLoop :: Socket -> MVar i -> IO ()
    acceptLoop so mvar = do
      (conn, _) <- accept so
      void . forkIO $ feed (runGetIncremental get) conn mvar
      acceptLoop so mvar

    feed
      :: Decoder i
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
     )
  => AddressDescription
  -> Stream (Of o) m r
  -> m r
openEgress addr stream = do
  so <- connectSocket =<< resolveAddr addr
  result <-
    S.mapM_
      (liftIO . sendAll so . encode)
      stream
  liftIO (close so)
  pure result


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
  :: forall request response m never_returns.
     ( Binary request
     , Binary response
     , MonadLogger m
     , MonadCatch m
     , MonadFail m
     , MonadUnliftIO m
     , Race
     )
  => AddressDescription
  -> Maybe (IO ServerParams)
  -> Stream (Of (request, response -> m Responded)) m never_returns
openServer bindAddr tls = do
    so <- listenSocket =<< resolveAddr bindAddr
    requestMVar <- liftIO newEmptyMVar
    lift
      . race "server accept loop"
      $ acceptLoop so requestMVar
    mvarToStream requestMVar
  where
    acceptLoop
      :: Socket
      -> MVar (request, response -> m Responded)
      -> m void
    acceptLoop so requestMVar = do
      (conn, ra) <- liftIO (accept so)
      logDebug $ "New connection: " <>  showt ra
      (input, send) <- prepareConnection conn
      void . liftIO . forkIO $ handleConnection input send requestMVar
      acceptLoop so requestMVar

    handleConnection
      :: ByteStream IO () {-^ raw bytes input from the socket -}
      -> (BSL.ByteString -> m ()) {-^ How to send bytes back -}
      -> MVar (request, response -> m Responded)
         {-^ how we stream (req, respond) tuples to the client code. -}
      -> IO ()
    handleConnection input send requestMVar =
        void $
          S.mapM_
            sendRequestToMVar
            (decoded input)
      where
        sendRequestToMVar :: Request request -> IO ()
        sendRequestToMVar Request { messageId , payload } =
          putMVar
            requestMVar
            ( payload
            , respond messageId
            )

        respond :: MessageId -> response -> m Responded
        respond responseTo response = do
          send . encode $ Response { responseTo , response }
          pure Responded

    {- Maybe make a TLS connection. -}
    prepareConnection
      :: Socket
      -> m
          ( ByteStream IO ()
          , BSL.ByteString -> m ()
          )
    prepareConnection conn =
      case tls of
        Nothing ->
          pure
            ( rereadNull
                (flip recv 4096)
                conn
            , liftIO . sendAll conn
            )
        Just getParams ->
          liftIO $ do
            ctx <- contextNew conn =<< getParams
            handshake ctx
            pure
              ( rereadNull recvData ctx
              , sendData ctx
              )


{- |
  Connect to a server. Returns a function in 'MonadIO' that can be used
  to submit requests to (and returns the corresponding response from)
  the server.
-}
connectServer
  :: forall n request m response.
     ( Binary request
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
      state <-
        newTVarIO
          ClientState
            { csServerAlive = True
            , csResponders = Map.empty
            , csMessageId = minBound
            , csRequestQueue = []
            }
      (send, responseSource) <- prepareConnection so
      void . forkIO $ (`runLoggingT` logging) (requestThread send state)
      void . forkIO $ (`runLoggingT` logging) (responseThread responseSource state)
      return (\i -> liftIO $ do
          mvar <- newEmptyMVar
          join . atomically $
            readTVar state >>= \case
              ClientState {csServerAlive = False} -> return $
                throwM (userError "Server connection died.")
              s@ClientState {csRequestQueue} -> do
                writeTVar state s {
                    csRequestQueue = csRequestQueue <> [(i, putMVar mvar)]
                  }
                return (takeMVar mvar)
        )
  where
    {- |
      Returns the (output, input) communication channels, either prepared
      for TSL or not depending on the configuration.
    -}
    prepareConnection
      :: Socket
      -> IO
           ( BSL.ByteString -> IO ()
           , ByteStream IO ()
           )
    prepareConnection so =
        case tls of
          Nothing ->
            pure
              ( sendAll so
              , rereadNull
                  (flip recv 4096)
                  so
              )
          Just params -> do
            ctx <- contextNew so params
            handshake ctx
            pure (send ctx, resSource ctx)
      where
        send :: Context -> BSL.ByteString -> IO ()
        send = sendData

        resSource
          :: Context
          -> ByteStream IO ()
        resSource = do
          rereadNull recvData

    {- |
      Receive requests from the client request function and send them
      to the server.
    -}
    requestThread
      :: (BSL.ByteString -> IO ())
      -> TVar (ClientState request response)
      -> LoggingT IO ()
    requestThread send state =
      join . liftIO . atomically $
        readTVar state >>= \case
          ClientState {csServerAlive = False} -> pure (pure ())
          ClientState {csRequestQueue = []} -> retry
          s@ClientState {
                csRequestQueue = (m, r):remaining,
                csResponders,
                csMessageId
              }
            -> do
              writeTVar state s {
                  csRequestQueue = remaining,
                  csResponders = Map.insert csMessageId r csResponders,
                  csMessageId = succ csMessageId
                }
              pure $ do
                liftIO $ send (encode (Request csMessageId m))
                requestThread send state

    {- |
      Receive responses from the server and send then them back to the
      client request function.
    -}
    responseThread
      :: ByteStream IO ()
      -> TVar (ClientState request response)
      -> LoggingT IO ()
    responseThread resSource stateT = do
        try
            (
              void $
                S.mapM_
                  handleResponse
                  (hoist liftIO (decoded resSource))
            )
          >>= \case
            Left err -> do
              logError
                $ "Socket receive error: "
                <> showt (err :: SomeException)
              throw err
            Right () ->
              pure ()
        closeClientState
      where
        closeClientState =
          join . liftIO . atomically $ do
            state <- readTVar stateT
            writeTVar stateT state
              { csServerAlive = False
              , csResponders = mempty
              , csRequestQueue = mempty
              }

            pure . traverse_ liftIO $
              [ respond (throw (userError "Remote connection died."))
              | respond <-
                  Map.elems (csResponders state)
                  <>  fmap snd (csRequestQueue state)
              ]

        handleResponse :: Response response -> LoggingT IO ()
        handleResponse
            responsePackage@Response
              { responseTo
              , response
              }
          = do
              join . lift . atomically $ do
                state <- readTVar stateT
                case deleteFind responseTo (csResponders state) of
                  Nothing ->
                    pure . logWarn $
                      "Unexpected server response: " <> showt responsePackage
                  Just (respond, newResponders) -> do
                    writeTVar stateT state {csResponders = newResponders}
                    pure . lift $ respond response


{- | A server endpoint configuration. -}
data Endpoint = Endpoint {
    bindAddr :: AddressDescription,
         tls :: Maybe (IO ServerParams)
  }
  deriving stock (Generic)


{- | Response to a request. -}
data Response p = Response
  { responseTo :: MessageId
  ,   response :: p
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
data ClientState i o = ClientState
  {  csServerAlive :: Bool
  ,   csResponders :: Map MessageId (o -> IO ())
  ,    csMessageId :: MessageId
  , csRequestQueue :: [(i, o -> IO ())]
  }


{- | A Request message type. -}
data Request p = Request
  { messageId :: MessageId
  ,   payload :: p
  }
  deriving stock (Generic, Show)
instance (Binary p) => Binary (Request p)


{- | A message identifier. -}
newtype MessageId = MessageId {
    _unMessageId :: Word32
  }
  deriving newtype (Binary, Num, Bounded, Eq, Ord, Show, Enum)


{- |
  Proof that a response function was called on the server. Mainly
  useful for including in a type signature somewhere in your server
  implementation to help ensure that you actually responded to the
  request in all cases.
-}
data Responded = Responded


mvarToStream
  :: (MonadIO m)
  => MVar i
  -> Stream (Of i) m never_returns
mvarToStream mvar = do
  liftIO (takeMVar mvar) >>= S.yield
  mvarToStream mvar


rereadNull
  :: (Monad m)
  => (c -> m ByteString)
  -> c
  -> ByteStream m ()
rereadNull f =
  reread
    (\c -> do
      bytes <- f c
      pure $ if BS.null bytes then Nothing else Just bytes
    )


{-|
  If the key exists in the map, delete it and return its value along
  with the new map.
-}
deleteFind
  :: (Ord k)
  => k
  -> Map k v
  -> Maybe (v, Map k v)
deleteFind key m =
  case Map.lookup key m of
    Nothing -> Nothing
    Just v ->
      Just (v, Map.delete key m)


