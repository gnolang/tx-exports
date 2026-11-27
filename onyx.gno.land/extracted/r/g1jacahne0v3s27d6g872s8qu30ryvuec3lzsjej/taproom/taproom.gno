// Package taproom is an escrowed bounty board ("quest board") for Gno.land.
//
// Anyone can pin a quest to the board and lock a GNOT reward in the realm.
// Hunters answer with one submission each. The poster picks a winner and the
// escrow is paid out in the same transaction. If nobody delivers, the poster
// gets the reward back, but only after the review window has closed, so
// hunters who did deliver cannot be starved by a poster who simply goes quiet.
//
// Design rules (each one is covered by a test in taproom_test.gno):
//
//   - Funds are only accepted from a direct user call (maketx call), because
//     OriginSend() only describes a real receipt for a pure EOA caller.
//   - Exactly one coin (ugnot) of at least MinReward is accepted per quest, so
//     nothing can be stranded in the realm.
//   - State is updated before coins move (checks, effects, interactions).
//   - totalEscrow tracks every ugnot the realm owes and is asserted against the
//     realm balance before each payout.
//   - Nothing mutable is ever returned by pointer from the public API.
package taproom

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

const (
	denom = "ugnot"

	// MinReward is 1 GNOT, expressed in ugnot.
	MinReward int64 = 1_000_000

	MaxDays        = 60
	MaxSubmissions = 100
	ReviewGrace    = 7 * 24 * time.Hour

	maxTitle   = 80
	maxDetails = 600
	maxNote    = 400
	maxLink    = 200
)

type Status int

const (
	StatusOpen Status = iota
	StatusAwarded
	StatusReclaimed
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusAwarded:
		return "awarded"
	case StatusReclaimed:
		return "reclaimed"
	}
	return "unknown"
}

type submission struct {
	hunter address
	note   string
	link   string
	at     time.Time
}

type quest struct {
	id       int
	poster   address
	title    string
	details  string
	reward   int64
	created  time.Time
	deadline time.Time
	status   Status
	winner   address
	subs     []submission
}

// stats is a per-address reputation record.
type stats struct {
	posted    int   // quests pinned
	paidOut   int64 // ugnot paid to hunters by this address as a poster
	submitted int   // submissions made
	won       int   // quests won
	earned    int64 // ugnot earned as a hunter
}

var (
	quests      avl.Tree // seqKey(id) -> *quest
	people      avl.Tree // address string -> *stats
	nextID      int
	totalEscrow int64 // ugnot currently locked in open quests
	totalPaid   int64 // ugnot ever paid out to winners
)

// PostQuest pins a new quest and locks the attached ugnot as its reward.
// Call it with -send "<amount>ugnot". days is how long hunters have to submit.
func PostQuest(cur realm, title, details string, days int) int {
	require(cur.Previous().IsUserCall(), "only a direct user call (maketx call) can fund a quest")

	title = strings.TrimSpace(title)
	details = strings.TrimSpace(details)
	require(len(title) > 0 && len(title) <= maxTitle, "title must be 1-"+strconv.Itoa(maxTitle)+" bytes")
	require(len(details) > 0 && len(details) <= maxDetails, "details must be 1-"+strconv.Itoa(maxDetails)+" bytes")
	require(days >= 1 && days <= MaxDays, "days must be between 1 and "+strconv.Itoa(MaxDays))

	sent := unsafe.OriginSend()
	require(len(sent) == 1 && sent[0].Denom == denom, "send exactly one coin type: ugnot")
	reward := sent[0].Amount
	require(reward >= MinReward, "reward must be at least "+gnot(MinReward))

	poster := cur.Previous().Address()
	now := time.Now()
	nextID++
	q := &quest{
		id:       nextID,
		poster:   poster,
		title:    title,
		details:  details,
		reward:   reward,
		created:  now,
		deadline: now.Add(time.Duration(days) * 24 * time.Hour),
		status:   StatusOpen,
	}
	quests.Set(seqKey(q.id), q)
	totalEscrow += reward
	statsOf(poster).posted++

	chain.Emit("QuestPosted",
		"id", strconv.Itoa(q.id),
		"poster", poster.String(),
		"reward", strconv.FormatInt(reward, 10),
	)
	return q.id
}

// Submit answers an open quest. One submission per address; the poster cannot
// answer their own quest. link is optional and must be an https URL.
func Submit(cur realm, id int, note, link string) {
	q := mustQuest(id)
	hunter := cur.Previous().Address()

	require(q.status == StatusOpen, "quest is not open")
	require(!time.Now().After(q.deadline), "submission window has closed")
	require(hunter != q.poster, "poster cannot answer their own quest")
	require(q.indexOf(hunter) < 0, "you already submitted to this quest")
	require(len(q.subs) < MaxSubmissions, "this quest is full")

	note = strings.TrimSpace(note)
	link = strings.TrimSpace(link)
	require(len(note) > 0 && len(note) <= maxNote, "note must be 1-"+strconv.Itoa(maxNote)+" bytes")
	require(len(link) <= maxLink, "link too long")
	require(link == "" || safeLink(link), "link must be a plain https:// URL")

	q.subs = append(q.subs, submission{hunter: hunter, note: note, link: link, at: time.Now()})
	statsOf(hunter).submitted++

	chain.Emit("Submitted", "id", strconv.Itoa(id), "hunter", hunter.String())
}

