import SCTP.Socket
import SCTP.Socket.Types
import SCTP.Socket.Utils

main :: IO ()
main = do
    listenAddress <- testUdpAddress testUdpPort
    connectAddress <- testUdpAddress $ testUdpPort + 1
    putStrLn "Starting on udp"
    sctp <- start_on_udp listenAddress
    otherSctp <- start_on_udp connectAddress
    putStrLn "Listening"
    listenSocket <- listen sctp listenAddress listenHandler
    putStrLn "Connecting"
    connectSocket <- connect otherSctp listenAddress connectHandler
    putStrLn "Waiting"
    getLine
    return ()
  where
    listenHandler (Established a) = putStrLn "Listener established"
    listenHandler (OtherEvent m) = return ()
    listenHandler (Data a) = putStrLn "got data!"
    connectHandler (Established a) = do
        putStrLn "Connector established"
        sendString a "Hello World!"
    connectHandler (OtherEvent m) = do
        return () --putStrLn $ show m
