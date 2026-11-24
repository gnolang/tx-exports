package mandate

import (
	"strconv"
	"strings"
	"time"
)

// Free reads. Each returns plain values (copies), never pointers into the
// realm's state, so callers and vm/qeval cannot change anything.

// PlanInfo is a copy of a plan.
type PlanInfo struct {
	ID        uint64
	Payee     address
	Title     string
	Amount    int64
	Period    int64
	CreatedAt int64
	Mandates  int // mandates ever created for this plan
	Cancelled int // how many of them were cancelled
	// PaidThisPeriod and PaidLastPeriod count the payments in the plan's
	// current period window, which started at PeriodStart, and in the window
	// before it. Windows are [k*Period, (k+1)*Period) in unix time. They count
	// payments, not distinct people (a creator can pay its own plan from a
	// second wallet). Historical facts, true at any time, whatever has
	// expired or been cancelled since.
	PaidThisPeriod int
	PaidLastPeriod int
	PeriodStart    int64
	Pulls          int64
	Paid           int64
	LastPullAt     int64
}

// MandateInfo is a copy of a mandate with the realm's view of it.
type MandateInfo struct {
	ID            uint64
	PlanID        uint64
	Payer         address
	Payee         address
	Session       address
	SessionPubKey string
	Amount        int64
	Period        int64
	CreatedAt     int64
	ExpiresAt     int64
	NextPullAt    int64
	LastPullAt    int64
	// PaidThrough is until when this mandate's payments, or paid time
	// carried over from the payer's earlier mandate for the plan, cover the
	// payer (0 if neither). A mandate that starts with carried time has its
	// first pull at that time.
	PaidThrough int64
	Pulls       int64
	Paid        int64
	CancelledAt int64
	CancelledBy address
	// Status is "active", "expired" or "cancelled": the realm's view only.
	Status string
	// Due is true when the mandate is active and a pull is allowed now.
	Due bool
	// SessionPubKey is the session key's public key when it is the payee's
	// current collector key, "" otherwise.
	//
	// SessionQuery is the free query an off-chain checker must also run:
	// the realm cannot see a session revoked or expired on chain.
	SessionQuery string
}

// PayeeInfo is a copy of a payee's totals and collector key.
type PayeeInfo struct {
	Addr          address
	Plans         int
	Pulls         int64
	Paid          int64
	LastPullAt    int64
	CollectorKey  string
	CollectorAddr address
	// CollectorFunded is true when the collector key's address holds coins:
	// the chain then refuses every new session for that key, so nobody can
	// subscribe until the creator publishes a new key. (An address that
	// received coins and was emptied is also refused by the chain; only the
	// free query auth/accounts/<CollectorAddr> shows that.)
	CollectorFunded bool
}

// GetPlan returns the plan with this id.
func GetPlan(id uint64) (PlanInfo, bool) {
	p := planOf(id)
	if p == nil {
		return PlanInfo{}, false
	}
	return p.info(), true
}

// MandateOf returns the latest mandate of payer for this session address.
func MandateOf(payer, sessionAddr address) (MandateInfo, bool) {
	m := latestBySession(payer, sessionAddr)
	if m == nil {
		return MandateInfo{}, false
	}
	return m.info(time.Now().Unix()), true
}

// PaidThrough is the read for services that deliver something to paying
// supporters. It returns the unix time until which the payer's payments for
// the plan cover them: the latest payment's time plus one period. Paid time
// stays the payer's when a mandate is cancelled (by either side) or
// expires, and a new mandate for the same plan starts when it ends, so it
// is not charged twice. The one exception: a payer who already holds 16
// kept periods (MaxCreditsPerPayer). 0 when they never paid for the plan.
// Deliver while now < PaidThrough.
//
// It turns false at the due time and moves on only when the payee's
// collector pulls the next payment: allow a grace equal to how often the
// collector runs (an hour, say) before treating a supporter as lapsed.
//
// A payment is proof; a mandate is not: anyone can record a mandate
// without creating a session and without paying. A realm also cannot see a
// session revoked on chain: a revoked supporter simply stops paying, so
// PaidThrough stops moving and runs out within one period.
func PaidThrough(payer address, planID uint64) int64 {
	pr := payerOf(payer)
	if pr == nil {
		return 0
	}
	now := time.Now().Unix()
	until := pr.creditFor(planID, now)
	for _, r := range pr.Active {
		if r.PlanID == planID {
			if t := r.M.paidThrough(); t > until {
				until = t
			}
		}
	}
	return until
}

// IsPaidUp reports whether payer's latest payment for the plan still covers
// now (now < PaidThrough). See PaidThrough.
func IsPaidUp(payer address, planID uint64) bool {
	return time.Now().Unix() < PaidThrough(payer, planID)
}

