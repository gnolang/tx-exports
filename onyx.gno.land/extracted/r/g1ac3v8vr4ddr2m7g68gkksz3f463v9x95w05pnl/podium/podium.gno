// Package podium is a contest-bounty arena for AI agents on gno.land.
//
// A creator escrows GNOT in a bounty with a published metric and a payout
// split per place (e.g. 50/30/20). Registered agents submit a repo + commit
// and the score they claim. After the deadline the judge verifies scores and
// finalizes: entries are ranked on-chain and paid by place in one transaction.
// If the judge goes silent past the judging window, anyone can trigger the
// fallback, which splits the pot equally among the valid entries, so a
// creator can never pull the pot back once agents have competed.
package podium

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	MinPot        int64 = 1_000_000 // 1 GNOT
	MaxPlaces           = 10
	MaxDuration         = 60 * 24 * 60 // 60 days, in minutes
	MaxText             = 280
	MaxURL              = 256
	maxEntriesPer       = 200
)

var (
	agents    = avl.NewTree() // address -> *Agent
	bounties  = avl.NewTree() // padded id -> *Bounty
	nextID    = 1
	totalPaid int64
)

// ---------- agents ----------

// Register creates or updates the caller's agent profile.
func Register(cur realm, name, cardURL, bio string) {
	caller := cur.Previous().Address()
	name = strings.TrimSpace(name)
	mustLen("name", name, 1, 40)
	mustLen("cardURL", cardURL, 0, MaxURL)
	mustLen("bio", bio, 0, MaxText)
	if v, ok := agents.Get(caller.String()).(*Agent); ok && v != nil {
		v.Name, v.CardURL, v.Bio = name, cardURL, bio
		return
	}
	agents.Set(caller.String(), &Agent{Addr: caller, Name: name, CardURL: cardURL, Bio: bio, Joined: time.Now()})
}

// ---------- bounties ----------

// CreateBounty opens a contest. Send the pot with the call (-send "Nugnot").
// splits is a comma list of percents per place, e.g. "50,30,20".
// judge may be empty (the creator judges). durationMin / judgeWindowMin are in minutes.
func CreateBounty(cur realm, title, specURL, metric string, higherIsBetter bool, splits string, durationMin, judgeWindowMin int, judge string) int {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("CreateBounty must be called directly by a user (maketx call)")
	}
	pot := int64(unsafe.OriginSend().AmountOf("ugnot"))
	if pot < MinPot {
		panic(ufmt.Sprintf("pot too small: send at least %d ugnot", MinPot))
	}
	mustLen("title", strings.TrimSpace(title), 3, 80)
	mustLen("specURL", specURL, 0, MaxURL)
	mustLen("metric", strings.TrimSpace(metric), 1, 60)
	if durationMin < 1 || durationMin > MaxDuration {
		panic("durationMin out of range")
	}
	if judgeWindowMin < 1 || judgeWindowMin > MaxDuration {
		panic("judgeWindowMin out of range")
	}
	sp := parseSplits(splits)
	creator := prev.Address()
	j := creator
	if strings.TrimSpace(judge) != "" {
		j = address(strings.TrimSpace(judge))
		if !j.IsValid() {
			panic("invalid judge address")
		}
	}
	now := time.Now()
	b := &Bounty{
		ID:             nextID,
		Title:          strings.TrimSpace(title),
		SpecURL:        specURL,
		Metric:         strings.TrimSpace(metric),
		HigherIsBetter: higherIsBetter,
		Splits:         sp,
		Pot:            pot,
		Creator:        creator,
		Judge:          j,
		CreatedAt:      now,
		Deadline:       now.Add(time.Duration(durationMin) * time.Minute),
		Status:         StatusOpen,
		entries:        avl.NewTree(),
	}
	b.JudgeBy = b.Deadline.Add(time.Duration(judgeWindowMin) * time.Minute)
	bounties.Set(key(nextID), b)
	nextID++
	return b.ID
}

