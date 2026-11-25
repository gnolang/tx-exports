// PKGPATH: gno.land/r/demo/grc1155leak

// Attack check for the CallerTeller leak: a realm may legally build a
// frame-relative teller and then export the VALUE. Construction privacy
// stops foreign realms from minting one; guardHome is what stops a minted
// one from travelling — every write must return ErrForeignCallerTeller
// once the invoking realm is not the token's home. This is a REAL
// cross-realm call: the teller was minted inside grc1155testhome's frame
// and is exercised here with this realm's own cur.
package grc1155leak

import (
	"chain"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
	"gno.land/r/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155testhome"
)

func main(cur realm) {
	victim := chain.PackageAddress("victim")
	attacker := cur.Address()

	must(grc1155testhome.Mint(cross(cur), victim, "wood", 5))

	// The home realm hands out its frame-relative teller; the value now
	// lives in this foreign realm's frame.
	teller := grc1155testhome.CallerTeller(cross(cur))

	err := teller.TransferFrom(0, cur, victim, attacker, "wood", 5)
	println("leaked transfer is ErrForeignCallerTeller:",
		err == grc1155.ErrForeignCallerTeller)

	err = teller.BatchTransferFrom(0, cur, victim, attacker,
		[]grc1155.TokenID{"wood"}, []int64{5})
	println("leaked batch is ErrForeignCallerTeller:",
		err == grc1155.ErrForeignCallerTeller)

	err = teller.SetApprovalForAll(0, cur, attacker, true)
	println("leaked setall is ErrForeignCallerTeller:",
		err == grc1155.ErrForeignCallerTeller)

	// Nothing moved and nothing was approved.
	println("victim wood after leak:", grc1155testhome.BalanceOf(cross(cur), victim, "wood"))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// Output:
// leaked transfer is ErrForeignCallerTeller: true
// leaked batch is ErrForeignCallerTeller: true
// leaked setall is ErrForeignCallerTeller: true
// victim wood after leak: 5
