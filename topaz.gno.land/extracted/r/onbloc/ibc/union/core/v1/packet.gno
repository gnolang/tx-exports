package core

import (
	"time"

	"gno.land/p/onbloc/ibc/union/app"
	"gno.land/p/onbloc/ibc/union/types"
	core "gno.land/r/onbloc/ibc/union/core"
)

// packet.gno: the packet lifecycle. SendPacket and WriteAcknowledgement are
// caller-authorized (port owner); the recv/ack/timeout/batch/commit-proof
// entrypoints keep their admin gate on the proxy. Apps are notified via cross(rlm).

// SendPacket commits a packet for the caller's port. Per the spec the timeout
// height is always zero; only the timeout timestamp is meaningful.
func (c *coreV1) SendPacket(_ int, rlm realm, sourceChannelId types.ChannelId, timeoutTimestamp types.Timestamp, data []byte) types.Packet {
	assertIsRlmCurrent(0, rlm)
	assertPacketDataSize(data)

	if timeoutTimestamp == 0 {
		panic(makeError(core.ErrTimeoutMustBeSet))
	}

	portId, ok := c.store.GetChannelOwner(sourceChannelId)
	if !ok {
		panic(makeError(core.ErrChannelNotFound, sourceChannelId.String()))
	}

	if string(portId) != rlm.Previous().PkgPath() {
		panic(makeError(core.ErrUnauthorizedPacketSender))
	}

	channel, err := c.getChannel(sourceChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	connection := c.ensureConnectionState(channel.ConnectionId)

	packet := types.Packet{
		SourceChannelId:      sourceChannelId,
		DestinationChannelId: channel.CounterpartyChannelId,
		Data:                 data,
		TimeoutHeight:        0,
		TimeoutTimestamp:     timeoutTimestamp,
	}
	if c.store.HasPacketCommitment(packet) {
		panic(makeError(core.ErrPacketCommitmentAlreadyExists))
	}

	c.store.CommitPacket(0, rlm, packet)

	core.EmitPacketSend(0, rlm, packet, channel, connection)

	return packet
}

// PacketRecv proves a batch of packets committed on the counterparty and
// dispatches each to its app, recording receipts and sync acks.
func (c *coreV1) PacketRecv(_ int, rlm realm, msg types.MsgPacketRecv) {
	assertIsRlmCurrent(0, rlm)

	relayer := rlm.Previous().Address()

	if len(msg.Packets) == 0 {
		panic(makeError(core.ErrNotEnoughPackets))
	}

	destinationChannelId := msg.Packets[0].DestinationChannelId
	channel, err := c.getChannel(destinationChannelId)
	if err != nil {
		panic(err)
	}

	connection := c.ensureConnectionState(channel.ConnectionId)

	proofKey := types.BatchPacketsPath(core.CommitPacketsHash(msg.Packets))
	magic := types.COMMITMENT_MAGIC
	c.verifyMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.Proof, proofKey[:], magic[:])

	portId, _ := c.store.GetChannelOwner(destinationChannelId)
	a, err := c.getAppAtPort(portId)
	if err != nil {
		panic(err)
	}

	nanoTimestamp := uint64(time.Now().UnixNano())

	// reference iterates packets.into_iter().zip(relayer_msgs) (contract.rs L1751):
	// each packet is paired with its relayer msg, so a packet without a matching
	// relayer msg is not dispatched (iteration stops at the shorter array).
	for i := 0; i < len(msg.Packets) && i < len(msg.RelayerMsgs); i++ {
		packet := msg.Packets[i]
		relayerMsg := msg.RelayerMsgs[i]

		skip := c.acceptRecvPacket(0, rlm, packet, destinationChannelId, nanoTimestamp)
		if skip {
			continue
		}

		res := a.OnRecvPacket(cross(rlm), packet, relayer, relayerMsg)
		if err := c.commitSyncAck(0, rlm, packet, channel, connection, res); err != nil {
			panic(err)
		}

		core.EmitPacketRecv(0, rlm, packet, channel, connection, relayerMsg)
	}
}

