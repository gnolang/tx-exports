package ucs03_zkgm

import (
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/fqname/v0"
	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
	"gno.land/r/demo/defi/grc20reg"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
)

// canonicalDecimals is the ledger precision a wrapped voucher is capped to.
// A source token with more decimals overflows the grc20 int64 ledger,
// so its amounts are downscaled to this precision on the way in,
// and upscaled back on the way out.
const canonicalDecimals = 6

// mintVoucher mints amount of the wrapped voucher for ibcDenom to receiver,
// creating the token on first use.
// The voucher is created before the mint,
// so a first-use mint already has the origin decimals bundled in;
// MintScaled then downscales the origin-precision amount to the ledger.
func (v *ucs03ZkgmV1) mintVoucher(_ int, rlm realm, ibcDenom string, image [32]byte, name, symbol string, decimals uint8, receiver address, amount *u256.Uint) error {
	vou, err := v.getOrCreateVoucher(0, rlm, ibcDenom, image, name, symbol, decimals)
	if err != nil {
		return err
	}

	return vou.MintScaled(receiver, amount)
}

// burnVoucher burns amount of the ibc/ wrapped voucher held by sender.
// Used on send-side UNESCROW (destroy wrapped supply before remote unwrap) and
// maker burn-address ack (burnEscrowedV2). GRC20 and native coins are never
// passed here — they cannot be supply-burned by this realm.
// BurnScaled downscales the origin-precision amount to the ledger.
func (v *ucs03ZkgmV1) burnVoucher(_ int, rlm realm, ibcDenom string, sender address, amount *u256.Uint) error {
	vou, ok := v.store.GetVoucher(ibcDenom)
	if !ok {
		return makeError(errVoucherNotFound, ibcDenom)
	}

	return vou.BurnScaled(sender, amount)
}

// transferVoucher moves amount of the wrapped voucher between holders (market-maker fill).
// TransferScaled downscales the origin-precision amount to the ledger.
func (v *ucs03ZkgmV1) transferVoucher(_ int, rlm realm, ibcDenom string, from, to address, amount *u256.Uint) error {
	vou, ok := v.store.GetVoucher(ibcDenom)
	if !ok {
		return makeError(errVoucherNotFound, ibcDenom)
	}

	return vou.TransferScaled(from, to, amount)
}

// VoucherApprove lets the caller (rlm.Previous(), the address that called the
// proxy) grant spender an allowance on their own wrapped-voucher balance.
// Delegates to Voucher.Approve so mint/burn stay reachable exclusively via
// mintVoucher/burnVoucher above; this never touches Ledger() directly.
func (v *ucs03ZkgmV1) VoucherApprove(_ int, rlm realm, ibcDenom string, spender address, amount int64) error {
	assertIsRlmCurrent(0, rlm)

	vou, ok := v.store.GetVoucher(ibcDenom)
	if !ok {
		return makeError(errVoucherNotFound, ibcDenom)
	}

	return vou.Approve(0, rlm, spender, amount)
}

// VoucherTransfer lets the caller (rlm.Previous(), the address that called the
// proxy) move their own wrapped-voucher balance directly to another address.
// Same capability scope as VoucherApprove: Transfer only, no mint/burn.
func (v *ucs03ZkgmV1) VoucherTransfer(_ int, rlm realm, ibcDenom string, to address, amount int64) error {
	assertIsRlmCurrent(0, rlm)

	vou, ok := v.store.GetVoucher(ibcDenom)
	if !ok {
		return makeError(errVoucherNotFound, ibcDenom)
	}

	return vou.Transfer(0, rlm, to, amount)
}

