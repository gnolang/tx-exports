// Package demo is The Waag's consumer demo realm (ledger O14): a MOCK GNOT
// vault valued entirely through the oracle realm's GetPrice.
//
// What it proves, in one page of on-chain state:
//
//  1. A real protocol can consume the feed: positions are opened at the
//     published median price and marked against it as the feed updates.
//  2. The refusal design works FROM THE CONSUMER SIDE: when the feed is
//     frozen (paused, stale, or below quorum), opening a position reverts
//     with a clear reason and the dashboard renders "FEED FROZEN" instead
//     of guessing a number. This is the exact integration pattern the
//     parked lending flagship will follow.
//  3. Positions go visibly UNDERWATER when the fed price falls more than
//     the threshold (admin-tunable, default 10%) below entry.
//
// It is a DEMO: deposits are mock numbers, no real GNOT is held or moved.
// No borrowing, no interest — valuation and health display only (O14).
//
// ---- The frozen-feed pattern (verified, not guessed) ----
//
// oracle.GetPrice PANICS when the feed cannot be trusted, and a panic that
// crosses a realm boundary cannot be caught in production (revive() is a
// test-mode builtin only — §13 trap, verified against v1.8.0). So this
// realm NEVER catches; it CHECKS FIRST and only then calls:
//
//	feedAnswering() = !paused (oracle.Config) AND fresh >= quorum
//	                  (parsed from the oracle.GetSources header, whose
//	                   stable text format is that function's documented
//	                   consumer contract)
//
// Why that check is sufficient (proof sketch, oracle.gno v0): GetPrice
// panics iff paused, unpublished, below quorum, or median stale. If >=
// quorum sources are fresh NOW, let hN be the newest fresh ACCEPTED
// submission height. Every currently-fresh source was also fresh at hN
// (its accepted height lies in (hN-staleness, hN]), so the recompute at
// hN saw quorum and published the median at hN; hN is within the
// staleness window, so the median is fresh and published. Hence
// feedAnswering() true => GetPrice cannot panic. Rejected outliers never
// update a source's height, so they cannot fake freshness.
//
// PRECONDITION: asset GNOT must be registered in the oracle before this
// realm renders (GetSources panics on unknown assets, and a crossing panic
// cannot be caught). Enforced by the deploy runbook order: oracle ->
// RegisterSource x3 -> demo.
//
// Math is integer-only (ledger O7), every product is bounds-checked
// against int64 overflow, and prices are feedmath.Price (micro-USD, 1e6).
package demo

import (
	"strconv"
	"strings"

	"chain"
	"chain/runtime"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
	"gno.land/p/nt/avl/v0"
	oracle "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0"
)

// ---- Constants ------------------------------------------------------------

// Asset is the single feed this demo consumes. v0 is deliberately
// single-asset; the oracle itself is multi-asset.
const Asset = "GNOT"

// OraclePath is informational (rendered in help text).
const OraclePath = "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0"

// DefaultThresholdBps: a position is UNDERWATER when the fed price is this
// many basis points (or more) BELOW its entry price. 1000 bps = 10%.
const DefaultThresholdBps = int64(1000)

// MaxPositionUGNOT caps one mock position at 1000 GNOT (1e9 ugnot). The cap
// keeps amount*price products provable: see valueMicroUSD's overflow guard,
// which holds for ANY price up to feedmath.MaxPrice.
const MaxPositionUGNOT = int64(1000000000)

// Admin is the project admin key (alice) — the same literal-admin rule the
// oracle realm uses (forced decision, master doc §7).
var admin = address("g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh")

// ---- Events ----------------------------------------------------------------

const (
	PositionOpenedEvent   = "VaultPositionOpened"
	PositionClosedEvent   = "VaultPositionClosed"
	ThresholdChangedEvent = "VaultThresholdChanged"
)

// ---- Types & state ----------------------------------------------------------

