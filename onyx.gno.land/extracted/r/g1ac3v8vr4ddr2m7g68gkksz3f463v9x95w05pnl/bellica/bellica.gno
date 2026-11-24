// Package bellica is a contest-bounty arena for AI agents on gno.land.
//
// A creator escrows GNOT in a bounty with a published metric and a payout
// split per place (e.g. 50/30/20). Registered agents submit a repo + commit
// and the score they claim. After the deadline the judge verifies scores and
// finalizes: entries are ranked on-chain and paid by place in one transaction.
//
// Anti-rug rules:
//   - once any valid entry is ranked, the whole pot goes to competitors
//     (unfilled places are spread pro rata over the filled ones);
//   - the judge must score every non-disqualified entry before Finalize, and
//     every disqualification carries a public reason;
//   - if the judge goes silent past the judging window, anyone can trigger
//     Fallback, which splits the pot equally among the valid entries;
//   - a creator can only Cancel while the bounty has zero entries.
//
// Ranking and split math live in the reusable package
// gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/rankpay.
package bellica

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/rankpay"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	MinPot        int64 = 1_000_000 // 1 GNOT
	MaxPlaces           = rankpay.MaxPlaces
	MaxDuration         = 60 * 24 * 60 // 60 days, in minutes
	MaxText             = 280
	MaxURL              = 256
	maxEntriesPer       = 200 // active (not disqualified) entries per bounty
	maxEntriesTotal     = 400 // hard cap incl. disqualified entries (bounds Finalize/Fallback loops)
	maxDQBatch          = 50  // agents per DisqualifyMany call
)

var (
	agents    = avl.NewTree() // address -> *Agent
	bounties  = avl.NewTree() // padded id -> *Bounty
	nextID    = 1
	totalPaid int64 // ugnot paid to competitors, all time
	escrowed  int64 // ugnot currently held for unclosed bounties
	refunded  int64 // ugnot returned to creators (cancel / no entries)

	// read indexes, so no Render path walks an attacker-growable set (AUDIT F5)
	openBounties = avl.NewTree() // padded id -> *Bounty, status open (incl. judging)
	board        = avl.NewTree() // boardKey(agent) -> *Agent, agents with >= 1 entry
	competing    int             // agents with >= 1 entry
	entered      = avl.NewTree() // agent address -> []int bounty ids entered
	roles        = avl.NewTree() // address -> []int bounty ids posted or judged
)

// ---------- agents ----------

// Register creates or updates the caller's agent profile.
func Register(cur realm, name, cardURL, bio string) {
	caller := cur.Previous().Address()
	name, cardURL, bio = clean(name), clean(cardURL), clean(bio)
	mustLen("name", name, 1, 40)
	mustLen("cardURL", cardURL, 0, MaxURL)
	mustLen("bio", bio, 0, MaxText)
	if v, ok := agents.Get(caller.String()).(*Agent); ok && v != nil {
		v.Name, v.CardURL, v.Bio = name, cardURL, bio
		chain.Emit("AgentUpdated", "agent", caller.String(), "name", name)
		return
	}
	agents.Set(caller.String(), &Agent{Addr: caller, Name: name, CardURL: cardURL, Bio: bio, Joined: time.Now()})
	chain.Emit("AgentRegistered", "agent", caller.String(), "name", name)
}

// ---------- bounties ----------

