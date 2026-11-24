// Package registry is the Lamplighter job registry.
//
// gno.land has no scheduler: a realm only runs when a transaction calls it.
// Here a realm registers a callback, a schedule and a reward. Once the job is
// due, anyone may call Exec, which runs the callback and pays the caller the
// reward in the same transaction.
//
// The callback is a crossing function value. The GnoVM runs it under the
// authority of the realm that declared it, wherever it is stored and whoever
// invokes it, so this registry can hold callbacks from any realm without
// gaining any power over their state.
//
// # What a callback must check
//
// Exec is open to everyone and so is Register, so the registry will run any
// reachable func(realm, uint64) error for anyone, including another realm's
// exported one. "The caller is the registry" therefore says nothing about
// which job is running or who scheduled it. A callback has to check both:
//
//	func tick(cur realm, job uint64) error {
//		if cur.Previous().PkgPath() != registry.Path() || job != myJob {
//			return errors.New("not my job")
//		}
//		...
//	}
//
// Keep the callback unexported, and never give the registry's address a
// privilege in your realm.
//
// # What running a job costs
//
// Exec runs code written by the job's owner. Whoever sends the transaction
// pays the storage deposit for every byte of state that code adds, in any
// realm. Send Exec with a small -max-deposit.
//
// # Where the storage deposit goes
//
// A job is a few kilobytes of state. The chain locks a deposit for them from
// whoever sends the transaction that registers the job, and releases it to
// whoever sends the transaction that removes it. Only Cancel removes a job,
// and only the job's owner can call it, so the deposit goes where the owner
// arranges for it to go. Funding and running a job leave the size of the
// state almost unchanged: a run pays its reward and nothing else.
//
// A job that runs once is therefore kept after its run, marked done, until
// its owner cancels it.
package registry

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	// Denom is the only coin accepted as oil.
	Denom = "ugnot"

	// MinInterval and MaxInterval bound the seconds between two runs of a
	// repeating job.
	MinInterval int64 = 10
	MaxInterval int64 = 10 * 365 * 24 * 60 * 60

	// MaxDelay is how far in the future a job's first run may be.
	MaxDelay = MaxInterval

	// MinReward is the smallest reward a job may offer, in ugnot. It is a
	// floor against dust, not a promise that the job is worth running: at
	// today's gas price a run costs several times this.
	MinReward int64 = 1000

	// MaxNameLen bounds the job name stored and rendered on chain.
	MaxNameLen = 80

	// MaxPage is the most jobs DueJobs returns in one call.
	MaxPage = 100
)

// job is one registered lamp: a callback, when it is next due, and the oil
// that pays whoever lights it.
type job struct {
	id       uint64
	name     string
	owner    string // pkgpath of the realm that registered the job
	callback func(realm, uint64) error

	interval int64 // seconds between runs; 0 means the job runs once
	nextDue  int64 // unix time from which Exec is accepted

	reward  int64 // ugnot paid to the caller of each Exec
	balance int64 // ugnot held for this job

	runs    int64
	lastRun int64
	lastBy  address

	done bool   // a job that runs once, after its run
	slot string // the job's key in the queue index
}

var (
	// realmPath is this realm's own package path, recorded when it is deployed.
	realmPath string

	// jobs holds every job that has not been cancelled, keyed by zero-padded id.
	jobs avl.Tree

	// queue indexes every job. A job that can run once its time comes sits
	// under a key that sorts by due time, then id, so finding the due jobs
	// never walks the jobs that are not. A job that cannot pay for a run, or
	// is done, is parked under a key that sorts after all of those. Moving
	// between the two is a change of key, not an insertion, so funding a job
	// or spending its last reward does not change the size of the state.
	queue avl.Tree

	nextID uint64 = 1

	// running is the id of the job whose callback is executing, 0 if none.
	// It is the reentrancy lock. A callback that panics aborts the whole
	// transaction, and with it the write that set the lock; Exec resets it
	// in a defer all the same, so that the lock could not outlive a run even
	// under a VM that let a caller survive such a panic.
	running uint64

	// held is the ugnot accounted to jobs. The realm's real balance can only
	// be higher, by coins that were sent to it without going through Fund.
	held int64

	totalRuns int64
	totalPaid int64
)

func init(cur realm) {
	realmPath = cur.PkgPath()
	initRecent(cur.Address())
}

// Path returns this realm's package path, for callbacks to compare
// cur.Previous().PkgPath() against.
func Path() string { return realmPath }

