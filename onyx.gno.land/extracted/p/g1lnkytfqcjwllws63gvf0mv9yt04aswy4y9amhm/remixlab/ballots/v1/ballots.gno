// Package ballots is the Remix Lab public-ballot block: single-choice polls
// with fixed options, an electorate captured at opening, one vote per
// eligible address, integer quorum and deterministic tie handling.
//
// Lifecycle: Create (draft) -> Open (options, rules and electorate freeze;
// the deadline starts) -> Finalize (any caller, once the deadline passed).
// A draft can be cancelled, which removes it. Early closure of an open
// ballot is not supported. Deadlines are only evaluated when a transaction
// or read happens; nothing closes a ballot automatically.
//
// MaxBallots bounds ballots that are not finalized (drafts and open
// ballots), so finalized history never blocks new ballots. Public ballots
// bound neither voters nor votes; each voter pays for their own vote's
// storage and nothing iterates over votes.
//
// Like every Remix Lab block, a *Box must stay in an unexported host-realm
// variable. The host authenticates callers and passes their address; the Box
// never trusts an address it did not receive from the host.
package ballots

import (
	"strconv"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/nt/avl/v0"
)

// Hard bounds that no configuration may exceed.
const (
	HardMaxOptions    = 20
	HardMaxElectorate = 1000
	HardMaxBallots    = 1000
	HardMaxTextBytes  = 512
)

// Config is fixed at construction. Each ballot copies the rules it depends
// on when it is created, so they never change underneath an open ballot.
type Config struct {
	MaxBallots     int // drafts plus open ballots at any one time
	MaxOptions     int
	MaxElectorate  int
	QuorumPercent  int   // 0..100, of the captured electorate
	AllowAbstain   bool  // voters may cast an explicit abstention
	MinDuration    int64 // seconds
	MaxDuration    int64 // seconds
	MaxTitleBytes  int
	MaxOptionBytes int
}

// DefaultConfig returns the starting limits proposed for the MVP.
func DefaultConfig() Config {
	return Config{
		MaxBallots:     100,
		MaxOptions:     20,
		MaxElectorate:  100,
		QuorumPercent:  0,
		AllowAbstain:   false,
		MinDuration:    60,
		MaxDuration:    30 * 24 * 3600,
		MaxTitleBytes:  140,
		MaxOptionBytes: 80,
	}
}

// Validate checks configuration bounds.
func (c Config) Validate() error {
	switch {
	case c.MaxBallots < 1 || c.MaxBallots > HardMaxBallots:
		return core.Errorf(core.ErrInvalidInput, "maxBallots out of range")
	case c.MaxOptions < 2 || c.MaxOptions > HardMaxOptions:
		return core.Errorf(core.ErrInvalidInput, "maxOptions out of range")
	case c.MaxElectorate < 1 || c.MaxElectorate > HardMaxElectorate:
		return core.Errorf(core.ErrInvalidInput, "maxElectorate out of range")
	case c.QuorumPercent < 0 || c.QuorumPercent > 100:
		return core.Errorf(core.ErrInvalidInput, "quorumPercent out of range")
	case c.MinDuration < 1 || c.MaxDuration < c.MinDuration:
		return core.Errorf(core.ErrInvalidInput, "duration bounds")
	case c.MaxTitleBytes < 1 || c.MaxTitleBytes > HardMaxTextBytes:
		return core.Errorf(core.ErrInvalidInput, "maxTitleBytes out of range")
	case c.MaxOptionBytes < 1 || c.MaxOptionBytes > HardMaxTextBytes:
		return core.Errorf(core.ErrInvalidInput, "maxOptionBytes out of range")
	}
	return nil
}

// Abstain is the choice value for an abstention.
const Abstain = -1

type ballot struct {
	id           uint64
	creator      address
	title        string
	options      []string
	duration     int64
	quorum       int
	allowAbstain bool

	status     core.BallotStatus
	public     bool
	electorate *avl.Tree // address -> true; nil for public ballots
	openedAt   int64
	deadline   int64

	votes       *avl.Tree // address -> int choice
	counts      []int
	abstentions int

	outcome core.BallotOutcome
	winner  int
}

// Box holds a bounded set of ballots.
type Box struct {
	cfg     Config
	ballots *avl.Tree // zero-padded id -> *ballot
	nextID  uint64
	active  int // drafts plus open ballots
}

// NewBox creates an empty box. It panics on invalid configuration.
func NewBox(cfg Config) *Box {
	if err := cfg.Validate(); err != nil {
		panic(err.Error())
	}
	return &Box{cfg: cfg, ballots: avl.NewTree()}
}

// Config returns the box configuration.
func (b *Box) Config() Config { return b.cfg }

// Count returns the number of ballots, finalized ones included.
func (b *Box) Count() int { return b.ballots.Size() }

// Active returns the number of drafts and open ballots.
func (b *Box) Active() int { return b.active }

