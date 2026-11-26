// PKGPATH: gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/main

package main

import (
	"chain"
	"testing"

	aevum "gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow"
)

const (
	issuerAddr address = "g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0"
	payerAddr  address = "g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c"
)

func main(cur realm) {
	testing.IssueCoins(issuerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(payerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})

	testing.SetRealm(testing.NewUserRealm(issuerAddr))
	id := aevum.CreateInvoice(cross(cur), 400, "icon pack", 3600)

	testing.IssueCoins(chain.PackageAddress("gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow"), chain.Coins{{Denom: "ugnot", Amount: 400}})
	testing.SetRealm(testing.NewUserRealm(payerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 400}})
	aevum.Fund(cross(cur), id)

	// escrow cannot be drained before the deadline
	aevum.Refund(cross(cur), id)
}

// Error:
// deadline not reached
