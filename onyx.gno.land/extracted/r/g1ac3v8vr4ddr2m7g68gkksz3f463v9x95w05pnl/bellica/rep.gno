package bellica

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Reputation for both sides, computed only from escrow outcomes and from
// ratings/reports by counterparties of finished, escrowed items.
//
// Escrow already makes non-payment impossible: once GNOT is posted it can only
// go to agents or, by the rules, back to the creator. Reputation covers what
// escrow cannot: unfair rejects, silence, self-judged disqualify-all.

// Rep holds outcome counters per address (giver side and agent side).
type Rep struct {
	Addr address
	// giver
	Posted             int   // bounties + jobs posted
	PaidOut            int64 // ugnot actually paid to agents
	PaidItems          int   // finished items that paid at least one agent
	Approved           int   // jobs approved / trial winners picked by the creator
	FastApprovals      int   // ... within the first half of the review window
	AutoReleased       int   // jobs paid only because the creator went silent
	JudgeSilent        int   // bounties where this judge missed the window (Fallback)
	RejectsIssued      int
	DeliveriesReceived int
	DisputesWon        int // arbiter ruled < 50% to the agent
	DisputesLost       int // arbiter ruled >= 50% to the agent
	RefundsNoDelivery  int // refunded because the hired agent never delivered
	DQAll              int // self-judged bounty with every entry DQ'd, or every trial rejected
	Cancellations      int
	// agent
	Hired         int // hired, accepted or shortlisted
	Delivered     int
	WorkApproved  int // approved jobs + picked trials
	WorkRejected  int
	Missed        int // hired but never delivered
	Wins          int // contest 1st places
	Podiums       int // contest paid places
	Earned        int64
	ADisputesWon  int
	ADisputesLost int
	// ratings and reports (by counterparties only)
	GiverRatingSum, GiverRatingN int
	AgentRatingSum, AgentRatingN int
	ReportsAgainst               int
	UpheldAgainst                int // reports with evidence that on-chain facts confirm
	ReportsFiled                 int
	giverKey, agentKey           string // current keys in the leaderboards
}

var (
	reps        = avl.NewTree() // address -> *Rep
	giverBoard  = avl.NewTree() // score key -> *Rep (givers who paid out)
	agentBoard2 = avl.NewTree() // score key -> *Rep (agents who earned)
	ratings     = avl.NewTree() // "kind:id:rater:target" -> *Rating
	ratingsOf   = avl.NewTree() // target -> []*Rating, newest 50
	reports     = avl.NewTree() // key(id) -> *Report
	nextReport  = 1
	reportPair  = avl.NewTree() // "kind:id:reporter:target" -> report id
	reportsOn   = avl.NewTree() // "kind:id" -> []int, newest 100
	reportsAbout = avl.NewTree() // target -> []int, newest 50
)

const (
	maxRatingsShown = 50
	maxReportsItem  = 100
	maxReportsAddr  = 50
	MinReportText   = 30
	MaxReportText   = 500
)

func repOf(a address) *Rep {
	if r, ok := reps.Get(a.String()).(*Rep); ok && r != nil {
		return r
	}
	return &Rep{Addr: a}
}

func peekRep(a address) *Rep {
	if r, ok := reps.Get(a.String()).(*Rep); ok && r != nil {
		return r
	}
	return nil
}

// repChange applies a change and keeps both leaderboards in sync.
func repChange(a address, change func(r *Rep)) {
	if a == "" {
		return
	}
	r := repOf(a)
	change(r)
	reps.Set(a.String(), r)
	if r.giverKey != "" {
		giverBoard.Remove(r.giverKey)
		r.giverKey = ""
	}
	if r.agentKey != "" {
		agentBoard2.Remove(r.agentKey)
		r.agentKey = ""
	}
	if r.PaidOut > 0 {
		r.giverKey = pad(9223372036854775807-giverScore(r), 19) + a.String()
		giverBoard.Set(r.giverKey, r)
	}
	if r.Earned > 0 {
		r.agentKey = pad(9223372036854775807-agentScore(r), 19) + a.String()
		agentBoard2.Set(r.agentKey, r)
	}
}

// ---------- scores, tiers, badges (documented in README) ----------

// avg10 is the average rating in tenths (e.g. 43 = 4.3), or -1 with no ratings.
func avg10(sum, n int) int {
	if n == 0 {
		return -1
	}
	return sum * 10 / n
}

func penalty(p int) int64 {
	if p < 0 {
		return 0
	}
	return int64(p)
}

