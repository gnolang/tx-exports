package gnogle_market

import (
	"chain"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

// ClaimAdmin assigns the market admin (one-time). Admin controls the platform fee.
func ClaimAdmin(cur realm) {
	if admin != zeroAddr {
		panic("admin already claimed")
	}
	admin = cur.Previous().Address()
	chain.Emit("ClaimAdmin", "admin", admin.String())
}

// SetFeeBps sets the platform fee on secondary sales (e.g. 250 = 2.5%). Admin only.
func SetFeeBps(cur realm, bps int64) {
	assertAdmin(cur)
	if bps < 0 || bps > maxFeeBps {
		panic(ufmt.Sprintf("feeBps must be between 0 and %d", maxFeeBps))
	}
	feeBps = bps
	chain.Emit("SetFee", "bps", strconv.FormatInt(bps, 10))
}

// WithdrawFees sends accrued platform fees to addr. Admin only.
func WithdrawFees(cur realm, addr address) int64 {
	assertAdmin(cur)
	if !addr.IsValid() {
		panic("invalid address")
	}
	amount := feePot
	if amount <= 0 {
		return 0
	}
	feePot = 0
	payout(cur, addr, amount)
	chain.Emit("WithdrawFees", "to", addr.String(), "amount", strconv.FormatInt(amount, 10))
	return amount
}

func assertAdmin(cur realm) {
	if admin == zeroAddr {
		panic("admin not set; call ClaimAdmin first")
	}
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
}

func Admin() address { return admin }
func FeeBps() int64  { return feeBps }
func FeePot() int64  { return feePot }
