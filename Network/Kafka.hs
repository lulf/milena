{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Kafka where

import Control.Lens
import Control.Applicative
import Control.Monad (liftM)
import Control.Monad.Trans (liftIO, lift)
import Control.Monad.Trans.Either
import Control.Monad.Trans.State
import Data.ByteString.Char8 (ByteString)
import Data.ByteString.Lens
import System.Random (getStdRandom, randomR)
import Data.Monoid ((<>))
import Data.Serialize.Get
import System.IO
import qualified Data.ByteString.Char8 as B
import qualified Data.Map as M
import qualified Network

import Network.Kafka.Protocol

data KafkaState = KafkaState { -- | Name to use as a client ID.
                               _stateName :: KafkaString
                               -- | An incrementing counter of requests.
                             , _stateCorrelationId :: CorrelationId
                               -- | How many acknowledgements are required for producing.
                             , _stateRequiredAcks :: RequiredAcks
                               -- | Time in milliseconds to wait for messages to be produced by broker.
                             , _stateRequestTimeout :: Timeout
                               -- | Minimum size of response bytes to block for.
                             , _stateWaitSize :: MinBytes
                               -- | Maximum size of response bytes to retrieve.
                             , _stateBufferSize :: MaxBytes
                               -- | Maximum time in milliseconds to wait for response.
                             , _stateWaitTime :: MaxWaitTime
                             }

makeLenses ''KafkaState

data KafkaConsumer = KafkaConsumer { _consumerState :: KafkaState
                                   , _consumerHandle :: Handle
                                   }

makeLenses ''KafkaConsumer

-- | The core Kafka monad.
type Kafka = StateT KafkaConsumer (EitherT KafkaClientError IO)

type KafkaAddress = (Host, Port)
type KafkaClientId = KafkaString

-- | Errors given from the Kafka monad.
data KafkaClientError = -- | A response did not contain an offset.
                        KafkaNoOffset
                        -- | Got a different form of a response than was requested.
                      | KafkaExpected KafkaExpectedResponse
                        -- | A value could not be deserialized correctly.
                      | KafkaDeserializationError String -- TODO: cereal is Stringly typed, should use tickle
                        deriving (Eq, Show)

-- | Type of response to expect, used for 'KafkaExpected' error.
data KafkaExpectedResponse = ExpectedMetadata
                           | ExpectedFetch
                           | ExpectedProduce
                             deriving (Eq, Show)

-- | An abstract form of Kafka's time. Used for querying offsets.
data KafkaTime = -- | The latest time on the broker.
                 LatestTime
                 -- | The earliest time on the broker.
               | EarliestTime
                 -- | A specific time.
               | OtherTime Time

data PartitionAndLeader = PartitionAndLeader { _palTopic :: TopicName
                                             , _palPartition :: Partition
                                             , _palLeader :: Leader
                                             }

makeLenses ''PartitionAndLeader

data TopicAndPartition = TopicAndPartition { _tapTopic :: TopicName
                                           , _tapPartition :: Partition
                                           }
                         deriving (Eq, Ord, Show)

-- | A topic with a serializable message.
data TopicAndMessage = TopicAndMessage { _tamTopic :: TopicName
                                       , _tamMessage :: Message
                                       }
                       deriving (Eq, Show)

makeLenses ''TopicAndMessage

-- | Get the bytes from the Kafka message, ignoring the topic.
tamPayload :: TopicAndMessage -> ByteString
tamPayload = foldOf (tamMessage . payload)

-- * Configuration

-- | Default: @0@
defaultCorrelationId :: CorrelationId
defaultCorrelationId = 0

-- | Default: @1@
defaultRequiredAcks :: RequiredAcks
defaultRequiredAcks = 1

-- | Default: @10000@
defaultRequestTimeout :: Timeout
defaultRequestTimeout = 10000

-- | Default: @0@
defaultMinBytes :: MinBytes
defaultMinBytes = MinBytes 0

-- | Default: @1024 * 1024@
defaultMaxBytes :: MaxBytes
defaultMaxBytes = 1024 * 1024

-- | Default: @0@
defaultMaxWaitTime :: MaxWaitTime
defaultMaxWaitTime = 0

-- | Create a consumer using default values.
defaultState :: KafkaClientId -> KafkaState
defaultState cid =
    KafkaState cid
               defaultCorrelationId
               defaultRequiredAcks
               defaultRequestTimeout
               defaultMinBytes
               defaultMaxBytes
               defaultMaxWaitTime

-- | Run the underlying Kafka monad at the given leader address and initial state.
runKafka :: KafkaAddress -> KafkaState -> Kafka a -> IO (Either KafkaClientError a)
runKafka (h, p) s k = do
  handle <- Network.connectTo h' p'
  r <- runEitherT . evalStateT k $ KafkaConsumer s handle
  hClose handle
  return r
      where h' = h ^. hostString . kString . unpackedChars
            p' = p ^. portInt . to fromIntegral . to Network.PortNumber

-- | Make a request, incrementing the `_stateCorrelationId`.
makeRequest :: RequestMessage -> Kafka Request
makeRequest m = do
  corid <- use (consumerState . stateCorrelationId)
  consumerState . stateCorrelationId += 1
  conid <- use (consumerState . stateName)
  return $ Request (corid, ClientId conid, m)

-- | Perform a request and deserialize the response.
doRequest :: Request -> Kafka Response
doRequest r = mapStateT (bimapEitherT KafkaDeserializationError id) $ do
  h <- use consumerHandle
  dataLength <- lift . EitherT $ do
    B.hPut h $ requestBytes r
    hFlush h
    rawLength <- B.hGet h 4
    return $ runGet (liftM fromIntegral getWord32be) rawLength
  resp <- liftIO $ B.hGet h dataLength
  a <- lift . hoistEither $ runGet (getResponse dataLength) resp
  return a

-- | Send a metadata request
metadata :: MetadataRequest -> Kafka MetadataResponse
metadata request =
    makeRequest (MetadataRequest request) >>= doRequest >>= expectResponse ExpectedMetadata _MetadataResponse

-- | Function to give an error when the response seems wrong.
expectResponse :: KafkaExpectedResponse -> Getting (Leftmost b) ResponseMessage b -> Response -> Kafka b
expectResponse e p = lift . maybe (left $ KafkaExpected e) return . firstOf (responseMessage . p)

-- | Convert an abstract time to a serializable protocol value.
protocolTime :: KafkaTime -> Time
protocolTime LatestTime = Time (-1)
protocolTime EarliestTime = Time (-2)
protocolTime (OtherTime o) = o

-- * Messages

-- | Group messages together with the leader they should be sent to.
partitionAndCollate :: [TopicAndMessage] -> Kafka (M.Map Leader (M.Map TopicAndPartition [TopicAndMessage]))
partitionAndCollate ks = f ks M.empty
      where f [] c = return c
            f (x:xs) a = do
              topicPartitionsList <- brokerPartitionInfo $ _tamTopic x
              pal <- liftIO $ getPartition topicPartitionsList
              let l = maybe (Leader Nothing) _palLeader pal
                  tp = TopicAndPartition <$> pal ^? folded . palTopic <*> pal ^? folded . palPartition
                  b = M.singleton l (maybe M.empty (`M.singleton` [x]) tp)
                  c = M.unionWith (M.unionWith (<>)) a b
              f xs c
            getPartition ps =
                let ps' = ps ^.. folded . filtered (has $ palLeader . leaderId . _Just)
                in (ps' ^?) . element <$> getStdRandom (randomR (0, length ps' - 1))

