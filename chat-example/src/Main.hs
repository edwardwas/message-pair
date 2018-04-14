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

import           Types
import           UI

import           Control.Concurrent.STM
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.Char                           (toUpper)
import qualified Data.Map                            as M
import qualified Network.WebSockets                  as WS

runServer :: TVar ServerState -> AppM () -> WS.ServerApp
runServer var app =
    runMessageWebsocketServer $
    hoistServer (\a -> runStdoutLoggingT $ runReaderT a var) app

runClient :: AppM () -> WS.ClientApp ()
runClient = runMessageWebsocketClient

run :: Location -> IO ()
run Server = do
  worldVar <- newTVarIO $ ServerState $ M.empty
  WS.runServer "127.0.0.1" 1234 $ runServer worldVar makeApp
run Client = WS.runClient "127.0.0.1" 1234 "/" $ runClient makeApp

main :: IO ()
main = do
  i <- getLine
  case map toUpper i of
    "SERVER" -> run Server
    "CLIENT" -> run Client
    _        -> putStrLn "I didn't understand that"