// Register adds a job and returns its id. Only a deployed realm can register,
// and that realm becomes the job's owner.
//
// firstDue is the unix time of the first run; a value in the past means "as
// soon as possible". interval is the number of seconds between runs, or 0 for
// a job that runs once. reward is the ugnot paid to the caller of each Exec.
// The job holds no coins until it is funded.
//
// callback receives the id of the job being run. See the package doc for what
// it must check.
func Register(cur realm, name string, firstDue, interval, reward int64, callback func(realm, uint64) error) uint64 {
	prev := cur.Previous()
	// A `maketx run` script also has a package path, but its code is not
	// kept on chain: it has no function of its own to register, only someone
	// else's to pass along.
	if !prev.IsCode() || prev.IsEphemeral() {
		panic("only a deployed realm can register a job")
	}
	if callback == nil {
		panic("callback must not be nil")
	}
	if !validName(name) {
		panic("name must be 1 to " + strconv.Itoa(MaxNameLen) + " bytes of printable text")
	}
	if interval != 0 && (interval < MinInterval || interval > MaxInterval) {
		panic("interval must be 0, or " + itoa(MinInterval) + " to " + itoa(MaxInterval) + " seconds")
	}
	if reward < MinReward {
		panic("reward must be at least " + itoa(MinReward) + " " + Denom)
	}

	now := time.Now().Unix()
	if firstDue < now {
		firstDue = now
	}
	if firstDue-now > MaxDelay {
		panic("first run is too far in the future")
	}

	id := nextID
	nextID++
	j := &job{
		id:       id,
		name:     name,
		owner:    prev.PkgPath(),
		callback: callback,
		interval: interval,
		nextDue:  firstDue,
		reward:   reward,
		// lastRun and lastBy are given their final size now, at the
		// registrant's cost, so that the first run does not grow the job by
		// an address for its executor to pay a deposit on. They mean
		// nothing until runs > 0.
		lastRun: now,
		lastBy:  prev.Address(),
	}
	jobs.Set(key(id), j)
	index(j)

	chain.Emit("JobRegistered",
		"id", utoa(id), "owner", prev.PkgPath(),
		"firstDue", itoa(firstDue), "interval", itoa(interval), "reward", itoa(reward))
	return id
}

// Fund adds the ugnot sent with the call to a job's balance. Anyone may fund
// any job. The coins belong to the job from then on: only its owner realm can
// close it, and the owner decides where what is left goes.
//
// A realm cannot call Fund; it sends coins to this realm and calls Credit.
func Fund(cur realm, id uint64) {
	// OriginSend describes the whole message, not the immediate caller, so
	// it is only meaningful when the message called this function directly.
	// This is the one use chain/runtime/unsafe is meant for.
	runtime.AssertOriginCall()

	deposit(mustJob(id), oilIn(unsafe.OriginSend()))
}

// oilIn returns the ugnot in the coins sent with a call, and refuses anything
// that is not ugnot alone: other coins would be stranded here.
func oilIn(sent chain.Coins) int64 {
	amount := sent.AmountOf(Denom)
	if len(sent) != 1 || amount <= 0 {
		panic("send only " + Denom)
	}
	return amount
}

// Credit adds amount ugnot to a job's balance out of the coins this realm
// holds that are not yet accounted to any job. It is how a realm funds a job:
// send the coins to this realm's address with a banker, then call Credit for
// the same amount, in the same transaction.
//
// The amount is explicit so that coins somebody else left here cannot change
// what a call credits. Credit is refused while a job is running, so a
// callback cannot refuel a job; do that from an ordinary call.
func Credit(cur realm, id uint64, amount int64) {
	if running != 0 {
		panic("reentrant call")
	}
	if amount <= 0 || amount > Unaccounted() {
		panic("credit more than 0 and no more than the " + itoa(Unaccounted()) + " " + Denom + " not yet accounted to a job")
	}
	deposit(mustJob(id), amount)
}

// Unaccounted returns the ugnot this realm holds that belong to no job: coins
// sent to its address that have not been credited yet.
func Unaccounted() int64 {
	return banker.NewReadonlyBanker().GetCoin(chain.PackageAddress(realmPath), Denom) - held
}

// deposit accounts coins that have already arrived to a job.
func deposit(j *job, amount int64) {
	if j.done {
		panic("job has already run")
	}
	if j.interval == 0 && j.balance+amount > j.reward {
		// More than one reward could never be spent, and would sit in the
		// job until its owner cancelled it.
		panic("a job that runs once holds one reward, " + itoa(j.reward) + " " + Denom)
	}
	j.balance += amount
	held += amount
	index(j)

	chain.Emit("JobFunded", "id", utoa(j.id), "amount", itoa(amount), "balance", itoa(j.balance))
}

