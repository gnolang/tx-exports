package dao

import (
	"errors"
	"std"
	"testing"
	"time"

	"gno.land/p/demo/testutils"

	gnome "gno.land/p/gnome/dao"
)

var (
	futureTime = time.Now().Add(time.Hour)
	zeroTime   = time.Time{}
)

// TODO: Improve proposal unit test using test cases and adding missing methods
func TestProposal(t *testing.T) {
	cases := []struct {
		name, title, description string
		dao                      *gnome.DAO
		err                      error
	}{
		{
			name:        "ok",
			dao:         gnome.MustNew("test", "Test"),
			title:       "Proposal",
			description: "Test proposal",
		},
		{
			name: "empty DAO",
			err:  errors.New("proposal DAO is required"),
		},
		{
			name: "empty title",
			dao:  gnome.MustNew("test", "Test"),
			err:  errors.New("proposal title is required"),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			id := gnome.ID(1)
			proposer := testutils.TestAddress("proposer")
			strategy := testStrategy{}
			status := gnome.StatusActive
			opts := []gnome.ProposalOption{
				gnome.WithDescription(tc.description),
			}

			// Act
			proposal, err := gnome.NewProposal(id, strategy, proposer, tc.dao, tc.title, opts...)

			// Assert
			if tc.err != nil {
				assertError(t, tc.err, err)
				return
			}

			assertNoError(t, err)

			if got := proposal.ID(); got != id {
				t.Fatalf("expected ID: %d, got: %d", id, got)
			}

			if got := proposal.DAO(); got.Name() != tc.dao.Name() {
				t.Fatalf("expected DAO: '%s', got: '%s'", tc.dao.Name(), got.Name())
			}

			if got := proposal.Title(); got != tc.title {
				t.Fatalf("expected title: '%s', got: '%s'", tc.title, got)
			}

			if got := proposal.Description(); got != tc.description {
				t.Fatalf("expected description: '%s', got: '%s'", tc.description, got)
			}

			if got := proposal.StatusReason(); got != "" {
				t.Fatalf("expected empty dismiss reason, got: '%s'", got)
			}

			if got := proposal.Proposer(); got != proposer {
				t.Fatalf("expected proposer: '%s', got: '%s'", proposer, got)
			}

			if got := proposal.CreatedAt(); got.IsZero() {
				t.Fatalf("expected a valid creation time, got: '%s'", got.String())
			}

			if c := len(proposal.Promotions()); c != 0 {
				t.Fatalf("expected an empty list of promotions, got: %d DAOs", c)
			}

			if got := proposal.VotingDeadline(); got.IsZero() {
				t.Fatalf("expected a valid deadline time, got: '%s'", got.String())
			}

			now := time.Now()
			if got := proposal.VotingDeadline(); got.Before(now) { // TODO: Using after makes assertion fail (?)
				t.Fatalf("expected deadline to happen after: '%s', got: '%s'", now.String(), got.String())
			}

			if got := proposal.Status(); got != status {
				t.Fatalf("expected status: %d, got: %d", status, got)
			}

			if got := proposal.Strategy().Name(); got != strategy.Name() {
				t.Fatalf("expected strategy: '%s', got: '%s'", strategy.Name(), got)
			}

			if got := proposal.Strategy().Name(); got != strategy.Name() {
				t.Fatalf("expected strategy: '%s', got: '%s'", strategy.Name(), got)
			}

			if c := len(proposal.Votes()); c != 0 {
				t.Fatalf("expected no votes, got: %d votes", c)
			}

			if c := proposal.VotingRecord().VoteCount(); c != 0 {
				t.Fatalf("expected an empty votes record, got: %d records", c)
			}
		})
	}
}

func TestProposalWithdraw(t *testing.T) {
	// TODO: Test success cases where proposal status is review
	wantErr := gnome.ErrReviewStatusRequired
	wantStatus := gnome.StatusWithdrawed
	proposal := mustCreateProposal(t, testStrategy{}, gnome.WithReviewDeadline(futureTime))

	if err := proposal.Withdraw(); err != nil {
		t.Fatalf("expected no error, got: '%s'", err.Error())
	}

	if err := proposal.Withdraw(); err != wantErr {
		t.Fatalf("expected error: '%s', got: '%s'", wantErr.Error(), err.Error())
	}

	if got := proposal.Status(); got != wantStatus {
		t.Fatalf("expected status: %d, got: %d", wantStatus, got)
	}
}

