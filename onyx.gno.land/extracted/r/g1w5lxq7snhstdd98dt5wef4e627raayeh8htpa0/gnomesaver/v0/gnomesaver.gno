// Package gnomesaver is a "set it and forget it" savings vault on Gno.land.
//
// Every deposit splits automatically: 90% stays spendable (withdrawable any
// time) and 10% goes into time-locked savings, released only after the
// depositor's chosen unlock date. There is no admin, no fee and no token —
// just native GNOT (ugnot) held by the realm itself, with all accounting
// visible on chain.
//
// Rules:
//   - Minimum deposit: 1000 ugnot (0.001 GNOT).
//   - Lock: 0-365 days per deposit (0 = 7-day default). A later deposit can
//     only extend the unlock date, never shorten it.
//   - Spendable balance: withdraw any time, any amount up to the balance.
//   - Locked savings: withdraw only after the unlock time has passed.
package gnomesaver

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const (
	// SaveRate is the share of every deposit that goes into locked savings.
	SaveRate = 10 // percent
	// MinDeposit is the smallest accepted deposit, in ugnot.
	MinDeposit = 1000
	// MaxLockDays caps the lock a depositor can choose.
	MaxLockDays = 365
	// DefaultLockDays applies when the caller passes 0.
	DefaultLockDays = 7
	// secondsPerDay converts lock days to unix seconds.
	secondsPerDay = 86400
)

// pkgPath is this realm's on-chain path (set at deploy time).
const pkgPath = "gno.land/r/g1w5lxq7snhstdd98dt5wef4e627raayeh8htpa0/gnomesaver/v0"

var (
	spendable  = map[address]int64{} // withdrawable any time
	savings    = map[address]int64{} // locked until unlockAt
	unlockAt   = map[address]int64{} // unix seconds
	seen       = map[address]bool{}
	depositors []address

	totalSaved int64 // all locked savings currently held
	totalSpend int64 // all spendable balances currently held
	totalDep   int64 // number of deposits ever made
)

// split divides a deposit into locked savings and spendable parts.
func split(amount int64) (saved int64, spend int64) {
	saved = amount * SaveRate / 100
	return saved, amount - saved
}

// Deposit splits the sent ugnot: SaveRate% into locked savings, the rest
// into the caller's spendable balance. lockDays (0-365, 0 = 7-day default)
// sets the savings unlock date; it can only be extended, never shortened.
// Returns (saved, spendable) amounts credited by this deposit.
func Deposit(cur realm, lockDays int64) (saved int64, spend int64) {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" {
		panic("send exactly ugnot")
	}
	amount := sent[0].Amount
	if amount < MinDeposit {
		panic("deposit below minimum (1000 ugnot)")
	}
	if lockDays < 0 || lockDays > MaxLockDays {
		panic("lockDays must be 0-365")
	}
	if lockDays == 0 {
		lockDays = DefaultLockDays
	}

	caller := cur.Previous().Address()
	saved, spend = split(amount)

	if !seen[caller] {
		seen[caller] = true
		depositors = append(depositors, caller)
	}
	spendable[caller] += spend
	savings[caller] += saved
	totalSpend += spend
	totalSaved += saved
	totalDep++

	unlock := time.Now().Unix() + lockDays*secondsPerDay
	if unlock > unlockAt[caller] {
		unlockAt[caller] = unlock
	}
	return saved, spend
}

// WithdrawSpendable returns amount ugnot from the caller's spendable balance.
func WithdrawSpendable(cur realm, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	caller := cur.Previous().Address()
	if spendable[caller] < amount {
		panic("insufficient spendable balance")
	}
	spendable[caller] -= amount
	totalSpend -= amount
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

// WithdrawSavings returns amount ugnot from the caller's locked savings.
// It aborts while the savings are still locked.
func WithdrawSavings(cur realm, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	caller := cur.Previous().Address()
	if time.Now().Unix() < unlockAt[caller] {
		panic("savings still locked")
	}
	if savings[caller] < amount {
		panic("insufficient savings balance")
	}
	savings[caller] -= amount
	totalSaved -= amount
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

// BalanceOf returns (spendable, savings) for addr. Read-only.
func BalanceOf(addr address) (spend int64, save int64) {
	return spendable[addr], savings[addr]
}

// UnlockAt returns the unix timestamp after which addr may withdraw savings.
// Read-only.
func UnlockAt(addr address) int64 {
	return unlockAt[addr]
}

// Stats returns (deposits, totalSaved, totalSpendable, users). Read-only.
func Stats() (deposits int64, saved int64, spend int64, users int) {
	return totalDep, totalSaved, totalSpend, len(depositors)
}

// Leaderboard returns a text table of the top 5 savers by locked savings.
// Read-only.
func Leaderboard() string {
	type entry struct {
		addr address
		save int64
	}
	top := make([]entry, 0, 5)
	for _, d := range depositors {
		s := savings[d]
		if s <= 0 {
			continue
		}
		// Insert sorted descending, keep at most 5.
		e := entry{d, s}
		i := 0
		for i < len(top) && top[i].save >= s {
			i++
		}
		if i < 5 {
			top = append(top, entry{})
			copy(top[i+1:], top[i:])
			top[i] = e
			if len(top) > 5 {
				top = top[:5]
			}
		}
	}
	var b strings.Builder
	b.WriteString("Top savers (locked savings, ugnot):\n")
	if len(top) == 0 {
		b.WriteString("No savers yet. Be the first!\n")
		return b.String()
	}
	for i, e := range top {
		b.WriteString(strconv.Itoa(i + 1))
		b.WriteString(". ")
		b.WriteString(e.addr.String())
		b.WriteString(" — ")
		b.WriteString(strconv.FormatInt(e.save, 10))
		b.WriteString(" ugnot\n")
	}
	return b.String()
}

// Render is the gnoweb page for this realm.
func Render(_ string) string {
	dep, saved, spend, users := Stats()
	var b strings.Builder
	b.WriteString("# GnomeSaver — Set it and forget it\n\n")
	b.WriteString("A savings vault on Gno.land. Every deposit splits automatically: ")
	b.WriteString("**90% spendable** (withdraw any time) and **10% locked savings** ")
	b.WriteString("(withdrawable after your chosen unlock date). No admin, no fees, ")
	b.WriteString("no token — just native GNOT held by this realm.\n\n")
	b.WriteString("## Stats\n\n")
	b.WriteString("- Deposits: " + strconv.FormatInt(dep, 10) + "\n")
	b.WriteString("- Total locked savings: " + strconv.FormatInt(saved, 10) + " ugnot\n")
	b.WriteString("- Total spendable: " + strconv.FormatInt(spend, 10) + " ugnot\n")
	b.WriteString("- Savers: " + strconv.Itoa(users) + "\n\n")
	b.WriteString("## How to use\n\n")
	b.WriteString("```\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkgPath + " \\\n")
	b.WriteString("  -func Deposit -args 7 -send 10000ugnot \\\n")
	b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 5000000 \\\n")
	b.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n")
	b.WriteString("```\n\n")
	b.WriteString("`Deposit(lockDays)` splits your deposit 90/10 and locks the 10% for ")
	b.WriteString("`lockDays` days (0 = 7 days, max 365). `WithdrawSpendable(amount)` ")
	b.WriteString("takes back spendable funds any time; `WithdrawSavings(amount)` takes ")
	b.WriteString("back locked savings after the unlock date. Minimum deposit: 1000 ugnot.\n\n")
	b.WriteString("## Leaderboard\n\n")
	b.WriteString(Leaderboard())
	return b.String()
}