// HasMandate reports whether payer has a mandate for the plan that is
// neither cancelled nor expired in the realm. It says nothing about payment
// (a mandate costs only a storage deposit to record) and cannot see a
// session revoked on chain: do not grant anything on it; use PaidThrough.
func HasMandate(payer address, planID uint64) bool {
	m := activeByPlan(payer, planID)
	return m != nil && m.isActive(time.Now().Unix())
}

// NextPullAt returns when the next pull of payer's active mandate for the
// plan is allowed (unix seconds), or 0 if there is no active mandate.
func NextPullAt(payer address, planID uint64) int64 {
	m := activeByPlan(payer, planID)
	if m == nil || !m.isActive(time.Now().Unix()) {
		return 0
	}
	return m.NextPullAt
}

// GetPayee returns a payee's totals and collector key.
func GetPayee(payee address) (PayeeInfo, bool) {
	pe := payeeOf(payee)
	if pe == nil {
		return PayeeInfo{}, false
	}
	return PayeeInfo{
		Addr:            pe.Addr,
		Plans:           pe.Plans,
		Pulls:           pe.Pulls,
		Paid:            pe.Paid,
		LastPullAt:      pe.LastPullAt,
		CollectorKey:    pe.CollectorKey,
		CollectorAddr:   pe.CollectorAddr,
		CollectorFunded: pe.CollectorKey != "" && collectorFunded(pe.CollectorAddr),
	}, true
}

// Totals returns the number of plans and mandates, and all pulls so far.
func Totals() (plansCount, mandatesCount int, pulls, paid int64) {
	return plans.Size(), int(nextMandateID), totalPulls, totalPaid
}

// Plans lists all plans, newest first, PageSize per page (page 1 first).
func Plans(page int) []PlanInfo {
	out := []PlanInfo{}
	plans.ReverseIterateByOffset(offset(page), PageSize, func(_ string, v any) bool {
		out = append(out, v.(*Plan).info())
		return false
	})
	return out
}

// PlansOf lists a payee's plans, oldest first.
func PlansOf(payee address, page int) []PlanInfo {
	out := []PlanInfo{}
	plans, _ := payeePlans(payee, page)
	for _, p := range plans {
		out = append(out, p.info())
	}
	return out
}

// payeePlans returns page `page` of a payee's plans and whether more follow.
func payeePlans(payee address, page int) ([]*Plan, bool) {
	pe := payeeOf(payee)
	if pe == nil {
		return nil, false
	}
	lo, hi, more := pageBounds(pe.planIDs.N, page)
	out := make([]*Plan, 0, hi-lo)
	for i := lo; i < hi; i++ {
		id, _ := strconv.ParseUint(pe.planIDs.at(i), 10, 64)
		out = append(out, planOf(id))
	}
	return out, more
}

// MandatesOf lists a payer's mandates (all states), newest first.
func MandatesOf(payer address, page int) []MandateInfo {
	list, _ := payerPage(payer, page)
	return infos(list)
}

// payerPage returns page `page` of the payer's mandates, newest first, and
// whether another page follows. It walks the payer's history, which only
// free reads do.
func payerPage(payer address, page int) ([]*Mandate, bool) {
	skip := offset(page)
	out := []*Mandate{}
	for m := payerHead(payer); m != nil; m = m.prevOfPayer {
		if skip > 0 {
			skip--
			continue
		}
		if len(out) == PageSize {
			return out, true
		}
		out = append(out, m)
	}
	return out, false
}

// SupportersOf lists a plan's active mandates (not cancelled, replaced or
// expired), oldest first. Page n covers entries (n-1)*PageSize to
// n*PageSize-1 of the plan's list, so a page may hold fewer rows than
// PageSize; inactive ones are on the payers' own pages.
func SupportersOf(planID uint64, page int) []MandateInfo {
	p := planOf(planID)
	if p == nil {
		return []MandateInfo{}
	}
	now := time.Now().Unix()
	out := []MandateInfo{}
	lo, hi, _ := pageBounds(p.Supporters.N, page)
	for i := lo; i < hi; i++ {
		e := decodeEntry(p.Supporters.at(i))
		if e.Status == statusCancelled {
			continue
		}
		if m := activeMandate(e); m != nil && m.isActive(now) {
			out = append(out, m.info(now))
		}
	}
	return out
}

// ScanLimit is the most supporter-list entries one free read resolves
// (looks up in its payer's record); WalkLimit is the most it reads at all.
// Entries carry their status, so cancelled ones, and for some reads unpaid
// ones, are skipped without a lookup. Reads that filter return a cursor to
// continue from, so junk can delay but never hide a real entry.
const (
	ScanLimit = 200
	WalkLimit = 1000
)

