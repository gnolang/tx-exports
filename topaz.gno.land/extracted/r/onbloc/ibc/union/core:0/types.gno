package core

import (
	"gno.land/p/onbloc/ibc/union/app"
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
)

// types.gno declares the upgradeable-proxy contracts for the IBC host, mirroring
// the apps/ucs03_zkgm split. core is the proxy: it owns the stable identity
// (package address/path), the Store, and the app registry, and delegates its
// logic to the installed mustGetImpl(). Shared access-manager authority lives in
// gno.land/r/onbloc/ibc/union/access and stays outside the swappable impl.
//
// ICore is the swappable logic surface: it carries every non-admin entrypoint
// (client, connection, channel, packet, app registration). The access-managed
// recovery entrypoints (Force* handshake overrides) and the read-only queries
// stay on the proxy: authorization is not swappable, and queries are pure views.
//
// core/v1 currently implements the client, connection, channel, packet, app
// registry, and query surfaces behind this interface.
type ICore interface {
	// --- Client ---
	RegisterClient(_ int, rlm realm, typ types.ClientType, impl lightclient.ClientImpl)
	HasClient(typ types.ClientType) bool
	CreateClient(_ int, rlm realm, msg types.MsgCreateClient)
	UpdateClient(_ int, rlm realm, msg types.MsgUpdateClient)
	ForceUpdateClient(_ int, rlm realm, msg types.MsgForceUpdateClient)
	Misbehaviour(_ int, rlm realm, msg types.MsgMisbehaviour)

	// --- Connection handshake ---
	ConnectionOpenInit(_ int, rlm realm, msg types.MsgConnectionOpenInit)
	ConnectionOpenTry(_ int, rlm realm, msg types.MsgConnectionOpenTry)
	ConnectionOpenAck(_ int, rlm realm, msg types.MsgConnectionOpenAck)
	ConnectionOpenConfirm(_ int, rlm realm, msg types.MsgConnectionOpenConfirm)
	// Force* are the admin recovery variants that skip counterparty proof
	// verification. The admin gate stays on the proxy.
	ForceConnectionOpenTry(_ int, rlm realm, msg types.MsgConnectionOpenTry)
	ForceConnectionOpenAck(_ int, rlm realm, msg types.MsgConnectionOpenAck)
	ForceConnectionOpenConfirm(_ int, rlm realm, msg types.MsgConnectionOpenConfirm)

	// --- Channel handshake ---
	ChannelOpenInit(_ int, rlm realm, msg types.MsgChannelOpenInit)
	ChannelOpenTry(_ int, rlm realm, msg types.MsgChannelOpenTry)
	ChannelOpenAck(_ int, rlm realm, msg types.MsgChannelOpenAck)
	ChannelOpenConfirm(_ int, rlm realm, msg types.MsgChannelOpenConfirm)
	ChannelCloseInit(_ int, rlm realm, msg types.MsgChannelCloseInit)
	ChannelCloseConfirm(_ int, rlm realm, msg types.MsgChannelCloseConfirm)
	// Force* are the admin recovery variants that skip counterparty proof
	// verification. The admin gate stays on the proxy.
	ForceChannelOpenTry(_ int, rlm realm, msg types.MsgChannelOpenTry)
	ForceChannelOpenAck(_ int, rlm realm, msg types.MsgChannelOpenAck)
	ForceChannelOpenConfirm(_ int, rlm realm, msg types.MsgChannelOpenConfirm)

	// --- Packet lifecycle ---
	SendPacket(_ int, rlm realm, sourceChannelId types.ChannelId, timeoutTimestamp types.Timestamp, data []byte) types.Packet
	PacketRecv(_ int, rlm realm, msg types.MsgPacketRecv)
	IntentPacketRecv(_ int, rlm realm, msg types.MsgIntentPacketRecv)
	PacketAcknowledgement(_ int, rlm realm, msg types.MsgPacketAcknowledgement)
	PacketTimeout(_ int, rlm realm, msg types.MsgPacketTimeout)
	CommitMembershipProof(_ int, rlm realm, msg types.MsgCommitMembershipProof)
	CommitNonMembershipProof(_ int, rlm realm, msg types.MsgCommitNonMembershipProof)
	BatchSend(_ int, rlm realm, msg types.MsgBatchSend)
	BatchAcks(_ int, rlm realm, msg types.MsgBatchAcks)
	WriteAcknowledgement(_ int, rlm realm, msg types.MsgWriteAcknowledgement)

	// --- App registry ---
	RegisterApp(_ int, rlm realm, app app.IApp)

	// Read-only relayer/tooling query surface.
	ICoreGetter
}

