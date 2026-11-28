// Package market is Assertpay's task state machine, kept pure: it takes
// heights, addresses and amounts as arguments and returns the payments to
// make. The realm owns the coins and decides who may call what and when.
//
// A task is funded on a spec. Solvers commit a hash with a bond, then
// reveal an implementation whose test results the realm passes in. Passing
// attempts are ordered by commit height; the earliest one not removed is
// the winner. During the window anyone may challenge the winner with a
// seed of their choice; a failure removes it and pays its bond to the
// challenger. After the window the winner can be paid.
package market

import "errors"

// Parameters, in blocks and ugnot.
const (
	Expiry      = 600       // a commit must be revealed within this many blocks
	Window      = 120       // challenge window after a new winner
	Grace       = 60        // blocks to complete an opened challenge
	MinBond     = 1_000_000 // 1 GNOT
	BondDivisor = 10        // bond = max(MinBond, reward / BondDivisor)
	MinReward   = 1_000_000
	MinDeadline = 200
	MaxDeadline = 200_000
)

var (
	ErrClosed       = errors.New("task is closed")
	ErrDeadline     = errors.New("commits are closed: the deadline has passed")
	ErrLiveCommit   = errors.New("you already have a live commit on this task")
	ErrNoCommit     = errors.New("no live commit matches this reveal")
	ErrNoWinner     = errors.New("no winner to challenge")
	ErrWindowOver   = errors.New("the challenge window is over")
	ErrOpenChal     = errors.New("a challenge is already open")
	ErrNoOpenChal   = errors.New("no open challenge")
	ErrGraceRunning = errors.New("the challenge can still be run")
	ErrNotClaimable = errors.New("not claimable yet")
	ErrNotRefund    = errors.New("not refundable: deadline not passed, or a winner, live commit or challenge exists")
	ErrBadParams    = errors.New("bad parameters")
)

// State of a task.
const (
	Open     = "open"
	Paid     = "paid"
	Refunded = "refunded"
)

// Payment is a transfer the realm must make.
type Payment struct {
	To     address
	Amount int64
	Why    string
}

// Commit is a sealed promise to reveal.
type Commit struct {
	Hash      string
	Who       address
	Height    int64
	Revealed  bool
	Forfeited bool
}

// Attempt is one revealed implementation and its results.
type Attempt struct {
	ID       int
	Who      address
	Entry    string // realm that revealed it
	CommitH  int64
	Height   int64
	Seed     uint64
	Passed   int
	Total    int
	Fail     string // first failure, "Name: message"
	Bits     string // one char per test, 'p' or 'f'
	Removed  bool   // knocked out by a challenge
	BondHeld bool   // bond locked because it passed
	Impl     any    // what was submitted, kept for challenges
}

// Challenge is a recorded challenge of the winner.
type Challenge struct {
	Who     address
	Target  int // attempt id
	Seed    uint64
	Height  int64
	Bond    int64 // only for the open (two-phase) kind
	Open    bool
	Outcome string // "held", "broke", "timeout"
	Fail    string
	Bits    string
}

// Task is one funded spec.
type Task struct {
	ID         int
	Spec       string
	Sponsor    address
	Reward     int64
	Bond       int64
	Created    int64
	Deadline   int64
	State      string
	Commits    []*Commit
	Attempts   []*Attempt
	Challenges []*Challenge
	WinnerID   int // -1 when none
	WindowEnd  int64
	Forfeit    int64 // expired bonds (kept out of the reward)
}

// NewTask validates and opens a task.
func NewTask(id int, spec string, sponsor address, reward int64, now, deadlineBlocks int64) *Task {
	if reward < MinReward || deadlineBlocks < MinDeadline || deadlineBlocks > MaxDeadline || spec == "" {
		panic(ErrBadParams)
	}
	bond := reward / BondDivisor
	if bond < MinBond {
		bond = MinBond
	}
	return &Task{ID: id, Spec: spec, Sponsor: sponsor, Reward: reward, Bond: bond, Created: now, Deadline: now + deadlineBlocks, State: Open, WinnerID: -1}
}