// position is one depositor's mock vault position. Stored as a POINTER in
// the avl.Tree (same reason as the oracle's sources: tree values are `any`,
// a by-value struct would hand back copies and mutations would vanish).
type position struct {
	depositor   address
	amountUGNOT int64          // mock ugnot, (0, MaxPositionUGNOT]
	entryPrice  feedmath.Price // published median when opened
	entryHeight int64          // height at which that median was published
}

var positions avl.Tree // depositor.String() -> *position

var thresholdBps = DefaultThresholdBps

// maxInt64 for overflow guards. Written as an UNTYPED shift (1<<63 - 1, the
// same idiom as math.MaxInt64) so the constant folds to 9223372036854775807
// at arbitrary precision; the typed form int64(1)<<63 overflows int64 before
// the subtraction and gno's type checker rejects it.
const maxInt64 = 1<<63 - 1

// ---- Feed status (the check-then-call gate) ---------------------------------

// feedAnswering reports whether oracle.GetPrice(Asset) will return a price
// right now instead of panicking. See the package doc for the proof that
// !paused && fresh>=quorum is sufficient.
func feedAnswering() bool {
	_, _, minFresh, paused := oracle.Config()
	if paused {
		return false
	}
	fresh, ok := parseFreshCount(oracle.GetSources(Asset))
	if !ok {
		return false // unparseable header: assume frozen, never guess
	}
	return fresh >= minFresh
}

// feedStatusText renders the feed state as a bare human-readable reason
// ("oracle paused", "only 0 of 2 required sources fresh", ... or
// "ANSWERING"). Callers add their own framing: Deposit wraps it in a
// revert message, Render prefixes the frozen banner.
func feedStatusText() string {
	_, _, minFresh, paused := oracle.Config()
	if paused {
		return "oracle paused"
	}
	fresh, ok := parseFreshCount(oracle.GetSources(Asset))
	if !ok {
		return "unreadable source snapshot"
	}
	if fresh < minFresh {
		return "only " + strconv.Itoa(fresh) + " of " +
			strconv.Itoa(minFresh) + " required sources fresh"
	}
	return "ANSWERING"
}

// parseFreshCount extracts N from the oracle.GetSources header
// "asset=GNOT fresh=N/M quorum=Q". The header format is that function's
// documented stable contract for consumers (oracle.gno).
func parseFreshCount(snapshot string) (int, bool) {
	i := strings.Index(snapshot, "fresh=")
	if i < 0 {
		return 0, false
	}
	rest := snapshot[i+len("fresh="):]
	slash := strings.IndexByte(rest, '/')
	if slash <= 0 {
		return 0, false
	}
	n, err := strconv.Atoi(rest[:slash])
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

// ---- Vault operations --------------------------------------------------------

// Deposit opens a mock position for the caller at the current published
// median. It REVERTS while the feed is frozen: no price, no position — the
// consumer-side mirror of the oracle's own refusal promise.
//
// Crossing function (cur realm): the depositor is cur.Previous(), and it
// must be a direct user call — a realm calling on a user's behalf is the
// confused-deputy hole the oracle also closes.
func Deposit(cur realm, amountUGNOT int64) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("vault: Deposit requires a direct user call")
	}
	if amountUGNOT <= 0 || amountUGNOT > MaxPositionUGNOT {
		panic("vault: amount must be within (0, " +
			strconv.FormatInt(MaxPositionUGNOT, 10) + "] ugnot")
	}
	who := caller.Address()
	key := who.String()
	if _, exists := positions.Get(key).(*position); exists {
		panic("vault: position already open - withdraw it first (v0 is one position per depositor)")
	}
	if !feedAnswering() {
		panic("vault: price feed unavailable (" + feedStatusText() +
			") - deposits are frozen until it answers again")
	}

	price, height := oracle.GetPrice(Asset)
	feedmath.MustValidPrice(price) // belt and braces: never store a bad entry

	positions.Set(key, &position{
		depositor:   who,
		amountUGNOT: amountUGNOT,
		entryPrice:  price,
		entryHeight: height,
	})
	chain.Emit(
		PositionOpenedEvent,
		"depositor", key,
		"asset", Asset,
		"amount_ugnot", strconv.FormatInt(amountUGNOT, 10),
		"entry_price", strconv.FormatInt(int64(price), 10),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}

