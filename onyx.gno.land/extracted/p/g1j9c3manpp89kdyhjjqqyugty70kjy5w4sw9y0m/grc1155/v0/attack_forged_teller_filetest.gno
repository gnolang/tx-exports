// PKGPATH: gno.land/r/demo/grc1155forged

// Attack check for teller forgery: wrapping a real Teller by embedding the
// interface is the classic confused-deputy shape. IsCanonicalTeller rejects
// it because the concrete type is not *fnTeller — and a realm that gates on
// the check refuses the forged value outright.
package grc1155forged

import (
	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
)

// evilTeller forges the Teller interface by embedding — every method
// delegates to the wrapped teller, yet it is not canonical.
type evilTeller struct{ grc1155.Teller }

func main(cur realm) {
	tok, led := grc1155.NewToken("Forge", "FORGE", "item/{id}", 0, cur)
	must(led.Mint(cur.Address(), "wood", 1))

	wrapped := tok.ReadonlyTeller()
	forged := &evilTeller{wrapped}

	println("forged teller canonical:", grc1155.IsCanonicalTeller(forged))
	println("wrapped teller canonical:", grc1155.IsCanonicalTeller(wrapped))

	// A guard that trusts IsCanonicalTeller refuses the forgery before any
	// method is ever invoked.
	if grc1155.IsCanonicalTeller(forged) {
		println("guard: forged teller ACCEPTED (bad)")
	} else {
		println("guard: forged teller rejected")
	}

	// And even if invoked anyway, the embedded ReadonlyTeller still refuses
	// writes — the forgery buys nothing.
	err := forged.TransferFrom(0, cur, cur.Address(), cur.Address(), "wood", 1)
	println("forged write is ErrReadonly:", err == grc1155.ErrReadonly)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// Output:
// forged teller canonical: false
// wrapped teller canonical: true
// guard: forged teller rejected
// forged write is ErrReadonly: true
