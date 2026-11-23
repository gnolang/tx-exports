package cutpurse

import "strconv"

// FROZEN CONTRACT (SPEC §9). The designer consumes these shapes and may not
// touch globals or maps. Widening a struct is builder-only and needs a SPEC
// amendment.

type JobView struct {
	ID        int64
	Name      string
	Creator   address
	Fee       int64
	Pot       int64
	Loot      int64
	Secured   int64
	Alarm     int64
	Phase     uint8
	Round     uint8
	Deadline  int64
	Height    int64
	NSeats    uint8
	Revealed  bool
	Traitor   int8
	OpenedAt  int64
	SettledAt int64
	Settled   bool
	Seats     []SeatView
}

type SeatView struct {
	Addr         address
	Committed    bool
	Revealed     bool
	Auto         bool
	Action       uint8
	Contribution int64
}

// jobView renders one job; Traitor is -1 until the snitch is public.
func jobView(id int64) (JobView, bool) {
	j, ok := jobs[id]
	if !ok {
		return JobView{}, false
	}

	v := JobView{
		ID:        j.ID,
		Name:      j.Name,
		Creator:   j.Creator,
		Fee:       j.Fee,
		Pot:       j.Pot,
		Loot:      j.Loot,
		Secured:   j.Secured,
		Alarm:     j.Alarm,
		Phase:     uint8(j.Phase),
		Round:     j.Round,
		Deadline:  j.Deadline,
		Height:    mustHeight(),
		NSeats:    j.NSeats,
		Revealed:  j.Revealed,
		Traitor:   -1,
		OpenedAt:  j.OpenedAt,
		SettledAt: j.SettledAt,
		Settled:   j.SettledAt != 0,
		Seats:     make([]SeatView, 0, int(j.NSeats)),
	}
	if j.Revealed {
		v.Traitor = j.Traitor
	}
	for i := 0; i < int(j.NSeats); i++ {
		s := j.Seats[i]
		v.Seats = append(v.Seats, SeatView{
			Addr:         s.Addr,
			Committed:    s.Committed,
			Revealed:     s.Action != ActNone,
			Auto:         s.Auto,
			Action:       uint8(s.Action),
			Contribution: s.Contribution,
		})
	}
	return v, true
}

// jobList returns up to limit views, newest first. phase > PhaseBusted means
// "any phase".
func jobList(phase uint8, limit int) []JobView {
	if limit < 1 {
		limit = 1
	}
	if limit > MaxListLimit {
		limit = MaxListLimit
	}

	out := make([]JobView, 0, limit)
	id := nextID - 1
	for scanned := 0; id >= 0 && len(out) < limit && scanned < LedgerMax; scanned++ {
		if v, ok := jobView(id); ok {
			if phase > uint8(PhaseBusted) || v.Phase == phase {
				out = append(out, v)
			}
		}
		id--
	}
	return out
}

// ledgerPage returns one ledger page, newest entry first.
func ledgerPage(n, size int) []Result {
	if size < 1 {
		size = 10
	}
	if size > MaxListLimit {
		size = MaxListLimit
	}
	if n < 0 {
		n = 0
	}

	out := make([]Result, 0, size)
	start := n * size
	for k := start; k < start+size && k < ledgerLen; k++ {
		idx := (ledgerHead - 1 - k + LedgerMax*2) % LedgerMax
		if r := ledger[idx]; r != nil {
			out = append(out, *r)
		}
	}
	return out
}

func statsOf(a address) (jobs, escapes, busts, loot int64) {
	s, ok := stats[a.String()]
	if !ok {
		return 0, 0, 0, 0
	}
	return s.Jobs, s.Escapes, s.Busts, s.Loot
}

// JobCount is the number of jobs ever created.
func JobCount() int64 { return nextID }

// JobViewOf / JobListOf / LedgerPageOf / StatsOfAddress are exported doors on
// the unexported contract helpers so out-of-package tests can assert on state
// without touching globals.
func JobViewOf(id int64) (JobView, bool) { return jobView(id) }

func JobListOf(phase uint8, limit int) []JobView { return jobList(phase, limit) }

func LedgerPageOf(n, size int) []Result { return ledgerPage(n, size) }

func StatsOfAddress(a address) (jobs, escapes, busts, loot int64) { return statsOf(a) }

// StatsOf is statsOf keyed by bech32 string (path input, no parser needed).
func StatsOf(a string) (jobs, escapes, busts, loot int64) {
	s, ok := stats[a]
	if !ok {
		return 0, 0, 0, 0
	}
	return s.Jobs, s.Escapes, s.Busts, s.Loot
}

// Name returns the stored (already sanitized) job name, or "".
func Name(id int64) string {
	if j, ok := jobs[id]; ok {
		return j.Name
	}
	return ""
}

// Treasury is the accrued 5% house cut, in ugnot.
func Treasury() int64 { return treasury }

// treasuryTotal is the designer's spelling for the same number.
func TreasuryTotal() int64 { return treasury }

// commitSalt is a round-stable, per-seat nonce the commit page shows. It is
// derived from OpenedAt (immutable for the life of the job) and Round, so the
// same value comes back at reveal time even though Deadline moves.
func saltFor(id int64, round uint8, who string) string {
	openedAt := int64(0)
	if j, ok := jobs[id]; ok {
		openedAt = j.OpenedAt
	}
	return sha256Hex("cutpurse|" +
		strconv.FormatInt(id, 10) + "|" +
		strconv.FormatUint(uint64(round), 10) + "|" +
		strconv.FormatInt(openedAt, 10) + "|" +
		who)
}

// CommitSalt is the exported door for out-of-package callers.
func CommitSalt(id int64, round uint8, who string) string { return saltFor(id, round, who) }

// LedgerLen is the number of archived results.
func LedgerLen() int64 { return int64(ledgerLen) }

// Archived returns the permanent ledger entry for a settled job.
func Archived(id int64) (Result, bool) {
	for k := 0; k < ledgerLen; k++ {
		idx := (ledgerHead - 1 - k + LedgerMax*2) % LedgerMax
		if r := ledger[idx]; r != nil && r.JobID == id {
			return *r, true
		}
	}
	return Result{}, false
}

// HistMax caps how much per-wallet history is kept. 40 is well past what a
// profile shows and small enough that the map stays cheap.
const HistMax = 40

// pushHist prepends a result to a wallet's history, newest first, capped.
func pushHist(a address, r Result) {
	if hist == nil {
		hist = make(map[address][]Result)
	}
	h := hist[a]
	if len(h) >= HistMax {
		h = h[:HistMax-1]
	}
	h = append(h, Result{})
	copy(h[1:], h[:len(h)-1])
	h[0] = r
	hist[a] = h
}

// resultsOf answers "this wallet's jobs", newest first, capped by limit.
// One map read instead of a ledger-ring walk: the walk cost ~660k gas per
// entry scanned and a full-ring miss blew past 100M (§10 R10).
func resultsOf(a address, limit int) []Result {
	if limit <= 0 {
		return nil
	}
	h := hist[a]
	if len(h) > limit {
		h = h[:limit]
	}
	out := make([]Result, len(h))
	copy(out, h)
	return out
}

// ResultsOf is the exported door for out-of-package callers.
func ResultsOf(a address, limit int) []Result { return resultsOf(a, limit) }
