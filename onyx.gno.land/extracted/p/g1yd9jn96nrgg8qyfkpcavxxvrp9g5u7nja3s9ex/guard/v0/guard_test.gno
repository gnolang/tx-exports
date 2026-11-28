package guard

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
)

func TestOnlyOwner(cur realm, t *testing.T) {
	uassert.NotPanics(t, cur, func() { OnlyOwner(alice, alice) })
	uassert.PanicsWithMessage(t, cur, "guard: caller is not the owner", func() { OnlyOwner(bob, alice) })
	uassert.PanicsWithMessage(t, cur, "guard: owner is not set", func() { OnlyOwner(bob, address("")) })
}

func TestOnlyOneOf(cur realm, t *testing.T) {
	uassert.NotPanics(t, cur, func() { OnlyOneOf(bob, alice, bob) })
	uassert.PanicsWithMessage(t, cur, "guard: caller is not authorized", func() { OnlyOneOf(bob, alice) })
	uassert.PanicsWithMessage(t, cur, "guard: caller is not authorized", func() { OnlyOneOf(address(""), address("")) })
}

func TestRequireValidAddr(cur realm, t *testing.T) {
	uassert.NotPanics(t, cur, func() { RequireValidAddr(alice, "to") })
	uassert.PanicsWithMessage(t, cur, "guard: invalid address for to", func() { RequireValidAddr(address("g1nope"), "to") })
}

func TestLengths(cur realm, t *testing.T) {
	uassert.NotPanics(t, cur, func() { RequireMaxLen("abc", 3, "body") })
	uassert.PanicsWithMessage(t, cur, "guard: body longer than 2 bytes", func() { RequireMaxLen("abc", 2, "body") })
	uassert.PanicsWithMessage(t, cur, "guard: body is empty", func() { RequireNonEmpty("", "body") })
	uassert.NotPanics(t, cur, func() { RequireMaxItems(5, 5, "ids") })
	uassert.PanicsWithMessage(t, cur, "guard: ids has more than 5 items", func() { RequireMaxItems(6, 5, "ids") })
}

func TestAmounts(cur realm, t *testing.T) {
	uassert.Equal(t, int64(3), SafeSub(10, 7))
	uassert.Equal(t, int64(0), SafeSub(7, 7))
	uassert.PanicsWithMessage(t, cur, "guard: insufficient balance", func() { SafeSub(5, 7) })
	uassert.PanicsWithMessage(t, cur, "guard: negative amount", func() { SafeSub(5, -1) })
	uassert.Equal(t, int64(12), SafeAdd(5, 7))
	uassert.PanicsWithMessage(t, cur, "guard: overflow", func() { SafeAdd(9223372036854775807, 1) })
	uassert.PanicsWithMessage(t, cur, "guard: amount must be positive", func() { RequirePositive(0, "amount") })
}