// giverScore = paid out (milli-GNOT) × rating factor (avg/5, or 3/5 unrated)
// × max(0, 100 − 10·silent − 20·disputes lost − 25·upheld reports − 25·DQ-all) %.
func giverScore(r *Rep) int64 {
	a := avg10(r.GiverRatingSum, r.GiverRatingN)
	if a < 0 {
		a = 30
	}
	p := penalty(100 - 10*(r.AutoReleased+r.JudgeSilent) - 20*r.DisputesLost - 25*r.UpheldAgainst - 25*r.DQAll)
	return (r.PaidOut / 1000) * int64(a) * p / 5000
}

// agentScore = earned (milli-GNOT) × rating factor × max(0, 100 − 20·missed − 20·disputes lost − 25·upheld) %.
func agentScore(r *Rep) int64 {
	a := avg10(r.AgentRatingSum, r.AgentRatingN)
	if a < 0 {
		a = 30
	}
	p := penalty(100 - 20*r.Missed - 20*r.ADisputesLost - 25*r.UpheldAgainst)
	return (r.Earned / 1000) * int64(a) * p / 5000
}

var tierNames = []string{"Tiro", "Gladiator", "Veteran", "Centurion", "Champion", "Rudiarius"}
var tierIcons = []string{"🪵", "🗡️", "🛡️", "🦅", "🏆", "👑"}

// tier rule per level: successes, earned (GNOT), min average (tenths), min ratings.
var tierRules = [][4]int64{
	{0, 0, 0, 0},
	{1, 0, 0, 0},
	{3, 5, 35, 0},
	{10, 25, 40, 3},
	{25, 100, 43, 10},
	{50, 500, 46, 25},
}

// agentTier: the highest level whose rule holds (successes = approved work +
// contest paid places), then one level down per 2 strikes (upheld reports + missed deadlines).
func agentTier(r *Rep) int {
	if r == nil {
		return 0
	}
	succ := int64(r.WorkApproved + r.Podiums)
	a := avg10(r.AgentRatingSum, r.AgentRatingN)
	t := 0
	for lvl := 1; lvl < len(tierRules); lvl++ {
		rule := tierRules[lvl]
		if succ < rule[0] || r.Earned < rule[1]*1_000_000 || int64(r.AgentRatingN) < rule[3] {
			break
		}
		if rule[2] > 0 && a >= 0 && int64(a) < rule[2] {
			break
		}
		t = lvl
	}
	t -= (r.UpheldAgainst + r.Missed) / 2
	if t < 0 {
		t = 0
	}
	return t
}

func tierOf(a address) int { return agentTier(peekRep(a)) }

func tierLabel(t int) string { return tierIcons[t] + " " + tierNames[t] }

// Patron ladder for givers: 0 none, 1..3 Patron I..III, minus one per 2 strikes
// (silent auto-releases + lost disputes + upheld reports + DQ-all).
func patronLevel(r *Rep) int {
	if r == nil || r.PaidItems == 0 {
		return 0
	}
	a := avg10(r.GiverRatingSum, r.GiverRatingN)
	lvl := 1
	if r.PaidItems >= 5 && r.PaidOut >= 10_000_000 && (a < 0 || a >= 35) {
		lvl = 2
	}
	if lvl == 2 && r.PaidItems >= 20 && r.PaidOut >= 100_000_000 && r.GiverRatingN >= 5 && a >= 40 {
		lvl = 3
	}
	lvl -= (r.AutoReleased + r.DisputesLost + r.UpheldAgainst + r.DQAll) / 2
	if lvl < 0 {
		lvl = 0
	}
	return lvl
}

func patronLabel(l int) string {
	switch l {
	case 1:
		return "🎗️ Patron I"
	case 2:
		return "🎗️ Patron II"
	case 3:
		return "🎗️ Patron III"
	}
	return ""
}

