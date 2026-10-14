// Package decisions is the ledger every bridge realm keeps of GovDAO's decisions (bridge/PLAN.md §5.3): a decision
// is born when a proposal made with one of the realm's builders executes, gets the next number, and is either
// applied at once or queued for 7 days of block time; anyone applies a queued one after its delay, and GovDAO can
// cancel it in between. The ledger keeps no closure and no proposal text: the parameters a builder wrote are the
// record. The realm decides what a decision does; this package keeps the numbers, the clocks and the page.
package decisions

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	// Day is a day of block time, in seconds.
	Day = int64(86400)
	// Factor divides every delay of the realms — Delay, Deadline, and the old router's 7 days after a swap, which
	// is Delay (§5.9): 1 for the mainnet build, which §8.3's check reads in the served source; the devnet build
	// is deployed with 8 here, so its 14 days pass in 42 hours, as the Solana programs' clock-factor-8 feature
	// does. A compiled constant beside the launch values, shown on every realm's page. The meters (§5.4) are
	// rates per real day and are not divided.
	Factor = int64(1)
	// Delay is the wait a raise, a swap, a credit, a migration or a sweep payment takes after its proposal
	// executes (§5.3: 7 days by block time), divided by Factor.
	Delay = 7 * Day / Factor
	// Deadline is how old a proposal may be when it executes; past it the closure returns an error and GovDAO
	// marks the proposal denied for good (§5.3: 14 days), divided by Factor.
	Deadline = 14 * Day / Factor
	// PageMax is how many decisions of one kind and state the page shows.
	PageMax = 100
	// DAOPath is the realm whose frame every builder's closure must be called from, once the governor has yielded
	// (or from the first block, when none was compiled): the proxy that executes GovDAO's proposals.
	DAOPath = "gno.land/r/gov/dao"
)

// ------------------------------------------------------------- governor --

// The governor (M1k, Jae 2026-10-14: "until I yield to GovDAO I want to be GovDAO alone"). Each bridge realm
// compiles a governor address beside its other launch values; while one is compiled and has not yielded, a
// decision is the governor's own direct call through the realm's Govern — the same closure, checks, queues and
// delays a proposal's execution runs, only who decides differs — and GovDAO's proposals are refused. The yield is
// one call on hlmailbox (Yield), which every realm reads, so no realm is ever governed apart from the others; from
// that block DAOPath's proxy is the only governor, as before M1k. A compiled governor of "" means GovDAO from the
// first block. This package keeps the rule and the page line; the realms keep the identity checks, since an
// identity is read from a live cur alone.

// DAOGoverns is whether DAOPath's proxy decides now: no governor was compiled, or the governor yielded at that
// block height (0 until the yield).
func DAOGoverns(governor address, yielded int64) bool { return governor == "" || yielded != 0 }

// GovernorLine is the line every bridge realm's page shows of who governs it.
func GovernorLine(governor address, yielded int64) string {
	switch {
	case governor == "":
		return "governor: " + DAOPath + " from the first block (no governor was compiled)"
	case yielded == 0:
		return "governor: " + string(governor) + " (until the yield) — it alone decides, by Govern from its own key, and " + DAOPath + "'s proposals are refused"
	}
	return "governor: " + DAOPath + " since height " + itoa(yielded) + " (" + string(governor) + " yielded)"
}

// GovernorJSON is the same for the agents: `"governor":"…","yielded":H` (no leading or trailing comma).
func GovernorJSON(governor address, yielded int64) string {
	return "\"governor\":" + strconv.Quote(string(governor)) + ",\"yielded\":" + itoa(yielded)
}

