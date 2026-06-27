package memba_reviews_v1

// Memba Reviews / Web-of-Trust realm.
//
// OPEN, on-chain ratings + reviews for any Memba subject (validator/candidate/
// individual address, or an org/DAO realm path). Anyone with a wallet may post
// ONE editable review per subject, react (like/dislike), reply (flat, one
// level), and flag. A running net-likes reputation counter per author drives
// ranking. Moderation = author delete (tombstone) + community flag + multisig
// hide (soft-delete). Text is permanent on-chain; Hide only omits from reads.
//
// Reads: exported *JSON funcs queried via RPC vm/qeval (paginated). Render() is
// a secondary human view for gnoweb.

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
)

// ── Constants ────────────────────────────────────────────────
const (
	MaxBodyLen    = 2000 // review body
	MaxCommentLen = 1000 // comment body
	MaxPageLimit  = 100  // hard cap on any paginated read (DoS guard)

	// Memba moderator multisig (samcrew-core-test1 on testnet). CONFIRM before deploy.
	ModeratorAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"
)

// ── Types ────────────────────────────────────────────────────
type Review struct {
	ID        uint64
	Subject   string  // g1… address OR realm path
	Author    address
	Rating    int     // 1..5
	Body      string  // optional, ≤ MaxBodyLen
	CreatedAt int64   // block height
	EditedAt  int64   // block height of last edit (0 if never)
	Hidden    bool    // multisig soft-delete / auto-hide
	Deleted   bool    // author tombstone
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

// ── State ────────────────────────────────────────────────────
var (
	reviews       *avl.Tree // strID(id) -> *Review
	comments      *avl.Tree // strID(id) -> *Comment
	subjectIndex  *avl.Tree // subject -> []uint64 (review IDs, ascending) — bounds reads
	commentIndex  *avl.Tree // strID(reviewID) -> []uint64 (comment IDs, ascending)
	authorSubject *avl.Tree // subject + "\x00" + author -> uint64 (reviewID) — one-per-pair
	reactions     *avl.Tree // strID(targetID) + "/" + addr -> "like"|"dislike"
	flags         *avl.Tree // strID(targetID) + "/" + addr -> true (one flag per acct/target)
	reputation    *avl.Tree // addr -> int64 (Σ likes−dislikes on their reviews+comments)
	flaggedIDs    *avl.Tree // strID(targetID) -> true (visible targets with ≥1 flag, for the mod dashboard)
	nextID        uint64
)

func init() {
	reviews = avl.NewTree()
	comments = avl.NewTree()
	subjectIndex = avl.NewTree()
	commentIndex = avl.NewTree()
	authorSubject = avl.NewTree()
	reactions = avl.NewTree()
	flags = avl.NewTree()
	reputation = avl.NewTree()
	flaggedIDs = avl.NewTree()
	nextID = 1
}

// ── Helpers ──────────────────────────────────────────────────
func strID(id uint64) string { return strconv.FormatUint(id, 10) }

func getReview(id uint64) (*Review, bool) {
	v, ok := reviews.Get(strID(id))
	if !ok {
		return nil, false
	}
	return v.(*Review), true
}

func getComment(id uint64) (*Comment, bool) {
	v, ok := comments.Get(strID(id))
	if !ok {
		return nil, false
	}
	return v.(*Comment), true
}

func assertModerator() {
	caller := unsafe.PreviousRealm().Address()
	if caller != address(ModeratorAddress) {
		panic("unauthorized: moderator multisig only")
	}
}

func getReputation(addr string) int64 {
	if v, ok := reputation.Get(addr); ok {
		return v.(int64)
	}
	return 0
}

func addReputation(addr string, delta int64) {
	reputation.Set(addr, getReputation(addr)+delta)
}

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

// sanitizeForRender strips markdown/HTML-sensitive chars from user strings used
// inside Render() markdown (defense-in-depth; the frontend also DOMPurifies).
// "&" is escaped FIRST to prevent entity-injection (e.g. "&lt;" → "&amp;lt;").
func sanitizeForRender(s string) string {
	r := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;", ">", "&gt;",
		"[", "(", "]", ")",
		"`", "'", "|", "/",
		"\n", " ", "\r", " ",
	)
	return r.Replace(s)
}

// jsonEscape escapes a string for embedding in the realm's hand-built JSON.
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

// ── Validation helpers (pure, no side-effects) ────────────────

func validRating(r int) bool { return r >= 1 && r <= 5 }

func validBody(b string) bool { return len(b) <= MaxBodyLen }

// pairKey returns the authorSubject tree key for a (subject, author) pair.
// The NUL separator prevents prefix collisions between subject and author.
func pairKey(subject string, a address) string { return subject + "\x00" + a.String() }

