{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeFamilies      #-}

module Control.Monad.MessagePass where

import           Data.Serialize

import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Writer

-- | A `Monad` that can send and wait for messages from somewhere else. This is unfortunatly ill defined - if you create on of these `waitForMessage` will block for ever. Here, they are designed to run in pairs, so there may be some way of choosing where they are send, maybe using some sort of phatom type trick like in ST
--
-- Default methods are implemented for transformer stacks which are and instance of `MonadTrans`. For any T one can write
--
-- >> instance MonadMessage m => instance MonadMessage (T m)
--
-- This helps with the instance problem for mtl style coding
class MonadIO m => MonadMessage m where
  sendMessage :: Serialize a => a -> m ()
  default sendMessage :: (Serialize a, m ~ t n, MonadTrans t, MonadMessage n) => a -> m ()
  sendMessage = lift . sendMessage

  -- | This should block until completion
  waitForMessage :: Serialize a => m a
  default waitForMessage :: (Serialize a, m ~ t n, MonadTrans t, MonadMessage n) => m a
  waitForMessage = lift waitForMessage

instance MonadMessage m => MonadMessage (StateT s m)
instance (Monoid w, MonadMessage m) => MonadMessage (WriterT w m)
instance MonadMessage m => MonadMessage (ReaderT r m)
