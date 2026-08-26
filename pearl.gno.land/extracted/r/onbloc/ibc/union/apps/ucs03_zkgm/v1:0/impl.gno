package ucs03_zkgm

import (
	"chain/runtime/unsafe"

	types "gno.land/p/onbloc/ibc/union/types"

	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
	"gno.land/r/onbloc/ibc/union/core"
)

// ucs03ZkgmV1 is the v1 implementation of the zkgm app. It holds the injected
// proxy state (zkgm.IStore) and contains all the protocol logic; the proxy keeps
// only the stable identity, the escrow funds, and the swap point. State writes go
// through the store's borrow-rule setters: v.store.SetXXX(0, rlm, ...).
type ucs03ZkgmV1 struct {
	store zkgm.IStore
}

var _ zkgm.IApp = &ucs03ZkgmV1{}

// NewUCS03ZkgmV1 constructs a fresh v1 impl bound to the injected store.
func NewUCS03ZkgmV1(store zkgm.IStore) zkgm.IApp {
	return &ucs03ZkgmV1{store: store}
}

// OnChannelOpenInit accepts a channel only if it speaks the zkgm protocol version.
func (v *ucs03ZkgmV1) OnChannelOpenInit(_ int, rlm realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, relayer address) {
	assertIsRlmCurrent(0, rlm)

	enforceVersion(version)
}

// OnChannelOpenTry enforces the protocol version on both sides of the handshake.
func (v *ucs03ZkgmV1) OnChannelOpenTry(_ int, rlm realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, counterpartyVersion string, relayer address) {
	assertIsRlmCurrent(0, rlm)

	enforceVersion(version)
	enforceVersion(counterpartyVersion)
}

// OnChannelOpenAck enforces the counterparty's negotiated protocol version.
func (v *ucs03ZkgmV1) OnChannelOpenAck(_ int, rlm realm, channelId types.ChannelId, counterpartyChannelId types.ChannelId, counterpartyVersion string, relayer address) {
	assertIsRlmCurrent(0, rlm)

	enforceVersion(counterpartyVersion)
}

// OnChannelOpenConfirm completes the handshake; zkgm keeps no per-channel state.
func (v *ucs03ZkgmV1) OnChannelOpenConfirm(_ int, rlm realm, channelId types.ChannelId, relayer address) {
	assertIsRlmCurrent(0, rlm)
}

// Channel closing is not supported by zkgm (reference returns an error).
func (v *ucs03ZkgmV1) OnChannelCloseInit(_ int, rlm realm, channelId types.ChannelId, relayer address) {
	assertIsRlmCurrent(0, rlm)

	panic("channel closing is not allowed")
}

func (v *ucs03ZkgmV1) OnChannelCloseConfirm(_ int, rlm realm, channelId types.ChannelId, relayer address) {
	assertIsRlmCurrent(0, rlm)

	panic("channel closing is not allowed")
}

// OnRecvPacket decodes the packet and dispatches it; decode/exec failures return a failure ack rather than aborting.
func (v *ucs03ZkgmV1) OnRecvPacket(_ int, rlm realm, packet types.Packet, relayer address, relayerMsg []byte) types.RecvPacketResult {
	assertIsRlmCurrent(0, rlm)

	zp, err := z.DecodeZkgmPacket(types.CloneBytes(packet.Data))
	if err != nil {
		zkgm.EmitRecvError(0, rlm, packet.SourceChannelId, packet.DestinationChannelId, err.Error())
		return failureResult(universalErrorAck())
	}

	res, err := v.dispatchExecutePacket(0, rlm, packet, relayer, relayerMsg, zp.Salt, zp.Path, zp.Instruction, false)
	if err != nil {
		zkgm.EmitRecvError(0, rlm, packet.SourceChannelId, packet.DestinationChannelId, err.Error())
		return failureResult(universalErrorAck())
	}

	// An only-maker outcome (a maker-only fill that could not be satisfied, or
	// an only-maker child anywhere in a batch) must revert the whole recv tx —
	// no ack is written and any already-applied batch-child mutations are rolled
	// back. This mirrors union's reply handler returning Err(OnlyMaker) for both
	// the single-instruction and batch cases (contract.rs L2530, L2545), and the
	// symmetric guard already in OnIntentRecvPacket. Core does not recover recv
	// panics, so this reverts atomically.
	if isOnlyMakerAck(res.Acknowledgement) {
		panic(errIsOnlyMakerAck)
	}

	return res
}

