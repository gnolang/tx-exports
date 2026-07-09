// Package memba_appstore_reviews_v1 is the dedicated on-chain reviews / web-of-trust realm for
// Memba App Store listings. Subject = an app's package path (e.g. gno.land/r/samcrew/…).
//
// It is a THIN wrapper over the shared, audited p/samcrew/reviews engine (extracted from the
// DoS-hardened memba_reviews_v2: RV-1 O(1) subject summary, RV-3 flaggedIDs GC). This realm
// owns one Store and supplies only what a package cannot: the caller (unsafe.PreviousRealm),
// the block height (runtime.ChainHeight), the moderator-multisig gate on takedowns, and a
// gnoweb Render() view. The ABI mirrors memba_reviews_v2 exactly so the frontend reviews
// client can target this realm by path with no code change.
//
// WHY DEDICATED (not the shared memba_reviews realm): reputation isolation. memba_reviews keeps
// a global per-author reputation; sharing it would let sockpuppet down-votes on an app review
// bleed into someone's validator web-of-trust. A separate Store + moderator wall that off.
package memba_appstore_reviews_v1

import (
	"strings"

	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/ufmt/v0"

	reviews "gno.land/p/samcrew/memba_reviews_core_v1"
)

// ModeratorAddress is the Memba moderator multisig (samcrew-core-test1 on testnet).
// CONFIRM before deploy — takedowns (Hide*/Unhide) are gated to exactly this address.
const ModeratorAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

var store *reviews.Store

func init() { store = reviews.NewStore() }

func caller() address { return unsafe.PreviousRealm().Address() }

func height() int64 { return runtime.ChainHeight() }

func assertModerator() {
	if caller() != address(ModeratorAddress) {
		panic("unauthorized: moderator multisig only")
	}
}

// ── Writes ───────────────────────────────────────────────────

// PostReview creates or in-place-updates the caller's review for `subject` (one per pair).
func PostReview(cur realm, subject string, rating int, body string) {
	store.PostReview(caller(), subject, rating, body, height())
}

// EditReview updates the caller's existing review. Author only.
func EditReview(cur realm, reviewID uint64, rating int, body string) {
	store.EditReview(caller(), reviewID, rating, body, height())
}

// DeleteReview tombstones the caller's review. Author only.
func DeleteReview(cur realm, reviewID uint64) {
	store.DeleteReview(caller(), reviewID)
}

// PostComment posts a flat reply to a review.
func PostComment(cur realm, reviewID uint64, body string) {
	store.PostComment(caller(), reviewID, body, height())
}

// EditComment updates the caller's comment. Author only.
func EditComment(cur realm, commentID uint64, body string) {
	store.EditComment(caller(), commentID, body, height())
}

// DeleteComment tombstones the caller's comment. Author only.
func DeleteComment(cur realm, commentID uint64) {
	store.DeleteComment(caller(), commentID)
}

// React toggles a like/dislike on a review or comment. Self-reactions rejected.
func React(cur realm, targetID uint64, kind string) {
	store.React(caller(), targetID, kind)
}

// Flag records one community flag per account per target.
func Flag(cur realm, targetID uint64) {
	store.Flag(caller(), targetID)
}

// ── Moderation (multisig only) ───────────────────────────────

// HideReview soft-deletes a review. Moderator multisig only.
func HideReview(cur realm, id uint64) {
	assertModerator()
	store.HideReview(id)
}

// HideComment soft-deletes a comment. Moderator multisig only.
func HideComment(cur realm, id uint64) {
	assertModerator()
	store.HideComment(id)
}

// Unhide reverses a hide on a review or comment. Moderator multisig only.
func Unhide(cur realm, targetID uint64) {
	assertModerator()
	store.Unhide(targetID)
}

// ── Reads (vm/qeval) ─────────────────────────────────────────

// GetReviewsJSON returns a subject's non-hidden reviews (paginated JSON array).
func GetReviewsJSON(subject string, offset, limit int) string {
	return store.GetReviewsJSON(subject, offset, limit)
}

// GetCommentsJSON returns a review's non-hidden comments (paginated JSON array).
func GetCommentsJSON(reviewID uint64, offset, limit int) string {
	return store.GetCommentsJSON(reviewID, offset, limit)
}

// GetSubjectSummaryJSON returns {"count","average","sum"} over a subject's visible reviews (O(1)).
func GetSubjectSummaryJSON(subject string) string {
	return store.SubjectSummaryJSON(subject)
}

// GetReputation returns an address's net likes−dislikes reputation (0 if unknown).
func GetReputation(addr string) int64 {
	return store.GetReputation(addr)
}

// GetFlaggedJSON returns flagged target IDs for the moderator dashboard (paginated).
func GetFlaggedJSON(offset, limit int) string {
	return store.GetFlaggedJSON(offset, limit)
}

// ── Render (gnoweb) ──────────────────────────────────────────

// Render — human gnoweb view. "" → home (total count); "s/<subject>" → subject review list.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf("# Memba App Reviews\n\nOn-chain reviews for App Store listings. %d reviews total.\n",
			store.ReviewCount())
	}
	if strings.HasPrefix(path, "s/") {
		subject := strings.TrimPrefix(path, "s/")
		return "# Reviews for " + reviews.SanitizeForRender(subject) + "\n\n" + store.RenderSubject(subject)
	}
	return "# 404\n"
}
