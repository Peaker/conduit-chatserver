{-# OPTIONS -Wall -O2 #-}
import Data.Conduit ( (=$), ($=), ($$) )
import qualified Data.Conduit.Network as Net
import qualified Data.Conduit.TMChan as TMChan
import Data.Conduit.Text (encode, decode, utf8)
import qualified Data.Conduit.List as L
import qualified Data.Text as Text
import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, ThreadId, myThreadId, killThread)
import Control.Concurrent.MVar
import Data.Map(Map)
import Data.Text(Text)
import qualified Control.Exception as E
import qualified Data.Map as Map
import Control.Concurrent.STM (STM, atomically)
import Data.Monoid (mappend, mconcat)

type ClientId = ThreadId

-- Chat Server:

data ChatServer = ChatServer {
  _clients :: MVar (Map ClientId (Text -> STM ()))
  }

makeChatServer :: IO ChatServer
makeChatServer = do
  ChatServer <$> newMVar Map.empty

addClient :: ChatServer -> ClientId -> (Text -> STM ()) -> IO ()
addClient (ChatServer clientsVar) clientId sender =
  modifyMVar_ clientsVar $ return . Map.insert clientId sender

removeClient :: ChatServer -> ClientId -> IO ()
removeClient (ChatServer clientsVar) clientId =
  modifyMVar_ clientsVar $ return . Map.delete clientId

sendMsg :: ChatServer -> Text -> IO ()
sendMsg (ChatServer clientsVar) text = do
  putStrLn $ Text.unpack text
  withMVar clientsVar (atomically . mapM_ ($ text) . Map.elems)


withClient :: ChatServer -> ClientId -> (Text -> STM ()) -> IO a -> IO a
withClient chatServer clientId sender =
  E.bracket_ add remove
  where
    msg text = sendMsg chatServer . Text.pack $ text ++ show clientId
    add = do
      addClient chatServer clientId sender
      msg "Added client: "
    remove = do
      removeClient chatServer clientId
      msg "Removed client: "

withForkIO :: IO () -> (ThreadId -> IO a) -> IO a
withForkIO act = E.bracket (forkIO act) killThread

withForkIO_ :: IO () -> IO a -> IO a
withForkIO_ act = withForkIO act . const

rTextDropWhile :: (Char -> Bool) -> Text -> Text
rTextDropWhile p = Text.reverse . Text.dropWhile p . Text.reverse

app :: ChatServer -> Net.Application IO
app chatServer src sink = do
  clientId <- myThreadId
  chan <- atomically $ TMChan.newTBMChan 16
  let
    handleMsg msg =
      sendMsg chatServer $
      mconcat
      [ Text.pack (show clientId ++ ": ")
      , msg
      ]
    tx = TMChan.sourceTBMChan chan $$ L.map (`mappend` Text.pack "\n") =$ encode utf8 =$ sink
    rx = src $= decode utf8 $$ L.mapM_ (handleMsg . rTextDropWhile (=='\n'))
  withClient chatServer clientId (TMChan.writeTBMChan chan) $
    withForkIO_ tx rx

main :: IO ()
main = do
  chatServer <- makeChatServer
  Net.runTCPServer (Net.ServerSettings 12345 Net.HostAny) (app chatServer)