// OnIntentRecvPacket executes the market-maker fast path. Only-maker outcomes
// abort the intent tx so proven recv can proceed instead. This is also the
// explicit stop point for market-maker fills that require unsupported native
// maker funding.
func (v *ucs03ZkgmV1) OnIntentRecvPacket(_ int, rlm realm, packet types.Packet, marketMaker address, marketMakerMsg []byte) types.RecvPacketResult {
	assertIsRlmCurrent(0, rlm)

	zp, err := z.DecodeZkgmPacket(types.CloneBytes(packet.Data))
	if err != nil {
		zkgm.EmitRecvError(0, rlm, packet.SourceChannelId, packet.DestinationChannelId, err.Error())
		return failureResult(universalErrorAck())
	}

	res, err := v.dispatchExecutePacket(0, rlm, packet, marketMaker, marketMakerMsg, zp.Salt, zp.Path, zp.Instruction, true)
	if err != nil {
		zkgm.EmitRecvError(0, rlm, packet.SourceChannelId, packet.DestinationChannelId, err.Error())
		return failureResult(universalErrorAck())
	}

	if isOnlyMakerAck(res.Acknowledgement) {
		// Intent recv must not silently succeed without a maker fill. Panicking
		// preserves the proven recv fallback path and makes unsupported native
		// market-maker funding fail explicitly until funds plumbing is added.
		panic("only maker")
	}

	return res
}

// OnAcknowledgementPacket routes the ack to its instruction, or to the forwarded parent packet.
func (v *ucs03ZkgmV1) OnAcknowledgementPacket(_ int, rlm realm, packet types.Packet, acknowledgement []byte, relayer address) {
	assertIsRlmCurrent(0, rlm)

	zp, err := z.DecodeZkgmPacket(types.CloneBytes(packet.Data))
	if err != nil {
		panic(err.Error())
	}

	if v.handleForwardChild(0, rlm, packet, zp, acknowledgement) {
		return
	}

	outerAck, err := z.DecodeAck(acknowledgement)
	if err != nil {
		panic(err.Error())
	}

	successful := outerAck.Tag != nil && outerAck.Tag.Eq(tagAckSuccess())
	if err := v.acknowledgeInternal(0, rlm, packet, relayer, zp.Salt, zp.Path, zp.Instruction, successful, outerAck.InnerAck); err != nil {
		panic(err.Error())
	}
}

// OnTimeoutPacket refunds the timed-out instruction, or settles the forwarded parent packet.
func (v *ucs03ZkgmV1) OnTimeoutPacket(_ int, rlm realm, packet types.Packet, relayer address) {
	assertIsRlmCurrent(0, rlm)

	zp, err := z.DecodeZkgmPacket(types.CloneBytes(packet.Data))
	if err != nil {
		panic(err.Error())
	}

	if v.handleForwardChild(0, rlm, packet, zp, universalErrorAck()) {
		return
	}

	if err := v.timeoutInternal(0, rlm, packet, zp.Salt, zp.Path, zp.Instruction); err != nil {
		panic(err.Error())
	}
}

// Send verifies the instruction against the attached funds, namespaces the salt, and emits the packet through core.
func (v *ucs03ZkgmV1) Send(_ int, rlm realm, channelId types.ChannelId, timeoutTimestamp types.Timestamp, salt [32]byte, instruction z.Instruction) types.Packet {
	assertIsRlmCurrent(0, rlm)

	sender := rlm.Previous().Address().String()

	funds := newFunds(parseCoins(""))

	// SAFE: native coins attached with -send live on the chain-root envelope,
	// not on rlm.Previous(). Guard direct user calls before reading
	// unsafe.OriginSend(), then seed the proxy escrow budget from it.
	if rlm.Previous().IsUserCall() {
		sentCoins := unsafe.OriginSend()
		funds = newFunds(sentCoins)
	}

	err := v.verifyInternal(0, rlm, funds, channelId, u256.Zero(), instruction)
	if err != nil {
		panic(err)
	}

	err = funds.assertEmpty()
	if err != nil {
		panic(err)
	}

	// Only user-initiated sends apply DeriveSenderSalt. Forwarded packets are
	// built in forward.gno and use DeriveForwardSalt instead.
	hashedSalt := z.DeriveSenderSalt([]byte(sender), salt)

	data, err := z.EncodeZkgmPacket(z.ZkgmPacket{
		Salt:        hashedSalt,
		Path:        u256.Zero(),
		Instruction: instruction,
	})
	if err != nil {
		panic(err)
	}

	return core.SendPacket(cross(rlm), channelId, timeoutTimestamp, data)
}

// enforceVersion rejects channels that do not speak the zkgm protocol version.
func enforceVersion(version string) {
	if version != zkgm.Version {
		panic("unsupported channel version")
	}
}
