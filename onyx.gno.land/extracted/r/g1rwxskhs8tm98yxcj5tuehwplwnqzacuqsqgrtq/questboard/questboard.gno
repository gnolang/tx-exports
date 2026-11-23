// Package questboard is an escrowed bounty board for Gno.land.
//
// Anyone can post a quest (a task) and lock ugnot as its reward. Anyone else
// can add to the reward, and hunters submit proof of work (a link and a note).
// The poster, or an optional arbiter named at creation, pays the full escrow
// to one hunter with Award. If the quest is cancelled, or if nobody decides
// within GracePeriod after the deadline, every contributor gets back exactly
// what they put in.
//
// Every address gets a public track record: how much it has paid out, how
// often it cancelled after work was submitted, how often it ghosted hunters,
// and how much it has earned as a hunter. That is the trust layer: hunters can
// see whether a poster actually pays before they start working.
package questboard

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	Denom             = "ugnot"
	MinReward   int64 = 100_000 // 0.1 GNOT
	MinTopUp    int64 = 10_000  // 0.01 GNOT
	MinDays           = 1
	MaxDays           = 90
	GracePeriod       = 7 * 24 * time.Hour

	MaxTitleLen    = 80
	MaxBodyLen     = 4000
	MaxLinkLen     = 300
	MaxNoteLen     = 500
	MaxReasonLen   = 200
	MaxSubmissions = 50
	MaxContribs    = 32
	maxRecent      = 20
)

var (
	nextID   seqid.ID
	quests   avl.Tree // seqid binary -> *Quest
	open     avl.Tree // seqid binary -> *Quest, open quests only
	closed   []int    // latest closed quest ids (bounded)
	profiles avl.Tree // address string -> *Profile

	openCount int
	escrowed  int64 // ugnot currently locked in open quests
	paidOut   int64 // ugnot paid to hunters, all time
	refunded  int64 // ugnot refunded to contributors, all time
	completed int   // quests awarded, all time
)

// PostQuest creates a quest and locks the ugnot sent with the transaction as
// its reward. days is how long hunters have to submit (1-90). arbiter is
// optional (leave empty): if set, that address can also award, reject or
// cancel, which lets a neutral party settle the quest.
//
//	gnokey maketx call -pkgpath <this realm> -func PostQuest \
//	  -args "Fix typo in README" -args "details..." -args 7 -args "" \
//	  -send 1000000ugnot ...
func PostQuest(cur realm, title, body string, days int, arbiter string) int {
	poster := cur.Previous().Address()
	amount := mustReceive(cur, MinReward)

	title = strings.TrimSpace(title)
	body = strings.TrimSpace(body)
	if title == "" {
		panic("title is required")
	}
	if len(title) > MaxTitleLen {
		panic("title too long (max " + strconv.Itoa(MaxTitleLen) + " bytes)")
	}
	if len(body) > MaxBodyLen {
		panic("body too long (max " + strconv.Itoa(MaxBodyLen) + " bytes)")
	}
	if days < MinDays || days > MaxDays {
		panic("days must be between " + strconv.Itoa(MinDays) + " and " + strconv.Itoa(MaxDays))
	}
	var arb address
	arbiter = strings.TrimSpace(arbiter)
	if arbiter != "" {
		arb = address(arbiter)
		if !arb.IsValid() {
			panic("invalid arbiter address")
		}
		if arb == poster {
			panic("arbiter must be someone other than the poster")
		}
	}

	now := time.Now()
	id := int(nextID.Next())
	q := &Quest{
		ID:        id,
		Poster:    poster,
		Arbiter:   arb,
		Title:     title,
		Body:      body,
		CreatedAt: now,
		Deadline:  now.Add(time.Duration(days) * 24 * time.Hour),
		Reward:    amount,
		Contribs:  []Contribution{{From: poster, Amount: amount}},
		Status:    StatusOpen,
	}
	quests.Set(key(id), q)
	open.Set(key(id), q)
	openCount++
	escrowed += amount

	p := profileOf(poster)
	p.Posted++
	p.Recent = append(p.Recent, id)
	if len(p.Recent) > maxRecent {
		p.Recent = p.Recent[len(p.Recent)-maxRecent:]
	}

	chain.Emit("QuestPosted",
		"id", strconv.Itoa(id),
		"poster", poster.String(),
		"reward", strconv.FormatInt(amount, 10),
		"deadline", q.Deadline.UTC().Format(time.RFC3339),
	)
	return id
}

