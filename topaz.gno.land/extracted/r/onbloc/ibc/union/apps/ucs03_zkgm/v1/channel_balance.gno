package ucs03_zkgm

import (
	"encoding/hex"

	types "gno.land/p/onbloc/ibc/union/types"

	u256 "gno.land/p/onbloc/math/uint256"
)

// Precision invariant: channel balances are denominated in LOCAL VAULT precision —
// the actual escrowed amount held on this chain (the grc20 ledger for vouchers,
// the banker for native), 1:1 with custody — NOT the wire/counterparty precision.

// ChannelBalanceKeyV2 returns the storage key for a v2 channel balance entry.
func ChannelBalanceKeyV2(channelId types.ChannelId, path *u256.Uint, baseToken, quoteToken []byte) string {
	return channelId.String() + "/" + path.ToString() + "/" + hex.EncodeToString(baseToken) + "/" + hex.EncodeToString(quoteToken)
}

// increaseChannelBalanceV2 adds amount to the (channel, path, base, quote) escrow balance.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L3272-L3299
func (v *ucs03ZkgmV1) increaseChannelBalanceV2(_ int, rlm realm, channelId types.ChannelId, path *u256.Uint, baseToken, quoteToken []byte, amount int64) error {
	key := ChannelBalanceKeyV2(channelId, path, baseToken, quoteToken)

	curAmount, ok := v.store.GetChannelBalanceV2(key)
	if !ok || curAmount == nil {
		curAmount = u256.Zero()
	}

	amountUint256 := u256.NewUint(uint64(amount))

	// silently storing a smaller balance. This entrypoint returns no error,
	// so an overflow aborts the tx via panic.
	calculatedAmount, overflow := u256.Zero().AddOverflow(curAmount, amountUint256)
	if overflow {
		return makeError(errChannelBalanceOverflow)
	}

	v.store.SetChannelBalanceV2(0, rlm, key, calculatedAmount)

	return nil
}

// decreaseChannelBalanceV2 subtracts from the escrow balance, erroring on underflow and preserving a zero entry.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L3241-L3268
func (v *ucs03ZkgmV1) decreaseChannelBalanceV2(_ int, rlm realm, channelId types.ChannelId, path *u256.Uint, baseToken, quoteToken []byte, amount int64) error {
	key := ChannelBalanceKeyV2(channelId, path, baseToken, quoteToken)

	amountUint256 := u256.NewUint(uint64(amount))

	curAmount, ok := v.store.GetChannelBalanceV2(key)
	if !ok || curAmount == nil || curAmount.Cmp(amountUint256) < 0 {
		return makeError(errChannelBalanceUnderflow)
	}

	// This entrypoint returns an error, so an underflow aborts the tx via return.
	calculatedAmount, underflow := u256.Zero().SubOverflow(curAmount, amountUint256)
	if underflow {
		return makeError(errChannelBalanceUnderflow)
	}

	v.store.SetChannelBalanceV2(0, rlm, key, calculatedAmount)

	return nil
}
