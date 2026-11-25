// Tavern Trader — verifiable PAPER-trading agent on Gno.land.
// Single realm, the on-chain source of truth for paper trades.
// NO real funds ever move here: positions are state only, settled in
// paper USD. Prices are micro-USD (1_000_000 = $1.00); sizes are USD cents.
//
// Written against Gno v1.8.0 (Onyx testnet). Note: the old `std`
// package no longer exists in v1.8.0 — realms use the `realm` first
// argument and `cur.Previous().Address()` for the caller (see the
// demo realms in the gno repo, e.g. r/demo/defi/foo20).
//
// Rules enforced on-chain (fail-closed):
//   - a position needs a score >= MinScore (60)
//   - a stop-loss is required, on the correct side of entry
//   - a take-profit is required, on the correct side of entry
//   - per-trade size capped at MaxPositionCents ($50 paper)
//   - at most MaxOpenPositions open at once
//   - cumulative realised paper loss capped at DailyLossCapCents ($20);
//     once breached, no new positions open until the owner resets it
//   - writes (open / close / score / halt) are owner-only: only the
//     deployer key (the agent) may write. Reads are public.
//
// Ownership: the deployer calls ClaimOwner() once, right after deploy
// (init cannot see the deployer). Until claimed, all writes are blocked.
package taverntrader

import "strconv"

// ---------------------------------------------------------------------------
// Constants — the risk policy, visible on-chain.
// ---------------------------------------------------------------------------

const (
	// MinScore is the minimum agent score (0-100) a trade needs.
	MinScore = 60
	// MaxPositionCents caps one paper trade at $50.00.
	MaxPositionCents = 5000
	// DailyLossCapCents caps cumulative realised paper loss at $20.00.
	DailyLossCapCents = 2000
	// MaxOpenPositions caps concurrent open paper positions.
	MaxOpenPositions = 5
)

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// Position is one paper trade. Status is "open" or "closed".
type Position struct {
	ID         int
	Symbol     string
	Side       string // "long" or "short"
	SizeCents  int64
	EntryPrice int64 // micro-USD
	StopLoss   int64 // micro-USD, required
	TakeProfit int64 // micro-USD, required
	Score      int
	Status     string
	Reason     string
	ClosePrice int64 // micro-USD, 0 while open
	PnLCents   int64 // realised paper P&L in cents, 0 while open
	Seq        int   // monotonic sequence number (ordering, no clock on-chain)
}

// Score is one agent scoring event, kept with its reason.
type Score struct {
	Symbol string
	Score  int
	Reason string
	Seq    int
}

