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


