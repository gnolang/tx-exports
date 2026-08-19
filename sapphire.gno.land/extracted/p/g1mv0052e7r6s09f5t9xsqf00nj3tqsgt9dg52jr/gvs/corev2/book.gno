package corev2

import "gno.land/p/nt/avl/v0"

// BPSDenom is 100% in basis points.
const BPSDenom int64 = 10_000

// Book is the share ledger for one vault. Fields stay unexported so foreign
// packages cannot mutate totals or alias the share tree.
type Book struct {
	totalAssets int64
	totalShares int64
	shares      avl.Tree
}

// NewBook returns an empty share ledger.
func NewBook() *Book {
	return &Book{}
}

// TotalAssets is the want-token amount the book currently attributes to depositors.
func (b *Book) TotalAssets() int64 { return b.totalAssets }

// TotalShares is the outstanding share supply.
func (b *Book) TotalShares() int64 { return b.totalShares }

// SharesOf returns the caller's minted shares. Missing accounts are zero.
func (b *Book) SharesOf(addr address) int64 {
	if addr == address("") {
		return 0
	}
	v := b.shares.Get(addr.String())
	if v == nil {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		panic("corrupt share entry")
	}
	return n
}

// PreviewDeposit is the shares minted for `assets` at the current price.
func (b *Book) PreviewDeposit(assets int64) int64 {
	if assets <= 0 {
		panic("assets must be positive")
	}
	if b.totalShares == 0 || b.totalAssets == 0 {
		return assets
	}
	return mulDiv(assets, b.totalShares, b.totalAssets)
}

// PreviewRedeem is the assets returned for `shares` at the current price.
func (b *Book) PreviewRedeem(shares int64) int64 {
	if shares <= 0 {
		panic("shares must be positive")
	}
	if b.totalShares == 0 {
		panic("no shares")
	}
	if shares == b.totalShares {
		return b.totalAssets
	}
	return mulDiv(shares, b.totalAssets, b.totalShares)
}

// Deposit credits `addr` with newly minted shares against `assets`.
func (b *Book) Deposit(addr address, assets int64) int64 {
	if addr == address("") {
		panic("empty address")
	}
	minted := b.PreviewDeposit(assets)
	if minted <= 0 {
		panic("zero shares")
	}
	nextAssets, ok := add64(b.totalAssets, assets)
	if !ok {
		panic("assets overflow")
	}
	nextShares, ok := add64(b.totalShares, minted)
	if !ok {
		panic("shares overflow")
	}
	held := b.SharesOf(addr)
	nextHeld, ok := add64(held, minted)
	if !ok {
		panic("account shares overflow")
	}
	b.totalAssets = nextAssets
	b.totalShares = nextShares
	b.shares.Set(addr.String(), nextHeld)
	return minted
}

// Withdraw burns `shares` from `addr` and returns the matching asset amount.
func (b *Book) Withdraw(addr address, shares int64) int64 {
	if addr == address("") {
		panic("empty address")
	}
	held := b.SharesOf(addr)
	if shares > held {
		panic("insufficient shares")
	}
	assets := b.PreviewRedeem(shares)
	if assets <= 0 {
		panic("zero assets")
	}
	if assets > b.totalAssets {
		panic("insolvent")
	}
	b.totalAssets -= assets
	b.totalShares -= shares
	remain := held - shares
	if remain == 0 {
		b.shares.Remove(addr.String())
	} else {
		b.shares.Set(addr.String(), remain)
	}
	return assets
}

// AddProfit increases totalAssets without minting shares (harvest / donation).
func (b *Book) AddProfit(assets int64) {
	if assets <= 0 {
		panic("profit must be positive")
	}
	if b.totalShares == 0 {
		panic("no depositors")
	}
	next, ok := add64(b.totalAssets, assets)
	if !ok {
		panic("assets overflow")
	}
	b.totalAssets = next
}

// TakeLoss decreases totalAssets (protocol fee taken from harvest before this
// is not a loss; use this only when the adapter reports a realized drawdown).
func (b *Book) TakeLoss(assets int64) {
	if assets <= 0 {
		panic("loss must be positive")
	}
	if assets > b.totalAssets {
		panic("loss exceeds assets")
	}
	b.totalAssets -= assets
}

func add64(a, b int64) (int64, bool) {
	if a > 0 && b > mathMaxInt64-a {
		return 0, false
	}
	if a < 0 && b < mathMinInt64-a {
		return 0, false
	}
	return a + b, true
}

const (
	mathMaxInt64 = int64(9223372036854775807)
	mathMinInt64 = int64(-9223372036854775808)
)

// mulDiv computes floor(a*b/denom) for non-negative inputs without overflowing
// int64 intermediates. Divides the larger factor first so a partial redeem
// (shares < supply, assets ~ 8e9) does not panic.
func mulDiv(a, b, denom int64) int64 {
	if denom <= 0 {
		panic("division by zero")
	}
	if a < 0 || b < 0 {
		panic("mulDiv expects non-negative")
	}
	if a == 0 || b == 0 {
		return 0
	}
	if a < b {
		a, b = b, a
	}
	if a <= mathMaxInt64/b {
		return a * b / denom
	}
	q := a / denom
	r := a % denom
	out, ok := mul64(q, b)
	if !ok {
		panic("mulDiv overflow")
	}
	var extra int64
	if r == 0 || b == 0 {
		extra = 0
	} else if r <= mathMaxInt64/b {
		extra = r * b / denom
	} else {
		extra = mulDiv(r, b, denom)
	}
	sum, ok := add64(out, extra)
	if !ok {
		panic("mulDiv overflow")
	}
	return sum
}

func mul64(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	if a > mathMaxInt64/b {
		return 0, false
	}
	return a * b, true
}