-- | Create a protocol message set from a list of messages.
groupMessagesToSet :: [TopicAndMessage] -> MessageSet
groupMessagesToSet xs = MessageSet $ uncurry msm <$> zip [0..] xs
    where msm n = MessageSetMember (Offset n) . _tamMessage

-- | Find a leader and partition for the topic.
brokerPartitionInfo :: TopicName -> Kafka [PartitionAndLeader]
brokerPartitionInfo t = do
  md <- metadata $ MetadataReq [t]
  return $ pal <$> md ^.. topicsMetadata . folded . partitionsMetadata . folded
      where pal d = PartitionAndLeader t (d ^. partitionId) (d ^. partitionMetadataLeader)

-- | Default: @1@
defaultMessageCrc :: Crc
defaultMessageCrc = 1

-- | Default: @0@
defaultMessageMagicByte :: MagicByte
defaultMessageMagicByte = 0

-- | Default: @Nothing@
defaultMessageKey :: Key
defaultMessageKey = Key $ MKB Nothing

-- | Default: @0@
defaultMessageAttributes :: Attributes
defaultMessageAttributes = 0

-- | Construct a message from a string of bytes using default attributes.
makeMessage :: ByteString -> Message
makeMessage m = Message (defaultMessageCrc, defaultMessageMagicByte, defaultMessageAttributes, defaultMessageKey, Value (MKB (Just (KBytes m))))

