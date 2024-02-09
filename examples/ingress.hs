{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main (main) where

import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Binary (Binary)
import Data.Function ((&))
import GHC.Generics (Generic)
import OM.Fork (runRace)
import OM.Socket (openIngress)
import Prelude (Applicative(pure), ($), IO, putStrLn)
import qualified Streaming.Prelude as S

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
  runRace $
    openIngress "localhost:9000"
    & S.mapM_ (\msg ->
         case msg of
           A -> liftIO $ putStrLn "Got A"
           B -> liftIO $ putStrLn "Got B"
       )


