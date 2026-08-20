package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"

	z "gno.land/p/onbloc/ibc/union/zkgm"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
)

// ucs03ZkgmV2LockedRecovery is an emergency-only impl: everything except Send
// panics ("recovery impl: X not supported"). Send is repurposed as the
// admin-only escrow-release entrypoint; see its own comment.
type ucs03ZkgmV2LockedRecovery struct {
	store zkgm.IStore
}

var _ zkgm.IApp = &ucs03ZkgmV2LockedRecovery{}

// NewUCS03ZkgmV2LockedRecovery constructs a fresh recovery impl bound to the injected store.
func NewUCS03ZkgmV2LockedRecovery(store zkgm.IStore) zkgm.IApp {
	return &ucs03ZkgmV2LockedRecovery{store: store}
}

func notSupported(name string) string {
	return "recovery impl: " + name + " not supported"
}

func (v *ucs03ZkgmV2LockedRecovery) OnChannelOpenInit(_ int, rlm realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, relayer address) {
	panic(notSupported("OnChannelOpenInit"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnChannelOpenTry(_ int, rlm realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, counterpartyVersion string, relayer address) {
	panic(notSupported("OnChannelOpenTry"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnChannelOpenAck(_ int, rlm realm, channelId types.ChannelId, counterpartyChannelId types.ChannelId, counterpartyVersion string, relayer address) {
	panic(notSupported("OnChannelOpenAck"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnChannelOpenConfirm(_ int, rlm realm, channelId types.ChannelId, relayer address) {
	panic(notSupported("OnChannelOpenConfirm"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnChannelCloseInit(_ int, rlm realm, channelId types.ChannelId, relayer address) {
	panic(notSupported("OnChannelCloseInit"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnChannelCloseConfirm(_ int, rlm realm, channelId types.ChannelId, relayer address) {
	panic(notSupported("OnChannelCloseConfirm"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnRecvPacket(_ int, rlm realm, packet types.Packet, relayer address, relayerMsg []byte) types.RecvPacketResult {
	panic(notSupported("OnRecvPacket"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnIntentRecvPacket(_ int, rlm realm, packet types.Packet, marketMaker address, marketMakerMsg []byte) types.RecvPacketResult {
	panic(notSupported("OnIntentRecvPacket"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnAcknowledgementPacket(_ int, rlm realm, packet types.Packet, acknowledgement []byte, relayer address) {
	panic(notSupported("OnAcknowledgementPacket"))
}

func (v *ucs03ZkgmV2LockedRecovery) OnTimeoutPacket(_ int, rlm realm, packet types.Packet, relayer address) {
	panic(notSupported("OnTimeoutPacket"))
}

func (v *ucs03ZkgmV2LockedRecovery) VoucherApprove(_ int, rlm realm, ibcDenom string, spender address, amount int64) error {
	panic(notSupported("VoucherApprove"))
}

func (v *ucs03ZkgmV2LockedRecovery) VoucherTransfer(_ int, rlm realm, ibcDenom string, to address, amount int64) error {
	panic(notSupported("VoucherTransfer"))
}

// Send is repurposed as the admin-only recovery entrypoint, reachable through
// the proxy's existing SendRaw (no proxy-side change needed). Operand is a
// standard ABI-encoded TokenOrderV2:
//   - Kind: must be TOKEN_ORDER_KIND_ESCROW — the only kind an active escrow can be released as
//   - BaseToken/QuoteToken: the channelBalanceV2 key to release (path always zero)
//   - BaseAmount: origin-token precision, same units as an ordinary Send —
//     ledgerAmountOf downscales via the voucher's ScaleExp for an ibc denom,
//     or passes through unchanged for native coin (origin == ledger there)
//   - Receiver: recipient address string; must pass address.IsValid()
//   - Sender, QuoteAmount, Metadata are ignored
//
// timeoutTimestamp and salt are unused; they exist only to satisfy IAppTransfer.
func (v *ucs03ZkgmV2LockedRecovery) Send(_ int, rlm realm, channelId types.ChannelId, timeoutTimestamp types.Timestamp, salt [32]byte, instruction z.Instruction) types.Packet {
	assertIsRlmCurrent(0, rlm)

	// Reject anything not built with the expected version/opcode instead of decoding loosely.
	if instruction.Version != z.INSTR_VERSION_2 || instruction.Opcode != z.OP_TOKEN_ORDER {
		panic(notSupported("Send: unrecognized version/opcode"))
	}

	order, err := z.DecodeTokenOrderV2(instruction.Operand)
	if err != nil {
		panic(err)
	}

	// A runbook mistake (e.g. reusing an INITIALIZE/UNESCROW operand) must not
	// be reinterpreted as a recovery request.
	if order.Kind != z.TOKEN_ORDER_KIND_ESCROW {
		panic(makeError(errRecoveryUnrecognizedKind))
	}

	v.adminRecoverLockedToken(0, rlm, channelId, order.BaseToken, order.QuoteToken, order.BaseAmount, address(order.Receiver))

	return types.Packet{}
}
