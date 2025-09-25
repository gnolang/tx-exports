package tutorials

import (
	"std"
	"strings"
	"time"

	"gno.land/p/gnome/blog"
	gnome "gno.land/p/gnome/dao"
	gnomeDAO "gno.land/r/gnome/dao/pre1"
)

// TODO: Move to a parameter
const tutorialsPath = "council/main/community/tutorials"

// SubmitCreationProposal submits a new proposal to create a new tutorial.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - tutorialSlug: Slug name of the tutorial (required)
// - tutorialTitle: A title for the tutorial (required)
// - tutorialContentHash: A SHA256 hash of the tutorial's content (required)
// - tutorialContentURL: A URL where the tutorial's content is currently available (required)
// - tutorialAuthors: List of author addresses (required)
// - tutorialEditors:	List of editor addresses
// - tutorialTags: Space separated list of tutorial tags
//
// Tutorial slug name allows letters from "a" to "z", numbers and "-" as valid characters.
// Unicode letters are also allowed.
//
// The list of authors and editors must be a newline separated list of addresses.
func SubmitCreationProposal(
	proposalTitle,
	proposalDescription,
	tutorialSlug,
	tutorialTitle,
	tutorialContentHash,
	tutorialContentURL,
	tutorialAuthors,
	tutorialEditors,
	tutorialTags string,
) uint64 {
	assertRealmIsNotLocked()
	assertSlugIsAvailable(tutorialSlug)
	blog.AssertTitleIsNotEmpty(tutorialTitle)
	blog.AssertIsSlug(tutorialSlug)
	blog.AssertIsSha256Hash(tutorialContentHash)
	blog.AssertIsContentURL(tutorialContentURL)

	tags := strings.Fields(tutorialTags)
	assertValidTags(tags)

	authors := blog.MustParseStringToAddresses(tutorialAuthors)
	if len(authors) == 0 {
		panic("tutorial authors must have at least one author's address")
	}

	strategy := creationStrategy{
		slug:        tutorialSlug,
		title:       strings.TrimSpace(tutorialTitle),
		contentHash: tutorialContentHash,
		contentURL:  tutorialContentURL,
		authors:     authors,
		editors:     blog.MustParseStringToAddresses(tutorialEditors),
		tags:        tags,
	}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, tutorialsPath)
	return uint64(id)
}

// SubmitModificationProposal submits a new proposal to modify a tutorial.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - tutorialSlug: Slug name of the tutorial (required)
// - tutorialTitle: A title for the tutorial
// - tutorialContentHash: A SHA256 hash of the new tutorial's content
// - tutorialCurrentContentHash: A SHA256 hash of the current tutorial's content
// - tutorialContentURL: A URL where the new tutorial's content is currently available
// - tutorialNewAuthors: List of author addresses
// - tutorialNewEditors:	List of editor addresses
// - tutorialTags: Space separated list of tutorial tags
//
// Tutorial slug name allows letters from "a" to "z", numbers and "-" as valid characters.
// Unicode letters are also allowed.
//
// The list of new authors and editors must be a newline separated list of addresses.
// If present, authors and editors are appended to the current list of authors and editors.
func SubmitModificationProposal(
	proposalTitle,
	proposalDescription,
	tutorialSlug,
	tutorialTitle,
	tutorialContentHash,
	tutorialCurrentContentHash,
	tutorialContentURL,
	tutorialNewAuthors,
	tutorialNewEditors,
	tutorialTags string,
) uint64 {
	assertRealmIsNotLocked()

	tutorialSlug = strings.TrimSpace(tutorialSlug)
	assertTutorialExists(tutorialSlug)

	tags := strings.Fields(tutorialTags)
	assertValidTags(tags)

	tutorialContentHash = strings.TrimSpace(tutorialContentHash)
	if tutorialContentHash != "" {
		tutorialCurrentContentHash = strings.TrimSpace(tutorialCurrentContentHash)
		if tutorialCurrentContentHash == "" {
			panic("the current content hash of the tutorial to modify is required")
		}

		blog.AssertIsSha256Hash(tutorialContentHash)
		blog.AssertIsSha256Hash(tutorialCurrentContentHash)
		blog.AssertIsContentURL(tutorialContentURL)
	}

	strategy := modificationStrategy{
		slug:               tutorialSlug,
		title:              strings.TrimSpace(tutorialTitle),
		contentHash:        tutorialContentHash,
		currentContentHash: tutorialCurrentContentHash,
		contentURL:         tutorialContentURL,
		authors:            blog.MustParseStringToAddresses(tutorialNewAuthors),
		editors:            blog.MustParseStringToAddresses(tutorialNewEditors),
		tags:               tags,
	}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, tutorialsPath)
	return uint64(id)
}

