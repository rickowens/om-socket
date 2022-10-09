{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wwarn #-}

module Main (main) where

import Conduit ((.|), runConduit, yield)
import Data.Binary (Binary)
import GHC.Generics (Generic)
import OM.Socket (openEgress)

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
  runConduit $
    mapM_ yield [A, B, B, A, A, A, B]
    .| openEgress "localhost:9000"