// Exec runs a due job and pays its reward to the caller.
//
// A callback that returns an error or panics aborts the whole transaction, so
// a failing job pays nothing and changes nothing. Simulate before sending.
func Exec(cur realm, id uint64) {
	if running != 0 {
		panic("reentrant call")
	}
	j := mustJob(id)
	now := time.Now().Unix()
	if reason := notRunnable(j, now); reason != "" {
		panic(reason)
	}
	caller := cur.Previous().Address()

	// Effects first: the job is already charged and rescheduled when the
	// callback runs, so nothing the callback does can run it twice.
	j.balance -= j.reward
	held -= j.reward
	j.runs++
	j.lastRun = now
	j.lastBy = caller

	if j.interval == 0 {
		j.done = true
	} else {
		j.nextDue = nextSlot(j.nextDue, j.interval, now)
	}
	index(j)

	running = id
	defer func() { running = 0 }()
	if err := j.callback(cross(cur), id); err != nil {
		panic("job failed: " + err.Error())
	}

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), caller, chain.Coins{{Denom, j.reward}})

	remember(id, caller, now, j.reward)
	totalRuns++
	totalPaid += j.reward

	chain.Emit("JobExecuted", "id", utoa(id), "by", caller.String(), "reward", itoa(j.reward))
}

// Cancel removes a job and sends its remaining balance to refundTo. Only the
// realm that registered the job may cancel it. It also frees the job's state,
// which releases the storage deposit to whoever sent the transaction, so it
// is how an owner cleans up a job that is done.
//
// A job may cancel itself from its own callback; that run is still paid.
func Cancel(cur realm, id uint64, refundTo address) {
	if running != 0 && running != id {
		panic("reentrant call")
	}
	j := mustJob(id)
	if cur.Previous().PkgPath() != j.owner {
		panic("only the owner realm can cancel a job")
	}
	if !refundTo.IsValid() {
		panic("invalid refund address")
	}

	refund := j.balance
	j.balance = 0
	held -= refund
	remove(j)

	if refund > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), refundTo, chain.Coins{{Denom, refund}})
	}

	chain.Emit("JobCancelled", "id", utoa(id), "refund", itoa(refund), "to", refundTo.String())
}

// notRunnable returns why a job cannot run at the given time, or "" if it can.
func notRunnable(j *job, now int64) string {
	switch {
	case j.done:
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
// skipped rather than replayed, and the grid never drifts. now must not be
// before due. Register bounds both due and interval, so this cannot overflow.
func nextSlot(due, interval, now int64) int64 {
	missed := (now - due) / interval
	return due + (missed+1)*interval
}

// index files a job in the queue under the key that matches its state: by
// due time if it can pay for a run, parked if it cannot or is done. It must
// be called after every change to a job's balance, due time or done flag.
func index(j *job) {
	slot := parkKey(j.id)
	if !j.done && j.balance >= j.reward {
		slot = dueKey(j.nextDue, j.id)
	}
	if slot == j.slot {
		return
	}
	if j.slot != "" {
		queue.Remove(j.slot)
	}
	queue.Set(slot, j)
	j.slot = slot
}

// remove deletes a job for good and frees the state it held.
func remove(j *job) {
	queue.Remove(j.slot)
	j.slot = ""
	jobs.Remove(key(j.id))
}

func mustJob(id uint64) *job {
	j, ok := jobs.Get(key(id)).(*job)
	if !ok {
		if id > 0 && id < nextID {
			panic("job " + utoa(id) + " was cancelled")
		}
		panic("unknown job " + utoa(id))
	}
	return j
}

// validName reports whether s can be stored and shown as a job name: valid
// UTF-8 with no control characters, and something left to read once
// invisible characters are taken out.
func validName(s string) bool {
	if s == "" || len(s) > MaxNameLen || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) {
			return false
		}
	}
	return strings.TrimSpace(sanitize.StripBidiAndZeroWidth(s)) != ""
}

// key zero-pads an id so that a tree iterates in numeric order.
func key(id uint64) string { return pad(utoa(id), 12) }

// dueKey sorts by due time, then by id.
func dueKey(due int64, id uint64) string { return pad(itoa(due), 12) + key(id) }

// parkKey sorts after every dueKey, and is exactly as long as one, so that a
// job moving between the two does not change the size of the state.
func parkKey(id uint64) string { return "z" + pad(utoa(id), 23) }

func pad(s string, width int) string {
	for len(s) < width {
		s = "0" + s
	}
	return s
}

func utoa(n uint64) string { return strconv.FormatUint(n, 10) }
func itoa(n int64) string  { return strconv.FormatInt(n, 10) }