// giverBadges: positive badges first, then warnings for agents' safety.
func giverBadges(r *Rep) []string {
	if r == nil || r.Posted == 0 {
		return nil
	}
	var out []string
	a := avg10(r.GiverRatingSum, r.GiverRatingN)
	silent := r.AutoReleased + r.JudgeSilent
	if r.PaidItems >= 3 && r.GiverRatingN >= 1 && a >= 40 {
		out = append(out, "🏅 Patron")
	}
	if r.FastApprovals >= 2 && silent == 0 {
		out = append(out, "⚡ Fast reviewer")
	}
	if r.PaidItems >= 3 && silent == 0 && r.DisputesLost == 0 && r.DQAll == 0 && r.UpheldAgainst == 0 {
		out = append(out, "✅ Reliable payer")
	}
	if silent >= 2 || (silent >= 1 && silent*4 >= r.PaidItems) {
		out = append(out, "🔕 Often silent")
	}
	if (r.DisputesLost >= 1 && r.DisputesLost >= r.DisputesWon) || r.UpheldAgainst >= 2 {
		out = append(out, "⚠️ Disputed")
	}
	if r.DQAll >= 1 {
		out = append(out, "🚫 Rejected everyone")
	}
	if r.RejectsIssued >= 3 && r.RejectsIssued*2 > r.DeliveriesReceived {
		out = append(out, "✂️ Harsh reviewer")
	}
	if len(out) == 0 && r.PaidItems == 0 {
		out = append(out, "🆕 New giver")
	}
	return out
}

func agentBadges(r *Rep) []string {
	if r == nil || (r.Hired == 0 && r.Podiums == 0 && r.Earned == 0) {
		return nil
	}
	var out []string
	a := avg10(r.AgentRatingSum, r.AgentRatingN)
	if r.WorkApproved+r.Podiums >= 3 && r.Missed == 0 && (a < 0 || a >= 40) {
		out = append(out, "⭐ Proven")
	}
	if r.Missed >= 2 || (r.Missed >= 1 && r.Missed*3 >= r.Hired) {
		out = append(out, "⏰ Misses deadlines")
	}
	if (r.ADisputesLost >= 1 && r.ADisputesLost >= r.ADisputesWon) || r.UpheldAgainst >= 2 {
		out = append(out, "⚠️ Disputed")
	}
	return out
}

// ---------- items and parties ----------

// partySides reports whether addr is on the giver side and/or the worker side
// of a finished, escrowed item ("job" or "bounty").
func partySides(kind string, id int, addr address) (giver, worker bool) {
	switch kind {
	case "job":
		j := mustJob(id)
		if !j.closed() || j.Status == JobCancelled {
			panic("only finished jobs can be rated or reported")
		}
		if addr == j.Creator {
			giver = true
		}
		if j.Mode == ModeSelection {
			if t, ok := j.trials.Get(addr.String()).(*Trial); ok && t != nil && !t.At.IsZero() {
				worker = true
			}
		} else if addr == j.Agent && j.Agent != "" {
			if j.Status != JobCancelled {
				worker = true
			}
		}
	case "bounty":
		b := mustBounty(id)
		if b.Status == StatusOpen || b.Status == StatusCancelled {
			panic("only finished bounties can be rated or reported")
		}
		if addr == b.Creator || addr == b.Judge {
			giver = true
		}
		if e, ok := b.entries.Get(addr.String()).(*Entry); ok && e != nil && (e.Payout > 0 || e.Disqualified) {
			worker = true
		}
	default:
		panic("kind must be job or bounty")
	}
	return
}

// mustCounterparties checks rater and target sit on opposite sides of the item.
// Returns true when the target is on the giver side.
func mustCounterparties(kind string, id int, rater, target address) bool {
	if rater == target {
		panic("you cannot rate or report yourself")
	}
	rg, rw := partySides(kind, id, rater)
	tg, tw := partySides(kind, id, target)
	switch {
	case rg && tw:
		return false
	case rw && tg:
		return true
	}
	panic("only counterparties of this item can rate or report each other")
}

// ---------- ratings ----------

type Rating struct {
	Kind    string
	ItemID  int
	Rater   address
	Target  address
	Score   int
	Comment string
	AsGiver bool // the target was rated in their giver role
	At      time.Time
}

// Rate scores a counterparty of a finished job or bounty from 1 to 5 with an
// optional comment (max 280 chars). One rating per rater, target and item.
func Rate(cur realm, kind string, id int, target string, score int, comment string) {
	rater := cur.Previous().Address()
	kind = strings.ToLower(clean(kind))
	t := mustAddr("target", clean(target))
	asGiver := mustCounterparties(kind, id, rater, t)
	if score < 1 || score > 5 {
		panic("score must be 1-5")
	}
	comment = clean(comment)
	mustLen("comment", comment, 0, MaxText)
	k := kind + ":" + strconv.Itoa(id) + ":" + rater.String() + ":" + t.String()
	if ratings.Has(k) {
		panic("you already rated this counterparty for this item")
	}
	rt := &Rating{Kind: kind, ItemID: id, Rater: rater, Target: t, Score: score, Comment: comment, AsGiver: asGiver, At: time.Now()}
	ratings.Set(k, rt)
	list, _ := ratingsOf.Get(t.String()).([]*Rating)
	list = append(list, rt)
	if len(list) > maxRatingsShown {
		list = list[len(list)-maxRatingsShown:]
	}
	ratingsOf.Set(t.String(), list)
	repChange(t, func(r *Rep) {
		if asGiver {
			r.GiverRatingSum += score
			r.GiverRatingN++
		} else {
			r.AgentRatingSum += score
			r.AgentRatingN++
		}
	})
	chain.Emit("Rated", "kind", kind, "id", strconv.Itoa(id), "rater", rater.String(), "target", t.String(), "score", strconv.Itoa(score))
}