// ── Write functions ───────────────────────────────────────────

// PostReview creates the caller's review for `subject`, or replaces it in place
// if one already exists (the "one editable review per pair" rule).
func PostReview(cur realm, subject string, rating int, body string) {
	caller := unsafe.PreviousRealm().Address()
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
	if v, ok := authorSubject.Get(pk); ok {
		r, found := getReview(v.(uint64))
		if found && !r.Deleted && !r.Hidden {
			r.Rating = rating
			r.Body = body
			r.EditedAt = runtime.ChainHeight()
			reviews.Set(strID(r.ID), r)
			chain.Emit("ReviewUpdated", "id", strID(r.ID), "subject", subject)
			return
		}
	}

	id := nextID
	nextID++
	r := &Review{
		ID:        id,
		Subject:   subject,
		Author:    caller,
		Rating:    rating,
		Body:      body,
		CreatedAt: runtime.ChainHeight(),
	}
	reviews.Set(strID(id), r)
	authorSubject.Set(pk, id)
	subjectIndex.Set(subject, append(idList(subjectIndex, subject), id))
	chain.Emit("ReviewPosted", "id", strID(id), "subject", subject, "author", caller.String())
}

// EditReview updates rating + body of an existing non-deleted review.
// Only the original author may edit.
func EditReview(cur realm, reviewID uint64, rating int, body string) {
	caller := unsafe.PreviousRealm().Address()
	r, ok := getReview(reviewID)
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
	r.Rating = rating
	r.Body = body
	r.EditedAt = runtime.ChainHeight()
	reviews.Set(strID(reviewID), r)
	chain.Emit("ReviewUpdated", "id", strID(reviewID), "subject", r.Subject)
}

// DeleteReview tombstones the caller's review: keeps the ID + reaction history,
// clears the body, and frees the (author, subject) pair for a fresh review.
// Only the original author may delete.
func DeleteReview(cur realm, reviewID uint64) {
	caller := unsafe.PreviousRealm().Address()
	r, ok := getReview(reviewID)
	if !ok || r.Deleted {
		panic("review not found")
	}
	if r.Author != caller {
		panic("author only")
	}
	r.Deleted = true
	r.Body = ""
	reviews.Set(strID(reviewID), r)
	authorSubject.Remove(pairKey(r.Subject, caller))
	subjectIndex.Set(r.Subject, removeID(idList(subjectIndex, r.Subject), reviewID))
	chain.Emit("ReviewDeleted", "id", strID(reviewID), "subject", r.Subject)
}

// ── Comment validation (pure, no side-effects) ────────────────

// validComment returns true iff body is non-empty and within MaxCommentLen.
func validComment(b string) bool { return b != "" && len(b) <= MaxCommentLen }

// ── Comment write functions ───────────────────────────────────

// PostComment posts a flat reply to an existing, non-deleted, non-hidden review.
func PostComment(cur realm, reviewID uint64, body string) {
	caller := unsafe.PreviousRealm().Address()
	r, ok := getReview(reviewID)
	if !ok || r.Deleted || r.Hidden {
		panic("review not found")
	}
	if !validComment(body) {
		panic("comment length invalid")
	}
	id := nextID
	nextID++
	c := &Comment{
		ID:        id,
		ReviewID:  reviewID,
		Author:    caller,
		Body:      body,
		CreatedAt: runtime.ChainHeight(),
	}
	comments.Set(strID(id), c)
	commentIndex.Set(strID(reviewID), append(idList(commentIndex, strID(reviewID)), id))
	chain.Emit("CommentPosted", "id", strID(id), "review", strID(reviewID), "author", caller.String())
}

// EditComment updates the body of an existing, non-deleted comment.
// Only the original author may edit.
func EditComment(cur realm, commentID uint64, body string) {
	caller := unsafe.PreviousRealm().Address()
	c, ok := getComment(commentID)
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
	c.EditedAt = runtime.ChainHeight()
	comments.Set(strID(commentID), c)
	chain.Emit("CommentUpdated", "id", strID(commentID))
}

// DeleteComment tombstones the caller's comment: clears the body.
// Only the original author may delete.
func DeleteComment(cur realm, commentID uint64) {
	caller := unsafe.PreviousRealm().Address()
	c, ok := getComment(commentID)
	if !ok || c.Deleted {
		panic("comment not found")
	}
	if c.Author != caller {
		panic("author only")
	}
	c.Deleted = true
	c.Body = ""
	comments.Set(strID(commentID), c)
	chain.Emit("CommentDeleted", "id", strID(commentID))
}

