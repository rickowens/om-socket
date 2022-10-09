{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Conduit
import Control.Monad.IO.Class
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
           A -> liftIO $ putStrLn "Got A"
           B -> liftIO $ putStrLn "Got B"
       )

  
