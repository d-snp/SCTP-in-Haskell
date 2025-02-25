module SCTP.Socket.Types where
import SCTP.Types
import SCTP.Socket.Timer
import Network.Socket (HostAddress, HostAddress6)
import qualified Network.Socket as NS
import qualified Network.BSD as NBSD
import qualified Data.Map as Map
import Control.Concurrent.MVar
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Word

data SCTP = MkSCTP {
    underLyingSocket :: NS.Socket,
    address :: IpAddress,
    instances :: MVar (Map.Map (IpAddress, PortNum) Socket)
}

data Socket =  
  -- Socket is an instance of SCTP
  ListenSocket {
      associations :: MVar (Map.Map VerificationTag Association),
      secretKey :: BS.ByteString,
      stack :: SCTP,
      eventhandler :: (Event -> IO())
  } |
  ConnectSocket {
      association :: MVar Association,
      socketVerificationTag :: VerificationTag,
      socketState :: SocketState,
      eventhandler :: (Event -> IO()),
      stack :: SCTP,
      peerAddress :: NS.SockAddr,
      socketAddress :: NS.SockAddr
  }

instance Show Socket where
  show ConnectSocket {} = "ConnectSocket"
  show ListenSocket {} = "ListenSocket"

data Event = OtherEvent Message
           | Established Association
           | Data Association BL.ByteString
           | Closed Association
           | Sent Association Word32
           | Error String

data SocketState = CONNECTING | CONNECTED | CLOSED

-- Transmission Control Block
data Association = Association {
    associationPeerVT :: VerificationTag,
    associationVT :: VerificationTag,
    associationState :: AssociationState,
    associationPort :: PortNum,
    associationPeerAddress :: NS.SockAddr,
    associationSocket :: Socket,
    associationTimeOut :: Integer, -- in milliseconds
    associationTimer :: Timer Word32
}

data AssociationState = COOKIEWAIT | COOKIEECHOED | ESTABLISHED |
                        SHUTDOWNPENDING | SHUTDOWNSENT | SHUTDOWNRECEIVED |
                        SHUTDOWNACKSENT