// ── Reaction helpers (pure, no side-effects) ──────────────────

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// reactionDelta returns how a reaction change (old -> newKind, each "" | "like" | "dislike")
// moves the target's like count, dislike count, and the target author's reputation.
// repDelta = likesDelta - dislikesDelta.
func reactionDelta(old, newKind string) (likesDelta, dislikesDelta, repDelta int) {
	likesDelta = boolToInt(newKind == "like") - boolToInt(old == "like")
	dislikesDelta = boolToInt(newKind == "dislike") - boolToInt(old == "dislike")
	repDelta = likesDelta - dislikesDelta
	return
}

// applyDelta adjusts an unsigned counter by ±1-style delta without underflow.
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

// ── React ─────────────────────────────────────────────────────

// React records or toggles a like/dislike on a review or comment.
// Re-reacting with the same kind toggles it off; switching kind replaces it.
// Updates the target's Likes/Dislikes counters and the author's reputation by
// Δ(likes−dislikes). Self-reactions are rejected. Deleted/hidden targets are rejected.
func React(cur realm, targetID uint64, kind string) {
	caller := unsafe.PreviousRealm().Address()
	if kind != "like" && kind != "dislike" {
		panic("kind must be like or dislike")
	}

	r, isReview := getReview(targetID)
	c, isComment := getComment(targetID)
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
	if v, ok := reactions.Get(rk); ok {
		old = v.(string)
	}

	newKind := kind
	if old == kind {
		newKind = "" // toggle off
	}

	likesDelta, dislikesDelta, repDelta := reactionDelta(old, newKind)

	if newKind == "" {
		reactions.Remove(rk)
	} else {
		reactions.Set(rk, newKind)
	}

	if isReview {
		r.Likes = applyDelta(r.Likes, likesDelta)
		r.Dislikes = applyDelta(r.Dislikes, dislikesDelta)
		reviews.Set(strID(targetID), r)
	} else {
		c.Likes = applyDelta(c.Likes, likesDelta)
		c.Dislikes = applyDelta(c.Dislikes, dislikesDelta)
		comments.Set(strID(targetID), c)
	}
	addReputation(author.String(), int64(repDelta))
	chain.Emit("Reacted", "target", strID(targetID), "kind", newKind, "by", caller.String())
}

// ── Flag + moderation ─────────────────────────────────────────

// Flag records one community flag per account per target (review or comment).
// Auto-hide is NOT performed here; takedowns are multisig-only (HideReview/HideComment).
// Deleted/hidden targets are rejected.
func Flag(cur realm, targetID uint64) {
	caller := unsafe.PreviousRealm().Address()
	r, isReview := getReview(targetID)
	c, isComment := getComment(targetID)
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
	if _, ok := flags.Get(fk); ok {
		panic("already flagged")
	}
	flags.Set(fk, true)

	if isReview {
		r.FlagCount++
		reviews.Set(strID(targetID), r)
	} else {
		c.FlagCount++
		comments.Set(strID(targetID), c)
	}
	flaggedIDs.Set(strID(targetID), true)
	chain.Emit("Flagged", "target", strID(targetID), "by", caller.String())
}

// HideReview soft-deletes a review. Moderator (multisig) only.
func HideReview(cur realm, id uint64) {
	assertModerator()
	r, ok := getReview(id)
	if !ok {
		panic("review not found")
	}
	r.Hidden = true
	reviews.Set(strID(id), r)
	chain.Emit("Hidden", "target", strID(id))
}

// HideComment soft-deletes a comment. Moderator (multisig) only.
func HideComment(cur realm, id uint64) {
	assertModerator()
	c, ok := getComment(id)
	if !ok {
		panic("comment not found")
	}
	c.Hidden = true
	comments.Set(strID(id), c)
	chain.Emit("Hidden", "target", strID(id))
}

// Unhide reverses a hide (manual or auto-flag) on a review or comment.
// Moderator (multisig) only. Also removes the target from the mod dashboard index.
func Unhide(cur realm, targetID uint64) {
	assertModerator()
	if r, ok := getReview(targetID); ok {
		r.Hidden = false
		reviews.Set(strID(targetID), r)
		flaggedIDs.Remove(strID(targetID))
		chain.Emit("Unhidden", "target", strID(targetID))
		return
	}
	if c, ok := getComment(targetID); ok {
		c.Hidden = false
		comments.Set(strID(targetID), c)
		flaggedIDs.Remove(strID(targetID))
		chain.Emit("Unhidden", "target", strID(targetID))
		return
	}
	panic("target not found")
}

// ── Read helpers ──────────────────────────────────────────────

// clampLimit ensures limit is in [1, MaxPageLimit]. Zero or negative values and
// values above MaxPageLimit are all clamped to MaxPageLimit.
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

