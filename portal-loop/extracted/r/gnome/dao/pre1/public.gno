package gnome

import (
	"std"
	"strings"

	gnome "gno.land/p/gnome/dao"
	router "gno.land/p/gnome/router/v1"
)

// Render returns a Markdown string with DAO or proposal details.
// By default it renders the Council DAO details view.
//
// Paths:
//   - `dao/DAO_PATH` => Renders DAO or sub DAO details
//   - `proposal/PROPOSAL_ID` => Renders details for a proposal
//   - `proposals/DAO_PATH` => Renders the list of proposals for a DAO
func Render(path string) string {
	r := router.New()

	r.HandleFunc("", renderDAO)
	r.HandleFunc("dao", renderDAO)
	r.HandleFunc("proposal", renderProposal)
	r.HandleFunc("proposals", renderProposals)
	r.HandleFunc("params", renderParams)

	// Render global alerts before proposal states are updated within the handlers
	return renderAlerts() + r.Render(path)
}

// GetDAO returns an invariant reference to a DAO.
// Council DAO is returned when path is empty.
func GetDAO(path string) gnome.InvarDAO {
	if path == "" {
		path = nameCouncilDAO
	}

	dao := mustGetDAO(path)
	return gnome.NewInvarDAO(dao)
}

// IterateProposals iterates DAO proposals by ascending IDs.
func IterateProposals(fn func(gnome.InvarProposal) bool) {
	proposals.Iterate(func(p *gnome.Proposal) bool {
		return fn(gnome.NewInvarProposal(p))
	})
}

// WithdrawProposal withdraws a proposal.
// Proposals can only be withdrawed by the account that creates it when the state is "review".
// They can't be withdrawed once the review deadline of one hour after creation is met.
func WithdrawProposal(proposalID uint64) string {
	assertDAOIsNotLocked()

	p := mustGetProposal(proposalID)
	assertCallerCanWithdraw(p)

	if err := p.Withdraw(); err != nil {
		panic(err)
	}

	AdvanceProposals()

	return "Proposal withdrawed"
}

// Vote submits a vote for a proposal.
//
// Parameters:
// - proposalID: ID of the proposal to vote (required)
// - vote: Voting choice, true=Yes, false=No (required)
// - reason: Text with the reason for the vote
// - daoPath: Path of the DAO where the voting account belongs to
//
// Reason is in general optional but might be required for some proposals when voting No.
//
// DAO name is optional and by default is the one that the proposal belongs to.
// Only parents of the proposal's DAO are allowed as `daoPath` values.
// Child votes are not tallied when a member of a parent DAO votes on a child's proposal.
func Vote(proposalID uint64, vote bool, reason, daoPath string) string {
	assertDAOIsNotLocked()

	// Make sure proposal states are up to date before submitting the vote
	AdvanceProposals()

	// Get proposal and check that current status accepts votes
	p := mustGetProposal(proposalID)
	if s := p.Status(); s.IsFinal() {
		panic("proposal status doesn't allow new vote submissions: " + s.String())
	}

	// When a DAO name is availalable check that it matches one of the proposal's DAO parents
	// and if so promote the proposal to a parent DAO. Promoting a proposal invalidates the votes
	// submitted by current DAO's members and moves voting responsibility to the parent DAO members.
	daoPath = strings.TrimSpace(daoPath)
	if daoPath != "" && p.DAO().Path() != daoPath {
		// Check that the path belongs to a parent DAO.
		// Path separator is added to the prefix to make sure that similar prefixes don't match.
		if !strings.HasPrefix(p.DAO().Path(), daoPath+gnome.PathSeparator) {
			panic(`path "` + daoPath + `" is not a parent of the proposal's DAO path`)
		}

		// Promote the active proposal's DAO to a parent DAO
		parentDAO := mustGetDAO(daoPath)
		if err := p.Promote(parentDAO); err != nil {
			panic(err)
		}

		// Reindex the proposal so its available under the parent DAO proposals. Child DAO will also
		// keep the promoted proposal indexed so it can be listed within the child DAO's proposals.
		proposals.Index(p)
	}

	// When proposal has "review" status check if deadline is met and if so activate it
	if p.Status() == gnome.StatusReview {
		if !p.HasReviewDeadlinePassed() {
			panic("votes are not allowed until " + p.ReviewDeadline().UTC().Format("2006-01-02 15:04 MST"))
		}

		if err := p.Activate(); err != nil {
			panic(err)
		}
	}

	var choice gnome.VoteChoice
	if vote {
		choice = gnome.ChoiceYes
	} else {
		choice = gnome.ChoiceNo
	}

	// Submit vote
	caller := std.GetOrigCaller() // TODO: Check that caller is member of the DAO
	err := p.Vote(caller, gnome.VoteChoice(choice), reason)
	if err != nil {
		panic(err)
	}

	return "Vote submitted for proposal " + makeProposalURI(gnome.ID(proposalID), false)
}

// AdvanceProposals iterates review and active proposals and tallies proposals that met their deadlines.
// Proposals in review status are activated to allow voting.
// Active proposals are tallied which means the number of votes is counted and status changed accordingly.
// Active executable proposals are executed when the proposal status changes to "passed".
func AdvanceProposals() string {
	assertDAOIsNotLocked()

	advanceProposals()

	return "Proposals advanced for realm " + makeRealmURL("")
}

// IsProposalsAdvanceNeeded checks if a call to `AdvanceProposals()` is required to update proposals.
func IsProposalsAdvanceNeeded() bool {
	if gnomeDAO.IsLocked() {
		return false
	}

	return proposals.ReverseIterate(func(p *gnome.Proposal) bool {
		switch p.Status() {
		case gnome.StatusReview:
			if p.HasReviewDeadlinePassed() {
				return true
			}
		case gnome.StatusActive:
			if p.HasVotingDeadlinePassed() {
				return true
			}
		}
		return false
	})
}

func advanceProposals() {
	// TODO: Use unix timestamp as part of proposal IDs to avoid iterating older tallied proposals
	proposals.Iterate(func(p *gnome.Proposal) bool {
		status := p.Status()
		if status == gnome.StatusReview && p.HasReviewDeadlinePassed() {
			p.Activate()
			status = p.Status()
		}

		if p.Status() == gnome.StatusActive && p.HasVotingDeadlinePassed() {
			p.Tally()

			// Change proposal status to failed when execution fails
			if err := p.Execute(); gnome.IsExecutionError(err) {
				p.Fail("failed due to conflicts: " + err.Error())
			}
		}
		return false
	})
}

func mustGetProposal(id uint64) *gnome.Proposal {
	p, found := proposals.GetByID(gnome.ID(id))
	if !found {
		panic("proposal not found")
	}
	return p
}

func assertCallerCanWithdraw(p *gnome.Proposal) {
	if p.Proposer() != std.GetOrigCaller() {
		panic("proposals can only be withdrawed by the proposer")
	}

	if p.Status() != gnome.StatusReview {
		panic(`proposals can only be withdrawed when status is "review"`)
	} else if p.HasReviewDeadlinePassed() {
		panic("withdrawal not allowed, withdrawal deadline expired")
	}
}
