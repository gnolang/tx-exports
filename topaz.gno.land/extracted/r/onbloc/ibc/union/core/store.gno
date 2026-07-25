package core

import (
	"chain/params"
	"encoding/hex"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/onbloc/ibc/union/app"
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
)

var (
	store        *Store
	proxyPkgPath string
)

func init(cur realm) {
	store = newStore()
	proxyPkgPath = cur.PkgPath()
}

// Store is the proxy-owned persistent state. It is a flat data layer: clients,
// connections, channels, and commitments are keyed directly by their globally
// allocated id or storage path, with no cross-entity indirection. All protocol
// logic — handshake state machines, the acknowledge/timeout flow, proof
// verification — lives in the impl (core/v1). The Store only stores and
// retrieves, mirroring commitment values into chain params so counterparties
// can prove them.
type Store struct {
	clientSeq      seqid.ID
	clientRegistry map[string]lightclient.ClientImpl // ClientRegistry: type → factory
	clientTypeByID map[uint32]types.ClientType       // ClientTypes: clientId → type
	clientImplByID map[uint32]lightclient.ClientImpl // ClientImpls: clientId → factory
	clientByID     map[uint32]*client                // clientId → instantiated state

	connectionSeq seqid.ID
	connections   *bptree.BPTree // connectionKey(ConnectionId) → types.Connection

	channelSeq seqid.ID
	channels   *bptree.BPTree // channelKey(ChannelId) → *channelEntry

	// commitments holds every packet/batch commitment keyed by its global storage
	// path. The path derivations (packet commitment, packet receipt, batch packets,
	// batch receipts) are namespaced so they never collide, so a single flat map
	// replaces the former per-client batch trees. Membership proofs keep their own
	// maps because they are read back by a different key shape.
	commitments         map[types.H256]types.H256
	membershipProofs    map[types.H256]types.H256
	nonMembershipProofs map[types.H256]types.H256

	ports map[string]app.IApp
}

type client struct {
	id                types.ClientId
	creator           address
	lightClient       lightclient.Interface
	clientState       []byte
	consensusByHeight *bptree.BPTree // string(height.Bytes()) → []byte
	// clientStore holds the light client's own key/value storage writes
	// (lightclient result StorageWrites). It stays per-client because the keys
	// are opaque to the host; the flat commitment map only covers host-derived
	// commitment paths.
	clientStore map[string][]byte
}

type channelEntry struct {
	channel types.Channel
	portId  types.Bytes
}

func newStore() *Store {
	return &Store{
		clientRegistry:      make(map[string]lightclient.ClientImpl),
		clientTypeByID:      make(map[uint32]types.ClientType),
		clientImplByID:      make(map[uint32]lightclient.ClientImpl),
		clientByID:          make(map[uint32]*client),
		connections:         bptree.NewBPTree32(),
		channels:            bptree.NewBPTree32(),
		commitments:         make(map[types.H256]types.H256),
		membershipProofs:    make(map[types.H256]types.H256),
		nonMembershipProofs: make(map[types.H256]types.H256),
		ports:               make(map[string]app.IApp),
	}
}

// The Store satisfies the IStore interface the impl is injected with. Each
// adapter routes to the flat data primitives below. Setters take the borrow-rule
// (_ int, rlm realm, ...) form; the realm token is threaded by the caller and
// unused here because the underlying writes already run in the proxy's ownership
// context.
var _ IStore = (*Store)(nil)

// RegisterClient stores a factory function for typ in the client registry.
func (s *Store) RegisterClient(_ int, rlm realm, typ types.ClientType, impl lightclient.ClientImpl) {
	assertIsRlmCurrent(0, rlm)

	s.registerClient(typ, impl)
}

// ClientRegistry returns the registered factory for typ.
func (s *Store) ClientRegistry(typ types.ClientType) (lightclient.ClientImpl, bool) {
	return s.clientRegistryEntry(typ)
}

