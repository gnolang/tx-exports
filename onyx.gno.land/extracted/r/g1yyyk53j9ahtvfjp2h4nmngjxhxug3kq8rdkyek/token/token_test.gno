package token

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// cur is a zero-value realm used as a placeholder when forwarding to
// uassert helpers. Test callbacks pass cross(cur) for crossing calls.
//
// NOTE on test isolation: tests in one file share a single realm state and
// run in file order (like gno.land/r/demo/defi/foo20, whose tests are also
// written as one sequential flow). The main flow below tracks balances
// cumulatively; the rejection tests capture their baselines first so they
// hold regardless of order.
var cur realm

var (
	owner = address("g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek")
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
)

// initialSupply is 1,000,000 TIP at 6 decimals = 10^12 base units.
const expectedSupply = int64(1_000_000_000_000)

// TestTokenFlow walks the happy path in order: initial supply, mint by the
// owner, transfer, tip, and burn — tracking balances cumulatively.
func TestTokenFlow(cur realm, t *testing.T) {
	// Initial state: the owner holds the whole initial supply.
	uassert.Equal(t, TotalSupply(), expectedSupply)
	uassert.Equal(t, BalanceOf(owner), expectedSupply)
	uassert.Equal(t, BalanceOf(alice), int64(0))
	uassert.Equal(t, BalanceOf(bob), int64(0))

	// Mint by the owner works and increases the supply.
	testing.SetOriginCaller(owner)
	Mint(cross(cur), alice, 500_000_000)
	uassert.Equal(t, BalanceOf(alice), int64(500_000_000))
	uassert.Equal(t, TotalSupply(), expectedSupply+500_000_000)
	uassert.Equal(t, BalanceOf(owner), expectedSupply)

	// Transfer moves TIP from the owner to alice; supply is unchanged.
	Transfer(cross(cur), alice, 250_000_000)
	uassert.Equal(t, BalanceOf(owner), expectedSupply-250_000_000)
	uassert.Equal(t, BalanceOf(alice), int64(750_000_000))
	uassert.Equal(t, TotalSupply(), expectedSupply+500_000_000)

	// Tip is Transfer under the tipping name.
	Tip(cross(cur), bob, 100_000_000)
	uassert.Equal(t, BalanceOf(owner), expectedSupply-350_000_000)
	uassert.Equal(t, BalanceOf(bob), int64(100_000_000))
	uassert.Equal(t, TotalSupply(), expectedSupply+500_000_000)

	// Burn by the owner destroys alice's TIP and shrinks the supply.
	Burn(cross(cur), alice, 50_000_000)
	uassert.Equal(t, BalanceOf(alice), int64(700_000_000))
	uassert.Equal(t, TotalSupply(), expectedSupply+450_000_000)
}

func TestMintByNonOwnerRejected(cur realm, t *testing.T) {
	// Baselines first: this test must hold whatever earlier tests did.
	beforeAlice := BalanceOf(alice)
	beforeSupply := TotalSupply()
	testing.SetOriginCaller(alice)
	uassert.AbortsWithMessage(t, cur, "ownable: caller is not owner", func() {
		Mint(cross(cur), alice, 1)
	})
	// State is unchanged by the rejected mint.
	uassert.Equal(t, BalanceOf(alice), beforeAlice)
	uassert.Equal(t, TotalSupply(), beforeSupply)
}

func TestTransferExceedsBalanceRejected(cur realm, t *testing.T) {
	// carol is a fresh address no other test touches, so her balance is 0
	// regardless of test order.
	carol := testutils.TestAddress("carol")
	beforeBob := BalanceOf(bob)
	beforeSupply := TotalSupply()
	testing.SetOriginCaller(carol)
	uassert.AbortsWithMessage(t, cur, "insufficient balance", func() {
		Transfer(cross(cur), bob, 1)
	})
	uassert.Equal(t, BalanceOf(carol), int64(0))
	uassert.Equal(t, BalanceOf(bob), beforeBob)
	uassert.Equal(t, TotalSupply(), beforeSupply)
}
