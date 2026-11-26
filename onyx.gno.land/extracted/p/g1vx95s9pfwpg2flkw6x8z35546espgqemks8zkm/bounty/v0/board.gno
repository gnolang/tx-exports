package bounty

import (
	"errors"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	ErrNotFound      = errors.New("bounty: not found")
	ErrNotOpen       = errors.New("bounty: bounty is not open")
	ErrNotClaimed    = errors.New("bounty: bounty is not claimed")
	ErrNotSubmitted  = errors.New("bounty: bounty has no pending submission")
	ErrNotPoster     = errors.New("bounty: only the poster can do this")
	ErrNotHunter     = errors.New("bounty: only the current hunter can do this")
	ErrOwnBounty     = errors.New("bounty: you cannot claim your own bounty")
	ErrClaimExpired  = errors.New("bounty: claim window has expired")
	ErrClaimActive   = errors.New("bounty: claim window has not expired yet")
	ErrReviewActive  = errors.New("bounty: review window has not expired yet")
	ErrRewardTooLow  = errors.New("bounty: reward is below the board minimum")
	ErrBadTitle      = errors.New("bounty: title must be 1-80 characters")
	ErrBadDesc       = errors.New("bounty: description is too long")
	ErrBadProof      = errors.New("bounty: proof must be 1-280 characters")
	ErrBadNote       = errors.New("bounty: note is too long")
	ErrBadWindow     = errors.New("bounty: claim window out of range")
	ErrInvalidCaller = errors.New("bounty: invalid caller address")
)

const (
	MaxTitleLen = 80
	MaxDescLen  = 2000
	MaxProofLen = 280
	MaxNoteLen  = 280
)

// Config tunes a Board. Zero values fall back to DefaultConfig.
type Config struct {
	MinReward      int64         // smallest reward accepted by Post
	MinClaimWindow time.Duration // shortest claim window a poster may set
	MaxClaimWindow time.Duration // longest claim window a poster may set
	ReviewWindow   time.Duration // after this, an unreviewed submission can be collected by the hunter
}

// DefaultConfig is used for every zero field of the Config passed to NewBoard.
var DefaultConfig = Config{
	MinReward:      1_000_000, // 1 GNOT in ugnot
	MinClaimWindow: time.Hour,
	MaxClaimWindow: 30 * 24 * time.Hour,
	ReviewWindow:   72 * time.Hour,
}

// Board is a bounty board. Keep it unexported in your realm and expose only
// crossing functions: whoever holds the pointer can mutate it.
type Board struct {
	cfg      Config
	ids      seqid.ID
	bounties *avl.Tree // seqid binary key -> *Bounty
	stats    *avl.Tree // address string -> *Stats

	escrowed int64 // rewards currently locked (open, claimed, submitted)
	paid     int64 // rewards paid out over the board's life
}

// NewBoard creates an empty board.
func NewBoard(cfg Config) *Board {
	if cfg.MinReward <= 0 {
		cfg.MinReward = DefaultConfig.MinReward
	}
	if cfg.MinClaimWindow <= 0 {
		cfg.MinClaimWindow = DefaultConfig.MinClaimWindow
	}
	if cfg.MaxClaimWindow <= 0 {
		cfg.MaxClaimWindow = DefaultConfig.MaxClaimWindow
	}
	if cfg.ReviewWindow <= 0 {
		cfg.ReviewWindow = DefaultConfig.ReviewWindow
	}
	return &Board{
		cfg:      cfg,
		bounties: avl.NewTree(),
		stats:    avl.NewTree(),
	}
}

// Config returns the board configuration.
func (bd *Board) Config() Config { return bd.cfg }

// Escrowed is the sum of rewards the owning realm must currently hold.
func (bd *Board) Escrowed() int64 { return bd.escrowed }

// TotalPaid is the sum of rewards paid out so far.
func (bd *Board) TotalPaid() int64 { return bd.paid }

// Size is the number of bounties ever posted.
func (bd *Board) Size() int { return bd.bounties.Size() }

// ReviewDeadline is the time after which the hunter may collect an
// unreviewed submission.
func (bd *Board) ReviewDeadline(b *Bounty) time.Time {
	return b.SubmittedAt.Add(bd.cfg.ReviewWindow)
}

