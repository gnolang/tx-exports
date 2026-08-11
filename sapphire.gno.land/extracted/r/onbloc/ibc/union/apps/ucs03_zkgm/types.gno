package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"
	tb "gno.land/p/onbloc/ibc/union/zkgm/tokenbucket"
	u256 "gno.land/p/onbloc/math/uint256"

	z "gno.land/p/onbloc/ibc/union/zkgm"
)

const Version = z.PROTOCOL_VERSION

type IApp interface {
	// IApp
	OnChannelOpenInit(_ int, rlm realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, relayer address)
	OnChannelOpenTry(_ int, rlm realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, counterpartyVersion string, relayer address)
	OnChannelOpenAck(_ int, rlm realm, channelId types.ChannelId, counterpartyChannelId types.ChannelId, counterpartyVersion string, relayer address)
	OnChannelOpenConfirm(_ int, rlm realm, channelId types.ChannelId, relayer address)
	OnChannelCloseInit(_ int, rlm realm, channelId types.ChannelId, relayer address)
	OnChannelCloseConfirm(_ int, rlm realm, channelId types.ChannelId, relayer address)
	OnRecvPacket(_ int, rlm realm, packet types.Packet, relayer address, relayerMsg []byte) types.RecvPacketResult
	OnAcknowledgementPacket(_ int, rlm realm, packet types.Packet, acknowledgement []byte, relayer address)
	OnTimeoutPacket(_ int, rlm realm, packet types.Packet, relayer address)

	// IIntentApp
	IAppIntent

	IAppTransfer

	IAppVoucher

	// Read-only relayer/tooling query surface.
	IAppGetter
}

type IAppIntent interface {
	OnIntentRecvPacket(_ int, rlm realm, packet types.Packet, marketMaker address, marketMakerMsg []byte) types.RecvPacketResult
}

// IAppTransfer is the user-initiated send surface. zkgm is a general instruction
// protocol (token order / batch / call / forward), so Send takes a raw
// Instruction rather than a token-transfer shaped argument list.
type IAppTransfer interface {
	Send(_ int, rlm realm, channelId types.ChannelId, timeoutTimestamp types.Timestamp, salt [32]byte, instruction z.Instruction) types.Packet
}

// IAppVoucher is the wrapped-voucher self-service surface: it lets a holder
// grant an allowance or move their own balance directly, without exposing the
// mint/burn capability that Store's Voucher.Ledger() carries.
type IAppVoucher interface {
	VoucherApprove(_ int, rlm realm, ibcDenom string, spender address, amount int64) error
	VoucherTransfer(_ int, rlm realm, ibcDenom string, to address, amount int64) error
}

// IAppGetter is the read-only query surface implemented by the impl and exposed
// by the proxy's getters.gno.
type IAppGetter interface {
	GetTokenBucket(denom string) (*tb.TokenBucket, error)
	GetChannelBalanceV2(channelId types.ChannelId, path *u256.Uint, baseToken string, quoteToken []byte) (*u256.Uint, error)
	GetLockedTokenAmount(denom string) (*u256.Uint, error)
	GetVoucherList(offset, count int) ([]VoucherInfo, error)
	GetVoucherSize() (int, error)
	GetVoucherInfo(ibcDenom string) (VoucherInfo, error)
}

type IStore interface {
	SetTokenOrigin(_ int, rlm realm, denom string, path *u256.Uint)
	GetTokenOrigin(denom string) (*u256.Uint, bool)

	SetChannelBalanceV2(_ int, rlm realm, key string, amount *u256.Uint)
	RemoveChannelBalanceV2(_ int, rlm realm, key string)
	GetChannelBalanceV2(key string) (*u256.Uint, bool)

	SetMetadataImageOf(_ int, rlm realm, denom string, image [32]byte)
	GetMetadataImageOf(denom string) ([32]byte, bool)

	SetForeignToken(_ int, rlm realm, denom string, token []byte)
	GetForeignToken(denom string) ([]byte, bool)

	SetInFlightPacket(_ int, rlm realm, packetHash string, parent types.Packet)
	GetInFlightPacket(packetHash string) (types.Packet, bool)
	RemoveInFlightPacket(_ int, rlm realm, packetHash string)

	SetTokenBucket(_ int, rlm realm, denom string, bucket *tb.TokenBucket)
	GetTokenBucket(denom string) (*tb.TokenBucket, bool)
	RemoveTokenBucket(_ int, rlm realm, denom string)

	SetVoucher(_ int, rlm realm, ibcDenom string, v *Voucher)
	GetVoucher(ibcDenom string) (*Voucher, bool)
	GetVoucherList(offset, count int) []VoucherInfo
	GetVoucherSize() int
	HasVoucher(ibcDenom string) bool

	// AddLockedTokenAmount/GetLockedTokenAmount are managed alongside the
	// voucher methods above: both cover non-escrow custody of a base token
	// (native or grc20) that zkgm cannot supply-burn the way it burns vouchers.
	AddLockedTokenAmount(_ int, rlm realm, denom string, amount *u256.Uint)
	GetLockedTokenAmount(denom string) (*u256.Uint, bool)

	SetReceiver(_ int, rlm realm, path string, receiver z.Zkgmable)
	GetReceiver(path string) (z.Zkgmable, bool)

	SetRateLimitDisabled(_ int, rlm realm, disabled bool)
	RateLimitDisabled() bool
}
