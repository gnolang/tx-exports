package gauntlet

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Status of a challenge.
type Status int

const (
	Open   Status = iota // accepting commits until the deadline
	Won                  // paid out to the earliest passing commit
	Closed               // nobody passed; reward returned to the poster
)

func (s Status) String() string {
	switch s {
	case Open:
		return "open"
	case Won:
		return "won"
	case Closed:
		return "closed"
	}
	return "unknown"
}

// State of an attempt.
type State int

const (
	Pending State = iota // committed, not yet revealed
	Passed               // revealed and passed every test
	Failed               // revealed and failed a test
	Expired              // not revealed in time; bond forfeited
	Refunded             // challenge ended before it was revealed; bond returned
)

func (s State) String() string {
	switch s {
	case Pending:
		return "pending"
	case Passed:
		return "passed"
	case Failed:
		return "failed"
	case Expired:
		return "expired"
	case Refunded:
		return "refunded"
	}
	return "unknown"
}

// Attempt is one solver's commit, and its result once revealed.
type Attempt struct {
	Seq         uint64 // global order of commits on the board
	Solver      address
	Hash        string
	CommittedAt time.Time
	State       State
	PkgPath     string // the solution realm, set on reveal
	RevealedAt  time.Time
	Report      Report
}

// Challenge is one bounty.
type Challenge struct {
	ID       uint64
	Title    string
	Spec     string // markdown
	Poster   address
	Reward   int64 // escrowed by the hosting realm
	Bond     int64 // required with every commit, refunded on reveal
	Created  time.Time
	Deadline time.Time     // last moment to commit
	Window   time.Duration // time allowed between commit and reveal

	Cases     []Case // fixed tests, may be empty if Judge is set
	Judge     *Judge
	JudgePath string // package path of the judge's code, for display

	Status    Status
	Winner    *Attempt
	Attempts  []*Attempt
	Forfeited int64 // expired bonds, added to the reward
	Boosts    int64 // reward added after posting
}

// Pot is what the winner (or, if nobody wins, the poster) receives.
func (c *Challenge) Pot() int64 { return c.Reward + c.Forfeited }

// Payout is an instruction for the hosting realm to send coins.
type Payout struct {
	To     address
	Amount int64
	Reason string
}

// PostParams describes a new challenge.
type PostParams struct {
	Title     string
	Spec      string
	Poster    address
	Reward    int64
	Bond      int64
	Deadline  time.Time
	Window    time.Duration
	Cases     []Case
	Judge     *Judge
	JudgePath string
}

const (
	MaxTitleLen   = 120
	MaxSpecLen    = 8000
	MaxAttempts   = 256
	MinWindow     = time.Minute
	MaxWindow     = 7 * 24 * time.Hour
	MaxPostLength = 90 * 24 * time.Hour
)

var (
	ErrNotFound       = errors.New("gauntlet: challenge not found")
	ErrNotOpen        = errors.New("gauntlet: challenge is not open")
	ErrPastDeadline   = errors.New("gauntlet: commits are closed for this challenge")
	ErrBadTitle       = errors.New("gauntlet: title must be 1-120 characters")
	ErrBadSpec        = errors.New("gauntlet: spec is too long")
	ErrBadReward      = errors.New("gauntlet: reward must be positive")
	ErrBadBond        = errors.New("gauntlet: bond cannot be negative")
	ErrBadDeadline    = errors.New("gauntlet: deadline must be in the future and within 90 days")
	ErrBadWindow      = errors.New("gauntlet: reveal window must be between 1 minute and 7 days")
	ErrNoTests        = errors.New("gauntlet: a challenge needs test cases or a judge")
	ErrBadHash        = errors.New("gauntlet: hash must be 64 hex characters")
	ErrWrongBond      = errors.New("gauntlet: wrong bond amount")
	ErrHasPending     = errors.New("gauntlet: you already have a pending commit on this challenge")
	ErrDuplicateHash  = errors.New("gauntlet: this hash was already committed")
	ErrFull           = errors.New("gauntlet: too many attempts on this challenge")
	ErrNoCommit       = errors.New("gauntlet: no pending commit matches this package path and salt")
	ErrRevealTooLate  = errors.New("gauntlet: reveal window has passed for this commit")
	ErrNotRealm       = errors.New("gauntlet: solutions must be revealed from a deployed /r/ realm")
	ErrBadBoostAmount = errors.New("gauntlet: boost must be positive")
)