// ---------- reports ----------

var reportReasons = []string{"non_payment_attempt", "unfair_reject", "unfair_dq", "spam", "plagiarism", "other"}

func evidenceRequired(reason string) bool {
	switch reason {
	case "non_payment_attempt", "unfair_reject", "unfair_dq", "plagiarism":
		return true
	}
	return false
}

type ReportRec struct {
	ID          int
	Kind        string
	ItemID      int
	Reporter    address
	Target      address
	Reason      string
	Text        string
	Evidence    string
	Facts       string // on-chain facts of the item, snapshot at report time
	Upheld      bool   // evidence given and the on-chain facts confirm it
	Basis       string // why it is upheld
	At          time.Time
	Response    string
	RespondedAt time.Time
}

// Report files a public report against a counterparty of a finished job or
// bounty. reason: non_payment_attempt, unfair_reject, unfair_dq, spam,
// plagiarism or other. text: 30-500 chars explaining what happened. evidence:
// https/ipfs link, required for every reason except spam and other.
// No on-chain punishment: reports are shown on the item and the profile, and
// only upheld ones (evidence + confirming on-chain facts) count in badges/scores.
func Report(cur realm, kind string, id int, target, reason, text, evidence string) int {
	rep := cur.Previous().Address()
	kind = strings.ToLower(clean(kind))
	t := mustAddr("target", clean(target))
	targetIsGiver := mustCounterparties(kind, id, rep, t)
	reason = strings.ToLower(clean(reason))
	if !inList(reason, reportReasons) {
		panic("reason must be one of " + strings.Join(reportReasons, ", "))
	}
	text = mustReportText(text)
	if clean(evidence) != "" {
		evidence = mustWorkURL("evidence", evidence)
	} else {
		evidence = ""
	}
	if evidenceRequired(reason) && evidence == "" {
		panic("an evidence link (https or ipfs) is required for " + reason)
	}
	pk := kind + ":" + strconv.Itoa(id) + ":" + rep.String() + ":" + t.String()
	if reportPair.Has(pk) {
		panic("you already reported this counterparty for this item")
	}
	r := &ReportRec{ID: nextReport, Kind: kind, ItemID: id, Reporter: rep, Target: t, Reason: reason, Text: text, Evidence: evidence, At: time.Now()}
	r.Facts = itemFacts(kind, id, rep, t)
	if evidence != "" {
		r.Upheld, r.Basis = upheld(kind, id, rep, t, targetIsGiver, reason)
	}
	reports.Set(key(r.ID), r)
	reportPair.Set(pk, r.ID)
	nextReport++
	ik := kind + ":" + strconv.Itoa(id)
	ids, _ := reportsOn.Get(ik).([]int)
	if len(ids) < maxReportsItem {
		reportsOn.Set(ik, append(ids, r.ID))
	}
	aids, _ := reportsAbout.Get(t.String()).([]int)
	aids = append(aids, r.ID)
	if len(aids) > maxReportsAddr {
		aids = aids[len(aids)-maxReportsAddr:]
	}
	reportsAbout.Set(t.String(), aids)
	repChange(t, func(x *Rep) {
		x.ReportsAgainst++
		if r.Upheld {
			x.UpheldAgainst++
		}
	})
	repChange(rep, func(x *Rep) { x.ReportsFiled++ })
	chain.Emit("Reported", "report", strconv.Itoa(r.ID), "kind", kind, "id", strconv.Itoa(id), "target", t.String(), "reason", reason, "upheld", strconv.FormatBool(r.Upheld))
	return r.ID
}

// Respond posts the reported party's single public answer to a report.
func Respond(cur realm, reportID int, text string) {
	caller := cur.Previous().Address()
	r, ok := reports.Get(key(reportID)).(*ReportRec)
	if !ok || r == nil {
		panic("report not found")
	}
	if caller != r.Target {
		panic("only the reported party can respond")
	}
	if r.Response != "" {
		panic("already responded")
	}
	r.Response = mustReportText(text)
	r.RespondedAt = time.Now()
	chain.Emit("ReportAnswered", "report", strconv.Itoa(reportID))
}

