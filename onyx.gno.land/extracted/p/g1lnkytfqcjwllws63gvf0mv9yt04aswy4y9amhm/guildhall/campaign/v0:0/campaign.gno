// Package campaign is the state machine behind Guildhall campaigns: bounties
// with a fixed reward per claim and a fixed number of slots, for small tasks
// many people can do (write a post, translate a page, file a bug report).
//
// Like gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounty,
// it holds no funds and moves no coins. Transitions validate who is acting,
// mutate the campaign, and return the transfers the escrow realm must make.
//
// The poster escrows Reward × Slots. Anyone except the poster and the
// reviewers can claim with a link to proof of the work; a pending claim
// reserves a slot. Any one reviewer approves (pays the reward) or rejects
// (frees the slot). Each address holds at most one pending or approved claim.
//
//	Open ──Close (poster, or anyone after the deadline)──▶ Closed (free slots refunded)
//	Open ──(every slot paid)──▶ Closed
//
//	Claim ──Approve──▶ Approved (reward paid)
//	  └────Reject───▶ Rejected (slot freed; refunded if the campaign is closed)
//
// Pending claims can still be reviewed after a campaign closes.
package campaign

import (
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Limits keep campaigns renderable and every transition bounded in gas.
const (
	MaxTitleLen       = 120
	MaxDescriptionLen = 8000
	MaxLinkLen        = 300
	MaxNoteLen        = 1000
	MaxSlots          = 1000
	MaxReviewers      = 9
	MaxTags           = 5
	MaxTagLen         = 24
)

var (
	ErrUnauthorized = errors.New("campaign: unauthorized")
	ErrClosed       = errors.New("campaign: closed to new claims")
	ErrBadClaim     = errors.New("campaign: unknown claim")
)

// Status is the lifecycle state of a campaign.
type Status int

const (
	StatusOpen Status = iota
	StatusClosed
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusClosed:
		return "closed"
	}
	return "unknown"
}

// ParseStatus is the inverse of Status.String.
func ParseStatus(s string) (Status, bool) {
	for _, st := range []Status{StatusOpen, StatusClosed} {
		if st.String() == s {
			return st, true
		}
	}
	return 0, false
}

// ClaimStatus is the state of a single claim.
type ClaimStatus int

const (
	ClaimPending ClaimStatus = iota
	ClaimApproved
	ClaimRejected
)

func (s ClaimStatus) String() string {
	switch s {
	case ClaimPending:
		return "pending"
	case ClaimApproved:
		return "approved"
	case ClaimRejected:
		return "rejected"
	}
	return "unknown"
}

// ParseClaimStatus is the inverse of ClaimStatus.String.
func ParseClaimStatus(s string) (ClaimStatus, bool) {
	for _, st := range []ClaimStatus{ClaimPending, ClaimApproved, ClaimRejected} {
		if st.String() == s {
			return st, true
		}
	}
	return 0, false
}

// Claim is one person's request to be paid for doing the task once.
type Claim struct {
	Number     int // 1-based, in order of submission
	Claimant   address
	Proof      string
	Status     ClaimStatus
	At         time.Time
	ReviewedBy address
	ReviewedAt time.Time
	Reason     string // why it was rejected
}

// Campaign is a pool of identical, individually paid tasks.
type Campaign struct {
	ID          uint64
	Poster      address
	Title       string
	Description string
	Link        string
	Tags        []string
	Denom       string
	IsGRC20     bool
	Reward      int64
	Slots       int
	Reviewers   []address
	Deadline    time.Time // zero: no deadline
	Status      Status
	CreatedAt   time.Time
	ClosedAt    time.Time

	Paid     int // approved claims
	Pending  int // claims awaiting review
	Rejected int
	Refunded int // slots returned to the poster

	claims     avl.Tree // padded claim number -> *Claim
	byClaimant avl.Tree // address -> latest claim number (int)
}

// Params are the inputs to New.
type Params struct {
	ID          uint64
	Poster      address
	Title       string
	Description string
	Link        string
	Tags        []string
	Denom       string
	IsGRC20     bool
	Reward      int64
	Slots       int
	Reviewers   []address
	Deadline    time.Time
	Now         time.Time
}

// PayoutKind says why escrowed funds move.
type PayoutKind string

const (
	PayoutWork   PayoutKind = "work"
	PayoutRefund PayoutKind = "refund"
)

// Payout is a transfer the escrow realm must execute. Claim is the claim
// number for work payouts and 0 for refunds.
type Payout struct {
	Kind   PayoutKind
	To     address
	Amount int64
	Claim  int
}