// CollectorPlans lists a payee's plans for a collector script, one per line:
//
//	<plan id> <amount ugnot> <period seconds> <mandates>
//
// PageSize per page; the last line is "more" or "end".
func CollectorPlans(payee address, page int) string {
	var b strings.Builder
	more := false
	if list, m := payeePlans(payee, page); list != nil {
		more = m
		for _, p := range list {
			b.WriteString(utoa(p.ID) + " " + itoa(p.Amount) + " " + itoa(p.Period) + " " + strconv.Itoa(p.Supporters.N) + "\n")
		}
	}
	if more {
		b.WriteString("more\n")
	} else {
		b.WriteString("end\n")
	}
	return b.String()
}

// CollectorScan walks at most ScanLimit entries of a plan's supporter list,
// from index `from` (0 = oldest), and returns the active mandates whose
// session key is sessionAddr, one per line:
//
//	<index> <mandate id> <payer> <amount ugnot> <next pull unix> <due|wait> <pulls> <paid>
//
// <paid> is 1 when the payer has paid for this plan (this mandate pulled, or
// it started with paid time carried over from an earlier one), 0 when it
// never has. The last line is "next <index>" when more entries follow,
// "end" otherwise. Cancelled and expired mandates, and mandates for other
// keys, are skipped here, so a collector never needs to read them. Anyone
// can record a mandate without a session, so a collector should check on
// chain that the session exists, at least before the first pull of a
// mandate whose payer never paid.
func CollectorScan(planID uint64, sessionAddr address, from int) string {
	p := planOf(planID)
	if p == nil {
		return "end\n"
	}
	if from < 0 {
		from = 0
	}
	if from > p.Supporters.N {
		from = p.Supporters.N // also keeps from+ScanLimit from overflowing
	}
	now := time.Now().Unix()
	var b strings.Builder
	end := from + ScanLimit
	if end > p.Supporters.N {
		end = p.Supporters.N
	}
	for i := from; i < end; i++ {
		e := decodeEntry(p.Supporters.at(i))
		if e.Status == statusCancelled {
			continue
		}
		pr := payerOf(e.Payer)
		if pr == nil {
			continue
		}
		var m *Mandate
		for _, r := range pr.Active {
			if r.ID == e.ID && r.Session == sessionAddr {
				m = r.M
			}
		}
		if m == nil || !m.isActive(now) {
			continue
		}
		due := "wait"
		if now >= m.NextPullAt {
			due = "due"
		}
		b.WriteString(strconv.Itoa(i) + " " + utoa(m.ID) + " " + m.Payer.String() + " " + itoa(p.Amount) + " " +
			itoa(m.NextPullAt) + " " + due + " " + itoa(m.Pulls) + " " + paidFlag(m) + "\n")
	}
	if end < p.Supporters.N {
		b.WriteString("next " + strconv.Itoa(end) + "\n")
	} else {
		b.WriteString("end\n")
	}
	return b.String()
}

// payingFrom lists a plan's supporters: mandates that have paid at least
// once and are active now, newest first, up to PageSize, starting at list
// index `from` (or the newest when from < 0). It reads at most WalkLimit
// entries and resolves at most ScanLimit of them (only entries marked paid
// are resolved), and returns the index to continue from (-1 when the list is
// exhausted).
func payingFrom(p *Plan, from int, now int64) ([]*Mandate, int) {
	if from < 0 || from >= p.Supporters.N {
		from = p.Supporters.N - 1
	}
	out := []*Mandate{}
	i, walked, resolved := from, 0, 0
	for ; i >= 0 && walked < WalkLimit && resolved < ScanLimit && len(out) < PageSize; i, walked = i-1, walked+1 {
		e := decodeEntry(p.Supporters.at(i))
		if e.Status != statusPaid {
			continue
		}
		resolved++
		if m := activeMandate(e); m != nil && m.isActive(now) {
			out = append(out, m)
		}
	}
	return out, i
}

// PayingSupporters lists a plan's supporters the way its gnoweb page does:
// mandates that have paid at least once and are active now, newest first,
// at most PageSize per call. Pass from = -1 for the newest; the second
// result is where to continue. A client must stop when it is -1 (the list
// is exhausted): -1 passed back in starts again from the newest, so a
// client that feeds the cursor back unchecked loops for ever. Each call
// walks at most WalkLimit entries and looks up at most ScanLimit of them,
// so a call may return fewer than PageSize (even none) and still a cursor.
func PayingSupporters(planID uint64, from int) ([]MandateInfo, int) {
	p := planOf(planID)
	if p == nil {
		return []MandateInfo{}, -1
	}
	now := time.Now().Unix()
	list, next := payingFrom(p, from, now)
	out := make([]MandateInfo, 0, len(list))
	for _, m := range list {
		out = append(out, m.info(now))
	}
	return out, next
}

