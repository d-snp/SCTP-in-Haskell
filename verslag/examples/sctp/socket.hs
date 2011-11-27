module Socket where
import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as NSB
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Network.BSD
import Control.Concurrent
import Debug.Trace
import Types
import Data.Word
import qualified Data.Map as Map
import Control.Concurrent.MVar

protocolNumber = 132 -- at least I think it is..
					 -- change this to non-standard to circumvent
					 -- OS limitations wrt capturing kernel protocols

maxMessageSize = 4096 -- RFC specifies minimum of 1500

data SCTP = MkSCTP {
    underLyingSocket :: NS.Socket,
	sockets :: MVar (Map.Map Word32 Socket)
}

data Socket = MkSocket {
    sockAddress :: SockAddr
}

-- TODO I think this is no longer necessary
data SockAddr = SockAddr {
    addrFamily :: NS.Family,
    portNumber :: Word16,
    ipAddress :: [Word32],
    flow :: Word32,
    scope :: Word32
}

{- Get the default local server address -}
localServerAddress = do
    host <- getHostByName "localhost"
    return $ hostAddress host

{- Convert NS.SockAddr to a SockAddr -}
fromSockAddr :: NS.SockAddr -> SockAddr
fromSockAddr (NS.SockAddrInet port host) =
    SockAddr family (fromIntegral port) ipAddress 0 0 -- no flow or scope
    where
        family = NS.AF_INET
        ipAddress = [host]

fromSockAddr (NS.SockAddrInet6 port flow host scope) =
    SockAddr family (fromIntegral port) ipAddress flow scope -- no flow or scope
    where
        family = NS.AF_INET6
        (a, b, c, d) = host
        ipAddress = [a,b,c,d]


{- Create a NS.SockAddr from a SockAddr that is ipv4 -}
sockAddr addr@(SockAddr {addrFamily = NS.AF_INET}) =
    NS.SockAddrInet (NS.PortNum $ portNumber addr) (head $ ipAddress addr)

{- Create a NS.SockAddr from a SockAddr that is ipv6 -}
sockAddr addr@(SockAddr {addrFamily = NS.AF_INET6}) =
    NS.SockAddrInet6 (NS.PortNum $ portNumber addr) (flow addr) (ip6Addr) (scope addr)
    where
        ipAddr = ipAddress addr
        ip6Addr = (ipAddr !! 0, ipAddr !! 1, ipAddr !! 2, ipAddr !! 3)

{- Connect to a remote socket at address -}
-- connect :: SCTP -> SockAddr -> IO (Int)
-- connect sock remoteAddress = do
--     NS.sendTo rawSock packed_init_chunk (sockAddr remoteAddress)
--     where
--         common_header = CommonHeader (portNumber . sockAddress $ sock)
--            (portNumber remoteAddress) 0 0
--        rawSock = underLyingSocket sock
--        init_chunk = undefined
--        packed_init_chunk = undefined

{- Listen on Socket -}
listen :: SCTP -> IO (ThreadId)
listen socket = do
    forkIO (listenLoop socket)

testUdpPort = 54312
testUdpAddress = do
    localhost <- localServerAddress -- default serveraddress for localhost
    return (NS.SockAddrInet testUdpPort localhost)

{- Create an udp socket and use that as the raw socket backend -}
start_on_udp :: NS.SockAddr -> IO (SCTP)
start_on_udp address =
    do
        sock <- NS.socket NS.AF_INET NS.Datagram NS.defaultProtocol
        NS.bindSocket sock address
        connections <- newMVar Map.empty
        let stack = MkSCTP sock connections
        thread <- listen stack
        return stack


listenLoop :: SCTP -> IO ()
listenLoop stack = do
    -- read data from socket
    -- parse the common header
    -- if it matches an existing stream, pass it to that stream
    -- if it is an init, generate a cookie
    -- it it is a cookie ack, establish a new connection
    -- TODO:
    -- connections and pending connections should be stored in Sockets
    -- so per stream configuration and variables can be read
    bytes <- NSB.recv (underLyingSocket stack) maxMessageSize
    let (header_bytes, chunk_bytes) = BS.splitAt (fromIntegral commonHeaderSize) bytes
    let header = deSerializeCommonHeader $ BL.fromChunks [header_bytes]
    let chunk = deSerializeChunk $ BL.fromChunks [chunk_bytes]
    -- putTraceMsg $ "Header: " ++ (show header)
    -- putTraceMsg $ "Chunk: " ++ (show chunk)
    let handler =
            case () of _
                        | t == initChunkType -> handleInit
                        | t == payloadChunkType -> handlePayload
                        | t == cookieChunkType -> handleCookie
            where t = toInteger $ chunkType chunk
    handler stack $ fromChunk chunk
    listenLoop stack

handleInit :: SCTP -> Init -> IO ()
handleInit stack init =
    undefined
    -- generate cookie
    -- init ack

handleCookie stack cookie =
    undefined
    -- build tcb
    -- cookie ack
    -- stream established

handlePayload stack payload =
    undefined

sendToSocket :: IO()
sendToSocket = do
    sock <- NS.socket NS.AF_INET NS.Datagram NS.defaultProtocol
    localhost <- localServerAddress
    NS.bindSocket sock (NS.SockAddrInet (testUdpPort + 1) localhost)
    NSB.sendTo sock bytes (NS.SockAddrInet testUdpPort localhost)
    return ()
    where
        header = CommonHeader 1 2 3 4
        chunk = Chunk 1 1 3 (BL.pack [1,1,1])
        bytes = BS.concat $ map (BS.concat . BL.toChunks)  [serializeCommonHeader header, serializeChunk chunk]
