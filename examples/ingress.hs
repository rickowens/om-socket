{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main (main) where

import Conduit ((.|), awaitForever, runConduit)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Binary (Binary)
import GHC.Generics (Generic)
import OM.Socket (openIngress)

{- | The messages that arrive on the socket. -}
data Msg
  = A
  | B
  deriving stock (Generic)
  deriving anyclass (Binary)

main :: IO ()
main =
  {-
    Don't actually call serveForever, because the "test" we are using to make
    sure this compiles will never finish running!
  -}
  -- serveForever
  pure ()

serveForever :: IO ()
serveForever =
  runConduit $
    openIngress "localhost:9000"
    .| awaitForever (\msg ->
         case msg of
           A -> liftIO $ putStrLn "Got A"
           B -> liftIO $ putStrLn "Got B"
       )

  