// IntentPacketRecv settles packets on the proofless market-maker fast path.
func (c *coreV1) IntentPacketRecv(_ int, rlm realm, msg types.MsgIntentPacketRecv) {
	assertIsRlmCurrent(0, rlm)

	marketMaker := rlm.Previous().Address()

	if len(msg.Packets) == 0 {
		panic(makeError(core.ErrNotEnoughPackets))
	}

	destinationChannelId := msg.Packets[0].DestinationChannelId

	channel, err := c.getChannel(destinationChannelId)
	if err != nil {
		panic(err)
	}
	connection := c.ensureConnectionState(channel.ConnectionId)

	portId, _ := c.store.GetChannelOwner(destinationChannelId)
	a, err := c.getAppAtPort(portId)
	if err != nil {
		panic(err)
	}

	intentApp, ok := a.(app.IIntentApp)
	if !ok {
		panic(makeError(core.ErrIntentNotSupported))
	}

	nanoTimestamp := uint64(time.Now().UnixNano())

	// reference iterates packets.into_iter().zip(market_maker_msgs) (contract.rs
	// L1751, intent path): a packet without a matching market-maker msg is not
	// dispatched (iteration stops at the shorter array).
	for i := 0; i < len(msg.Packets) && i < len(msg.MarketMakerMessages); i++ {
		packet := msg.Packets[i]
		marketMakerMsg := msg.MarketMakerMessages[i]

		skip := c.acceptRecvPacket(0, rlm, packet, destinationChannelId, nanoTimestamp)
		if skip {
			continue
		}

		res := intentApp.OnIntentRecvPacket(cross(rlm), packet, marketMaker, marketMakerMsg)
		if err := c.commitSyncAck(0, rlm, packet, channel, connection, res); err != nil {
			panic(err)
		}

		core.EmitIntentPacketRecv(0, rlm, packet, channel, connection, marketMakerMsg)
	}
}

// PacketAcknowledgement proves the counterparty's acks and notifies the app.
func (c *coreV1) PacketAcknowledgement(_ int, rlm realm, msg types.MsgPacketAcknowledgement) {
	assertIsRlmCurrent(0, rlm)

	relayer := rlm.Previous().Address()

	if len(msg.Packets) == 0 {
		panic(makeError(core.ErrNotEnoughPackets))
	}

	first := msg.Packets[0]
	sourceChannelId := first.SourceChannelId
	channel, err := c.getChannel(sourceChannelId)
	if err != nil {
		panic(err)
	}

	connection := c.ensureConnectionState(channel.ConnectionId)

	commitmentKey := types.BatchReceiptsPath(core.CommitPacketsHash(msg.Packets))
	commitmentValue := types.CommitAcks(msg.Acknowledgements)
	c.verifyMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.Proof, commitmentKey[:], commitmentValue[:])

	portId, _ := c.store.GetChannelOwner(sourceChannelId)
	a, _ := c.store.GetAppByPortId(portId)

	for i, ack := range msg.Acknowledgements {
		if i >= len(msg.Packets) {
			break
		}

		packet := msg.Packets[i]
		if packet.SourceChannelId != first.SourceChannelId {
			panic(makeError(core.ErrBatchSameChannelOnly))
		}

		c.markPacketAcknowledged(0, rlm, packet)

		a.OnAcknowledgementPacket(cross(rlm), packet, ack, relayer)
		core.EmitPacketAck(0, rlm, packet, channel, connection, ack)
	}
}

// PacketTimeout proves the counterparty never received the packet and notifies
// the app to refund.
func (c *coreV1) PacketTimeout(_ int, rlm realm, msg types.MsgPacketTimeout) {
	assertIsRlmCurrent(0, rlm)

	relayer := rlm.Previous().Address()
	packet := msg.Packet

	channel, err := c.getChannel(packet.SourceChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	connection := c.ensureConnectionState(channel.ConnectionId)

	lc, err := c.getClient(connection.ClientId)
	if err != nil {
		panic(err)
	}

	proofTimestamp, err := lc.GetTimestampAtHeight(msg.ProofHeight)
	if err != nil {
		panic(err)
	}

	if proofTimestamp == 0 {
		panic(makeError(core.ErrTimeoutProofTimestampNotFound))
	}

	commitmentKey := types.BatchReceiptsPath(core.CommitPacketHash(packet))
	c.verifyNonMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.Proof, commitmentKey[:])

	c.markPacketAcknowledged(0, rlm, packet)

	if packet.TimeoutTimestamp == 0 {
		panic(makeError(core.ErrTimeoutMustBeSet))
	}

	if uint64(packet.TimeoutTimestamp) > uint64(proofTimestamp) {
		panic(makeError(core.ErrPacketTimeoutNotReached))
	}

	portId, _ := c.store.GetChannelOwner(packet.SourceChannelId)
	a, _ := c.store.GetAppByPortId(portId)
	a.OnTimeoutPacket(cross(rlm), packet, relayer)

	core.EmitPacketTimeout(0, rlm, packet, channel, connection)
}

