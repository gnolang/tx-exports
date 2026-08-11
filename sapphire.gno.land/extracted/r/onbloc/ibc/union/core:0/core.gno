package core

import (
	"gno.land/p/onbloc/ibc/union/types"
	"gno.land/r/onbloc/ibc/union/access"
)

// core.gno is the packet-lifecycle entrypoint surface. Each function delegates
// its logic to the installed impl; the admin-gated entrypoints keep their admin
// gate on the proxy. SendPacket and WriteAcknowledgement are caller/port-owner
// authorized inside the mustGetImpl().

// SendPacket commits a packet for the caller's port.
func SendPacket(cur realm, sourceChannelId types.ChannelId, timeoutTimestamp types.Timestamp, data []byte) types.Packet {
	return mustGetImpl().SendPacket(0, cur, sourceChannelId, timeoutTimestamp, data)
}

// PacketRecv proves and dispatches a batch of received packets.
func PacketRecv(cur realm, msg types.MsgPacketRecv) {
	access.AssertCanCall(0, cur, SelectorPacketRecv)
	mustGetImpl().PacketRecv(0, cur, msg)
}

// IntentPacketRecv settles packets on the proofless market-maker fast path.
func IntentPacketRecv(cur realm, msg types.MsgIntentPacketRecv) {
	access.AssertCanCall(0, cur, SelectorIntentPacketRecv)
	mustGetImpl().IntentPacketRecv(0, cur, msg)
}

// PacketAcknowledgement proves the counterparty acks and notifies the app.
func PacketAcknowledgement(cur realm, msg types.MsgPacketAcknowledgement) {
	access.AssertCanCall(0, cur, SelectorPacketAck)
	mustGetImpl().PacketAcknowledgement(0, cur, msg)
}

// PacketTimeout proves a packet was never received and notifies the app.
func PacketTimeout(cur realm, msg types.MsgPacketTimeout) {
	access.AssertCanCall(0, cur, SelectorPacketTimeout)
	mustGetImpl().PacketTimeout(0, cur, msg)
}

// CommitMembershipProof verifies and records a membership proof.
func CommitMembershipProof(cur realm, msg types.MsgCommitMembershipProof) {
	access.AssertCanCall(0, cur, SelectorCommitMembershipProof)
	mustGetImpl().CommitMembershipProof(0, cur, msg)
}

// CommitNonMembershipProof verifies and records a non-membership proof.
func CommitNonMembershipProof(cur realm, msg types.MsgCommitNonMembershipProof) {
	access.AssertCanCall(0, cur, SelectorCommitNonMembershipProof)
	mustGetImpl().CommitNonMembershipProof(0, cur, msg)
}

// BatchSend aggregates already-committed packets into a batch commitment.
func BatchSend(cur realm, msg types.MsgBatchSend) {
	access.AssertCanCall(0, cur, SelectorBatchSend)
	mustGetImpl().BatchSend(0, cur, msg)
}

// BatchAcks aggregates the acks of received packets into a batch receipt.
func BatchAcks(cur realm, msg types.MsgBatchAcks) {
	access.AssertCanCall(0, cur, SelectorBatchAcks)
	mustGetImpl().BatchAcks(0, cur, msg)
}

// WriteAcknowledgement commits a deferred acknowledgement for a received packet.
func WriteAcknowledgement(cur realm, msg types.MsgWriteAcknowledgement) {
	mustGetImpl().WriteAcknowledgement(0, cur, msg)
}
