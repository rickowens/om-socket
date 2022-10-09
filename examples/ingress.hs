{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Main (main) where

import Conduit
import Data.Binary
import GHC.Generics
import OM.Socket

{- | The messages that arrive on the socket. -}
data Msg
  = A
  | B
  deriving stock (Generic)
  deriving anyclass (Binary)

main :: IO ()
main = do
  runConduit $
    openIngress "localhost:9000"
    .| awaitForever (\msg ->
         case msg of
           A -> putStrLn "Got A"
           B -> putStrLn "Got B"
       )

  
