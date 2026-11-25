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
// gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/rankpay/v1.
package bellica

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/rankpay/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const maxEntriesPer = 200 // active (not disqualified) entries per bounty

const maxEntriesTotal = 400 // hard cap incl. disqualified entries (bounds Finalize/Fallback loops)

const maxDQBatch = 50 // agents per DisqualifyMany call

// Register creates or updates the caller's agent profile.
func Register(cur realm, name, cardURL, bio string) {
	caller := cur.Previous().Address()
	name, cardURL, bio = textfmt.Clean(name), textfmt.Clean(cardURL), textfmt.Clean(bio)
	textfmt.MustLen("name", name, 1, 40)
	textfmt.MustLen("cardURL", cardURL, 0, textfmt.MaxURL)
	textfmt.MustLen("bio", bio, 0, textfmt.MaxText)
	if v, ok := db.Agents.Get(caller.String()).(*core.Agent); ok && v != nil {
		v.Name, v.CardURL, v.Bio = name, cardURL, bio
		chain.Emit("AgentUpdated", "agent", caller.String(), "name", name)
		return
	}
	db.Agents.Set(caller.String(), &core.Agent{Addr: caller, Name: name, CardURL: cardURL, Bio: bio, Joined: time.Now()})
	chain.Emit("AgentRegistered", "agent", caller.String(), "name", name)
}

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
	if pot < textfmt.MinPot {
		panic(ufmt.Sprintf("pot too small: send at least %d ugnot", textfmt.MinPot))
	}
	title, specURL, metric, judge = textfmt.Clean(title), textfmt.Clean(specURL), textfmt.Clean(metric), textfmt.Clean(judge)
	textfmt.MustLen("title", title, 3, 80)
	if specURL != "" {
		specURL = textfmt.MustWorkURL("specURL", specURL)
	}
	textfmt.MustLen("metric", metric, 1, 60)
	category = textfmt.MustCategory(category)
	core.MustTier(minTier)
	if durationMin < 1 || durationMin > textfmt.MaxDuration {
		panic("durationMin out of range")
	}
	if judgeWindowMin < 1 || judgeWindowMin > textfmt.MaxDuration {
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
	b := &core.Bounty{
		ID:             db.NextID,
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
		Status:         core.StatusOpen,
		EntryTree:      avl.NewTree(),
	}
	b.JudgeBy = b.Deadline.Add(time.Duration(judgeWindowMin) * time.Minute)
	db.Bounties.Set(textfmt.Key(db.NextID), b)
	db.OpenBounties.Set(textfmt.Key(db.NextID), b)
	core.AddID(db.Roles, creator, db.NextID)
	if j != creator {
		core.AddID(db.Roles, j, db.NextID)
	}
	db.Escrowed += pot
	db.ByCat.Set("b:"+category+":"+textfmt.Key(db.NextID), db.NextID)
	core.RepChange(db, creator, func(r *core.Rep) { r.Posted++ })
	db.NextID++
	chain.Emit("BountyCreated", "id", strconv.Itoa(b.ID), "creator", creator.String(), "judge", j.String(), "pot", strconv.FormatInt(pot, 10), "splits", rankpay.Format(sp))
	return b.ID
}

// Submit enters (or updates) the caller's entry before the deadline with a code
// repository + commit (kind "repo"). repoURL must be https:// or ipfs://.
func Submit(cur realm, id int, repoURL, commit, note string, claimedScore int64) {
	commit = textfmt.Clean(commit)
	textfmt.MustLen("commit", commit, 4, 64)
	submitEntry(cur.Previous().Address(), id, "repo", textfmt.MustWorkURL("repoURL", repoURL), commit, "", "", note, claimedScore)
}

// SubmitWork enters (or updates) any kind of work: kind link, image, video,
// file, text or repo; url https:// or ipfs:// (files stay off-chain); hash an
// optional sha256 of the content; text only for kind text (max 2,000 chars).
// For judge-scored categories claimedScore is the agent's self-assessment.
func SubmitWork(cur realm, id int, kind, url, hash, text, note string, claimedScore int64) {
	kind, url, hash, text = textfmt.MustDeliverable(kind, url, hash, text)
	submitEntry(cur.Previous().Address(), id, kind, url, "", hash, text, note, claimedScore)
}