// getOrCreateVoucher returns the wrapped grc20 voucher for ibcDenom, creating and registering it on first use.
func (v *ucs03ZkgmV1) getOrCreateVoucher(_ int, rlm realm, ibcDenom string, image [32]byte, name, symbol string, decimals uint8) (*zkgm.Voucher, error) {
	if vou, ok := v.store.GetVoucher(ibcDenom); ok {
		return vou, nil
	}

	if name == "" {
		name = ibcDenom
	}

	symbol = sanitizeVoucherSymbol(symbol, ibcDenom)

	// grc20reg keys its registry by (registering realm, token symbol) and
	// panics on a repeat key. Every voucher this realm registers shares the
	// same realm path, so a symbol collision here always means a different
	// ibcDenom already claimed this symbol. Check the prospective key
	// ourselves so that case fails with a controlled error instead of a panic.
	key := fqname.Construct(rlm.PkgPath(), symbol)
	if grc20reg.Get(key) != nil {
		return nil, makeError(errVoucherSymbolAlreadyRegistered, symbol)
	}

	// The grc20 ledger is int64,
	// so a source token above canonicalDecimals is created at canonicalDecimals.
	// The origin decimals are bundled into the voucher (see Voucher.ScaleExp),
	// so only the local ledger is downscaled; the packet keeps origin precision.
	ledgerDecimals := decimals
	if scaleExpForDecimals(decimals) > 0 {
		ledgerDecimals = canonicalDecimals
	}

	token, ledger := grc20.NewToken(name, symbol, int(ledgerDecimals), 0, rlm)
	grc20reg.Register(cross(rlm), token, strings.TrimPrefix(ibcDenom, ibcDenomPrefix))

	// originDecimals travels with the token,
	// so every mint/burn/transfer derives the same scale from it and the ledger token,
	// with no parallel map to keep in sync.
	voucher := zkgm.NewVoucher(token, ledger, decimals)
	v.store.SetVoucher(0, rlm, ibcDenom, voucher)

	return voucher, nil
}

// ledgerAmountOf downscales an origin-precision amount to the ledger amount for a denom.
// It delegates to Voucher.ToLedgerAmount when a voucher exists,
// otherwise it is an identity narrow for native/low-decimal denoms.
// Used by the token-order pre-flight checks, which hold only a denom string.
func (v *ucs03ZkgmV1) ledgerAmountOf(ibcDenom string, amount *u256.Uint) (int64, error) {
	if vou, ok := v.store.GetVoucher(ibcDenom); ok {
		return vou.ToLedgerAmount(amount)
	}

	return amountInt64(amount)
}

// scaleExpOf returns the origin->ledger downscale exponent registered for a
// denom, or 0 when no voucher exists for it (native and low-decimal tokens).
func (v *ucs03ZkgmV1) scaleExpOf(ibcDenom string) int {
	if vou, ok := v.store.GetVoucher(ibcDenom); ok {
		return vou.ScaleExp()
	}

	return 0
}

// sanitizeVoucherSymbol derives a grc20-legal symbol (<=MaxSymbolLen, [A-Za-z0-9_-])
// from the candidate, falling back to a prefix of the IBC hash when empty.
func sanitizeVoucherSymbol(candidate, ibcDenom string) string {
	out := make([]byte, 0, grc20.MaxSymbolLen)
	for i := 0; i < len(candidate) && len(out) < grc20.MaxSymbolLen; i++ {
		c := candidate[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' {
			out = append(out, c)
		}
	}

	if len(out) == 0 {
		fallback := strings.TrimPrefix(ibcDenom, ibcDenomPrefix)
		if len(fallback) > grc20.MaxSymbolLen {
			fallback = fallback[:grc20.MaxSymbolLen]
		}

		return fallback
	}

	return string(out)
}

// scaleExpForDecimals returns the origin->ledger downscale exponent for `decimals`:
// the low-order digits dropped so the ledger holds canonicalDecimals.
// Tokens at or below canonicalDecimals return 0.
// Used at creation to cap the ledger,
// and by the INITIALIZE pre-flight check before a voucher exists.
func scaleExpForDecimals(decimals uint8) int {
	if int(decimals) > canonicalDecimals {
		return int(decimals) - canonicalDecimals
	}

	return 0
}

// amountInt64 narrows a uint256 to int64 for the native banker/grc20 paths (no scaling).
// It is the scaleExp-0 case of the shared downscaler,
// kept as a named helper for the native call sites (funds.sub, sendNative).
func amountInt64(amount *u256.Uint) (int64, error) {
	return z.ScaleDownToInt64(amount, 0)
}
