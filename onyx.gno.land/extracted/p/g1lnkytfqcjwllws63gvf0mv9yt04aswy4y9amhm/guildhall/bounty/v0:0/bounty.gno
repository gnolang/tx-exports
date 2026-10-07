// Package bounty is the state machine behind Guildhall bounties.
//
// It holds no funds and moves no coins. Every transition validates who is
// acting and what state the bounty is in, mutates the bounty, and returns the
// transfers the escrow realm must execute as a list of Payouts. Keeping the
// rules here, free of chain effects, lets them be tested exhaustively and
// reused by any realm that wants to escrow work.
//
// Lifecycle:
//
//	Open ──Assign──▶ Active ──(every milestone settled)──▶ Completed
//	  ▲                │
//	  └──Unassign/Resign┘
//	Open ──Cancel──▶ Cancelled (unpaid milestones refunded)
//
// Milestones move independently once a bounty is Active:
//
//	Pending ──Submit──▶ Submitted ──Approve×quorum──▶ Paid
//	   ▲                  │   │
//	   └──RequestChanges──┘   └──OpenDispute──▶ Disputed ──Resolve──▶ Paid | Split | Refunded
//
// A milestone with requested changes can be resubmitted or disputed.
package bounty

import (
	"errors"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// Limits keep bounties renderable and every transition bounded in gas.
const (
	MaxTitleLen       = 120
	MaxDescriptionLen = 8000
	MaxLinkLen        = 300
	MaxNoteLen        = 1000
	MaxMilestones     = 20
	MaxReviewers      = 9
	MaxApplicants     = 50
	MaxTags           = 5
	MaxTagLen         = 24
	MaxBps            = 10000
	DefaultWorkWindow = 30 * 24 * time.Hour
)

var (
	ErrUnauthorized = errors.New("bounty: unauthorized")
	ErrBadState     = errors.New("bounty: invalid state for this action")
	ErrBadMilestone = errors.New("bounty: unknown milestone")
)

// Status is the lifecycle state of a bounty.
type Status int

const (
	StatusOpen Status = iota
	StatusActive
	StatusCompleted
	StatusCancelled
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusActive:
		return "active"
	case StatusCompleted:
		return "completed"
	case StatusCancelled:
		return "cancelled"
	}
	return "unknown"
}

// ParseStatus is the inverse of Status.String.
func ParseStatus(s string) (Status, bool) {
	for _, st := range []Status{StatusOpen, StatusActive, StatusCompleted, StatusCancelled} {
		if st.String() == s {
			return st, true
		}
	}
	return 0, false
}

// MilestoneStatus is the state of a single milestone.
type MilestoneStatus int

const (
	MilestonePending MilestoneStatus = iota
	MilestoneSubmitted
	MilestoneChangesRequested
	MilestoneDisputed
	MilestonePaid
	MilestoneSplit
	MilestoneRefunded
)

func (s MilestoneStatus) String() string {
	switch s {
	case MilestonePending:
		return "pending"
	case MilestoneSubmitted:
		return "submitted"
	case MilestoneChangesRequested:
		return "changes requested"
	case MilestoneDisputed:
		return "disputed"
	case MilestonePaid:
		return "paid"
	case MilestoneSplit:
		return "split"
	case MilestoneRefunded:
		return "refunded"
	}
	return "unknown"
}

// Settled reports whether the milestone's escrow has been fully released.
func (s MilestoneStatus) Settled() bool {
	return s == MilestonePaid || s == MilestoneSplit || s == MilestoneRefunded
}

// Dispute records a contested milestone and how it was settled.
type Dispute struct {
	OpenedBy   address
	Reason     string
	OpenedAt   time.Time
	Resolved   bool
	ResolvedAt time.Time
	// WorkerBps is the share of the milestone the arbiter awarded the worker.
	WorkerBps int64
	Ruling    string
}

// Milestone is one independently payable slice of a bounty.
type Milestone struct {
	Title       string
	Amount      int64
	Status      MilestoneStatus
	Submission  string
	SubmittedAt time.Time
	Approvals   []address
	Feedback    string
	Dispute     *Dispute
	// Worker is the assignee at the time the milestone was submitted. It
	// stays fixed through review and dispute so a later reassignment cannot
	// redirect payment for work someone else delivered.
	Worker   address
	PaidOut  int64
	Refunded int64
	SettleAt time.Time
}

