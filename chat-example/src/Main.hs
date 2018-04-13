{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module Main where

import           Control.Monad.MessagePair.Websocket
import           Control.Monad.MessagePass
import           Control.Monad.ServerOrClient

import           Control.Concurrent.STM
import           Control.Lens
import           Control.Monad.Logger
import           Control.Monad.Reader
import qualified Data.Map                            as M
import           Data.Semigroup                      ((<>))
import           Data.Serialize                      (Serialize ())
import           Data.Serialize.Text                 ()
import qualified Data.Text                           as T
import           GHC.Exts                            (IsString (..))
import           GHC.Generics                        (Generic ())
import qualified Network.WebSockets                  as WS

instance MonadMessage m => MonadMessage (LoggingT m)

newtype Nickname = Nickname
    { unNickname :: T.Text
    } deriving (Eq, Show, Ord, IsString,Generic)
instance Serialize Nickname
makeWrapped ''Nickname

data Message = Message
    { _sender  :: Nickname
    , _content :: T.Text
    } deriving (Eq,Show,Generic)
instance Serialize Message
makeLenses ''Message

data ServerState = ServerState
    { _mailBoxes :: M.Map Nickname [Message]
    } deriving (Eq, Show)
makeLenses ''ServerState

data ServerRequest res where
  SendMessage :: T.Text -> ServerRequest ()
  GetMessages :: ServerRequest [Message]

type ServerM = ReaderT (TVar ServerState) (LoggingT (MessageWebsocketT IO))
type ClientM = MessageWebsocketT IO
type AppM a = forall location . SLocationI location => ServerOrClient ServerM ClientM location a

handleServerRequest :: Nickname -> ServerRequest res -> ServerM res
handleServerRequest name (SendMessage content) = do
  let message = Message name content
  worldVar <- ask
  liftIO $ atomically $ modifyTVar' worldVar $ mailBoxes . itraversed . indices (/= name) %~ (message: )
  logInfoN $ "Message sent: " <> T.pack (show message)
handleServerRequest name GetMessages = do
  worldVar <- ask
  messages <- liftIO $ atomically $ do
    messages <- toListOf (mailBoxes . ix name . traverse) <$> readTVar worldVar
    modifyTVar' worldVar $ mailBoxes . ix name .~ []
    return messages
  logInfoN $ unNickname name <> " retrieved " <> T.pack (show $ length messages) <> " messages"
  return messages

messageLoop :: Nickname -> AppM ()
messageLoop name = do
    message <- runOnClient $ liftIO $ getLine
    if | message == "QUIT" -> do
           runOnClient_ (liftIO $ putStrLn "Logging out")
           runOnServer_ $ do
              worldVar <- ask
              logInfoN $ unNickname name <> " logged out"
              liftIO $ atomically $ modifyTVar' worldVar $ mailBoxes . at name .~ Nothing
       | message == "" ->
           runOnServer (handleServerRequest name GetMessages) >>=
           runOnClient_ . mapM_ (liftIO . print)
       | otherwise ->
           runOnServer_
               (handleServerRequest name (SendMessage $ T.pack message))
    unless (message == "QUIT") $ messageLoop name

handleLogIn :: (Nickname -> AppM ()) -> AppM ()
handleLogIn cont = do
  name <- Nickname . T.pack <$> runOnClient (liftIO $ putStrLn "What is your name?" >> getLine)
  nameTaken <- runOnServer $ do
      worldVar <- ask
      liftIO $ atomically (has (mailBoxes . ix name) <$> readTVar worldVar)
  if | nameTaken -> do
        runOnClient_ (liftIO $ putStrLn "Name already taken...")
        runOnServer_ $ logWarnN $ "Name collision with " <> unNickname name
     | otherwise -> do
        runOnClient_ (liftIO $ putStrLn "Logging in..")
        runOnServer_ $ do
          worldVar <- ask
          liftIO $ atomically $ modifyTVar' worldVar $ mailBoxes . at name .~ Just []
          logInfoN $ unNickname name <> " logged in."
        cont name


runServer :: String -> Int -> AppM () -> IO ()
runServer host port app = do
    worldVar <- newTVarIO $ ServerState M.empty
    WS.runServer host port $
        runMessageWebsocketServer $
        hoistServer (\act -> runStdoutLoggingT $ runReaderT act worldVar) app

runClient :: String -> Int -> String -> AppM () -> IO ()
runClient host port root = WS.runClient host port root . runMessageWebsocketClient

main :: IO ()
main = putStrLn "Hello, Haskell!"
