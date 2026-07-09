// Package reviews is the shared engine behind Memba's on-chain reviews / web-of-trust.
//
// It holds NO global state: a realm owns a *Store (avl-backed) and calls its methods.
// This is the reusable core extracted from memba_reviews_v2 (DoS-hardened: RV-1 O(1)
// per-subject summary counters, RV-3 flaggedIDs GC), so the app-reviews realm and any
// future memba_reviews_v3 share one audited implementation instead of forked copies.
//
// SPLIT OF CONCERNS: the Store is pure storage + validation + event emission. It takes the
// caller address and block height as explicit arguments — the consuming realm reads those
// from unsafe.PreviousRealm()/runtime.ChainHeight(), performs the moderator-multisig gate on
// Hide*/Unhide, and passes them in. That keeps the Store unit-testable without a realm frame.
package memba_reviews_core_v1

import (
	"strconv"
	"strings"

	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ── Constants ────────────────────────────────────────────────
const (
	MaxBodyLen    = 2000 // review body
	MaxCommentLen = 1000 // comment body
	MaxPageLimit  = 100  // hard cap on any paginated read (DoS guard)
)

// ── Types ────────────────────────────────────────────────────
type Review struct {
	ID        uint64
	Subject   string // g1… address OR realm path
	Author    address
	Rating    int    // 1..5
	Body      string // optional, ≤ MaxBodyLen
	CreatedAt int64  // block height
	EditedAt  int64  // block height of last edit (0 if never)
	Hidden    bool   // multisig soft-delete / auto-hide
	Deleted   bool   // author tombstone
	Likes     uint64
	Dislikes  uint64
	FlagCount uint64
}

type Comment struct {
	ID        uint64
	ReviewID  uint64
	Author    address
	Body      string // ≤ MaxCommentLen
	CreatedAt int64
	EditedAt  int64
	Hidden    bool
	Deleted   bool
	Likes     uint64
	Dislikes  uint64
	FlagCount uint64
}

// Store owns all review state for one consuming realm.
type Store struct {
	reviews       *avl.Tree // strID(id) -> *Review
	comments      *avl.Tree // strID(id) -> *Comment
	subjectIndex  *avl.Tree // subject -> []uint64 (review IDs, ascending)
	commentIndex  *avl.Tree // strID(reviewID) -> []uint64 (comment IDs, ascending)
	authorSubject *avl.Tree // subject + "\x00" + author -> uint64 (reviewID) — one-per-pair
	reactions     *avl.Tree // strID(targetID) + "/" + addr -> "like"|"dislike"
	flags         *avl.Tree // strID(targetID) + "/" + addr -> true
	reputation    *avl.Tree // addr -> int64 (Σ likes−dislikes on their reviews+comments)
	flaggedIDs    *avl.Tree // strID(targetID) -> true (visible targets with ≥1 flag)
	subjStatCount *avl.Tree // subject -> int64 (# visible reviews) — RV-1 O(1) summary
	subjStatSum   *avl.Tree // subject -> int64 (Σ rating over visible reviews)
	nextID        uint64
}

// NewStore returns an empty review store ready for a realm to embed.
func NewStore() *Store {
	return &Store{
		reviews:       avl.NewTree(),
		comments:      avl.NewTree(),
		subjectIndex:  avl.NewTree(),
		commentIndex:  avl.NewTree(),
		authorSubject: avl.NewTree(),
		reactions:     avl.NewTree(),
		flags:         avl.NewTree(),
		reputation:    avl.NewTree(),
		flaggedIDs:    avl.NewTree(),
		subjStatCount: avl.NewTree(),
		subjStatSum:   avl.NewTree(),
		nextID:        1,
	}
}

// ── Pure helpers (no state) ──────────────────────────────────
func strID(id uint64) string { return strconv.FormatUint(id, 10) }

func validRating(r int) bool { return r >= 1 && r <= 5 }

func validBody(b string) bool { return len(b) <= MaxBodyLen }

func validComment(b string) bool { return b != "" && len(b) <= MaxCommentLen }

// pairKey returns the authorSubject tree key for a (subject, author) pair.
// The NUL separator prevents prefix collisions between subject and author.
func pairKey(subject string, a address) string { return subject + "\x00" + a.String() }

func idList(t *avl.Tree, key string) []uint64 {
	if v, ok := t.Get(key); ok {
		return v.([]uint64)
	}
	return nil
}

// removeID returns ids with the first occurrence of target removed.
func removeID(ids []uint64, target uint64) []uint64 {
	out := make([]uint64, 0, len(ids))
	removed := false
	for _, id := range ids {
		if !removed && id == target {
			removed = true
			continue
		}
		out = append(out, id)
	}
	return out
}

func getStat(t *avl.Tree, subject string) int64 {
	if v, ok := t.Get(subject); ok {
		return v.(int64)
	}
	return 0
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// reactionDelta returns how a reaction change (old -> newKind, each "" | "like" | "dislike")
// moves the target's like count, dislike count, and the target author's reputation.
func reactionDelta(old, newKind string) (likesDelta, dislikesDelta, repDelta int) {
	likesDelta = boolToInt(newKind == "like") - boolToInt(old == "like")
	dislikesDelta = boolToInt(newKind == "dislike") - boolToInt(old == "dislike")
	repDelta = likesDelta - dislikesDelta
	return
}

// applyDelta adjusts an unsigned counter by ±delta without underflow.
func applyDelta(v uint64, delta int) uint64 {
	if delta < 0 {
		d := uint64(-delta)
		if v < d {
			return 0
		}
		return v - d
	}
	return v + uint64(delta)
}

// clampLimit ensures limit is in [1, MaxPageLimit].
func clampLimit(limit int) int {
	if limit <= 0 || limit > MaxPageLimit {
		return MaxPageLimit
	}
	return limit
}

// window slices ids[offset : offset+limit] safely (no panics on out-of-range).
func window(ids []uint64, offset, limit int) []uint64 {
	limit = clampLimit(limit)
	if offset < 0 {
		offset = 0
	}
	if offset >= len(ids) {
		return nil
	}
	end := offset + limit
	if end > len(ids) {
		end = len(ids)
	}
	return ids[offset:end]
}

// SanitizeForRender strips markdown/HTML-sensitive chars from user strings used inside a
// realm's Render() markdown (defense-in-depth; the frontend also DOMPurifies). "&" first.
func SanitizeForRender(s string) string {
	r := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;", ">", "&gt;",
		"[", "(", "]", ")",
		"`", "'", "|", "/",
		"\n", " ", "\r", " ",
	)
	return r.Replace(s)
}

// jsonEscape escapes a string for embedding in hand-built JSON.
func jsonEscape(s string) string {
	var b strings.Builder
	for _, c := range s {
		switch c {
		case '"':
			b.WriteString("\\\"")
		case '\\':
			b.WriteString("\\\\")
		case '\n':
			b.WriteString("\\n")
		case '\r':
			b.WriteString("\\r")
		case '\t':
			b.WriteString("\\t")
		default:
			if c < 0x20 {
				const hexDigits = "0123456789abcdef"
				b.WriteString("\\u00")
				b.WriteByte(hexDigits[int((c>>4)&0xf)])
				b.WriteByte(hexDigits[int(c&0xf)])
			} else {
				b.WriteRune(c)
			}
		}
	}
	return b.String()
}

// ── Store state helpers ──────────────────────────────────────
func (s *Store) getReview(id uint64) (*Review, bool) {
	v, ok := s.reviews.Get(strID(id))
	if !ok {
		return nil, false
	}
	return v.(*Review), true
}

func (s *Store) getComment(id uint64) (*Comment, bool) {
	v, ok := s.comments.Get(strID(id))
	if !ok {
		return nil, false
	}
	return v.(*Comment), true
}

func (s *Store) getReputation(addr string) int64 { return getStat(s.reputation, addr) }

func (s *Store) addReputation(addr string, delta int64) {
	s.reputation.Set(addr, s.getReputation(addr)+delta)
}

// applySubjectStat adjusts the visible-review counters (RV-1) for a subject.
func (s *Store) applySubjectStat(subject string, dCount, dSum int64) {
	if dCount != 0 {
		s.subjStatCount.Set(subject, getStat(s.subjStatCount, subject)+dCount)
	}
	if dSum != 0 {
		s.subjStatSum.Set(subject, getStat(s.subjStatSum, subject)+dSum)
	}
}

// ── Review writes ────────────────────────────────────────────

// PostReview creates the caller's review for `subject`, or replaces it in place if one already
// exists (the "one editable review per pair" rule). Returns the review id.
func (s *Store) PostReview(caller address, subject string, rating int, body string, height int64) uint64 {
	if subject == "" {
		panic("subject required")
	}
	if !validRating(rating) {
		panic("rating must be 1..5")
	}
	if !validBody(body) {
		panic("body too long")
	}

	pk := pairKey(subject, caller)
	if v, ok := s.authorSubject.Get(pk); ok {
		r, found := s.getReview(v.(uint64))
		if found && !r.Deleted && !r.Hidden {
			// counted review already exists for this (subject, author): rating change only.
			s.applySubjectStat(subject, 0, int64(rating)-int64(r.Rating))
			r.Rating = rating
			r.Body = body
			r.EditedAt = height
			s.reviews.Set(strID(r.ID), r)
			chain.Emit("ReviewUpdated", "id", strID(r.ID), "subject", subject)
			return r.ID
		}
	}

	id := s.nextID
	s.nextID++
	r := &Review{
		ID:        id,
		Subject:   subject,
		Author:    caller,
		Rating:    rating,
		Body:      body,
		CreatedAt: height,
	}
	s.reviews.Set(strID(id), r)
	s.authorSubject.Set(pk, id)
	s.subjectIndex.Set(subject, append(idList(s.subjectIndex, subject), id))
	s.applySubjectStat(subject, 1, int64(rating)) // new visible review
	chain.Emit("ReviewPosted", "id", strID(id), "subject", subject, "author", caller.String())
	return id
}

// EditReview updates rating + body of an existing non-deleted review. Author only.
func (s *Store) EditReview(caller address, reviewID uint64, rating int, body string, height int64) {
	r, ok := s.getReview(reviewID)
	if !ok || r.Deleted {
		panic("review not found")
	}
	if r.Author != caller {
		panic("author only")
	}
	if !validRating(rating) {
		panic("rating must be 1..5")
	}
	if !validBody(body) {
		panic("body too long")
	}
	if !r.Hidden { // counted (r.Deleted is false per guard): apply the rating delta
		s.applySubjectStat(r.Subject, 0, int64(rating)-int64(r.Rating))
	}
	r.Rating = rating
	r.Body = body
	r.EditedAt = height
	s.reviews.Set(strID(reviewID), r)
	chain.Emit("ReviewUpdated", "id", strID(reviewID), "subject", r.Subject)
}

// DeleteReview tombstones the caller's review: keeps the ID + reaction history, clears the
// body, and frees the (author, subject) pair. Author only.
func (s *Store) DeleteReview(caller address, reviewID uint64) {
	r, ok := s.getReview(reviewID)
	if !ok || r.Deleted {
		panic("review not found")
	}
	if r.Author != caller {
		panic("author only")
	}
	if !r.Hidden { // was counted (r.Deleted false per guard): drop from subject stats
		s.applySubjectStat(r.Subject, -1, -int64(r.Rating))
	}
	r.Deleted = true
	r.Body = ""
	s.reviews.Set(strID(reviewID), r)
	s.authorSubject.Remove(pairKey(r.Subject, caller))
	s.subjectIndex.Set(r.Subject, removeID(idList(s.subjectIndex, r.Subject), reviewID))
	s.flaggedIDs.Remove(strID(reviewID)) // RV-3: don't leave a tombstoned review in the dashboard
	chain.Emit("ReviewDeleted", "id", strID(reviewID), "subject", r.Subject)
}

// ── Comment writes ───────────────────────────────────────────

// PostComment posts a flat reply to an existing, non-deleted, non-hidden review. Returns id.
func (s *Store) PostComment(caller address, reviewID uint64, body string, height int64) uint64 {
	r, ok := s.getReview(reviewID)
	if !ok || r.Deleted || r.Hidden {
		panic("review not found")
	}
	if !validComment(body) {
		panic("comment length invalid")
	}
	id := s.nextID
	s.nextID++
	c := &Comment{
		ID:        id,
		ReviewID:  reviewID,
		Author:    caller,
		Body:      body,
		CreatedAt: height,
	}
	s.comments.Set(strID(id), c)
	s.commentIndex.Set(strID(reviewID), append(idList(s.commentIndex, strID(reviewID)), id))
	chain.Emit("CommentPosted", "id", strID(id), "review", strID(reviewID), "author", caller.String())
	return id
}

// EditComment updates the body of an existing, non-deleted comment. Author only.
func (s *Store) EditComment(caller address, commentID uint64, body string, height int64) {
	c, ok := s.getComment(commentID)
	if !ok || c.Deleted {
		panic("comment not found")
	}
	if c.Author != caller {
		panic("author only")
	}
	if !validComment(body) {
		panic("comment length invalid")
	}
	c.Body = body
	c.EditedAt = height
	s.comments.Set(strID(commentID), c)
	chain.Emit("CommentUpdated", "id", strID(commentID))
}

// DeleteComment tombstones the caller's comment. Author only.
func (s *Store) DeleteComment(caller address, commentID uint64) {
	c, ok := s.getComment(commentID)
	if !ok || c.Deleted {
		panic("comment not found")
	}
	if c.Author != caller {
		panic("author only")
	}
	c.Deleted = true
	c.Body = ""
	s.comments.Set(strID(commentID), c)
	s.flaggedIDs.Remove(strID(commentID)) // RV-3
	chain.Emit("CommentDeleted", "id", strID(commentID))
}

// ── React ────────────────────────────────────────────────────

// React records or toggles a like/dislike on a review or comment. Re-reacting with the same
// kind toggles it off; switching kind replaces it. Self-reactions and deleted/hidden targets
// are rejected.
func (s *Store) React(caller address, targetID uint64, kind string) {
	if kind != "like" && kind != "dislike" {
		panic("kind must be like or dislike")
	}

	r, isReview := s.getReview(targetID)
	c, isComment := s.getComment(targetID)
	if !isReview && !isComment {
		panic("target not found")
	}

	var author address
	if isReview {
		author = r.Author
		if r.Deleted || r.Hidden {
			panic("target not found")
		}
	} else {
		author = c.Author
		if c.Deleted || c.Hidden {
			panic("target not found")
		}
	}
	if author == caller {
		panic("cannot react to your own review or comment")
	}

	rk := strID(targetID) + "/" + caller.String()
	var old string
	if v, ok := s.reactions.Get(rk); ok {
		old = v.(string)
	}

	newKind := kind
	if old == kind {
		newKind = "" // toggle off
	}

	likesDelta, dislikesDelta, repDelta := reactionDelta(old, newKind)

	if newKind == "" {
		s.reactions.Remove(rk)
	} else {
		s.reactions.Set(rk, newKind)
	}

	if isReview {
		r.Likes = applyDelta(r.Likes, likesDelta)
		r.Dislikes = applyDelta(r.Dislikes, dislikesDelta)
		s.reviews.Set(strID(targetID), r)
	} else {
		c.Likes = applyDelta(c.Likes, likesDelta)
		c.Dislikes = applyDelta(c.Dislikes, dislikesDelta)
		s.comments.Set(strID(targetID), c)
	}
	s.addReputation(author.String(), int64(repDelta))
	chain.Emit("Reacted", "target", strID(targetID), "kind", newKind, "by", caller.String())
}

// ── Flag + moderation ────────────────────────────────────────

// Flag records one community flag per account per target. Takedowns are moderator-only
// (HideReview/HideComment, gated by the realm). Deleted/hidden targets are rejected.
func (s *Store) Flag(caller address, targetID uint64) {
	r, isReview := s.getReview(targetID)
	c, isComment := s.getComment(targetID)
	if !isReview && !isComment {
		panic("target not found")
	}
	if isReview && (r.Deleted || r.Hidden) {
		panic("target not found")
	}
	if isComment && (c.Deleted || c.Hidden) {
		panic("target not found")
	}
	fk := strID(targetID) + "/" + caller.String()
	if _, ok := s.flags.Get(fk); ok {
		panic("already flagged")
	}
	s.flags.Set(fk, true)

	if isReview {
		r.FlagCount++
		s.reviews.Set(strID(targetID), r)
	} else {
		c.FlagCount++
		s.comments.Set(strID(targetID), c)
	}
	s.flaggedIDs.Set(strID(targetID), true)
	chain.Emit("Flagged", "target", strID(targetID), "by", caller.String())
}

// HideReview soft-deletes a review. The realm gates this to the moderator multisig.
func (s *Store) HideReview(id uint64) {
	r, ok := s.getReview(id)
	if !ok {
		panic("review not found")
	}
	if !r.Hidden && !r.Deleted { // was counted → drop from subject stats
		s.applySubjectStat(r.Subject, -1, -int64(r.Rating))
	}
	r.Hidden = true
	s.reviews.Set(strID(id), r)
	chain.Emit("Hidden", "target", strID(id))
}

// HideComment soft-deletes a comment. The realm gates this to the moderator multisig.
func (s *Store) HideComment(id uint64) {
	c, ok := s.getComment(id)
	if !ok {
		panic("comment not found")
	}
	c.Hidden = true
	s.comments.Set(strID(id), c)
	chain.Emit("Hidden", "target", strID(id))
}

// Unhide reverses a hide on a review or comment. The realm gates this to the moderator multisig.
func (s *Store) Unhide(targetID uint64) {
	if r, ok := s.getReview(targetID); ok {
		if r.Hidden && !r.Deleted { // becomes counted again → restore to subject stats
			s.applySubjectStat(r.Subject, 1, int64(r.Rating))
		}
		r.Hidden = false
		s.reviews.Set(strID(targetID), r)
		s.flaggedIDs.Remove(strID(targetID))
		chain.Emit("Unhidden", "target", strID(targetID))
		return
	}
	if c, ok := s.getComment(targetID); ok {
		c.Hidden = false
		s.comments.Set(strID(targetID), c)
		s.flaggedIDs.Remove(strID(targetID))
		chain.Emit("Unhidden", "target", strID(targetID))
		return
	}
	panic("target not found")
}

// ── Reads ────────────────────────────────────────────────────

func (s *Store) reviewJSON(r *Review) string {
	body := ""
	if !r.Deleted {
		body = jsonEscape(r.Body)
	}
	return ufmt.Sprintf(
		`{"id":%d,"subject":"%s","author":"%s","rating":%d,"body":"%s","createdAt":%d,"editedAt":%d,"deleted":%t,"likes":%d,"dislikes":%d,"flags":%d,"reputation":%d}`,
		r.ID, jsonEscape(r.Subject), jsonEscape(r.Author.String()), r.Rating, body,
		r.CreatedAt, r.EditedAt, r.Deleted, r.Likes, r.Dislikes, r.FlagCount,
		s.getReputation(r.Author.String()),
	)
}

func (s *Store) commentJSON(c *Comment) string {
	body := ""
	if !c.Deleted {
		body = jsonEscape(c.Body)
	}
	return ufmt.Sprintf(
		`{"id":%d,"reviewId":%d,"author":"%s","body":"%s","createdAt":%d,"editedAt":%d,"deleted":%t,"likes":%d,"dislikes":%d,"flags":%d,"reputation":%d}`,
		c.ID, c.ReviewID, jsonEscape(c.Author.String()), body,
		c.CreatedAt, c.EditedAt, c.Deleted, c.Likes, c.Dislikes, c.FlagCount,
		s.getReputation(c.Author.String()),
	)
}

// GetReviewsJSON returns a JSON array of a subject's non-hidden reviews (paginated).
// Deleted reviews were removed from the subject index by DeleteReview, so they do NOT appear
// here; hidden reviews are excluded at read time. (reviewJSON still tombstones a deleted review
// defensively for any caller that fetches one by id.)
func (s *Store) GetReviewsJSON(subject string, offset, limit int) string {
	ids := window(idList(s.subjectIndex, subject), offset, limit)
	var b strings.Builder
	b.WriteString("[")
	first := true
	for _, id := range ids {
		r, ok := s.getReview(id)
		if !ok || r.Hidden {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		b.WriteString(s.reviewJSON(r))
		first = false
	}
	b.WriteString("]")
	return b.String()
}

// GetCommentsJSON returns a JSON array of a review's non-hidden comments (paginated).
func (s *Store) GetCommentsJSON(reviewID uint64, offset, limit int) string {
	ids := window(idList(s.commentIndex, strID(reviewID)), offset, limit)
	var b strings.Builder
	b.WriteString("[")
	first := true
	for _, id := range ids {
		c, ok := s.getComment(id)
		if !ok || c.Hidden {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		b.WriteString(s.commentJSON(c))
		first = false
	}
	b.WriteString("]")
	return b.String()
}

// SubjectSummaryJSON returns {"count":N,"average":A,"sum":S} over VISIBLE reviews (RV-1: O(1)).
func (s *Store) SubjectSummaryJSON(subject string) string {
	n := getStat(s.subjStatCount, subject)
	sum := getStat(s.subjStatSum, subject)
	avg := int64(0)
	if n > 0 {
		avg = (sum + n/2) / n // round to nearest
	}
	return ufmt.Sprintf(`{"count":%d,"average":%d,"sum":%d}`, n, avg, sum)
}

// GetReputation returns the net likes−dislikes reputation for an address (0 if unknown).
func (s *Store) GetReputation(addr string) int64 { return s.getReputation(addr) }

// GetFlaggedJSON returns a paginated JSON array of flagged target IDs for the mod dashboard.
func (s *Store) GetFlaggedJSON(offset, limit int) string {
	limit = clampLimit(limit)
	if offset < 0 {
		offset = 0
	}
	var ids []uint64
	skipped := 0
	s.flaggedIDs.Iterate("", "", func(key string, _ interface{}) bool {
		if skipped < offset {
			skipped++
			return false
		}
		id, _ := strconv.ParseUint(key, 10, 64)
		ids = append(ids, id)
		return len(ids) >= limit // stop once collected enough
	})
	var b strings.Builder
	b.WriteString("[")
	for i, id := range ids {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(strID(id))
	}
	b.WriteString("]")
	return b.String()
}

// ReviewCount returns the total number of reviews ever created (any state).
func (s *Store) ReviewCount() int { return s.reviews.Size() }

// RenderSubject returns a markdown list of a subject's visible reviews (bounded), for a
// realm's Render() gnoweb view.
func (s *Store) RenderSubject(subject string) string {
	var b strings.Builder
	written := false
	renderedCount := 0
	for _, id := range idList(s.subjectIndex, subject) {
		if renderedCount >= MaxPageLimit {
			break
		}
		r, ok := s.getReview(id)
		if !ok || r.Hidden || r.Deleted {
			continue
		}
		b.WriteString(ufmt.Sprintf("**%d/5** by %s\n\n%s\n\n---\n",
			r.Rating, r.Author.String(), SanitizeForRender(r.Body)))
		written = true
		renderedCount++
	}
	if !written {
		return "No reviews yet.\n"
	}
	return b.String()
}