// Decision is one numbered change, as the realm's page shows it.
type Decision struct {
	ID        int64
	Kind      string // the builder's name, e.g. "set cap floor"
	Text      string // the parameters, as the builder wrote them into the proposal's description
	Params    any    // the parameters, typed, the realm's own
	Made      int64  // unix time the proposal was made (the builder call)
	Recorded  int64  // unix time the proposal executed: the decision's birth
	Due       int64  // unix time it may be applied: Recorded for an at-once change, Recorded + Delay for a queued one
	Applied   int64  // unix time it was applied; 0 while pending
	Cancelled int64  // unix time GovDAO cancelled it; 0 if it was not
	Spent     bool   // recorded with no effect (an unpause that would have cleared nothing)
	Note      string // what happened at execution, in words
}

// Pending is whether the decision still waits to be applied.
func (d *Decision) Pending() bool { return d.Applied == 0 && d.Cancelled == 0 && !d.Spent }

// Queued is whether the decision waits on its delay (pending, and not due at once).
func (d *Decision) Queued() bool { return d.Pending() && d.Due > d.Recorded }

// State is "pending", "applied", "cancelled" or "spent".
func (d *Decision) State() string {
	switch {
	case d.Cancelled != 0:
		return "cancelled"
	case d.Spent:
		return "spent"
	case d.Applied != 0:
		return "applied"
	}
	return "pending"
}

// Ledger numbers and keeps a realm's decisions. The zero value is empty.
type Ledger struct {
	seq int64
	all avl.Tree // key(id) → *Decision
}

func key(id int64) string {
	s := strconv.FormatInt(id, 10)
	return strings.Repeat("0", 12-len(s)) + s
}

// Record gives a decision the next number and keeps it. due is when it may be applied (now for at once).
func (l *Ledger) Record(kind, text string, params any, made, now, due int64) *Decision {
	l.seq++
	d := &Decision{ID: l.seq, Kind: kind, Text: text, Params: params, Made: made, Recorded: now, Due: due}
	l.all.Set(key(d.ID), d)
	return d
}

// Get is the decision with this number, or nil.
func (l *Ledger) Get(id int64) *Decision {
	v := l.all.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*Decision)
}

// Last is the number of the newest decision (0 if none).
func (l *Ledger) Last() int64 { return l.seq }

// Size is how many decisions were ever recorded.
func (l *Ledger) Size() int { return l.all.Size() }

// Apply marks a decision applied now, with a note.
func (l *Ledger) Apply(d *Decision, now int64, note string) {
	d.Applied = now
	if note != "" {
		d.Note = note
	}
}

// Spend marks a decision spent: recorded, no effect.
func (l *Ledger) Spend(d *Decision, note string) {
	d.Spent = true
	d.Note = note
}

// Cancel marks a pending decision cancelled now. It errors on a number that is not pending.
func (l *Ledger) Cancel(id, now int64) (*Decision, error) {
	d := l.Get(id)
	if d == nil {
		return nil, errors.New("no decision " + strconv.FormatInt(id, 10))
	}
	if !d.Pending() {
		return nil, errors.New("decision " + strconv.FormatInt(id, 10) + " is " + d.State() + ", not pending")
	}
	d.Cancelled = now
	return d, nil
}

// Due is a pending decision whose delay has passed, by number; it errors otherwise.
func (l *Ledger) Due(id, now int64) (*Decision, error) {
	d := l.Get(id)
	if d == nil {
		return nil, errors.New("no decision " + strconv.FormatInt(id, 10))
	}
	if !d.Pending() {
		return nil, errors.New("decision " + strconv.FormatInt(id, 10) + " is " + d.State() + ", not pending")
	}
	if now < d.Due {
		return nil, errors.New("decision " + strconv.FormatInt(id, 10) + " is due at " + strconv.FormatInt(d.Due, 10) + ", not before")
	}
	return d, nil
}

// Each walks every decision, oldest first, until fn returns true.
func (l *Ledger) Each(fn func(d *Decision) bool) {
	l.all.Iterate("", "", func(_ string, v any) bool { return fn(v.(*Decision)) })
}