// Post creates a new open bounty. The caller (realm) must already hold reward
// in escrow when calling this.
func (bd *Board) Post(poster address, title, description string, reward int64, claimWindow time.Duration, now time.Time) (*Bounty, error) {
	if !poster.IsValid() {
		return nil, ErrInvalidCaller
	}
	title = strings.TrimSpace(title)
	if len(title) == 0 || len(title) > MaxTitleLen {
		return nil, ErrBadTitle
	}
	description = strings.TrimSpace(description)
	if len(description) > MaxDescLen {
		return nil, ErrBadDesc
	}
	if reward < bd.cfg.MinReward {
		return nil, ErrRewardTooLow
	}
	if claimWindow < bd.cfg.MinClaimWindow || claimWindow > bd.cfg.MaxClaimWindow {
		return nil, ErrBadWindow
	}

	id := bd.ids.Next()
	b := &Bounty{
		ID:          uint64(id),
		Title:       title,
		Description: description,
		Poster:      poster,
		Reward:      reward,
		Status:      StatusOpen,
		ClaimWindow: claimWindow,
		CreatedAt:   now,
	}
	b.log(now, poster, "posted", "")
	bd.bounties.Set(id.Binary(), b)

	bd.escrowed += reward
	bd.statsOf(poster).Posted++
	return b, nil
}

// Claim reserves an open bounty for hunter for the bounty's claim window.
func (bd *Board) Claim(id uint64, hunter address, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if !hunter.IsValid() {
		return nil, ErrInvalidCaller
	}
	if b.Status != StatusOpen {
		return nil, ErrNotOpen
	}
	if hunter == b.Poster {
		return nil, ErrOwnBounty
	}
	b.Status = StatusClaimed
	b.Hunter = hunter
	b.Proof = ""
	b.ClaimedAt = now
	b.log(now, hunter, "claimed", "")
	bd.statsOf(hunter) // make the hunter show up on the board
	return b, nil
}

// Unclaim lets the current hunter give a claimed bounty back voluntarily
// (counts as abandoned, but frees the task for others right away).
func (bd *Board) Unclaim(id uint64, hunter address, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusClaimed {
		return nil, ErrNotClaimed
	}
	if hunter != b.Hunter {
		return nil, ErrNotHunter
	}
	bd.reopen(b, hunter, "released", "given back by hunter", now)
	bd.statsOf(hunter).Abandoned++
	return b, nil
}

// Release reopens a bounty whose claim window expired without a submission.
// Anyone may call it.
func (bd *Board) Release(id uint64, caller address, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusClaimed {
		return nil, ErrNotClaimed
	}
	if !b.ClaimExpired(now) {
		return nil, ErrClaimActive
	}
	bd.statsOf(b.Hunter).Abandoned++
	bd.reopen(b, caller, "released", "claim expired", now)
	return b, nil
}

// Submit records the hunter's proof of work. Submitting again before review
// replaces the proof.
func (bd *Board) Submit(id uint64, hunter address, proof string, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusClaimed && b.Status != StatusSubmitted {
		return nil, ErrNotClaimed
	}
	if hunter != b.Hunter {
		return nil, ErrNotHunter
	}
	if b.Status == StatusClaimed && b.ClaimExpired(now) {
		return nil, ErrClaimExpired
	}
	proof = strings.TrimSpace(proof)
	if len(proof) == 0 || len(proof) > MaxProofLen {
		return nil, ErrBadProof
	}
	b.Status = StatusSubmitted
	b.Proof = proof
	b.SubmittedAt = now
	b.log(now, hunter, "submitted", proof)
	return b, nil
}

// Approve accepts the submission. The owning realm must pay b.Reward to
// b.Hunter after a successful call.
func (bd *Board) Approve(id uint64, poster address, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusSubmitted {
		return nil, ErrNotSubmitted
	}
	if poster != b.Poster {
		return nil, ErrNotPoster
	}
	bd.settle(b, poster, "paid", now)
	return b, nil
}

// Collect lets the hunter take the reward when the poster did not review the
// submission within the board's review window. The owning realm must pay
// b.Reward to b.Hunter after a successful call.
func (bd *Board) Collect(id uint64, hunter address, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusSubmitted {
		return nil, ErrNotSubmitted
	}
	if hunter != b.Hunter {
		return nil, ErrNotHunter
	}
	if !now.After(bd.ReviewDeadline(b)) {
		return nil, ErrReviewActive
	}
	bd.settle(b, hunter, "auto-paid", now)
	return b, nil
}

// Reject declines the submission and reopens the bounty for everyone.
func (bd *Board) Reject(id uint64, poster address, reason string, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusSubmitted {
		return nil, ErrNotSubmitted
	}
	if poster != b.Poster {
		return nil, ErrNotPoster
	}
	reason = strings.TrimSpace(reason)
	if len(reason) > MaxNoteLen {
		return nil, ErrBadNote
	}
	bd.statsOf(b.Hunter).Rejected++
	bd.statsOf(poster).RejectionsMade++
	bd.reopen(b, poster, "rejected", reason, now)
	return b, nil
}