func TestProposalDismiss(t *testing.T) {
	cases := []struct {
		name, reason string
		status       gnome.ProposalStatus
		err          error
	}{
		{
			name:   "ok",
			reason: "Foo",
			status: gnome.StatusDismissed,
		},
		{
			name: "empty reason",
			err:  gnome.ErrReasonRequired,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			proposal := mustCreateProposal(t, testStrategy{})

			// Act
			err := proposal.Dismiss(tc.reason)

			// Assert
			if tc.err != nil {
				assertError(t, tc.err, err)
				return
			}

			assertNoError(t, err)

			if got := proposal.Status(); got != tc.status {
				t.Fatalf("expected status: %s, got: %s", tc.status.String(), got.String())
			}

			if got := proposal.StatusReason(); got != tc.reason {
				t.Fatalf("expected dismiss reason: '%s', got: '%s'", tc.reason, got)
			}
		})
	}
}

func TestProposalActivate(t *testing.T) {
	cases := []struct {
		name   string
		status gnome.ProposalStatus
		setup  func(*gnome.Proposal)
		err    error
	}{
		{
			name:   "ok",
			status: gnome.StatusActive,
		},
		{
			name: "review status required",
			setup: func(p *gnome.Proposal) {
				p.Activate()
			},
			err: gnome.ErrReviewStatusRequired,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			proposal := mustCreateProposal(t, testStrategy{}, gnome.WithReviewDeadline(futureTime))

			if tc.setup != nil {
				tc.setup(proposal)
			}

			// Act
			err := proposal.Activate()

			// Assert
			if tc.err != nil {
				assertError(t, tc.err, err)
				return
			}

			assertNoError(t, err)

			if got := proposal.Status(); got != tc.status {
				t.Fatalf("expected status: %s, got: %s", tc.status.String(), got.String())
			}
		})
	}
}

func TestProposalPromote(t *testing.T) {
	strategy := testStrategy{}
	addr := testutils.TestAddress("proposer")
	cases := []struct {
		name     string
		daoNames []string
		setup    func() (*gnome.Proposal, *gnome.DAO)
		err      error
	}{
		{
			name:     "promote to parent",
			daoNames: []string{"child", "parent"},
			setup: func() (*gnome.Proposal, *gnome.DAO) {
				child := gnome.MustNew("child", "Child")
				parent := gnome.MustNew("parent", "Parent", gnome.WithSubDAO(child))
				p, _ := gnome.NewProposal(1, strategy, addr, child, "Title")
				return p, parent
			},
		},
		{
			name:     "promote to root",
			daoNames: []string{"child", "root"},
			setup: func() (*gnome.Proposal, *gnome.DAO) {
				child := gnome.MustNew("child", "Child")
				root := gnome.MustNew("root", "Root", gnome.WithSubDAO(
					gnome.MustNew("parent", "Parent", gnome.WithSubDAO(child)),
				))
				p, _ := gnome.NewProposal(1, strategy, addr, child, "Title")
				return p, root
			},
		},
		{
			name: "promote to non parent",
			setup: func() (*gnome.Proposal, *gnome.DAO) {
				child := gnome.MustNew("child", "Child")
				gnome.MustNew("parent", "Parent", gnome.WithSubDAO(child))
				p, _ := gnome.NewProposal(1, strategy, addr, child, "Title")
				return p, gnome.MustNew("foo", "Foo")
			},
			err: gnome.ErrProposalPromote,
		},
		{
			name:     "promote with one promotion",
			daoNames: []string{"child", "parent", "root"},
			setup: func() (*gnome.Proposal, *gnome.DAO) {
				child := gnome.MustNew("child", "Child")
				parent := gnome.MustNew("parent", "Parent", gnome.WithSubDAO(child))
				root := gnome.MustNew("root", "Root", gnome.WithSubDAO(parent))
				p, _ := gnome.NewProposal(1, strategy, addr, child, "Title")
				p.Promote(parent)
				return p, root
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			p, dao := tc.setup()

			deadline := time.Now().Add(-time.Hour * 24)
			p.votingDeadline = deadline // Change deadline to check that its resetted on promote

			p.VotingRecord().Add(gnome.Vote{}) // Add a single dummy vote for the current DAO

			// Act
			err := p.Promote(dao)

			// Assert
			if tc.err != nil {
				assertError(t, tc.err, err)
				return
			}

			assertNoError(t, err)

			if !p.HasBeenPromoted() {
				t.Fatal("expected proposal to be promotedt")
			}

			if !p.HasPromotion(dao.Path()) {
				t.Fatal("expected proposal promotions to include the DAO")
			}

			if got := p.VotingDeadline(); !got.After(deadline) {
				t.Fatalf("expected voting deadline to be greater than original deadline: %d, got: %d", deadline.Unix(), got.Unix())
			}

			if p.VotingRecord().VoteCount() != 0 {
				t.Fatal("expected the voting record to be empty")
			}

			promotions := p.Promotions()
			if c := len(promotions); c != len(tc.daoNames) {
				t.Fatalf("expected promotions count: %d, got: %d DAOs", len(tc.daoNames), c)
			}

			for i, dao := range promotions {
				if got := dao.Name(); tc.daoNames[i] != got {
					t.Fatalf("expected DAO name: '%s', got: '%s'", tc.daoNames[i], got)
				}
			}
		})
	}
}