func (t *Task) mustOpen() {
	if t.State != Open {
		panic(ErrClosed)
	}
}

// Live reports whether a commit can still be revealed at now.
func (c *Commit) Live(now int64) bool {
	return !c.Revealed && !c.Forfeited && now-c.Height <= Expiry
}

// Sweep forfeits expired commits and returns how much bond moved to the
// forfeit pool. Every state change calls it first.
func (t *Task) Sweep(now int64) int64 {
	var moved int64
	for _, c := range t.Commits {
		if !c.Revealed && !c.Forfeited && now-c.Height > Expiry {
			c.Forfeited = true
			t.Forfeit += t.Bond
			moved += t.Bond
		}
	}
	return moved
}

// AddCommit records a commit; the caller has already received the bond.
func (t *Task) AddCommit(who address, hash string, now int64) {
	t.mustOpen()
	t.Sweep(now)
	if now > t.Deadline {
		panic(ErrDeadline)
	}
	for _, c := range t.Commits {
		if c.Who == who && c.Live(now) {
			panic(ErrLiveCommit)
		}
	}
	t.Commits = append(t.Commits, &Commit{Hash: hash, Who: who, Height: now})
}

// FindCommit returns the live commit with hash by who.
func (t *Task) FindCommit(who address, hash string, now int64) *Commit {
	t.mustOpen()
	t.Sweep(now)
	for _, c := range t.Commits {
		if c.Hash == hash && c.Who == who && c.Live(now) {
			return c
		}
	}
	panic(ErrNoCommit)
}

// Result summarises a test run for the market.
type Result struct {
	Seed   uint64
	Passed int
	Total  int
	Fail   string
	Bits   string
}

// Pass reports whether every test passed.
func (r Result) Pass() bool { return r.Total > 0 && r.Passed == r.Total }

// Reveal records an attempt for commit c. A failing attempt gets its bond
// back now; a passing one keeps it locked and may become the winner.
func (t *Task) Reveal(c *Commit, entry string, impl any, res Result, now int64) (*Attempt, []Payment) {
	c.Revealed = true
	a := &Attempt{ID: len(t.Attempts), Who: c.Who, Entry: entry, CommitH: c.Height, Height: now, Seed: res.Seed,
		Passed: res.Passed, Total: res.Total, Fail: res.Fail, Bits: res.Bits, Impl: impl}
	t.Attempts = append(t.Attempts, a)
	if !res.Pass() {
		return a, []Payment{{To: c.Who, Amount: t.Bond, Why: "bond back: attempt failed"}}
	}
	a.BondHeld = true
	t.elect(now)
	return a, nil
}

// elect picks the earliest-committed passing attempt not removed and
// restarts the window if the winner changed.
func (t *Task) elect(now int64) {
	best := -1
	for _, a := range t.Attempts {
		if !a.BondHeld || a.Removed {
			continue
		}
		if best < 0 || a.CommitH < t.Attempts[best].CommitH || (a.CommitH == t.Attempts[best].CommitH && a.ID < best) {
			best = a.ID
		}
	}
	if best != t.WinnerID {
		t.WinnerID = best
		if best >= 0 {
			t.WindowEnd = now + Window
		}
	}
}

// Winner returns the current winner or nil.
func (t *Task) Winner() *Attempt {
	if t.WinnerID < 0 {
		return nil
	}
	return t.Attempts[t.WinnerID]
}

// OpenChallenge returns the open two-phase challenge, if any.
func (t *Task) OpenChallenge() *Challenge {
	for _, c := range t.Challenges {
		if c.Open {
			return c
		}
	}
	return nil
}

func (t *Task) mustChallengeable(now int64) *Attempt {
	t.mustOpen()
	w := t.Winner()
	if w == nil {
		panic(ErrNoWinner)
	}
	if now > t.WindowEnd {
		panic(ErrWindowOver)
	}
	if t.OpenChallenge() != nil {
		panic(ErrOpenChal)
	}
	return w
}

