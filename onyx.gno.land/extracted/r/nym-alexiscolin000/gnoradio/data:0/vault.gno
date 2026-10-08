package data

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// The vault holds the coins of promo budgets, at this realm's address, so
// they never move across a release. It lives in unexported state, not in a
// collection, so no writer can forge a balance. An account ("catalog/<id>")
// has a funder, a balance and holds: amounts reserved until a UTC day, which
// lapse by themselves after it. A role's writer credits, holds, releases,
// pays from holds and refunds; the funder alone withdraws what is not held,
// whatever the writer, a pause or a renounced owner. Holds lapse on the
// vault's clock (VaultDay), which a pause stops.
//
// Invariant: the realm's ugnot >= VaultTotal. A credit is checked against
// the coins already received; every payout lowers the total first.

const (
	denom       = "ugnot"
	daySecs     = 24 * 3600
	maxHoldDays = 31 // a hold lapses at most this many days ahead
	maxAcct     = 64
)

var (
	vault      = bptree.NewBPTree32() // account -> store.Rec(funder, balance, holds)
	vaultTotal int64
)

type account struct {
	funder  address
	balance int64  // held for the account, holds included
	holds   string // "day:ugnot,..." reserved until the end of day
}

func getAcct(name string) account {
	if len(name) > maxAcct || !strings.Contains(name, "/") {
		panic("data: an account is <role>/<name>, at most 64 bytes")
	}
	v := vault.Get(name)
	if v == nil {
		return account{}
	}
	f := store.Fields(v.(string))
	return account{address(f[0]), atoi(f[1]), f[2]}
}

func putAcct(name string, a account) {
	vault.Set(name, store.Rec(a.funder.String(), strconv.FormatInt(a.balance, 10), a.holds))
}

func atoi(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("data: bad number")
	}
	return n
}

// VaultDay is the UTC day of the vault's clock, which stands still while
// any role is paused: a pause never makes a hold lapse, it lapses that much
// later. The clock lags real time by every past pause, so a hold made
// after one also lasts that much longer.
func VaultDay() int64 {
	if frozeAt != 0 {
		return (frozeAt - frozen) / daySecs
	}
	return (now() - frozen) / daySecs
}

func today() int64 { return VaultDay() }

// held reads the holds still live today, and the one lapsing on day e.
func held(list string, e int64) (live, atE int64) {
	t := today()
	for _, p := range strings.Split(list, ",") {
		d, v, ok := strings.Cut(p, ":")
		if ok && atoi(d) >= t {
			live += atoi(v)
			if atoi(d) == e {
				atE += atoi(v)
			}
		}
	}
	return live, atE
}

// hold adds delta to the hold lapsing on day e and drops lapsed ones.
func hold(list string, e, delta int64) string {
	t := today()
	var out []string
	for _, p := range strings.Split(list, ",") {
		d, v, ok := strings.Cut(p, ":")
		if !ok || atoi(d) < t {
			continue
		}
		n := atoi(v)
		if atoi(d) == e {
			n, delta = n+delta, 0
		}
		if n > 0 {
			out = append(out, d+":"+strconv.FormatInt(n, 10))
		}
	}
	if delta > 0 {
		out = append(out, strconv.FormatInt(e, 10)+":"+strconv.FormatInt(delta, 10))
	}
	return strings.Join(out, ",")
}

func (a account) free() int64 {
	live, _ := held(a.holds, -1)
	return a.balance - live
}

func positive(amt int64) {
	if amt <= 0 {
		panic("data: the amount must be positive")
	}
}

// send pays out of the vault: the total goes down before the coins leave.
func send(cur realm, acct string, to address, amt int64, event string) {
	vaultTotal -= amt
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), to, chain.Coins{{denom, amt}})
	chain.Emit(event, "account", acct, "to", to.String(), "amount", strconv.FormatInt(amt, 10))
}

