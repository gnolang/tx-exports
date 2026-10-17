package nsdata

import (
	"strconv"
	"time"

	"chain"
)

/*
THE INCIDENT SWITCHES: the undo for what a stolen admin key set instantly
(re-audit 2026-10-16, M-2).

The admin's instant powers leave their marks in this realm — credits it
granted its own wallets, the claim window it opened, the granter's and the
keeper's seats — and those outlive its eviction. The incident runbook could
not undo them in time: every logic write passes the trust gate and the
pause, so while the logic was revoked and the registry paused nothing could
be disarmed, and the moment recovery unpaused, the thief's wallets redeemed
in the same block. So these are DIRECT WALLET CALLS on the vault, by the
governance roles, that work while paused and with every logic realm
revoked — which is exactly when they are needed — and that only ever take
something away:

	Disarm           admin, recovery or guardian. Deletes the globals whose
	                 presence is a power (disarmKeys): the claim window, the
	                 granter and the keeper. Instant and idempotent, so the
	                 guardian bot may send it without reading first.

	VoidGrantsSince  recovery. Everything a logic realm granted at or after
	                 `since`, up to this second, is void — nslogic reads its
	                 credits through GrantVoided. Windows only accumulate;
	                 none is ever lifted, so nothing voided comes back to
	                 life. Past maxGrantVoids the two with the smallest gap
	                 merge. The admin grants again what was legitimate.

	SetQuarantine    recovery. Until `until`, nothing that gives a name away
	                 runs — nslogic: credit redemption, RegisterFor, free
	                 grants — whatever the claim window says, so the registry
	                 can be unpaused before the new admin has finished
	                 cleaning up. At most maxQuarantine ahead; recovery may
	                 shorten or lift it.

THE REGISTRY STILL DOES NOT DECIDE. The key names below are the logic
realm's, like the restore machinery's own keys, and a logic realm must keep
"absent" the safe reading of each: no claim window is a closed one, no
granter and no keeper is nobody. What a void or a quarantine covers is the
logic realm's to say; the vault keeps the clocks and the roles.
*/

// disarmKeys are the globals whose presence is a power and whose absence is
// the safe reading (nslogic: credits.gno, freetier.gno, keeper.gno).
var disarmKeys = []string{"claimend", "granter", "keeper"}

const (
	maxGrantVoids = 8                       // void windows kept; the oldest two merge past it
	maxQuarantine = int64(30 * 24 * 60 * 60) // the furthest a quarantine may reach, in seconds
)

var (
	// grantVoids are [from, to] windows, unix seconds inclusive, oldest
	// first: a grant whose time falls inside any of them is void.
	grantVoids [][2]int64

	// quarantineUntil is the unix second giveaways may run again; 0 none.
	quarantineUntil int64
)

func assertIsRecovery(cur realm) {
	if a := cur.Previous().Address(); a == "" || a != recovery {
		panic("nsdata: restricted to recovery")
	}
}

// Disarm deletes the claim window, the granter and the keeper at once.
// Admin, recovery or guardian, as a direct wallet call; it works while the
// registry is paused and with every logic realm revoked.
func Disarm(cur realm) {
	assertCanPause(cur)
	had := ""
	for _, k := range disarmKeys {
		if globals.Get(k) != nil {
			globals.Remove(k)
			if had != "" {
				had += ","
			}
			had += k
		}
	}
	chain.Emit("Disarmed", "keys", had, "by", cur.Previous().Address().String())
}

// VoidGrantsSince voids every grant made at or after `since`, up to now.
// Recovery only. `since` may be 0 (everything so far) and may not be in the
// future. The window joins the ones already in force; past maxGrantVoids
// the two oldest merge, which can only void more, never less.
func VoidGrantsSince(cur realm, since int64) {
	assertIsRecovery(cur)
	now := time.Now().Unix()
	if since < 0 || since > now {
		panic("nsdata: a void starts in the past, at 0 or later")
	}
	grantVoids = insertVoid(grantVoids, [2]int64{since, now})
	for len(grantVoids) > maxGrantVoids {
		// Merge the two windows with the smallest gap between them, so the
		// fewest legitimate grants fall into the merged span (re-audit
		// follow-up), and say what was merged.
		best := 0
		for i := 1; i+1 < len(grantVoids); i++ {
			if grantVoids[i+1][0]-grantVoids[i][1] < grantVoids[best+1][0]-grantVoids[best][1] {
				best = i
			}
		}
		a, b := grantVoids[best], grantVoids[best+1]
		m := [2]int64{a[0], a[1]}
		if b[1] > m[1] {
			m[1] = b[1]
		}
		chain.Emit("GrantVoidsMerged", "from", strconv.FormatInt(m[0], 10), "to", strconv.FormatInt(m[1], 10))
		grantVoids = append(append(append([][2]int64{}, grantVoids[:best]...), m), grantVoids[best+2:]...)
	}
	chain.Emit("GrantsVoided", "from", strconv.FormatInt(since, 10), "to", strconv.FormatInt(now, 10),
		"by", cur.Previous().Address().String())
}

// insertVoid keeps the windows sorted by start and folds overlapping ones
// together, so "the gap between two windows" means what it says.
func insertVoid(ws [][2]int64, w [2]int64) [][2]int64 {
	out := [][2]int64{}
	placed := false
	for _, x := range ws {
		if !placed && w[0] < x[0] {
			out = append(out, w)
			placed = true
		}
		out = append(out, x)
	}
	if !placed {
		out = append(out, w)
	}
	merged := [][2]int64{}
	for _, x := range out {
		if n := len(merged); n > 0 && x[0] <= merged[n-1][1] {
			if x[1] > merged[n-1][1] {
				merged[n-1][1] = x[1]
			}
			continue
		}
		merged = append(merged, x)
	}
	return merged
}

// GrantVoided reports whether a grant made at unix second `at` falls inside
// a void recovery declared.
func GrantVoided(at int64) bool {
	for _, w := range grantVoids {
		if at >= w[0] && at <= w[1] {
			return true
		}
	}
	return false
}

// GrantVoids lists the void windows, "from-to" comma-separated, oldest first.
func GrantVoids() string {
	out := ""
	for i, w := range grantVoids {
		if i > 0 {
			out += ","
		}
		out += strconv.FormatInt(w[0], 10) + "-" + strconv.FormatInt(w[1], 10)
	}
	return out
}

// SetQuarantine holds every giveaway shut until `until` (unix seconds), at
// most maxQuarantine ahead; 0 lifts it. Recovery only.
func SetQuarantine(cur realm, until int64) {
	assertIsRecovery(cur)
	now := time.Now().Unix()
	if until != 0 && (until <= now || until > now+maxQuarantine) {
		panic("nsdata: a quarantine ends in the future and at most " +
			strconv.FormatInt(maxQuarantine/86400, 10) + " days ahead; 0 lifts it")
	}
	quarantineUntil = until
	chain.Emit("QuarantineSet", "until", strconv.FormatInt(until, 10), "by", cur.Previous().Address().String())
}

// QuarantineUntil is the unix second giveaways may run again, 0 for none.
func QuarantineUntil() int64 { return quarantineUntil }

// Quarantined reports whether a quarantine holds right now.
func Quarantined() bool { return time.Now().Unix() < quarantineUntil }
