// Package gild is a paid task board.
//
// A poster locks a reward in this realm when posting a task. One doer takes
// the task and sends a link to the work. The poster approves and the realm
// pays the doer. Two rules protect both sides:
//
//   - If the poster stays silent for ReviewWindow after the work is sent,
//     the doer can claim the reward.
//   - If nobody takes the task, or the doer never sends work before the
//     deadline, the poster gets the reward back.
//
// Every payout is written to a public work record (see p/thesithunyein/rep),
// which other realms can read through Completed and Earned.
package gild

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/g1jw2yrfqnd4fp90qadw88pnjgpden4vgagjvpe6/rep/v0"
)

// Rules. They are constants so anyone can read them in the source.
const (
	Denom                  = "ugnot"
	MinReward        int64 = 1_000_000             // 1 GNOT
	MaxReward        int64 = 1_000_000_000_000_000 // 1 billion GNOT, a sanity cap
	ReviewWindow           = 7 * 24 * time.Hour    // poster's time to answer sent work
	ChangesExtension       = 3 * 24 * time.Hour    // minimum time a doer gets after changes are asked
	MinDeadline            = time.Hour
	MaxDeadline            = 90 * 24 * time.Hour

	MinTitle   = 3
	MaxTitle   = 120
	MaxDetails = 4000
	MaxDone    = 1000
	MaxURL     = 300
	MaxNote    = 1000
	MaxPage    = 50
)

// Status is where a task is in its life.
type Status int

const (
	StatusOpen     Status = iota // reward locked, waiting for a doer
	StatusTaken                  // a doer is working on it
	StatusInReview               // work sent, waiting for the poster
	StatusPaid                   // reward paid to the doer
	StatusRefunded               // reward returned to the poster
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusTaken:
		return "taken"
	case StatusInReview:
		return "in_review"
	case StatusPaid:
		return "paid"
	case StatusRefunded:
		return "refunded"
	}
	return "unknown"
}

// Categories a task can have.
var categories = []string{"code", "docs", "design", "testing", "translation", "other"}

// Task is one posted piece of work.
type Task struct {
	ID       seqid.ID
	Title    string
	Details  string
	Done     string // what "done" looks like
	Category string
	Poster   address
	Doer     address
	Reward   int64 // in Denom
	Status   Status

	CreatedAt   time.Time
	Deadline    time.Time // a doer must send work before this
	TakenAt     time.Time
	SubmittedAt time.Time
	ClosedAt    time.Time

	WorkURL      string
	ChangesAsked bool
	ChangesNote  string
	PaidBy       string // "approval" or "silence" once paid
}

var (
	tasks     avl.Tree // id key -> *Task, every task
	openTasks avl.Tree // id key -> *Task, only open tasks
	byPoster  avl.Tree // address -> *avl.Tree of id key -> *Task
	byDoer    avl.Tree // address -> *avl.Tree of id key -> *Task
	nextID    seqid.ID
	book      = rep.NewBook(20)

	lockedTotal int64 // rewards currently held by this realm
	paidTotal   int64 // rewards paid to doers

	webPath string // this realm's gnoweb path, e.g. "/r/thesithunyein/gild/v0"
)

func init(cur realm) {
	webPath = strings.TrimPrefix(cur.PkgPath(), "gno.land")
}

// Post creates a task and locks the coins sent with the call as its reward.
// It must be called directly by a user (maketx call) with exactly one coin of
// Denom attached. deadline is a Unix time in seconds.
func Post(cur realm, title, details, done, category string, deadline int64) int64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic(ErrUserCallOnly)
	}
	reward := rewardFrom(unsafe.OriginSend())

	title = trimSpace(title)
	details = trimSpace(details)
	done = trimSpace(done)
	checkText(title, MinTitle, MaxTitle, ErrTitle)
	checkText(details, 0, MaxDetails, ErrDetails)
	checkText(done, 0, MaxDone, ErrDone)
	if !isCategory(category) {
		panic(ErrCategory)
	}

	now := time.Now()
	dl := time.Unix(deadline, 0)
	if dl.Before(now.Add(MinDeadline)) || dl.After(now.Add(MaxDeadline)) {
		panic(ErrDeadline)
	}

	t := &Task{
		ID:        nextID.Next(),
		Title:     title,
		Details:   details,
		Done:      done,
		Category:  category,
		Poster:    prev.Address(),
		Reward:    reward,
		Status:    StatusOpen,
		CreatedAt: now,
		Deadline:  dl,
	}
	key := t.ID.Binary()
	tasks.Set(key, t)
	openTasks.Set(key, t)
	index(&byPoster, t.Poster, key, t)
	lockedTotal += reward
	return int64(t.ID)
}

// Take assigns an open task to the caller. The poster cannot take their own
// task, and nobody can take a task after its deadline.
func Take(cur realm, id int64) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if t.Status != StatusOpen {
		panic(ErrNotOpen)
	}
	if caller == t.Poster {
		panic(ErrOwnTask)
	}
	now := time.Now()
	if !now.Before(t.Deadline) {
		panic(ErrPastDeadline)
	}
	t.Doer = caller
	t.Status = StatusTaken
	t.TakenAt = now
	key := t.ID.Binary()
	openTasks.Remove(key)
	index(&byDoer, caller, key, t)
}

// Release gives a taken task back so someone else can take it. Only the doer
// can call it, and only before work is sent. Any change request is cleared,
// so the next doer starts fresh.
func Release(cur realm, id int64) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if caller != t.Doer {
		panic(ErrNotDoer)
	}
	if t.Status != StatusTaken {
		panic(ErrNotTaken)
	}
	key := t.ID.Binary()
	unindex(&byDoer, t.Doer, key)
	t.Doer = ""
	t.TakenAt = time.Time{}
	t.WorkURL = ""
	t.ChangesAsked = false
	t.ChangesNote = ""
	t.Status = StatusOpen
	openTasks.Set(key, t)
}

