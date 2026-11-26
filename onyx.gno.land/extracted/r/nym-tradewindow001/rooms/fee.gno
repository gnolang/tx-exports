package rooms

import (
	"chain"
	"math"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// The service fee. When a room settles, the realm keeps FeeBps basis points
// of every coin and token that crosses, from each side, and sends it to the
// treasury; the rest goes to the other party. NFTs cross whole and pay
// nothing. Withdrawing, cancelling and expiring cost nothing.
//
// A room keeps the rate it was opened with, so the admin can never raise
// the fee on a trade already under way, and no rate can exceed MaxFeeBps.

const (
	// DefaultFeeBps is 0.5%.
	DefaultFeeBps = 50
	// MaxFeeBps caps the fee at 1%, whatever the admin sets.
	MaxFeeBps = 100
)

var (
	feeBps   uint64  = DefaultFeeBps
	treasury address // set to the deployer in init; fees are off while it is empty

	fees avl.Tree // kind + ":" + denom -> int64 fees collected
)

// SetFee sets the rate for rooms opened from now on, in basis points
// (50 is 0.5%), at most MaxFeeBps. Rooms already open keep their rate.
func SetFee(cur realm, bps uint64) {
	assertAdmin(cur)
	if bps > MaxFeeBps {
		panic("the fee can be at most " + strconv.Itoa(MaxFeeBps) + " basis points")
	}
	feeBps = bps
	chain.Emit("FeeChanged", "bps", strconv.FormatUint(bps, 10))
}

// SetTreasury names the account that receives fees from now on.
func SetTreasury(cur realm, to string) {
	assertAdmin(cur)
	addr := address(to)
	if !addr.IsValid() {
		panic("treasury is not a valid address")
	}
	treasury = addr
	chain.Emit("TreasuryChanged", "treasury", addr.String())
}

// FeeBps returns the rate a room opened now would get.
func FeeBps() uint64 {
	return openingFee()
}

// Treasury returns the account that receives fees, or "" when fees are off.
func Treasury() string {
	return treasury.String()
}

// openingFee is the rate a new room keeps for its whole life.
func openingFee() uint64 {
	if treasury == "" {
		return 0
	}
	return feeBps
}

// feeOf is the fee on amount at bps basis points, rounded down. It never
// overflows: bps is at most MaxFeeBps.
func feeOf(amount int64, bps uint64) int64 {
	if bps == 0 || amount <= 0 {
		return 0
	}
	b := int64(bps)
	return amount/10000*b + amount%10000*b/10000
}

// pay sends one asset of a settling room to the party receiving it, less
// the room's fee on coins and tokens.
func (r *room) pay(cur realm, to address, a asset) {
	fee := int64(0)
	if a.kind != KindNFT {
		fee = feeOf(a.amount, r.feeBps)
	}
	if fee > 0 {
		send(cur, treasury, asset{kind: a.kind, denom: a.denom, amount: fee})
		addFee(a.kind, a.denom, fee)
	}
	send(cur, to, asset{kind: a.kind, denom: a.denom, amount: a.amount - fee})
}

func addFee(kind, denom string, amount int64) {
	key := kind + ":" + denom
	total := int64(0)
	if v := fees.Get(key); v != nil {
		total = v.(int64)
	}
	if amount > math.MaxInt64-total {
		total = math.MaxInt64
	} else {
		total += amount
	}
	fees.Set(key, total)
}
