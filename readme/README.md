# message-pair: Seamless server client programs

Quite often we have a problem which requires communication between a server and a client. If this can be formulated in a stateless way (such as a REST app) the solution is quite easy. Otherwise, the whole things gets messy, with every communication required lots of error functions and even sometimes abandoning type safety. This library attempts to solve this problem by letting you write a single program which can act differently depending on where it is ran.

## Quick tutorial

The bulk of this library is in the `ServerOrClient` type. This takes four type parameters: `sm`, `cm` `location` and `a`. `sm` is the monadic context that the server runs in, `cm` is the same for the client. `location` is either `Server` or `Client` and says where the computation takes place and `a` is the result type. As long as `sm` and `cm` are `Monad`s, `ServerOrClient` is also a `Monad`, allowing us to write code which looks and feels like normal Haskell code.

When one wants to run code on only the server, one can use `runOnServer`. If `location` is `Server`, this runs the supplied function and sends the message across to the client. If we're on the client, we instead block until we receive the message. This lets us keep the two in sync with each other seamlessly. To send the data across the wire, the return type must be an instance of `Serialize` from the cereal library. One can also use `runOnServer_`, which runs the computation but does not send the result. This means that the client doesn't need to block and we don't need to serialize anything. There are also `runOnClient` and `runOnClient_` for using the client.

`runOnServer` requires both `cm` and `sm` to be instances of `MonadMessage`. This is an mtl style type class for sending and receiving messages between computations. At the moment the interface is quite poorly defined, so this will be improved later. We provide two monad transformer instances of this: `MessageAsyncT` for running two threads in one program and using async and stm to communicate and `MessageWebsocketT` which uses websockets. 

##Ping server example

Let's create a quite example - it will read a string and capitalize it for you remotely. We can start by importing some libraries.

```haskell
{-# LANGUAGE RankNTypes #-}

import Control.Monad.ServerOrClient (ServerOrClient, SLocationI, runOnServer, runOnClient, runOnClient_
  , onBoth, Location(..))
import Control.Monad.MessagePass (MonadMessage)

import Control.Monad.MessagePair.Async
import Control.Monad.MessagePair.Websocket

import Data.Char (toUpper)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Proxy (Proxy(..))
import qualified Network.WebSockets as WS
```

Let's write out function.

```haskell
capitalApp :: (SLocationI location, MonadMessage cm, MonadMessage sm) => ServerOrClient sm cm location ()
capitalApp = do
  input <- runOnClient $ liftIO $ putStrLn "What do you want to capitalize?" >> getLine
  output <- runOnServer (liftIO (putStrLn $ "Recieved: " ++ input) >> return (map toUpper input))
  liftIO $ putStrLn $ "Responce: " ++ output
```

Although this example is quite contrived we can still examine it. Line 1 prints out a message and gets your input, but only on the client. There server waits patiently for input. On line 2, the server prints a message and capitalizes our string. We don't need to do it in `IO`, but it helps for the example. Finally, both print out the result.

We can now run it in different ways by choosing a concrete value for `sm` and `cm`. The simplest is to use `MessageAsyncT`.

```haskell
runAsyncApp :: IO ()
runAsyncApp = runMessageAsyncPair capitalApp
```

Note that if we run this, the response is printed twice. This is because both threads are using it. We can make a server and client using `MessageWebsocketT` and a bit more work.

```haskell
runWebsocketApp :: Location -> IO ()
runWebsocketApp location =
    let app :: forall location . SLocationI location =>
            ServerOrClient (MessageWebsocketT IO) (MessageWebsocketT IO) location ()
        app = capitalApp
    in case location of
        Server -> WS.runServer "127.0.0.1" 1234 $ runMessageWebsocketServer app
        Client -> WS.runClient "127.0.0.1" 1234 "/" $ runMessageWebsocketClient app
```

Unfortunately, we have to create the local variable `app` and give it a (fairly complex) type signature to fix the types later.

# Alternatives

### Cloud Haskell

Cloud Haskell works on a similar idea, but seems a lot more heavy weight. It does allow one to transmit functions, but it also requires template-haskell

### Transient

I'm not going to lie - I don't fully understand transient. It seems to offer the world, but every time I've tried to use it I've come up against strange edge cases which I don't fully understand.

# Future

* More instances of `MonadMessage` - maybe TCP?
* Make `MonadMessage` have some notion of where it is sending its payload
* At the moment one can only have one client, which makes some code impure like shared state. We should be able to expand out to multiple, either all using the same type of context of a type level list.

# Other

We need a main function to compile...

```haskell
main :: IO ()
main = return ()
```