// ICoreGetter is the read-only query surface, implemented by the impl and exposed by
// the proxy's getters.gno. Queries that fail on a missing lookup return an error.
// Best-effort Union query mirrors, such as GetClientImpl, return Gno-native
// identifiers; see getters.gno for the notes.
type ICoreGetter interface {
	GetStatus(clientId types.ClientId) (types.Status, error)
	GetClientType(clientId types.ClientId) (types.ClientType, error)
	GetLightClient(clientId types.ClientId) (lightclient.Interface, bool)
	GetClientImpl(clientId types.ClientId) (string, error)
	GetRegisteredClientType(clientType types.ClientType) bool
	GetClientStateBytes(clientId types.ClientId) ([]byte, error)
	GetConsensusStateBytes(clientId types.ClientId, height types.Height) ([]byte, error)
	GetLatestHeight(clientId types.ClientId) (uint64, error)
	GetTimestampAtHeight(clientId types.ClientId, height uint64) (types.Timestamp, error)
	GetConnection(connectionId types.ConnectionId) (types.Connection, error)
	GetChannels() ([]types.Channel, error)
	GetChannel(channelId types.ChannelId) (types.Channel, error)
	GetBatchPacketsCommitment(batchHash types.H256) (types.H256, error)
	GetBatchReceiptsCommitment(batchHash types.H256) (types.H256, error)
	GetCommittedMembershipProofCommitment(clientId types.ClientId, proofHeight uint64, path []byte) (types.H256, error)
	GetCommittedNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) bool
}

// IStore is the proxy-owned persistent state injected into the mustGetImpl(). Setters take
// the borrow-rule (_ int, rlm realm, ...) form; getters are plain. The nested
// per-client structure (consensus/connection/channel/batch trees, chain-param
// commitment mirror) stays private to the Store — the impl operates by id, so the
// encapsulation survives impl upgrades.
//
// IStore exposes the client, connection, channel, packet, app registry, proof,
// batch, and query-support operations used by the installed impl.
type IStore interface {
	// --- Client ---
	RegisterClient(_ int, rlm realm, typ types.ClientType, impl lightclient.ClientImpl)
	ClientRegistry(typ types.ClientType) (lightclient.ClientImpl, bool)
	HasRegisteredClient(typ types.ClientType) bool
	AddClient(_ int, rlm realm, typ types.ClientType, creator address, lc lightclient.Interface) types.ClientId
	GetClientImpl(clientId types.ClientId) (lightclient.ClientImpl, bool)
	ClientExists(clientId types.ClientId) bool
	ClientType(clientId types.ClientId) (types.ClientType, bool)
	GetLightClient(clientId types.ClientId) (lightclient.Interface, bool)
	SetLightClient(_ int, rlm realm, clientId types.ClientId, lc lightclient.Interface) bool
	SaveClientState(_ int, rlm realm, clientId types.ClientId, clientStateBytes []byte) bool
	SaveConsensusState(_ int, rlm realm, clientId types.ClientId, height types.Height, consensusStateBytes []byte) bool
	SaveClientStore(_ int, rlm realm, clientId types.ClientId, key string, value []byte) bool

	// --- Connection ---
	NextConnectionId(_ int, rlm realm) types.ConnectionId
	SaveConnection(_ int, rlm realm, connectionId types.ConnectionId, connection types.Connection)
	GetConnection(connectionId types.ConnectionId) (types.Connection, bool)

	// --- Channel ---
	NextChannelId(_ int, rlm realm) types.ChannelId
	CreateChannel(_ int, rlm realm, channelId types.ChannelId, channel types.Channel, portId types.Bytes)
	SaveChannel(_ int, rlm realm, channelId types.ChannelId, channel types.Channel)
	GetChannels() ([]types.Channel, error)
	GetChannel(channelId types.ChannelId) (types.Channel, bool)
	GetChannelOwner(channelId types.ChannelId) (types.Bytes, bool)

	// --- App registry ---
	GetAppByPortId(portId types.Bytes) (app.IApp, bool)
	HasApp(portId types.Bytes) bool
	RegisterAppAtPort(_ int, rlm realm, portId types.Bytes, a app.IApp)

	// --- Packet commitment (source side) ---
	HasPacketCommitment(packet types.Packet) bool
	CommitPacket(_ int, rlm realm, packet types.Packet)
	// SetPacketAcknowledged flips a packet's source commitment to the acknowledged
	// marker. The acknowledge/timeout state machine (the read-check that the
	// commitment exists and is not already acknowledged) lives in the mustGetImpl().
	SetPacketAcknowledged(_ int, rlm realm, packet types.Packet)

	// --- Packet receipt / acknowledgement (destination side) ---
	HasPacketReceipt(packet types.Packet) bool
	SetPacketReceipt(_ int, rlm realm, packet types.Packet)
	CommitAcknowledgement(_ int, rlm realm, packet types.Packet, ack []byte)
	AcknowledgementReceipt(channelId types.ChannelId, packet types.Packet) (types.H256, bool)

	// --- Batch ---
	PacketCommitment(channelId types.ChannelId, packet types.Packet) (types.H256, bool)
	SaveBatchPackets(_ int, rlm realm, channelId types.ChannelId, batchHash, value types.H256)
	SaveBatchReceipts(_ int, rlm realm, channelId types.ChannelId, batchHash, value types.H256)

	// --- Committed proofs ---
	SaveMembershipProof(_ int, rlm realm, clientId types.ClientId, proofHeight uint64, path []byte, value types.H256)
	SaveNonMembershipProof(_ int, rlm realm, clientId types.ClientId, proofHeight uint64, path []byte, value types.H256)

	// --- Read-only query support ---
	ClientStateBytes(clientId types.ClientId) ([]byte, bool)
	ConsensusStateBytes(clientId types.ClientId, height types.Height) ([]byte, bool)
	BatchPacketsAt(batchHash types.H256) (types.H256, bool)
	BatchReceiptsAt(batchHash types.H256) (types.H256, bool)
	MembershipProofAt(clientId types.ClientId, proofHeight uint64, path []byte) (types.H256, bool)
	HasNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) bool
}

