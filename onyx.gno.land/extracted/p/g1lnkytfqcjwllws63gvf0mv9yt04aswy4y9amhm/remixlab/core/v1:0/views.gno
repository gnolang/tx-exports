package core

// MemberView is an inert membership record.
type MemberView struct {
	Address address
	Role    Role
}

// MembershipReader is the read side of a membership set, implemented by the
// membership block and by adapters to shared membership realms.
type MembershipReader interface {
	// RoleOf returns addr's role, RoleNone for non-members.
	RoleOf(addr address) Role
	// Size returns the number of members.
	Size() int
	// Snapshot returns every member whose role is at least minRole, in a
	// stable order. ok is false (and the slice nil) when more than max
	// members qualify, so callers never act on a truncated electorate.
	// A negative max or an invalid minRole also yields (nil, false).
	Snapshot(minRole Role, max int) (addrs []address, ok bool)
}

// AuthorizationPolicy decides whether an authenticated actor may perform a
// named operation. The actor must come from the realm's authenticated
// context, never from a caller-supplied argument.
type AuthorizationPolicy interface {
	Authorize(op string, actor address) error
}

// BallotStatus is the lifecycle stage of a ballot.
type BallotStatus int

const (
	BallotDraft BallotStatus = iota
	BallotOpen
	BallotFinalized
)

func (s BallotStatus) String() string {
	switch s {
	case BallotDraft:
		return "draft"
	case BallotOpen:
		return "open"
	case BallotFinalized:
		return "finalized"
	}
	return "unknown"
}

// BallotOutcome is the committed result of a finalized ballot.
type BallotOutcome int

const (
	OutcomePending BallotOutcome = iota
	OutcomeWinner
	OutcomeTie
	OutcomeNoQuorum
	OutcomeNoVotes
)

func (o BallotOutcome) String() string {
	switch o {
	case OutcomePending:
		return "pending"
	case OutcomeWinner:
		return "winner"
	case OutcomeTie:
		return "tie"
	case OutcomeNoQuorum:
		return "no-quorum"
	case OutcomeNoVotes:
		return "no-votes"
	}
	return "unknown"
}

// BallotView is an inert summary of a ballot and its current tally.
type BallotView struct {
	ID             uint64
	Title          string
	Options        []string
	Status         BallotStatus
	Public         bool  // anyone may vote; no electorate snapshot
	ElectorateSize int   // 0 for public ballots
	QuorumPercent  int   // of the captured electorate
	OpenedAt       int64 // unix seconds, 0 while draft
	Deadline       int64 // unix seconds, 0 while draft
	Counts         []int // per option, same order as Options
	Abstentions    int
	Turnout        int // ballots cast, including abstentions
	Outcome        BallotOutcome
	Winner         int // option index when Outcome == OutcomeWinner, else -1
}

// BallotReader is the read side of a ballot box.
type BallotReader interface {
	Ballot(id uint64) (BallotView, bool)
}

// SubmissionStatus is the review state of a form submission.
type SubmissionStatus int

const (
	SubmissionSubmitted SubmissionStatus = iota
	SubmissionAccepted
	SubmissionRejected
)

func (s SubmissionStatus) String() string {
	switch s {
	case SubmissionSubmitted:
		return "submitted"
	case SubmissionAccepted:
		return "accepted"
	case SubmissionRejected:
		return "rejected"
	}
	return "unknown"
}

// SubmissionView is an inert copy of a submission.
type SubmissionView struct {
	ID        uint64
	Submitter address
	Answers   []string // in form field order
	Status    SubmissionStatus
}

// SubmissionReader is the read side of a form.
type SubmissionReader interface {
	Submission(id uint64) (SubmissionView, bool)
	// Submissions pages through submissions, optionally filtered by status
	// (pass -1 for all), in submission order.
	Submissions(status int, offset, limit int) []SubmissionView
	Count() int
}

// AppDescriptor identifies how a realm was composed. Generated realms expose
// one so the Lab can show an app's ingredients from the chain itself.
type AppDescriptor struct {
	Recipe            string
	RecipeVersion     string
	Components        []string // "<component-id>@<catalog-version>"
	ConfigDigest      string
	ViewSchemaVersion int
	Bindings          []string // "<interface>=<pkgpath>"
}
