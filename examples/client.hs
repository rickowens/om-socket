{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.Logger (runStdoutLoggingT)
import Data.Binary (Binary)
import OM.Socket (connectServer)

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
    Don't actually call sendRequests, because there is no server running to
    connect to, which will cause an error, which will cause the test to fail.
  -}
  -- sendRequests
  pure ()


sendRequests :: IO ()
sendRequests = do
  client <-
    runStdoutLoggingT $
      connectServer "localhost:9000" Nothing
  putStrLn =<< client (EchoRequest "hello")
  putStrLn =<< client (EchoRequest "world")


