package gnome

import (
	"std"
	"strings"
	"time"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

const (
	// Names of the initial DAOs.
	nameCouncilDAO = "council"
	nameMainDAO    = "main"

	// Minimum number of members per DAO.
	// This requirement is enforced because two members DAO can only use plurality to tally.
	minMembersCount = 3

	// Review deadline defines the time after which a proposal can't be withdrawed by the proposer.
	// Proposal can only be voted on after this deadline but not before.
	// This greace period gives the proposer the chance to withdraw a proposal if there is a mistake.
	reviewDeadline = time.Second
)

// Member roles
// TODO: Define the list of Gnome DAO roles
const (
	RoleDirector gnome.Role = "director"
	RoleEcoDev   gnome.Role = "eco-dev"
	RoleDev      gnome.Role = "dev"
	RoleRealm    gnome.Role = "realm"
)

// The "Gno.me" DAO defines an initial root DAO with a single sub DAO, where the root is
// the council DAO and the child is the main DAO. Council DAO members are hard coded and
// can't be modified. Main DAO members can be modified anytime though a modify DAO members
// proposals.
//
// The main DAO must have a minimum of three members at all time to be able to apply 2/3s
// voting majority criteria required for some proposal types allowed for the main DAO.
//
// Sub DAOs can be created though sub DAO add proposals but its members can't be modified
// once the sub DAO is created. Sub DAOs must be dismissed though a proposal and a new sub
// DAO must be created if its members must be modified.
var gnomeDAO = gnome.MustNew(
	nameCouncilDAO,
	"Council",
	gnome.WithManifest("Gnomes are thinking"),
	gnome.AssignAsSuperCouncil(),
	gnome.WithMembers(
		gnome.NewMember("g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun"),
		gnome.NewMember("g125t352u4pmdrr57emc4pe04y40sknr5ztng5mt"),
		gnome.NewMember("g1778y2yphxs2wpuaflsy5y9qwcd4gttn4g5yjx5"),
	),
	gnome.WithSubDAO(
		gnome.MustNew(
			nameMainDAO,
			"Main",
			gnome.WithManifest("Gnomes are building"),
			gnome.WithMembers(
				gnome.NewMember("g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun", RoleDev),
				gnome.NewMember("g125t352u4pmdrr57emc4pe04y40sknr5ztng5mt", RoleDev),
				gnome.NewMember("g1778y2yphxs2wpuaflsy5y9qwcd4gttn4g5yjx5", RoleEcoDev),
			),
		),
	),
)

// SubmitProposal submits a new proposal.
//
// This function allows other realms to submit custom proposal types.
// Realms must have a DAO assigned to their address to be able to create proposals in the assigned
// DAO or any of its sub DAOs.
//
// Parameters:
// - title: A title for the proposal (required)
// - description: A description of the proposal
// - strategy: A strategy for the new proposal (required)
// - daoPath: Path of the DAO where the proposal should be created (required)
//
// The DAO where the proposal is created is by default the DAO assigned to the caller realm address.
func SubmitProposal(title, description string, s gnome.ProposalStrategy, daoPath string) gnome.ID {
	assertDAOIsNotLocked()

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	id := genProposalID()
	p, err := gnome.NewProposal(id, s, caller, dao, title, gnome.WithDescription(description))
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	return p.ID()
}

// SubmitGeneralProposal submits a new general proposal.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
// Default voting period is 2 days but can optionally go up to 10 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal (required)
// - daoPath: Path of the DAO where the proposal should be created (required)
// - votingDeadline: Number of days until the voting period ends (default: 2)
//
// The name of the DAO where the proposal is created is a slug, where "council"
// is the Council DAO and "main" is the name of the Main DAO.
//
// The voting period deadline for the proposal must be between 2 and 10 days.
// It defaults to 2 days when `votingDeadline` value is 0.
func SubmitGeneralProposal(
	proposalTitle,
	proposalDescription,
	daoPath string,
	votingDeadline uint,
) uint64 {
	assertDAOIsNotLocked()

	opts := []gnome.ProposalOption{
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(reviewDeadline)),
	}

	if votingDeadline != 0 {
		if votingDeadline < 2 || votingDeadline > 10 {
			panic("voting period deadline must be between 2 and 10 days")
		}

		deadline := time.Now().Add(time.Hour * 24 * time.Duration(votingDeadline))
		opts = append(opts, gnome.WithVotingDeadline(deadline))
	}

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	p, err := gnome.NewProposal(genProposalID(), newGeneralStrategy(), caller, dao, proposalTitle, opts...)
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	AdvanceProposals()

	return uint64(p.ID())
}

