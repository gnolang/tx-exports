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

var realmAddr = chain.PackageAddress("gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow")

func main(cur realm) {
	testing.IssueCoins(issuerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(payerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})

	// issuer creates an invoice
	testing.SetRealm(testing.NewUserRealm(issuerAddr))
	id := aevum.CreateInvoice(cross(cur), 400, "icon pack", 3600)
	println("created:", id)

	// payer tries to fund with the WRONG amount (300 instead of 400)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 300}})
	testing.SetRealm(testing.NewUserRealm(payerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300}})
	aevum.Fund(cross(cur), id)
}

// Error:
// must attach exactly 400ugnot
