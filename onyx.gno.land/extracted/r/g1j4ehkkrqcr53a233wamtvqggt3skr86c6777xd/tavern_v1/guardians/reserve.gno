package guardians

import (
	"chain"
	"gno.land/p/nt/ufmt/v0"
)

// The approved genesis list contains 369 independent one-token claims.
// The Merkle manifest must be checked against this value before activation.
const allowlistReservedSupply = int64(369)

var (
	allowlistMintedSupply int64
	allowlistReserveReleased bool
)

func AllowlistReservedSupply() int64 { return allowlistReservedSupply }
func AllowlistMintedSupply() int64 { return allowlistMintedSupply }
func AllowlistReserveReleased() bool { return allowlistReserveReleased }
func AllowlistUnclaimedSupply() int64 { return allowlistReservedSupply - allowlistMintedSupply }
func AllowlistReserveRemaining() int64 {
	if allowlistReserveReleased { return 0 }
	return AllowlistUnclaimedSupply()
}
func PublicMintableSupply() int64 {
	return maxSupply - token.TotalSupply() - AllowlistReserveRemaining()
}

// This one-way administrator action releases only the still-unclaimed stock.
// It does NOT change the proof root, free price, or individual free entitlement.
// No timer, public mint, or claim can trigger this release automatically.
func ReleaseAllowlistReserve(cur realm) {
	assertAdmin(cur.Previous().Address())
	if !saleConfigured || revealState != revealStateCommitted {
		panic("guardians: reserve release is not available")
	}
	if allowlistReserveReleased { panic("guardians: reserve already released") }
	released := AllowlistReserveRemaining()
	allowlistReserveReleased = true
	chain.Emit("AllowlistReserveReleased", "released", ufmt.Sprintf("%d", released), "freeEntitlementsPreserved", "true")
}

func assertReserveCapacity(freeQuantity, paidQuantity int) {
	if freeQuantity < 0 || paidQuantity < 0 { panic("guardians: invalid reserved allocation") }
	if int64(freeQuantity) > AllowlistUnclaimedSupply() { panic("guardians: whitelist allocation exhausted") }
	if token.TotalSupply()+int64(freeQuantity+paidQuantity) > maxSupply { panic("guardians: max supply reached") }
	// A free claim consumes one reserved slot and one supply slot together.
	// A paid mint must never consume the slots that remain protected afterwards.
	protectedAfter := AllowlistReserveRemaining()
	if !allowlistReserveReleased { protectedAfter -= int64(freeQuantity) }
	remainingAfter := maxSupply-token.TotalSupply()-int64(freeQuantity+paidQuantity)
	if remainingAfter < protectedAfter { panic("guardians: remaining supply is reserved for whitelist claims") }
}