// Application is a contributor's request to be assigned.
type Application struct {
	Applicant address
	Pitch     string
	At        time.Time
}

// Bounty is a funded task split into milestones.
type Bounty struct {
	ID          uint64
	Poster      address
	Title       string
	Description string
	Link        string
	Tags        []string
	// Denom identifies what the escrow holds: a native coin denom, or a
	// grc20reg key when IsGRC20 is set.
	Denom   string
	IsGRC20 bool

	Reviewers []address
	Quorum    int
	Arbiter   address

	Assignee     address
	Applications []Application
	Milestones   []*Milestone
	Status       Status
	WorkWindow   time.Duration

	CreatedAt  time.Time
	AssignedAt time.Time
	ClosedAt   time.Time
}

// MilestoneSpec describes a milestone when posting a bounty.
type MilestoneSpec struct {
	Title  string
	Amount int64
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
	Reviewers   []address
	Quorum      int
	Arbiter     address
	Milestones  []MilestoneSpec
	WorkWindow  time.Duration
	Now         time.Time
}

// PayoutKind says why escrowed funds move.
type PayoutKind string

const (
	PayoutWork   PayoutKind = "work"
	PayoutRefund PayoutKind = "refund"
)

// Payout is a transfer the escrow realm must execute.
type Payout struct {
	Kind      PayoutKind
	To        address
	Amount    int64
	Milestone int
}

// New validates p and returns a funded, open bounty.
//
// When no reviewers are given, the poster reviews alone. When no arbiter is
// given, the caller is expected to fill in a default (the escrow realm's
// council) before calling New.
func New(p Params) (*Bounty, error) {
	if !p.Poster.IsValid() {
		return nil, errors.New("bounty: invalid poster address")
	}
	title := strings.TrimSpace(p.Title)
	if title == "" || len(title) > MaxTitleLen {
		return nil, errorf("bounty: title must be 1..%d bytes", MaxTitleLen)
	}
	if len(p.Description) > MaxDescriptionLen {
		return nil, errorf("bounty: description exceeds %d bytes", MaxDescriptionLen)
	}
	if len(p.Link) > MaxLinkLen {
		return nil, errorf("bounty: link exceeds %d bytes", MaxLinkLen)
	}
	tags, err := normalizeTags(p.Tags)
	if err != nil {
		return nil, err
	}
	if p.Denom == "" {
		return nil, errors.New("bounty: missing denomination")
	}

	reviewers := p.Reviewers
	if len(reviewers) == 0 {
		reviewers = []address{p.Poster}
	}
	if len(reviewers) > MaxReviewers {
		return nil, errorf("bounty: at most %d reviewers", MaxReviewers)
	}
	seen := map[address]bool{}
	for _, r := range reviewers {
		if !r.IsValid() {
			return nil, errors.New("bounty: invalid reviewer address " + r.String())
		}
		if seen[r] {
			return nil, errors.New("bounty: duplicate reviewer " + r.String())
		}
		seen[r] = true
	}
	quorum := p.Quorum
	if quorum == 0 {
		quorum = 1
	}
	if quorum < 1 || quorum > len(reviewers) {
		return nil, errorf("bounty: quorum must be within 1..%d", len(reviewers))
	}
	if !p.Arbiter.IsValid() {
		return nil, errors.New("bounty: invalid arbiter address")
	}

	if len(p.Milestones) == 0 || len(p.Milestones) > MaxMilestones {
		return nil, errorf("bounty: need 1..%d milestones", MaxMilestones)
	}
	ms := make([]*Milestone, 0, len(p.Milestones))
	total := int64(0)
	for i, spec := range p.Milestones {
		mt := strings.TrimSpace(spec.Title)
		if mt == "" || len(mt) > MaxTitleLen {
			return nil, errorf("bounty: milestone %d title must be 1..%d bytes", i+1, MaxTitleLen)
		}
		if spec.Amount <= 0 {
			return nil, errorf("bounty: milestone %d amount must be positive", i+1)
		}
		if total+spec.Amount < total {
			return nil, errors.New("bounty: total overflows")
		}
		total += spec.Amount
		ms = append(ms, &Milestone{Title: mt, Amount: spec.Amount})
	}

	window := p.WorkWindow
	if window == 0 {
		window = DefaultWorkWindow
	}
	if window < 0 {
		return nil, errors.New("bounty: work window must be positive")
	}

	return &Bounty{
		ID:          p.ID,
		Poster:      p.Poster,
		Title:       title,
		Description: p.Description,
		Link:        p.Link,
		Tags:        tags,
		Denom:       p.Denom,
		IsGRC20:     p.IsGRC20,
		Reviewers:   reviewers,
		Quorum:      quorum,
		Arbiter:     p.Arbiter,
		Milestones:  ms,
		Status:      StatusOpen,
		WorkWindow:  window,
		CreatedAt:   p.Now,
	}, nil
}

