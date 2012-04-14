{-# OPTIONS -Wall -O2 #-}
import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, ThreadId, myThreadId, killThread)
import Control.Concurrent.MVar
import Control.Concurrent.STM (STM, atomically)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Resource (ResourceT, runResourceT, MonadResource)
import Data.Conduit ( (=$), ($=), ($$), Source, Sink )
import Data.Conduit.Text (encode, decode, utf8)
import Data.Map(Map)
import Data.Monoid (mappend, mconcat)
import Data.Text(Text)
import qualified Control.Exception as E
import qualified Data.Conduit.Binary as Bin
import qualified Data.Conduit.List as L
import qualified Data.Conduit.Network as Net
import qualified Data.Conduit.TMChan as TMChan
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified System.IO as IO
import Data.ByteString (ByteString)

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
sendMsg (ChatServer clientsVar) text =
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

client :: ChatServer -> Net.Application (ResourceT IO)
client chatServer src sink = do
  clientId <- liftIO $ myThreadId
  chan <- liftIO . atomically $ TMChan.newTBMChan 16
  let
    handleMsg msg =
      sendMsg chatServer $
      mconcat
      [ Text.pack (show clientId ++ ": ")
      , msg
      ]
    tx = TMChan.sourceTBMChan chan $$ L.map (`mappend` Text.pack "\n") =$ encode utf8 =$ sink
    rx = src $= decode utf8 $$ L.mapM_ (liftIO . handleMsg . rTextDropWhile (=='\n'))
  liftIO .
    withClient chatServer clientId (TMChan.writeTBMChan chan) $
      withForkIO_ (runResourceT tx) (runResourceT rx)

runStdHandles
  :: (MonadResource m)
  => (Source m ByteString
      -> Sink ByteString m ()
      -> a)
  -> a
runStdHandles f = f (Bin.sourceHandle IO.stdin) (Bin.sinkHandle IO.stdout)

main :: IO ()
main = do
  chatServer <- makeChatServer
  withForkIO_ ((runResourceT . runStdHandles) (client chatServer)) .
    runResourceT $ Net.runTCPServer (Net.ServerSettings 12345 Net.HostAny) (client chatServer)
