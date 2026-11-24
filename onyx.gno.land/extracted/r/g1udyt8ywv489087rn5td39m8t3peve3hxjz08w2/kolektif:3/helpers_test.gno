package kolektif

import (
	"chain"
	"chain/banker"
	"testing"
)

// realmAddr is the address coins land on when someone calls this realm.
var realmAddr = chain.PackageAddress("gno.land/r/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/kolektif")

const gnot = int64(1000000)

// reset clears the realm state between tests: every test runs in the same
// package instance.
func reset() {
	circles = nil
	seq = 0
}

// payFrom simulates the coins a transaction carries: they exist on the realm
// account and they are reported as the origin send of the current call.
//
// Note: testing.SetRealm does NOT survive a function boundary, so callers must
// set the realm inline in the same frame that makes the crossing call.
func payFrom(amount int64) {
	coins := chain.NewCoins(chain.NewCoin("ugnot", amount))
	testing.IssueCoins(realmAddr, coins)
	testing.SetOriginSend(coins)
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, "ugnot")
}

func fund(addr address, amount int64) {
	testing.IssueCoins(addr, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}