-- * Fetching

-- | Default: @-1@
ordinaryConsumerId :: ReplicaId
ordinaryConsumerId = ReplicaId (-1)

-- | Construct a fetch request from the values in the state.
fetchRequest :: Offset -> Partition -> TopicName -> Kafka FetchRequest
fetchRequest o p topic = do
  wt <- use (consumerState . stateWaitTime)
  ws <- use (consumerState . stateWaitSize)
  bs <- use (consumerState . stateBufferSize)
  return $ FetchReq (ordinaryConsumerId, wt, ws, [(topic, [(p, o, bs)])])

-- | Execute a fetch request and get the raw fetch response.
fetch :: FetchRequest -> Kafka FetchResponse
fetch request =
    makeRequest (FetchRequest request) >>= doRequest >>= expectResponse ExpectedFetch _FetchResponse

-- | Extract out messages with their topics from a fetch response.
fetchMessages :: FetchResponse -> [TopicAndMessage]
fetchMessages fr = (fr ^.. fetchResponseFields . folded) >>= tam
    where tam a = TopicAndMessage (a ^. _1) <$> a ^.. _2 . folded . _4 . messageSetMembers . folded . message

-- * Producing

-- | Execute a produce request and get the raw preduce response.
produce :: ProduceRequest -> Kafka ProduceResponse
produce request = do
    makeRequest (ProduceRequest request) >>= doRequest >>= expectResponse ExpectedProduce _ProduceResponse

-- | Construct a produce request with explicit arguments.
produceRequest :: RequiredAcks -> Timeout -> [(TopicAndPartition, MessageSet)] -> ProduceRequest
produceRequest ra ti ts =
    ProduceReq (ra, ti, M.toList . M.unionsWith (<>) $ fmap f ts)
        where f (TopicAndPartition t p, i) = M.singleton t [(p, i)]

-- | Send messages to partition calculated by 'partitionAndCollate'.
produceMessages :: [TopicAndMessage] -> Kafka [ProduceResponse]
produceMessages tams = do
  m <- fmap (fmap groupMessagesToSet) <$> partitionAndCollate tams
  -- TODO: Use the leaders
  mapM send $ M.toList <$> M.elems m

-- | Execute a produce request using the values in the state.
send :: [(TopicAndPartition, MessageSet)] -> Kafka ProduceResponse
send ts = do
  requiredAcks <- use (consumerState . stateRequiredAcks)
  requestTimeout <- use (consumerState . stateRequestTimeout)
  produce $ produceRequest requiredAcks requestTimeout ts

-- * Offsets

-- | Fields to construct an offset request, per topic and partition.
data PartitionOffsetRequestInfo =
    PartitionOffsetRequestInfo { -- | Time to find an offset for.
                                 _kafkaTime :: KafkaTime
                                 -- | Number of offsets to retrieve.
                               , _maxNumOffsets :: MaxNumberOfOffsets
                               }

-- TODO: Properly look up the offset via the partition.
-- | Get the first found offset.
getLastOffset :: KafkaTime -> Partition -> TopicName -> Kafka Offset
getLastOffset m p t =
    makeRequest (offsetRequest [(TopicAndPartition t p, PartitionOffsetRequestInfo m 1)]) >>= doRequest >>= maybe (StateT . const $ left KafkaNoOffset) return . firstOf (responseMessage . _OffsetResponse . offsetResponseOffset p)

-- | Create an offset request.
offsetRequest :: [(TopicAndPartition, PartitionOffsetRequestInfo)] -> RequestMessage
offsetRequest ts =
    OffsetRequest $ OffsetReq (ReplicaId (-1), M.toList . M.unionsWith (<>) $ fmap f ts)
        where f (TopicAndPartition t p, i) = M.singleton t [g p i]
              g p (PartitionOffsetRequestInfo kt mno) = (p, protocolTime kt, mno)
