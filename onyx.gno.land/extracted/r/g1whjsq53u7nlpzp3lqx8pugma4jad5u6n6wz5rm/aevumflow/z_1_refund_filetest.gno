// PKGPATH: gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/main

package main

import (
	"chain"
	"chain/banker"
	"testing"
	"time"

	aevum "gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow"
)

const (
	issuerAddr address = "g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0"
	payerAddr  address = "g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c"
)

var realmAddr = chain.PackageAddress("gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow")

func main(cur realm) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	testing.IssueCoins(issuerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(payerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})

	// issuer creates an invoice with a tiny delivery window
	testing.SetRealm(testing.NewUserRealm(issuerAddr))
	id := aevum.CreateInvoice(cross(cur), 700, "banner set", 5)
	println("created:", id)
	println("t0:", time.Now().Unix())

	// payer funds
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 700}})
	testing.SetRealm(testing.NewUserRealm(payerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 700}})
	aevum.Fund(cross(cur), id)
	println("funded:", aevum.GetInvoice(id).Status == aevum.StatusFunded)

	// issuer may settle anytime; payer may not — that case is covered in z_2

	// advance past the deadline, then refund
	testing.SkipHeights(100)
	println("t1:", time.Now().Unix())
	aevum.Refund(cross(cur), id)
	inv := aevum.GetInvoice(id)
	println("refunded:", inv.Status == aevum.StatusRefunded)
	println("payer balance:", b.GetCoin(payerAddr, "ugnot"))
	println("realm balance:", b.GetCoin(realmAddr, "ugnot"))
}

// Output:
// created: 1
// t0: 1234567890
// funded: true
// t1: 1234568390
// refunded: true
// payer balance: 1000700
// realm balance: 0
