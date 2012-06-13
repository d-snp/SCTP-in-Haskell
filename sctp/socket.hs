module SCTP.Socket where
import Network.Socket (HostAddress, HostAddress6)
import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as NSB
import qualified Network.Socket.ByteString.Lazy as NSBL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Network.BSD as NBSD
import Control.Monad
import Control.Concurrent
import Debug.Trace
import SCTP.Types
import SCTP.Utils
import SCTP.Socket.Types
import SCTP.Socket.Utils
import Data.Word
import qualified Data.Map as Map
import Control.Concurrent.MVar
import System.Random
import Data.Time.Clock

protocolNumber = 132 -- at least I think it is..
                     -- change this to non-standard to circumvent
                     -- OS limitations wrt capturing kernel protocols

maxMessageSize = 4096 -- RFC specifies minimum of 1500

{- Create an udp socket and use that as the raw socket backend -}
start_on_udp :: NS.SockAddr -> IO (SCTP)
start_on_udp address =
    do
        sock <- NS.socket NS.AF_INET NS.Datagram NS.defaultProtocol
        NS.bindSocket sock address
        connections <- newMVar Map.empty
        let stack = MkSCTP sock (ipAddress address) connections
        thread <- forkIO (stackLoop stack)
        return stack

{- This loops on the underlying socket receiving messages and dispatching them
 - to registered sockets. -}
stackLoop :: SCTP -> IO ()
stackLoop stack = forever $ do
    (bytes, peerAddress) <- NSB.recvFrom (underLyingSocket stack) maxMessageSize
    let message = deserializeMessage bytes
    let h = header message
    let destination = (address stack, destinationPortNumber h)
    sockets <- readMVar (instances stack)
    case Map.lookup destination sockets of
        Just socket -> socketAcceptMessage socket (ipAddress peerAddress) message
        Nothing -> return ()

{- Listen on Socket -}
listen :: SCTP -> NS.SockAddr -> (Event -> IO()) -> IO (Socket)
listen stack sockaddr eventhandler = do
    associations <- newMVar Map.empty
    keyValues <- replicateM 4 (randomIO :: IO(Int))
    let secretKey = BS.pack $ map fromIntegral keyValues
    let socket = ListenSocket associations secretKey stack eventhandler
    registerSocket stack sockaddr socket
    return socket

{- Connect -}
connect :: SCTP -> NS.SockAddr -> (Event -> IO()) -> IO (Socket)
connect stack peerAddr eventhandler = do
    keyValues <- replicateM 4 (randomIO :: IO(Int))
    myVT <- liftM fromIntegral (randomIO :: IO Int)
    myPort <- liftM fromIntegral $ do 
        let portnum = testUdpPort + 1
        return portnum -- TODO obtain portnumber

    let myAddr = sockAddr (address stack, fromIntegral myPort)

    let association = makeAssociation (myVT) myPort peerAddr
    associationMVar <- newMVar association

    let socket = makeConnectionSocket stack myVT associationMVar myAddr eventhandler peerAddr
    registerSocket stack myAddr socket

    let initMessage = makeInitMessage myVT myPort peerAddr
    socketSendMessage socket (ipAddress peerAddr, portNumber peerAddr) initMessage
    return socket

registerSocket :: SCTP -> NS.SockAddr -> Socket -> IO()
registerSocket stack addr socket =
    -- TODO simply overrides existing sockets, is this what we want?
    modifyMVar_ (instances stack) (return . Map.insert (ipAddress addr, fromIntegral(portNumber addr)) socket)

socketAcceptMessage :: Socket -> IpAddress -> Message -> IO()
socketAcceptMessage socket address message = do
    (eventhandler socket) (OtherEvent message)
    -- Drop packet if verifyChecksum fails
    when (verifyChecksum message) $ do
        let tag = verificationTag $ header message
        if tag == 0 -- verification tag is 0, so message MUST be INIT
            then handleInit socket address message
            else do
                let allChunks@(firstChunk : restChunks) = chunks message
                let toProcess
                        | chunkType firstChunk == cookieEchoChunkType = restChunks
                        | otherwise = allChunks
                when (chunkType firstChunk == cookieEchoChunkType) $ handleCookieEcho socket address message
                unless (toProcess == []) $ do
                    maybeAssociation <- getAssociation socket tag
                    case maybeAssociation of
                        Just association  ->
                            mapM_ (handleChunk socket association) toProcess
                        Nothing -> return()
  where
    getAssociation ConnectSocket{} _ = do
        assoc <- readMVar $ association socket
        return $ Just assoc
    getAssociation ListenSocket{} tag = do
        assocs <- readMVar (associations socket)
        return $ Map.lookup tag assocs