// Board is a set of challenges. The zero value is ready to use.
type Board struct {
	challenges avl.Tree // key(id) -> *Challenge
	lastID     uint64
	seq        uint64
}

func key(id uint64) string {
	s := strconv.FormatUint(id, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

// HashSolution is the commitment a solver posts: sha256(pkgPath + ":" + salt)
// as lowercase hex.
func HashSolution(pkgPath, salt string) string {
	sum := sha256.Sum256([]byte(pkgPath + ":" + salt))
	return hex.EncodeToString(sum[:])
}

// Post adds a challenge. The caller must already hold p.Reward in escrow.
func (b *Board) Post(p PostParams, now time.Time) (*Challenge, error) {
	if len(p.Title) == 0 || len(p.Title) > MaxTitleLen {
		return nil, ErrBadTitle
	}
	if len(p.Spec) > MaxSpecLen {
		return nil, ErrBadSpec
	}
	if p.Reward <= 0 {
		return nil, ErrBadReward
	}
	if p.Bond < 0 {
		return nil, ErrBadBond
	}
	if !p.Deadline.After(now) || p.Deadline.Sub(now) > MaxPostLength {
		return nil, ErrBadDeadline
	}
	if p.Window < MinWindow || p.Window > MaxWindow {
		return nil, ErrBadWindow
	}
	if len(p.Cases) == 0 && p.Judge == nil {
		return nil, ErrNoTests
	}
	if len(p.Cases) > MaxCases {
		return nil, ErrTooManyCase
	}
	b.lastID++
	c := &Challenge{
		ID:        b.lastID,
		Title:     p.Title,
		Spec:      p.Spec,
		Poster:    p.Poster,
		Reward:    p.Reward,
		Bond:      p.Bond,
		Created:   now,
		Deadline:  p.Deadline,
		Window:    p.Window,
		Cases:     p.Cases,
		Judge:     p.Judge,
		JudgePath: p.JudgePath,
		Status:    Open,
	}
	b.challenges.Set(key(c.ID), c)
	return c, nil
}

// Get returns a challenge or nil.
func (b *Board) Get(id uint64) *Challenge {
	v := b.challenges.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*Challenge)
}

// Size is the number of challenges ever posted.
func (b *Board) Size() int { return b.challenges.Size() }

// Iterate visits challenges newest first. Return true to stop.
func (b *Board) Iterate(cb func(c *Challenge) bool) {
	b.challenges.ReverseIterate("", "", func(_ string, v any) bool {
		return cb(v.(*Challenge))
	})
}

// Commit records a solver's place in line.
func (b *Board) Commit(id uint64, solver address, hash string, bond int64, now time.Time) (*Attempt, error) {
	c := b.Get(id)
	if c == nil {
		return nil, ErrNotFound
	}
	if c.Status != Open {
		return nil, ErrNotOpen
	}
	if !now.Before(c.Deadline) {
		return nil, ErrPastDeadline
	}
	if bond != c.Bond {
		return nil, ErrWrongBond
	}
	if !isHexHash(hash) {
		return nil, ErrBadHash
	}
	if len(c.Attempts) >= MaxAttempts {
		return nil, ErrFull
	}
	for _, a := range c.Attempts {
		if a.Hash == hash {
			return nil, ErrDuplicateHash
		}
		if a.Solver == solver && a.State == Pending {
			return nil, ErrHasPending
		}
	}
	b.seq++
	a := &Attempt{
		Seq:         b.seq,
		Solver:      solver,
		Hash:        hash,
		CommittedAt: now,
		State:       Pending,
	}
	c.Attempts = append(c.Attempts, a)
	return a, nil
}

// Reveal grades a solution. pkgPath must be the package path of the realm
// that is calling, as reported by the runtime, never a value a user typed.
func (b *Board) Reveal(id uint64, pkgPath, salt string, solve Solver, now time.Time) (*Attempt, []Payout, error) {
	c := b.Get(id)
	if c == nil {
		return nil, nil, ErrNotFound
	}
	if !strings.Contains(pkgPath, "/r/") {
		return nil, nil, ErrNotRealm
	}
	hash := HashSolution(pkgPath, salt)
	var a *Attempt
	for _, x := range c.Attempts {
		if x.Hash == hash {
			a = x
			break
		}
	}
	if a == nil || a.State != Pending {
		return nil, nil, ErrNoCommit
	}
	if now.After(a.CommittedAt.Add(c.Window)) {
		return nil, nil, ErrRevealTooLate
	}

	a.PkgPath = pkgPath
	a.RevealedAt = now
	if c.Judge != nil {
		a.Report = GradeJudge(c.Judge, seedFor(hash, salt, now), solve)
	} else {
		a.Report = GradeCases(c.Cases, solve)
	}
	// A judged challenge with fixed cases runs both.
	if c.Judge != nil && len(c.Cases) > 0 && a.Report.OK() {
		fixed := GradeCases(c.Cases, solve)
		fixed.Passed += a.Report.Passed
		fixed.Total += a.Report.Total
		a.Report = fixed
	}
	if a.Report.OK() {
		a.State = Passed
	} else {
		a.State = Failed
	}

	var payouts []Payout
	if c.Bond > 0 {
		payouts = append(payouts, Payout{To: a.Solver, Amount: c.Bond, Reason: "bond refund"})
	}
	payouts = append(payouts, b.settle(c, now)...)
	return a, payouts, nil
}

// Settle moves a challenge forward: it expires late commits and, when the
// result is certain, pays the winner or returns the reward to the poster.
// Anyone may call it; it is also run after every reveal.
func (b *Board) Settle(id uint64, now time.Time) ([]Payout, error) {
	c := b.Get(id)
	if c == nil {
		return nil, ErrNotFound
	}
	return b.settle(c, now), nil
}

func (b *Board) settle(c *Challenge, now time.Time) []Payout {
	if c.Status != Open {
		return nil
	}
	var winner *Attempt
	for _, a := range c.Attempts { // already in commit order
		if a.State == Pending && now.After(a.CommittedAt.Add(c.Window)) {
			a.State = Expired
			c.Forfeited += c.Bond
		}
		switch a.State {
		case Pending:
			return nil // an earlier commit may still win; wait for it
		case Passed:
			winner = a
		}
		if winner != nil {
			break
		}
	}

	var payouts []Payout
	if winner != nil {
		c.Status = Won
		c.Winner = winner
		payouts = append(payouts, Payout{To: winner.Solver, Amount: c.Pot(), Reason: "bounty won"})
	} else if !now.Before(c.Deadline) {
		c.Status = Closed
		payouts = append(payouts, Payout{To: c.Poster, Amount: c.Pot(), Reason: "no winner, reward returned"})
	} else {
		return nil
	}
	// Later commits did nothing wrong: return their bonds.
	for _, a := range c.Attempts {
		if a.State == Pending {
			a.State = Refunded
			if c.Bond > 0 {
				payouts = append(payouts, Payout{To: a.Solver, Amount: c.Bond, Reason: "bond refund, challenge ended"})
			}
		}
	}
	return payouts
}

// Boost adds to the reward of an open challenge.
func (b *Board) Boost(id uint64, amount int64, now time.Time) error {
	c := b.Get(id)
	if c == nil {
		return ErrNotFound
	}
	if c.Status != Open || !now.Before(c.Deadline) {
		return ErrNotOpen
	}
	if amount <= 0 {
		return ErrBadBoostAmount
	}
	c.Reward += amount
	c.Boosts += amount
	return nil
}

func isHexHash(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') {
			return false
		}
	}
	return true
}

// seedFor derives the judge seed from values fixed only at reveal time.
func seedFor(hash, salt string, now time.Time) uint64 {
	sum := sha256.Sum256([]byte(hash + ":" + salt + ":" + strconv.FormatInt(now.UnixNano(), 10)))
	return binary.BigEndian.Uint64(sum[:8])
}
