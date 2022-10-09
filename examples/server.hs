{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wwarn #-}

module Main (main) where

import Conduit ( (.|), awaitForever, runConduit )
import Control.Monad.Logger ( runStdoutLoggingT )
import Control.Monad.Trans.Class ( MonadTrans(lift) )
import Data.Binary ( Binary )
import OM.Socket ( openServer )

{- | The requests accepted by the server. -}
newtype Request = EchoRequest String
  deriving newtype (Binary, Show)


{- | The response sent back to the client. -}
newtype Responsee = EchoResponse String
  deriving newtype (Binary, Show)


main :: IO ()
main =
  {-
    Don't actually call server, because the "test" we are using to make
    sure this compiles will never finish running!
  -}
  -- server
  pure ()


server :: IO ()
server =
  runStdoutLoggingT . runConduit $
    pure ()
    .| openServer "localhost:9000" Nothing
    .| awaitForever (\(EchoRequest str, respond) ->
        lift $ respond (EchoResponse str)
    )

