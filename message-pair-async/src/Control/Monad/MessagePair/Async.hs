{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Control.Monad.MessagePair.Async where

import           Control.Monad.MessagePass
import           Control.Monad.ServerOrClient

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.STM
import           Control.Monad.Base
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

instance MonadReader r m => MonadReader r (MessageAsyncT m) where
  ask = MessageAsyncT $ lift ask
  local func (MessageAsyncT act) = do
      chans <- MessageAsyncT ask
      MessageAsyncT $ lift $ local func $ runReaderT act chans

instance MonadTrans MessageAsyncT where
  lift = MessageAsyncT . lift

instance MonadBase b m => MonadBase b (MessageAsyncT m) where
  liftBase = lift . liftBase

instance MonadTransControl MessageAsyncT where
    type StT MessageAsyncT a = StT (ReaderT ( TChan B.ByteString
                                            , TChan (B.ByteString -> STM ()))) a
    liftWith = defaultLiftWith MessageAsyncT unMessageAsyncT
    restoreT = defaultRestoreT MessageAsyncT

instance MonadBaseControl b m => MonadBaseControl b (MessageAsyncT m) where
  type StM (MessageAsyncT m) a = ComposeSt MessageAsyncT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM

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

test :: SLocationI location => ServerOrClient (MessageAsyncT IO) (MessageAsyncT IO) location ()
test = do
  getLineAct <- embedOnClient (\str -> liftIO (putStrLn str >> getLine))
  runOnServer_ $ liftIO $ getLineAct "Boop!" >>= print