// markPacketAcknowledged is the source-side acknowledge/timeout state machine.
// It verifies the packet's commitment exists and is not already acknowledged,
// then flips it through the store's pure SetPacketAcknowledged primitive. Acks
// and timeouts share it: both retire a sent packet exactly once.
func (c *coreV1) markPacketAcknowledged(_ int, rlm realm, packet types.Packet) {
	commitment, ok := c.store.PacketCommitment(packet.SourceChannelId, packet)
	if !ok {
		panic(makeError(core.ErrPacketCommitmentNotFound))
	}

	if commitment == types.COMMITMENT_MAGIC_ACK {
		panic(makeError(core.ErrPacketAlreadyAcknowledged))
	}

	if commitment != types.COMMITMENT_MAGIC {
		panic(makeError(core.ErrPacketCommitmentNotFound))
	}

	c.store.SetPacketAcknowledged(0, rlm, packet)
}

// CommitMembershipProof verifies and records a membership proof for later reuse.
func (c *coreV1) CommitMembershipProof(_ int, rlm realm, msg types.MsgCommitMembershipProof) {
	assertIsRlmCurrent(0, rlm)

	c.verifyMembership(msg.ClientId, types.NewHeight(msg.ProofHeight), msg.Proof, msg.Path, msg.Value)
	c.store.SaveMembershipProof(0, rlm, msg.ClientId, msg.ProofHeight, msg.Path, types.Keccak(msg.Value))
	core.EmitCommitMembershipProof(0, rlm, msg)
}

// CommitNonMembershipProof verifies and records a non-membership proof.
func (c *coreV1) CommitNonMembershipProof(_ int, rlm realm, msg types.MsgCommitNonMembershipProof) {
	assertIsRlmCurrent(0, rlm)

	if !c.store.ClientExists(msg.ClientId) {
		panic(makeError(core.ErrClientNotFound, msg.ClientId.String()))
	}

	c.verifyNonMembership(msg.ClientId, types.NewHeight(msg.ProofHeight), msg.Proof, msg.Path)
	c.store.SaveNonMembershipProof(0, rlm, msg.ClientId, msg.ProofHeight, msg.Path, types.NON_MEMBERSHIP_COMMITMENT_VALUE)
	core.EmitCommitNonMembershipProof(0, rlm, msg)
}

// BatchSend aggregates several already-committed packets into a single batch
// commitment.
func (c *coreV1) BatchSend(_ int, rlm realm, msg types.MsgBatchSend) {
	assertIsRlmCurrent(0, rlm)

	if len(msg.Packets) < 2 {
		panic(makeError(core.ErrNotEnoughPackets))
	}

	channelId := msg.Packets[0].SourceChannelId
	batchHash := core.CommitPacketsHash(msg.Packets)

	for _, packet := range msg.Packets {
		if packet.SourceChannelId != channelId {
			panic(makeError(core.ErrBatchSameChannelOnly))
		}

		commitment, ok := c.store.PacketCommitment(channelId, packet)
		if !ok || commitment != types.COMMITMENT_MAGIC {
			panic(makeError(core.ErrPacketCommitmentNotFound))
		}

		packetHash := core.CommitPacketsHash([]types.Packet{packet})
		core.EmitBatchSend(0, rlm, channelId, packetHash, batchHash)
	}

	c.store.SaveBatchPackets(0, rlm, channelId, batchHash, types.COMMITMENT_MAGIC)
}

// BatchAcks aggregates the acks of several received packets into a batch receipt.
func (c *coreV1) BatchAcks(_ int, rlm realm, msg types.MsgBatchAcks) {
	assertIsRlmCurrent(0, rlm)

	if len(msg.Packets) < 2 {
		panic(makeError(core.ErrNotEnoughPackets))
	}

	channelId := msg.Packets[0].DestinationChannelId
	batchHash := core.CommitPacketsHash(msg.Packets)

	for i, ack := range msg.Acks {
		if i >= len(msg.Packets) {
			break
		}

		packet := msg.Packets[i]
		if packet.DestinationChannelId != channelId {
			panic(makeError(core.ErrBatchSameChannelOnly))
		}

		packetHash := core.CommitPacketsHash([]types.Packet{packet})
		core.EmitBatchAcks(0, rlm, channelId, packetHash, batchHash)

		commitment, ok := c.store.AcknowledgementReceipt(channelId, packet)
		if !ok {
			panic(makeError(core.ErrPacketCommitmentNotFound))
		}

		if commitment == types.COMMITMENT_MAGIC {
			panic(makeError(core.ErrAcknowledgementEmpty))
		}

		if expected := types.CommitAcks([][]byte{ack}); commitment != expected {
			panic(makeError(core.ErrAcknowledgementMismatch))
		}
	}

	c.store.SaveBatchReceipts(0, rlm, channelId, batchHash, types.CommitAcks(msg.Acks))
}

