package miner

import (
	"chain"
	"strings"
)

// Admin functions: the smallest honest upgrade path. None of them can edit a
// player's values, log, history or badges.
//
//   - Halt(reason): one way. Join and Collect panic with "Halted: <reason>"
//     from then on; nothing else changes. State, Season, PlayerSeason,
//     SeasonResult and Render keep working: every player's stored
//     projection is their result, and season results become final at the
//     season end as usual (computed on read, since no Collect stores the
//     cutoffs any more).
//   - SetSuccessor(path): records the package path of the realm that takes
//     over (shown by Render and Season()). It may be set before or after a
//     halt, and corrected.
//   - ProposeAdmin(addr), then AcceptAdmin() by addr: hands the admin role
//     over in two steps, so a typo cannot lose it.

const (
	MaxReasonBytes    = 200
	MaxSuccessorBytes = 128
)

var (
	halted       bool
	haltReason   string
	successor    string  // package path of the next realm, "" = none
	pendingAdmin address // proposed by ProposeAdmin, "" = none
)

func onlyAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func notHalted() {
	if halted {
		panic("Halted: " + haltReason)
	}
}

// Halt stops Join and Collect for good, with a reason shown to players
// (1 to MaxReasonBytes bytes, one line). Admin only.
func Halt(cur realm, reason string) {
	onlyAdmin(cur.Previous().Address())
	if halted {
		panic("already halted")
	}
	if reason == "" || len(reason) > MaxReasonBytes {
		panic("reason: 1 to 200 bytes")
	}
	for i := 0; i < len(reason); i++ {
		if reason[i] < 0x20 || reason[i] == 0x7f {
			panic("reason: one line, no control characters")
		}
	}
	halted = true
	haltReason = reason
	chain.Emit("Halt", "reason", reason)
}

// SetSuccessor records the package path of the realm that continues the
// game, e.g. "gno.land/r/…/gnogame/miner/v2"; "" clears it. Admin only.
func SetSuccessor(cur realm, path string) {
	onlyAdmin(cur.Previous().Address())
	if path != "" {
		if !strings.HasPrefix(path, "gno.land/r/") || len(path) > MaxSuccessorBytes {
			panic("successor: a realm path gno.land/r/…, at most 128 bytes")
		}
		for i := len("gno.land/r/"); i < len(path); i++ {
			c := path[i]
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '/' || c == '_' || c == '.' || c == '-') {
				panic("successor: only a-z 0-9 / _ . - in the path")
			}
		}
	}
	successor = path
	chain.Emit("Successor", "path", path)
}

// ProposeAdmin names the next admin; it takes effect when that address
// calls AcceptAdmin. Proposing again replaces the proposal. Admin only.
func ProposeAdmin(cur realm, addr address) {
	onlyAdmin(cur.Previous().Address())
	if !addr.IsValid() {
		panic("invalid address")
	}
	pendingAdmin = addr
	chain.Emit("AdminProposed", "admin", admin.String(), "proposed", addr.String())
}

// AcceptAdmin makes the caller the admin; only the proposed address may
// call it.
func AcceptAdmin(cur realm) {
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("not the proposed admin")
	}
	prev := admin
	admin = caller
	pendingAdmin = ""
	chain.Emit("AdminChanged", "from", prev.String(), "to", caller.String())
}