// SubmitDeletionProposal submits a new proposal to delete a tutorial.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - tutorialSlug: Slug name of the tutorial (required)
func SubmitDeletionProposal(proposalTitle, proposalDescription, tutorialSlug string) uint64 {
	assertRealmIsNotLocked()

	tutorialSlug = strings.TrimSpace(tutorialSlug)
	assertTutorialExists(tutorialSlug)

	strategy := deletionStrategy{tutorialSlug}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, tutorialsPath)
	return uint64(id)
}

// SubmitLockingProposal submits a new proposal to lock the realm.
//
// Locking the realm "freezes the state" by disallowing further modifications.
// State must be locked to migrate the realm to a newer version.
//
// Proposal requires a 33% quorum, otherwise the outcome will be low participation.
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
	assertHasAdminRole(std.OriginCaller())

	if realmPath != "" && !strings.HasPrefix(realmPath, "gno.land/r/") {
		panic(`realm path must start with "gno.land/r/"`)
	}

	strategy := lockingStrategy{realmPath}
	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, tutorialsPath)
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
// - votingPeriodCreation: Voting period for tutorial creation proposals
// - votingPeriodModification: Voting period for tutorial modification proposals
// - votingPeriodDeletion: Voting period for tutorial deletion proposals
// - votingPeriodLocking: Voting period for realm locking proposals
// - votingPeriodParamsUpdate: Voting period for parameters update proposals
//
// Voting period is the number of days that members can vote on a proposal
// At least one parameter value is required for creating a proposal.
func SubmitParamsUpdateProposal(
	proposalTitle,
	proposalDescription string,
	votingPeriodCreation,
	votingPeriodModification,
	votingPeriodDeletion,
	votingPeriodLocking,
	votingPeriodParamsUpdate int,
) uint64 {
	strategy := paramsUpdateStrategy{}
	if votingPeriodCreation > 0 {
		period := time.Duration(votingPeriodCreation) * Day
		strategy.votingPeriods.Set(StrategyNameCreation, period)
	}

	if votingPeriodModification > 0 {
		period := time.Duration(votingPeriodModification) * Day
		strategy.votingPeriods.Set(StrategyNameModification, period)
	}

	if votingPeriodDeletion > 0 {
		period := time.Duration(votingPeriodDeletion) * Day
		strategy.votingPeriods.Set(StrategyNameDeletion, period)
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

	id := gnomeDAO.SubmitCustomProposal(proposalTitle, proposalDescription, strategy, tutorialsPath)
	return uint64(id)
}

func assertSlugIsAvailable(slug string) {
	if tutorialsBlog.HasPost(slug) {
		panic("tutorial URL slug already exists")
	}
}

func assertTutorialExists(slug string) {
	if !tutorialsBlog.HasPost(slug) {
		panic("tutorial not found")
	}
}

func assertValidTags(tags []string) {
	for _, t := range tags {
		if !blog.IsSlug(t) {
			panic("invalid tag: " + t)
		}
	}
}

func assertHasAdminRole(addr std.Address) {
	dao := gnomeDAO.GetDAO(tutorialsPath)
	m, found := getMember(dao, addr)
	if !found {
		panic("address is not a member of tutorials DAO: " + addr.String())
	}

	for _, r := range m.Roles {
		if r == gnomeDAO.RoleAdmin {
			// Member has admin role
			return
		}
	}

	panic("member doesn't have admin role: " + addr.String())
}

func getMember(dao gnome.InvarDAO, addr std.Address) (gnome.Member, bool) {
	for _, m := range dao.Members() {
		if m.Address == addr {
			return m, true
		}
	}
	return gnome.Member{}, false
}
