// Package escrow holds the rules of a single-builder bounty escrow: the
// Quest type, its states and every legal move between them.
//
// The package is pure. It holds no coins, no banker and no storage. A realm
// that imports it keeps the *Quest values, moves the coins, and asks this
// package whether a move is allowed. Every move takes the acting address and
// the current block height as arguments, so the rules can be tested without a
// chain and cannot be bypassed by the caller's own logic.
//
// Moves that can release money (Cancel, Unclaim, Release, Approve, Reject,
// ClaimPayout) return a Payout telling the realm exactly whom to pay and how
// much; a zero Payout (Due() == false) means no coins move. A non-zero Payout
// is only ever returned together with a move into a final state (Paid or
// Cancelled), and a final quest accepts no further move, so a quest can
// produce at most one non-zero Payout.
//
// A realm using this package must:
//   - lock exactly Reward() in its own balance before calling NewQuest,
//   - apply the move first and send the coins of the returned Payout after,
//   - treat any returned error as fatal (panic) so the transaction reverts.
//
// States and moves:
//
//	(none)    Post (NewQuest)  anyone                        -> Open
//	Open      Claim            anyone except the poster      -> Claimed
//	Open      Cancel           poster                        -> Cancelled  refund Reward to poster
//	Claimed   Cancel ("close") poster                        -> Claimed, closing
//	Submitted Cancel ("close") poster                        -> Submitted, closing
//	Claimed   Submit(link)     builder, until work deadline  -> Submitted
//	Claimed   Unclaim          builder                       -> Open (closing: Cancelled, refund)
//	Claimed   Release          anyone, after work deadline   -> Open (closing: Cancelled, refund)
//	Submitted Approve          poster                        -> Paid       pay Reward to builder
//	Submitted Reject(reason)   poster, until review deadline -> Open (closing: Cancelled, refund)
//	Submitted ClaimPayout      builder, after review deadline-> Paid       pay Reward to builder
//
// Closing: a poster cannot take the reward back while a builder holds the
// quest, but can close it. The current builder keeps every right (submit,
// get approved, claim the timeout payout); any move that would put the quest
// back to Open ends it instead and refunds the poster. So a builder can hold
// a closing quest for at most one work window, and nobody can re-claim it.
// Closing cannot be undone.
//
// Deadlines are block heights. "Until" a deadline includes the deadline block
// itself; "after" a deadline starts at the next block.
package escrow

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Limits. Text limits count Unicode characters (runes).
const (
	MaxTitleLen   = 80
	MaxDetailsLen = 1000
	MaxLinkLen    = 300
	MaxReasonLen  = 300

	// Windows are in blocks. Measured block time on 2026-11-23 was about
	// 3.4 s (Onyx) to 3.5 s (mainnet); the values below assume 3.5 s.
	// See docs/gno-notes.md for the maths.

	// MinWorkBlocks and MaxWorkBlocks bound the work window a poster may set:
	// about 1 hour and about 90 days.
	MinWorkBlocks int64 = 1_000
	MaxWorkBlocks int64 = 2_200_000

	// ReviewBlocks is the fixed review window every quest gets after Submit,
	// about 7 days. If the poster neither approves nor rejects within it, the
	// builder may call ClaimPayout.
	ReviewBlocks int64 = 172_800
)

// State is the stage a quest is in.
type State uint8

const (
	// Open: waiting for a builder.
	Open State = iota + 1
	// Claimed: a builder is working on it.
	Claimed
	// Submitted: work link sent, waiting for the poster's review.
	Submitted
	// Paid: reward paid to the builder. Final.
	Paid
	// Cancelled: reward refunded to the poster. Final.
	Cancelled
)

// String returns the state name.
func (s State) String() string {
	switch s {
	case Open:
		return "Open"
	case Claimed:
		return "Claimed"
	case Submitted:
		return "Submitted"
	case Paid:
		return "Paid"
	case Cancelled:
		return "Cancelled"
	}
	return "Unknown"
}

// IsFinal reports whether no further move is possible from s.
func (s State) IsFinal() bool {
	return s == Paid || s == Cancelled
}

// PayoutKind says why coins must move.
type PayoutKind uint8

const (
	// PayBuilder: send the reward to the builder (Approve, ClaimPayout).
	PayBuilder PayoutKind = iota + 1
	// RefundPoster: send the reward back to the poster (Cancel).
	RefundPoster
)

// String returns the payout kind name.
func (k PayoutKind) String() string {
	switch k {
	case PayBuilder:
		return "PayBuilder"
	case RefundPoster:
		return "RefundPoster"
	}
	return "Unknown"
}

