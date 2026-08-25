package nftlimits

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

func TestSetAndGetMaxPerWallet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lim-alice")

	var collID string
	t.Run("alice creates a collection and sets a limit", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID = nft.CreateCollection(cross(cur), "Limit Test", "LIM", "", "", 100, 0, true)

		uassert.Equal(t, int64(0), GetMaxPerWallet(collID))

		SetMaxPerWallet(cross(cur), collID, 2)
		uassert.Equal(t, int64(2), GetMaxPerWallet(collID))
	})

	t.Run("alice clears the limit", func(t *testing.T) {
		SetMaxPerWallet(cross(cur), collID, 0)
		uassert.Equal(t, int64(0), GetMaxPerWallet(collID))
	})
}

func TestOnlyCreatorCanSetLimit(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lim-alice2")
	bob := testutils.TestAddress("lim-bob2")

	testing.SetOriginCaller(alice)
	collID := nft.CreateCollection(cross(cur), "Limit Test 2", "LIM2", "", "", 100, 0, true)

	testing.SetOriginCaller(bob)
	uassert.AbortsWithMessage(t, cur, "only the collection's creator can set its mint limit", func() {
		SetMaxPerWallet(cross(cur), collID, 1)
	})
}

func TestNegativeLimitAborts(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lim-alice3")

	testing.SetOriginCaller(alice)
	collID := nft.CreateCollection(cross(cur), "Limit Test 3", "LIM3", "", "", 100, 0, true)

	uassert.AbortsWithMessage(t, cur, "max must be >= 0 (0 clears the limit)", func() {
		SetMaxPerWallet(cross(cur), collID, -1)
	})
}
