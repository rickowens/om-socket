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


