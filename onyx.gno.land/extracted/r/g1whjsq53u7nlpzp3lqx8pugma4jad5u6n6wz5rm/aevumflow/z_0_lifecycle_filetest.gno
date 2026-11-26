// PKGPATH: gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/main

package main

import (
	"chain"
	"chain/banker"
	"testing"

	aevum "gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow"
)

const (
	issuerAddr address = "g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0"
	payerAddr  address = "g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c"
)

var realmAddr = chain.PackageAddress("gno.land/r/g1whjsq53u7nlpzp3lqx8pugma4jad5u6n6wz5rm/aevumflow")

func main(cur realm) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	// fund both wallets
	testing.IssueCoins(issuerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(payerAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})

	// 1. issuer creates an invoice: 500 ugnot, 1h delivery window
	testing.SetRealm(testing.NewUserRealm(issuerAddr))
	id := aevum.CreateInvoice(cross(cur), 500, "logo design", 3600)
	println("invoice id:", id)

	inv := aevum.GetInvoice(id)
	println("status:", inv.Status == aevum.StatusCreated) // true
	println("amount:", inv.Amount)

	// 2. payer funds with exactly 500 ugnot
	// (filetest: simulate the tx send envelope by issuing coins to the realm)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 500}})
	testing.SetRealm(testing.NewUserRealm(payerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 500}})
	aevum.Fund(cross(cur), id)
	inv = aevum.GetInvoice(id)
	println("funded:", inv.Status == aevum.StatusFunded) // true
	println("payer ok:", inv.Payer == payerAddr)
	println("realm balance:", b.GetCoin(realmAddr, "ugnot")) // 500

	// 3. issuer settles: issuer receives 500 - 1% = 495
	testing.SetRealm(testing.NewUserRealm(issuerAddr))
	aevum.Settle(cross(cur), id)
	inv = aevum.GetInvoice(id)
	println("settled:", inv.Status == aevum.StatusSettled) // true
	println("issuer balance:", b.GetCoin(issuerAddr, "ugnot"))
	println("realm balance after settle:", b.GetCoin(realmAddr, "ugnot")) // 5 (fee)
}

// Output:
// invoice id: 1
// status: true
// amount: 500
// funded: true
// payer ok: true
// realm balance: 500
// settled: true
// issuer balance: 1000495
// realm balance after settle: 5
