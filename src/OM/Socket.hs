{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Socket utilities. -}
module OM.Socket (
  AddressDescription(..),
  openIngress,
  openEgress,
  resolveAddr,
) where


import Control.Applicative ((<|>))
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracketOnError)
import Control.Monad (void, when)
import Control.Monad.Catch (MonadThrow)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Binary (Binary(get))
import Data.Binary.Get (Decoder(Done, Fail, Partial), pushChunk,
  runGetIncremental)
import Data.Conduit ((.|), ConduitT, yield)
import Data.Conduit.Network (sinkSocket)
import Data.Conduit.Serialization.Binary (conduitEncode)
import Data.String (IsString)
import Data.Text (Text)
import Data.Void (Void)
import GHC.Generics (Generic)
import Network.Socket (Family(AF_INET, AF_INET6, AF_UNIX),
  SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix),
  SocketOption(ReuseAddr), SocketType(Stream), HostName, ServiceName,
  Socket, accept, addrAddress, bind, close, connect, defaultProtocol,
  getAddrInfo, listen, setSocketOption, socket)
import Network.Socket.ByteString (recv)
import Text.Megaparsec (Parsec, eof, many, oneOf, parse, satisfy)
import Text.Megaparsec.Char (char)
import qualified Data.ByteString as BS (null)
import qualified Data.Text as T (unpack)
import qualified Text.Megaparsec as M (MonadParsec(try))


{- |
  Opens an "ingress" socket, which is a socket that accepts a stream of
  messages without responding.
-}
openIngress :: (Binary i, MonadIO m, MonadFail m)
  => AddressDescription
  -> ConduitT () i m ()
openIngress bindAddr = do
    so <- listenSocket =<< resolveAddr bindAddr
    mvar <- liftIO newEmptyMVar
    void . liftIO . forkIO $ acceptLoop so mvar
    mvarToSource mvar
  where
    mvarToSource :: (MonadIO m) => MVar a -> ConduitT () a m ()
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
  deriving stock (Generic)
  deriving newtype (
    IsString, Binary, Eq, Ord, FromJSON, ToJSON, FromJSONKey, ToJSONKey,
    Semigroup, Monoid
  )
instance Show AddressDescription where
  show = T.unpack . unAddressDescription


