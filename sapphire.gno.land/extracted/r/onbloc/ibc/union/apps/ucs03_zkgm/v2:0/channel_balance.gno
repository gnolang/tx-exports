package ucs03_zkgm

import (
	"encoding/hex"

	types "gno.land/p/onbloc/ibc/union/types"

	u256 "gno.land/p/onbloc/math/uint256"
)

// Precision invariant: channel balances are local vault precision (real custody), not wire precision.

// ChannelBalanceKeyV2 returns the storage key for a v2 channel balance entry.
func ChannelBalanceKeyV2(channelId types.ChannelId, path *u256.Uint, baseToken, quoteToken []byte) string {
	return channelId.String() + "/" + path.ToString() + "/" + hex.EncodeToString(baseToken) + "/" + hex.EncodeToString(quoteToken)
}

// decreaseChannelBalanceV2 subtracts from the escrow balance, erroring on underflow.
func (v *ucs03ZkgmV2LockedRecovery) decreaseChannelBalanceV2(_ int, rlm realm, channelId types.ChannelId, path *u256.Uint, baseToken, quoteToken []byte, amount int64) error {
	key := ChannelBalanceKeyV2(channelId, path, baseToken, quoteToken)

	amountUint256 := u256.NewUint(uint64(amount))

	curAmount, ok := v.store.GetChannelBalanceV2(key)
	if !ok || curAmount == nil || curAmount.Cmp(amountUint256) < 0 {
		return makeError(errChannelBalanceUnderflow)
	}

	calculatedAmount, underflow := u256.Zero().SubOverflow(curAmount, amountUint256)
	if underflow {
		return makeError(errChannelBalanceUnderflow)
	}

	v.store.SetChannelBalanceV2(0, rlm, key, calculatedAmount)

	return nil
}