// ParseMilestones parses "Title=amount;Title=amount". An empty string yields a
// single "Complete the bounty" milestone worth total (which must be positive).
func ParseMilestones(s string, total int64) ([]MilestoneSpec, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		if total <= 0 {
			return nil, errors.New("bounty: no milestones and no amount")
		}
		return []MilestoneSpec{{Title: "Complete the bounty", Amount: total}}, nil
	}
	var specs []MilestoneSpec
	for _, part := range strings.Split(s, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		eq := strings.LastIndex(part, "=")
		if eq < 0 {
			return nil, errors.New("bounty: milestone must be Title=amount: " + part)
		}
		amt, err := parseAmount(strings.TrimSpace(part[eq+1:]))
		if err != nil {
			return nil, err
		}
		specs = append(specs, MilestoneSpec{Title: strings.TrimSpace(part[:eq]), Amount: amt})
	}
	if len(specs) == 0 {
		return nil, errors.New("bounty: no milestones")
	}
	return specs, nil
}

// ParseAddresses parses a comma- or space-separated list of addresses.
func ParseAddresses(s string) []address {
	var out []address
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' }) {
		out = append(out, address(f))
	}
	return out
}

// Total is the sum of all milestone amounts.
func (b *Bounty) Total() int64 {
	t := int64(0)
	for _, m := range b.Milestones {
		t += m.Amount
	}
	return t
}

// Escrowed is the amount still held for this bounty.
func (b *Bounty) Escrowed() int64 {
	t := int64(0)
	for _, m := range b.Milestones {
		if !m.Status.Settled() {
			t += m.Amount
		}
	}
	return t
}

// PaidOut is the amount released to workers.
func (b *Bounty) PaidOut() int64 {
	t := int64(0)
	for _, m := range b.Milestones {
		t += m.PaidOut
	}
	return t
}

// IsReviewer reports whether addr is one of the bounty's reviewers.
func (b *Bounty) IsReviewer(addr address) bool {
	for _, r := range b.Reviewers {
		if r == addr {
			return true
		}
	}
	return false
}

// HasApplied reports whether addr has an application on file.
func (b *Bounty) HasApplied(addr address) bool {
	for _, a := range b.Applications {
		if a.Applicant == addr {
			return true
		}
	}
	return false
}

// Milestone returns the milestone at idx.
func (b *Bounty) Milestone(idx int) (*Milestone, error) {
	if idx < 0 || idx >= len(b.Milestones) {
		return nil, ErrBadMilestone
	}
	return b.Milestones[idx], nil
}

// Apply files an application from a prospective contributor.
func (b *Bounty) Apply(who address, pitch string, now time.Time) error {
	if b.Status != StatusOpen {
		return ErrBadState
	}
	if who == b.Poster || b.IsReviewer(who) {
		return errors.New("bounty: posters and reviewers cannot apply")
	}
	if b.HasApplied(who) {
		return errors.New("bounty: already applied")
	}
	if len(b.Applications) >= MaxApplicants {
		return errors.New("bounty: application list is full")
	}
	if len(pitch) > MaxNoteLen {
		return errorf("bounty: pitch exceeds %d bytes", MaxNoteLen)
	}
	b.Applications = append(b.Applications, Application{Applicant: who, Pitch: pitch, At: now})
	return nil
}

// Assign hands the bounty to a contributor. Only the poster may assign, and
// the assignee cannot be the poster or a reviewer.
func (b *Bounty) Assign(caller, who address, now time.Time) error {
	if caller != b.Poster {
		return ErrUnauthorized
	}
	if b.Status != StatusOpen {
		return ErrBadState
	}
	if !who.IsValid() {
		return errors.New("bounty: invalid assignee address")
	}
	if who == b.Poster || who == b.Arbiter || b.IsReviewer(who) {
		return errors.New("bounty: posters, reviewers and the arbiter cannot be assigned")
	}
	b.Assignee = who
	b.AssignedAt = now
	b.Status = StatusActive
	return nil
}

