// Package registry is the Lamplighter job registry.
//
// A chain has no timer: nothing on gno.land wakes a realm up. Lamplighter is
// the waking. A realm registers a callback, a schedule and a reward; once the
// job is due, anyone may call Exec, which runs the callback and pays the
// caller the reward in the same transaction.
//
// The callback is a crossing function value. The GnoVM runs it under the
// authority of the realm that declared it, wherever it is stored and whoever
// invokes it, so this registry can hold callbacks from any realm without
// gaining any power over their state.
package registry

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
)

const (
	// realmPath is this realm's package path, used to build links.
	realmPath = "gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v1"

	// Denom is the only coin accepted as oil.
	Denom = "ugnot"

	// MinInterval is the shortest repeat interval, in seconds.
	MinInterval int64 = 10

	// MaxNameLen bounds the job name stored and rendered on chain.
	MaxNameLen = 80
)

// Job is one registered lamp: a callback, when it is next due, and the oil
// that pays whoever lights it.
type Job struct {
	id       uint64
	name     string
	owner    string // pkgpath of the realm that registered the job
	callback func(realm) error

	interval int64 // seconds between runs; 0 means the job runs once
	nextDue  int64 // unix time from which Exec is accepted

	reward  int64 // ugnot paid to the caller of each Exec
	balance int64 // ugnot held for this job

	runs     int64
	lastRun  int64
	lastBy   address
	finished bool // a one-shot job that has run
	closed   bool // cancelled by its owner
}

// recentSize is how many past runs the registry remembers.
const recentSize = 8

// Run is one past execution, kept for the dashboard.
type Run struct {
	job    uint64
	by     address
	at     int64 // unix time; 0 marks a slot that has never been used
	reward int64
}

var (
	jobs   avl.Tree // zero-padded id -> *Job
	nextID uint64   = 1

	// recent is a ring of the last runs. Whoever sends a transaction pays a
	// storage deposit for every byte of state it adds, so a per-executor
	// table would charge each newcomer for their own row. The ring is
	// allocated in full when the realm is deployed and a run overwrites a
	// slot in place, which keeps running a job nearly free of deposit.
	recent     [recentSize]Run
	recentNext int

	// busy is the reentrancy lock held while a callback runs.
	busy bool

	totalRuns int64
	totalPaid int64
)

func init(cur realm) {
	// Fill every slot with an address now, so that the first runs do not
	// each grow the state by one.
	for i := range recent {
		recent[i].by = cur.Address()
	}
}

// Register adds a job and returns its id. Only a realm can register, and that
// realm becomes the job's owner.
//
// firstDue is the unix time of the first run; a value in the past means "as
// soon as possible". interval is the number of seconds between runs, or 0 for
// a job that runs once. reward is the ugnot paid to the caller of each Exec.
// The job holds no coins until someone calls Fund.
func Register(cur realm, name string, firstDue, interval, reward int64, callback func(realm) error) uint64 {
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("only a realm can register a job")
	}
	if callback == nil {
		panic("callback must not be nil")
	}
	if name == "" || len(name) > MaxNameLen {
		panic("name must be 1 to " + strconv.Itoa(MaxNameLen) + " bytes")
	}
	if interval != 0 && interval < MinInterval {
		panic("interval must be 0 or at least " + strconv.FormatInt(MinInterval, 10) + " seconds")
	}
	if reward <= 0 {
		panic("reward must be positive")
	}

	now := time.Now().Unix()
	if firstDue < now {
		firstDue = now
	}

	id := nextID
	nextID++
	jobs.Set(key(id), &Job{
		id:       id,
		name:     name,
		owner:    prev.PkgPath(),
		callback: callback,
		interval: interval,
		nextDue:  firstDue,
		reward:   reward,
	})

	chain.Emit("JobRegistered", "id", utoa(id), "owner", prev.PkgPath())
	return id
}

// Fund adds the ugnot sent with the transaction to a job's balance. Anyone
// may fund any open job.
func Fund(cur realm, id uint64) {
	// OriginSend describes the transaction, not the immediate caller, so a
	// realm in between could otherwise claim someone else's coins as its own.
	runtime.AssertOriginCall()

	amount := deposit(id, unsafe.OriginSend())
	chain.Emit("JobFunded", "id", utoa(id), "amount", itoa(amount))
}

// deposit credits coins that have arrived with the transaction to a job and
// returns the amount credited.
func deposit(id uint64, sent chain.Coins) int64 {
	j := mustJob(id)
	if j.closed || j.finished {
		panic("job is no longer open")
	}
	amount := sent.AmountOf(Denom)
	if len(sent) != 1 || amount <= 0 {
		panic("send only " + Denom)
	}
	j.balance += amount
	return amount
}

