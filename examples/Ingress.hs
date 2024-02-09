{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Ingress (main) where

import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Binary (Binary)
import Data.Function ((&))
import GHC.Generics (Generic)
import OM.Fork (runRace)
import OM.Socket (openIngress)
import Prelude (($), IO, putStrLn)
import qualified Streaming.Prelude as Stream

{- |
  The messages that arrive on the socket.

  This type would typically be shared by both the Ingress and Egress side,
  or at least the binary encoding must be identical.
-}
data Msg
  = A
  | B
  deriving stock (Generic)
  deriving anyclass (Binary)


main :: IO ()
main =
  runRace $
    openIngress "localhost:9000"
    & Stream.mapM_
       (\msg ->
           case msg of
             A -> liftIO $ putStrLn "Got A"
             B -> liftIO $ putStrLn "Got B"
         )


