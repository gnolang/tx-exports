// Fixed reviews target chosen once during generation. Never imports both versions.
package memba_dao
import (
    "gno.land/p/samcrew/memba_weighted_host"
    "gno.land/r/samcrew/memba_reviews_v2"
)
func reviewsState(a memba_weighted_host.ReviewsAction) memba_weighted_host.ReviewsState {
    s := memba_weighted_host.ReviewsState{Moderator:address(memba_reviews_v2.GetModerator()),PendingModerator:address(memba_reviews_v2.GetPendingModerator())}
    if a.ID() != 0 {
        i := memba_reviews_v2.GetModerationState(a.ID())
        s.Item = memba_weighted_host.ReviewsItem{ID:i.ID, Review:i.Review, ParentID:i.ParentID, Subject:i.Subject, Author:i.Author, Rating:i.Rating, BodyHash:i.BodyHash, CreatedAt:i.CreatedAt, EditedAt:i.EditedAt, Hidden:i.Hidden, Deleted:i.Deleted, Flagged:i.Flagged}
    }
    return s
}
func ProposeReviewsAccept(cur realm) uint64 { a := reviewsPolicy.Accept(); return host.ProposeReviews(a,reviewsState(a),cur) }
func ProposeReviewsReturn(cur realm) uint64 { a := reviewsPolicy.Return(); return host.ProposeReviews(a,reviewsState(a),cur) }
func ProposeReviewsAbortReturn(cur realm) uint64 { a := reviewsPolicy.AbortReturn(); return host.ProposeReviews(a,reviewsState(a),cur) }
func ProposeReviewsHideReview(cur realm, id uint64) uint64 { a := reviewsPolicy.HideReview(id); return host.ProposeReviews(a,reviewsState(a),cur) }
func ProposeReviewsHideComment(cur realm, id uint64) uint64 { a := reviewsPolicy.HideComment(id); return host.ProposeReviews(a,reviewsState(a),cur) }
func ProposeReviewsUnhide(cur realm, id uint64) uint64 { a := reviewsPolicy.Unhide(id); return host.ProposeReviews(a,reviewsState(a),cur) }
func executeReviews(cur realm, id uint64) {
    proposed := host.Proposal(id).ReviewsAction
    before := reviewsState(proposed)
    a := host.ConsumeReviews(id,before,cur)
    expected := before
    switch a.Kind() {
    case memba_weighted_host.ReviewsAcceptModerator:
        expected.Moderator = reviewsPolicy.DAO(); expected.PendingModerator = ""
        memba_reviews_v2.AcceptOwnership(cross(cur))
    case memba_weighted_host.ReviewsReturnModerator:
        expected.PendingModerator = a.Recipient()
        memba_reviews_v2.TransferOwnership(cross(cur),a.Recipient())
    case memba_weighted_host.ReviewsAbortReturn:
        expected.PendingModerator = ""
        memba_reviews_v2.CancelOwnershipTransfer(cross(cur))
    case memba_weighted_host.ReviewsHideReview:
        expected.Item.Hidden = true
        memba_reviews_v2.HideReview(cross(cur),a.ID())
    case memba_weighted_host.ReviewsHideComment:
        expected.Item.Hidden = true
        memba_reviews_v2.HideComment(cross(cur),a.ID())
    case memba_weighted_host.ReviewsUnhide:
        expected.Item.Hidden = false; expected.Item.Flagged = false
        memba_reviews_v2.Unhide(cross(cur),a.ID())
    default: panic("unsupported reviews action")
    }
    if reviewsState(a) != expected { panic("reviews postcondition mismatch") }
}
