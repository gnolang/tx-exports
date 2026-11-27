// Package agentleash is an on-chain allowance / guardrail realm for AI agents.
//
// A human owner creates a "leash" for an agent address: a per-transaction
// cap, a daily cap and an optional expiry. The owner deposits testnet ugnot
// into the realm vault; the agent can then pay third parties ONLY through
// this realm, and the realm enforces the caps on-chain. Every spend is
// recorded in a transparent on-chain history. The owner can pause or revoke
// the leash at any time (revoke refunds whatever is left).
//
// Story: AI agents (e.g. driven through gnomcp) get money with guardrails.
// An over-limit payment attempt is rejected by the chain itself, not by a
// prompt or a policy file.
//
// PHASE 1 SKELETON: core state + the five core functions with basic cap
// enforcement and unit tests. Not yet deployed anywhere.
package agentleash

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// denom is the only coin this realm handles in v1: native testnet ugnot.
const denom = "ugnot"

// SpendRecord is one entry of a leash's transparent spend history.
type SpendRecord struct {
	To     address
	Amount int64 // ugnot
	At     time.Time
	Memo   string
}

// Leash is the guardrail contract between one owner and one agent.
type Leash struct {
	ID         int
	Owner      address
	Agent      address
	PerTxCap   int64 // ugnot; max amount per single Spend call
	DailyCap   int64 // ugnot; max total spent per UTC day
	SpentToday int64 // ugnot already spent in the current UTC day window
	DayStart   time.Time
	Balance    int64 // ugnot held in the vault for this leash
	Paused     bool
	Revoked    bool
	ExpiresAt  time.Time // zero value = no expiry
	History    []SpendRecord
}

var (
	leashes avl.Tree // id (string) -> *Leash
	counter int
)

// ---------------------------------------------------------------------------
// Core functions
// ---------------------------------------------------------------------------

// CreateLeash creates a new leash for `agent`, owned by the caller.
// perTxCap and dailyCap are in ugnot and must be positive.
// expiryUnix is a unix timestamp (seconds); 0 means no expiry.
// Returns the new leash ID.
func CreateLeash(cur realm, agent address, perTxCap int64, dailyCap int64, expiryUnix int64) int {
	owner := cur.Previous().Address()
	require(agent != "", "agent address required")
	require(agent != owner, "agent must differ from owner")
	require(perTxCap > 0, "per-transaction cap must be positive")
	require(dailyCap >= perTxCap, "daily cap must be >= per-transaction cap")

	l := &Leash{
		Owner:    owner,
		Agent:    agent,
		PerTxCap: perTxCap,
		DailyCap: dailyCap,
		DayStart: startOfDay(time.Now()),
	}
	if expiryUnix > 0 {
		l.ExpiresAt = time.Unix(expiryUnix, 0).UTC()
		require(l.ExpiresAt.After(time.Now()), "expiry must be in the future")
	}

	counter++
	l.ID = counter
	leashes.Set(strconv.Itoa(counter), l)
	return counter
}

// Deposit adds ugnot to a leash's vault balance. Owner only.
// The coins must be attached to the call (maketx call -send <amount>ugnot).
// Only direct user calls are accepted: OriginSend describes a real payment
// only for a pure EOA caller (see gno security guide).
func Deposit(cur realm, id int) {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	l := mustGet(id)
	require(cur.Previous().Address() == l.Owner, "only the owner can deposit")
	require(!l.Revoked, "leash is revoked")

	sent := unsafe.OriginSend()
	amount := sent.AmountOf(denom)
	require(amount > 0, "deposit must attach ugnot")
	require(int64(len(sent)) == 1, "deposit accepts ugnot only")

	l.Balance += amount
}

