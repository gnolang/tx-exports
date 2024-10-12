package tutorials

import (
	"errors"
	"std"
	"strings"
	"time"

	"gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/blog"
	dao "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao/v1"
)

const tutorialsDAO = "council/main/sections/tutorials"

// Imported defines an interface to allow exporting realm data.
type Importer interface {
	// Import imports tutorials.
	Import(blog.InvarBlog) error
}

// SubmitCreationProposal submits a new proposal to create a new tutorial.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
// Default voting period is 7 days.
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
	id := dao.SubmitProposal(proposalTitle, proposalDescription, strategy, tutorialsDAO)
	return uint64(id)
}

// SubmitModificationProposal submits a new proposal to modify a tutorial.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
// Default voting period is 4 days.
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
	id := dao.SubmitProposal(proposalTitle, proposalDescription, strategy, tutorialsDAO)
	return uint64(id)
}

// SubmitDeletionProposal submits a new proposal to delete a tutorial.
//
// Proposal requires a 51% quorum, otherwise the outcome will be low participation.
// Tally is done by absolute majority, so all abstentions are considered.
// Default voting period is 2 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - tutorialSlug: Slug name of the tutorial (required)
func SubmitDeletionProposal(proposalTitle, proposalDescription, tutorialSlug string) uint64 {
	tutorialSlug = strings.TrimSpace(tutorialSlug)
	assertTutorialExists(tutorialSlug)

	strategy := deletionStrategy{tutorialSlug}
	id := dao.SubmitProposal(proposalTitle, proposalDescription, strategy, tutorialsDAO)
	return uint64(id)
}

// Publish publishes content for a tutorial.
//
// The submited content must be previously approved by a creation or modification proposal.
//
// Parameters:
// - slug: Slug name of the tutorial (required)
// - content: The tutorial content to publish (required)
func Publish(slug, content string) {
	// Check that content checksum matches the approved content for the tutorial post
	p := mustGetPost(slug)
	blog.AssertContentSha256Hash(content, p.ContentHash)

	// Add caller to the list of publishers
	caller := std.GetOrigCaller()
	if !p.Publishers.HasAddress(caller) {
		p.Publishers = append(p.Publishers, caller)
	}

	if p.Status == blog.StatusDraft {
		p.PublishAt = time.Now()
	}

	p.Status = blog.StatusPublished
	p.Content = content
	p.UpdatedAt = time.Now()
}

// Export exports the tutorial realm's state.
// The caller's realm path prefix must match the prefix of the tutorials realm
// to be able to import the state.
func Export(x Importer) error {
	// TODO: Check that realm is locked and the caller realm path is the next version
	currentPath := std.CurrentRealm().PkgPath()
	if !strings.HasPrefix(std.PrevRealm().PkgPath(), currentPath) {
		return errors.New("caller realm path must start with: " + currentPath)
	}

	return x.Import(blog.NewInvarBlog(&tutorialsBlog))
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
