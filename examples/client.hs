{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.Logger (runStdoutLoggingT)
import Conduit ((.|), awaitForever, runConduit)
import Control.Monad.Logger (runStdoutLoggingT)
import Data.Binary (Binary)
import OM.Socket

{- | The requests accepted by the server. -}
newtype Request = EchoRequest String
  deriving newtype (Binary, Show)


{- | The response sent back to the client. -}
newtype Responsee = EchoResponse String
  deriving newtype (Binary, Show)


{- | Simple echo resposne server. -}
main :: IO ()
main = do
  client <-
    runStdoutLoggingT $
      connectServer "localhost:9000" Nothing
  putStrLn =<< client (EchoRequest "hello")
  putStrLn =<< client (EchoRequest "world")