// Fund adds the ugnot sent with the transaction to an open quest's reward.
// If the quest is later cancelled or expires, the funder is refunded.
func Fund(cur realm, id int) {
	funder := cur.Previous().Address()
	amount := mustReceive(cur, MinTopUp)
	q := mustOpen(id)
	if q.pastDeadline(time.Now()) {
		panic("quest deadline has passed")
	}

	found := false
	for i := range q.Contribs {
		if q.Contribs[i].From == funder {
			q.Contribs[i].Amount += amount
			found = true
			break
		}
	}
	if !found {
		if len(q.Contribs) >= MaxContribs {
			panic("too many contributors on this quest")
		}
		q.Contribs = append(q.Contribs, Contribution{From: funder, Amount: amount})
	}
	q.Reward += amount
	escrowed += amount
	if funder != q.Poster {
		profileOf(funder).Funded += amount
	}

	chain.Emit("QuestFunded",
		"id", strconv.Itoa(id),
		"funder", funder.String(),
		"amount", strconv.FormatInt(amount, 10),
		"reward", strconv.FormatInt(q.Reward, 10),
	)
}

// Submit records (or updates) the caller's proof of work for a quest.
// link must be an http(s) URL, e.g. a merge request, commit or demo.
func Submit(cur realm, id int, link, note string) {
	hunter := cur.Previous().Address()
	q := mustOpen(id)
	if q.pastDeadline(time.Now()) {
		panic("quest deadline has passed")
	}
	if q.isManager(hunter) {
		panic("the poster or arbiter cannot submit to their own quest")
	}
	link = strings.TrimSpace(link)
	note = strings.TrimSpace(note)
	if len(link) > MaxLinkLen {
		panic("link too long (max " + strconv.Itoa(MaxLinkLen) + " bytes)")
	}
	if !strings.HasPrefix(link, "https://") && !strings.HasPrefix(link, "http://") {
		panic("link must start with https:// or http://")
	}
	if sanitize.URL(link) == "" {
		panic("invalid link")
	}
	if len(note) > MaxNoteLen {
		panic("note too long (max " + strconv.Itoa(MaxNoteLen) + " bytes)")
	}

	now := time.Now()
	if s := q.findSub(hunter); s != nil {
		s.Link, s.Note, s.At = link, note, now
		s.Rejected, s.Reason = false, ""
	} else {
		if len(q.Subs) >= MaxSubmissions {
			panic("this quest has reached its submission limit")
		}
		q.Subs = append(q.Subs, &Submission{Hunter: hunter, Link: link, Note: note, At: now})
		profileOf(hunter).Submitted++
	}

	chain.Emit("QuestSubmitted", "id", strconv.Itoa(id), "hunter", hunter.String())
}

// Reject marks a hunter's submission as not accepted, with a short reason.
// The hunter may resubmit before the deadline. Poster or arbiter only.
func Reject(cur realm, id int, hunter string, reason string) {
	caller := cur.Previous().Address()
	q := mustOpen(id)
	if !q.isManager(caller) {
		panic("only the poster or arbiter can reject submissions")
	}
	reason = strings.TrimSpace(reason)
	if len(reason) > MaxReasonLen {
		panic("reason too long (max " + strconv.Itoa(MaxReasonLen) + " bytes)")
	}
	s := q.findSub(address(strings.TrimSpace(hunter)))
	if s == nil {
		panic("no submission from that address")
	}
	s.Rejected, s.Reason = true, reason

	chain.Emit("QuestRejected", "id", strconv.Itoa(id), "hunter", s.Hunter.String())
}