// New validates p and returns a funded, open campaign. When no reviewers are
// given, the poster reviews alone.
func New(p Params) (*Campaign, error) {
	if !p.Poster.IsValid() {
		return nil, errors.New("campaign: invalid poster address")
	}
	title := strings.TrimSpace(p.Title)
	if title == "" || len(title) > MaxTitleLen {
		return nil, errorf("campaign: title must be 1..%d bytes", MaxTitleLen)
	}
	if len(p.Description) > MaxDescriptionLen {
		return nil, errorf("campaign: description exceeds %d bytes", MaxDescriptionLen)
	}
	link := strings.TrimSpace(p.Link)
	if len(link) > MaxLinkLen {
		return nil, errorf("campaign: link exceeds %d bytes", MaxLinkLen)
	}
	tags, err := normalizeTags(p.Tags)
	if err != nil {
		return nil, err
	}
	if p.Denom == "" {
		return nil, errors.New("campaign: missing denomination")
	}
	if p.Reward <= 0 {
		return nil, errors.New("campaign: reward must be positive")
	}
	if p.Slots < 1 || p.Slots > MaxSlots {
		return nil, errorf("campaign: slots must be within 1..%d", MaxSlots)
	}
	if p.Reward > (1<<63-1)/int64(p.Slots) {
		return nil, errors.New("campaign: total overflows")
	}

	reviewers := p.Reviewers
	if len(reviewers) == 0 {
		reviewers = []address{p.Poster}
	}
	if len(reviewers) > MaxReviewers {
		return nil, errorf("campaign: at most %d reviewers", MaxReviewers)
	}
	seen := map[address]bool{}
	for _, r := range reviewers {
		if !r.IsValid() {
			return nil, errors.New("campaign: invalid reviewer address " + r.String())
		}
		if seen[r] {
			return nil, errors.New("campaign: duplicate reviewer " + r.String())
		}
		seen[r] = true
	}
	if !p.Deadline.IsZero() && !p.Deadline.After(p.Now) {
		return nil, errors.New("campaign: deadline must be in the future")
	}

	return &Campaign{
		ID:          p.ID,
		Poster:      p.Poster,
		Title:       title,
		Description: p.Description,
		Link:        link,
		Tags:        tags,
		Denom:       p.Denom,
		IsGRC20:     p.IsGRC20,
		Reward:      p.Reward,
		Slots:       p.Slots,
		Reviewers:   append([]address{}, reviewers...),
		Deadline:    p.Deadline,
		Status:      StatusOpen,
		CreatedAt:   p.Now,
	}, nil
}

// Claim records that claimant did the task, with a link to proof, and
// reserves a slot. It returns the claim number.
func (c *Campaign) Claim(claimant address, proof string, now time.Time) (int, error) {
	if c.Status != StatusOpen {
		return 0, ErrClosed
	}
	if c.Expired(now) {
		return 0, errors.New("campaign: the deadline has passed")
	}
	if !claimant.IsValid() {
		return 0, errors.New("campaign: invalid claimant address")
	}
	if claimant == c.Poster || c.IsReviewer(claimant) {
		return 0, errors.New("campaign: the poster and reviewers cannot claim")
	}
	proof = strings.TrimSpace(proof)
	if proof == "" || len(proof) > MaxLinkLen {
		return 0, errorf("campaign: proof link must be 1..%d bytes", MaxLinkLen)
	}
	if prev := c.ClaimOf(claimant); prev != nil && prev.Status != ClaimRejected {
		article := "a "
		if prev.Status == ClaimApproved {
			article = "an "
		}
		return 0, errors.New("campaign: you already have " + article + prev.Status.String() + " claim (#" + strconv.Itoa(prev.Number) + ")")
	}
	if c.FreeSlots() == 0 {
		return 0, errors.New("campaign: every slot is taken or awaiting review")
	}
	n := c.claims.Size() + 1
	c.claims.Set(claimKey(n), &Claim{Number: n, Claimant: claimant, Proof: proof, Status: ClaimPending, At: now})
	c.byClaimant.Set(claimant.String(), n)
	c.Pending++
	return n, nil
}

// Approve pays a pending claim. Any one reviewer may approve. When the last
// slot is paid, the campaign closes.
func (c *Campaign) Approve(caller address, number int, now time.Time) ([]Payout, error) {
	cl, err := c.pendingClaim(caller, number)
	if err != nil {
		return nil, err
	}
	cl.Status = ClaimApproved
	cl.ReviewedBy = caller
	cl.ReviewedAt = now
	c.Pending--
	c.Paid++
	if c.Status == StatusOpen && c.Paid == c.Slots {
		c.Status = StatusClosed
		c.ClosedAt = now
	}
	return []Payout{{Kind: PayoutWork, To: cl.Claimant, Amount: c.Reward, Claim: number}}, nil
}

// Reject turns down a pending claim and frees its slot. If the campaign has
// closed, the slot's reward goes back to the poster. The claimant may claim
// again while the campaign is open.
func (c *Campaign) Reject(caller address, number int, reason string, now time.Time) ([]Payout, error) {
	cl, err := c.pendingClaim(caller, number)
	if err != nil {
		return nil, err
	}
	reason = strings.TrimSpace(reason)
	if len(reason) > MaxNoteLen {
		return nil, errorf("campaign: reason exceeds %d bytes", MaxNoteLen)
	}
	cl.Status = ClaimRejected
	cl.ReviewedBy = caller
	cl.ReviewedAt = now
	cl.Reason = reason
	c.Pending--
	c.Rejected++
	if c.Status == StatusClosed {
		c.Refunded++
		return []Payout{{Kind: PayoutRefund, To: c.Poster, Amount: c.Reward}}, nil
	}
	return nil, nil
}

