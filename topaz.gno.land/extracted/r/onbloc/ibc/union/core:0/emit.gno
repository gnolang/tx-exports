package core

import (
	"gno.land/p/onbloc/ibc/union/types"
)

// EmitRegisterClient emits the RegisterClient host event.
func EmitRegisterClient(_ int, rlm realm, clientType types.ClientType) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitRegisterClientEvent(clientType)
}

// EmitCreateClient emits the CreateClient host event.
func EmitCreateClient(_ int, rlm realm, clientId types.ClientId, clientType types.ClientType, counterpartyChainId string) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitCreateClientEvent(clientId, clientType, counterpartyChainId)
}

// EmitUpdateClient emits the UpdateClient host event.
func EmitUpdateClient(_ int, rlm realm, clientId types.ClientId, height types.Height) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitUpdateClientEvent(clientId, height)
}

// EmitForceUpdateClient emits the ForceUpdateClient host event.
func EmitForceUpdateClient(_ int, rlm realm, clientId types.ClientId, height types.Height) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitForceUpdateClientEvent(clientId, height)
}

// EmitMisbehaviour emits the Misbehaviour host event.
func EmitMisbehaviour(_ int, rlm realm, clientId types.ClientId) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitMisbehaviourEvent(clientId)
}

// EmitConnectionOpenInit emits the ConnectionOpenInit host event.
func EmitConnectionOpenInit(_ int, rlm realm, connectionId types.ConnectionId, clientId, counterpartyClientId types.ClientId) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitConnectionOpenInitEvent(connectionId, clientId, counterpartyClientId)
}

// EmitConnectionOpenTry emits the ConnectionOpenTry host event.
func EmitConnectionOpenTry(_ int, rlm realm, connectionId types.ConnectionId, clientId, counterpartyClientId types.ClientId, counterpartyConnectionId types.ConnectionId) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitConnectionOpenTryEvent(connectionId, clientId, counterpartyClientId, counterpartyConnectionId)
}

// EmitConnectionOpenAck emits the ConnectionOpenAck host event.
func EmitConnectionOpenAck(_ int, rlm realm, connectionId types.ConnectionId, clientId, counterpartyClientId types.ClientId, counterpartyConnectionId types.ConnectionId) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitConnectionOpenAckEvent(connectionId, clientId, counterpartyClientId, counterpartyConnectionId)
}

// EmitConnectionOpenConfirm emits the ConnectionOpenConfirm host event.
func EmitConnectionOpenConfirm(_ int, rlm realm, connectionId types.ConnectionId, clientId, counterpartyClientId types.ClientId, counterpartyConnectionId types.ConnectionId) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitConnectionOpenConfirmEvent(connectionId, clientId, counterpartyClientId, counterpartyConnectionId)
}

// ConnectionValue returns the H256 commitment value of a connection, exposed so
// the impl can build the expected counterparty value for membership proofs.
func ConnectionValue(connection types.Connection) types.H256 {
	return connectionValue(connection)
}

// ChannelValue returns the H256 commitment value of a channel, exposed so the
// impl can build the expected counterparty value for membership proofs.
func ChannelValue(channel types.Channel) types.H256 {
	return channelValue(channel)
}

// EmitChannelOpenInit emits the ChannelOpenInit host event.
func EmitChannelOpenInit(_ int, rlm realm, portId types.Bytes, channelId types.ChannelId, channel types.Channel, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitChannelOpenInitEvent(portId, channelId, channel, connection)
}

// EmitChannelOpenTry emits the ChannelOpenTry host event.
func EmitChannelOpenTry(_ int, rlm realm, portId types.Bytes, channelId types.ChannelId, channel types.Channel, counterpartyVersion string, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitChannelOpenTryEvent(portId, channelId, channel, counterpartyVersion, connection)
}

// EmitChannelOpenAck emits the ChannelOpenAck host event.
func EmitChannelOpenAck(_ int, rlm realm, portId types.Bytes, channelId types.ChannelId, channel types.Channel, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitChannelOpenAckEvent(portId, channelId, channel, connection)
}

// EmitChannelOpenConfirm emits the ChannelOpenConfirm host event.
func EmitChannelOpenConfirm(_ int, rlm realm, portId types.Bytes, channelId types.ChannelId, channel types.Channel, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitChannelOpenConfirmEvent(portId, channelId, channel, connection)
}

// EmitChannelCloseInit emits the ChannelCloseInit host event.
func EmitChannelCloseInit(_ int, rlm realm, portId types.Bytes, channelId types.ChannelId, channel types.Channel, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitChannelCloseInitEvent(portId, channelId, channel, connection)
}