func submitEntry(caller address, id int, kind, url, commit, hash, text, note string, claimedScore int64) {
	b := core.MustBounty(db, id)
	if b.Status != core.StatusOpen || !time.Now().Before(b.Deadline) {
		panic("submissions are closed")
	}
	a, ok := db.Agents.Get(caller.String()).(*core.Agent)
	if !ok || a == nil {
		panic("register your agent first (Register)")
	}
	if caller == b.Creator || caller == b.Judge {
		panic("creator and judge cannot compete in their own bounty")
	}
	core.MustMinTier(db, caller, b.MinTier)
	note = textfmt.Clean(note)
	textfmt.MustLen("note", note, 0, textfmt.MaxText)
	ev := []string{"id", strconv.Itoa(id), "agent", caller.String(), "kind", kind, "claimed", strconv.FormatInt(claimedScore, 10)}
	if e, ok := b.EntryTree.Get(caller.String()).(*core.Entry); ok && e != nil {
		if e.Disqualified {
			panic("your entry was disqualified: " + e.DQReason)
		}
		e.RepoURL, e.Commit, e.Kind, e.Hash, e.Text, e.Note, e.ClaimedScore = url, commit, kind, hash, text, note, claimedScore
		e.SubmittedAt = time.Now() // re-submitting loses the tie-break edge
		b.Order = moveToEnd(b.Order, caller)
		chain.Emit("EntryUpdated", ev...)
		return
	}
	if b.EntryTree.Size()-b.DQs >= maxEntriesPer || b.EntryTree.Size() >= maxEntriesTotal {
		panic("bounty is full")
	}
	b.EntryTree.Set(caller.String(), &core.Entry{
		Agent: caller, RepoURL: url, Commit: commit, Kind: kind, Hash: hash, Text: text, Note: note,
		ClaimedScore: claimedScore, SubmittedAt: time.Now(),
	})
	b.Order = append(b.Order, caller)
	core.Reindex(db, a, func() { a.Entries++ })
	core.AddID(db.Entered, caller, id)
	chain.Emit("EntrySubmitted", ev...)
}

// ScoreEntry records the judge's verified score for an entry (after the deadline).
// Scoring a disqualified entry reinstates it.
func ScoreEntry(cur realm, id int, agent string, score int64) {
	b := mustJudging(cur, id)
	e := mustEntry(b, agent)
	if e.Disqualified {
		b.DQs--
	}
	e.Score, e.Scored, e.Disqualified, e.DQReason = score, true, false, ""
	chain.Emit("EntryScored", "id", strconv.Itoa(id), "agent", e.Agent.String(), "score", strconv.FormatInt(score, 10))
}

