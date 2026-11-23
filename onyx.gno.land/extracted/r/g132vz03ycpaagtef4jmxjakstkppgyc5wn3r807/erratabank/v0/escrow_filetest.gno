// PKGPATH: gno.land/r/test/escrowfixture/main

package main

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v0"
)

const (
	owner  = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	reader = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
)

func main(cur realm) {
	bank := banker.NewReadonlyBanker()
	bankAddr := chain.PackageAddress("gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v0")
	println("initial realm balance:", bank.GetCoin(bankAddr, "ugnot"))

	stageSend(cur, bankAddr, 900)
	testing.SetRealm(testing.NewUserRealm(owner))
	bookID := erratabank.CreateBook(cross(cur), "Quickstart", "First", "https://example.org/guide", 1000)
	book, _ := erratabank.GetBook(bookID)
	println("created escrow and realm balance:", book.Escrow, bank.GetCoin(bankAddr, "ugnot"))

	stageSend(cur, bankAddr, 500)
	testing.SetRealm(testing.NewUserRealm(reader))
	erratabank.FundBook(cross(cur), bookID)
	book, _ = erratabank.GetBook(bookID)
	println("funded escrow and realm balance:", book.Escrow, bank.GetCoin(bankAddr, "ugnot"))

	testing.SetOriginSend(nil)
	first := erratabank.Submit(cross(cur), bookID, "Page 1", "Fix the example.")
	second := erratabank.Submit(cross(cur), bookID, "Page 2", "Fix the note.")
	testing.SetRealm(testing.NewUserRealm(owner))
	erratabank.Accept(cross(cur), first, "Confirmed")
	report, _ := erratabank.GetErratum(first)
	book, _ = erratabank.GetBook(bookID)
	println("paid, escrow, realm, finder:", report.Paid, book.Escrow,
		bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(reader, "ugnot"))

	erratabank.Accept(cross(cur), second, "Confirmed")
	report, _ = erratabank.GetErratum(second)
	count, earned := erratabank.FinderStats(reader)
	book, _ = erratabank.GetBook(bookID)
	println("credit only, escrow, realm, finder:", report.Status, report.Paid, book.Escrow,
		bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(reader, "ugnot"))
	println("finder stats:", count, earned)

	erratabank.Withdraw(cross(cur), bookID, 200)
	book, _ = erratabank.GetBook(bookID)
	println("withdrawal escrow, realm, owner:", book.Escrow, bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(owner, "ugnot"))
}

// stageSend reproduces the chain's transfer and origin-send envelope before MsgCall.
func stageSend(cur realm, target address, amount int64) {
	sent := chain.NewCoins(chain.NewCoin("ugnot", amount))
	testing.IssueCoins(cur.Address(), sent)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), target, sent)
	testing.SetOriginSend(sent)
}

// Output:
// initial realm balance: 0
// created escrow and realm balance: 900 900
// funded escrow and realm balance: 1400 1400
// paid, escrow, realm, finder: 1000 400 400 1000
// credit only, escrow, realm, finder: Accepted 0 400 400 1000
// finder stats: 2 1000
// withdrawal escrow, realm, owner: 200 200 200