// Create adds a draft ballot. Options are copied. creator must be the
// authenticated caller.
func (b *Box) Create(creator address, title string, options []string, duration int64) (uint64, error) {
	if !creator.IsValid() {
		return 0, core.Errorf(core.ErrInvalidInput, "invalid creator")
	}
	if b.active >= b.cfg.MaxBallots {
		return 0, core.Errorf(core.ErrLimitExceeded, "too many active ballots")
	}
	if err := core.CheckText("title", title, 1, b.cfg.MaxTitleBytes, false); err != nil {
		return 0, err
	}
	if len(options) < 2 {
		return 0, core.Errorf(core.ErrInvalidInput, "at least two options required")
	}
	if len(options) > b.cfg.MaxOptions {
		return 0, core.Errorf(core.ErrLimitExceeded, "too many options")
	}
	opts := make([]string, len(options))
	seen := map[string]bool{}
	for i, o := range options {
		if err := core.CheckText("option", o, 1, b.cfg.MaxOptionBytes, false); err != nil {
			return 0, err
		}
		if seen[o] {
			return 0, core.Errorf(core.ErrInvalidInput, "duplicate option")
		}
		seen[o] = true
		opts[i] = o
	}
	if duration < b.cfg.MinDuration || duration > b.cfg.MaxDuration {
		return 0, core.Errorf(core.ErrInvalidInput, "duration out of range")
	}
	b.nextID++
	id := b.nextID
	b.ballots.Set(key(id), &ballot{
		id:           id,
		creator:      creator,
		title:        title,
		options:      opts,
		duration:     duration,
		quorum:       b.cfg.QuorumPercent,
		allowAbstain: b.cfg.AllowAbstain,
		status:       core.BallotDraft,
		counts:       make([]int, len(opts)),
		winner:       -1,
	})
	b.active++
	return id, nil
}

// CancelDraft removes a ballot that was never opened. The host must have
// authorized the actor.
func (b *Box) CancelDraft(id uint64) error {
	if _, err := b.draft(id); err != nil {
		return err
	}
	b.ballots.Remove(key(id))
	b.active--
	return nil
}

// Creator returns the address that created ballot id.
func (b *Box) Creator(id uint64) (address, bool) {
	bl := b.get(id)
	if bl == nil {
		return "", false
	}
	return bl.creator, true
}

// OpenWithElectorate opens a draft ballot restricted to voters. The list is
// copied; later membership changes do not affect this ballot.
func (b *Box) OpenWithElectorate(id uint64, now int64, voters []address) error {
	bl, err := b.draft(id)
	if err != nil {
		return err
	}
	if err := bl.checkOpenTime(now); err != nil {
		return err
	}
	if len(voters) == 0 {
		return core.Errorf(core.ErrInvalidInput, "empty electorate")
	}
	el := avl.NewTree()
	for _, v := range voters {
		if !v.IsValid() {
			return core.Errorf(core.ErrInvalidInput, "invalid voter address")
		}
		el.Set(v.String(), true)
		if el.Size() > b.cfg.MaxElectorate {
			return core.Errorf(core.ErrLimitExceeded, "electorate too large")
		}
	}
	bl.electorate = el
	bl.open(now)
	return nil
}

// OpenPublic opens a draft ballot to any address. Percentage quorum needs a
// known electorate, so public ballots require QuorumPercent == 0.
func (b *Box) OpenPublic(id uint64, now int64) error {
	bl, err := b.draft(id)
	if err != nil {
		return err
	}
	if bl.quorum != 0 {
		return core.Errorf(core.ErrInvalidState, "public ballots cannot use a percentage quorum")
	}
	if err := bl.checkOpenTime(now); err != nil {
		return err
	}
	bl.public = true
	bl.open(now)
	return nil
}

// Vote records voter's choice. voter must be the authenticated caller.
// Votes are final.
func (b *Box) Vote(id uint64, voter address, choice int, now int64) error {
	bl := b.get(id)
	if bl == nil {
		return core.Errorf(core.ErrNotFound, "ballot")
	}
	if bl.status != core.BallotOpen {
		return core.Errorf(core.ErrInvalidState, "ballot is not open")
	}
	if now >= bl.deadline {
		return core.Errorf(core.ErrInvalidState, "voting period has ended")
	}
	if !bl.eligible(voter) {
		return core.Errorf(core.ErrUnauthorized, "not in the electorate")
	}
	if bl.votes.Has(voter.String()) {
		return core.Errorf(core.ErrConflict, "already voted")
	}
	switch {
	case choice == Abstain && bl.allowAbstain:
		bl.abstentions++
	case choice >= 0 && choice < len(bl.options):
		bl.counts[choice]++
	default:
		return core.Errorf(core.ErrInvalidInput, "invalid choice")
	}
	bl.votes.Set(voter.String(), choice)
	return nil
}

