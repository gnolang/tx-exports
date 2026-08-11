package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"
	tb "gno.land/p/onbloc/ibc/union/zkgm/tokenbucket"
	u256 "gno.land/p/onbloc/math/uint256"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
)

// getters.gno implements the read-only IAppGetter surface. Results read the
// injected proxy store and return snapshots so callers do not receive mutable
// proxy-owned pointers.

// GetTokenBucket returns the rate-limit bucket configured for denom.
func (v *ucs03ZkgmV1) GetTokenBucket(denom string) (*tb.TokenBucket, error) {
	bucket, ok := v.store.GetTokenBucket(denom)
	if !ok || bucket == nil {
		return nil, makeError(zkgm.ErrTokenBucketNotFound, denom)
	}

	return cloneTokenBucket(bucket), nil
}

// GetChannelBalanceV2 returns the escrow balance for the v2 channel-balance key.
func (v *ucs03ZkgmV1) GetChannelBalanceV2(channelId types.ChannelId, path *u256.Uint, baseToken string, quoteToken []byte) (*u256.Uint, error) {
	balance, ok := v.store.GetChannelBalanceV2(ChannelBalanceKeyV2(channelId, path, []byte(baseToken), quoteToken))
	if !ok || balance == nil {
		return nil, makeError(zkgm.ErrChannelBalanceV2NotFound, channelId.String())
	}

	return balance.Clone(), nil
}

// GetLockedTokenAmount returns the terminally locked base-token amount for denom.
func (v *ucs03ZkgmV1) GetLockedTokenAmount(denom string) (*u256.Uint, error) {
	total, ok := v.store.GetLockedTokenAmount(denom)
	if !ok || total == nil {
		return u256.Zero(), nil
	}

	return total.Clone(), nil
}

// GetVoucherList returns a page of up to count wrapped voucher tokens starting
// at offset, ordered by denom. An empty page (e.g. offset past the end, or no
// vouchers registered yet) is not an error condition, so this returns an empty
// slice rather than failing; the error return exists only to match the
// calling convention shared by every other IAppGetter method and is always nil.
func (v *ucs03ZkgmV1) GetVoucherList(offset, count int) ([]zkgm.VoucherInfo, error) {
	return v.store.GetVoucherList(offset, count), nil
}

// GetVoucherSize returns the total number of registered vouchers. Like
// GetVoucherList, the error return exists only to match the calling
// convention shared by every other IAppGetter method and is always nil.
func (v *ucs03ZkgmV1) GetVoucherSize() (int, error) {
	return v.store.GetVoucherSize(), nil
}

// GetVoucherInfo returns a snapshot of the single wrapped voucher registered
// for ibcDenom. Unlike GetVoucherList, the caller already holds the key, so
// this reads Store.GetVoucher directly and converts via the voucher's public
// (capability-free) accessors instead of adding a Store-level method.
func (v *ucs03ZkgmV1) GetVoucherInfo(ibcDenom string) (zkgm.VoucherInfo, error) {
	vou, ok := v.store.GetVoucher(ibcDenom)
	if !ok || vou == nil {
		return zkgm.NewVoucherInfo("", "", "", 0, 0, 0), makeError(errVoucherNotFound, ibcDenom)
	}

	return zkgm.NewVoucherInfo(
		ibcDenom,
		vou.Token().GetName(),
		vou.Token().GetSymbol(),
		vou.OriginDecimals(),
		uint8(vou.Token().GetDecimals()),
		vou.Token().TotalSupply(),
	), nil
}

func cloneTokenBucket(bucket *tb.TokenBucket) *tb.TokenBucket {
	return &tb.TokenBucket{
		Capacity:   bucket.Capacity.Clone(),
		Available:  bucket.Available.Clone(),
		RefillRate: bucket.RefillRate.Clone(),
		LastRefill: bucket.LastRefill.Clone(),
	}
}
