package agentmarketplace

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Reputation tunables.
const (
	minRatedForTrust = 3
	halfLifeDays     = 45
	posterCapBps     = 2000 // 20% target cap; raised to 1/N when fewer posters
	weightUnit       = 1000 // reviewer weight scale; 1000 = 1.0
	decayScale       = 1000000
	scoreScale       = 1000 // milli-stars; 5000 = 5.000
	maxRatings       = 20000
	maxReviewerBonus = 2000 // extra weight cap in weightUnit
)

var (
	nextRatingID = 1

	ratings        = avl.NewTree() // padID(id) -> *Rating
	ratingsByAgent = avl.NewTree() // agent + "/" + padID(id) -> *Rating
	ratingByTask   = avl.NewTree() // padID(taskID) -> ratingID
	scores         = avl.NewTree() // agent.String() -> *AgentScore
	scoreboard     = avl.NewTree() // scoreKey -> agent address
	posterStats    = avl.NewTree() // poster.String() -> *PosterStats
	posterAgents   = avl.NewTree() // poster + "/" + agent -> true
)

// Rate records the task poster's 1-5 review of a settled job. Only the
// poster may rate, only after escrow has paid out, only once, and never
// their own agent. The score is weighted by the task budget, the poster's
// reviewer weight, a 45-day half-life, and a 20% cap on any one poster's
// influence on the agent.
func Rate(cur realm, taskID, score int, comment string) int {
	caller := mustUserCall(cur)
	t := mustGetTask(taskID)
	if t.Status != StatusCompleted || !t.Settled {
		panic("only a settled, completed task can be rated")
	}
	if t.Poster != caller {
		panic("only the task poster can rate this job")
	}
	if t.Winner == caller {
		panic("you cannot rate your own agent")
	}
	if ratingByTask.Get(padID(taskID)) != nil {
		panic("this task has already been rated")
	}
	checkScore(score)
	checkComment(comment)
	if ratings.Size() >= maxRatings {
		panic("the rating board is full")
	}

	now := time.Now()
	wt := currentReviewerWeight(caller)
	r := &Rating{
		ID:          nextRatingID,
		TaskID:      taskID,
		Agent:       t.Winner,
		Poster:      caller,
		Score:       score,
		Comment:     comment,
		BudgetUgnot: t.BudgetUgnot,
		ReviewerWt:  wt,
		RatedAt:     now,
	}
	nextRatingID++
	ratings.Set(padID(r.ID), r)
	ratingsByAgent.Set(r.Agent.String()+"/"+padID(r.ID), r)
	ratingByTask.Set(padID(taskID), r.ID)

	chain.Emit("RatingCast",
		"id", strconv.Itoa(r.ID),
		"task", strconv.Itoa(taskID),
		"agent", r.Agent.String(),
		"poster", caller.String(),
		"score", strconv.Itoa(score),
		"budgetUgnot", strconv.FormatInt(t.BudgetUgnot, 10),
	)
	recomputeAndStore(r.Agent, now)
	return r.ID
}

// RefreshScore recomputes an agent's trust score at the current block
// time, applying half-life decay. Anyone may call it.
func RefreshScore(cur realm, agent address) {
	mustUserCall(cur)
	if !agent.IsValid() {
		panic("invalid address")
	}
	recomputeAndStore(agent, time.Now())
}

// ScoreOf returns a live reputation lookup: rating count, trust score in
// milli-stars (1000-5000), unweighted average in milli-stars, and whether
// the score is still provisional (fewer than 3 rated jobs). Unrated agents
// return (0, 0, 0, true).
func ScoreOf(agent address) (int, int64, int64, bool) {
	s := liveScore(agent, time.Now())
	return s.RatedCount, s.TrustMilli, s.RawMilli, s.Provisional
}

// RatingCount is the number of ratings stored in the realm.
func RatingCount() int { return ratings.Size() }