// HasRegisteredClient reports whether a factory is registered for typ.
func (s *Store) HasRegisteredClient(typ types.ClientType) bool {
	_, found := s.clientRegistryEntry(typ)
	return found
}

// AddClient allocates a new client id and stores the light client object,
// returning the assigned id.
func (s *Store) AddClient(_ int, rlm realm, typ types.ClientType, creator address, lc lightclient.Interface) types.ClientId {
	assertIsRlmCurrent(0, rlm)

	return s.addClient(s.nextClientId(), typ, creator, lc).id
}

// GetClientImpl returns the factory stored for clientId.
func (s *Store) GetClientImpl(clientId types.ClientId) (lightclient.ClientImpl, bool) {
	impl, found := s.clientImplByID[uint32(clientId)]
	return impl, found
}

// SaveClientStore records a light client storage write (result StorageWrites),
// returning false when the client is unknown.
func (s *Store) SaveClientStore(_ int, rlm realm, clientId types.ClientId, key string, value []byte) bool {
	assertIsRlmCurrent(0, rlm)

	c := s.getClient(clientId)
	if c == nil {
		return false
	}

	c.saveClientStore(key, value)

	return true
}

// ClientExists reports whether a client is registered under clientId.
func (s *Store) ClientExists(clientId types.ClientId) bool {
	_, found := s.clientTypeByID[uint32(clientId)]
	return found
}

// ClientType returns the registered client type for clientId.
func (s *Store) ClientType(clientId types.ClientId) (types.ClientType, bool) {
	typ, found := s.clientTypeByID[uint32(clientId)]
	return typ, found
}

// GetLightClient returns the stored light client object for clientId.
func (s *Store) GetLightClient(clientId types.ClientId) (lightclient.Interface, bool) {
	return s.lightClientOf(clientId)
}

// SetLightClient replaces a client's light client object (force-update recovery),
// returning false when the client is unknown.
func (s *Store) SetLightClient(_ int, rlm realm, clientId types.ClientId, lc lightclient.Interface) bool {
	assertIsRlmCurrent(0, rlm)

	c := s.getClient(clientId)
	if c == nil {
		return false
	}

	c.lightClient = lc

	return true
}

// SaveClientState mirrors the client state bytes for queries and counterparty
// proofs, returning false when the client is unknown.
func (s *Store) SaveClientState(_ int, rlm realm, clientId types.ClientId, clientStateBytes []byte) bool {
	assertIsRlmCurrent(0, rlm)

	c := s.getClient(clientId)
	if c == nil {
		return false
	}

	c.saveClientState(clientStateBytes)

	return true
}

// SaveConsensusState records the consensus state at height, returning false when
// the client is unknown.
func (s *Store) SaveConsensusState(_ int, rlm realm, clientId types.ClientId, height types.Height, consensusStateBytes []byte) bool {
	assertIsRlmCurrent(0, rlm)

	c := s.getClient(clientId)
	if c == nil {
		return false
	}

	c.saveConsensusState(height, consensusStateBytes)

	return true
}

// NextConnectionId allocates the next connection id from the sequence.
func (s *Store) NextConnectionId(_ int, rlm realm) types.ConnectionId {
	assertIsRlmCurrent(0, rlm)

	return s.nextConnectionId()
}

// SaveConnection persists a connection and mirrors its commitment.
func (s *Store) SaveConnection(_ int, rlm realm, connectionId types.ConnectionId, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)

	s.saveConnection(connectionId, connection)
}

// GetConnection returns the stored connection for connectionId.
func (s *Store) GetConnection(connectionId types.ConnectionId) (types.Connection, bool) {
	return s.getConnection(connectionId)
}

// NextChannelId allocates the next channel id from the sequence.
func (s *Store) NextChannelId(_ int, rlm realm) types.ChannelId {
	assertIsRlmCurrent(0, rlm)

	return s.nextChannelId()
}

