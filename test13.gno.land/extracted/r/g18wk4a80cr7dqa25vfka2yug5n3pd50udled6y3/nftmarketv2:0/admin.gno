package nftmarket

import (
	"chain"

	"gno.land/p/nt/ufmt/v0"
)

// ClaimAdmin assigns the platform admin to the caller. It can only be called
// once (when no admin is set yet). Deployers should call this immediately
// after publishing the realm — ideally in the same deploy script — to avoid
// someone else claiming it first.
func ClaimAdmin(cur realm) {
	if admin != zeroAddr {
		panic("admin already claimed")
	}
	admin = cur.Previous().Address()
	chain.Emit("ClaimAdmin", "admin", admin.String())
}

// SetAdmin transfers the platform admin role to newAdmin. Admin only.
func SetAdmin(cur realm, newAdmin address) {
	assertAdmin(cur)
	if !newAdmin.IsValid() {
		panic("invalid admin address")
	}
	prev := admin
	admin = newAdmin
	chain.Emit("SetAdmin", "from", prev.String(), "to", newAdmin.String())
}

// SetFeeBps sets the platform fee charged on secondary sales, in basis points
// (e.g. 250 = 2.5%). Capped at maxFeeBps. Admin only.
func SetFeeBps(cur realm, bps int64) {
	assertAdmin(cur)
	if bps < 0 || bps > maxFeeBps {
		panic(ufmt.Sprintf("feeBps must be between 0 and %d", maxFeeBps))
	}
	feeBps = bps
	chain.Emit("SetFee", "bps", ufmt.Sprintf("%d", bps))
}

// WithdrawFees sends all accrued platform fees to addr and returns the amount.
// Admin only.
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
	chain.Emit("WithdrawFees", "to", addr.String(), "amount", ufmt.Sprintf("%d", amount))
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

// --- read-only views --------------------------------------------------------

// Admin returns the current platform admin address.
func Admin() address { return admin }

// FeeBps returns the current platform fee in basis points.
func FeeBps() int64 { return feeBps }

// FeePot returns the amount of ugnot currently withdrawable as platform fees.
func FeePot() int64 { return feePot }
