{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wwarn #-}

module Main (main) where

import Conduit ((.|), awaitForever, runConduit)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Binary (Binary)
import GHC.Generics (Generic)
import OM.Socket

{- | The requests accepted by the server. -}
newtype Request = EchoRequest String
  deriving newtype (Binary)


{- | The response sent back to the client. -}
newtype Responsee = EchoResponse String


main :: IO ()
main =
  {-
    Don't actually call serveForever, because the "test" we are using to make
    sure this compiles will never finish running!
  -}
  -- serveForever
  pure ()


server :: IO ()
server =
  runConduit $
    pure ()
    .| openServer "localhost:9000" Nothing
    .| awaitForever (\(EchoRequest str, respond) ->
        liftIO $ respond (EchoResponse str)
    )

