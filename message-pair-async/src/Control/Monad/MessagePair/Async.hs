{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Control.Monad.MessagePair.Async where

import           Control.Monad.MessagePass
import           Control.Monad.ServerOrClient

import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Monad.Base
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Control
import           Control.Monad.Writer
import qualified Data.ByteString              as B
import           Data.Serialize

-- | And instance of `MonadMessage` that runs in two threads on a local system. This is of limited utility, but is simple to understand.
newtype MessageAsyncT m a = MessageAsyncT
    { unMessageAsyncT :: ReaderT (TChan B.ByteString, TChan B.ByteString) m a
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadIO
               , MonadState s
               , MonadWriter w
               , MonadTrans
               )

instance MonadReader r m => MonadReader r (MessageAsyncT m) where
  ask = MessageAsyncT $ lift ask
  local func (MessageAsyncT act) = do
      chans <- MessageAsyncT ask
      MessageAsyncT $ lift $ local func $ runReaderT act chans

instance MonadIO m => MonadMessage (MessageAsyncT m) where
  sendMessage a = MessageAsyncT $ do
    (chan,_) <- ask
    liftIO $ atomically $ writeTChan chan $ encode a
  waitForMessage = MessageAsyncT $ do
    (_,chan) <- ask
    msg <- liftIO $ atomically $ readTChan chan
    case decode msg of
      Right a -> return a
      Left e  -> error $ "Decode error: " ++ e

instance MonadBase b m => MonadBase b (MessageAsyncT m) where
  liftBase = lift . liftBase

instance MonadTransControl MessageAsyncT where
  type StT MessageAsyncT a = StT (ReaderT (TChan B.ByteString, TChan B.ByteString)) a
  liftWith = defaultLiftWith MessageAsyncT unMessageAsyncT
  restoreT = defaultRestoreT MessageAsyncT

instance MonadBaseControl b m => MonadBaseControl b (MessageAsyncT m) where
  type StM (MessageAsyncT m) a = ComposeSt MessageAsyncT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM

-- | Run a `ServerOrClient` program on both the client and the server
runMessageAsyncPair ::
       (forall location. SLocationI location =>
                             ServerOrClient (MessageAsyncT IO) (MessageAsyncT IO) location ())
    -> IO ()
runMessageAsyncPair act = do
    (chanA, chanB) <- atomically ((,) <$> newTChan <*> newTChan)
    clientSync <-
        async $ runReaderT (unMessageAsyncT (unOnClient act)) (chanA, chanB)
    runReaderT (unMessageAsyncT $ unOnServer act) (chanB, chanA)
    wait clientSync
