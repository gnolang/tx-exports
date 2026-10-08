package memba_gov

import "time"

// Classes. A target hard-codes the minimum class of each action it governs.
const (
	Routine   = 1
	Financial = 2
	Critical  = 3
)

// A route is one way a proposal passes: a rule on the YES votes of the
// seated roster and the delay that follows. Thresholds are fractions of the
// seated weight W and persons N. Every rule needs at least two persons: the
// critical ones because N is at least 2.
type route struct {
	rule  int
	delay time.Duration
}

const (
	ruleRoutine = iota
	ruleFinancial
	ruleWeighted
	ruleHeadcount
)

func meets(rule, w, p, W, N int) bool {
	switch rule {
	case ruleRoutine: // >= 3/8 of the weight
		return 8*w >= 3*W && p >= 2
	case ruleFinancial: // >= 3/5 of the weight and a majority of persons
		return 5*w >= 3*W && p >= 3 && 2*p > N
	case ruleWeighted: // >= 2/3 of the weight and a majority of persons
		return 3*w >= 2*W && 2*p > N
	case ruleHeadcount: // >= 2/3 of the persons and a majority of the weight
		return 3*p >= 2*N && 2*w > W
	}
	return false
}

// routes returns the ways proposal p passes: its class sets the rules, and
// a roster action of this realm has its own delay on every route.
func routes(p *proposal) []route {
	var rs []route
	switch p.class {
	case Routine:
		rs = []route{{ruleRoutine, 0}}
	case Financial:
		rs = []route{{ruleFinancial, 0}}
	default:
		rs = []route{{ruleWeighted, WeightedDelay}, {ruleHeadcount, HeadcountDelay}}
	}
	if p.target == corePath {
		for i := range rs {
			rs[i].delay = rosterDelay(p.action)
		}
	}
	return rs
}

// A streak is one current YES ballot: when it began and its voter's weight.
type streak struct {
	since  int64
	weight int
}

// yesStreaks returns p's current YES ballots, oldest streak first.
func yesStreaks(p *proposal) []streak {
	var ys []streak
	for _, b := range p.ballots {
		if b.vote != voteYes {
			continue
		}
		x := streak{b.since, weightOf(b.person)}
		ys = append(ys, x)
		i := len(ys) - 1
		for ; i > 0 && ys[i-1].since > x.since; i-- {
			ys[i] = ys[i-1]
		}
		ys[i] = x
	}
	return ys
}

// qualifiedSince returns when (unix seconds) the earliest coalition still
// voting YES without interruption first met rule, or 0. The coalition of a
// start time is every YES streak begun no later; every rule only grows with
// more votes, so the first prefix of ys that meets it ends on that time
// (streaks begun in the same second share it). A voter the rest of the
// coalition does not need cannot postpone the clock by withdrawing and
// rejoining.
func qualifiedSince(ys []streak, rule, W, N int) int64 {
	w, n := 0, 0
	for _, x := range ys {
		w += x.weight
		n++
		if meets(rule, w, n, W, N) {
			return x.since
		}
	}
	return 0
}

// Proposal states, in the order a reader checks them.
const (
	stExecuted    = "executed"
	stInvalidated = "invalidated"
	stExpired     = "expired"
	stReady       = "ready"
	stTimelocked  = "timelocked"
	stVoting      = "voting"
)

// state returns p's status and, once some route qualified, the earliest
// unix time it is or becomes executable (0 before). Voting ends just before
// the deadline second; readyAt and the end of the execution window are
// inclusive.
func state(p *proposal) (string, int64) {
	if p.consumed {
		return stExecuted, 0
	}
	if p.globalGen != globalGen || p.scopeGen != scopeGen(p.target, p.scope) || vetoed(p) {
		return stInvalidated, 0
	}
	t := now()
	W, N := seatedTotals()
	ys := yesStreaks(p)
	var readyAt, longest int64
	for _, r := range routes(p) {
		if d := secs(r.delay); d > longest {
			longest = d
		}
		if since := qualifiedSince(ys, r.rule, W, N); since != 0 {
			if at := since + secs(r.delay); readyAt == 0 || at < readyAt {
				readyAt = at
			}
		}
	}
	deadline := p.created + secs(VotingPeriod)
	if t > deadline+longest+secs(ExecutionWindow) || (readyAt == 0 && t >= deadline) {
		return stExpired, readyAt
	}
	switch {
	case readyAt == 0:
		return stVoting, readyAt
	case t < readyAt:
		return stTimelocked, readyAt
	}
	return stReady, readyAt
}

// vetoed reports whether the member a RemoveInactive names has been active
// since the proposal: proposing, voting, executing or joining vetoes it.
func vetoed(p *proposal) bool {
	if p.target != corePath || p.action != actRemoveInactive {
		return false
	}
	m := personByID(p.subject)
	return m != nil && m.lastActive >= p.created
}
