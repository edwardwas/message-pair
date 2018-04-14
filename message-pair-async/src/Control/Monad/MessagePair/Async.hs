{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}

module Control.Monad.MessagePair.Async where

import           Control.Monad.MessagePass
import           Control.Monad.ServerOrClient

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.STM
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import qualified Data.ByteString                      as B
import           Data.Serialize

newtype MessageAsyncT m a = MessageAsyncT
    { unMessageAsyncT :: ReaderT (TChan B.ByteString, TChan (B.ByteString -> STM ())) m a
    } deriving (Functor,Applicative,Monad, MonadIO)

instance MonadIO m => MonadMessage (MessageAsyncT m) where
  sendMessage a = do
    (sendChan,_) <- MessageAsyncT ask
    liftIO $ atomically $ writeTChan sendChan $ encode a
  waitForMessage = do
    (_,waitChan) <- MessageAsyncT ask
    waitVar <- liftIO $ atomically $ newEmptyTMVar
    liftIO $ atomically $ writeTChan waitChan $ putTMVar waitVar
    result <- liftIO $ atomically $ readTMVar waitVar
    case decode result of
      Right x -> return x
      Left e  -> error $ "Decode error: " ++ e

runMessageAsyncT ::
       (MonadBaseControl IO m, Forall (Pure m), MonadIO m)
    => TChan B.ByteString
    -> TChan B.ByteString
    -> MessageAsyncT m a
    -> m ()
runMessageAsyncT sendChan recvChan (MessageAsyncT act) = do
    waitChan <- liftIO $ atomically $ newTChan
    let recvHelper =
            liftIO (atomically (readTChan waitChan <*> readTChan recvChan)) >>=
            liftIO . atomically
    recvSync <- async $ forever recvHelper
    runReaderT act (sendChan, waitChan)
    cancel recvSync

runMessageServerOrClient ::
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => (forall location. SLocationI location =>
                             ServerOrClient (MessageAsyncT m) (MessageAsyncT m) location ())
    -> m ()
runMessageServerOrClient app = do
    (chanA, chanB) <- liftIO $ atomically ((,) <$> newTChan <*> newTChan)
    clientSync <- async $ runMessageAsyncT chanA chanB $ unOnClient app
    runMessageAsyncT chanB chanA $ unOnServer app
    wait clientSync
