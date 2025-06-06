// PKGPATH: gno.land/r/demo/wugnot_test
package wugnot_test

import (
	"fmt"
	"std"

	"gno.land/p/demo/testutils"
	"gno.land/r/demo/wugnot"

	pusers "gno.land/p/demo/users"
)

var (
	addr1 = testutils.TestAddress("test1")
	addrc = std.DerivePkgAddr("gno.land/r/demo/wugnot")
	addrt = std.DerivePkgAddr("gno.land/r/demo/wugnot_test")
)

func main() {
	std.TestSetOrigPkgAddr(addrc)
	std.TestIssueCoins(addrc, std.Coins{{"ugnot", 100000001}}) // TODO: remove this

	// issue ugnots
	std.TestIssueCoins(addr1, std.Coins{{"ugnot", 100000001}})

	// print initial state
	printBalances()
	// println(wugnot.Render("queues"))
	// println("A -", wugnot.Render(""))

	std.TestSetOriginCaller(addr1)
	std.TestSetOriginSend(std.Coins{{"ugnot", 123_400}}, nil)
	wugnot.Deposit()
	printBalances()
	wugnot.Withdraw(4242)
	printBalances()
}

func printBalances() {
	printSingleBalance := func(name string, addr std.Address) {
		wugnotBal := wugnot.BalanceOf(pusers.AddressOrName(addr))
		std.TestSetOriginCaller(addr)
		robanker := std.GetBanker(std.BankerTypeReadonly)
		coins := robanker.GetCoins(addr).AmountOf("ugnot")
		fmt.Printf("| %-13s | addr=%s | wugnot=%-5d | ugnot=%-9d |\n",
			name, addr, wugnotBal, coins)
	}
	println("-----------")
	printSingleBalance("wugnot_test", addrt)
	printSingleBalance("wugnot", addrc)
	printSingleBalance("addr1", addr1)
	println("-----------")
}

// Output:
// -----------
// | wugnot_test   | addr=g19rmydykafrqyyegc8uuaxxpzqwzcnxraj2dev9 | wugnot=0     | ugnot=200000000 |
// | wugnot        | addr=g1pf6dv9fjk3rn0m4jjcne306ga4he3mzmupfjl6 | wugnot=0     | ugnot=100000001 |
// | addr1         | addr=g1w3jhxap3ta047h6lta047h6lta047h6l4mfnm7 | wugnot=0     | ugnot=100000001 |
// -----------
// -----------
// | wugnot_test   | addr=g19rmydykafrqyyegc8uuaxxpzqwzcnxraj2dev9 | wugnot=123400 | ugnot=200000000 |
// | wugnot        | addr=g1pf6dv9fjk3rn0m4jjcne306ga4he3mzmupfjl6 | wugnot=0     | ugnot=100000001 |
// | addr1         | addr=g1w3jhxap3ta047h6lta047h6lta047h6l4mfnm7 | wugnot=0     | ugnot=100000001 |
// -----------
// -----------
// | wugnot_test   | addr=g19rmydykafrqyyegc8uuaxxpzqwzcnxraj2dev9 | wugnot=119158 | ugnot=200004242 |
// | wugnot        | addr=g1pf6dv9fjk3rn0m4jjcne306ga4he3mzmupfjl6 | wugnot=0     | ugnot=99995759  |
// | addr1         | addr=g1w3jhxap3ta047h6lta047h6lta047h6l4mfnm7 | wugnot=0     | ugnot=100000001 |
// -----------