// Award pays the whole escrow to a hunter who submitted. Poster or arbiter
// only. Allowed any time while the quest is open, including after the
// deadline, until someone calls Expire.
func Award(cur realm, id int, hunter string) {
	caller := cur.Previous().Address()
	q := mustOpen(id)
	if !q.isManager(caller) {
		panic("only the poster or arbiter can award a quest")
	}
	s := q.findSub(address(strings.TrimSpace(hunter)))
	if s == nil {
		panic("no submission from that address")
	}
	if s.Rejected {
		panic("that submission was rejected")
	}

	amount := q.Reward
	q.Status = StatusAwarded
	q.Winner = s.Hunter
	q.ClosedAt = time.Now()
	markClosed(q)
	escrowed -= amount
	paidOut += amount
	completed++

	pp := profileOf(q.Poster)
	pp.Completed++
	pp.Paid += amount
	hp := profileOf(s.Hunter)
	hp.Won++
	hp.Earned += amount

	send(cur, s.Hunter, amount)

	chain.Emit("QuestAwarded",
		"id", strconv.Itoa(id),
		"hunter", s.Hunter.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// Cancel closes a quest and refunds every contributor. The poster can cancel
// at any time; if work had already been submitted, that is recorded on the
// poster's public profile. The arbiter can also cancel.
func Cancel(cur realm, id int) {
	caller := cur.Previous().Address()
	q := mustOpen(id)
	if !q.isManager(caller) {
		panic("only the poster or arbiter can cancel a quest")
	}
	if q.activeSubs() > 0 && caller == q.Poster {
		profileOf(q.Poster).Cancelled++
	}
	closeAndRefund(cur, q, StatusCancelled)
	chain.Emit("QuestCancelled", "id", strconv.Itoa(id), "by", caller.String())
}

// Expire can be called by anyone once GracePeriod has passed after the
// deadline without an award. It refunds every contributor. If hunters were
// left waiting, the poster's profile records it as ghosted.
func Expire(cur realm, id int) {
	q := mustOpen(id)
	if !q.expirable(time.Now()) {
		panic("quest can only expire " + GracePeriod.String() + " after its deadline")
	}
	if q.activeSubs() > 0 {
		profileOf(q.Poster).Ghosted++
	}
	closeAndRefund(cur, q, StatusExpired)
	chain.Emit("QuestExpired", "id", strconv.Itoa(id))
}

// ---- read-only helpers for other realms and clients ----

// QuestCount returns how many quests were ever posted.
func QuestCount() int { return quests.Size() }

// RewardOf returns the current reward (ugnot) and status of a quest.
func RewardOf(id int) (int64, string) {
	q := mustGet(id)
	return q.Reward, q.Status.String()
}

// Stats returns board-wide totals: open quests, ugnot in escrow, ugnot paid
// to hunters, quests completed.
func Stats() (int, int64, int64, int) {
	return openCount, escrowed, paidOut, completed
}

// ---- internals ----

func closeAndRefund(cur realm, q *Quest, st Status) {
	q.Status = st
	q.ClosedAt = time.Now()
	markClosed(q)
	escrowed -= q.Reward
	refunded += q.Reward
	for _, c := range q.Contribs {
		if c.Amount > 0 {
			send(cur, c.From, c.Amount)
		}
	}
}

func markClosed(q *Quest) {
	open.Remove(key(q.ID))
	openCount--
	closed = append(closed, q.ID)
	if len(closed) > maxRecent {
		closed = closed[len(closed)-maxRecent:]
	}
}

// mustReceive checks that the transaction sent at least min ugnot to this
// realm, and nothing else. Only direct user calls are accepted: OriginSend
// describes coins that actually landed here only for a pure EOA call.
func mustReceive(cur realm, min int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls (maketx call) can send funds")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("send exactly one coin type: " + Denom)
	}
	amount := sent[0].Amount
	if amount < min {
		panic("send at least " + strconv.FormatInt(min, 10) + Denom)
	}
	return amount
}

func send(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(Denom, amount)})
}

func key(id int) string { return seqid.ID(id).Binary() }

func getQuest(id int) *Quest {
	if id <= 0 {
		return nil
	}
	v := quests.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*Quest)
}

func mustGet(id int) *Quest {
	q := getQuest(id)
	if q == nil {
		panic("quest not found")
	}
	return q
}

func mustOpen(id int) *Quest {
	q := mustGet(id)
	if q.Status != StatusOpen {
		panic("quest is " + q.Status.String())
	}
	return q
}

func profileOf(addr address) *Profile {
	if v := profiles.Get(addr.String()); v != nil {
		return v.(*Profile)
	}
	p := &Profile{}
	profiles.Set(addr.String(), p)
	return p
}

func peekProfile(addr address) *Profile {
	v := profiles.Get(addr.String())
	if v == nil {
		return nil
	}
	return v.(*Profile)
}

func avlTree() avl.Tree { return avl.Tree{} }
