{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Socket utilities. -}
module OM.Socket (
  openServer,
  connectServer,
  openIngress,
  openEgress,
  resolveAddr,
) where


import Control.Applicative ((<|>))
import Control.Concurrent (throwTo, Chan, newChan, writeChan, forkIO,
  readChan, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, newTVar, atomically, readTVar,
  writeTVar, retry)
import Control.Exception (SomeException, bracketOnError, throw)
import Control.Monad (void, join)
import Control.Monad.Catch (try, MonadCatch, throwM, MonadThrow)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Logger (logWarn, MonadLoggerIO, askLoggerIO,
  runLoggingT, logError, logDebug, logInfo)
import Data.Binary (Binary, encode)
import Data.Conduit (Source, awaitForever, yield, runConduit, (.|),
  Sink, transPipe)
import Data.Conduit.Network (sourceSocket, sinkSocket)
import Data.Conduit.Serialization.Binary (conduitDecode, conduitEncode)
import Data.Map (Map)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import Network.Socket (Socket, socket, SocketType(Stream),
  defaultProtocol, setSocketOption, SocketOption(ReuseAddr), bind,
  listen, accept, SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix,
  SockAddrCan), Family(AF_INET, AF_INET6, AF_UNIX, AF_CAN), close,
  connect, getAddrInfo, addrAddress, HostName, ServiceName)
import Network.Socket.ByteString.Lazy (sendAll)
import Text.Megaparsec (parse, char, Parsec, Dec, many, satisfy, oneOf, eof)
import qualified Data.Conduit.List as CL
import qualified Data.Map as Map
import qualified Data.Text as T
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
  => SockAddr
  -> Source m (i, o -> m ())
openServer addr = do
    so <- listenSocket addr
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
openIngress :: (
      Binary i,
      MonadIO m
    )
  => SockAddr
  -> Source m i
openIngress addr = do
    so <- listenSocket addr
    inChan <- liftIO newChan
    void . liftIO . forkIO $ acceptLoop so inChan
    chanToSource inChan
  where
    acceptLoop :: (
          Binary i,
          MonadIO m
        )
      => Socket
      -> Chan i
      -> m ()
    acceptLoop so requestChan = do
      (conn, _) <- liftIO (accept so)
      void . liftIO . forkIO . runConduit $
        sourceSocket conn
        .| conduitDecode
        .| CL.mapM_ (liftIO . writeChan requestChan)
      acceptLoop so requestChan


{- |
  Open an "egress" socket, which is a socket that sends a stream of messages
  without receiving responses.
-}
openEgress :: (
      Binary o,
      MonadIO m,
      MonadThrow m
    )
  => SockAddr
  -> Sink o m ()
openEgress addr = do
  so <- connectSocket addr
  conduitEncode .| sinkSocket so


{- | Connect to a server. -}
connectServer :: (
      Binary i,
      Binary o,
      MonadIO m,
      MonadLoggerIO n,
      Show o
    )
  => SockAddr
  -> n (i -> m o)
connectServer addr = do
    logging <- askLoggerIO
    liftIO $ do
      so <- connectSocket addr
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


{- | Parse host:port address. -}
resolveAddr :: (MonadIO m) => Text -> m SockAddr
resolveAddr str = 
  case parse parser "$" str of
    Left err -> fail (show err)
    Right (host, port) ->
      liftIO (getAddrInfo Nothing (Just host) (Just port)) >>= \case
        [] -> fail "Address not found: (host, port)"
        sa:_ -> return (addrAddress sa)
  where
    parser :: Parsec Dec Text (HostName, ServiceName)
    parser = do
      host <- M.try ipv6 <|> ipv4
      void $ char ':'
      port <- many (oneOf ("0123456789" :: String))
      eof
      return (host, port)

    ipv6 :: Parsec Dec Text HostName
    ipv6 = do
      void $ char '['
      host <- many (satisfy (/= ']'))
      void $ char ']'
      return host

    ipv4 :: Parsec Dec Text HostName
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


{- | Like `show`, but for 'Text'. -}
showt :: (Show a) => a -> Text
showt a = T.pack (show a)