// Expired is the one error a builder's closure returns: the proposal was made more than Deadline ago, so GovDAO
// marks it denied for good. Everything else a closure refuses is a panic, which leaves the proposal for a retry.
func Expired(made, now int64) error {
	if now-made > Deadline {
		return errors.New("the proposal is past its 14-day deadline (made at " + strconv.FormatInt(made, 10) + ", now " + strconv.FormatInt(now, 10) + ")")
	}
	return nil
}

// ---------------------------------------------------------------- pages --

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// Clocks says the clock factor and the delays it gives, for every realm's page: §8.3's check reads it against
// the served source, where the mainnet build's factor is 1.
func Clocks() string {
	return "clock factor " + itoa(Factor) + " (1 on mainnet; a devnet build is compiled with 8): the 7-day delay is " + itoa(Delay) +
		" s and the 14-day deadline " + itoa(Deadline) + " s of block time"
}

// ClocksJSON is the same for the agents: {"factor":…,"delay":…,"deadline":…}.
func ClocksJSON() string {
	return "{\"factor\":" + itoa(Factor) + ",\"delay\":" + itoa(Delay) + ",\"deadline\":" + itoa(Deadline) + "}"
}

// Page is the decisions page: for every kind, the pending decisions (up to PageMax) and the last PageMax executed
// ones, newest first.
func (l *Ledger) Page() string {
	if l.all.Size() == 0 {
		return "No decision yet: one exists only when a proposal made with a builder executes.\n"
	}
	kinds := []string{}
	pending := map[string][]*Decision{}
	done := map[string][]*Decision{}
	l.all.ReverseIterate("", "", func(_ string, v any) bool {
		d := v.(*Decision)
		if _, ok := pending[d.Kind]; !ok {
			kinds = append(kinds, d.Kind)
			pending[d.Kind] = nil
			done[d.Kind] = nil
		}
		if d.Pending() {
			if len(pending[d.Kind]) < PageMax {
				pending[d.Kind] = append(pending[d.Kind], d)
			}
		} else if len(done[d.Kind]) < PageMax {
			done[d.Kind] = append(done[d.Kind], d)
		}
		return false
	})
	var b strings.Builder
	for _, k := range kinds {
		b.WriteString("### " + k + "\n\n")
		if len(pending[k]) == 0 {
			b.WriteString("pending: none\n")
		} else {
			b.WriteString("pending:\n")
			for _, d := range pending[k] {
				b.WriteString("- " + line(d) + "\n")
			}
		}
		if len(done[k]) > 0 {
			b.WriteString("\nexecuted:\n")
			for _, d := range done[k] {
				b.WriteString("- " + line(d) + "\n")
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

func line(d *Decision) string {
	s := "#" + itoa(d.ID) + " " + d.State() + ": " + d.Text + " (recorded " + itoa(d.Recorded)
	if d.Queued() {
		s += ", due " + itoa(d.Due)
	}
	switch {
	case d.Applied != 0:
		s += ", applied " + itoa(d.Applied)
	case d.Cancelled != 0:
		s += ", cancelled " + itoa(d.Cancelled)
	}
	s += ")"
	if d.Note != "" {
		s += " — " + d.Note
	}
	return s
}

// JSON is every decision, oldest first, as a JSON array.
func (l *Ledger) JSON() string {
	var b strings.Builder
	b.WriteString("[")
	first := true
	l.all.Iterate("", "", func(_ string, v any) bool {
		d := v.(*Decision)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString("{\"id\":" + itoa(d.ID) + ",\"kind\":" + strconv.Quote(d.Kind) + ",\"text\":" + strconv.Quote(d.Text) +
			",\"state\":" + strconv.Quote(d.State()) + ",\"made\":" + itoa(d.Made) + ",\"recorded\":" + itoa(d.Recorded) +
			",\"due\":" + itoa(d.Due) + ",\"applied\":" + itoa(d.Applied) + ",\"cancelled\":" + itoa(d.Cancelled) +
			",\"note\":" + strconv.Quote(d.Note) + "}")
		return false
	})
	b.WriteString("]")
	return b.String()
}
