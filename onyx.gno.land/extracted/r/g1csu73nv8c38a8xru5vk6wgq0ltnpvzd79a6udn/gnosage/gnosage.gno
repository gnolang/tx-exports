// Package gnosage is the on-chain review board for GnoSage, an autonomous
// open-source AI agent that reviews Gno realms and posts scored verdicts
// on-chain.
//
// Anyone can post a review. Reviews from registered agent keys are marked
// as agent reviews and are the ones the board surfaces as the headline
// verdict for each realm. Human reviews are kept alongside them.
//
// A review scores a realm 0-100 overall and in four categories (docs,
// tests, safety, code quality), carries a short verdict and a compact
// machine-readable check list, and is versioned per realm path so a
// re-review after a redeploy never overwrites history.
package gnosage

import (
	"chain"
	"errors"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Limits keep review payloads small: storage on Gno.land costs a
// refundable deposit, and a review board must stay cheap to write.
const (
	maxPathLength    = 256
	maxVerdictLength = 1000
	maxChecksLength  = 2000
)

const (
	// ReviewPostedEvent is emitted on every accepted review.
	ReviewPostedEvent = "ReviewPosted"
	// ReviewerRegisteredEvent is emitted when the owner registers a reviewer.
	ReviewerRegisteredEvent = "ReviewerRegistered"
	// ReviewerRemovedEvent is emitted when the owner removes a reviewer.
	ReviewerRemovedEvent = "ReviewerRemoved"
)

var (
	ErrEmptyPath      = errors.New("pkgPath must not be empty")
	ErrPathTooLong    = errors.New("pkgPath is too long")
	ErrBadPath        = errors.New("pkgPath must start with gno.land/")
	ErrScoreOutOfRange = errors.New("scores must be between 0 and 100")
	ErrEmptyVerdict   = errors.New("verdict must not be empty")
	ErrVerdictTooLong = errors.New("verdict is too long")
	ErrChecksTooLong  = errors.New("checks list is too long")
	ErrNotOwner       = errors.New("caller is not the owner")
	ErrReviewNotFound = errors.New("review not found")
)

// Review is one scored verdict for one realm path at one version.
type Review struct {
	ID        uint64    // global sequence number across all reviews
	PkgPath   string    // reviewed realm path, e.g. gno.land/r/<addr>/foo
	Version   uint64    // review version for this path, starting at 1
	Reviewer  address   // who posted it
	Agent     bool      // true when the reviewer is a registered agent key
	Score     int       // 0-100 overall
	Docs      int       // 0-100 documentation
	Tests     int       // 0-100 tests
	Safety    int       // 0-100 safety
	Quality   int       // 0-100 code quality
	Verdict   string    // short human-readable summary
	Checks    string    // compact check list, "name:result;name:result"
	CreatedAt time.Time // block time of the review
}

var (
	// Ownable gates reviewer registration to the deployer.
	Ownable *ownable.Ownable

	// reviews holds every review, keyed by "pkgPath#%020d" (version).
	reviews *avl.Tree
	// versions holds the review count per path, keyed by pkgPath.
	versions *avl.Tree
	// latestAgent holds the latest agent review version per path.
	latestAgent *avl.Tree
	// reviewers holds registered agent reviewer addresses, keyed by address.
	reviewers *avl.Tree
	// reviewCount is the total number of reviews posted.
	reviewCount uint64
)

func init(cur realm) {
	reviews = avl.NewTree()
	versions = avl.NewTree()
	latestAgent = avl.NewTree()
	reviewers = avl.NewTree()
	reviewCount = 0
	// At real deploy time the previous realm is the deploying user, who
	// becomes the owner. Under `gno test` there is no user caller, so the
	// owner stays unset and tests set it explicitly.
	if cur.Previous().IsUserCall() {
		Ownable = ownable.NewWithAddress(cur.Previous().Address())
	}
}

// reviewKey builds the storage key for one version of one path. The
// zero-padded version keeps lexicographic order equal to version order,
// so range scans over a path return reviews oldest-first.
func reviewKey(pkgPath string, version uint64) string {
	return pkgPath + "#" + ufmt.Sprintf("%020d", version)
}

// assertOwner panics unless the caller is the realm owner.
func assertOwner(cur realm) {
	if !Ownable.OwnedBy(cur.Previous().Address()) {
		panic(ErrNotOwner)
	}
}

// RegisterReviewer marks an address as a trusted agent reviewer. Only
// the owner can register reviewers. Reviews from registered reviewers
// are the board's headline verdicts.
func RegisterReviewer(cur realm, reviewer address) {
	assertOwner(cur)
	reviewers.Set(reviewer.String(), true)
	chain.Emit(ReviewerRegisteredEvent,
		"reviewer", reviewer.String(),
	)
}

// UnregisterReviewer removes a registered agent reviewer. Only the owner.
func UnregisterReviewer(cur realm, reviewer address) {
	assertOwner(cur)
	reviewers.Remove(reviewer.String())
	chain.Emit(ReviewerRemovedEvent,
		"reviewer", reviewer.String(),
	)
}

// IsReviewer reports whether an address is a registered agent reviewer.
func IsReviewer(reviewer address) bool {
	v, ok := reviewers.Get(reviewer.String()).(bool)
	return ok && v
}

// PostReview records a scored verdict for a realm path. Any caller may
// post; the review is marked as an agent review only when the caller is
// a registered agent reviewer. Returns the new version for the path.
func PostReview(cur realm, pkgPath string, score, docs, tests, safety, quality int, verdict, checks string) (uint64, error) {
	if err := validateReview(pkgPath, score, docs, tests, safety, quality, verdict, checks); err != nil {
		return 0, err
	}

	caller := cur.Previous().Address()
	agent := IsReviewer(caller)

	version := uint64(1)
	if v, ok := versions.Get(pkgPath).(int); ok {
		version = uint64(v) + 1
	}
	versions.Set(pkgPath, int(version))

	reviewCount++
	review := &Review{
		ID:        reviewCount,
		PkgPath:   pkgPath,
		Version:   version,
		Reviewer:  caller,
		Agent:     agent,
		Score:     score,
		Docs:      docs,
		Tests:     tests,
		Safety:    safety,
		Quality:   quality,
		Verdict:   verdict,
		Checks:    checks,
		CreatedAt: time.Now(),
	}
	reviews.Set(reviewKey(pkgPath, version), review)

	if agent {
		latestAgent.Set(pkgPath, int(version))
	}

	chain.Emit(ReviewPostedEvent,
		"pkg", pkgPath,
		"version", ufmt.Sprintf("%d", version),
		"reviewer", caller.String(),
		"agent", ufmt.Sprintf("%t", agent),
		"score", ufmt.Sprintf("%d", score),
	)

	return version, nil
}

// validateReview checks every field of a review before it is stored.
func validateReview(pkgPath string, score, docs, tests, safety, quality int, verdict, checks string) error {
	if strings.TrimSpace(pkgPath) == "" {
		return ErrEmptyPath
	}
	if len(pkgPath) > maxPathLength {
		return ErrPathTooLong
	}
	if !strings.HasPrefix(pkgPath, "gno.land/") {
		return ErrBadPath
	}
	for _, s := range []int{score, docs, tests, safety, quality} {
		if s < 0 || s > 100 {
			return ErrScoreOutOfRange
		}
	}
	if strings.TrimSpace(verdict) == "" {
		return ErrEmptyVerdict
	}
	if len(verdict) > maxVerdictLength {
		return ErrVerdictTooLong
	}
	if len(checks) > maxChecksLength {
		return ErrChecksTooLong
	}
	return nil
}

// GetReview returns one review by path and version, or nil.
func GetReview(pkgPath string, version uint64) *Review {
	v, ok := reviews.Get(reviewKey(pkgPath, version)).(*Review)
	if !ok {
		return nil
	}
	return v
}

// LatestAgentReview returns the newest agent review for a path, or nil
// when no agent has reviewed it yet.
func LatestAgentReview(pkgPath string) *Review {
	v, ok := latestAgent.Get(pkgPath).(int)
	if !ok {
		return nil
	}
	return GetReview(pkgPath, uint64(v))
}

// VersionCount returns how many reviews a path has received.
func VersionCount(pkgPath string) int {
	v, ok := versions.Get(pkgPath).(int)
	if !ok {
		return 0
	}
	return v
}

// ReviewCount returns the total number of reviews on the board.
func ReviewCount() uint64 {
	return reviewCount
}

// ReviewedPaths returns every path that has at least one review, in
// lexicographic order.
func ReviewedPaths() []string {
	paths := []string{}
	versions.Iterate("", "", func(key string, _ any) bool {
		paths = append(paths, key)
		return false
	})
	return paths
}