// Exec runs a due job and pays its reward to the caller.
//
// A callback that returns an error or panics aborts the whole transaction, so
// a failing job pays nothing and changes nothing. Simulate before sending.
func Exec(cur realm, id uint64) {
	if busy {
		panic("reentrant call")
	}
	j := mustJob(id)
	if reason := notRunnable(j, time.Now().Unix()); reason != "" {
		panic(reason)
	}

	caller := cur.Previous().Address()
	now := time.Now().Unix()

	// Effects first: the job is already rescheduled and charged when the
	// callback runs, so nothing the callback does can run it twice.
	j.balance -= j.reward
	j.runs++
	j.lastRun = now
	j.lastBy = caller
	if j.interval == 0 {
		j.finished = true
	} else {
		j.nextDue = nextSlot(j.nextDue, j.interval, now)
	}

	busy = true
	if err := j.callback(cross(cur)); err != nil {
		panic("job failed: " + err.Error())
	}
	busy = false

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), caller, chain.Coins{{Denom, j.reward}})

	remember(id, caller, now, j.reward)
	totalRuns++
	totalPaid += j.reward

	chain.Emit("JobExecuted", "id", utoa(id), "by", caller.String(), "reward", itoa(j.reward))
}

// Cancel closes a job and sends its remaining balance to refundTo. Only the
// realm that registered the job may cancel it.
func Cancel(cur realm, id uint64, refundTo address) {
	if busy {
		panic("reentrant call")
	}
	j := mustJob(id)
	if cur.Previous().PkgPath() != j.owner {
		panic("only the owner realm can cancel a job")
	}
	if j.closed {
		panic("job is already closed")
	}
	if !refundTo.IsValid() {
		panic("invalid refund address")
	}

	refund := j.balance
	j.balance = 0
	j.closed = true
	j.callback = nil

	if refund > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), refundTo, chain.Coins{{Denom, refund}})
	}

	chain.Emit("JobCancelled", "id", utoa(id), "refund", itoa(refund))
}

// IsDue reports whether Exec would currently be accepted for a job.
func IsDue(id uint64) bool {
	j, ok := jobs.Get(key(id)).(*Job)
	if !ok {
		return false
	}
	return notRunnable(j, time.Now().Unix()) == ""
}

// DueJobs returns the ids of every job Exec would currently accept, comma
// separated. It is what an executor bot polls.
func DueJobs() string {
	now := time.Now().Unix()
	out := ""
	jobs.Iterate("", "", func(_ string, v any) bool {
		j := v.(*Job)
		if notRunnable(j, now) == "" {
			if out != "" {
				out += ","
			}
			out += utoa(j.id)
		}
		return false
	})
	return out
}

// notRunnable returns why a job cannot run at the given time, or "" if it can.
func notRunnable(j *Job, now int64) string {
	switch {
	case j.closed:
		return "job is closed"
	case j.finished:
		return "job has already run"
	case now < j.nextDue:
		return "job is not due yet"
	case j.balance < j.reward:
		return "job is out of oil"
	}
	return ""
}

// nextSlot returns the first slot after now on the grid due, due+interval,
// due+2*interval, and so on. Slots missed while nobody executed the job are
// skipped rather than replayed, and the grid never drifts.
func nextSlot(due, interval, now int64) int64 {
	if now < due {
		return due + interval
	}
	missed := (now - due) / interval
	return due + (missed+1)*interval
}

// remember records a run in the ring, overwriting the oldest one.
func remember(job uint64, by address, at, reward int64) {
	r := &recent[recentNext]
	r.job = job
	r.by = by
	r.at = at
	r.reward = reward
	recentNext = (recentNext + 1) % recentSize
}

// recentRuns returns the remembered runs, newest first.
func recentRuns() []Run {
	out := make([]Run, 0, recentSize)
	for i := 1; i <= recentSize; i++ {
		r := recent[(recentNext-i+recentSize)%recentSize]
		if r.at != 0 {
			out = append(out, r)
		}
	}
	return out
}

func mustJob(id uint64) *Job {
	j, ok := jobs.Get(key(id)).(*Job)
	if !ok {
		panic("unknown job " + utoa(id))
	}
	return j
}

// key zero-pads the id so the tree iterates in numeric order.
func key(id uint64) string {
	s := utoa(id)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func utoa(n uint64) string { return strconv.FormatUint(n, 10) }
func itoa(n int64) string  { return strconv.FormatInt(n, 10) }
