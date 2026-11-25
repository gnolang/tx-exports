package erratabank

import (
	"chain"
	"strconv"
)

// Bound the work of a single call even when many small sponsor balances fund a reward.
const settlementSteps = 8

// FundBook records an owner deposit or a locked sponsor deposit and services the
// oldest fully funded reward first. The owner can fund existing debts after closing.
func FundBook(cur realm, bookID int) {
	caller := callerAddress(cur)
	amount := inboundUgnot(cur)
	if amount == 0 {
		panic(errPayment)
	}
	record := requireBook(bookID)
	book := &record.book
	addAmount(record.totalFunds(), amount)
	if caller == book.Owner {
		book.OwnerFunds += amount
	} else {
		if !book.Open {
			panic(errClosedSponsor)
		}
		addr := caller.String()
		balance, _ := record.sponsors.Get(addr).(int64)
		record.sponsors.Set(addr, balance+amount)
		book.SponsorFunds += amount
	}
	chain.Emit("BookFunded", "book", strconv.Itoa(bookID), "funder", caller.String(),
		"amount", strconv.FormatInt(amount, 10))
	settleRewards(cur, record)
}

func (record *bookRecord) totalFunds() int64 {
	return record.book.OwnerFunds + record.book.SponsorFunds
}

func (record *bookRecord) queueReward(report *Erratum, finder *finderRecord, reward int64) {
	record.book.Owed = addAmount(record.book.Owed, reward)
	finder.owed = addAmount(finder.owed, reward)
	report.Owed = reward
	sequence := advanceID(&record.nextOwedID)
	record.owedReports.Set(idKey(sequence), report.ID)
}

// Consume sponsor balances in address order before touching owner deposits.
func (record *bookRecord) debitFunds(amount int64) int64 {
	if record.book.SponsorFunds == 0 {
		record.book.OwnerFunds -= amount
		return amount
	}
	addr, value := record.sponsors.GetByIndex(0)
	balance := value.(int64)
	if amount >= balance {
		amount = balance
		record.sponsors.Remove(addr)
	} else {
		record.sponsors.Set(addr, balance-amount)
	}
	record.book.SponsorFunds -= amount
	return amount
}

func settleRewards(cur realm, record *bookRecord) {
	steps := settlementSteps
	for steps > 0 && record.owedReports.Size() > 0 {
		key, id := record.owedReports.GetByIndex(0)
		report := reportByID(id.(int))
		if record.totalFunds() < report.Owed {
			return
		}
		remaining := report.Owed
		for remaining > 0 && steps > 0 {
			remaining -= record.debitFunds(remaining)
			steps--
		}
		amount := report.Owed - remaining
		record.book.Owed -= amount
		report.Owed = remaining
		report.Paid += amount
		finder := finders.Get(report.Finder.String()).(*finderRecord)
		finder.owed -= amount
		finder.paid = addAmount(finder.paid, amount)
		if remaining == 0 {
			record.owedReports.Remove(key)
		}
		sendUgnot(cur, report.Finder, amount)
		chain.Emit("ErratumPaid", "book", strconv.Itoa(report.BookID), "erratum", strconv.Itoa(report.ID),
			"finder", report.Finder.String(), "amount", strconv.FormatInt(amount, 10),
			"owed", strconv.FormatInt(remaining, 10))
	}
}

// SettleOwed continues payouts when a previous call reached its work limit.
func SettleOwed(cur realm, bookID int) {
	callerAddress(cur)
	rejectCoins(cur)
	settleRewards(cur, requireBook(bookID))
}

func (record *bookRecord) ownerWithdrawable() int64 {
	// Complete queued payouts before making owner deposits withdrawable.
	if record.book.Owed != 0 {
		return 0
	}
	return record.book.OwnerFunds
}

// Withdraw returns only the owner's deposits in excess of outstanding rewards.
func Withdraw(cur realm, bookID int, amount int64) {
	caller := callerAddress(cur)
	rejectCoins(cur)
	record := requireBook(bookID)
	requireOwner(record, caller)
	if amount <= 0 || amount > record.ownerWithdrawable() {
		panic(errWithdraw)
	}
	record.book.OwnerFunds -= amount
	sendUgnot(cur, caller, amount)
	chain.Emit("BookWithdrawn", "book", strconv.Itoa(bookID), "owner", caller.String(),
		"amount", strconv.FormatInt(amount, 10))
}

// SponsorBalance returns the sponsor's remaining deposit for a book.
func SponsorBalance(bookID int, sponsor address) int64 {
	record := bookByID(bookID)
	if record == nil {
		return 0
	}
	balance, _ := record.sponsors.Get(sponsor.String()).(int64)
	return balance
}

// RefundSponsor returns the caller's remaining sponsor deposit on a closed book
// after all accepted rewards have settled.
func RefundSponsor(cur realm, bookID int) {
	caller := callerAddress(cur)
	rejectCoins(cur)
	record := requireBook(bookID)
	if record.book.Open || record.book.Owed != 0 {
		panic(errRefundUnavailable)
	}
	amount := SponsorBalance(bookID, caller)
	if amount == 0 {
		panic(errNoSponsorFunds)
	}
	record.sponsors.Remove(caller.String())
	record.book.SponsorFunds -= amount
	sendUgnot(cur, caller, amount)
	chain.Emit("SponsorRefunded", "book", strconv.Itoa(bookID), "sponsor", caller.String(),
		"amount", strconv.FormatInt(amount, 10))
}
