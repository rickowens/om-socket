{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main (main) where

import Control.Monad.Logger (runStdoutLoggingT)
import Data.Binary (Binary)
import Data.Function ((&))
import OM.Fork (runRace)
import OM.Socket (openServer)
import Prelude (Maybe(Nothing), ($), IO, Show, String, pure)
import qualified Streaming.Prelude as Stream

{- | The requests accepted by the server. -}
newtype Request = EchoRequest String
  deriving newtype (Binary, Show)


{- | The response sent back to the client. -}
newtype Responsee = EchoResponse String
  deriving newtype (Binary, Show)


{- | Simple echo resposne server. -}
main :: IO ()
main = do
  {-
    Don't actually call server, because the "test" we are using to make
    sure this compiles will never finish running!
  -}
  -- server
  pure ()


server :: IO ()
server =
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