// Payout is the transfer a realm must make after a successful move. The zero
// Payout means no transfer. When Due, Amount is always the quest's stored
// Reward.
type Payout struct {
	Kind   PayoutKind
	To     address
	Amount int64
}

// Due reports whether coins must move.
func (p Payout) Due() bool {
	return p.Kind != 0
}

// Errors returned by the moves. Realms usually panic with err.Error().
var (
	ErrInvalidPoster     = errors.New("escrow: invalid poster address")
	ErrInvalidActor      = errors.New("escrow: invalid caller address")
	ErrInvalidReward     = errors.New("escrow: reward must be positive")
	ErrInvalidHeight     = errors.New("escrow: invalid block height")
	ErrTitleEmpty        = errors.New("escrow: title is empty")
	ErrTitleTooLong      = errors.New("escrow: title is too long")
	ErrTitleControlChar  = errors.New("escrow: title must not contain control characters such as newlines or tabs")
	ErrDetailsTooLong    = errors.New("escrow: details are too long")
	ErrWorkBlocksTooLow  = errors.New("escrow: work window is below the minimum")
	ErrWorkBlocksTooHigh = errors.New("escrow: work window is above the maximum")
	ErrLinkEmpty         = errors.New("escrow: work link is empty")
	ErrLinkTooLong       = errors.New("escrow: work link is too long")
	ErrLinkNotHTTPS      = errors.New("escrow: work link must start with https://")
	ErrLinkInvalid       = errors.New("escrow: work link contains spaces or control characters")
	ErrReasonEmpty       = errors.New("escrow: reject reason is empty")
	ErrReasonTooLong     = errors.New("escrow: reject reason is too long")
	ErrInvalidText       = errors.New("escrow: text is not valid UTF-8")

	ErrWrongState              = errors.New("escrow: move not allowed in the quest's current state")
	ErrNotPoster               = errors.New("escrow: only the poster can do this")
	ErrNotBuilder              = errors.New("escrow: only the builder can do this")
	ErrPosterCannotClaim       = errors.New("escrow: the poster cannot claim their own quest")
	ErrWorkDeadlinePassed      = errors.New("escrow: work deadline has passed")
	ErrWorkDeadlineNotPassed   = errors.New("escrow: work deadline has not passed yet")
	ErrReviewDeadlinePassed    = errors.New("escrow: review deadline has passed")
	ErrReviewDeadlineNotPassed = errors.New("escrow: review deadline has not passed yet")
	ErrAlreadyClosing          = errors.New("escrow: the quest is already closing")
)

// Quest is one bounty. Its fields are private so that only the moves below
// can change it; read them with the getters.
type Quest struct {
	id          uint64
	poster      address
	title       string
	details     string
	reward      int64
	state       State
	builder     address
	workLink    string
	workBlocks  int64
	createdAt   int64
	claimedAt   int64
	submittedAt int64

	rejectCount      int
	lastRejectReason string

	closing bool // set by Cancel on a Claimed or Submitted quest
}

// NewQuest validates a new quest and returns it in the Open state. The caller
// must already hold reward (in its own coin) for this quest. id is chosen by
// the caller and is not checked for uniqueness here.
func NewQuest(id uint64, poster address, title, details string, reward, workBlocks, height int64) (*Quest, error) {
	if !poster.IsValid() {
		return nil, ErrInvalidPoster
	}
	if reward <= 0 {
		return nil, ErrInvalidReward
	}
	if height < 0 {
		return nil, ErrInvalidHeight
	}
	if err := ValidateTitle(title); err != nil {
		return nil, err
	}
	if err := ValidateDetails(details); err != nil {
		return nil, err
	}
	if err := ValidateWorkBlocks(workBlocks); err != nil {
		return nil, err
	}
	return &Quest{
		id:         id,
		poster:     poster,
		title:      title,
		details:    details,
		reward:     reward,
		state:      Open,
		workBlocks: workBlocks,
		createdAt:  height,
	}, nil
}

// Claim lets anyone except the poster take an Open quest. The work window
// starts at height.
func (q *Quest) Claim(actor address, height int64) error {
	if q.state != Open {
		return ErrWrongState
	}
	if !actor.IsValid() {
		return ErrInvalidActor
	}
	if actor == q.poster {
		return ErrPosterCannotClaim
	}
	if height < q.createdAt {
		return ErrInvalidHeight
	}
	q.state = Claimed
	q.builder = actor
	q.claimedAt = height
	return nil
}