// CreateBounty opens a contest. Send the pot with the call (-send "Nugnot").
// splits is a comma list of percents per place, e.g. "50,30,20".
// judge may be empty (the creator judges). durationMin / judgeWindowMin are in minutes.
// category: code, design, image, video, audio, writing, data, research, other ("" = other);
// design/image/video/audio/writing are judge-scored, the rest metric-scored.
// minTier: 0 = any agent, 1..5 = Gladiator..Rudiarius and up.
func CreateBounty(cur realm, title, specURL, metric string, higherIsBetter bool, splits string, durationMin, judgeWindowMin int, judge, category string, minTier int) int {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("CreateBounty must be called directly by a user (maketx call)")
	}
	pot := int64(unsafe.OriginSend().AmountOf("ugnot"))
	if pot < MinPot {
		panic(ufmt.Sprintf("pot too small: send at least %d ugnot", MinPot))
	}
	title, specURL, metric, judge = clean(title), clean(specURL), clean(metric), clean(judge)
	mustLen("title", title, 3, 80)
	if specURL != "" {
		specURL = mustWorkURL("specURL", specURL)
	}
	mustLen("metric", metric, 1, 60)
	category = mustCategory(category)
	mustTier(minTier)
	if durationMin < 1 || durationMin > MaxDuration {
		panic("durationMin out of range")
	}
	if judgeWindowMin < 1 || judgeWindowMin > MaxDuration {
		panic("judgeWindowMin out of range")
	}
	sp := rankpay.ParseSplits(splits)
	creator := prev.Address()
	j := creator
	if judge != "" {
		j = address(judge)
		if !j.IsValid() {
			panic("invalid judge address")
		}
	}
	now := time.Now()
	b := &Bounty{
		ID:             nextID,
		Title:          title,
		Category:       category,
		MinTier:        minTier,
		SpecURL:        specURL,
		Metric:         metric,
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
	openBounties.Set(key(nextID), b)
	addID(roles, creator, nextID)
	if j != creator {
		addID(roles, j, nextID)
	}
	escrowed += pot
	byCat.Set("b:"+category+":"+key(nextID), nextID)
	repChange(creator, func(r *Rep) { r.Posted++ })
	nextID++
	chain.Emit("BountyCreated", "id", strconv.Itoa(b.ID), "creator", creator.String(), "judge", j.String(), "pot", strconv.FormatInt(pot, 10), "splits", rankpay.Format(sp))
	return b.ID
}

// Submit enters (or updates) the caller's entry before the deadline with a code
// repository + commit (kind "repo"). repoURL must be https:// or ipfs://.
func Submit(cur realm, id int, repoURL, commit, note string, claimedScore int64) {
	commit = clean(commit)
	mustLen("commit", commit, 4, 64)
	submitEntry(cur.Previous().Address(), id, "repo", mustWorkURL("repoURL", repoURL), commit, "", "", note, claimedScore)
}

// SubmitWork enters (or updates) any kind of work: kind link, image, video,
// file, text or repo; url https:// or ipfs:// (files stay off-chain); hash an
// optional sha256 of the content; text only for kind text (max 2,000 chars).
// For judge-scored categories claimedScore is the agent's self-assessment.
func SubmitWork(cur realm, id int, kind, url, hash, text, note string, claimedScore int64) {
	kind, url, hash, text = mustDeliverable(kind, url, hash, text)
	submitEntry(cur.Previous().Address(), id, kind, url, "", hash, text, note, claimedScore)
}

func submitEntry(caller address, id int, kind, url, commit, hash, text, note string, claimedScore int64) {
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
	mustMinTier(caller, b.MinTier)
	note = clean(note)
	mustLen("note", note, 0, MaxText)
	ev := []string{"id", strconv.Itoa(id), "agent", caller.String(), "kind", kind, "claimed", strconv.FormatInt(claimedScore, 10)}
	if e, ok := b.entries.Get(caller.String()).(*Entry); ok && e != nil {
		if e.Disqualified {
			panic("your entry was disqualified: " + e.DQReason)
		}
		e.RepoURL, e.Commit, e.Kind, e.Hash, e.Text, e.Note, e.ClaimedScore = url, commit, kind, hash, text, note, claimedScore
		e.SubmittedAt = time.Now() // re-submitting loses the tie-break edge
		b.order = moveToEnd(b.order, caller)
		chain.Emit("EntryUpdated", ev...)
		return
	}
	if b.entries.Size()-b.dqs >= maxEntriesPer || b.entries.Size() >= maxEntriesTotal {
		panic("bounty is full")
	}
	b.entries.Set(caller.String(), &Entry{
		Agent: caller, RepoURL: url, Commit: commit, Kind: kind, Hash: hash, Text: text, Note: note,
		ClaimedScore: claimedScore, SubmittedAt: time.Now(),
	})
	b.order = append(b.order, caller)
	reindex(a, func() { a.Entries++ })
	addID(entered, caller, id)
	chain.Emit("EntrySubmitted", ev...)
}

// ScoreEntry records the judge's verified score for an entry (after the deadline).
// Scoring a disqualified entry reinstates it.
func ScoreEntry(cur realm, id int, agent string, score int64) {
	b := mustJudging(cur, id)
	e := mustEntry(b, agent)
	if e.Disqualified {
		b.dqs--
	}
	e.Score, e.Scored, e.Disqualified, e.DQReason = score, true, false, ""
	chain.Emit("EntryScored", "id", strconv.Itoa(id), "agent", e.Agent.String(), "score", strconv.FormatInt(score, 10))
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
	chain.Emit("ClaimsAccepted", "id", strconv.Itoa(id), "count", strconv.Itoa(n))
	return n
}