// CreateChannel persists a new channel owned by portId and mirrors its commitment.
func (s *Store) CreateChannel(_ int, rlm realm, channelId types.ChannelId, channel types.Channel, portId types.Bytes) {
	assertIsRlmCurrent(0, rlm)

	s.createChannel(channelId, channel, portId)
}

// SaveChannel updates a stored channel and mirrors its commitment.
func (s *Store) SaveChannel(_ int, rlm realm, channelId types.ChannelId, channel types.Channel) {
	assertIsRlmCurrent(0, rlm)

	s.saveChannel(channelId, channel)
}

// GetChannels returns all stored channel records.
// The bptree callback returns false to keep iterating (returning true stops early),
// and the empty range bounds walk every entry.
func (s *Store) GetChannels() ([]types.Channel, error) {
	channels := make([]types.Channel, 0)

	s.channels.Iterate("", "", func(key string, value any) bool {
		entry, ok := value.(*channelEntry)
		if !ok {
			return false
		}

		channels = append(channels, entry.channel)

		return false
	})

	return channels, nil
}

// GetChannel returns the stored channel for channelId.
func (s *Store) GetChannel(channelId types.ChannelId) (types.Channel, bool) {
	entry, ok := s.getChannelEntry(channelId)
	if !ok {
		return types.Channel{}, false
	}

	return entry.channel, true
}

// GetChannelOwner returns the port id that owns channelId.
func (s *Store) GetChannelOwner(channelId types.ChannelId) (types.Bytes, bool) {
	entry, ok := s.getChannelEntry(channelId)
	if !ok {
		return nil, false
	}

	return entry.portId, true
}

// GetAppByPortId returns the IBC app registered at portId.
func (s *Store) GetAppByPortId(portId types.Bytes) (app.IApp, bool) {
	a, ok := s.ports[portKey(portId)]

	return a, ok
}

// HasApp reports whether an app is registered at portId.
func (s *Store) HasApp(portId types.Bytes) bool {
	_, ok := s.ports[portKey(portId)]

	return ok
}

// RegisterAppAtPort installs an app at portId, panicking if one is already
// registered there.
func (s *Store) RegisterAppAtPort(_ int, rlm realm, portId types.Bytes, a app.IApp) {
	assertIsRlmCurrent(0, rlm)

	key := portKey(portId)
	if _, ok := s.ports[key]; ok {
		panic("port " + string(portId) + " already registered")
	}

	s.ports[key] = a
}

// HasPacketCommitment reports whether the source-side packet commitment exists.
func (s *Store) HasPacketCommitment(packet types.Packet) bool {
	_, found := s.getCommitment(packetCommitmentPath(packet))
	return found
}

// CommitPacket records the source-side commitment for a sent packet.
func (s *Store) CommitPacket(_ int, rlm realm, packet types.Packet) {
	assertIsRlmCurrent(0, rlm)

	s.setCommitment(packetCommitmentPath(packet), types.COMMITMENT_MAGIC)
}

// SetPacketAcknowledged flips a source-side commitment to the acknowledged
// marker. It is a pure write: the impl owns the state machine (verifying the
// commitment exists and is not already acknowledged) before calling this. The
// flip stays in memory only — the chain-param commitment keeps recording that
// the packet was sent.
func (s *Store) SetPacketAcknowledged(_ int, rlm realm, packet types.Packet) {
	assertIsRlmCurrent(0, rlm)

	s.setCommitmentMem(packetCommitmentPath(packet), types.COMMITMENT_MAGIC_ACK)
}

// HasPacketReceipt reports whether a destination-side receipt exists.
func (s *Store) HasPacketReceipt(packet types.Packet) bool {
	_, found := s.getCommitment(packetAcknowledgementPath(packet))
	return found
}

// SetPacketReceipt records a destination-side receipt (replay protection).
func (s *Store) SetPacketReceipt(_ int, rlm realm, packet types.Packet) {
	assertIsRlmCurrent(0, rlm)

	s.setCommitment(packetAcknowledgementPath(packet), types.COMMITMENT_MAGIC)
}

