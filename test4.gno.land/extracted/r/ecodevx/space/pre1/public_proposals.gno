package space

import (
	"regexp"
	"std"
	"strconv"
	"strings"
	"time"

	"gno.land/p/ecodevx/blog"
	gnomeDAO "gno.land/r/ecodevx/dao/pre1"
)

const maxSectionTitleLen = 60 // TODO: Should it be a parameter?

var realmPathRe = regexp.MustCompile(`^gno\.land\/r(?:\/_?[a-z]+[a-z0-9_]*)+$`)

// SubmitEditorsModificationProposal submits a new proposal to modify Gnome space editors.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - newEditors: List of editor addresses
// - removeEditors: List of editor addresses
//
// At least one editor to add or remove is required for the proposal to be valid.
// The list of editors must be a newline separated list of addresses.
func SubmitEditorsModificationProposal(
	proposalTitle,
	proposalDescription,
	newEditors,
	removeEditors string,
) uint64 {
	assertRealmIsNotLocked()

	strategy := editorsModificationStrategy{
		newEditors:    blog.MustParseStringToAddresses(newEditors),
		removeEditors: blog.MustParseStringToAddresses(removeEditors),
	}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, parameters.SpaceDAO)
	return uint64(id)
}

// SubmitDataSectionProposal submits a new proposal to add a datasource based Gnome space section.
//
// IMPORTANT, this function must be called using a MsgRun message, for example with `gnokey maketx run` command.
// The code uploaded within this message must be verified to be sure realm path matches the datasource's one.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - realm: The realm path of the datasource (required)
// - slug: Slug of the section (required)
// - sectionTitle: A title for the section (required)
// - ds: A datasource to retrieve section's data (required)
func SubmitDataSectionProposal(
	proposalTitle,
	proposalDescription,
	realm,
	slug,
	sectionTitle string,
	sectionDS Datasource,
) uint64 {
	assertRealmIsNotLocked()

	if sectionDS == nil {
		panic("section datasource is required")
	}

	if !std.PrevRealm().IsUser() {
		// TODO: Support realm calls when datasource package can be inferred
		panic("realm calls are not allowed")
	}

	sectionTitle = strings.TrimSpace(sectionTitle)
	assertValidSectionTitle(sectionTitle)
	assertIsSlug(slug)
	assertIsRealmPath(realm)

	strategy := dataSectionStrategy{
		slug:        slug,
		title:       sectionTitle,
		realm:       realm,
		datasource:  sectionDS,
		blockHeight: std.GetHeight(),
	}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, parameters.SpaceDAO)
	return uint64(id)
}

// SubmitLockingProposal submits a new proposal to lock the realm.
//
// Locking the realm "freezes the state" by disallowing further modifications.
// State must be locked to migrate the realm to a newer version.
//
// Proposal requires a 34% quorum, otherwise the outcome will be low participation.
// This type of proposal can only be created by members with `admin` role.
// Tally is done by plurality.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - realmPath: Path of the realm that should be allowed to import state data
//
// The optional realm path authorizes a realm to import the state data once the realm is locked.
func SubmitLockingProposal(proposalTitle, proposalDescription, realmPath string) uint64 {
	assertHasAdminRole(std.GetOrigCaller())

	if realmPath != "" && !strings.HasPrefix(realmPath, "gno.land/r/") {
		panic(`realm path must start with "gno.land/r/"`)
	}

	strategy := lockingStrategy{realmPath}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, parameters.SpaceDAO)
	return uint64(id)
}

// SubmitParamsUpdateProposal submits a new proposal to update one or more realm parameters.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - spaceDAO: Path to the space SubDAO
// - votingPeriodEditorsModification: Voting period for editors modification proposals
// - votingPeriodLocking: Voting period for realm locking proposals
// - votingPeriodParamsUpdate: Voting period for parameters update proposals
//
// Voting period is the number of days that members can vote on a proposal
// At least one parameter value is required for creating a proposal.
func SubmitParamsUpdateProposal(
	proposalTitle,
	proposalDescription,
	spaceDAO string,
	votingPeriodEditorsModification,
	votingPeriodLocking,
	votingPeriodParamsUpdate int,
) uint64 {
	strategy := paramsUpdateStrategy{}
	spaceDAO = strings.TrimSpace(spaceDAO)
	if spaceDAO != "" {
		if _, found := gnomeDAO.GetDAO(spaceDAO); !found {
			panic("space DAO path doesn't exist: " + spaceDAO)
		}

		strategy.spaceDAO = spaceDAO
	}

	if votingPeriodEditorsModification > 0 {
		period := time.Duration(votingPeriodEditorsModification) * Day
		strategy.votingPeriods.Set(StrategyNameEditorsModification, period)
	}

	if votingPeriodLocking > 0 {
		period := time.Duration(votingPeriodLocking) * Day
		strategy.votingPeriods.Set(StrategyNameLocking, period)
	}

	if votingPeriodParamsUpdate > 0 {
		period := time.Duration(votingPeriodParamsUpdate) * Day
		strategy.votingPeriods.Set(StrategyNameParamsUpdate, period)
	}

	if strategy.votingPeriods.Size() == 0 {
		panic("at least one parameter value must be specified")
	}

	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, parameters.SpaceDAO)
	return uint64(id)
}

func assertHasAdminRole(addr std.Address) {
	err := gnomeDAO.CheckMemberHasRole(parameters.SpaceDAO, addr, gnomeDAO.RoleAdmin)
	if err != nil {
		panic(err)
	}
}

func assertIsRealmPath(path string) {
	if !realmPathRe.MatchString(path) {
		panic("invalid realm path")
	}
}

func assertIsSlug(slug string) {
	if !blog.IsSlug(slug) {
		panic("invalid slug: " + slug)
	}
}

func assertValidSectionTitle(title string) {
	if title == "" {
		panic("section title is required")
	}

	if len(title) > maxSectionTitleLen {
		panic("maximum section title length is " + strconv.Itoa(maxSectionTitleLen) + " chars")
	}
}
