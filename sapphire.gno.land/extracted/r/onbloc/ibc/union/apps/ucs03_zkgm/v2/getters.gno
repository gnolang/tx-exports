package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"
	tb "gno.land/p/onbloc/ibc/union/zkgm/tokenbucket"
	u256 "gno.land/p/onbloc/math/uint256"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
)

// getters.gno implements IAppGetter; results are snapshots, not mutable proxy-owned pointers.

// GetTokenBucket returns the rate-limit bucket configured for denom.
func (v *ucs03ZkgmV2LockedRecovery) GetTokenBucket(denom string) (*tb.TokenBucket, error) {
	bucket, ok := v.store.GetTokenBucket(denom)
	if !ok || bucket == nil {
		return nil, makeError(zkgm.ErrTokenBucketNotFound, denom)
	}

	return cloneTokenBucket(bucket), nil
}

// GetChannelBalanceV2 returns the escrow balance for the v2 channel-balance key.
func (v *ucs03ZkgmV2LockedRecovery) GetChannelBalanceV2(channelId types.ChannelId, path *u256.Uint, baseToken string, quoteToken []byte) (*u256.Uint, error) {
	balance, ok := v.store.GetChannelBalanceV2(ChannelBalanceKeyV2(channelId, path, []byte(baseToken), quoteToken))
	if !ok || balance == nil {
		return nil, makeError(zkgm.ErrChannelBalanceV2NotFound, channelId.String())
	}

	return balance.Clone(), nil
}

// GetLockedTokenAmount returns the terminally locked base-token amount for denom.
func (v *ucs03ZkgmV2LockedRecovery) GetLockedTokenAmount(denom string) (*u256.Uint, error) {
	total, ok := v.store.GetLockedTokenAmount(denom)
	if !ok || total == nil {
		return u256.Zero(), nil
	}

	return total.Clone(), nil
}

// GetVoucherList returns a page of up to count vouchers starting at offset. The
// error return is always nil; it exists only to match IAppGetter's convention.
func (v *ucs03ZkgmV2LockedRecovery) GetVoucherList(offset, count int) ([]zkgm.VoucherInfo, error) {
	return v.store.GetVoucherList(offset, count), nil
}

// GetVoucherSize returns the total number of registered vouchers (error always nil).
func (v *ucs03ZkgmV2LockedRecovery) GetVoucherSize() (int, error) {
	return v.store.GetVoucherSize(), nil
}

// GetVoucherInfo returns a snapshot of the single voucher registered for ibcDenom.
func (v *ucs03ZkgmV2LockedRecovery) GetVoucherInfo(ibcDenom string) (zkgm.VoucherInfo, error) {
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