// Spend pays `amount` ugnot from the leash vault to `to`. Agent only.
// The realm enforces, in order: leash active (not revoked / paused /
// expired), per-transaction cap, daily cap (UTC day window), vault balance.
// An over-limit attempt panics — the payment is rejected on-chain and no
// state changes.
func Spend(cur realm, id int, to address, amount int64, memo string) {
	l := mustGet(id)
	require(cur.Previous().Address() == l.Agent, "caller is not the agent")
	require(!l.Revoked, "leash is revoked")
	require(!l.Paused, "leash is paused")
	require(to != "", "recipient required")
	require(amount > 0, "amount must be positive")

	now := time.Now()
	if !l.ExpiresAt.IsZero() && now.After(l.ExpiresAt) {
		panic("leash expired")
	}
	require(amount <= l.PerTxCap, "over per-transaction cap")

	// Roll the daily window if a new UTC day has started.
	if today := startOfDay(now); !today.Equal(l.DayStart) {
		l.DayStart = today
		l.SpentToday = 0
	}
	require(l.SpentToday+amount <= l.DailyCap, "over daily cap")
	require(amount <= l.Balance, "insufficient vault balance")

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{Denom: denom, Amount: amount}})

	l.Balance -= amount
	l.SpentToday += amount
	l.History = append(l.History, SpendRecord{To: to, Amount: amount, At: now, Memo: memo})
}

// PauseLeash freezes a leash: the agent cannot spend until resumed or
// revoked. Owner only.
func PauseLeash(cur realm, id int) {
	l := mustGet(id)
	require(cur.Previous().Address() == l.Owner, "only the owner can pause")
	require(!l.Revoked, "leash is revoked")
	l.Paused = true
}

// ResumeLeash unfreezes a paused leash. Owner only.
func ResumeLeash(cur realm, id int) {
	l := mustGet(id)
	require(cur.Previous().Address() == l.Owner, "only the owner can resume")
	require(!l.Revoked, "leash is revoked")
	l.Paused = false
}

// RevokeLeash permanently disables a leash and refunds the remaining vault
// balance to the owner. Owner only.
func RevokeLeash(cur realm, id int) {
	l := mustGet(id)
	require(cur.Previous().Address() == l.Owner, "only the owner can revoke")
	require(!l.Revoked, "leash already revoked")

	if l.Balance > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), l.Owner, chain.Coins{{Denom: denom, Amount: l.Balance}})
		l.Balance = 0
	}
	l.Revoked = true
	l.Paused = false
}

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

// Render shows the leash list (home) or one leash with its spend history
// (path = leash ID). Path input is only used as a numeric lookup key.
func Render(path string) string {
	if path == "" {
		out := "# AgentLeash — on-chain guardrails for AI agents\n\n"
		if leashes.Size() == 0 {
			return out + "No leashes yet."
		}
		leashes.Iterate("", "", func(key string, value any) bool {
			l := value.(*Leash)
			out += ufmt.Sprintf("- #%d owner %s · agent %s · balance %d%s · status %s\n",
				l.ID, l.Owner, l.Agent, l.Balance, denom, l.status())
			return false
		})
		return out
	}

	l := leashes.Get(path)
	if l == nil {
		return "404: unknown leash"
	}
	leash := l.(*Leash)
	out := ufmt.Sprintf("# Leash #%d\n\n- owner: %s\n- agent: %s\n- per-tx cap: %d%s\n- daily cap: %d%s (spent today: %d%s)\n- balance: %d%s\n- status: %s\n",
		leash.ID, leash.Owner, leash.Agent,
		leash.PerTxCap, denom, leash.DailyCap, denom, leash.SpentToday, denom,
		leash.Balance, denom, leash.status())
	if !leash.ExpiresAt.IsZero() {
		out += ufmt.Sprintf("- expires: %s\n", leash.ExpiresAt.Format(time.RFC3339))
	}
	if len(leash.History) > 0 {
		out += "\n## Spend history\n\n"
		for _, r := range leash.History {
			out += ufmt.Sprintf("- %s · %d%s -> %s · %s\n",
				r.At.Format(time.RFC3339), r.Amount, denom, r.To, r.Memo)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

func (l *Leash) status() string {
	switch {
	case l.Revoked:
		return "revoked"
	case l.Paused:
		return "paused"
	case !l.ExpiresAt.IsZero() && time.Now().After(l.ExpiresAt):
		return "expired"
	default:
		return "active"
	}
}

// startOfDay returns the UTC midnight at or before t.
func startOfDay(t time.Time) time.Time {
	u := t.UTC()
	return time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)
}

func mustGet(id int) *Leash {
	v := leashes.Get(strconv.Itoa(id))
	if v == nil {
		panic("unknown leash ID")
	}
	return v.(*Leash)
}

func require(check bool, msg string) {
	if !check {
		panic(msg)
	}
}