func NewChannel(
	state types.ChannelState,
	connectionId types.ConnectionId,
	counterpartyChannelId types.ChannelId,
	counterpartyPortId types.Bytes,
	version string,
) types.Channel {
	return types.NewChannel(
		state,
		connectionId,
		counterpartyChannelId,
		counterpartyPortId,
		version,
	)
}

func NewConnection(
	state types.ConnectionState,
	clientId,
	counterpartyClientId types.ClientId,
	counterpartyConnectionId types.ConnectionId,
) types.Connection {
	return types.NewConnection(
		state,
		clientId,
		counterpartyClientId,
		counterpartyConnectionId,
	)
}

func NewPacket(
	sourceChannelId,
	destinationChannelId types.ChannelId,
	data []byte,
	timeoutTimestamp types.Timestamp,
) types.Packet {
	return types.NewPacket(
		sourceChannelId,
		destinationChannelId,
		data,
		timeoutTimestamp,
	)
}

func NewRecvPacketResult(status types.PacketStatus, acknowledgement []byte) types.RecvPacketResult {
	return types.NewRecvPacketResult(status, acknowledgement)
}

func NewMsgChannelOpenTry(
	portId []byte,
	channel types.Channel,
	counterpartyVersion string,
	proofInit []byte,
	proofHeight uint64,
	relayer string,
) types.MsgChannelOpenTry {
	return types.NewMsgChannelOpenTry(
		portId,
		channel,
		counterpartyVersion,
		proofInit,
		proofHeight,
		relayer,
	)
}

// The remaining message constructors are wrapped here (rather than calling
// types.NewMsgXXX directly) so the datagram is allocated in core's realm. Under
// the InterRealm v2 ownership rules an object built in the caller's realm and
// then handed to a core entrypoint is read-only (taint); constructing it through
// the owning (core) realm avoids that.

func NewMsgCreateClient(clientType types.ClientType, clientStateBytes, consensusStateBytes []byte) types.MsgCreateClient {
	return types.NewMsgCreateClient(clientType, clientStateBytes, consensusStateBytes)
}

func NewMsgConnectionOpenInit(clientId, counterpartyClientId types.ClientId) types.MsgConnectionOpenInit {
	return types.NewMsgConnectionOpenInit(clientId, counterpartyClientId)
}

func NewMsgConnectionOpenAck(connectionId, counterpartyConnectionId types.ConnectionId, proofTry []byte, proofHeight uint64) types.MsgConnectionOpenAck {
	return types.NewMsgConnectionOpenAck(connectionId, counterpartyConnectionId, proofTry, proofHeight)
}

func NewMsgChannelOpenInit(portId, counterpartyPortId []byte, connectionId types.ConnectionId, version string, relayer string) types.MsgChannelOpenInit {
	return types.NewMsgChannelOpenInit(portId, counterpartyPortId, connectionId, version, relayer)
}

func NewMsgChannelOpenAck(channelId types.ChannelId, counterpartyVersion string, counterpartyChannelId types.ChannelId, proofTry []byte, proofHeight uint64, relayer string) types.MsgChannelOpenAck {
	return types.NewMsgChannelOpenAck(channelId, counterpartyVersion, counterpartyChannelId, proofTry, proofHeight, relayer)
}

func NewMsgPacketRecv(packets []types.Packet, relayerMsgs [][]byte, proof []byte, proofHeight uint64) types.MsgPacketRecv {
	return types.NewMsgPacketRecv(packets, relayerMsgs, proof, proofHeight)
}

func NewMsgPacketAcknowledgement(packets []types.Packet, acknowledgements [][]byte, proof []byte, proofHeight uint64) types.MsgPacketAcknowledgement {
	return types.NewMsgPacketAcknowledgement(packets, acknowledgements, proof, proofHeight)
}
