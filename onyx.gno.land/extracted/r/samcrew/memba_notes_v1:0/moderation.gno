package memba_notes_v1

import keys "gno.land/r/samcrew/enckeys_v1"

const MaxModerators = 32

var moderators []address

func moderator(who address) bool { return who == admin || contains(moderators, who) }
func AddModerator(cur realm, to address) {
	who := enter(cur, false)
	defer leave()
	administrator(who)
	to = keys.CanonicalAddress(to)
	if contains(moderators, to) {
		panic("notes: moderator exists")
	}
	if len(moderators) >= MaxModerators {
		panic("notes: moderator cap")
	}
	moderators = append(moderators, to)
}
func RemoveModerator(cur realm, to address) {
	who := enter(cur, false)
	defer leave()
	administrator(who)
	to = keys.CanonicalAddress(to)
	for i, a := range moderators {
		if a == to {
			moderators = append(moderators[:i], moderators[i+1:]...)
			return
		}
	}
	panic("notes: moderator missing")
}
func ModeratorsJSON() string {
	out := "["
	for i, a := range moderators {
		if i > 0 {
			out += ","
		}
		out += q(string(a))
	}
	return out + "]"
}

// Directory moderation is separate from owner discoverability. Owners cannot
// undo a moderation hide by toggling their own listing preference.
func ModerateListing(cur realm, id [16]byte, baseRevision uint64, visible bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateModerateListing(cur, who, id, baseRevision, visible, opID)
}
func mutateModerateListing(cur realm, who address, id [16]byte, baseRevision uint64, visible bool, opID [16]byte) {
	n := live(id)
	if !moderator(who) {
		panic("notes: moderator required")
	}
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: public note required")
	}
	operation(n, opID)
	unindex(n)
	n.ModeratorHidden = !visible
	index(n)
	bump(n, who, opID, "moderate-listing")
}

// RedactedTitle replaces a redacted current title, which must stay valid.
const RedactedTitle = "Redacted by moderation"

// RedactPublicContent removes one public title (field 1) or body (field 2)
// version from realm storage. Public history keeps the version's SHA-256 and a
// content-redact entry naming the moderator. Redacting the current version also
// replaces it (placeholder title, empty body) under a new field revision. Gno
// refunds the freed storage to the moderator who frees it.
func RedactPublicContent(cur realm, id [16]byte, baseRevision uint64, field uint8, fieldRevision uint64, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateRedactPublicContent(cur, who, id, baseRevision, field, fieldRevision, opID)
}
func mutateRedactPublicContent(cur realm, who address, id [16]byte, baseRevision uint64, field uint8, fieldRevision uint64, opID [16]byte) {
	n := find(id)
	if !moderator(who) {
		panic("notes: moderator required")
	}
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: public note required")
	}
	name := ""
	switch field {
	case 1:
		name = "title"
	case 2:
		name = "body"
	default:
		panic("notes: bad redaction field")
	}
	v, ok := historyBlobs.Get(name + ":" + historyKey(n.ID, fieldRevision))
	if !ok {
		panic("notes: history version missing")
	}
	b := v.(*historyBlob)
	if b.Redacted {
		panic("notes: already redacted")
	}
	operation(n, opID)
	if !n.Deleted && field == 1 && fieldRevision == n.TitleRevision {
		if n.TitleRevision == ^uint64(0) {
			panic("notes: title revision exhausted")
		}
		n.Title = []byte(RedactedTitle)
		n.TitleRevision++
	}
	if !n.Deleted && field == 2 && fieldRevision == n.BodyRevision {
		if n.BodyRevision == ^uint64(0) {
			panic("notes: body revision exhausted")
		}
		n.Body = []byte{}
		n.BodyBytes = 0
		n.BodyRevision++
	}
	b.Bytes, b.Redacted = nil, true
	bumpHistory(n, who, opID, "content-redact", `,"field":`+q(name)+`,"field_revision":`+u(fieldRevision)+`,"sha256":`+q(b.Hash))
}

// RedactPublicComment removes a public comment's anchor and body from both the
// live comment (which becomes hidden and cannot be shown again) and its public
// history. A purged comment keeps only its history record, which is redacted
// the same way; baseRevision is then ignored (pass 0).
func RedactPublicComment(cur realm, id, cid [16]byte, baseRevision uint64, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateRedactPublicComment(cur, who, id, cid, baseRevision, opID)
}
func mutateRedactPublicComment(cur realm, who address, id, cid [16]byte, baseRevision uint64, opID [16]byte) {
	n := find(id)
	if !moderator(who) {
		panic("notes: moderator required")
	}
	if !public(n.Mode) {
		panic("notes: public note required")
	}
	key := commentKey(id, cid)
	v, ok := historyComments.Get(key)
	if !ok {
		panic("notes: missing public comment history")
	}
	archived := v.(*historyComment)
	if archived.Redacted {
		panic("notes: already redacted")
	}
	cv, live := comments.Get(key)
	if !live {
		if opID == ([16]byte{}) {
			panic("notes: empty operation id")
		}
		archived.Initial.Anchor, archived.Initial.Body, archived.Redacted = nil, nil, true
		e := historyAppend(n, who, opID, cid, "comment-redact", `{"comment_id":`+q(idText(cid))+`,"purged":true}`)
		archived.LatestSeq = e.Seq
		return
	}
	c := cv.(*comment)
	commentExpected(c, baseRevision, opID)
	archived.Initial.Anchor, archived.Initial.Body, archived.Redacted = nil, nil, true
	c.Anchor, c.Body, c.Hidden = nil, nil, true
	commentReceipt(c, who, opID)
	historyCommentChange(n, c, "comment-redact")
}