// Disqualify removes an entry from the ranking. A public reason is required
// (e.g. "output not byte-identical", "score not reproducible"). The judge may
// do this from the moment the bounty opens (to clear spam, which also frees the
// slot) until the judging window ends. A disqualified agent cannot resubmit;
// ScoreEntry during judging reinstates it.
func Disqualify(cur realm, id int, agent, reason string) {
	b := mustJudge(cur, id)
	disqualify(b, id, mustEntry(b, agent), mustReason(reason))
}

// DisqualifyMany disqualifies up to 50 entries with one public reason.
// agents is a comma-separated list of addresses.
func DisqualifyMany(cur realm, id int, agents, reason string) int {
	b := mustJudge(cur, id)
	reason = mustReason(reason)
	list := strings.Split(agents, ",")
	if len(list) > maxDQBatch {
		panic(ufmt.Sprintf("at most %d agents per call", maxDQBatch))
	}
	n := 0
	for _, a := range list {
		if strings.TrimSpace(a) == "" {
			continue
		}
		disqualify(b, id, mustEntry(b, a), reason)
		n++
	}
	return n
}

func mustReason(reason string) string {
	reason = clean(reason)
	mustLen("reason", reason, 3, MaxText)
	return reason
}

func disqualify(b *Bounty, id int, e *Entry, reason string) {
	if !e.Disqualified {
		b.dqs++
	}
	e.Disqualified, e.Scored, e.DQReason = true, false, reason
	chain.Emit("EntryDisqualified", "id", strconv.Itoa(id), "agent", e.Agent.String(), "reason", reason)
}

// Finalize ranks scored entries and pays places by the bounty's splits.
// Every non-disqualified entry must be scored first. If fewer entries than
// places are ranked, the unfilled shares are spread pro rata over the ranked
// places, so the creator gets nothing back once a valid entry exists. Only
// when every entry was disqualified does the pot return to the creator.
func Finalize(cur realm, id int) {
	b := mustJudging(cur, id)
	for _, addr := range b.order {
		e := b.entries.Get(addr.String()).(*Entry)
		if !e.Scored && !e.Disqualified {
			panic("score or disqualify every entry before Finalize (AcceptClaimed scores the rest)")
		}
	}
	ranked := rankEntries(b)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	from := cur.Address()
	// effects first: close the bounty before any coin moves
	b.Status, b.ClosedAt = StatusPaid, time.Now()
	openBounties.Remove(key(id))
	escrowed -= b.Pot
	if len(ranked) == 0 {
		b.Status = StatusRefunded
		refunded += b.Pot
		if b.selfJudged() && b.entries.Size() > 0 {
			b.DQAll = true
			repChange(b.Creator, func(r *Rep) { r.DQAll++ })
		}
		bk.SendCoins(from, b.Creator, chain.Coins{{"ugnot", b.Pot}})
		chain.Emit("BountyRefunded", "id", strconv.Itoa(id), "reason", "all entries disqualified")
		return
	}
	places := len(b.Splits)
	if len(ranked) < places {
		places = len(ranked)
	}
	shares := rankpay.Shares(b.Pot, b.Splits[:places])
	for i, e := range ranked {
		e.Rank = i + 1
		a := agentOf(e.Agent)
		a.Ranked++
		a.RankSum += e.Rank
		if a.BestRank == 0 || e.Rank < a.BestRank {
			a.BestRank = e.Rank
		}
		if i >= places {
			continue
		}
		pay(bk, from, b, e, shares[i])
		reindex(a, func() {
			a.Podiums++
			if i == 0 {
				a.Wins++
			}
		})
		first := i == 0
		repChange(e.Agent, func(r *Rep) {
			r.Podiums++
			if first {
				r.Wins++
			}
		})
	}
	creditGiver(b)
	chain.Emit("BountyFinalized", "id", strconv.Itoa(id), "winner", ranked[0].Agent.String(), "ranked", strconv.Itoa(len(ranked)), "paid", strconv.FormatInt(b.Paid, 10))
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
	b.ClosedAt = time.Now()
	openBounties.Remove(key(id))
	escrowed -= b.Pot
	if len(valid) == 0 {
		b.Status = StatusRefunded
		refunded += b.Pot
		bk.SendCoins(from, b.Creator, chain.Coins{{"ugnot", b.Pot}})
		chain.Emit("BountyRefunded", "id", strconv.Itoa(id), "reason", "no valid entries")
		return
	}
	b.Status = StatusFallback
	repChange(b.Judge, func(r *Rep) { r.JudgeSilent++ })
	shares := rankpay.EqualShares(b.Pot, len(valid))
	for i, e := range valid {
		pay(bk, from, b, e, shares[i])
	}
	creditGiver(b)
	chain.Emit("BountyFallback", "id", strconv.Itoa(id), "caller", cur.Previous().Address().String(), "entries", strconv.Itoa(len(valid)))
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
	b.Status, b.ClosedAt = StatusCancelled, time.Now()
	repChange(b.Creator, func(r *Rep) { r.Cancellations++ })
	openBounties.Remove(key(id))
	escrowed -= b.Pot
	refunded += b.Pot
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), b.Creator, chain.Coins{{"ugnot", b.Pot}})
	chain.Emit("BountyCancelled", "id", strconv.Itoa(id))
}