// Finalize commits the result once the deadline has passed. Any caller may
// finalize; the outcome depends only on rules fixed at opening.
func (b *Box) Finalize(id uint64, now int64) (core.BallotView, error) {
	bl := b.get(id)
	if bl == nil {
		return core.BallotView{}, core.Errorf(core.ErrNotFound, "ballot")
	}
	if bl.status != core.BallotOpen {
		return core.BallotView{}, core.Errorf(core.ErrInvalidState, "ballot is not open")
	}
	if now < bl.deadline {
		return core.BallotView{}, core.Errorf(core.ErrInvalidState, "deadline not reached")
	}
	bl.outcome, bl.winner = bl.compute()
	bl.status = core.BallotFinalized
	b.active--
	return bl.view(), nil
}

// Ballot implements core.BallotReader.
func (b *Box) Ballot(id uint64) (core.BallotView, bool) {
	bl := b.get(id)
	if bl == nil {
		return core.BallotView{}, false
	}
	return bl.view(), true
}

// List returns up to limit ballots, newest first.
func (b *Box) List(offset, limit int) []core.BallotView {
	var out []core.BallotView
	if offset < 0 || limit <= 0 {
		return out
	}
	b.ballots.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
		out = append(out, v.(*ballot).view())
		return false
	})
	return out
}

// HasVoted reports whether voter has cast a ballot (including abstention).
func (b *Box) HasVoted(id uint64, voter address) bool {
	bl := b.get(id)
	return bl != nil && bl.votes != nil && bl.votes.Has(voter.String())
}

// Eligible reports whether voter belongs to an open ballot's electorate. It
// ignores the deadline and whether voter has already voted.
func (b *Box) Eligible(id uint64, voter address) bool {
	bl := b.get(id)
	return bl != nil && bl.status == core.BallotOpen && bl.eligible(voter)
}

// InElectorate reports whether voter belongs to the ballot's frozen
// electorate (always true for public ballots once open).
func (b *Box) InElectorate(id uint64, voter address) bool {
	bl := b.get(id)
	return bl != nil && bl.status != core.BallotDraft && bl.eligible(voter)
}

func (b *Box) get(id uint64) *ballot {
	v := b.ballots.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*ballot)
}

func (b *Box) draft(id uint64) (*ballot, error) {
	bl := b.get(id)
	if bl == nil {
		return nil, core.Errorf(core.ErrNotFound, "ballot")
	}
	if bl.status != core.BallotDraft {
		return nil, core.Errorf(core.ErrInvalidState, "ballot already opened")
	}
	return bl, nil
}

// checkOpenTime rejects clocks that are unset or would overflow the
// deadline.
func (bl *ballot) checkOpenTime(now int64) error {
	const maxInt64 = int64(^uint64(0) >> 1)
	if now <= 0 || now > maxInt64-bl.duration {
		return core.Errorf(core.ErrInvalidInput, "invalid opening time")
	}
	return nil
}

func (bl *ballot) open(now int64) {
	bl.status = core.BallotOpen
	bl.openedAt = now
	bl.deadline = now + bl.duration
	bl.votes = avl.NewTree()
}

func (bl *ballot) eligible(voter address) bool {
	if bl.public {
		return voter.IsValid()
	}
	return bl.electorate != nil && bl.electorate.Has(voter.String())
}

func (bl *ballot) turnout() int {
	if bl.votes == nil {
		return 0
	}
	return bl.votes.Size()
}

func (bl *ballot) electorateSize() int {
	if bl.electorate == nil {
		return 0
	}
	return bl.electorate.Size()
}

// compute derives the outcome from the frozen rules and recorded votes.
// Integer arithmetic only: quorum is met when turnout*100 >= quorum*size.
func (bl *ballot) compute() (core.BallotOutcome, int) {
	turnout := bl.turnout()
	if turnout == 0 {
		return core.OutcomeNoVotes, -1
	}
	if !bl.public && turnout*100 < bl.quorum*bl.electorateSize() {
		return core.OutcomeNoQuorum, -1
	}
	best, bestCount, tie := -1, 0, false
	for i, c := range bl.counts {
		switch {
		case c > bestCount:
			best, bestCount, tie = i, c, false
		case c == bestCount && c > 0:
			tie = true
		}
	}
	if bestCount == 0 {
		return core.OutcomeNoVotes, -1
	}
	if tie {
		return core.OutcomeTie, -1
	}
	return core.OutcomeWinner, best
}

func (bl *ballot) view() core.BallotView {
	opts := make([]string, len(bl.options))
	copy(opts, bl.options)
	counts := make([]int, len(bl.counts))
	copy(counts, bl.counts)
	return core.BallotView{
		ID:             bl.id,
		Title:          bl.title,
		Options:        opts,
		Status:         bl.status,
		Public:         bl.public,
		ElectorateSize: bl.electorateSize(),
		QuorumPercent:  bl.quorum,
		OpenedAt:       bl.openedAt,
		Deadline:       bl.deadline,
		Counts:         counts,
		Abstentions:    bl.abstentions,
		Turnout:        bl.turnout(),
		Outcome:        bl.outcome,
		Winner:         bl.winner,
	}
}

func key(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}
