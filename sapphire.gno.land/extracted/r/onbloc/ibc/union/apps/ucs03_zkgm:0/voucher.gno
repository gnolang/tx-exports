package ucs03_zkgm

import (
	"gno.land/p/demo/tokens/grc20"
	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
)

// Voucher bundles a wrapped grc20 token, its private mint/burn ledger,
// and the origin token's decimal precision.
// It is proxy-owned state held in the Store,
// so its mint/burn rights survive impl upgrades.
//
// Packet amounts are in the origin token's decimals;
// the grc20 ledger holds them downscaled to the (possibly capped) ledger decimals,
// so they fit int64.
// MintScaled / BurnScaled / TransferScaled apply that downscale,
// so callers never combine the scale and the ledger by hand;
// the raw int64 ops stay reachable via Ledger().
//
// SECURITY: those methods and Ledger() all hand out the mint/burn capability,
// so a *Voucher must stay impl-gated.
// The Store is injected and never publicly returned,
// so untrusted realms can only read balances via VoucherBalanceOf.
type Voucher struct {
	token          *grc20.Token
	ledger         *grc20.PrivateLedger
	originDecimals uint8
}

// NewVoucher is a crossing-safe constructor,
// so the impl realm can build one without tripping the foreign-composite-literal rule.
// originDecimals is the origin token's precision;
// the ledger token is created at min(originDecimals, ledger cap).
func NewVoucher(token *grc20.Token, ledger *grc20.PrivateLedger, originDecimals uint8) *Voucher {
	return &Voucher{token: token, ledger: ledger, originDecimals: originDecimals}
}

// VoucherInfo is a read-only snapshot of a wrapped voucher's grc20 identity
// for the voucher-list getter. It carries only scalar fields copied out of
// Voucher/Token — no token/ledger handles — so listing vouchers never hands
// out the mint/burn capability that *Voucher.Ledger() exposes.
type VoucherInfo struct {
	Denom          string
	Name           string
	Symbol         string
	OriginDecimals uint8
	LedgerDecimals uint8
	TotalSupply    int64
}

// NewVoucherInfo is a crossing-safe constructor,
// so the impl realm (and test doubles) can build one without tripping the
// foreign-composite-literal rule.
func NewVoucherInfo(denom, name, symbol string, originDecimals, ledgerDecimals uint8, totalSupply int64) VoucherInfo {
	return VoucherInfo{
		Denom:          denom,
		Name:           name,
		Symbol:         symbol,
		OriginDecimals: originDecimals,
		LedgerDecimals: ledgerDecimals,
		TotalSupply:    totalSupply,
	}
}

// Token returns the read-only token handle (safe: balances, metadata).
func (v *Voucher) Token() *grc20.Token { return v.token }

// Ledger returns the mint/burn capability. Callers MUST be impl-gated.
func (v *Voucher) Ledger() *grc20.PrivateLedger { return v.ledger }

// OriginDecimals returns the origin token's precision.
// The scalar is copied across the realm boundary, so impl reads are safe.
func (v *Voucher) OriginDecimals() uint8 { return v.originDecimals }

// ScaleExp is the origin->ledger downscale exponent:
// the low-order digits dropped between origin precision and the ledger token's precision.
// Derived from both stored decimals, so it needs no global constant,
// and clamps to 0 for native/low-decimal tokens.
func (v *Voucher) ScaleExp() int {
	exp := int(v.originDecimals) - v.token.GetDecimals()
	if exp < 0 {
		return 0
	}

	return exp
}

// ToLedgerAmount narrows an origin-precision amount to this voucher's int64 ledger amount,
// rejecting sub-precision dust and int64 overflow.
// MintScaled, BurnScaled, TransferScaled and the impl's pre-flight checks all route through it.
func (v *Voucher) ToLedgerAmount(amount *u256.Uint) (int64, error) {
	return z.ScaleDownToInt64(amount, v.ScaleExp())
}

// MintScaled credits an origin-precision amount, downscaled to the ledger.
// Carries the mint capability; callers MUST be impl-gated.
func (v *Voucher) MintScaled(receiver address, amount *u256.Uint) error {
	n, err := v.ToLedgerAmount(amount)
	if err != nil {
		return err
	}

	return v.ledger.Mint(receiver, n)
}

// BurnScaled debits an origin-precision amount, downscaled to the ledger.
// Carries the burn capability; callers MUST be impl-gated.
func (v *Voucher) BurnScaled(holder address, amount *u256.Uint) error {
	n, err := v.ToLedgerAmount(amount)
	if err != nil {
		return err
	}

	return v.ledger.Burn(holder, n)
}

// TransferScaled moves an origin-precision amount between holders, downscaled to the ledger.
// Carries the ledger capability; callers MUST be impl-gated.
func (v *Voucher) TransferScaled(from, to address, amount *u256.Uint) error {
	n, err := v.ToLedgerAmount(amount)
	if err != nil {
		return err
	}

	return v.ledger.Transfer(from, to, n)
}

// Approve grants spender an allowance on holder's ledger-precision balance.
// Unlike MintScaled/BurnScaled/TransferScaled, the amount is not scaled from
// origin precision: it is a self-service action on the holder's own balance,
// matching the ledger units VoucherBalanceOf already reads.
// Carries the ledger's Approve capability; callers MUST be impl-gated.
func (v *Voucher) Approve(_ int, rlm realm, spender address, amount int64) error {
	teller := v.ledger.ImpersonateTeller(rlm.Previous().Address())
	return teller.Approve(0, rlm, spender, amount)
}

// Transfer moves amount of holder's ledger-precision balance to another
// address. Same scale as Approve: no origin-precision scaling.
// Carries the ledger's Transfer capability; callers MUST be impl-gated.
func (v *Voucher) Transfer(_ int, rlm realm, to address, amount int64) error {
	teller := v.ledger.ImpersonateTeller(rlm.Previous().Address())
	return teller.Transfer(0, rlm, to, amount)
}

// VoucherApprove lets the caller grant spender an allowance on their own
// wrapped-voucher balance for ibcDenom, so the voucher can be used through
// GRC20-composable flows (e.g. Gnoswap) that rely on TransferFrom.
func VoucherApprove(cur realm, ibcDenom string, spender address, amount int64) {
	assertIsNotPaused()

	if err := mustGetImpl().VoucherApprove(0, cur, ibcDenom, spender, amount); err != nil {
		panic(err)
	}
}

// VoucherTransfer lets the caller move their own wrapped-voucher balance for
// ibcDenom directly to another address.
func VoucherTransfer(cur realm, ibcDenom string, to address, amount int64) {
	assertIsNotPaused()

	if err := mustGetImpl().VoucherTransfer(0, cur, ibcDenom, to, amount); err != nil {
		panic(err)
	}
}

// VoucherBalanceOf returns addr's wrapped-voucher balance for ibcDenom, or 0 if none.
// It reads the proxy-owned Store,
// so the balance survives impl upgrades and does not depend on grc20reg's key.
func VoucherBalanceOf(ibcDenom string, addr address) int64 {
	vou, ok := store.GetVoucher(ibcDenom)
	if !ok {
		return 0
	}

	return vou.Token().BalanceOf(addr)
}