func reviewJSON(r *Review) string {
	body := ""
	if !r.Deleted {
		body = jsonEscape(r.Body)
	}
	return ufmt.Sprintf(
		`{"id":%d,"subject":"%s","author":"%s","rating":%d,"body":"%s","createdAt":%d,"editedAt":%d,"deleted":%t,"likes":%d,"dislikes":%d,"flags":%d,"reputation":%d}`,
		r.ID, jsonEscape(r.Subject), jsonEscape(r.Author.String()), r.Rating, body,
		r.CreatedAt, r.EditedAt, r.Deleted, r.Likes, r.Dislikes, r.FlagCount,
		getReputation(r.Author.String()),
	)
}

func commentJSON(c *Comment) string {
	body := ""
	if !c.Deleted {
		body = jsonEscape(c.Body)
	}
	return ufmt.Sprintf(
		`{"id":%d,"reviewId":%d,"author":"%s","body":"%s","createdAt":%d,"editedAt":%d,"deleted":%t,"likes":%d,"dislikes":%d,"flags":%d,"reputation":%d}`,
		c.ID, c.ReviewID, jsonEscape(c.Author.String()), body,
		c.CreatedAt, c.EditedAt, c.Deleted, c.Likes, c.Dislikes, c.FlagCount,
		getReputation(c.Author.String()),
	)
}

// GetReviewsJSON returns a JSON array of a subject's non-hidden reviews (paginated).
// Deleted reviews are included as tombstones (empty body, deleted:true).
func GetReviewsJSON(subject string, offset, limit int) string {
	ids := window(idList(subjectIndex, subject), offset, limit)
	var b strings.Builder
	b.WriteString("[")
	first := true
	for _, id := range ids {
		r, ok := getReview(id)
		if !ok || r.Hidden {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		b.WriteString(reviewJSON(r))
		first = false
	}
	b.WriteString("]")
	return b.String()
}

// GetCommentsJSON returns a JSON array of a review's non-hidden comments (paginated).
func GetCommentsJSON(reviewID uint64, offset, limit int) string {
	ids := window(idList(commentIndex, strID(reviewID)), offset, limit)
	var b strings.Builder
	b.WriteString("[")
	first := true
	for _, id := range ids {
		c, ok := getComment(id)
		if !ok || c.Hidden {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		b.WriteString(commentJSON(c))
		first = false
	}
	b.WriteString("]")
	return b.String()
}

// GetSubjectSummaryJSON returns {"count":N,"average":A,"sum":S} over non-hidden,
// non-deleted reviews for a subject. Average is integer-rounded.
func GetSubjectSummaryJSON(subject string) string {
	ids := idList(subjectIndex, subject)
	var sum, n int64
	for _, id := range ids {
		r, ok := getReview(id)
		if !ok || r.Hidden || r.Deleted {
			continue
		}
		sum += int64(r.Rating)
		n++
	}
	avg := int64(0)
	if n > 0 {
		avg = (sum + n/2) / n // round to nearest
	}
	return ufmt.Sprintf(`{"count":%d,"average":%d,"sum":%d}`, n, avg, sum)
}

// GetReputation returns the net likes−dislikes reputation for an address.
// Returns 0 for unknown addresses. Queried via vm/qeval (bare int64).
func GetReputation(addr string) int64 { return getReputation(addr) }

// GetFlaggedJSON returns a JSON array of flagged target IDs for the mod dashboard,
// paginated. IDs are returned as bare integers (not quoted strings).
// Uses early-stop iteration to avoid loading the entire tree.
func GetFlaggedJSON(offset, limit int) string {
	limit = clampLimit(limit)
	if offset < 0 {
		offset = 0
	}
	var ids []uint64
	skipped := 0
	flaggedIDs.Iterate("", "", func(key string, _ interface{}) bool {
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

// Render — human gnoweb view.
// "" → home (total count); "s/<subject>" → subject review list; else 404.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf("# Memba Reviews\n\nOn-chain web-of-trust. %d reviews total.\n", reviews.Size())
	}
	if strings.HasPrefix(path, "s/") {
		subject := strings.TrimPrefix(path, "s/")
		var b strings.Builder
		b.WriteString("# Reviews for " + sanitizeForRender(subject) + "\n\n")
		written := false
		renderedCount := 0
		for _, id := range idList(subjectIndex, subject) {
			if renderedCount >= MaxPageLimit {
				break
			}
			r, ok := getReview(id)
			if !ok || r.Hidden || r.Deleted {
				continue
			}
			b.WriteString(ufmt.Sprintf("**%d/5** by %s\n\n%s\n\n---\n",
				r.Rating, r.Author.String(), sanitizeForRender(r.Body)))
			written = true
			renderedCount++
		}
		if !written {
			b.WriteString("No reviews yet.\n")
		}
		return b.String()
	}
	return "# 404\n"
}