// Cancel is the poster's way out.
//   - On an Open quest it ends the quest at once: Cancelled, and the returned
//     Payout refunds the reward to the poster.
//   - On a Claimed or Submitted quest it only marks the quest as closing and
//     returns a zero Payout: the current builder keeps every right, and the
//     reward goes back to the poster when the builder's turn ends without
//     approval (Unclaim, Release or Reject). A second call fails.
func (q *Quest) Cancel(actor address, height int64) (Payout, error) {
	switch q.state {
	case Open, Claimed, Submitted:
	default:
		return Payout{}, ErrWrongState
	}
	if actor != q.poster {
		return Payout{}, ErrNotPoster
	}
	if q.state == Open {
		return q.cancel(), nil
	}
	if q.closing {
		return Payout{}, ErrAlreadyClosing
	}
	q.closing = true
	return Payout{}, nil
}

// Submit lets the builder hand in a work link, up to and including the work
// deadline block. The review window starts at height.
func (q *Quest) Submit(actor address, link string, height int64) error {
	if q.state != Claimed {
		return ErrWrongState
	}
	if actor != q.builder {
		return ErrNotBuilder
	}
	if height < q.claimedAt {
		return ErrInvalidHeight
	}
	if height > q.WorkDeadline() {
		return ErrWorkDeadlinePassed
	}
	if err := ValidateLink(link); err != nil {
		return err
	}
	q.state = Submitted
	q.workLink = link
	q.submittedAt = height
	return nil
}

// Unclaim lets the builder give a Claimed quest back. It becomes Open again,
// or, if it is closing, Cancelled with a refund to the poster.
func (q *Quest) Unclaim(actor address, height int64) (Payout, error) {
	if q.state != Claimed {
		return Payout{}, ErrWrongState
	}
	if actor != q.builder {
		return Payout{}, ErrNotBuilder
	}
	return q.endTurn(), nil
}

// Release lets anyone end the builder's turn on a Claimed quest once the
// work deadline has passed (from WorkDeadline()+1 on) without a submission.
// The quest becomes Open again, or, if it is closing, Cancelled with a refund
// to the poster.
func (q *Quest) Release(actor address, height int64) (Payout, error) {
	if q.state != Claimed {
		return Payout{}, ErrWrongState
	}
	if !actor.IsValid() {
		return Payout{}, ErrInvalidActor
	}
	if height <= q.WorkDeadline() {
		return Payout{}, ErrWorkDeadlineNotPassed
	}
	return q.endTurn(), nil
}

// Approve lets the poster accept the submitted work. The returned Payout pays
// the reward to the builder. Approving after the review deadline is allowed:
// it pays the same builder as ClaimPayout would.
func (q *Quest) Approve(actor address, height int64) (Payout, error) {
	if q.state != Submitted {
		return Payout{}, ErrWrongState
	}
	if actor != q.poster {
		return Payout{}, ErrNotPoster
	}
	q.state = Paid
	return Payout{Kind: PayBuilder, To: q.builder, Amount: q.reward}, nil
}

// Reject lets the poster refuse the submitted work, up to and including the
// review deadline block. The builder is cleared, and the reject count and
// last reason are kept on the quest for everyone to see. The quest becomes
// Open again, or, if it is closing, Cancelled with a refund to the poster.
func (q *Quest) Reject(actor address, reason string, height int64) (Payout, error) {
	if q.state != Submitted {
		return Payout{}, ErrWrongState
	}
	if actor != q.poster {
		return Payout{}, ErrNotPoster
	}
	if height > q.ReviewDeadline() {
		return Payout{}, ErrReviewDeadlinePassed
	}
	if err := ValidateReason(reason); err != nil {
		return Payout{}, err
	}
	q.rejectCount++
	q.lastRejectReason = reason
	return q.endTurn(), nil
}

// ClaimPayout lets the builder take the reward when the poster has not
// answered within the review window (from ReviewDeadline()+1 on). The
// returned Payout pays the reward to the builder.
func (q *Quest) ClaimPayout(actor address, height int64) (Payout, error) {
	if q.state != Submitted {
		return Payout{}, ErrWrongState
	}
	if actor != q.builder {
		return Payout{}, ErrNotBuilder
	}
	if height <= q.ReviewDeadline() {
		return Payout{}, ErrReviewDeadlineNotPassed
	}
	q.state = Paid
	return Payout{Kind: PayBuilder, To: q.builder, Amount: q.reward}, nil
}

// endTurn ends the current builder's turn: it clears the builder and the
// work, then puts the quest back to Open, or, if it is closing, cancels it
// and returns the refund.
func (q *Quest) endTurn() Payout {
	q.builder = ""
	q.workLink = ""
	q.claimedAt = 0
	q.submittedAt = 0
	if q.closing {
		return q.cancel()
	}
	q.state = Open
	return Payout{}
}

// cancel ends the quest and returns the refund to the poster. It is the only
// place that returns a RefundPoster payout.
func (q *Quest) cancel() Payout {
	q.state = Cancelled
	return Payout{Kind: RefundPoster, To: q.poster, Amount: q.reward}
}

