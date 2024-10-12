package gnome

import (
	"std"
	"strings"
	"time"

	gnome "gno.land/p/gnome/dao"
)

// SubmitCustomProposal submits a new proposal of a custom type.
//
// This function allows other realms to submit custom proposal types.
//
// Parameters:
// - title: A title for the proposal (required)
// - description: A description of the proposal
// - strategy: A strategy for the new proposal (required)
// - daoPath: Path of the DAO where the proposal should be created (required)
func SubmitCustomProposal(title, description string, s gnome.ProposalStrategy, daoPath string) gnome.ID {
	assertDAOIsNotLocked()

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	id := genProposalID()
	p, err := gnome.NewProposal(
		id,
		s,
		caller,
		dao,
		title,
		gnome.WithDescription(description),
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
	)
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
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal (required)
// - daoPath: Path of the DAO where the proposal should be created (required)
// - votingDeadline: Number of days until the voting period ends
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
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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
	strategy := newSubDAOCreationStrategy(daos, subDAOName, subDAOTitle, subDAOManifest, members)
	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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

	strategy := newDAOMembersModificationStrategy(
		gnome.MustParseStringToMembers(newMembers),
		gnome.MustParseStringToMembers(removeMembers),
	)
	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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

// SubmitDAOLockingProposal submits a new proposal to lock the DAO.
//
// Locking the DAO "freezes the state" by disallowing further modifications.
// State must be locked to migrate the realm to a newer version.
//
// Proposal requires a 33% quorum, otherwise the outcome will be low participation.
// This type of proposal can only be created by the Council or Main DAO members.
// Tally is done by plurality.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - daoPath: Path of the DAO where the proposal should be created (required)
// - reason: Text with the DAO locking reason
//
// The optional `reason` argument can contain HTML.
func SubmitDAOLockingProposal(
	proposalTitle,
	proposalDescription,
	daoPath,
	reason string,
) uint64 {
	assertDAOIsNotLocked()

	caller := std.GetOrigCaller()
	assertIsCouncilOrMainDAOMember(caller)

	dao := mustGetDAO(daoPath)
	assertIsCouncilOrMainDAO(dao)

	reason = strings.TrimSpace(reason)
	strategy := newLockingStrategy(gnomeDAO, reason, func() error {
		// Advance all proposals before locking the DAO
		advanceProposals()
		return nil
	})

	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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

// SubmitParamsUpdateProposal submits a new proposal to update one or more realm parameters.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - daoPath: Path of the DAO where the proposal should be created (required)
// - proposalReviewDeadline: Number of seconds where proposals can be withdrawed
// - votingPeriodSubDAOCreation: Voting period for sub DAO creation proposals
// - votingPeriodSubDAODismissal: Voting period for sub DAO dismissal proposals
// - votingPeriodDAOMembersModification: Voting period for DAO members modification proposals
// - votingPeriodBudget: Voting period for budget proposals
// - votingPeriodGeneral: Voting period for general proposals
// - votingPeriodLocking: Voting period for locking proposals
// - votingPeriodParamsUpdate: Voting period for parameters update proposals
//
// Voting period is the number of days that members can vote on a proposal
// At least one parameter value is required for creating a proposal.
func SubmitParamsUpdateProposal(
	proposalTitle,
	proposalDescription,
	daoPath string,
	proposalReviewDeadline,
	votingPeriodSubDAOCreation,
	votingPeriodSubDAODismissal,
	votingPeriodDAOMembersModification,
	votingPeriodBudget,
	votingPeriodGeneral,
	votingPeriodLocking,
	votingPeriodParamsUpdate int,
) uint64 {
	assertDAOIsNotLocked()

	dao := mustGetDAO(daoPath)
	assertDAOIsNotDismissed(dao)

	caller := std.GetOrigCaller()
	assertCanCreateProposal(caller, dao)

	strategy := paramsUpdateStrategy{
		reviewDeadline: time.Second * time.Duration(proposalReviewDeadline),
	}

	if votingPeriodSubDAOCreation > 0 {
		period := time.Duration(votingPeriodSubDAOCreation) * Day
		strategy.votingPeriods.Set(StrategyNameBudget, period)
	}

	if votingPeriodSubDAODismissal > 0 {
		period := time.Duration(votingPeriodSubDAODismissal) * Day
		strategy.votingPeriods.Set(StrategyNameBudget, period)
	}

	if votingPeriodDAOMembersModification > 0 {
		period := time.Duration(votingPeriodDAOMembersModification) * Day
		strategy.votingPeriods.Set(StrategyNameBudget, period)
	}

	if votingPeriodBudget > 0 {
		period := time.Duration(votingPeriodBudget) * Day
		strategy.votingPeriods.Set(StrategyNameBudget, period)
	}

	if votingPeriodGeneral > 0 {
		period := time.Duration(votingPeriodGeneral) * Day
		strategy.votingPeriods.Set(StrategyNameGeneral, period)
	}

	if votingPeriodLocking > 0 {
		period := time.Duration(votingPeriodLocking) * Day
		strategy.votingPeriods.Set(StrategyNameLocking, period)
	}

	if votingPeriodParamsUpdate > 0 {
		period := time.Duration(votingPeriodParamsUpdate) * Day
		strategy.votingPeriods.Set(StrategyNameParamsUpdate, period)
	}

	if strategy.votingPeriods.Size() == 0 && strategy.reviewDeadline == 0 {
		panic("at least one parameter value must be specified")
	}

	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(parameters.ReviewDeadline)),
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

func assertCanCreateProposal(proposer std.Address, dao *gnome.DAO) {
	if !dao.HasMember(proposer) {
		panic("you must be a DAO member to create a proposal")
	}
}

func assertDAOIsNotDismissed(dao *gnome.DAO) {
	// DAOs are locked when they are dismissed
	if dao.IsLocked() {
		panic("DAO is dismissed: " + dao.Path())
	}
}

func assertDAOIsNotLocked() {
	if gnomeDAO.IsLocked() {
		panic("DAO is locked")
	}
}

func assertIsCouncilOrMainDAO(dao *gnome.DAO) {
	if !dao.IsSuperCouncil() {
		// Main DAO parent must be the super council
		parentDAO := dao.Parent()
		if !parentDAO.IsSuperCouncil() {
			panic("DAO is not the council or main DAO")
		}
	}
}

func assertIsCouncilOrMainDAOMember(addr std.Address) {
	if !gnomeDAO.HasMember(addr) {
		mainDAO := gnomeDAO.SubDAOs()[0]
		if !mainDAO.HasMember(addr) {
			panic("account is not a council or main DAO member")
		}
	}
}