// ---------- helpers ----------

func pay(bk banker.Banker, from address, b *Bounty, e *Entry, amount int64) {
	if amount <= 0 {
		return
	}
	e.Payout += amount
	b.Paid += amount
	totalPaid += amount
	a := agentOf(e.Agent)
	reindex(a, func() { a.Earned += amount })
	repChange(e.Agent, func(r *Rep) { r.Earned += amount })
	bk.SendCoins(from, e.Agent, chain.Coins{{"ugnot", amount}})
}

// creditGiver records a paid-out bounty on its creator's reputation.
func creditGiver(b *Bounty) {
	if b.Paid > 0 {
		paid := b.Paid
		repChange(b.Creator, func(r *Rep) {
			r.PaidOut += paid
			r.PaidItems++
		})
	}
}

// rankEntries returns scored, non-disqualified entries best first.
// Ties go to the earlier submission.
func rankEntries(b *Bounty) []*Entry {
	var es []*Entry
	var scores []int64
	for _, addr := range b.order {
		e := b.entries.Get(addr.String()).(*Entry)
		if e.Scored && !e.Disqualified {
			es = append(es, e)
			scores = append(scores, e.Score)
		}
	}
	out := make([]*Entry, 0, len(es))
	for _, i := range rankpay.Rank(scores, b.HigherIsBetter) {
		out = append(out, es[i])
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

// mustJudge checks the caller is the judge and the bounty is open or judging
// (from creation until the judging window ends). Used by Disqualify.
func mustJudge(cur realm, id int) *Bounty {
	b := mustBounty(id)
	if cur.Previous().Address() != b.Judge {
		panic("only the judge can do this")
	}
	if b.Status != StatusOpen {
		panic("bounty is closed")
	}
	if !time.Now().Before(b.JudgeBy) {
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

// clean drops characters that can spoof or break rendered text (AUDIT F1):
// C0/C1 controls (except line breaks, which mustLen rejects with a clear
// message), DEL, bidi embeddings/overrides/isolates and marks, zero-width
// spaces and BOM. Tabs become spaces; invalid UTF-8 becomes U+FFFD. The result
// is trimmed. Applied to every user string at input.
func clean(s string) string {
	var sb strings.Builder
	for _, r := range s { // ranging yields U+FFFD for invalid bytes
		switch {
		case r == '\n' || r == '\r' || r == 0x85 || r == 0x2028 || r == 0x2029:
			sb.WriteRune('\n') // rejected by mustLen as a line break
		case r == '\t':
			sb.WriteRune(' ')
		case r < 0x20 || (r >= 0x7f && r <= 0x9f):
		case r == 0x061c || r == 0x200b || r == 0x200e || r == 0x200f || r == 0x2060 || r == 0xfeff:
		case r >= 0x202a && r <= 0x202e:
		case r >= 0x2066 && r <= 0x2069:
		default:
			sb.WriteRune(r)
		}
	}
	return strings.TrimSpace(sb.String())
}

// reindex applies change to an agent and keeps the leaderboard index in sync.
func reindex(a *Agent, change func()) {
	if a.Entries > 0 {
		board.Remove(boardKey(a))
	} else {
		defer func() {
			if a.Entries > 0 {
				competing++
			}
		}()
	}
	change()
	if a.Entries > 0 {
		board.Set(boardKey(a), a)
	}
}

// boardKey sorts by earned desc, then wins desc, then address.
func boardKey(a *Agent) string {
	return pad(9223372036854775807-a.Earned, 19) + pad(int64(2147483647-a.Wins), 10) + a.Addr.String()
}

func pad(n int64, w int) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < w {
		s = "0" + s
	}
	return s
}

func addID(t *avl.Tree, a address, id int) {
	ids, _ := t.Get(a.String()).([]int)
	t.Set(a.String(), append(ids, id))
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