// Decision is the append-only on-chain decision log.
type Decision struct {
	Kind   string // "open", "close", "score", "halt", "resume", "reset-loss", "claim"
	Detail string
	Seq    int
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

var (
	owner            address
	nextID           int
	seq              int
	positions        []Position
	scores           []Score
	decisions        []Decision
	realizedPnLCents int64
	halted           bool
	haltReason       string
)

func init() {
	nextID = 1
	seq = 1
	positions = []Position{}
	scores = []Score{}
	decisions = []Decision{}
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

func assertOwner(cur realm) {
	if owner == "" {
		panic("taverntrader: owner not claimed yet — deployer must call ClaimOwner first")
	}
	if cur.Previous().Address() != owner {
		panic("taverntrader: caller is not the owner")
	}
}

func nextSeq() int {
	s := seq
	seq++
	return s
}

func logDecision(kind, detail string) {
	decisions = append(decisions, Decision{Kind: kind, Detail: detail, Seq: nextSeq()})
}

func findPosition(id int) int {
	for i, p := range positions {
		if p.ID == id {
			return i
		}
	}
	return -1
}

func openCount() int {
	n := 0
	for _, p := range positions {
		if p.Status == "open" {
			n++
		}
	}
	return n
}

// validateTrade enforces the on-chain risk policy. It panics (fail-closed)
// on the first broken rule, before any state changes.
func validateTrade(symbol, side string, sizeCents, entryPrice, stopLoss, takeProfit int64, score int) {
	if symbol == "" {
		panic("taverntrader: symbol required")
	}
	if side != "long" && side != "short" {
		panic("taverntrader: side must be long or short")
	}
	if score < MinScore {
		panic("taverntrader: score below threshold")
	}
	if entryPrice <= 0 {
		panic("taverntrader: entry price must be positive")
	}
	if stopLoss <= 0 {
		panic("taverntrader: stop-loss required")
	}
	if takeProfit <= 0 {
		panic("taverntrader: take-profit required")
	}
	if side == "long" && stopLoss >= entryPrice {
		panic("taverntrader: long stop-loss must be below entry")
	}
	if side == "short" && stopLoss <= entryPrice {
		panic("taverntrader: short stop-loss must be above entry")
	}
	if side == "long" && takeProfit <= entryPrice {
		panic("taverntrader: long take-profit must be above entry")
	}
	if side == "short" && takeProfit >= entryPrice {
		panic("taverntrader: short take-profit must be below entry")
	}
	if sizeCents <= 0 {
		panic("taverntrader: size must be positive")
	}
	if sizeCents > MaxPositionCents {
		panic("taverntrader: size above per-trade cap")
	}
	if halted {
		panic("taverntrader: trading halted: " + haltReason)
	}
	if openCount() >= MaxOpenPositions {
		panic("taverntrader: too many open positions")
	}
	if realizedPnLCents < -DailyLossCapCents {
		panic("taverntrader: cumulative realised loss cap breached")
	}
}

// openPosition is the state-changing core, shared by the exported
// OpenPaperPosition and the tests.
func openPosition(symbol, side string, sizeCents, entryPrice, stopLoss, takeProfit int64, score int, reason string) int {
	validateTrade(symbol, side, sizeCents, entryPrice, stopLoss, takeProfit, score)
	id := nextID
	nextID++
	positions = append(positions, Position{
		ID: id, Symbol: symbol, Side: side, SizeCents: sizeCents,
		EntryPrice: entryPrice, StopLoss: stopLoss, TakeProfit: takeProfit,
		Score: score, Status: "open", Reason: reason, Seq: nextSeq(),
	})
	logDecision("open", symbol+" "+side+" #"+strconv.Itoa(id)+" score="+strconv.Itoa(score)+" "+reason)
	return id
}

// closePosition settles one open position at closePrice. Returns paper P&L in cents.
func closePosition(id int, closePrice int64, reason string) int64 {
	if closePrice <= 0 {
		panic("taverntrader: close price must be positive")
	}
	i := findPosition(id)
	if i < 0 {
		panic("taverntrader: unknown position")
	}
	if positions[i].Status != "open" {
		panic("taverntrader: position already closed")
	}
	p := &positions[i]
	var pnl int64
	if p.Side == "long" {
		pnl = p.SizeCents * (closePrice - p.EntryPrice) / p.EntryPrice
	} else {
		pnl = p.SizeCents * (p.EntryPrice - closePrice) / p.EntryPrice
	}
	p.Status = "closed"
	p.ClosePrice = closePrice
	p.PnLCents = pnl
	realizedPnLCents += pnl
	logDecision("close", p.Symbol+" "+p.Side+" #"+strconv.Itoa(id)+" pnl="+strconv.FormatInt(pnl, 10)+"c "+reason)
	return pnl
}

// ---------------------------------------------------------------------------
// Writes — owner-only (the agent key).
// ---------------------------------------------------------------------------

// ClaimOwner claims ownership for the caller. Callable exactly once, while
// owner is unset — the deployer calls it right after addpkg.
func ClaimOwner(cur realm) {
	if owner != "" {
		panic("taverntrader: owner already claimed")
	}
	owner = cur.Previous().Address()
	logDecision("claim", "owner claimed: "+string(owner))
}

// OpenPaperPosition opens a paper position. Returns the position id.
func OpenPaperPosition(cur realm, symbol, side string, sizeCents, entryPrice, stopLoss, takeProfit int64, score int, reason string) int {
	validateTrade(symbol, side, sizeCents, entryPrice, stopLoss, takeProfit, score)
	assertOwner(cur)
	return openPosition(symbol, side, sizeCents, entryPrice, stopLoss, takeProfit, score, reason)
}

// ClosePaperPosition closes an open paper position at closePrice.
// Returns realised paper P&L in USD cents.
func ClosePaperPosition(cur realm, id int, closePrice int64, reason string) int64 {
	assertOwner(cur)
	return closePosition(id, closePrice, reason)
}

// RecordScore stores one agent scoring event with its reason.
func RecordScore(cur realm, symbol string, score int, reason string) {
	assertOwner(cur)
	if symbol == "" {
		panic("taverntrader: symbol required")
	}
	if score < 0 || score > 100 {
		panic("taverntrader: score must be 0-100")
	}
	scores = append(scores, Score{Symbol: symbol, Score: score, Reason: reason, Seq: nextSeq()})
	logDecision("score", symbol+" score="+strconv.Itoa(score)+" "+reason)
}

// HaltPaperTrading stops new positions until ResumePaperTrading is called.
func HaltPaperTrading(cur realm, reason string) {
	assertOwner(cur)
	halted = true
	haltReason = reason
	logDecision("halt", reason)
}

// ResumePaperTrading lifts a halt.
func ResumePaperTrading(cur realm) {
	assertOwner(cur)
	halted = false
	haltReason = ""
	logDecision("resume", "trading resumed by owner")
}

// ResetLossCap resets the cumulative realised paper P&L to zero.
// Owner-only, and journaled — it is a deliberate reset, not a silent one.
func ResetLossCap(cur realm, reason string) {
	assertOwner(cur)
	realizedPnLCents = 0
	logDecision("reset-loss", reason)
}

// ---------------------------------------------------------------------------
// Reads — public.
// ---------------------------------------------------------------------------

// GetOwner returns the owner address ("" until ClaimOwner is called).
func GetOwner() address {
	return owner
}

// GetPosition returns one position as a readable line, or "" if unknown.
func GetPosition(id int) string {
	i := findPosition(id)
	if i < 0 {
		return ""
	}
	return formatPosition(positions[i])
}

// GetPositions returns all positions, one per line.
func GetPositions() string {
	out := ""
	for _, p := range positions {
		out += formatPosition(p) + "\n"
	}
	return out
}

// GetOpenPositions returns only open positions, one per line.
func GetOpenPositions() string {
	out := ""
	for _, p := range positions {
		if p.Status == "open" {
			out += formatPosition(p) + "\n"
		}
	}
	return out
}

// GetScores returns scoring events for a symbol, one per line.
func GetScores(symbol string) string {
	out := ""
	for _, s := range scores {
		if s.Symbol == symbol {
			out += symbol + " score=" + strconv.Itoa(s.Score) + " " + s.Reason + "\n"
		}
	}
	return out
}

// GetDecisions returns the on-chain decision log, one per line.
func GetDecisions() string {
	out := ""
	for _, d := range decisions {
		out += strconv.Itoa(d.Seq) + " [" + d.Kind + "] " + d.Detail + "\n"
	}
	return out
}

// GetStats returns a one-line summary: open count, realised P&L (cents), halted.
func GetStats() string {
	return "open=" + strconv.Itoa(openCount()) +
		" positions=" + strconv.Itoa(len(positions)) +
		" realisedPnLCents=" + strconv.FormatInt(realizedPnLCents, 10) +
		" halted=" + strconv.FormatBool(halted)
}

// GetRealizedPnLCents returns cumulative realised paper P&L in USD cents.
func GetRealizedPnLCents() int64 {
	return realizedPnLCents
}

func formatPosition(p Position) string {
	s := "#" + strconv.Itoa(p.ID) + " " + p.Symbol + " " + p.Side +
		" size=" + strconv.FormatInt(p.SizeCents, 10) + "c" +
		" entry=" + strconv.FormatInt(p.EntryPrice, 10) +
		" sl=" + strconv.FormatInt(p.StopLoss, 10) +
		" tp=" + strconv.FormatInt(p.TakeProfit, 10) +
		" score=" + strconv.Itoa(p.Score) +
		" status=" + p.Status +
		" reason=" + p.Reason
	if p.Status == "closed" {
		s += " close=" + strconv.FormatInt(p.ClosePrice, 10) +
			" pnl=" + strconv.FormatInt(p.PnLCents, 10) + "c"
	}
	return s
}

// Render renders the realm page.
func Render(path string) string {
	out := "# Tavern Trader — paper trading on Gno.land\n\n"
	out += "PAPER ONLY. No real funds move here — positions are state only, settled in paper USD.\n\n"
	out += "## Stats\n\n" + GetStats() + "\n\n"
	out += "## Open positions\n\n" + GetOpenPositions() + "\n"
	out += "## All positions\n\n" + GetPositions() + "\n"
	out += "## Decision log\n\n" + GetDecisions()
	return out
}

