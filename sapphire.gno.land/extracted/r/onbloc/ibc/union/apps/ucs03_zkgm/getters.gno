package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"
	tb "gno.land/p/onbloc/ibc/union/zkgm/tokenbucket"
	u256 "gno.land/p/onbloc/math/uint256"
)

// GetTokenBucket returns a snapshot of the rate-limit bucket configured for denom.
func GetTokenBucket(denom string) (*tb.TokenBucket, error) {
	return mustGetImpl().GetTokenBucket(denom)
}

// GetChannelBalanceV2 returns the escrow balance for the v2 channel-balance key.
func GetChannelBalanceV2(channelId types.ChannelId, path *u256.Uint, baseToken string, quoteToken []byte) (*u256.Uint, error) {
	return mustGetImpl().GetChannelBalanceV2(channelId, path, baseToken, quoteToken)
}

// GetLockedTokenAmount returns the total terminally locked base-token amount for denom.
func GetLockedTokenAmount(denom string) (*u256.Uint, error) {
	return mustGetImpl().GetLockedTokenAmount(denom)
}

// GetVoucherList returns a page of up to count wrapped voucher tokens starting
// at offset, ordered by denom.
func GetVoucherList(offset, count int) ([]VoucherInfo, error) {
	return mustGetImpl().GetVoucherList(offset, count)
}

// GetVoucherInfo returns a snapshot of the single wrapped voucher registered for ibcDenom.
func GetVoucherInfo(ibcDenom string) (VoucherInfo, error) {
	return mustGetImpl().GetVoucherInfo(ibcDenom)
}

// GetVoucherSize returns the total number of registered vouchers, i.e. the
// key count callers need to drive GetVoucherList's offset/count pagination.
func GetVoucherSize() (int, error) {
	return mustGetImpl().GetVoucherSize()
}
