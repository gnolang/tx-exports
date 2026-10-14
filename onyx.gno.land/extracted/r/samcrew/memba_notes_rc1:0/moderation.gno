package memba_notes_rc1

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

// RedactPublicContentAtSeq removes one public title (field 1) or body (field 2)
// from realm storage: the one recorded by the note-level history event seq (a
// version's recorded_seq). The name carries the addressing so a caller written
// for field revisions cannot act on the wrong version. History stores each field
// revision once, so every version that kept that title or body shows it
// redacted. Public history keeps its SHA-256 and a content-redact entry naming
// the moderator and the field revision. Redacting the current version also
// replaces it (placeholder title, empty body) under a new field revision. Gno
// refunds the freed storage to the moderator who frees it.
func RedactPublicContentAtSeq(cur realm, id [16]byte, baseRevision uint64, field uint8, seq uint64, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateRedactPublicContentAtSeq(cur, who, id, baseRevision, field, seq, opID)
}
func mutateRedactPublicContentAtSeq(cur realm, who address, id [16]byte, baseRevision uint64, field uint8, seq uint64, opID [16]byte) {
	n := find(id)
	if !moderator(who) {
		panic("notes: moderator required")
	}
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: public note required")
	}
	if field != 1 && field != 2 {
		panic("notes: bad redaction field")
	}
	v := historyVersionAt(n.ID, seq)
	if v == nil {
		panic("notes: history version missing")
	}
	name, b, fieldRevision := "title", v.Title, v.TitleRevision
	if field == 2 {
		name, b, fieldRevision = "body", v.Body, v.BodyRevision
	}
	if b == nil {
		panic("notes: history version missing")
	}
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
		archived.Anchor, archived.Body, archived.Redacted = nil, nil, true
		e := historyAppend(n, who, opID, cid, "comment-redact", `{"comment_id":`+q(idText(cid))+`,"purged":true}`)
		archived.LatestSeq = e.Seq
		return
	}
	c := cv.(*comment)
	commentExpected(c, baseRevision, opID)
	archived.Anchor, archived.Body, archived.Redacted = nil, nil, true
	c.Anchor, c.Body, c.Hidden = nil, nil, true
	commentReceipt(c, who, opID)
	historyCommentChange(n, c, "comment-redact")
}
