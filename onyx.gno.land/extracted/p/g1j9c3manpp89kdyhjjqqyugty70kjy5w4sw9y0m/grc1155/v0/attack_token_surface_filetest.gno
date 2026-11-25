// PKGPATH: gno.land/r/demo/grc1155attack

// Attack check for quarantined grc1155 gap 3: a third-party realm that a
// user calls can only ever obtain the published *Token — the PrivateLedger
// never leaves the home realm (grc1155testhome here). Every write path
// available through that surface must fail: ReadonlyTeller refuses writes,
// and RealmTeller binds to THIS realm's own address, so it can only spend
// what this realm owns or was approved for — never the victim's tokens.
package grc1155attack

import (
	"chain"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
	"gno.land/r/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155testhome"
)

func main(cur realm) {
	victim := chain.PackageAddress("victim")
	attacker := cur.Address()

	// The home realm published its token pointer; we hold only *Token.
	tok := grc1155testhome.Token(cross(cur))
	must(grc1155testhome.Mint(cross(cur), victim, "wood", 5))

	// ReadonlyTeller: reads fine, every write is ErrReadonly.
	ro := tok.ReadonlyTeller()
	bal, err := ro.BalanceOf(victim, "wood")
	println("readonly sees victim balance:", bal == 5 && err == nil)

	err = ro.TransferFrom(0, cur, victim, attacker, "wood", 5)
	println("readonly transfer is ErrReadonly:", err == grc1155.ErrReadonly)
	err = ro.BatchTransferFrom(0, cur, victim, attacker,
		[]grc1155.TokenID{"wood"}, []int64{5})
	println("readonly batch is ErrReadonly:", err == grc1155.ErrReadonly)
	err = ro.SetApprovalForAll(0, cur, attacker, true)
	println("readonly setall is ErrReadonly:", err == grc1155.ErrReadonly)

	// RealmTeller binds to this realm's address eagerly: spending the
	// victim's tokens fails authorization — we are not the owner and hold
	// no approval.
	rt := tok.RealmTeller(0, cur)
	err = rt.TransferFrom(0, cur, victim, attacker, "wood", 5)
	println("realm teller steal is ErrCallerIsNotOwnerOrApproved:",
		err == grc1155.ErrCallerIsNotOwnerOrApproved)

	// Nothing moved.
	println("victim wood after attacks:", grc1155testhome.BalanceOf(cross(cur), victim, "wood"))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// Output:
// readonly sees victim balance: true
// readonly transfer is ErrReadonly: true
// readonly batch is ErrReadonly: true
// readonly setall is ErrReadonly: true
// realm teller steal is ErrCallerIsNotOwnerOrApproved: true
// victim wood after attacks: 5
