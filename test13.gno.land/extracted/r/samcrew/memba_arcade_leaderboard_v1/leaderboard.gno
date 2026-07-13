// Package memba_arcade_leaderboard_v1 is the funds-free, verified-score ledger for MEMBA: BARRICADE
// (and future Memba arcade games). Nothing here trusts a client number: an authorized ATTESTER (the
// backend verifier's key) re-simulates a submitted input log and attests only the reproduced result.
// The chain stores the attested result plus a commitment to the log (its sha256) — the log itself
// stays off-chain; "verified, never trustless" is the public contract.
//
// SAFETY: there is NO banker, NO transfer, and NO OriginSend anywhere — the fund-drain risk class
// does not apply. The only trust boundary is who may attest (owner ∪ the attester allowlist); every
// write emits an event. Two buckets never mix: the competitive DAILY BOARD (one best entry per
// address per day, shared seed) and personal TRAINING RECEIPTS (practice runs — a verified flex,
// never ranked).
package memba_arcade_leaderboard_v1

import (
	"chain"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// AdminAddress is the samcrew-core deploy multisig (same as the other Memba realms). It inits
// `owner`; hand it to the memba_dao executor post-deploy via the 2-step ownership transfer.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const (
	// MaxScore bounds a single attested score — a fat-finger / overflow guard far above any
	// reachable sim score (BARRICADE scores live in the tens of thousands).
	MaxScore = int64(1_000_000_000)
	// ReceiptsCap bounds one address's training-receipt ring (oldest evicted first).
	ReceiptsCap = 100
	// ReceiptDailyCap bounds how many receipts one address may mint per day (spam cap).
	ReceiptDailyCap = 5
	// RequestCap bounds one address's PENDING receipt requests (fulfilled ones free their slot):
	// the only unprivileged write path must not grow realm state unboundedly.
	RequestCap = 8
)

// Entry is one attested, verifier-reproduced run result.
type Entry struct {
	Addr           address
	Day            string // YYYY-MM-DD (the shared daily seed's date; receipt = submission day)
	Mode           string // "daily" | "practice"
	Seed           string
	Score          int64
	Waves          int64
	Won            bool // the Core Arc was cleared (overtime always ends in the line falling)
	OvertimeRound  int64
	SimVersion     int64
	StateHash      string // the sim's canonical terminal-state digest
	InputLogSha256 string // commitment to the off-chain input log (the proof)
	AttestedAt     int64  // block height
}

var (
	owner        address
	pendingOwner address
	paused       bool
	attesters    = avl.NewTree() // attester address string -> bool
	boards       = avl.NewTree() // "day|addr" -> *Entry (competitive, one best per addr/day)
	receipts     = avl.NewTree() // addr string -> []*Entry (training ring, capped)
	logHashes    = avl.NewTree() // "day|sha256" -> addr string (board slot: first-submitter-per-day)
	hashOwners   = avl.NewTree() // sha256 -> addr string (GLOBAL: a log binds to ONE address, ever)
	requests     = avl.NewTree() // "addr|sha256" -> int64 height (player-paid receipt requests)
	requestCount = avl.NewTree() // addr string -> int (pending requests, capped at RequestCap)
	boardCount   = avl.NewTree() // day -> int (entries per day, O(1) reads)
)

func init() { owner = address(AdminAddress) }

func assertOwner(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if cur.Previous().Address() != owner {
		panic("unauthorized: owner only")
	}
}

func assertNotPaused() {
	if paused {
		panic("attestation is paused")
	}
}

func isAttester(addr string) bool {
	_, ok := attesters.Get(addr)
	return ok
}

// assertAttester is the single trust boundary: only the owner or an allowlisted attester key (the
// backend verifier) may write results. The verifier's own re-simulation gate is what makes an
// attested score meaningful — this realm only enforces that the source is trusted.
func assertAttester(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	pr := cur.Previous().Address()
	if pr != owner && !isAttester(pr.String()) {
		panic("unauthorized: owner or allowlisted attester only")
	}
}

func assertEntryShape(addr address, day, mode, seed string, score, waves, simVersion int64, stateHash, logHash string) {
	if addr == "" {
		panic("addr must be non-empty")
	}
	if len(day) != 10 || day[4] != '-' || day[7] != '-' {
		panic("day must be YYYY-MM-DD")
	}
	for _, i := range []int{0, 1, 2, 3, 5, 6, 8, 9} {
		if day[i] < '0' || day[i] > '9' {
			panic("day must be YYYY-MM-DD")
		}
	}
	if mode != "daily" && mode != "practice" {
		panic("mode must be daily or practice")
	}
	if seed == "" {
		panic("seed must be non-empty")
	}
	if score < 0 || score > MaxScore {
		panic("score out of range")
	}
	if waves < 0 {
		panic("waves out of range")
	}
	if simVersion <= 0 {
		panic("simVersion must be positive")
	}
	if stateHash == "" || logHash == "" {
		panic("stateHash and inputLogSha256 must be non-empty")
	}
}