// EmitChannelCloseConfirm emits the ChannelCloseConfirm host event.
func EmitChannelCloseConfirm(_ int, rlm realm, portId types.Bytes, channelId types.ChannelId, channel types.Channel, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitChannelCloseConfirmEvent(portId, channelId, channel, connection)
}

// EmitAppRegistered emits the AppRegistered host event.
func EmitAppRegistered(_ int, rlm realm, portId []byte, registrarPkgPath string, adminOverride bool) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitAppRegisteredEvent(portId, registrarPkgPath, adminOverride)
}

// --- Packet lifecycle: pure helpers and event emitters exposed to the impl ---

// CommitPacketHash returns the union commitment hash of a single packet.
func CommitPacketHash(packet types.Packet) types.H256 {
	return commitPacketHash(packet)
}

// CommitPacketsHash returns the union commitment hash of a packet batch.
func CommitPacketsHash(packets []types.Packet) types.H256 {
	return commitPacketsHash(packets)
}

// EmitPacketSend emits the PacketSend host event.
func EmitPacketSend(_ int, rlm realm, packet types.Packet, sourceChannel types.Channel, sourceConnection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitPacketSendEvent(packet, sourceChannel, sourceConnection)
}

// EmitPacketRecv emits the PacketRecv host event.
func EmitPacketRecv(_ int, rlm realm, packet types.Packet, destinationChannel types.Channel, connection types.Connection, relayerMsg []byte) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	if !IsValidEventSize(packet.Data, relayerMsg) {
		panic(makeError(ErrPacketCombinedDataTooLarge))
	}

	emitPacketRecvEvent(PacketRecvEvent, packet, destinationChannel, connection, relayerMsg)
}

// EmitIntentPacketRecv emits the IntentPacketRecv host event.
func EmitIntentPacketRecv(_ int, rlm realm, packet types.Packet, destinationChannel types.Channel, connection types.Connection, marketMakerMsg []byte) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	if !IsValidEventSize(packet.Data, marketMakerMsg) {
		panic(makeError(ErrPacketCombinedDataTooLarge))
	}

	emitPacketRecvEvent(IntentPacketRecvEvent, packet, destinationChannel, connection, marketMakerMsg)
}

// EmitPacketAck emits the PacketAck host event.
func EmitPacketAck(_ int, rlm realm, packet types.Packet, sourceChannel types.Channel, connection types.Connection, acknowledgement []byte) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	if !IsValidEventSize(packet.Data, acknowledgement) {
		panic(makeError(ErrPacketCombinedDataTooLarge))
	}

	emitPacketAckEvent(packet, sourceChannel, connection, acknowledgement)
}

// EmitPacketTimeout emits the PacketTimeout host event.
func EmitPacketTimeout(_ int, rlm realm, packet types.Packet, sourceChannel types.Channel, connection types.Connection) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	if !IsValidEventSize(packet.Data) {
		panic(makeError(ErrPacketCombinedDataTooLarge))
	}

	emitPacketTimeoutEvent(packet, sourceChannel, connection)
}

// EmitWriteAck emits the WriteAck host event.
func EmitWriteAck(_ int, rlm realm, packet types.Packet, destinationChannel types.Channel, connection types.Connection, acknowledgement []byte) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	if !IsValidEventSize(packet.Data, acknowledgement) {
		panic(makeError(ErrPacketCombinedDataTooLarge))
	}

	emitWriteAckEvent(packet, destinationChannel, connection, acknowledgement)
}

// EmitBatchSend emits the BatchSend host event.
func EmitBatchSend(_ int, rlm realm, channelId types.ChannelId, packetHash, batchHash types.H256) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitBatchSendEvent(channelId, packetHash, batchHash)
}

// EmitBatchAcks emits the BatchAcks host event.
func EmitBatchAcks(_ int, rlm realm, channelId types.ChannelId, packetHash, batchHash types.H256) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitBatchAcksEvent(channelId, packetHash, batchHash)
}

// EmitCommitMembershipProof emits the CommitMembershipProof host event.
func EmitCommitMembershipProof(_ int, rlm realm, msg types.MsgCommitMembershipProof) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitCommitMembershipProofEvent(msg)
}

// EmitCommitNonMembershipProof emits the CommitNonMembershipProof host event.
func EmitCommitNonMembershipProof(_ int, rlm realm, msg types.MsgCommitNonMembershipProof) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitCommitNonMembershipProofEvent(msg)
}