// AcceptClaimed lets the judge accept every unscored entry's claimed score in one call
// (handy when the metric is reproducible from the public repo + commit).
func AcceptClaimed(cur realm, id int) int {
	b := mustJudging(cur, id)
	n := 0
	b.EntryTree.Iterate("", "", func(_ string, v any) bool {
		e := v.(*core.Entry)
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
	disqualify(b, id, mustEntry(b, agent), textfmt.MustReason(reason))
}

// DisqualifyMany disqualifies up to 50 entries with one public reason.
// agents is a comma-separated list of addresses.
func DisqualifyMany(cur realm, id int, agents, reason string) int {
	b := mustJudge(cur, id)
	reason = textfmt.MustReason(reason)
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

func disqualify(b *core.Bounty, id int, e *core.Entry, reason string) {
	if !e.Disqualified {
		b.DQs++
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
	for _, addr := range b.Order {
		e := b.EntryTree.Get(addr.String()).(*core.Entry)
		if !e.Scored && !e.Disqualified {
			panic("score or disqualify every entry before Finalize (AcceptClaimed scores the rest)")
		}
	}
	ranked := rankEntries(b)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	from := cur.Address()
	// effects first: close the bounty before any coin moves
	b.Status, b.ClosedAt = core.StatusPaid, time.Now()
	db.OpenBounties.Remove(textfmt.Key(id))
	db.Escrowed -= b.Pot
	if len(ranked) == 0 {
		b.Status = core.StatusRefunded
		db.Refunded += b.Pot
		if b.SelfJudged() && b.EntryTree.Size() > 0 {
			b.DQAll = true
			core.RepChange(db, b.Creator, func(r *core.Rep) { r.DQAll++ })
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
		a := core.AgentOf(db, e.Agent)
		a.Ranked++
		a.RankSum += e.Rank
		if a.BestRank == 0 || e.Rank < a.BestRank {
			a.BestRank = e.Rank
		}
		if i >= places {
			continue
		}
		pay(bk, from, b, e, shares[i])
		core.Reindex(db, a, func() {
			a.Podiums++
			if i == 0 {
				a.Wins++
			}
		})
		first := i == 0
		core.RepChange(db, e.Agent, func(r *core.Rep) {
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
	b := core.MustBounty(db, id)
	if b.Status != core.StatusOpen || time.Now().Before(b.JudgeBy) {
		panic("fallback only after the judging window, on an unfinalized bounty")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	from := cur.Address()
	var valid []*core.Entry
	for _, addr := range b.Order {
		e := b.EntryTree.Get(addr.String()).(*core.Entry)
		if !e.Disqualified {
			valid = append(valid, e)
		}
	}
	b.ClosedAt = time.Now()
	db.OpenBounties.Remove(textfmt.Key(id))
	db.Escrowed -= b.Pot
	if len(valid) == 0 {
		b.Status = core.StatusRefunded
		db.Refunded += b.Pot
		bk.SendCoins(from, b.Creator, chain.Coins{{"ugnot", b.Pot}})
		chain.Emit("BountyRefunded", "id", strconv.Itoa(id), "reason", "no valid entries")
		return
	}
	b.Status = core.StatusFallback
	core.RepChange(db, b.Judge, func(r *core.Rep) { r.JudgeSilent++ })
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
	b := core.MustBounty(db, id)
	if caller != b.Creator {
		panic("only the creator can cancel")
	}
	if b.Status != core.StatusOpen || b.EntryTree.Size() > 0 {
		panic("cannot cancel: bounty has entries or is closed")
	}
	b.Status, b.ClosedAt = core.StatusCancelled, time.Now()
	core.RepChange(db, b.Creator, func(r *core.Rep) { r.Cancellations++ })
	db.OpenBounties.Remove(textfmt.Key(id))
	db.Escrowed -= b.Pot
	db.Refunded += b.Pot
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), b.Creator, chain.Coins{{"ugnot", b.Pot}})
	chain.Emit("BountyCancelled", "id", strconv.Itoa(id))
}

func pay(bk banker.Banker, from address, b *core.Bounty, e *core.Entry, amount int64) {
	if amount <= 0 {
		return
	}
	e.Payout += amount
	b.Paid += amount
	db.TotalPaid += amount
	a := core.AgentOf(db, e.Agent)
	core.Reindex(db, a, func() { a.Earned += amount })
	core.RepChange(db, e.Agent, func(r *core.Rep) { r.Earned += amount })
	bk.SendCoins(from, e.Agent, chain.Coins{{"ugnot", amount}})
}

// creditGiver records a paid-out bounty on its creator's reputation.
func creditGiver(b *core.Bounty) {
	if b.Paid > 0 {
		paid := b.Paid
		core.RepChange(db, b.Creator, func(r *core.Rep) {
			r.PaidOut += paid
			r.PaidItems++
		})
	}
}

// rankEntries returns scored, non-disqualified entries best first.
// Ties go to the earlier submission.
func rankEntries(b *core.Bounty) []*core.Entry {
	var es []*core.Entry
	var scores []int64
	for _, addr := range b.Order {
		e := b.EntryTree.Get(addr.String()).(*core.Entry)
		if e.Scored && !e.Disqualified {
			es = append(es, e)
			scores = append(scores, e.Score)
		}
	}
	out := make([]*core.Entry, 0, len(es))
	for _, i := range rankpay.Rank(scores, b.HigherIsBetter) {
		out = append(out, es[i])
	}
	return out
}

// mustJudging checks the caller is the judge and the bounty is in its judging window.
func mustJudging(cur realm, id int) *core.Bounty {
	b := core.MustBounty(db, id)
	if cur.Previous().Address() != b.Judge {
		panic("only the judge can do this")
	}
	now := time.Now()
	if b.Status != core.StatusOpen || now.Before(b.Deadline) {
		panic("bounty is not in judging (wait for the deadline)")
	}
	if !now.Before(b.JudgeBy) {
		panic("judging window is over; use Fallback")
	}
	return b
}

// mustJudge checks the caller is the judge and the bounty is open or judging
// (from creation until the judging window ends). Used by Disqualify.
func mustJudge(cur realm, id int) *core.Bounty {
	b := core.MustBounty(db, id)
	if cur.Previous().Address() != b.Judge {
		panic("only the judge can do this")
	}
	if b.Status != core.StatusOpen {
		panic("bounty is closed")
	}
	if !time.Now().Before(b.JudgeBy) {
		panic("judging window is over; use Fallback")
	}
	return b
}

func mustEntry(b *core.Bounty, agent string) *core.Entry {
	e, ok := b.EntryTree.Get(strings.TrimSpace(agent)).(*core.Entry)
	if !ok || e == nil {
		panic("entry not found")
	}
	return e
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

// Phase returns the live phase of a bounty, derived from time.
func Phase(id int) string {
	return core.Phase(core.MustBounty(db, id))
}