// AttestScore writes (or improves) an address's entry on a day's competitive board. Attester-only.
// The verifier batches the day's results into one multi-msg tx at day close, plus spam-capped
// singles for the "certify now" flow. Re-attesting the same address/day only ever RAISES the score
// (Second Wind). A log hash already attested that day for a DIFFERENT address is rejected — on a
// shared daily seed a valid input log is portable, so first-submitter wins (replay-theft defense).
func AttestScore(cur realm, addr address, day, seed string, score, waves int64, won bool, overtimeRound, simVersion int64, stateHash, logHash string) {
	assertNotPaused()
	assertAttester(cur)
	assertEntryShape(addr, day, "daily", seed, score, waves, simVersion, stateHash, logHash)
	if overtimeRound < 0 {
		panic("overtimeRound out of range")
	}

	hashKey := day + "|" + logHash
	if v, ok := logHashes.Get(hashKey); ok && v.(string) != addr.String() {
		panic("duplicate input log: already attested for another address today")
	}
	// The GLOBAL net: a log binds to one address forever, across BOTH buckets —
	// a stolen log can't take a board slot today, a receipt tomorrow, or
	// anything under a different day string (review finding: the day-scoped
	// check alone left the receipts surface forgeable).
	assertHashOwner(logHash, addr)

	key := day + "|" + addr.String()
	if v, ok := boards.Get(key); ok {
		if v.(*Entry).Score >= score {
			panic("existing entry is not improved")
		}
	} else {
		n := 0
		if c, ok := boardCount.Get(day); ok {
			n = c.(int)
		}
		boardCount.Set(day, n+1)
	}

	e := &Entry{
		Addr: addr, Day: day, Mode: "daily", Seed: seed, Score: score, Waves: waves, Won: won,
		OvertimeRound: overtimeRound, SimVersion: simVersion, StateHash: stateHash,
		InputLogSha256: logHash, AttestedAt: runtime.ChainHeight(),
	}
	boards.Set(key, e)
	logHashes.Set(hashKey, addr.String())
	hashOwners.Set(logHash, addr.String())
	chain.Emit("ScoreAttested", "addr", addr.String(), "day", day, "score", itoa64(score),
		"won", boolStr(won), "overtime", itoa64(overtimeRound), "simVersion", itoa64(simVersion))
}

// AttestReceipt mints a personal training receipt — a verified "I did this run", never ranked.
// Attester-only; capped per address per day and ring-capped per address. Fulfills (and clears) a
// matching player-paid RequestReceipt if one is staged.
func AttestReceipt(cur realm, addr address, day, seed string, score, waves int64, won bool, overtimeRound, simVersion int64, stateHash, logHash string) {
	assertNotPaused()
	assertAttester(cur)
	assertEntryShape(addr, day, "practice", seed, score, waves, simVersion, stateHash, logHash)
	if overtimeRound < 0 {
		panic("overtimeRound out of range")
	}

	var ring []*Entry
	if v, ok := receipts.Get(addr.String()); ok {
		ring = v.([]*Entry)
	}
	sameDay := 0
	for _, r := range ring {
		if r.InputLogSha256 == logHash {
			panic("duplicate receipt for this input log")
		}
		if r.Day == day {
			sameDay++
		}
	}
	if sameDay >= ReceiptDailyCap {
		panic("receipt cap reached for this day")
	}
	// The same GLOBAL net as the board: a receipt for someone else's attested
	// log is a forged "verified flex" — reject it, and bind first use here too.
	assertHashOwner(logHash, addr)

	e := &Entry{
		Addr: addr, Day: day, Mode: "practice", Seed: seed, Score: score, Waves: waves, Won: won,
		OvertimeRound: overtimeRound, SimVersion: simVersion, StateHash: stateHash,
		InputLogSha256: logHash, AttestedAt: runtime.ChainHeight(),
	}
	ring = append(ring, e)
	if len(ring) > ReceiptsCap {
		ring = ring[len(ring)-ReceiptsCap:] // evict oldest
	}
	receipts.Set(addr.String(), ring)
	hashOwners.Set(logHash, addr.String())
	clearRequest(addr, logHash)
	chain.Emit("ReceiptAttested", "addr", addr.String(), "day", day, "score", itoa64(score),
		"simVersion", itoa64(simVersion))
}

// RequestReceipt is the player-paid leg: ANY signer stages an on-chain consent + payment anchor for
// one of their own runs (they pay this call's gas). The backend sees the event, verifies the stored
// log, and fulfills via AttestReceipt. Self-limiting: each request costs the caller gas, and one
// key slot per (addr, hash).
func RequestReceipt(cur realm, logHash string) {
	assertNotPaused()
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if logHash == "" {
		panic("logHash must be non-empty")
	}
	caller := cur.Previous().Address()
	key := caller.String() + "|" + logHash
	if _, ok := requests.Get(key); !ok {
		n := 0
		if c, ok := requestCount.Get(caller.String()); ok {
			n = c.(int)
		}
		if n >= RequestCap {
			panic("pending request cap reached — wait for fulfillment")
		}
		requestCount.Set(caller.String(), n+1)
	}
	requests.Set(key, runtime.ChainHeight())
	chain.Emit("ReceiptRequested", "addr", caller.String(), "logHash", logHash)
}

// assertHashOwner enforces the GLOBAL one-log-one-address rule shared by both
// buckets, and is idempotent for the rightful owner (Second Wind re-attests).
func assertHashOwner(logHash string, addr address) {
	if v, ok := hashOwners.Get(logHash); ok && v.(string) != addr.String() {
		panic("duplicate input log: already bound to another address")
	}
}

// clearRequest removes a fulfilled request and frees the caller's cap slot.
func clearRequest(addr address, logHash string) {
	key := addr.String() + "|" + logHash
	if _, ok := requests.Get(key); !ok {
		return
	}
	requests.Remove(key)
	if c, ok := requestCount.Get(addr.String()); ok {
		if n := c.(int); n > 1 {
			requestCount.Set(addr.String(), n-1)
		} else {
			requestCount.Remove(addr.String())
		}
	}
}

func itoa64(n int64) string { return ufmt.Sprintf("%d", n) }

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