// CommitAcknowledgement records the acknowledgement for a received packet.
func (s *Store) CommitAcknowledgement(_ int, rlm realm, packet types.Packet, ack []byte) {
	assertIsRlmCurrent(0, rlm)

	s.setCommitment(packetAcknowledgementPath(packet), types.CommitAcks([][]byte{ack}))
}

// AcknowledgementReceipt returns the receipt stored at a packet's ack path.
func (s *Store) AcknowledgementReceipt(channelId types.ChannelId, packet types.Packet) (types.H256, bool) {
	return s.getCommitment(packetAcknowledgementPath(packet))
}

// PacketCommitment returns the commitment stored at a packet's commitment path.
func (s *Store) PacketCommitment(channelId types.ChannelId, packet types.Packet) (types.H256, bool) {
	return s.getCommitment(packetCommitmentPath(packet))
}

// SaveBatchPackets records a batch commitment under batchHash.
func (s *Store) SaveBatchPackets(_ int, rlm realm, channelId types.ChannelId, batchHash, value types.H256) {
	assertIsRlmCurrent(0, rlm)

	s.setCommitment(types.BatchPacketsPath(batchHash), value)
}

// SaveBatchReceipts records a batch receipt under batchHash.
func (s *Store) SaveBatchReceipts(_ int, rlm realm, channelId types.ChannelId, batchHash, value types.H256) {
	assertIsRlmCurrent(0, rlm)

	s.setCommitment(types.BatchReceiptsPath(batchHash), value)
}

// SaveMembershipProof records a verified membership commitment.
func (s *Store) SaveMembershipProof(_ int, rlm realm, clientId types.ClientId, proofHeight uint64, path []byte, value types.H256) {
	assertIsRlmCurrent(0, rlm)

	s.saveMembershipProof(clientId, proofHeight, path, value)
}

// SaveNonMembershipProof records a verified non-membership commitment.
func (s *Store) SaveNonMembershipProof(_ int, rlm realm, clientId types.ClientId, proofHeight uint64, path []byte, value types.H256) {
	assertIsRlmCurrent(0, rlm)

	s.saveNonMembershipProof(clientId, proofHeight, path, value)
}

// ClientStateBytes returns the mirrored client state bytes for a client.
func (s *Store) ClientStateBytes(clientId types.ClientId) ([]byte, bool) {
	c := s.getClient(clientId)
	if c == nil || len(c.clientState) == 0 {
		return nil, false
	}

	return types.CloneBytes(c.clientState), true
}

// ConsensusStateBytes returns the consensus state bytes at a height.
func (s *Store) ConsensusStateBytes(clientId types.ClientId, height types.Height) ([]byte, bool) {
	c := s.getClient(clientId)
	if c == nil {
		return nil, false
	}

	return c.getConsensusState(height)
}

// BatchPacketsAt returns the batch packet commitment for a batch hash. The
// commitment is keyed by the global batch path, so no channel id is required.
func (s *Store) BatchPacketsAt(batchHash types.H256) (types.H256, bool) {
	return s.getCommitment(types.BatchPacketsPath(batchHash))
}

// BatchReceiptsAt returns the batch receipt commitment for a batch hash. The
// commitment is keyed by the global batch path, so no channel id is required.
func (s *Store) BatchReceiptsAt(batchHash types.H256) (types.H256, bool) {
	return s.getCommitment(types.BatchReceiptsPath(batchHash))
}

// MembershipProofAt returns the committed membership proof value for the
// client/height/path key.
func (s *Store) MembershipProofAt(clientId types.ClientId, proofHeight uint64, path []byte) (types.H256, bool) {
	return s.getMembershipProof(clientId, proofHeight, path)
}

// HasNonMembershipProof reports whether a non-membership proof was committed
// for the client/height/path key.
func (s *Store) HasNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) bool {
	return s.hasNonMembershipProof(clientId, proofHeight, path)
}

