package memba_notes_rc1

import "strconv"

const MaxBodyChunkBytes = 8192

func NoteMetaJSON(idHex string) string {
	v, ok := notes.Get(idText(readID(idHex)))
	if !ok {
		return "null"
	}
	return noteJSON(v.(*note), false)
}

// Each page is tied to the complete state revision, including access/mode and
// epoch changes. Clients concatenate binary chunks before decoding UTF8/AEAD.
func NoteBodyChunkJSON(idHex string, expectedRevision uint64, offset, limit int) string {
	n := find(readID(idHex))
	if expectedRevision != n.Revision {
		panic("notes: stale body revision")
	}
	if limit < 1 || limit > MaxBodyChunkBytes || offset < 0 || offset > n.BodyBytes {
		panic("notes: body chunk bounds")
	}
	end := offset + limit
	if end > n.BodyBytes {
		end = n.BodyBytes
	}
	return `{"id":` + q(idText(n.ID)) + `,"state_revision":` + u(n.Revision) + `,"body_revision":` + u(n.BodyRevision) + `,"epoch":` + u(uint64(n.Epoch)) + `,"offset":` + q(strconv.Itoa(offset)) + `,"total":` + q(strconv.Itoa(n.BodyBytes)) + `,"next_offset":` + q(strconv.Itoa(end)) + `,"chunk_blob":` + blob(n.Body[offset:end]) + `}`
}
