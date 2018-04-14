{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module Control.Monad.ServerOrClient
    ( Location(..)
    , SLocationI()
    , ServerOrClient(..)
    , unOnClient
    , unOnServer
    , hoistServer
    , hoistClient
    , onBoth
    , mapOnBoth
    , runOnServer
    , runOnServer_
    , runOnClient
    , runOnClient_
    , embedOnServer
    , embedOnServer_
    , embedOnClient
    , embedOnClient_
    ) where

import           Control.Monad.MessagePass

import           Control.Monad.Base
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Control
import           Control.Monad.Writer
import           Data.Proxy
import           Data.Serialize              hiding (get, put)

-- | Where the code is running, either on the server or on the client. This is more often used at the type level thanks to DataKinds
data Location = Server | Client
  deriving (Eq,Show)

-- | A singleton `Location`, allowing us to use type information at run time
data SLocation location where
  SServer :: SLocation Server
  SClient :: SLocation Client

-- | Proof that the location has an `SLocation`. This is true for all values of `Location`, but this is unfortunatly nessacery with GHC
class SLocationI location where
  sLocation :: SLocation location

instance SLocationI Server where
  sLocation = SServer

instance SLocationI Client where
  sLocation = SClient

-- | The workhouse of this module. By looking at the value of location, we can decide if we are on the server and using sm or on the client and use the cm context. Functions likes `runOnServer` convert actions at the other location to either non-ops or with for the message from the other, allowing use to seamlessly pass control around
data ServerOrClient sm cm location a where
  OnServer :: sm a -> ServerOrClient sm cm Server a
  OnClient :: cm a -> ServerOrClient sm cm Client a

-- | Run `ServerOrClient` on the server
unOnServer :: ServerOrClient sm cm Server a -> sm a
unOnServer (OnServer a) = a

-- | Run `ServerOrClient` on the client
unOnClient :: ServerOrClient sm cm Client a -> cm a
unOnClient (OnClient a) = a

-- | Change the server context.
hoistServer ::
       (sm a -> sm' a)
    -> ServerOrClient sm cm location a
    -> ServerOrClient sm' cm location a
hoistServer func (OnServer a) = OnServer $ func a
hoistServer _ (OnClient a)    = OnClient a

-- | Change the client context
hoistClient ::
       (cm a -> cm' a)
    -> ServerOrClient sm cm location a
    -> ServerOrClient sm cm' location a
hoistClient _ (OnServer a)    = OnServer a
hoistClient func (OnClient a) = OnClient (func a)

-- | As long as sm and cm both satisfy a constraint c, run an action on both the server and the client. This can be used to implement something like `ask` from `MonadReader
--
-- >> ask' = onBoth (Proxy :: Proxy MonadReader) ask
onBoth ::
       forall location c sm cm a. (SLocationI location, c sm, c cm)
    => Proxy c
    -> (forall f. c f =>
                      f a)
    -> ServerOrClient sm cm location a
onBoth _ func =
    case sLocation :: SLocation location of
        SServer -> OnServer func
        SClient -> OnClient func

-- | As long as sm and cm both satisfy a constraint c, apply a transformation to the context on both the server and the client. This is used to implement `Functor`
--
-- >> fmap' f = mapOnBoth (Proxy :: Proxy Functor) (fmap f)
mapOnBoth ::
       forall location c sm cm a b. (c sm, c cm)
    => Proxy c
    -> (forall f. c f =>
                      f a -> f b)
    -> ServerOrClient sm cm location a
    -> ServerOrClient sm cm location b
mapOnBoth _ func (OnServer a) = OnServer (func a)
mapOnBoth _ func (OnClient a) = OnClient (func a)

instance (Functor sm, Functor cm) =>
         Functor (ServerOrClient sm cm location) where
  fmap f = mapOnBoth (Proxy @Functor) (fmap f)

instance (Applicative sm, Applicative cm, SLocationI location) =>
         Applicative (ServerOrClient sm cm location) where
  pure a = onBoth (Proxy @Applicative) (pure a)
  OnServer f <*> OnServer a = OnServer (f <*> a)
  OnClient f <*> OnClient a = OnClient (f <*> a)

instance (Monad sm, Monad cm, SLocationI location) =>
      Monad (ServerOrClient sm cm location) where
  OnServer a >>= f = OnServer $ a >>= unOnServer . f
  OnClient a >>= f = OnClient $ a >>= unOnClient . f

instance (MonadIO sm, MonadIO cm, SLocationI location) =>
         MonadIO (ServerOrClient sm cm location) where
    liftIO a = onBoth (Proxy @MonadIO) (liftIO a)

instance (MonadReader r sm, MonadReader r cm, SLocationI location) =>
         MonadReader r (ServerOrClient sm cm location) where
    ask = onBoth (Proxy @(MonadReader r)) ask
    local f = mapOnBoth (Proxy @(MonadReader r)) (local f)

instance (MonadWriter w sm, MonadWriter w cm, SLocationI location) =>
         MonadWriter w (ServerOrClient sm cm location) where
    tell x = onBoth (Proxy @(MonadWriter w)) (tell x)
    listen = mapOnBoth (Proxy @(MonadWriter w)) listen
    pass = mapOnBoth (Proxy @(MonadWriter w)) pass

instance (MonadState s sm, MonadState s cm, SLocationI location) =>
         MonadState s (ServerOrClient sm cm location) where
    get = onBoth (Proxy @(MonadState s)) get
    put s = onBoth (Proxy @(MonadState s)) (put s)

instance (MonadBase b sm, MonadBase b cm, SLocationI location) =>
  MonadBase b (ServerOrClient sm cm location) where
    liftBase ba = onBoth (Proxy @(MonadBase b)) (liftBase ba)

-- | Run a compuation in sm only on the server. The server completes the action, and then sends the result to the client. The client blocks here until it recieves the result. The result is encoded via `Serialize`, hence the constraint on the output type
runOnServer ::
       forall location sm cm a.
       (MonadMessage cm, MonadMessage sm, SLocationI location, Serialize a)
    => sm a
    -> ServerOrClient sm cm location a
runOnServer act =
    case sLocation :: SLocation location of
        SServer ->
            OnServer $ do
                res <- act
                sendMessage res
                return res
        SClient -> OnClient waitForMessage

-- | Run a computation of the server with no result. Because there is no result, the client does not block here.
runOnServer_ ::
       forall location sm cm. (SLocationI location, Monad cm)
    => sm ()
    -> ServerOrClient sm cm location ()
runOnServer_ act =
    case sLocation :: SLocation location of
        SServer -> OnServer act
        SClient -> OnClient $ return ()

-- | Like `runOnServer`, but for the client
runOnClient ::
       forall location sm cm a.
       (MonadMessage cm, MonadMessage sm, SLocationI location, Serialize a)
    => cm a
    -> ServerOrClient sm cm location a
runOnClient act =
    case sLocation :: SLocation location of
        SServer -> OnServer waitForMessage
        SClient ->
            OnClient $ do
                res <- act
                sendMessage res
                return res

-- | Like `runOnServer_`, but for the client
runOnClient_ ::
       forall location sm cm. (SLocationI location, Monad sm, Monad cm)
    => cm ()
    -> ServerOrClient sm cm location ()
runOnClient_ act =
    case sLocation :: SLocation location of
        SServer -> return ()
        SClient -> OnClient act

embedOnServer ::
       forall location a b sm cm m.
       ( MonadBaseControl m sm
       , MonadBaseControl m cm
       , SLocationI location
       , StM sm b ~ b
       , StM cm b ~ b
       , MonadMessage sm
       , MonadMessage cm
       , Serialize b
       )
    => (a -> sm b)
    -> ServerOrClient sm cm location (a -> m b)
embedOnServer func =
    case sLocation :: SLocation location of
        SServer ->
            OnServer $
            embed $ \a -> do
                res <- func a
                sendMessage res
                return res
        SClient -> OnClient $ embed $ \_ -> (waitForMessage  :: cm b)

embedOnServer_ ::
       forall location a sm cm bm.
       ( SLocationI location
       , StM sm () ~ ()
       , MonadBaseControl bm sm
       , Applicative cm
       )
    => (a -> sm ())
    -> ServerOrClient sm cm location (a -> bm ())
embedOnServer_ func =
    case sLocation :: SLocation location of
        SServer -> OnServer $ embed func
        SClient -> pure $ const $ pure ()

embedOnClient ::
       forall location a b sm cm bm.
       ( MonadBaseControl bm sm
       , MonadBaseControl bm cm
       , SLocationI location
       , StM sm b ~ b
       , StM cm b ~ b
       , MonadMessage sm
       , MonadMessage cm
       , Serialize b
       )
    => (a -> cm b)
    -> ServerOrClient sm cm location (a -> bm b)
embedOnClient func =
    case sLocation :: SLocation location of
        SClient ->
            OnClient $
            embed $ \a -> do
                res <- func a
                sendMessage res
                return res
        SServer -> OnServer $ embed $ \_ -> (waitForMessage :: sm b)

embedOnClient_ ::
       forall location a sm cm bm.
       ( SLocationI location
       , StM cm () ~ ()
       , MonadBaseControl bm cm
       , Applicative sm)
    => (a -> cm ())
    -> ServerOrClient sm cm location (a -> bm ())
embedOnClient_ func =
    case sLocation :: SLocation location of
        SServer -> pure $ const $ pure ()
        SClient -> OnClient $ embed func