// Unassign returns an active bounty to the open pool.
//
// The assignee may step back at any time. The poster may reclaim the bounty
// once the work window has elapsed since assignment. Either way, no milestone
// may be awaiting review or arbitration: those are settled first.
func (b *Bounty) Unassign(caller address, now time.Time) error {
	if b.Status != StatusActive {
		return ErrBadState
	}
	switch caller {
	case b.Assignee:
	case b.Poster:
		if now.Before(b.AssignedAt.Add(b.WorkWindow)) {
			return errors.New("bounty: work window has not elapsed")
		}
	default:
		return ErrUnauthorized
	}
	for _, m := range b.Milestones {
		if m.Status == MilestoneSubmitted || m.Status == MilestoneDisputed {
			return errors.New("bounty: a milestone is awaiting review or arbitration")
		}
	}
	for _, m := range b.Milestones {
		if m.Status == MilestoneChangesRequested {
			m.Status = MilestonePending
			m.Submission = ""
			m.Worker = ""
		}
	}
	b.Assignee = ""
	b.AssignedAt = time.Time{}
	b.Status = StatusOpen
	return nil
}

// Submit hands a milestone in for review.
func (b *Bounty) Submit(caller address, idx int, link string, now time.Time) error {
	if b.Status != StatusActive {
		return ErrBadState
	}
	if caller != b.Assignee {
		return ErrUnauthorized
	}
	m, err := b.Milestone(idx)
	if err != nil {
		return err
	}
	if m.Status != MilestonePending && m.Status != MilestoneChangesRequested {
		return ErrBadState
	}
	link = strings.TrimSpace(link)
	if link == "" || len(link) > MaxLinkLen {
		return errorf("bounty: submission link must be 1..%d bytes", MaxLinkLen)
	}
	m.Status = MilestoneSubmitted
	m.Submission = link
	m.SubmittedAt = now
	m.Approvals = nil
	m.Worker = caller
	return nil
}

// Approve records a reviewer's approval. When the quorum is reached the
// milestone is paid and the returned payout sends its full amount to the
// worker.
func (b *Bounty) Approve(caller address, idx int, now time.Time) ([]Payout, error) {
	if b.Status != StatusActive {
		return nil, ErrBadState
	}
	if !b.IsReviewer(caller) {
		return nil, ErrUnauthorized
	}
	m, err := b.Milestone(idx)
	if err != nil {
		return nil, err
	}
	if m.Status != MilestoneSubmitted {
		return nil, ErrBadState
	}
	if caller == m.Worker {
		return nil, errors.New("bounty: workers cannot approve their own work")
	}
	for _, a := range m.Approvals {
		if a == caller {
			return nil, errors.New("bounty: already approved")
		}
	}
	m.Approvals = append(m.Approvals, caller)
	if len(m.Approvals) < b.Quorum {
		return nil, nil
	}
	m.Status = MilestonePaid
	m.PaidOut = m.Amount
	m.SettleAt = now
	b.maybeComplete(now)
	return []Payout{{Kind: PayoutWork, To: m.Worker, Amount: m.Amount, Milestone: idx}}, nil
}

// RequestChanges sends a submitted milestone back to the worker, discarding
// approvals collected so far.
func (b *Bounty) RequestChanges(caller address, idx int, feedback string) error {
	if b.Status != StatusActive {
		return ErrBadState
	}
	if !b.IsReviewer(caller) {
		return ErrUnauthorized
	}
	m, err := b.Milestone(idx)
	if err != nil {
		return err
	}
	if m.Status != MilestoneSubmitted {
		return ErrBadState
	}
	if len(feedback) > MaxNoteLen {
		return errorf("bounty: feedback exceeds %d bytes", MaxNoteLen)
	}
	m.Status = MilestoneChangesRequested
	m.Feedback = feedback
	m.Approvals = nil
	return nil
}

// OpenDispute escalates a submitted or rejected milestone to the arbiter.
// Either the poster or the worker who submitted it may open a dispute.
func (b *Bounty) OpenDispute(caller address, idx int, reason string, now time.Time) error {
	if b.Status != StatusActive {
		return ErrBadState
	}
	m, err := b.Milestone(idx)
	if err != nil {
		return err
	}
	if caller != b.Poster && caller != m.Worker {
		return ErrUnauthorized
	}
	if m.Status != MilestoneSubmitted && m.Status != MilestoneChangesRequested {
		return ErrBadState
	}
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > MaxNoteLen {
		return errorf("bounty: reason must be 1..%d bytes", MaxNoteLen)
	}
	m.Status = MilestoneDisputed
	m.Dispute = &Dispute{OpenedBy: caller, Reason: reason, OpenedAt: now}
	return nil
}

