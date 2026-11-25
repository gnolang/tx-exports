// PKGPATH: gno.land/r/demo/grc1155spoof

// Attack check for teller construction: RealmTeller/RealmSubTeller capture
// the calling realm eagerly, so a stale or fabricated `rlm` argument must
// panic with ErrSpoofedRealm instead of minting a teller bound to the wrong
// identity. NewToken applies the same guard to its rlm. A fabricated realm
// value fails IsCurrent() — it was never the current crossing frame's cur.
package grc1155spoof

import (
	"testing"

	"chain"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
)

func main(cur realm) {
	tok, led := grc1155.NewToken("Forge", "FORGE", "item/{id}", 0, cur)
	must(led.Mint(cur.Address(), "wood", 1))

	// A realm value fabricated out of thin air is never current.
	fake := testing.MakeRealm(
		chain.PackageAddress("gno.land/r/attacker/scavenger"),
		"gno.land/r/attacker/scavenger",
		testing.OriginRealm(),
	)

	func() {
		defer func() {
			println("RealmTeller fake is ErrSpoofedRealm:",
				recover() == grc1155.ErrSpoofedRealm)
		}()
		tok.RealmTeller(0, fake)
	}()

	func() {
		defer func() {
			println("RealmSubTeller fake is ErrSpoofedRealm:",
				recover() == grc1155.ErrSpoofedRealm)
		}()
		tok.RealmSubTeller(0, fake, "vault")
	}()

	func() {
		defer func() {
			println("NewToken fake is ErrSpoofedRealm:",
				recover() == grc1155.ErrSpoofedRealm)
		}()
		grc1155.NewToken("Other", "OTH", "", 0, fake)
	}()

	// Control: the live cur still constructs fine.
	t2 := tok.RealmTeller(0, cur)
	println("live RealmTeller canonical:", grc1155.IsCanonicalTeller(t2))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// Output:
// RealmTeller fake is ErrSpoofedRealm: true
// RealmSubTeller fake is ErrSpoofedRealm: true
// NewToken fake is ErrSpoofedRealm: true
// live RealmTeller canonical: true