// SubmitSubDAOCreationProposal submits a new proposal to add a sub DAO to an existing DAO.
//
// Proposal requires the participation of all DAO members, otherwise the outcome will be low participation.
// Default voting period is 7 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - parentDAOPath: Path of the sub DAO's parent (required)
// - subDAOName: Slug name of the new sub DAO (required)
// - subDAOTitle: A title for the new sub DAO (required)
// - subDAOManifest: Sub DAO manifest (required)
// - subDAOMembers: List of sub DAO member addresses (required)
//
// Sub DAO name must be a slug allows letters from "a" to "z", numbers, "-" and "_" as valid characters.
//
// The list of sub DAO members must be a newline separated list of addresses, with a minimum of 2 addresses.
// Each line must contain an address and optionally be followed by one or more DAO member roles:
// ```
// g187982000zsc493znqt828s90cmp6hcp2erhu6m foo
// g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 bar foo
// ```
func SubmitSubDAOCreationProposal(
	proposalTitle,
	proposalDescription,
	parentDAOPath,
	subDAOName,
	subDAOTitle,
	subDAOManifest,
	subDAOMembers string,
) uint64 {
	assertDAOIsNotLocked()

	dao := mustGetDAO(parentDAOPath)
	assertDAOIsNotDismissed(dao)

	subDAOPath := dao.Path() + gnome.PathSeparator + subDAOName
	if daos.HasPathKey(subDAOPath) {
		panic("sub DAO name is already taken by another DAO")
	}

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	members := gnome.MustParseStringToMembers(subDAOMembers)
	assertMemberRolesExist(members)

	strategy := newSubDAOCreationStrategy(daos, subDAOName, subDAOTitle, subDAOManifest, members)
	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(reviewDeadline)),
	)
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	AdvanceProposals()

	return uint64(p.ID())
}

// SubmitSubDAODismissalProposal submits a new proposal to dismiss a sub DAO.
//
// Dismissing a sub DAO also dismisses all active proposals and any sub DAO below the dismissed DAO tree.
// Only the direct parent of a DAO can create a proposal to dismiss any of its fist level sub DAOs.
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by plurality.
// Default voting period is 7 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - daoPath: Path of the DAO where the proposal should be created (required)
// - subDAOName: Slug name of the sub DAO to dismiss (required)
func SubmitSubDAODismissalProposal(proposalTitle, daoPath, subDAOName string) uint64 {
	assertDAOIsNotLocked()

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	subDAOPath := dao.Path() + gnome.PathSeparator + subDAOName
	subDAO := mustGetDAO(subDAOPath)
	assertDAOIsNotDismissed(subDAO)

	caller := std.GetOrigCaller()
	strategy := newSubDAODismissalStrategy(subDAO, proposals)
	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithReviewDeadline(time.Now().Add(reviewDeadline)),
	)
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	AdvanceProposals()

	return uint64(p.ID())
}

// SubmitDAOMembersModificationProposal submits a new proposal to modify the members of a DAO.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by super majority with a 2/3s threshold. Abstentions are not considered.
// Default voting period is 7 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - daoPath: Path of the DAO where the proposal should be created (required)
// - newMembers: List of member addresses to add to Main DAO
// - removeMembers: List of member addresses to remove from the Main DAO
//
// At leat one member address is required either to be added or removed from the DAO.
// Members can be added and removed within the same proposal.
//
// Each list of members must be newline separated list of addresses.
// Each line must contain an address and optionally be followed by one or more DAO member roles:
// ```
// g187982000zsc493znqt828s90cmp6hcp2erhu6m foo
// g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 bar foo
// ```
func SubmitDAOMembersModificationProposal(
	proposalTitle,
	proposalDescription,
	daoPath,
	newMembers,
	removeMembers string,
) uint64 {
	assertDAOIsNotLocked()

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	membersToAdd := gnome.MustParseStringToMembers(newMembers)
	assertMemberRolesExist(membersToAdd)
	membersToRemove := gnome.MustParseStringToMembers(removeMembers)
	assertMemberRolesExist(membersToRemove)

	strategy := newDAOMembersModificationStrategy(membersToAdd, membersToRemove)
	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(reviewDeadline)),
	)
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	AdvanceProposals()

	return uint64(p.ID())
}

// SubmitBudgetProposal submits a new budget proposal.
//
// Only membes of the Council or Main DAO can vote on this type of proposals.
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
// Default voting period is 7 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - daoPath: Path of the DAO where the proposal should be created (required)
// - budget: The proposal budget (required)
//
// Budget doesn't enforce any specific format right now but an example format that
// could be used is amount plus symbol, for example 100UGNOT, 100000USD, etc.
func SubmitBudgetProposal(
	proposalTitle,
	proposalDescription,
	daoPath,
	budget string,
) uint64 {
	assertDAOIsNotLocked()

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	strategy := newBudgetStrategy(gnomeDAO, budget)
	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(reviewDeadline)),
	)
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	AdvanceProposals()

	return uint64(p.ID())
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

func mustGetDAO(path string) *gnome.DAO {
	if strings.TrimSpace(path) == "" {
		panic("DAO path is empty")
	}

	dao, found := daos.GetByPath(path)
	if !found {
		panic("DAO not found")
	}
	return dao
}

func mustGetProposal(id uint64) *gnome.Proposal {
	p, found := proposals.GetByID(gnome.ID(id))
	if !found {
		panic("proposal not found")
	}
	return p
}

func assertMemberRolesExist(members []gnome.Member) {
	for _, m := range members {
		for _, r := range m.Roles {
			if !roles.Has(r.String()) {
				panic("unknown DAO member role: " + gnome.EscapeHTML(string(r)))
			}
		}
	}
}

func assertCanCreateProposal(proposer std.Address, dao *gnome.DAO) {
	if !dao.HasMember(proposer) {
		panic("you must be a DAO member to create a proposal")
	}
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

func assertDAOIsNotDismissed(dao *gnome.DAO) {
	// DAOs are locked when they are dismissed
	if dao.IsLocked() {
		panic("DAO is dismissed: " + dao.Path())
	}
}