// WorkDeadline is the last block at which the builder may submit. It is 0
// unless the quest is Claimed or Submitted.
func (q *Quest) WorkDeadline() int64 {
	if q.state != Claimed && q.state != Submitted {
		return 0
	}
	return q.claimedAt + q.workBlocks
}

// ReviewDeadline is the last block at which the poster may reject. It is 0
// unless the quest is Submitted.
func (q *Quest) ReviewDeadline() int64 {
	if q.state != Submitted {
		return 0
	}
	return q.submittedAt + ReviewBlocks
}

// CanRelease reports whether Release would succeed at height.
func (q *Quest) CanRelease(height int64) bool {
	return q.state == Claimed && height > q.WorkDeadline()
}

// CanClaimPayout reports whether the builder could call ClaimPayout at height.
func (q *Quest) CanClaimPayout(height int64) bool {
	return q.state == Submitted && height > q.ReviewDeadline()
}

// Getters.

func (q *Quest) ID() uint64               { return q.id }
func (q *Quest) Poster() address          { return q.poster }
func (q *Quest) Title() string            { return q.title }
func (q *Quest) Details() string          { return q.details }
func (q *Quest) Reward() int64            { return q.reward }
func (q *Quest) State() State             { return q.state }
func (q *Quest) Builder() address         { return q.builder }
func (q *Quest) WorkLink() string         { return q.workLink }
func (q *Quest) WorkBlocks() int64        { return q.workBlocks }
func (q *Quest) CreatedAt() int64         { return q.createdAt }
func (q *Quest) ClaimedAt() int64         { return q.claimedAt }
func (q *Quest) SubmittedAt() int64       { return q.submittedAt }
func (q *Quest) RejectCount() int         { return q.rejectCount }
func (q *Quest) LastRejectReason() string { return q.lastRejectReason }

// Closing reports whether the poster has closed the quest while a builder
// held it: the reward returns to the poster when the builder's turn ends
// without approval.
func (q *Quest) Closing() bool { return q.closing }

// HoldsFunds reports whether the quest's reward is still held in escrow
// (Open, Claimed or Submitted). The sum of Reward() over quests that hold
// funds must equal what the realm holds for them.
func (q *Quest) HoldsFunds() bool {
	return !q.state.IsFinal()
}

// Validators. They are exported so a realm can check input early.

// ValidateTitle checks a quest title: not blank, at most MaxTitleLen
// characters, and no control characters (newline, tab, etc.) or Unicode line
// and paragraph separators, because titles are shown inside Markdown tables
// and links.
func ValidateTitle(s string) error {
	if !utf8.ValidString(s) {
		return ErrInvalidText
	}
	if strings.TrimSpace(s) == "" {
		return ErrTitleEmpty
	}
	if utf8.RuneCountInString(s) > MaxTitleLen {
		return ErrTitleTooLong
	}
	for _, r := range s {
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			return ErrTitleControlChar
		}
	}
	return nil
}

// ValidateDetails checks quest details: at most MaxDetailsLen characters (may be empty).
func ValidateDetails(s string) error {
	if !utf8.ValidString(s) {
		return ErrInvalidText
	}
	if utf8.RuneCountInString(s) > MaxDetailsLen {
		return ErrDetailsTooLong
	}
	return nil
}

// ValidateWorkBlocks checks that w is within [MinWorkBlocks, MaxWorkBlocks].
func ValidateWorkBlocks(w int64) error {
	if w < MinWorkBlocks {
		return ErrWorkBlocksTooLow
	}
	if w > MaxWorkBlocks {
		return ErrWorkBlocksTooHigh
	}
	return nil
}

// ValidateLink checks a work link: starts with "https://", has something
// after it, at most MaxLinkLen characters, and has no spaces or control
// characters.
func ValidateLink(s string) error {
	if s == "" {
		return ErrLinkEmpty
	}
	if !utf8.ValidString(s) {
		return ErrInvalidText
	}
	if utf8.RuneCountInString(s) > MaxLinkLen {
		return ErrLinkTooLong
	}
	if !strings.HasPrefix(s, "https://") || len(s) == len("https://") {
		return ErrLinkNotHTTPS
	}
	for _, r := range s {
		if r <= ' ' || r == 0x7f {
			return ErrLinkInvalid
		}
	}
	return nil
}

// ValidateReason checks a reject reason: not blank, at most MaxReasonLen characters.
func ValidateReason(s string) error {
	if !utf8.ValidString(s) {
		return ErrInvalidText
	}
	if strings.TrimSpace(s) == "" {
		return ErrReasonEmpty
	}
	if utf8.RuneCountInString(s) > MaxReasonLen {
		return ErrReasonTooLong
	}
	return nil
}