// --- Key helpers ---

func connectionKey(id types.ConnectionId) string {
	return seqid.ID(id).Binary()
}

func channelKey(id types.ChannelId) string {
	return seqid.ID(id).Binary()
}

func setChainParam(key string, value []byte) {
	// NOTE: find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(key, value)
}

// h256ChainParamKey encodes Union commitment paths for chain params. Unlike
// classic IBC string paths, Union paths are H256 storage keys and are mirrored
// into params as lowercase hex strings.
func h256ChainParamKey(key types.H256) string {
	return hex.EncodeToString(key[:])
}

// --- Commitment primitives (path → value) ---

// setCommitment stores a commitment value and mirrors it into chain params so
// counterparties can prove it.
func (s *Store) setCommitment(path types.H256, value types.H256) {
	s.commitments[path] = value
	setChainParam(h256ChainParamKey(path), value[:])
}

// setCommitmentMem stores a commitment value in memory only (no chain-param
// mirror). Used for the acknowledged flip, which is local bookkeeping.
func (s *Store) setCommitmentMem(path types.H256, value types.H256) {
	s.commitments[path] = value
}

// getCommitment reads the commitment value stored at path.
func (s *Store) getCommitment(path types.H256) (types.H256, bool) {
	v, found := s.commitments[path]
	if !found {
		var zero types.H256
		return zero, false
	}

	return v, true
}

// --- Client state ---

func (c *client) saveClientState(clientStateBytes []byte) {
	c.clientState = types.CloneBytes(clientStateBytes)
	setChainParam(h256ChainParamKey(types.ClientStatePath(c.id)), h256Bytes(keccak(clientStateBytes)))
}

func (c *client) saveConsensusState(height types.Height, consensusStateBytes []byte) {
	c.consensusByHeight.Set(string(height.Bytes()), types.CloneBytes(consensusStateBytes))
	setChainParam(h256ChainParamKey(types.ConsensusStatePath(c.id, height)), h256Bytes(keccak(consensusStateBytes)))
}

func (c *client) getConsensusState(height types.Height) ([]byte, bool) {
	v := c.consensusByHeight.Get(string(height.Bytes()))
	if v == nil {
		return nil, false
	}

	return types.CloneBytes(v.([]byte)), true
}

// --- Client store (light client storage writes) ---

func (c *client) saveClientStore(key string, value []byte) {
	c.clientStore[key] = types.CloneBytes(value)
}

func (c *client) getClientStore(key string) ([]byte, bool) {
	v, found := c.clientStore[key]
	if !found {
		return nil, false
	}

	return types.CloneBytes(v), true
}

// --- Committed proofs (global paths) ---

func (s *Store) saveMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte, value types.H256) {
	key := types.MembershipProofPath(clientId, proofHeight, path)
	s.membershipProofs[key] = value
	setChainParam(h256ChainParamKey(key), value[:])
}

func (s *Store) getMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) (types.H256, bool) {
	v, found := s.membershipProofs[types.MembershipProofPath(clientId, proofHeight, path)]
	if !found {
		var zero types.H256
		return zero, false
	}

	return v, true
}

func (s *Store) saveNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte, value types.H256) {
	key := types.NonMembershipProofPath(clientId, proofHeight, path)
	s.nonMembershipProofs[key] = value
	setChainParam(h256ChainParamKey(key), value[:])
}

func (s *Store) hasNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) bool {
	v, found := s.nonMembershipProofs[types.NonMembershipProofPath(clientId, proofHeight, path)]
	return found && v == types.NON_MEMBERSHIP_COMMITMENT_VALUE
}

// --- ID sequences ---

func (s *Store) nextConnectionId() types.ConnectionId {
	return types.ConnectionId(uint32(s.connectionSeq.Next()))
}

func (s *Store) nextChannelId() types.ChannelId {
	return types.ChannelId(uint32(s.channelSeq.Next()))
}