// CheckChallenge validates a one-shot challenge before the realm runs it.
func (t *Task) CheckChallenge(now int64) *Attempt { return t.mustChallengeable(now) }

// Challenged records a one-shot challenge result. A failure removes the
// winner and pays its bond to the challenger.
func (t *Task) Challenged(who address, res Result, now int64) []Payment {
	w := t.mustChallengeable(now)
	ch := &Challenge{Who: who, Target: w.ID, Seed: res.Seed, Height: now, Fail: res.Fail, Bits: res.Bits}
	t.Challenges = append(t.Challenges, ch)
	if res.Pass() {
		ch.Outcome = "held"
		return nil
	}
	ch.Outcome = "broke"
	return t.knockOut(w, who, 0, now)
}

func (t *Task) knockOut(w *Attempt, challenger address, extra int64, now int64) []Payment {
	w.Removed = true
	w.BondHeld = false
	t.elect(now)
	return []Payment{{To: challenger, Amount: t.Bond + extra, Why: "challenge broke the winner"}}
}

// Open starts a two-phase challenge (for winners whose code aborts the
// transaction). The caller has received bond from the challenger.
func (t *Task) Open(who address, seed uint64, bond int64, now int64) *Challenge {
	w := t.mustChallengeable(now)
	if bond < t.Bond {
		panic(ErrBadParams)
	}
	ch := &Challenge{Who: who, Target: w.ID, Seed: seed, Height: now, Bond: bond, Open: true}
	t.Challenges = append(t.Challenges, ch)
	return ch
}

// RanOpen records the run of the open challenge.
func (t *Task) RanOpen(res Result, now int64) []Payment {
	ch := t.OpenChallenge()
	if ch == nil {
		panic(ErrNoOpenChal)
	}
	ch.Open = false
	ch.Fail, ch.Bits = res.Fail, res.Bits
	w := t.Attempts[ch.Target]
	if res.Pass() {
		ch.Outcome = "held"
		return []Payment{{To: w.Who, Amount: ch.Bond, Why: "challenger bond: winner held"}}
	}
	ch.Outcome = "broke"
	return t.knockOut(w, ch.Who, ch.Bond, now)
}

// TimeoutOpen resolves an open challenge that nobody could run in Grace
// blocks: the winner is removed.
func (t *Task) TimeoutOpen(now int64) []Payment {
	ch := t.OpenChallenge()
	if ch == nil {
		panic(ErrNoOpenChal)
	}
	if now-ch.Height <= Grace {
		panic(ErrGraceRunning)
	}
	ch.Open = false
	ch.Outcome = "timeout"
	return t.knockOut(t.Attempts[ch.Target], ch.Who, ch.Bond, now)
}

// Claim pays the winner after the window.
func (t *Task) Claim(now int64) []Payment {
	t.mustOpen()
	t.Sweep(now)
	w := t.Winner()
	if w == nil || now <= t.WindowEnd || t.OpenChallenge() != nil {
		panic(ErrNotClaimable)
	}
	t.State = Paid
	w.BondHeld = false
	pays := []Payment{{To: w.Who, Amount: t.Reward + t.Bond, Why: "reward and bond"}}
	// other passing attempts get their bonds back
	for _, a := range t.Attempts {
		if a.BondHeld {
			a.BondHeld = false
			pays = append(pays, Payment{To: a.Who, Amount: t.Bond, Why: "bond back: task closed"})
		}
	}
	return pays
}

// Refund returns the reward after the deadline when nothing is pending.
func (t *Task) Refund(now int64) []Payment {
	t.mustOpen()
	t.Sweep(now)
	if now <= t.Deadline || t.Winner() != nil || t.OpenChallenge() != nil {
		panic(ErrNotRefund)
	}
	for _, c := range t.Commits {
		if c.Live(now) {
			panic(ErrNotRefund)
		}
	}
	t.State = Refunded
	return []Payment{{To: t.Sponsor, Amount: t.Reward, Why: "refund: no passing implementation"}}
}
