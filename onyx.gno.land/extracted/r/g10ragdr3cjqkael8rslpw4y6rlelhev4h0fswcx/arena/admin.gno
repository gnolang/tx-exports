package arena

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

// SetPaused freezes posts, replies, tips, and ticket buys when on is true/1/yes.
// Pass false/0/no to reopen. Ticket sells are never paused.
func SetPaused(cur realm, on string) {
	mustAdmin(cur)
	switch on {
	case "true", "1", "yes":
		state.paused = true
	case "false", "0", "no":
		state.paused = false
	default:
		panic("paused must be true or false")
	}
	chain.Emit("ArenaPause", "paused", on, "admin", state.admin.String())
}

// SetTreasury moves future protocol fees and surplus sweeps to next.
func SetTreasury(cur realm, next address) {
	mustAdmin(cur)
	if !next.IsValid() {
		panic("bad treasury")
	}
	state.treasury = next
	chain.Emit("ArenaTreasury", "treasury", next.String())
}

// TransferAdmin rotates the pause/sweep key.
func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if !next.IsValid() {
		panic("bad admin")
	}
	state.admin = next
	chain.Emit("ArenaAdmin", "admin", next.String())
}

// SetSuccessor records the package path of a later realm.
// An empty path clears it. This does not move coins or shares.
func SetSuccessor(cur realm, next string) {
	mustAdmin(cur)
	next = strings.TrimSpace(next)
	if next != "" {
		if !validSuccessor(next) || next == unsafe.CurrentRealm().PkgPath() {
			panic("bad successor")
		}
	}
	state.successor = next
	chain.Emit("ArenaSuccessor", "path", next)
}

func validSuccessor(path string) bool {
	const prefix = "gno.land/r/"
	if !strings.HasPrefix(path, prefix) || len(path) > 128 {
		return false
	}
	rest := path[len(prefix):]
	if rest == "" || strings.HasSuffix(rest, "/") || strings.Contains(rest, "//") || strings.Contains(rest, ".") {
		return false
	}
	for i := 0; i < len(rest); i++ {
		c := rest[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '/', c == '_':
		default:
			return false
		}
	}
	return true
}

// Sweep sends this realm's ugnot above TotalReserve to the treasury.
// confirm must be the word "sweep". Ticket collateral is not included.
func Sweep(cur realm, confirm string) {
	mustAdmin(cur)
	if confirm != "sweep" {
		panic("confirm sweep")
	}
	if !state.treasury.IsValid() {
		panic("treasury not set")
	}
	bal := banker.NewReadonlyBanker().GetCoins(cur.Address()).AmountOf("ugnot")
	if bal < state.totalReserve {
		panic("insolvent")
	}
	surplus := bal - state.totalReserve
	payout(cur, state.treasury, surplus, "treasury")
	chain.Emit("ArenaSweep", "ugnot", strconv.FormatInt(surplus, 10))
}