// PlanCounts returns the numbers the gnoweb plan page shows: how many
// supporters paid in the plan's current period window and in the one
// before (as in GetPlan), and how many active mandates have never paid,
// among the latest ScanLimit entries (unpaidExact is false when there were
// more entries than that).
func PlanCounts(planID uint64) (paidThisPeriod, paidLastPeriod, unpaid int, unpaidExact bool) {
	p := planOf(planID)
	if p == nil {
		return 0, 0, 0, true
	}
	now := time.Now().Unix()
	paidThisPeriod, paidLastPeriod = p.paidWindows(now)
	unpaid, unpaidExact = countUnpaid(p, now)
	return
}

// countUnpaid counts active mandates that have never paid, among the
// plan's latest ScanLimit mandates, and says whether that covered them all.
func countUnpaid(p *Plan, now int64) (int, bool) {
	n := 0
	lo := p.Supporters.N - ScanLimit
	if lo < 0 {
		lo = 0
	}
	for i := p.Supporters.N - 1; i >= lo; i-- {
		e := decodeEntry(p.Supporters.at(i))
		if e.Status != statusUnpaid {
			continue
		}
		if m := activeMandate(e); m != nil && m.isActive(now) {
			n++
		}
	}
	return n, lo == 0
}

func infos(list []*Mandate) []MandateInfo {
	now := time.Now().Unix()
	out := []MandateInfo{}
	for _, m := range list {
		out = append(out, m.info(now))
	}
	return out
}

func (p *Plan) info() PlanInfo {
	now := time.Now().Unix()
	current, previous := p.paidWindows(now)
	return PlanInfo{
		ID:             p.ID,
		Payee:          p.Payee,
		Title:          p.Title,
		Amount:         p.Amount,
		Period:         p.Period,
		CreatedAt:      p.CreatedAt,
		Mandates:       p.Supporters.N,
		Cancelled:      p.Cancelled,
		PaidThisPeriod: current,
		PaidLastPeriod: previous,
		PeriodStart:    now / p.Period * p.Period,
		Pulls:          p.Pulls,
		Paid:           p.Pulls * p.Amount,
		LastPullAt:     p.LastPullAt,
	}
}

func (m *Mandate) info(now int64) MandateInfo {
	p := m.plan
	st := m.status(now)
	return MandateInfo{
		ID:            m.ID,
		PlanID:        p.ID,
		Payer:         m.Payer,
		Payee:         p.Payee,
		Session:       m.Session,
		SessionPubKey: m.sessionPubKey(),
		Amount:        p.Amount,
		Period:        p.Period,
		CreatedAt:     m.CreatedAt,
		ExpiresAt:     m.ExpiresAt,
		NextPullAt:    m.NextPullAt,
		LastPullAt:    m.lastPullAt(),
		PaidThrough:   m.paidThrough(),
		Pulls:         m.Pulls,
		Paid:          m.Pulls * p.Amount,
		CancelledAt:   m.CancelledAt,
		CancelledBy:   m.CancelledBy,
		Status:        st,
		Due:           st == "active" && now >= m.NextPullAt,
		SessionQuery:  "auth/accounts/" + m.Payer.String() + "/session/" + m.Session.String(),
	}
}

// lastPullAt is when the last pull happened (0 = never): each pull sets
// NextPullAt to its own time plus one period.
func (m *Mandate) lastPullAt() int64 {
	if m.Pulls == 0 {
		return 0
	}
	return m.NextPullAt - m.plan.Period
}

// sessionPubKey returns the session key's public key when it is the payee's
// current collector key, "" otherwise (the realm then does not know it).
func (m *Mandate) sessionPubKey() string {
	if pe := m.plan.payee; pe.CollectorAddr == m.Session {
		return pe.CollectorKey
	}
	return ""
}

// offset turns a 1-based page number into a row offset; pages below 1 and
// absurdly large pages are clamped.
func offset(page int) int {
	if page < 1 {
		page = 1
	}
	if page > 1_000_000 {
		page = 1_000_000
	}
	return (page - 1) * PageSize
}

// pageBounds returns the slice bounds of page `page` (1-based, PageSize
// rows) in a list of n rows, and whether another page follows.
func pageBounds(n, page int) (lo, hi int, more bool) {
	lo = offset(page)
	if lo > n {
		lo = n
	}
	hi = lo + PageSize
	if hi > n {
		hi = n
	}
	return lo, hi, hi < n
}

// paidFlag is CollectorScan's last column: "1" once the payer has paid for
// the plan through this mandate or carried paid time into it, else "0".
func paidFlag(m *Mandate) string {
	if m.paidThrough() > 0 {
		return "1"
	}
	return "0"
}
