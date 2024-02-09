# om-socket

- [Overview](#overview)
- [Examples](#examples)
    - [Open an Ingress service](#open-an-ingress-service)
    - [Open an Egress connection](#open-an-egress-connection)
    - [Start a server process](#start-a-server-process)
    - [Connect a client to a server](#connect-a-client-to-a-server)

## Overview

This package provides some utilities for Haskell programs to communicate raw
binary messages over the network. It includes:

* Opening an "Ingress" service.
  It provides a way for a program to open a socket and accept a
  stream of messages without responding to any of them.

* Open an "Egress" socket.
  It provides a way to connect to an "Ingress" service and dump a stream of
  messages to it.

* Open a bidirectional "server".
  It provides a way to open a "server", which provides your program with a
  stream of requests paired with a way to respond to each request. Responses are
  allowed to be supplied in an order different than that from which the
  corresponding requests were received.

* Open a client to a bidirectional "server".
  It provides a way to connect to an open server and provides a convenient
  `(request -> IO response)` interface to talk to the server.

## Examples

### Open an Ingress service

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Ingress (main) where

import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Binary (Binary)
import Data.Function ((&))
import GHC.Generics (Generic)
import OM.Fork (runRace)
import OM.Socket (openIngress)
import Prelude (($), IO, putStrLn)
import qualified Streaming.Prelude as Stream

{- |
  The messages that arrive on the socket.

  This type would typically be shared by both the Ingress and Egress side,
  or at least the binary encoding must be identical.
-}
data Msg
  = A
  | B
  deriving stock (Generic)
  deriving anyclass (Binary)


main :: IO ()
main =
  runRace $
    openIngress "localhost:9000"
    & Stream.mapM_
       (\msg ->
           case msg of
             A -> liftIO $ putStrLn "Got A"
             B -> liftIO $ putStrLn "Got B"
         )
```

  
### Open an Egress connection

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Egress (main) where

import Data.Binary (Binary)
import Data.Function ((&))
import GHC.Generics (Generic)
import OM.Socket (openEgress)
import Prelude (IO)
import qualified Streaming.Prelude as Stream

{- |
  The messages that arrive on the socket.

  This type would typically be shared between the client and the server,
  or at least the binary representation must be identical (as, for
  example, if the client is not written in Haskell).
-}
data Msg
  = A
  | B
  deriving stock (Generic)
  deriving anyclass (Binary)


main :: IO ()
main =
  Stream.each [A, B, B, A, A, A, B]
  & openEgress "localhost:9000"

```

### Start a server process


```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}


module Server (main) where

import Control.Monad.Logger (runStdoutLoggingT)
import Data.Binary (Binary)
import Data.Function ((&))
import OM.Fork (runRace)
import OM.Socket (openServer)
import Prelude (Maybe(Nothing), ($), IO, Show, String)
import qualified Streaming.Prelude as Stream


{-|
  The requests accepted by the server.

  This type would typically be shared between client and server.
-}
newtype Request = EchoRequest String
  deriving newtype (Binary, Show)


{-|
  The response sent back to the client.

  This type would typically be shared between client and server.
-}
newtype Responsee = EchoResponse String
  deriving newtype (Binary, Show)


{-| Simple echo resposne server. -}
main :: IO ()
main =
  runRace
  $ runStdoutLoggingT
  $ (
      openServer "localhost:9000" Nothing
      & Stream.mapM_
          (\ (EchoRequest str, respond) ->
            {-
              You don't necessarily have to respond right away if
              you don't want to. You can cache the responder away in
              some state and get back to it at some later time if you
              like. `openServer` and `connectServer` have a mechnamism
              for handling out of order responses.
            -}
            respond (EchoResponse str)
          )
    )
```

### Connect a client to a server

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Client (main) where

import Control.Monad.Logger (runStdoutLoggingT)
import Data.Binary (Binary)
import OM.Socket (connectServer)

{-|
  The requests accepted by the server.

  This would typically need to be shared between the client and the
  server. Certainly the binary encoding must be identical.
-}
newtype Request = EchoRequest String
  deriving newtype (Binary, Show)


{-|
  The response sent back to the client.

  Likewise, this would be shared between client and server.
-}
newtype Responsee = EchoResponse String
  deriving newtype (Binary, Show)


{-| Simple echo resposne client. -}
main :: IO ()
main = do
  client <-
    runStdoutLoggingT $
      connectServer "localhost:9000" Nothing
  putStrLn =<< client (EchoRequest "hello")
  putStrLn =<< client (EchoRequest "world")
```