// Submit sends a link to the finished work. Only the doer can call it, and
// only while the task is taken.
func Submit(cur realm, id int64, workURL string) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if caller != t.Doer {
		panic(ErrNotDoer)
	}
	if t.Status != StatusTaken {
		panic(ErrNotTaken)
	}
	workURL = trimSpace(workURL)
	if !isWorkURL(workURL) {
		panic(ErrURL)
	}
	t.WorkURL = workURL
	t.SubmittedAt = time.Now()
	t.Status = StatusInReview
}

// Approve pays the doer. Only the poster can call it, and only after work
// was sent.
func Approve(cur realm, id int64) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if caller != t.Poster {
		panic(ErrNotPoster)
	}
	if t.Status != StatusInReview {
		panic(ErrNotInReview)
	}
	pay(t, cur, "approval")
}

// RequestChanges sends the task back to the doer once. The doer gets at least
// ChangesExtension from now before the poster can take the reward back.
func RequestChanges(cur realm, id int64, note string) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if caller != t.Poster {
		panic(ErrNotPoster)
	}
	if t.Status != StatusInReview {
		panic(ErrNotInReview)
	}
	if t.ChangesAsked {
		panic(ErrChangesUsed)
	}
	note = trimSpace(note)
	checkText(note, 1, MaxNote, ErrNote)

	t.ChangesAsked = true
	t.ChangesNote = note
	t.Status = StatusTaken
	t.SubmittedAt = time.Time{}
	if floor := time.Now().Add(ChangesExtension); t.Deadline.Before(floor) {
		t.Deadline = floor
	}
}

// ClaimAfterSilence pays the doer when the poster has not answered within
// ReviewWindow of the work being sent.
func ClaimAfterSilence(cur realm, id int64) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if caller != t.Doer {
		panic(ErrNotDoer)
	}
	if t.Status != StatusInReview {
		panic(ErrNotInReview)
	}
	if time.Now().Before(t.SubmittedAt.Add(ReviewWindow)) {
		panic(ErrTooEarly)
	}
	pay(t, cur, "silence")
}

// Cancel returns the reward to the poster. It works while the task is open,
// or when a doer took it but sent no work before the deadline. It never works
// once work has been sent, so a poster cannot cancel to avoid paying.
func Cancel(cur realm, id int64) {
	caller := cur.Previous().Address()
	t := mustGet(id)
	if caller != t.Poster {
		panic(ErrNotPoster)
	}
	switch t.Status {
	case StatusOpen:
		openTasks.Remove(t.ID.Binary())
	case StatusTaken:
		if time.Now().Before(t.Deadline) {
			panic(ErrDoerHasTime)
		}
	default:
		panic(ErrCannotCancel)
	}
	t.Status = StatusRefunded
	t.ClosedAt = time.Now()
	lockedTotal -= t.Reward
	send(t.Poster, t.Reward, cur)
}

// Completed returns how many tasks addr finished and was paid for on Gild.
// Other realms can call it to gate features by proven work.
func Completed(addr address) int { return book.Completed(addr) }

// Earned returns the total paid to addr on Gild, in Denom.
func Earned(addr address) int64 { return book.Earned(addr) }

// HasCompleted reports whether addr finished at least n tasks on Gild.
func HasCompleted(addr address, n int) bool { return book.HasCompleted(addr, n) }

// pay marks the task paid, records it, then sends the reward. State changes
// come before the transfer.
func pay(t *Task, rlm realm, by string) {
	now := time.Now()
	t.Status = StatusPaid
	t.ClosedAt = now
	t.PaidBy = by
	lockedTotal -= t.Reward
	paidTotal += t.Reward
	book.Add(rep.Record{
		TaskID: idStr(t.ID),
		Title:  t.Title,
		Poster: t.Poster,
		Doer:   t.Doer,
		Amount: t.Reward,
		Denom:  Denom,
		At:     now,
	})
	send(t.Doer, t.Reward, rlm)
}

// send pays amount from this realm to addr. rlm must be the live realm handle.
func send(to address, amount int64, rlm realm) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), to, chain.Coins{{Denom, amount}})
}

func rewardFrom(sent chain.Coins) int64 {
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic(ErrReward)
	}
	amount := sent[0].Amount
	if amount < MinReward || amount > MaxReward {
		panic(ErrRewardRange)
	}
	return amount
}

// idStr is the public form of a task id, e.g. "12".
func idStr(id seqid.ID) string { return strconv.FormatInt(int64(id), 10) }

func mustGet(id int64) *Task {
	if id < 1 {
		panic(ErrNotFound)
	}
	v := tasks.Get(seqid.ID(id).Binary())
	if v == nil {
		panic(ErrNotFound)
	}
	return v.(*Task)
}

func index(tree *avl.Tree, addr address, key string, t *Task) {
	var sub *avl.Tree
	if v := tree.Get(addr.String()); v != nil {
		sub = v.(*avl.Tree)
	} else {
		sub = avl.NewTree()
		tree.Set(addr.String(), sub)
	}
	sub.Set(key, t)
}

func unindex(tree *avl.Tree, addr address, key string) {
	v := tree.Get(addr.String())
	if v == nil {
		return
	}
	sub := v.(*avl.Tree)
	sub.Remove(key)
	if sub.Size() == 0 {
		tree.Remove(addr.String())
	}
}

func isCategory(c string) bool {
	for _, k := range categories {
		if c == k {
			return true
		}
	}
	return false
}
