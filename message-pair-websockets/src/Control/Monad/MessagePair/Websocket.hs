{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Control.Monad.MessagePair.Websocket where

import           Control.Monad.MessagePass
import           Control.Monad.ServerOrClient

import           Control.Monad.Base
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Control
import           Control.Monad.Writer
import qualified Data.ByteString              as B
import qualified Data.ByteString.Lazy         as BL
import           Data.Serialize
import qualified Network.WebSockets           as WS

-- | An instance of `MonadMessage` that uses websockets to pass messages. This in principle can be compiles by GHCJS letting us write server-cleint programs easily
newtype MessageWebsocketT m a = MessageWebsocketT
    { unMessageWebsocket :: ReaderT WS.Connection m a
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadTrans
               , MonadIO
               , MonadState s
               , MonadWriter w
               )

instance MonadReader r m => MonadReader r (MessageWebsocketT m) where
  ask = MessageWebsocketT $ lift ask
  local func (MessageWebsocketT act) = do
      chans <- MessageWebsocketT ask
      MessageWebsocketT $ lift $ local func $ runReaderT act chans

instance MonadIO m => MonadMessage (MessageWebsocketT m) where
  sendMessage a = MessageWebsocketT $ do
    conn <- ask
    liftIO $ WS.sendDataMessage conn $ WS.Binary $ BL.fromStrict $ encode a
  waitForMessage = MessageWebsocketT $ do
    conn <- ask
    WS.Binary msg <- liftIO $ WS.receiveDataMessage conn
    case decode $ BL.toStrict msg of
      Right x -> return x
      Left e  -> error $ "Decode error: " ++ e

instance MonadBase b m => MonadBase b (MessageWebsocketT m) where
  liftBase = lift . liftBase

instance MonadTransControl MessageWebsocketT where
  type StT MessageWebsocketT a = StT (ReaderT WS.Connection) a
  liftWith = defaultLiftWith MessageWebsocketT unMessageWebsocket
  restoreT = defaultRestoreT MessageWebsocketT

instance MonadBaseControl b m => MonadBaseControl b (MessageWebsocketT m) where
    type StM (MessageWebsocketT m) a = ComposeSt MessageWebsocketT m a
    liftBaseWith = defaultLiftBaseWith
    restoreM = defaultRestoreM

-- | Run a `ServerOrClient` action on the server. This will have one instance running per client and they won't share their Monadic context. If you want to share state, parse in a mutable varaibles of some sort
runMessageWebsocketServer ::
       ServerOrClient (MessageWebsocketT IO) cm Server () -> WS.ServerApp
runMessageWebsocketServer (OnServer (MessageWebsocketT act)) pendingConn =
    WS.acceptRequest pendingConn >>= runReaderT act

-- | Run a `ServerOrClient` action on the client.
runMessageWebsocketClient ::
       ServerOrClient sm (MessageWebsocketT IO) Client () -> WS.ClientApp ()
runMessageWebsocketClient (OnClient (MessageWebsocketT act)) =
    runReaderT act