// ReputationSummary is a one-line text score, or "" if the agent is unrated.
func ReputationSummary(agent address) string {
	s := liveScore(agent, time.Now())
	if s.RatedCount == 0 {
		return ""
	}
	label := "trusted"
	if s.Provisional {
		label = "provisional"
	}
	jobs := strconv.Itoa(s.RatedCount) + " jobs"
	if s.RatedCount == 1 {
		jobs = "1 job"
	}
	return fmtScore(s.TrustMilli) + " / 5 (" + label + ", " + jobs + ", raw " + fmtScore(s.RawMilli) + ")"
}

// ---------------------------------------------------------------------------
// internals

type posterBucket struct {
	poster address
	weight int64
	points int64
}

func liveScore(agent address, now time.Time) *AgentScore {
	out := &AgentScore{Agent: agent, Provisional: true}
	var buckets []posterBucket
	var rawSum int64
	var last time.Time
	prefix := agent.String() + "/"
	ratingsByAgent.Iterate(prefix, prefix+"~", func(_ string, v any) bool {
		r := v.(*Rating)
		out.RatedCount++
		rawSum += int64(r.Score)
		if last.IsZero() || r.RatedAt.After(last) {
			last = r.RatedAt
		}
		w := ratingWeight(r, now)
		if w <= 0 {
			return false
		}
		i := findBucket(buckets, r.Poster)
		if i < 0 {
			buckets = append(buckets, posterBucket{poster: r.Poster, weight: w, points: w * int64(r.Score)})
		} else {
			buckets[i].weight += w
			buckets[i].points += w * int64(r.Score)
		}
		return false
	})
	out.LastRatedAt = last
	if out.RatedCount == 0 {
		return out
	}
	out.RawMilli = (rawSum * scoreScale) / int64(out.RatedCount)
	out.Provisional = out.RatedCount < minRatedForTrust
	capBuckets(buckets)
	var denom, sum int64
	for _, b := range buckets {
		denom += b.weight
		sum += b.points
	}
	if denom > 0 {
		out.TrustMilli = (sum * scoreScale) / denom
	}
	return out
}

func ratingWeight(r *Rating, now time.Time) int64 {
	age := now.Sub(r.RatedAt)
	if age < 0 {
		age = 0
	}
	// weight = budget * (reviewerWt / 1000) * (decay / 1e6)
	w := r.BudgetUgnot
	if r.ReviewerWt > 0 {
		w = w * r.ReviewerWt / weightUnit
	}
	d := decayPPM(age)
	if d <= 0 {
		return 0
	}
	return w * d / decayScale
}

// decayPPM is 1e6 * 0.5^(age / 45 days), computed in integer math at
// the current block time.
func decayPPM(age time.Duration) int64 {
	const halfLife = time.Duration(halfLifeDays) * 24 * time.Hour
	if age <= 0 {
		return decayScale
	}
	n := int64(age / halfLife)
	if n >= 40 {
		return 0
	}
	ppm := int64(decayScale)
	for i := int64(0); i < n; i++ {
		ppm /= 2
	}
	rem := age % halfLife
	if rem == 0 || ppm == 0 {
		return ppm
	}
	// 0.5^(rem/halfLife) ≈ 1 - ln2 f + (ln2^2/2) f^2 - (ln2^3/6) f^3
	// with f in 1e6 and coefficients in 1e6.
	// Convert to seconds first: rem * 1e6 overflows int64 in nanoseconds.
	f := int64(rem/time.Second) * decayScale / int64(halfLife/time.Second)
	const ln2 = int64(693147)
	const c2 = int64(240226)
	const c3 = int64(55504)
	f2 := f * f / decayScale
	f3 := f2 * f / decayScale
	adj := decayScale - (ln2*f)/decayScale + (c2*f2)/decayScale - (c3*f3)/decayScale
	if adj < decayScale/2 {
		adj = decayScale / 2
	}
	if adj > decayScale {
		adj = decayScale
	}
	return ppm * adj / decayScale
}

func findBucket(bs []posterBucket, poster address) int {
	for i, b := range bs {
		if b.poster == poster {
			return i
		}
	}
	return -1
}

