package core

import (
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
)

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
	GiverKey, AgentKey           string // current keys in the leaderboards
}

const MaxRatingsShown = 50

const MaxReportsItem = 100

const MaxReportsAddr = 50

func RepOf(db *State, a address) *Rep {
	if r, ok := db.Reps.Get(a.String()).(*Rep); ok && r != nil {
		return r
	}
	return &Rep{Addr: a}
}

func PeekRep(db *State, a address) *Rep {
	if r, ok := db.Reps.Get(a.String()).(*Rep); ok && r != nil {
		return r
	}
	return nil
}

// repChange applies a change and keeps both leaderboards in sync.
func RepChange(db *State, a address, change func(r *Rep)) {
	if a == "" {
		return
	}
	r := RepOf(db, a)
	change(r)
	db.Reps.Set(a.String(), r)
	if r.GiverKey != "" {
		db.GiverBoard.Remove(r.GiverKey)
		r.GiverKey = ""
	}
	if r.AgentKey != "" {
		db.AgentBoard2.Remove(r.AgentKey)
		r.AgentKey = ""
	}
	if r.PaidOut > 0 {
		r.GiverKey = textfmt.Pad(9223372036854775807-GiverScore(r), 19) + a.String()
		db.GiverBoard.Set(r.GiverKey, r)
	}
	if r.Earned > 0 {
		r.AgentKey = textfmt.Pad(9223372036854775807-AgentScore(r), 19) + a.String()
		db.AgentBoard2.Set(r.AgentKey, r)
	}
}

// avg10 is the average rating in tenths (e.g. 43 = 4.3), or -1 with no ratings.
func Avg10(sum, n int) int {
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
func GiverScore(r *Rep) int64 {
	a := Avg10(r.GiverRatingSum, r.GiverRatingN)
	if a < 0 {
		a = 30
	}
	p := penalty(100 - 10*(r.AutoReleased+r.JudgeSilent) - 20*r.DisputesLost - 25*r.UpheldAgainst - 25*r.DQAll)
	return (r.PaidOut / 1000) * int64(a) * p / 5000
}

// agentScore = earned (milli-GNOT) × rating factor × max(0, 100 − 20·missed − 20·disputes lost − 25·upheld) %.
func AgentScore(r *Rep) int64 {
	a := Avg10(r.AgentRatingSum, r.AgentRatingN)
	if a < 0 {
		a = 30
	}
	p := penalty(100 - 20*r.Missed - 20*r.ADisputesLost - 25*r.UpheldAgainst)
	return (r.Earned / 1000) * int64(a) * p / 5000
}

var TierNames = []string{"Tiro", "Gladiator", "Veteran", "Centurion", "Champion", "Rudiarius"}

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
func AgentTier(r *Rep) int {
	if r == nil {
		return 0
	}
	succ := int64(r.WorkApproved + r.Podiums)
	a := Avg10(r.AgentRatingSum, r.AgentRatingN)
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

func TierOf(db *State, a address) int { return AgentTier(PeekRep(db, a)) }

func TierLabel(t int) string { return tierIcons[t] + " " + TierNames[t] }

// Patron ladder for givers: 0 none, 1..3 Patron I..III, minus one per 2 strikes
// (silent auto-releases + lost disputes + upheld reports + DQ-all).
func PatronLevel(r *Rep) int {
	if r == nil || r.PaidItems == 0 {
		return 0
	}
	a := Avg10(r.GiverRatingSum, r.GiverRatingN)
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

func PatronLabel(l int) string {
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
func GiverBadges(r *Rep) []string {
	if r == nil || r.Posted == 0 {
		return nil
	}
	var out []string
	a := Avg10(r.GiverRatingSum, r.GiverRatingN)
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

func AgentBadges(r *Rep) []string {
	if r == nil || (r.Hired == 0 && r.Podiums == 0 && r.Earned == 0) {
		return nil
	}
	var out []string
	a := Avg10(r.AgentRatingSum, r.AgentRatingN)
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

func MustTier(t int) {
	if t < 0 || t >= len(TierNames) {
		panic("minTier must be 0-5 (0 = any)")
	}
}

// mustMinTier gates Apply / Accept / Submit on a job or bounty's minimum tier.
func MustMinTier(db *State, a address, min int) {
	if min > 0 && TierOf(db, a) < min {
		panic("this requires tier " + TierNames[min] + " or higher; yours is " + TierNames[TierOf(db, a)])
	}
}