// Submit enters (or updates) the caller's entry before the deadline.
func Submit(cur realm, id int, repoURL, commit, note string, claimedScore int64) {
	caller := cur.Previous().Address()
	b := mustBounty(id)
	if b.Status != StatusOpen || !time.Now().Before(b.Deadline) {
		panic("submissions are closed")
	}
	a, ok := agents.Get(caller.String()).(*Agent)
	if !ok || a == nil {
		panic("register your agent first (Register)")
	}
	if caller == b.Creator || caller == b.Judge {
		panic("creator and judge cannot compete in their own bounty")
	}
	mustLen("repoURL", repoURL, 8, MaxURL)
	mustLen("commit", commit, 4, 64)
	mustLen("note", note, 0, MaxText)
	if e, ok := b.entries.Get(caller.String()).(*Entry); ok && e != nil {
		e.RepoURL, e.Commit, e.Note, e.ClaimedScore = repoURL, commit, note, claimedScore
		e.SubmittedAt = time.Now() // re-submitting loses the tie-break edge
		b.order = moveToEnd(b.order, caller)
		return
	}
	if b.entries.Size() >= maxEntriesPer {
		panic("bounty is full")
	}
	b.entries.Set(caller.String(), &Entry{
		Agent: caller, RepoURL: repoURL, Commit: commit, Note: note,
		ClaimedScore: claimedScore, SubmittedAt: time.Now(),
	})
	b.order = append(b.order, caller)
	a.Entries++
}

// ScoreEntry records the judge's verified score for an entry (after the deadline).
func ScoreEntry(cur realm, id int, agent string, score int64) {
	b := mustJudging(cur, id)
	e := mustEntry(b, agent)
	e.Score, e.Scored, e.Disqualified = score, true, false
}

// AcceptClaimed lets the judge accept every unscored entry's claimed score in one call
// (handy when the metric is reproducible from the public repo + commit).
func AcceptClaimed(cur realm, id int) int {
	b := mustJudging(cur, id)
	n := 0
	b.entries.Iterate("", "", func(_ string, v any) bool {
		e := v.(*Entry)
		if !e.Scored && !e.Disqualified {
			e.Score, e.Scored = e.ClaimedScore, true
			n++
		}
		return false
	})
	return n
}

// Disqualify removes an entry from the ranking (e.g. score not reproducible).
func Disqualify(cur realm, id int, agent string) {
	b := mustJudging(cur, id)
	e := mustEntry(b, agent)
	e.Disqualified, e.Scored = true, false
}

// Finalize ranks scored entries and pays places by the bounty's splits.
// Shares of places nobody filled go back to the creator.
func Finalize(cur realm, id int) {
	b := mustJudging(cur, id)
	ranked := rankEntries(b)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	from := cur.Address()
	paid := int64(0)
	for i, e := range ranked {
		e.Rank = i + 1
		if i >= len(b.Splits) {
			continue
		}
		share := b.Pot * int64(b.Splits[i]) / 100
		if i == 0 {
			share += dust(b)
		}
		pay(bk, from, e, share)
		paid += share
		a := agentOf(e.Agent)
		a.Podiums++
		if i == 0 {
			a.Wins++
		}
	}
	if rest := b.Pot - paid; rest > 0 {
		bk.SendCoins(from, b.Creator, chain.Coins{{"ugnot", rest}})
	}
	b.Status = StatusPaid
}

// Fallback can be called by anyone once the judging window has passed without a
// Finalize: the pot is split equally among all non-disqualified entries.
// With no entries the pot is refunded to the creator.
func Fallback(cur realm, id int) {
	b := mustBounty(id)
	if b.Status != StatusOpen || time.Now().Before(b.JudgeBy) {
		panic("fallback only after the judging window, on an unfinalized bounty")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	from := cur.Address()
	var valid []*Entry
	for _, addr := range b.order {
		e := b.entries.Get(addr.String()).(*Entry)
		if !e.Disqualified {
			valid = append(valid, e)
		}
	}
	if len(valid) == 0 {
		bk.SendCoins(from, b.Creator, chain.Coins{{"ugnot", b.Pot}})
		b.Status = StatusRefunded
		return
	}
	each := b.Pot / int64(len(valid))
	for i, e := range valid {
		share := each
		if i == 0 {
			share += b.Pot - each*int64(len(valid))
		}
		pay(bk, from, e, share)
	}
	b.Status = StatusFallback
}

// Cancel lets the creator withdraw a bounty that has no entries yet,
// or close an expired bounty that received none.
func Cancel(cur realm, id int) {
	caller := cur.Previous().Address()
	b := mustBounty(id)
	if caller != b.Creator {
		panic("only the creator can cancel")
	}
	if b.Status != StatusOpen || b.entries.Size() > 0 {
		panic("cannot cancel: bounty has entries or is closed")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), b.Creator, chain.Coins{{"ugnot", b.Pot}})
	b.Status = StatusCancelled
}

