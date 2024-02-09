{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar,
  threadDelay)
import Control.Monad (void)
import Control.Monad.Catch (MonadCatch)
import Control.Monad.IO.Unlift (MonadIO(liftIO), MonadUnliftIO)
import Control.Monad.Logger (MonadLogger, runStdoutLoggingT)
import Data.Function ((&))
import Data.Text (Text)
import OM.Fork (Race, runRace)
import OM.Show (showt)
import OM.Socket (Responded, connectServer, openEgress, openIngress,
  openServer)
import Prelude (Applicative(pure), Foldable(length), Functor(fmap),
  Maybe(Nothing), Traversable(sequence), ($), (.), (<$>), (=<<), IO,
  Int, MonadFail, fst, print, reverse, seq, sequence_)
import Streaming.Prelude (Of, Stream)
import Test.Hspec (hspec, it, shouldBe)
import qualified Client
import qualified Egress
import qualified Ingress
import qualified Server
import qualified Streaming.Prelude as Stream


main :: IO ()
main =
  hspec $ do
    it "ingress/egress" $ do
      let
        expected :: [Int]
        expected = [1, 2, 3, 4]
      block <- newEmptyMVar
      void . forkIO $ do {- Ingress thread -}
        let
          instream :: (Race) => Stream (Of Int) IO ()
          instream = openIngress "localhost:9933"
        {-
          The instream never closes, because an ingress server is meant
          to listen forever, so we consume only the expected number
          of items from the stream
        -}
        actual <-
          runRace $
            Stream.take (length expected) instream & Stream.toList_
        putMVar block actual

      {- Push the expected items over the network.  -}
      Stream.each expected & openEgress "localhost:9933"
      actual <- takeMVar block
      print actual
      actual `shouldBe` expected

    it "client/server" $ do
      let
        requestStream
          :: ( MonadCatch m
             , MonadFail m
             , MonadLogger m
             , MonadUnliftIO m
             , Race
             )
          => Stream (Of (Int, Text -> m Responded)) m void
        requestStream = openServer "localhost:9934" Nothing

        requests :: [Int]
        requests = [1..4]

        expected :: [Text]
        expected = showt <$> requests

      block <- newEmptyMVar
      void . forkIO $ runRace $ runStdoutLoggingT $ do
        {-
          Handle the requests in reverse order to test out of order
          handling.
        -}
        reqs <-
          fmap reverse
          . Stream.toList_
          . Stream.take (length expected)
          $ requestStream
        liftIO (print (fst <$> reqs))
        sequence_
          [ respond (showt request)
          | (request, respond) <- reqs
          ]
        liftIO (putMVar block ())
      call <- runStdoutLoggingT (connectServer "localhost:9934" Nothing)
      calls <-
        sequence
          [ do
              threadDelay 100_000
              response <- newEmptyMVar
              void . forkIO $
                putMVar response =<< call i
              pure response
          | i <- requests
          ]
      responses <-
        sequence
          [ takeMVar response
          | response <- calls
          ]
      print responses
      responses `shouldBe` expected
      takeMVar block

    it "make sure the examples compile" $
      {-
        We don't actually _run_ the examples. Really it is the imports
        that makes sure the examples compile. We `seq` them here just
        so we don't get warnings about unused imports.
      -}
      Client.main
      `seq` Server.main
      `seq` Ingress.main
      `seq` Egress.main
      `seq` (pure () :: IO ())

