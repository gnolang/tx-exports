package memba_reviews_v2

import (
	"crypto/sha256"
	"encoding/hex"
)

// ModerationState is a bounded copied snapshot, including hidden/deleted items.
// No pointer or body is exposed. BodyHash binds edits even within the same block.
// Reactions and cumulative flag counts are not moderation authorization inputs.
type ModerationState struct {
	ID        uint64
	Review    bool
	ParentID  uint64
	Subject   string
	Author    address
	Rating    int
	BodyHash  string
	CreatedAt int64
	EditedAt  int64
	Hidden    bool
	Deleted   bool
	Flagged   bool
}

func moderationBodyHash(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// GetModerationState returns a zero value for an absent ID. The flagged-index
// bit is distinct from historical flags; Unhide removes only the index entry.
func GetModerationState(id uint64) ModerationState {
	_, flagged := flaggedIDs.Get(strID(id))
	if r, ok := getReview(id); ok {
		return ModerationState{ID: r.ID, Review: true, Subject: r.Subject, Author: r.Author,
			Rating: r.Rating, BodyHash: moderationBodyHash(r.Body), CreatedAt: r.CreatedAt,
			EditedAt: r.EditedAt, Hidden: r.Hidden, Deleted: r.Deleted, Flagged: flagged}
	}
	if c, ok := getComment(id); ok {
		return ModerationState{ID: c.ID, ParentID: c.ReviewID, Author: c.Author,
			BodyHash: moderationBodyHash(c.Body), CreatedAt: c.CreatedAt, EditedAt: c.EditedAt,
			Hidden: c.Hidden, Deleted: c.Deleted, Flagged: flagged}
	}
	return ModerationState{}
}