// Close stops new claims and refunds every slot that is neither paid nor
// awaiting review. The poster can close at any time; anyone can close once
// the deadline has passed.
func (c *Campaign) Close(caller address, now time.Time) ([]Payout, error) {
	if c.Status != StatusOpen {
		return nil, errors.New("campaign: already closed")
	}
	if caller != c.Poster && !c.Expired(now) {
		return nil, ErrUnauthorized
	}
	free := c.FreeSlots()
	c.Status = StatusClosed
	c.ClosedAt = now
	if free == 0 {
		return nil, nil
	}
	c.Refunded += free
	return []Payout{{Kind: PayoutRefund, To: c.Poster, Amount: c.Reward * int64(free)}}, nil
}

func (c *Campaign) pendingClaim(caller address, number int) (*Claim, error) {
	if !c.IsReviewer(caller) {
		return nil, ErrUnauthorized
	}
	cl := c.GetClaim(number)
	if cl == nil {
		return nil, ErrBadClaim
	}
	if cl.Status != ClaimPending {
		return nil, errors.New("campaign: claim #" + strconv.Itoa(number) + " is already " + cl.Status.String())
	}
	return cl, nil
}

// Total is the amount escrowed when the campaign was posted.
func (c *Campaign) Total() int64 { return c.Reward * int64(c.Slots) }

// Escrowed is the amount still held for this campaign.
func (c *Campaign) Escrowed() int64 {
	return c.Reward * int64(c.Slots-c.Paid-c.Refunded)
}

// PaidOut is the amount paid to claimants so far.
func (c *Campaign) PaidOut() int64 { return c.Reward * int64(c.Paid) }

// FreeSlots is how many more claims an open campaign can take.
func (c *Campaign) FreeSlots() int {
	if c.Status != StatusOpen {
		return 0
	}
	return c.Slots - c.Paid - c.Pending - c.Refunded
}

// Expired reports whether the campaign has a deadline that has passed.
func (c *Campaign) Expired(now time.Time) bool {
	return !c.Deadline.IsZero() && !now.Before(c.Deadline)
}

// IsReviewer reports whether addr may approve and reject claims.
func (c *Campaign) IsReviewer(addr address) bool {
	for _, r := range c.Reviewers {
		if r == addr {
			return true
		}
	}
	return false
}

// ClaimCount is the number of claims ever submitted.
func (c *Campaign) ClaimCount() int { return c.claims.Size() }

// GetClaim returns claim number (1-based), or nil.
func (c *Campaign) GetClaim(number int) *Claim {
	if number < 1 {
		return nil
	}
	v := c.claims.Get(claimKey(number))
	if v == nil {
		return nil
	}
	return v.(*Claim)
}

// ClaimOf returns addr's most recent claim, or nil.
func (c *Campaign) ClaimOf(addr address) *Claim {
	v := c.byClaimant.Get(addr.String())
	if v == nil {
		return nil
	}
	return c.GetClaim(v.(int))
}

// Claims returns up to limit claims, newest first, after skipping offset
// claims. With a status filter, only matching claims are counted.
func (c *Campaign) Claims(status *ClaimStatus, offset, limit int) (out []*Claim, more bool) {
	c.claims.ReverseIterate("", "", func(_ string, v any) bool {
		cl := v.(*Claim)
		if status != nil && cl.Status != *status {
			return false
		}
		if offset > 0 {
			offset--
			return false
		}
		if len(out) == limit {
			more = true
			return true
		}
		out = append(out, cl)
		return false
	})
	return out, more
}

// ParseAddresses splits a comma or whitespace separated address list.
func ParseAddresses(s string) []address {
	var out []address
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' }) {
		out = append(out, address(f))
	}
	return out
}

func normalizeTags(in []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, t := range in {
		t = strings.ToLower(strings.TrimSpace(t))
		if t == "" || seen[t] {
			continue
		}
		if len(t) > MaxTagLen {
			return nil, errorf("campaign: tag %q exceeds %d bytes", t, MaxTagLen)
		}
		for _, r := range t {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return nil, errors.New("campaign: tags may only contain a-z, 0-9 and '-'")
			}
		}
		seen[t] = true
		out = append(out, t)
	}
	if len(out) > MaxTags {
		return nil, errorf("campaign: at most %d tags", MaxTags)
	}
	return out, nil
}

func claimKey(n int) string {
	s := strconv.Itoa(n)
	for len(s) < 6 {
		s = "0" + s
	}
	return s
}

func errorf(format string, args ...any) error {
	return errors.New(ufmt.Sprintf(format, args...))
}