handleChunk socket association chunk
    | t == initAckChunkType = handleInitAck socket association $ fromChunk chunk
    | t == payloadChunkType = handlePayload socket association $ fromChunk chunk
    | t == shutdownChunkType = handleShutdown socket association $ fromChunk chunk
    | t == cookieAckChunkType = handleCookieAck socket association $ fromChunk chunk
    | otherwise = return ()--putStrLn $ "Got chunk:" ++ show chunk -- return() -- exception?
  where
    t = chunkType chunk

handleInitAck :: Socket -> Association -> Init -> IO()
handleInitAck socket assoc initAck = do
    --registerSocket (stack socket) (socketAddress socket) newSocket
    let cookieEcho = makeCookieEcho newAssociation initAck
    let peerAddr = peerAddress socket
    socketSendMessage socket (ipAddress peerAddr, portNumber peerAddr) cookieEcho
    swapMVar (association socket) newAssociation
    return ()
  where
    peerVT = initiateTag initAck
    newAssociation = assoc { associationPeerVT = peerVT, associationState = COOKIEECHOED}

handleCookieAck :: Socket -> Association -> CookieAck -> IO()
handleCookieAck socket association initAck = do
    (eventhandler socket) $ Established association

handleShutdown :: Socket -> Association -> Shutdown -> IO()
handleShutdown socket association chunk = do
    (eventhandler socket) $ Closed association

handlePayload :: Socket -> Association -> Payload -> IO()
handlePayload socket association chunk = do 
    putStrLn "handlePayload"

handleInit :: Socket -> IpAddress -> Message -> IO()
handleInit socket@ConnectSocket{} _ message = return () -- throw away init's when we're not listening
handleInit socket@ListenSocket{} address message = do
    time <- getCurrentTime
    myVT <- randomIO :: IO Int
    myTSN <- randomIO :: IO Int
    let responseMessage = makeInitResponse address message secret time myVT myTSN
    socketSendMessage socket (address, portnum) responseMessage
    return ()
  where
    secret = secretKey socket
    portnum = fromIntegral $ (sourcePortNumber.header) message

socketSendMessage :: Socket -> (IpAddress, NBSD.PortNumber) -> Message -> IO(Int)
socketSendMessage socket address message = do
    --putStrLn $ "SendMessage: " ++ (show message) ++ "To: " ++ (show address)
    NSB.sendTo (underLyingSocket $ stack socket) messageBytes (sockAddr address)
  where
    messageBytes = (BS.concat . BL.toChunks) $ serializeMessage message

handleCookieEcho :: Socket -> IpAddress -> Message -> IO()
handleCookieEcho socket@ConnectSocket{} addr message = return ()
handleCookieEcho socket@ListenSocket{} addr message = do
    when validMac $ do
        assocs <- takeMVar $ associations socket
        let newAssocs =  Map.insert myVT association assocs
        putMVar (associations socket) newAssocs
        (eventhandler socket) $ Established association
        socketSendMessage socket peerAddr $ cookieAckMessage
        return ()
  where
    cookieChunk = fromChunk $ head $ chunks message
    (cookie,rest) = deserializeCookie $ cookieEcho cookieChunk
    myVT = verificationTag $ header message
    myAddress = address $ stack socket
    myPortnum = destinationPortNumber $ header message
    secret = secretKey $ socket
    myMac = makeMac cookie (fromIntegral myVT) myAddress myPortnum secret
    validMac = myMac == (mac cookie)
    peerVT =  peerVerificationTag cookie
    peerPort = sourcePortNumber $ header message
    peerAddr = (addr, fromIntegral peerPort)
    association = MkAssociation peerVT myVT ESTABLISHED myPortnum (sockAddr peerAddr)
    cookieAckMessage =  Message (makeHeader association 0) [toChunk CookieAck]