// WriteAcknowledgement commits a (previously deferred) acknowledgement for a
// received packet. Only the channel's port owner may write it.
func (c *coreV1) WriteAcknowledgement(_ int, rlm realm, msg types.MsgWriteAcknowledgement) {
	assertIsRlmCurrent(0, rlm)

	if len(msg.Acknowledgement) == 0 {
		panic(makeError(core.ErrAcknowledgementEmpty))
	}

	channelId := msg.Packet.DestinationChannelId
	portId, ok := c.store.GetChannelOwner(channelId)

	if !ok {
		panic(makeError(core.ErrChannelNotFound, channelId.String()))
	}

	if string(portId) != rlm.Previous().PkgPath() {
		panic(makeError(core.ErrUnauthorizedAckWriter))
	}

	commitment, ok := c.store.AcknowledgementReceipt(channelId, msg.Packet)
	if !ok {
		panic(makeError(core.ErrPacketReceiptNotFound))
	}

	if commitment != types.COMMITMENT_MAGIC {
		panic(makeError(core.ErrAcknowledgementAlreadyWritten))
	}

	channel, err := c.getChannel(channelId)
	if err != nil {
		panic(err)
	}
	connection := c.ensureConnectionState(channel.ConnectionId)

	c.store.CommitAcknowledgement(0, rlm, msg.Packet, msg.Acknowledgement)

	core.EmitWriteAck(0, rlm, msg.Packet, channel, connection, msg.Acknowledgement)
}

// --- shared recv helpers ---

// acceptRecvPacket validates recv-path invariants and records a packet receipt,
// returning skip=true for an already-received (duplicate) packet.
func (c *coreV1) acceptRecvPacket(_ int, rlm realm, packet types.Packet, batchChannelId types.ChannelId, now uint64) bool {
	if packet.DestinationChannelId != batchChannelId {
		panic(makeError(core.ErrBatchSameChannelOnly))
	}

	channel, err := c.getChannel(packet.DestinationChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	if now >= uint64(packet.TimeoutTimestamp) {
		panic(makeError(core.ErrPacketTimeoutExpired))
	}

	if c.store.HasPacketReceipt(packet) {
		return true
	}

	c.store.SetPacketReceipt(0, rlm, packet)

	return false
}

// commitSyncAck records a synchronous recv result as receipt evidence. Sync
// success/failure must carry a non-empty acknowledgement; async is deferred.
func (c *coreV1) commitSyncAck(_ int, rlm realm, packet types.Packet, channel types.Channel, connection types.Connection, res types.RecvPacketResult) error {
	switch res.Status {
	case types.PacketStatusAsync:
		return nil
	case types.PacketStatusSuccess, types.PacketStatusFailure:
		if len(res.Acknowledgement) == 0 {
			return makeError(core.ErrSyncAckEmpty)
		}

		c.store.CommitAcknowledgement(0, rlm, packet, res.Acknowledgement)
		core.EmitWriteAck(0, rlm, packet, channel, connection, res.Acknowledgement)

		return nil
	default:
		return makeError(core.ErrUnknownPacketStatus)
	}
}

// verifyNonMembership checks a non-membership proof against an active light client.
func (c *coreV1) verifyNonMembership(clientId types.ClientId, height types.Height, proof, key []byte) {
	lc, err := c.getActiveClient(clientId)
	if err != nil {
		panic(err)
	}

	if err := lc.VerifyNonMembership(height.RevisionHeight, key, proof); err != nil {
		panic(err)
	}
}

// getAppAtPort returns the app registered for portId, or an error when no app
// is registered. It centralizes the port -> app lookup the recv and handshake
// callback paths share; the caller (entrypoint) decides whether a miss reverts.
func (c *coreV1) getAppAtPort(portId types.Bytes) (app.IApp, error) {
	a, ok := c.store.GetAppByPortId(portId)
	if !ok {
		return nil, makeError(core.ErrPortNotFound, string(portId))
	}

	return a, nil
}