// Award picks the winner of a quest and pays the escrow out immediately.
// Only the poster can call it, and only for an address that submitted.
func Award(cur realm, id int, hunter address) {
	q := mustQuest(id)
	caller := cur.Previous().Address()

	require(caller == q.poster, "only the poster can award this quest")
	require(q.status == StatusOpen, "quest is not open")
	require(q.indexOf(hunter) >= 0, "that address has not submitted")

	// effects
	reward := q.reward
	q.status = StatusAwarded
	q.winner = hunter
	totalEscrow -= reward
	totalPaid += reward
	ps := statsOf(q.poster)
	ps.paidOut += reward
	hs := statsOf(hunter)
	hs.won++
	hs.earned += reward

	// interaction
	pay(cur, hunter, reward)

	chain.Emit("Awarded",
		"id", strconv.Itoa(id),
		"winner", hunter.String(),
		"reward", strconv.FormatInt(reward, 10),
	)
}

// Reclaim returns the escrow to the poster.
// With no submissions the poster may withdraw at any time. Once hunters have
// delivered, the poster must wait for the deadline plus the review window.
func Reclaim(cur realm, id int) {
	q := mustQuest(id)
	caller := cur.Previous().Address()

	require(caller == q.poster, "only the poster can reclaim this quest")
	require(q.status == StatusOpen, "quest is not open")
	if len(q.subs) > 0 {
		require(time.Now().After(q.deadline.Add(ReviewGrace)),
			"hunters have submitted: wait until the review window ends")
	}

	reward := q.reward
	q.status = StatusReclaimed
	totalEscrow -= reward

	pay(cur, q.poster, reward)

	chain.Emit("Reclaimed", "id", strconv.Itoa(id), "reward", strconv.FormatInt(reward, 10))
}

// ---- read-only helpers (values only, never pointers) ----

// Count returns the number of quests ever pinned.
func Count() int { return nextID }

// TotalEscrow returns the ugnot currently locked in open quests.
func TotalEscrow() int64 { return totalEscrow }

// TotalPaid returns the ugnot ever paid out to winners.
func TotalPaid() int64 { return totalPaid }

// StatusOf returns the status string of a quest, or panics if it does not exist.
func StatusOf(id int) string { return mustQuest(id).status.String() }

// SubmissionCount returns how many hunters answered a quest.
func SubmissionCount(id int) int { return len(mustQuest(id).subs) }

// ---- internals ----

func require(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}

func seqKey(id int) string {
	// zero-padded so the AVL tree iterates in numeric order
	s := strconv.Itoa(id)
	return strings.Repeat("0", 10-len(s)) + s
}

func mustQuest(id int) *quest {
	v := quests.Get(seqKey(id))
	require(v != nil, "no such quest: "+strconv.Itoa(id))
	return v.(*quest)
}

func (q *quest) indexOf(a address) int {
	for i := range q.subs {
		if q.subs[i].hunter == a {
			return i
		}
	}
	return -1
}

func statsOf(a address) *stats {
	if v := people.Get(a.String()); v != nil {
		return v.(*stats)
	}
	s := &stats{}
	people.Set(a.String(), s)
	return s
}

// pay sends ugnot from the realm's own balance, after checking the realm can
// cover everything it owes.
func pay(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := cur.Address()
	// totalEscrow was already reduced for this payout, so add it back.
	require(b.GetCoin(self, denom) >= totalEscrow+amount, "escrow invariant violated")
	b.SendCoins(self, to, chain.NewCoins(chain.NewCoin(denom, amount)))
}

// safeLink accepts only plain https URLs that cannot break out of markdown.
func safeLink(s string) bool {
	if !strings.HasPrefix(s, "https://") || len(s) <= len("https://") {
		return false
	}
	for _, r := range s {
		if r <= ' ' || r >= 0x7f {
			return false
		}
		switch r {
		case '(', ')', '[', ']', '<', '>', '"', '\'', '`', '\\', '*', '|':
			return false
		}
	}
	return true
}

// gnot formats ugnot as a human-readable GNOT amount.
func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	s := strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac, 10)
		f = strings.Repeat("0", 6-len(f)) + f
		f = strings.TrimRight(f, "0")
		s += "." + f
	}
	return s + " GNOT"
}