func TestProposalVote(t *testing.T) {
	memberAddr := testutils.TestAddress("member")
	setupDAOMember := func(p *gnome.Proposal) {
		p.DAO().AddMember(gnome.NewMember(memberAddr))
	}

	cases := []struct {
		name, reason string
		address      std.Address
		choice       gnome.VoteChoice
		voteCount    int
		options      []gnome.ProposalOption
		setup        func(*gnome.Proposal)
		err          error
	}{
		{
			name:      "ok",
			address:   memberAddr,
			choice:    gnome.ChoiceYes,
			voteCount: 1,
			setup:     setupDAOMember,
		},
		{
			name:    "proposal not active",
			address: memberAddr,
			choice:  gnome.ChoiceYes,
			options: []gnome.ProposalOption{
				gnome.WithReviewDeadline(futureTime),
			},
			err: gnome.ErrProposalNotActive,
			setup: func(p *gnome.Proposal) {
				setupDAOMember(p)
				p.Withdraw()
			},
		},
		{
			name:    "vote with invalid reason",
			address: memberAddr,
			choice:  gnome.ChoiceYes,
			reason:  "1234",
			err:     gnome.ErrInvalidReason,
			setup:   setupDAOMember,
		},
		{
			name:      "already voted",
			address:   memberAddr,
			choice:    gnome.ChoiceYes,
			voteCount: 1,
			options: []gnome.ProposalOption{
				gnome.WithVoteChangeDuration(-1),
			},
			err: gnome.ErrAlreadyVoted,
			setup: func(p *gnome.Proposal) {
				setupDAOMember(p)
				p.Vote(memberAddr, gnome.ChoiceYes, "")
			},
		},
		{
			name:    "vote after proposal deadline",
			address: memberAddr,
			choice:  gnome.ChoiceYes,
			options: []gnome.ProposalOption{
				gnome.WithVotingDeadline(zeroTime),
			},
			err:   gnome.ErrProposalVotingDeadlineMet,
			setup: setupDAOMember,
		},
		{
			name:    "non member vote not allowed",
			address: memberAddr,
			choice:  gnome.ChoiceYes,
			err:     gnome.ErrMemberVoteNotAllowed,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			proposal := mustCreateProposal(t, testStrategy{}, tc.options...)

			if tc.setup != nil {
				tc.setup(proposal)
			}

			// Act
			err := proposal.Vote(tc.address, tc.choice, tc.reason)

			// Assert
			if tc.err != nil {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}

			votes := proposal.Votes()
			voteCount := len(votes)
			if voteCount != tc.voteCount {
				t.Fatalf("expected %d vote(s), got: %d", tc.voteCount, voteCount)
			}

			if voteCount > 0 {
				if got := votes[0].Address; got != tc.address {
					t.Fatalf("expected vote address: '%s', got: '%s'", tc.address, got)
				}

				if got := votes[0].Choice; got != tc.choice {
					t.Fatalf("expected vote choice: '%s', got: '%s'", tc.choice, got)
				}

				if got := votes[0].Reason; got != tc.reason {
					t.Fatalf("expected vote reason: '%s', got: '%s'", tc.reason, got)
				}
			}
		})
	}
}

