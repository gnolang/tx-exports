// PKGPATH: gno.land/r/test/escrowv1fixture/main

package main

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v1"
)

const (
	owner   = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	reader  = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	sponsor = address("g1juz2yxmdsa6audkp6ep9vfv80c8p5u76e03vvh")
)

func main(cur realm) {
	bank := banker.NewReadonlyBanker()
	bankAddr := chain.PackageAddress("gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v1")
	readerTwo := chain.PackageAddress("gno.land/r/test/escrowv1reader")
	otherSponsor := chain.PackageAddress("gno.land/r/test/escrowv1sponsor")

	stageSend(cur, bankAddr, 250)
	testing.SetRealm(testing.NewUserRealm(owner))
	id := erratabank.CreateBook(cross(cur), "Quickstart", "First", "https://example.org/guide", 1000)
	stageSend(cur, bankAddr, 1100)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	erratabank.FundBook(cross(cur), id)
	testing.SetOriginSend(nil)
	book, _ := erratabank.GetBook(id)
	println("initial owner, sponsor, realm:", book.OwnerFunds, book.SponsorFunds, bank.GetCoin(bankAddr, "ugnot"))

	testing.SetRealm(testing.NewUserRealm(reader))
	paid := erratabank.Submit(cross(cur), id, "Page 1", "First correction.")
	submittedEarlier := erratabank.Submit(cross(cur), id, "Page 2", "Second submission.")
	testing.SetRealm(testing.NewUserRealm(readerTwo))
	acceptedEarlier := erratabank.Submit(cross(cur), id, "Page 3", "Third submission.")
	testing.SetRealm(testing.NewUserRealm(owner))
	erratabank.Accept(cross(cur), paid, "")
	book, _ = erratabank.GetBook(id)
	println("sponsor payout, owner, sponsor, realm, finder:", book.OwnerFunds, book.SponsorFunds,
		bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(reader, "ugnot"))

	erratabank.Accept(cross(cur), acceptedEarlier, "")
	erratabank.Accept(cross(cur), submittedEarlier, "")
	book, _ = erratabank.GetBook(id)
	println("unfunded rewards and realm:", book.Owed, bank.GetCoin(bankAddr, "ugnot"))
	println("reserved withdrawal:", revive(func() { erratabank.Withdraw(cross(cur), id, 1) }))

	stageSend(cur, bankAddr, 650)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	erratabank.FundBook(cross(cur), id)
	testing.SetOriginSend(nil)
	book, _ = erratabank.GetBook(id)
	println("first accepted debt settled, owed, realm, finders:", book.Owed, bank.GetCoin(bankAddr, "ugnot"),
		bank.GetCoin(reader, "ugnot"), bank.GetCoin(readerTwo, "ugnot"))

	stageSend(cur, bankAddr, 1250)
	testing.SetRealm(testing.NewUserRealm(owner))
	erratabank.FundBook(cross(cur), id)
	report, _ := erratabank.GetErratum(submittedEarlier)
	stats := erratabank.FinderStats(reader)
	testing.SetOriginSend(nil)
	book, _ = erratabank.GetBook(id)
	println("second debt settled, owner, owed, report paid, finder paid, finder owed:", book.OwnerFunds,
		book.Owed, report.Paid, stats.Paid, stats.Owed)
	println("finder bank balance:", bank.GetCoin(reader, "ugnot"))

	stageSend(cur, bankAddr, 500)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	erratabank.FundBook(cross(cur), id)
	stageSend(cur, bankAddr, 100)
	testing.SetRealm(testing.NewUserRealm(otherSponsor))
	erratabank.FundBook(cross(cur), id)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(owner))
	println("sponsor withdrawal blocked:", revive(func() { erratabank.Withdraw(cross(cur), id, 251) }))
	erratabank.Withdraw(cross(cur), id, 200)
	book, _ = erratabank.GetBook(id)
	println("owner withdrawal, owner funds, sponsor funds, realm, owner balance:", book.OwnerFunds,
		book.SponsorFunds, bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(owner, "ugnot"))

	erratabank.SetBookOpen(cross(cur), id, false)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	erratabank.RefundSponsor(cross(cur), id)
	println("refund to first sponsor, second sponsor deposit, realm:", bank.GetCoin(sponsor, "ugnot"),
		erratabank.SponsorBalance(id, otherSponsor), bank.GetCoin(bankAddr, "ugnot"))
	println("refund replay:", revive(func() { erratabank.RefundSponsor(cross(cur), id) }))
	testing.SetRealm(testing.NewUserRealm(otherSponsor))
	erratabank.RefundSponsor(cross(cur), id)
	book, _ = erratabank.GetBook(id)
	println("refund to second sponsor, sponsor funds, realm:", bank.GetCoin(otherSponsor, "ugnot"),
		book.SponsorFunds, bank.GetCoin(bankAddr, "ugnot"))

	testing.SetRealm(testing.NewUserRealm(owner))
	closedID := erratabank.CreateBook(cross(cur), "Close with debt", "First", "https://example.org/guide", 1000)
	stageSend(cur, bankAddr, 300)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	erratabank.FundBook(cross(cur), closedID)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(reader))
	closedReportID := erratabank.Submit(cross(cur), closedID, "Page 1", "Payable before closure.")
	testing.SetRealm(testing.NewUserRealm(owner))
	erratabank.Accept(cross(cur), closedReportID, "")
	erratabank.SetBookOpen(cross(cur), closedID, false)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	println("refund while finder is owed:", revive(func() { erratabank.RefundSponsor(cross(cur), closedID) }))
	stageSend(cur, bankAddr, 700)
	testing.SetRealm(testing.NewUserRealm(owner))
	erratabank.FundBook(cross(cur), closedID)
	closedBook, _ := erratabank.GetBook(closedID)
	println("closed book settled, open, owed, realm, finder:", closedBook.Open, closedBook.Owed,
		bank.GetCoin(bankAddr, "ugnot"), bank.GetCoin(reader, "ugnot"))
}

// Reproduce the VM's transfer and origin-send envelope before MsgCall.
func stageSend(cur realm, target address, amount int64) {
	sent := chain.NewCoins(chain.NewCoin("ugnot", amount))
	testing.IssueCoins(cur.Address(), sent)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), target, sent)
	testing.SetOriginSend(sent)
}

// Output:
// initial owner, sponsor, realm: 250 1100 1350
// sponsor payout, owner, sponsor, realm, finder: 250 100 350 1000
// unfunded rewards and realm: 2000 350
// reserved withdrawal: withdrawal must be positive and within unreserved owner funds
// first accepted debt settled, owed, realm, finders: 1000 0 1000 1000
// second debt settled, owner, owed, report paid, finder paid, finder owed: 250 0 1000 2000 0
// finder bank balance: 2000
// sponsor withdrawal blocked: withdrawal must be positive and within unreserved owner funds
// owner withdrawal, owner funds, sponsor funds, realm, owner balance: 50 600 650 200
// refund to first sponsor, second sponsor deposit, realm: 500 100 150
// refund replay: no sponsor funds to refund
// refund to second sponsor, sponsor funds, realm: 100 0 50
// refund while finder is owed: sponsor refunds require a closed book with no unpaid rewards
// closed book settled, open, owed, realm, finder: false 0 50 3000