// capBuckets caps one poster's share of the pre-cap weight mass. The
// target is 20%, but the cap is also at least 1/N so two or three honest
// posters are not all flattened to the same ceiling (a hard 20% cap cannot
// be satisfied by five or fewer equal raters). A sole poster is uncapped.
// Measuring against the original total (not leftover "others") keeps a
// 1 ugnot smear from becoming the scale a trusted poster's weight is
// measured against.
func capBuckets(bs []posterBucket) {
	if len(bs) < 2 {
		return
	}
	var total int64
	for _, b := range bs {
		total += b.weight
	}
	if total <= 0 {
		return
	}
	n := int64(len(bs))
	maxBps := int64(posterCapBps)
	if inv := 10000 / n; inv > maxBps {
		maxBps = inv
	}
	// maxW = maxBps of the pre-cap total, rounded up
	maxW := (total*maxBps + 9999) / 10000
	if maxW < 1 {
		maxW = 1
	}
	for i, b := range bs {
		if b.weight > maxW {
			if b.weight > 0 {
				bs[i].points = bs[i].points * maxW / b.weight
			}
			bs[i].weight = maxW
		}
	}
}

func currentReviewerWeight(poster address) int64 {
	w := int64(weightUnit)
	v := posterStats.Get(poster.String())
	if v == nil {
		return w
	}
	ps := v.(*PosterStats)
	d := int64(ps.DistinctAgents)
	if d > 20 {
		d = 20
	}
	w += d * 100
	gnot := ps.SettledUgnot / ugnotPerGnot
	if gnot > maxReviewerBonus {
		gnot = maxReviewerBonus
	}
	w += gnot
	if w > weightUnit+maxReviewerBonus {
		w = weightUnit + maxReviewerBonus
	}
	return w
}

func recordPosterPayment(poster, agent address, budget int64) {
	v := posterStats.Get(poster.String())
	var ps *PosterStats
	if v == nil {
		ps = &PosterStats{Owner: poster}
		posterStats.Set(poster.String(), ps)
	} else {
		ps = v.(*PosterStats)
	}
	key := poster.String() + "/" + agent.String()
	if posterAgents.Get(key) == nil {
		posterAgents.Set(key, true)
		ps.DistinctAgents++
	}
	ps.SettledJobs++
	ps.SettledUgnot += budget
}

func recomputeAndStore(agent address, now time.Time) *AgentScore {
	s := liveScore(agent, now)
	if prev := scores.Get(agent.String()); prev != nil {
		old := prev.(*AgentScore)
		scoreboard.Remove(scoreKey(old.TrustMilli, old.RatedCount, agent))
	}
	if s.RatedCount > 0 {
		scores.Set(agent.String(), s)
		scoreboard.Set(scoreKey(s.TrustMilli, s.RatedCount, agent), agent)
	} else {
		scores.Remove(agent.String())
	}
	chain.Emit("ScoreUpdated",
		"agent", agent.String(),
		"ratedCount", strconv.Itoa(s.RatedCount),
		"trustMilli", strconv.FormatInt(s.TrustMilli, 10),
		"rawMilli", strconv.FormatInt(s.RawMilli, 10),
		"provisional", strconv.FormatBool(s.Provisional),
	)
	return s
}

// scoreKey sorts the highest trust first, then the most ratings, then
// lowest address for a stable tie-break.
func scoreKey(trustMilli int64, count int, agent address) string {
	const ceiling = int64(9999999)
	inv := strconv.FormatInt(ceiling-trustMilli, 10)
	for len(inv) < 7 {
		inv = "0" + inv
	}
	c := strconv.Itoa(1000000 - count)
	for len(c) < 7 {
		c = "0" + c
	}
	return inv + "/" + c + "/" + agent.String()
}

func fmtScore(milli int64) string {
	if milli < 0 {
		milli = 0
	}
	whole := milli / scoreScale
	frac := milli % scoreScale
	// two decimal places
	frac = frac / 10
	f := strconv.FormatInt(frac, 10)
	for len(f) < 2 {
		f = "0" + f
	}
	return strconv.FormatInt(whole, 10) + "." + f
}
