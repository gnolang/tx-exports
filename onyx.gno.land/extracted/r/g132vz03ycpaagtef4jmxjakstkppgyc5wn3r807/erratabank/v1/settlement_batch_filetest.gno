// PKGPATH: gno.land/r/test/escrowv1batch/main

package main

import (
	"chain"
	"chain/banker"
	"strconv"
	"testing"

	"gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v1"
)

func main(cur realm) {
	owner := address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	finder := address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	bankAddr := chain.PackageAddress("gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v1")
	bank := banker.NewReadonlyBanker()

	testing.SetRealm(testing.NewUserRealm(owner))
	bookID := erratabank.CreateBook(cross(cur), "Many sponsors", "First", "https://example.org", 900)
	for i := 0; i < 9; i++ {
		coins := chain.NewCoins(chain.NewCoin("ugnot", 100))
		testing.IssueCoins(cur.Address(), coins)
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), bankAddr, coins)
		testing.SetOriginSend(coins)
		addr := chain.PackageAddress("gno.land/r/test/escrowv1sponsor" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(addr))
		erratabank.FundBook(cross(cur), bookID)
	}
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(finder))
	id := erratabank.Submit(cross(cur), bookID, "Section 1", "Correction funded by many sponsors.")
	testing.SetRealm(testing.NewUserRealm(owner))
	erratabank.Accept(cross(cur), id, "")
	report, _ := erratabank.GetErratum(id)
	println("bounded settlement, paid, owed, realm, finder:", report.Paid, report.Owed,
		bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(finder, "ugnot"))

	testing.SetRealm(testing.NewUserRealm(finder))
	erratabank.SettleOwed(cross(cur), bookID)
	report, _ = erratabank.GetErratum(id)
	println("continued settlement, paid, owed, realm, finder:", report.Paid, report.Owed,
		bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(finder, "ugnot"))
}

// Output:
// bounded settlement, paid, owed, realm, finder: 800 100 100 800
// continued settlement, paid, owed, realm, finder: 900 0 0 900