// VaultCredit adds amt, which the writer has just sent to this realm, to an
// account funded by funder. A new funder needs an empty account
// (VaultRefund first).
func VaultCredit(cur realm, acct string, funder address, amt int64) {
	gate(cur, acct)
	positive(amt)
	if !role.Canonical(funder) || IsGnoRadio(funder) {
		panic("data: a funder is an account outside GnoRadio")
	}
	a := getAcct(acct)
	if a.balance > 0 && a.funder != funder {
		panic("data: refund the previous funder first")
	}
	// GetCoin >= vaultTotal holds, so the subtraction cannot wrap (an addition
	// could, with a huge amt).
	if banker.NewReadonlyBanker().GetCoin(cur.Address(), denom)-vaultTotal < amt {
		panic("data: send the coins before crediting them")
	}
	if a.balance == 0 {
		a.holds = ""
	}
	a.funder, a.balance = funder, a.balance+amt
	vaultTotal += amt
	putAcct(acct, a)
	chain.Emit("VaultCredited", "account", acct, "funder", funder.String(), "amount", strconv.FormatInt(amt, 10))
}

// VaultHold reserves amt of the free balance until the end of day on the
// vault's clock (from VaultDay to 31 days from now).
func VaultHold(cur realm, acct string, amt, day int64) {
	gate(cur, acct)
	positive(amt)
	if day < today() || day > now()/daySecs+maxHoldDays {
		panic("data: a hold lapses within 31 days")
	}
	a := getAcct(acct)
	if a.free() < amt {
		panic("data: not enough free in this account")
	}
	a.holds = hold(a.holds, day, amt)
	putAcct(acct, a)
}

// VaultRelease gives back up to amt of the hold lapsing on day and returns
// what it released (less when part of it lapsed or was refunded).
func VaultRelease(cur realm, acct string, amt, day int64) int64 {
	gate(cur, acct)
	positive(amt)
	a := getAcct(acct)
	if _, atE := held(a.holds, day); atE < amt {
		amt = atE
	}
	if amt > 0 {
		a.holds = hold(a.holds, day, -amt)
		putAcct(acct, a)
	}
	return amt
}

// VaultPay pays amt from the live hold lapsing on day to an account outside
// GnoRadio.
func VaultPay(cur realm, acct string, to address, amt, day int64) {
	gate(cur, acct)
	positive(amt)
	if !role.Canonical(to) || IsGnoRadio(to) {
		panic("data: pay an account outside GnoRadio")
	}
	a := getAcct(acct)
	if _, atE := held(a.holds, day); atE < amt {
		panic("data: no such hold")
	}
	a.holds, a.balance = hold(a.holds, day, -amt), a.balance-amt
	putAcct(acct, a)
	send(cur, acct, to, amt, "VaultPaid")
}

// VaultRefund pays the whole balance back to the funder and drops the holds
// (the profile changed hands). It returns the amount.
func VaultRefund(cur realm, acct string) int64 {
	gate(cur, acct)
	a := getAcct(acct)
	amt := a.balance
	if amt == 0 {
		return 0
	}
	a.balance, a.holds = 0, ""
	putAcct(acct, a)
	send(cur, acct, a.funder, amt, "VaultRefunded")
	return amt
}

// VaultWithdraw pays the caller what is free in an account they funded. It
// works whoever the writer is, while paused and after Renounce.
func VaultWithdraw(cur realm, acct string) {
	noPayment()
	a := getAcct(acct)
	free := a.free()
	if a.funder != cur.Previous().Address() || free <= 0 {
		panic("data: nothing of yours to withdraw here")
	}
	a.balance -= free
	putAcct(acct, a)
	send(cur, acct, a.funder, free, "VaultWithdrawn")
}

// VaultInfo is an account's funder, balance and free part (not held).
func VaultInfo(acct string) (funder address, balance, free int64) {
	a := getAcct(acct)
	return a.funder, a.balance, a.free()
}

// VaultHeld is the live hold of an account lapsing on day.
func VaultHeld(acct string, day int64) int64 {
	_, atE := held(getAcct(acct).holds, day)
	return atE
}

// VaultTotal is every account's balance: what this realm holds for them.
func VaultTotal() int64 { return vaultTotal }
