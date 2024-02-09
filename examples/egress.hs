{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main (main) where

import Data.Binary (Binary)
import Data.Function ((&))
import GHC.Generics (Generic)
import OM.Socket (openEgress)
import Prelude (Applicative(pure), IO)
import Streaming.Prelude (each)

{- | The messages that arrive on the socket. -}
data Msg
  = A
  | B
  deriving stock (Generic)
  deriving anyclass (Binary)

main :: IO ()
main =
  {-
    Don't actually call sendMessages, because there is no server running to
    connect to, which will cause an error, which will cause the test to fail.
  -}
  -- sendMessages
  pure ()

sendMessages :: IO ()
sendMessages = do
  each [A, B, B, A, A, A, B]
  & openEgress "localhost:9000"