// Withdraw closes the caller's position. ALWAYS allowed, even with a frozen
// feed: mock funds are never held hostage by a dead oracle. The realized
// P&L is only computed when the feed answers; otherwise the event says so.
func Withdraw(cur realm) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("vault: Withdraw requires a direct user call")
	}
	who := caller.Address()
	key := who.String()
	p, ok := positions.Get(key).(*position)
	if !ok {
		panic("vault: no open position")
	}
	positions.Remove(key)

	feedState := "frozen"
	pnl := int64(0)
	exitPrice := int64(0)
	if feedAnswering() {
		curPrice, _ := oracle.GetPrice(Asset)
		feedState = "answering"
		exitPrice = int64(curPrice)
		pnl = pnlBps(p.entryPrice, curPrice)
	}
	chain.Emit(
		PositionClosedEvent,
		"depositor", key,
		"asset", Asset,
		"amount_ugnot", strconv.FormatInt(p.amountUGNOT, 10),
		"entry_price", strconv.FormatInt(int64(p.entryPrice), 10),
		"exit_price", strconv.FormatInt(exitPrice, 10),
		"pnl_bps", strconv.FormatInt(pnl, 10),
		"feed", feedState,
	)
}

// SetThreshold retunes the underwater threshold (bps below entry).
// Admin-only, direct user calls only.
func SetThreshold(cur realm, bps int64) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("vault: admin functions require a direct user call")
	}
	if caller.Address() != admin {
		panic("vault: caller is not the admin")
	}
	if bps < 0 || bps > feedmath.BpsScale {
		panic("vault: threshold must be within [0, 10000] bps")
	}
	thresholdBps = bps
	chain.Emit(
		ThresholdChangedEvent,
		"threshold_bps", strconv.FormatInt(bps, 10),
	)
}

// ---- Valuation math (integer-only, overflow-guarded) -------------------------

// pnlBps is the signed percentage move from entry to current, in basis
// points. Bounds: |diff| <= feedmath.MaxPrice (1e14), diff*1e4 <= 1e18,
// comfortably inside int64 (9.22e18). Both prices are validated (>0) before
// storage, and GetPrice never returns a non-positive price.
func pnlBps(entry, current feedmath.Price) int64 {
	if current >= entry {
		return int64(current-entry) * feedmath.BpsScale / int64(entry)
	}
	return -int64(entry-current) * feedmath.BpsScale / int64(entry)
}

// valueMicroUSD converts a mock ugnot amount to micro-USD at a price, with
// an explicit overflow guard: amount <= 1e9 and price <= 1e14 CAN exceed
// int64 when multiplied, so the product is checked before it happens.
// ok=false means "too large to display", and the render says exactly that
// instead of wrapping around to a negative number.
func valueMicroUSD(amountUGNOT int64, p feedmath.Price) (int64, bool) {
	if amountUGNOT <= 0 || p <= 0 {
		return 0, false
	}
	if int64(p) > maxInt64/amountUGNOT {
		return 0, false
	}
	return amountUGNOT * int64(p) / feedmath.Scale, true
}

// healthPct is current price as an integer percentage of entry (100 = flat).
// current <= 1e14, *100 = 1e16 — inside int64.
func healthPct(entry, current feedmath.Price) int64 {
	return int64(current) * 100 / int64(entry)
}

// isUnderwater reports whether the position has fallen at least
// thresholdBps below entry.
func isUnderwater(entry, current feedmath.Price) bool {
	return pnlBps(entry, current) <= -thresholdBps
}

// getPosition is the read helper used by render.
func getPosition(addr address) *position {
	p, ok := positions.Get(addr.String()).(*position)
	if !ok {
		return nil
	}
	return p
}