func (s *Store) nextClientId() types.ClientId {
	return types.ClientId(uint32(s.clientSeq.Next()))
}

// --- Client ---

func (s *Store) addClient(clientId types.ClientId, typ types.ClientType, creator address, lc lightclient.Interface) *client {
	id := uint32(clientId)
	clientImpl, _ := s.clientRegistryEntry(typ)
	c := &client{
		id:                clientId,
		creator:           creator,
		lightClient:       lc,
		consensusByHeight: bptree.NewBPTree32(),
		clientStore:       make(map[string][]byte),
	}
	s.clientTypeByID[id] = typ
	s.clientImplByID[id] = clientImpl
	s.clientByID[id] = c

	return c
}

func (s *Store) registerClient(typ types.ClientType, impl lightclient.ClientImpl) {
	key := typ.String()
	if _, ok := s.clientRegistry[key]; ok {
		panic("client type already exists")
	}
	s.clientRegistry[key] = impl
}

func (s *Store) clientRegistryEntry(typ types.ClientType) (lightclient.ClientImpl, bool) {
	impl, found := s.clientRegistry[string(typ)]
	return impl, found
}

func (s *Store) getClient(clientId types.ClientId) *client {
	c, found := s.clientByID[uint32(clientId)]
	if !found {
		return nil
	}

	return c
}

func (s *Store) lightClientOf(clientId types.ClientId) (lightclient.Interface, bool) {
	c := s.getClient(clientId)
	if c == nil {
		return nil, false
	}

	return c.lightClient, true
}

// --- App routing ---

func portKey(portId types.Bytes) string {
	return string(portId)
}

func (s *Store) getAppByPortId(portId types.Bytes) app.IApp {
	a, ok := s.ports[portKey(portId)]
	if !ok {
		panic(makeError(ErrPortNotFound, string(portId)))
	}

	return a
}

// --- Connection ---

func (s *Store) saveConnection(connectionId types.ConnectionId, connection types.Connection) {
	s.connections.Set(connectionKey(connectionId), connection)
	setChainParam(h256ChainParamKey(types.ConnectionPath(connectionId)), h256Bytes(connectionValue(connection)))
}

func (s *Store) getConnection(connectionId types.ConnectionId) (types.Connection, bool) {
	v := s.connections.Get(connectionKey(connectionId))
	if v == nil {
		return types.Connection{}, false
	}

	return v.(types.Connection), true
}

// --- Channel ---

func (s *Store) createChannel(channelId types.ChannelId, channel types.Channel, portId types.Bytes) {
	entry := &channelEntry{
		channel: cloneChannel(channel),
		portId:  portId.Clone(),
	}
	s.channels.Set(channelKey(channelId), entry)
	setChainParam(h256ChainParamKey(types.ChannelPath(channelId)), h256Bytes(channelValue(channel)))
}

func (s *Store) saveChannel(channelId types.ChannelId, channel types.Channel) {
	entry, found := s.getChannelEntry(channelId)
	if !found {
		panic(makeError(ErrChannelNotFound, channelId.String()))
	}

	entry.channel = cloneChannel(channel)
	setChainParam(h256ChainParamKey(types.ChannelPath(channelId)), h256Bytes(channelValue(channel)))
}

func (s *Store) getChannelEntry(channelId types.ChannelId) (*channelEntry, bool) {
	v := s.channels.Get(channelKey(channelId))
	if v == nil {
		return nil, false
	}

	return v.(*channelEntry), true
}

func (s *Store) getChannel(channelId types.ChannelId) types.Channel {
	entry, found := s.getChannelEntry(channelId)
	if !found {
		panic(makeError(ErrChannelNotFound, channelId.String()))
	}

	return entry.channel
}

func (s *Store) getChannelOwner(channelId types.ChannelId) types.Bytes {
	entry, found := s.getChannelEntry(channelId)
	if !found {
		panic(makeError(ErrChannelNotFound, channelId.String()))
	}

	return entry.portId
}