// mustReportText: 30-500 chars, single line, and not filler (AUDIT H5): at
// least 8 distinct letters/digits and no single character over half the text.
func mustReportText(s string) string {
	s = clean(s)
	mustLen("text", s, MinReportText, MaxReportText)
	seen := map[rune]int{}
	total, distinct, top := 0, 0, 0
	for _, r := range s {
		if r == ' ' {
			continue
		}
		total++
		if seen[r] == 0 && (r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r > 127) {
			distinct++
		}
		seen[r]++
		if seen[r] > top {
			top = seen[r]
		}
	}
	if distinct < 8 || top*2 > total {
		panic("text must explain what happened (not repeated characters)")
	}
	return s
}

// itemFacts snapshots the recorded on-chain facts relevant to a report.
func itemFacts(kind string, id int, reporter, target address) string {
	if kind == "job" {
		j := mustJob(id)
		s := ufmt.Sprintf("job #%d (%s) %s · pay %s · outcome %s", j.ID, j.Mode, j.Status, gnot(j.Pay), j.Status)
		if j.Mode == ModeDirect {
			if !j.DeliveredAt.IsZero() {
				s += " · delivered " + when(j.DeliveredAt) + " (" + j.Kind + ")"
			} else {
				s += " · never delivered"
			}
			s += ufmt.Sprintf(" · %d reject(s)", j.Rejects)
			if j.RejectReason != "" {
				s += " · last reject reason: " + j.RejectReason
			}
			s += ufmt.Sprintf(" · agent got %d%%", j.AgentPct)
		} else {
			s += ufmt.Sprintf(" · %d trial(s) delivered of %d shortlisted", j.Deliveries, len(j.shortlist))
			if j.RejectedAll {
				s += " · creator rejected all trials: " + j.RejectReason
			}
		}
		if j.Resolved {
			s += " · resolved by the arbiter"
		}
		if j.AutoReleased {
			s += " · paid by auto-release (silence)"
		}
		return s
	}
	b := mustBounty(id)
	s := ufmt.Sprintf("bounty #%d %s · pot %s · paid %s", b.ID, b.Status, gnot(b.Pot), gnot(b.Paid))
	if b.selfJudged() {
		s += " · self-judged"
	}
	for _, a := range []address{reporter, target} {
		if e, ok := b.entries.Get(a.String()).(*Entry); ok && e != nil {
			if e.Disqualified {
				s += " · " + a.String()[:10] + "… DQ'd: " + e.DQReason
			} else if e.Payout > 0 {
				s += " · " + a.String()[:10] + "… paid " + gnot(e.Payout)
			}
		}
	}
	return s
}

// upheld: does the item's recorded outcome confirm the report? Never decided
// by votes, only by escrow facts (arbiter ruling, silence, self-judged DQ-all).
func upheld(kind string, id int, reporter, target address, targetIsGiver bool, reason string) (bool, string) {
	if kind == "job" {
		j := mustJob(id)
		if j.Resolved {
			if targetIsGiver && j.AgentPct >= 50 {
				return true, "the arbiter ruled for the agent"
			}
			if !targetIsGiver && j.AgentPct < 50 {
				return true, "the arbiter ruled for the creator"
			}
		}
		if targetIsGiver && j.AutoReleased && j.Mode == ModeDirect && (reason == "unfair_reject" || reason == "non_payment_attempt") {
			return true, "the creator went silent and the pay was auto-released"
		}
		if !targetIsGiver && j.NoDelivery {
			return true, "the agent never delivered"
		}
		return false, ""
	}
	b := mustBounty(id)
	if targetIsGiver && reason == "unfair_dq" && b.DQAll {
		if e, ok := b.entries.Get(reporter.String()).(*Entry); ok && e != nil && e.Disqualified {
			return true, "self-judged bounty disqualified every entry"
		}
	}
	return false, ""
}

func mustTier(t int) {
	if t < 0 || t >= len(tierNames) {
		panic("minTier must be 0-5 (0 = any)")
	}
}

// mustMinTier gates Apply / Accept / Submit on a job or bounty's minimum tier.
func mustMinTier(a address, min int) {
	if min > 0 && tierOf(a) < min {
		panic("this requires tier " + tierNames[min] + " or higher; yours is " + tierNames[tierOf(a)])
	}
}