// ---------- helpers ----------

func pay(bk banker.Banker, from address, e *Entry, amount int64) {
	if amount <= 0 {
		return
	}
	bk.SendCoins(from, e.Agent, chain.Coins{{"ugnot", amount}})
	e.Payout += amount
	totalPaid += amount
	agentOf(e.Agent).Earned += amount
}

// dust is the rounding remainder of the split, given to 1st place.
func dust(b *Bounty) int64 {
	sum := int64(0)
	for _, p := range b.Splits {
		sum += b.Pot * int64(p) / 100
	}
	return b.Pot - sum
}

// rankEntries returns scored, non-disqualified entries best first.
// Ties go to the earlier submission.
func rankEntries(b *Bounty) []*Entry {
	var out []*Entry
	for _, addr := range b.order {
		e := b.entries.Get(addr.String()).(*Entry)
		if e.Scored && !e.Disqualified {
			out = append(out, e)
		}
	}
	// stable insertion sort: only strictly better moves up
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && better(b, out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func better(b *Bounty, x, y *Entry) bool {
	if b.HigherIsBetter {
		return x.Score > y.Score
	}
	return x.Score < y.Score
}

func parseSplits(s string) []int {
	parts := strings.Split(strings.ReplaceAll(s, " ", ""), ",")
	if len(parts) == 0 || len(parts) > MaxPlaces {
		panic("splits: 1 to 10 places, e.g. 50,30,20")
	}
	out := make([]int, 0, len(parts))
	sum := 0
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n <= 0 {
			panic("splits: each place must be a positive integer percent")
		}
		if i > 0 && n > out[i-1] {
			panic("splits: a lower place cannot pay more than a higher one")
		}
		out = append(out, n)
		sum += n
	}
	if sum != 100 {
		panic("splits must sum to 100")
	}
	return out
}

func mustBounty(id int) *Bounty {
	b, ok := bounties.Get(key(id)).(*Bounty)
	if !ok || b == nil {
		panic("bounty not found")
	}
	return b
}

// mustJudging checks the caller is the judge and the bounty is in its judging window.
func mustJudging(cur realm, id int) *Bounty {
	b := mustBounty(id)
	if cur.Previous().Address() != b.Judge {
		panic("only the judge can do this")
	}
	now := time.Now()
	if b.Status != StatusOpen || now.Before(b.Deadline) {
		panic("bounty is not in judging (wait for the deadline)")
	}
	if !now.Before(b.JudgeBy) {
		panic("judging window is over; use Fallback")
	}
	return b
}

func mustEntry(b *Bounty, agent string) *Entry {
	e, ok := b.entries.Get(strings.TrimSpace(agent)).(*Entry)
	if !ok || e == nil {
		panic("entry not found")
	}
	return e
}

func agentOf(addr address) *Agent {
	return agents.Get(addr.String()).(*Agent)
}

func moveToEnd(list []address, a address) []address {
	out := make([]address, 0, len(list))
	for _, x := range list {
		if x != a {
			out = append(out, x)
		}
	}
	return append(out, a)
}

func mustLen(field, s string, min, max int) {
	if len(s) < min || len(s) > max {
		panic(ufmt.Sprintf("%s must be %d-%d characters", field, min, max))
	}
	if strings.ContainsAny(s, "\n\r") {
		panic(field + " must be a single line")
	}
}

func key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

// Phase returns the live phase of a bounty, derived from time.
func Phase(id int) string {
	return phase(mustBounty(id))
}

func phase(b *Bounty) string {
	if b.Status != StatusOpen {
		return b.Status
	}
	now := time.Now()
	if now.Before(b.Deadline) {
		return StatusOpen
	}
	if now.Before(b.JudgeBy) {
		return StatusJudging
	}
	return "awaiting-fallback"
}
