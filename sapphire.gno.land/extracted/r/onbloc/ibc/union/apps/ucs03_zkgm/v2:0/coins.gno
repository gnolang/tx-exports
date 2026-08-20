package ucs03_zkgm

import (
	"strings"

	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
	"gno.land/r/demo/defi/grc20reg"
)

// ibcDenomPrefix is the prefix of wrapped IBC voucher denoms.
const ibcDenomPrefix = "ibc/"

const (
	IBC_TOKEN   = iota // zkgm-issued voucher; custody is the proxy's voucher-ledger balance
	GRC20_TOKEN        // locally registered grc20; not supported by recovery
	NATIVE_COIN        // banker coin; custody is the proxy's banker balance
)

func isIBCTokenDenom(denom string) bool {
	return strings.HasPrefix(denom, ibcDenomPrefix)
}

func getTokenType(denom string) int {
	if isIBCTokenDenom(denom) {
		return IBC_TOKEN
	}

	if token := grc20reg.Get(denom); token != nil {
		return GRC20_TOKEN
	}

	return NATIVE_COIN
}

// amountInt64 narrows a ledger-precision uint256 to int64 (no scaling).
func amountInt64(amount *u256.Uint) (int64, error) {
	return z.ScaleDownToInt64(amount, 0)
}

// ledgerAmountOf narrows an origin-precision amount to ledger precision, via
// the voucher's ScaleExp when denom is a registered ibc voucher, or identity
// otherwise (native coin — mirrors v1's ledgerAmountOf).
func (v *ucs03ZkgmV2LockedRecovery) ledgerAmountOf(denom string, amount *u256.Uint) (int64, error) {
	if vou, ok := v.store.GetVoucher(denom); ok {
		return vou.ToLedgerAmount(amount)
	}

	return amountInt64(amount)
}