func TestProposalTally(t *testing.T) {
	addresses := [3]std.Address{
		testutils.TestAddress("member1"),
		testutils.TestAddress("member2"),
		testutils.TestAddress("member3"),
	}
	setupDAOMembers := func(p *gnome.Proposal) {
		dao := p.DAO()
		for _, addr := range addresses {
			dao.AddMember(gnome.NewMember(addr))
		}
	}

	cases := []struct {
		name                 string
		votes                []gnome.Vote
		choice               gnome.VoteChoice
		strategy             gnome.ProposalStrategy
		status               gnome.ProposalStatus
		statusReason         string
		votingDeadlinePassed bool
		options              []gnome.ProposalOption
		setup                func(*gnome.Proposal)
		err                  error
	}{
		{
			name: "proposal pass",
			votes: []gnome.Vote{
				{Address: addresses[0], Choice: gnome.ChoiceYes},
				{Address: addresses[1], Choice: gnome.ChoiceYes},
			},
			choice:   gnome.ChoiceYes,
			strategy: testStrategy{gnome.ChoiceYes},
			status:   gnome.StatusPassed,
			options:  []gnome.ProposalOption{gnome.WithVotingDeadline(zeroTime)},
			setup:    setupDAOMembers,
		},
		{
			name: "proposal rejected",
			votes: []gnome.Vote{
				{Address: addresses[0], Choice: gnome.ChoiceYes},
				{Address: addresses[1], Choice: gnome.ChoiceNo},
				{Address: addresses[2], Choice: gnome.ChoiceNo},
			},
			choice:   gnome.ChoiceNo,
			strategy: testStrategy{gnome.ChoiceNo},
			status:   gnome.StatusRejected,
			options:  []gnome.ProposalOption{gnome.WithVotingDeadline(zeroTime)},
			setup:    setupDAOMembers,
		},
		{
			name: "no quorum",
			votes: []gnome.Vote{
				{Address: addresses[0], Choice: gnome.ChoiceYes},
			},
			strategy:     testStrategy{},
			status:       gnome.StatusRejected,
			statusReason: "low participation",
			options:      []gnome.ProposalOption{gnome.WithVotingDeadline(zeroTime)},
			setup:        setupDAOMembers,
		},
		{
			name:     "proposal not active",
			status:   gnome.StatusWithdrawed,
			options:  []gnome.ProposalOption{gnome.WithReviewDeadline(futureTime)},
			strategy: testStrategy{},
			setup: func(p *gnome.Proposal) {
				p.Withdraw()
			},
			err: gnome.ErrProposalNotActive,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			proposal := mustCreateProposal(t, tc.strategy, tc.options...)

			for _, v := range tc.votes {
				// Add votes directly to the record because deadline might be expired for some test cases
				proposal.VotingRecord().Add(v)
			}

			if tc.setup != nil {
				tc.setup(proposal)
			}

			// Act
			err := proposal.Tally()

			// Assert
			if tc.err != nil {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}

			if got := proposal.Status(); got != tc.status {
				t.Fatalf("expected status: %d, got: %d", tc.status, got)
			}

			if got := proposal.StatusReason(); got != tc.statusReason {
				t.Fatalf("expected status reason: '%s', got: '%s'", tc.statusReason, got)
			}

			if got := proposal.Choice(); got != tc.choice {
				t.Fatalf("expected winner choice: '%s', got: '%s'", tc.choice, got)
			}
		})
	}
}

func mustCreateProposal(t *testing.T, s gnome.ProposalStrategy, options ...gnome.ProposalOption) *gnome.Proposal {
	t.Helper()

	dao := gnome.MustNew("test", "Test")
	addr := testutils.TestAddress("proposer")
	proposal, err := gnome.NewProposal(1, s, addr, dao, "Title", options...)
	if err != nil {
		t.Fatal(err)
	}

	return proposal
}

func assertError(t *testing.T, expected interface{}, actual error) {
	t.Helper()

	want, ok := expected.(string)
	if !ok {
		if err, ok := expected.(error); ok {
			want = err.Error()
		}
	}

	if actual == nil {
		t.Fatalf("expected error: '%s', got no error", want)
	}

	if want != actual.Error() {
		t.Fatalf("expected error: '%s', got: '%s'", want, actual.Error())
	}
}

func assertNoError(t *testing.T, err interface{}) {
	t.Helper()

	if err == nil {
		return
	}

	actual, ok := err.(string)
	if !ok {
		if e, ok := err.(error); ok {
			actual = e.Error()
		}
	}

	if actual != "" {
		t.Fatalf("expected no error, got: '%s'", actual)
	}
}

type testStrategy struct {
	Choice gnome.VoteChoice
}

func (testStrategy) Name() string                                            { return "test" }
func (testStrategy) Quorum() float64                                         { return 0.51 }
func (testStrategy) VotingPeriod() time.Duration                             { return time.Hour * 24 * 2 }
func (s testStrategy) Tally(*gnome.DAO, gnome.VotingRecord) gnome.VoteChoice { return s.Choice }

func (testStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}