// Cancel withdraws an open bounty. The owning realm must refund b.Reward to
// b.Poster after a successful call.
func (bd *Board) Cancel(id uint64, poster address, now time.Time) (*Bounty, error) {
	b, err := bd.mustGet(id)
	if err != nil {
		return nil, err
	}
	if b.Status != StatusOpen {
		return nil, ErrNotOpen
	}
	if poster != b.Poster {
		return nil, ErrNotPoster
	}
	b.Status = StatusCancelled
	b.ClosedAt = now
	b.log(now, poster, "cancelled", "")
	bd.escrowed -= b.Reward
	bd.statsOf(poster).Cancelled++
	return b, nil
}

// Get returns a bounty by id.
func (bd *Board) Get(id uint64) (*Bounty, bool) {
	v := bd.bounties.Get(seqid.ID(id).Binary())
	if v == nil {
		return nil, false
	}
	return v.(*Bounty), true
}

// Filter selects bounties for List. A nil Filter matches everything.
type Filter func(b *Bounty) bool

// ByStatus matches bounties in one of the given states.
func ByStatus(states ...Status) Filter {
	return func(b *Bounty) bool {
		for _, s := range states {
			if b.Status == s {
				return true
			}
		}
		return false
	}
}

// ByAddress matches bounties posted or hunted by addr.
func ByAddress(addr address) Filter {
	return func(b *Bounty) bool { return b.Poster == addr || b.Hunter == addr }
}

// List returns up to limit bounties matching f, newest first, skipping the
// first offset matches. It also returns the total number of matches.
func (bd *Board) List(f Filter, offset, limit int) (page []*Bounty, total int) {
	bd.bounties.ReverseIterate("", "", func(_ string, v any) bool {
		b := v.(*Bounty)
		if f != nil && !f(b) {
			return false
		}
		if total >= offset && len(page) < limit {
			page = append(page, b)
		}
		total++
		return false
	})
	return page, total
}

// Count returns how many bounties match f.
func (bd *Board) Count(f Filter) int {
	_, total := bd.List(f, 0, 0)
	return total
}

// Stats returns the reputation of addr (zero Stats if unknown).
func (bd *Board) Stats(addr address) Stats {
	v := bd.stats.Get(addr.String())
	if v == nil {
		return Stats{Address: addr}
	}
	return *(v.(*Stats))
}

// Participants is the number of distinct addresses that posted or claimed.
func (bd *Board) Participants() int { return bd.stats.Size() }

// Leaderboard returns the top n hunters by Score, then by Earned.
func (bd *Board) Leaderboard(n int) []Stats {
	var top []Stats
	bd.stats.Iterate("", "", func(_ string, v any) bool {
		s := *(v.(*Stats))
		if s.Completed == 0 {
			return false
		}
		// insertion into a small sorted slice
		i := len(top)
		for i > 0 && better(s, top[i-1]) {
			i--
		}
		if i >= n {
			return false
		}
		top = append(top, Stats{})
		copy(top[i+1:], top[i:])
		top[i] = s
		if len(top) > n {
			top = top[:n]
		}
		return false
	})
	return top
}

func better(a, b Stats) bool {
	if a.Score() != b.Score() {
		return a.Score() > b.Score()
	}
	return a.Earned > b.Earned
}

func (bd *Board) mustGet(id uint64) (*Bounty, error) {
	b, ok := bd.Get(id)
	if !ok {
		return nil, ErrNotFound
	}
	return b, nil
}

func (bd *Board) statsOf(addr address) *Stats {
	key := addr.String()
	if v := bd.stats.Get(key); v != nil {
		return v.(*Stats)
	}
	s := &Stats{Address: addr}
	bd.stats.Set(key, s)
	return s
}

func (bd *Board) reopen(b *Bounty, actor address, action, note string, now time.Time) {
	b.Status = StatusOpen
	b.Hunter = address("")
	b.ClaimedAt = time.Time{}
	b.SubmittedAt = time.Time{}
	b.log(now, actor, action, note)
}

func (bd *Board) settle(b *Bounty, actor address, action string, now time.Time) {
	b.Status = StatusPaid
	b.ClosedAt = now
	b.log(now, actor, action, "")
	bd.escrowed -= b.Reward
	bd.paid += b.Reward

	h := bd.statsOf(b.Hunter)
	h.Completed++
	h.Earned += b.Reward
	bd.statsOf(b.Poster).PaidOut += b.Reward
}
