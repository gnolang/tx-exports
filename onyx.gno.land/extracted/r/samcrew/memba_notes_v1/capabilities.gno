package memba_notes_v1

import (
	"gno.land/p/samcrew/avl"
	"strconv"
)

// Only explicit public grants are stored. Private notes keep their existing ACL.
var publicWriteGrants = avl.NewTree()

func publicWritesEnabled(n *note) bool {
	_, granted := publicWriteGrants.Get(idText(n.ID))
	return !n.Deleted && n.Mode == ModePublicOpen && granted
}
func resetPublicWrites(n *note) {
	if _, granted := publicWriteGrants.Get(idText(n.ID)); granted {
		publicWriteGrants.Remove(idText(n.ID))
	}
}

// Community editing never grants ResolveComment or any owner/moderator action.
// Keep requireWrite unchanged for those existing permissions.
// While paused the grant is ignored, so only the existing ACL can edit.
func requireContentWrite(cur realm, n *note, who address) {
	if !paused && publicWritesEnabled(n) && cur.Previous().IsUserCall() {
		return
	}
	requireWrite(cur, n, who)
}

func SetPublicWrites(cur realm, id [16]byte, baseRevision uint64, on bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateSetPublicWrites(cur, who, id, baseRevision, on, opID)
}
func mutateSetPublicWrites(cur realm, who address, id [16]byte, baseRevision uint64, on bool, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if n.Mode != ModePublicOpen {
		panic("notes: public-open note required")
	}
	operation(n, opID)
	if publicWritesEnabled(n) == on {
		panic("notes: public writes unchanged")
	}
	if on {
		publicWriteGrants.Set(idText(id), true)
	} else {
		resetPublicWrites(n)
	}
	bump(n, who, opID, "public-writes")
}

// Separate schema: existing NoteJSON consumers retain their exact field set.
func PublicCapabilitiesJSON(idHex string) string {
	v, ok := notes.Get(idText(readID(idHex)))
	if !ok {
		return "null"
	}
	n := v.(*note)
	if !public(n.Mode) {
		return "null"
	}
	return `{"schema":"memba-notes/public-capabilities/v1","id":` + q(idText(n.ID)) + `,"state_revision":` + u(n.Revision) + `,"owner_generation":` + u(n.OwnerGeneration) + `,"mode":` + strconv.Itoa(int(n.Mode)) + `,"deleted":` + strconv.FormatBool(n.Deleted) + `,"allow_public_writes":` + strconv.FormatBool(publicWritesEnabled(n)) + `}`
}