// Resolve settles a disputed milestone. The arbiter awards workerBps of the
// milestone to the worker and refunds the rest to the poster.
func (b *Bounty) Resolve(caller address, idx int, workerBps int64, ruling string, now time.Time) ([]Payout, error) {
	if caller != b.Arbiter {
		return nil, ErrUnauthorized
	}
	m, err := b.Milestone(idx)
	if err != nil {
		return nil, err
	}
	if m.Status != MilestoneDisputed || m.Dispute == nil {
		return nil, ErrBadState
	}
	if workerBps < 0 || workerBps > MaxBps {
		return nil, errors.New("bounty: worker share must be within 0..10000 bps")
	}
	if len(ruling) > MaxNoteLen {
		return nil, errorf("bounty: ruling exceeds %d bytes", MaxNoteLen)
	}
	toWorker := m.Amount * workerBps / MaxBps
	toPoster := m.Amount - toWorker

	m.Dispute.Resolved = true
	m.Dispute.ResolvedAt = now
	m.Dispute.WorkerBps = workerBps
	m.Dispute.Ruling = ruling
	m.PaidOut = toWorker
	m.Refunded = toPoster
	m.SettleAt = now
	switch {
	case toPoster == 0:
		m.Status = MilestonePaid
	case toWorker == 0:
		m.Status = MilestoneRefunded
	default:
		m.Status = MilestoneSplit
	}

	var payouts []Payout
	if toWorker > 0 {
		payouts = append(payouts, Payout{Kind: PayoutWork, To: m.Worker, Amount: toWorker, Milestone: idx})
	}
	if toPoster > 0 {
		payouts = append(payouts, Payout{Kind: PayoutRefund, To: b.Poster, Amount: toPoster, Milestone: idx})
	}
	b.maybeComplete(now)
	return payouts, nil
}

// Cancel withdraws an open bounty and refunds every unsettled milestone. An
// active bounty must be unassigned first, so a poster cannot pull funds from
// under someone who is working.
func (b *Bounty) Cancel(caller address, now time.Time) ([]Payout, error) {
	if caller != b.Poster {
		return nil, ErrUnauthorized
	}
	if b.Status != StatusOpen {
		return nil, ErrBadState
	}
	var payouts []Payout
	for i, m := range b.Milestones {
		if m.Status.Settled() {
			continue
		}
		m.Status = MilestoneRefunded
		m.Refunded = m.Amount
		m.SettleAt = now
		payouts = append(payouts, Payout{Kind: PayoutRefund, To: b.Poster, Amount: m.Amount, Milestone: i})
	}
	b.Status = StatusCancelled
	b.ClosedAt = now
	return payouts, nil
}

// Involves reports whether addr plays any role in the bounty.
func (b *Bounty) Involves(addr address) bool {
	return addr == b.Poster || addr == b.Assignee || addr == b.Arbiter || b.IsReviewer(addr)
}

func (b *Bounty) maybeComplete(now time.Time) {
	for _, m := range b.Milestones {
		if !m.Status.Settled() {
			return
		}
	}
	b.Status = StatusCompleted
	b.ClosedAt = now
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
			return nil, errorf("bounty: tag %q exceeds %d bytes", t, MaxTagLen)
		}
		for _, r := range t {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return nil, errors.New("bounty: tags may only contain a-z, 0-9 and '-'")
			}
		}
		seen[t] = true
		out = append(out, t)
	}
	if len(out) > MaxTags {
		return nil, errorf("bounty: at most %d tags", MaxTags)
	}
	return out, nil
}

func parseAmount(s string) (int64, error) {
	if s == "" {
		return 0, errors.New("bounty: empty amount")
	}
	n := int64(0)
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, errors.New("bounty: amount must be a positive integer: " + s)
		}
		d := int64(r - '0')
		if n > (9223372036854775807-d)/10 {
			return 0, errors.New("bounty: amount overflows")
		}
		n = n*10 + d
	}
	if n <= 0 {
		return 0, errors.New("bounty: amount must be positive")
	}
	return n, nil
}

func errorf(format string, args ...any) error {
	return errors.New(ufmt.Sprintf(format, args...))
}
