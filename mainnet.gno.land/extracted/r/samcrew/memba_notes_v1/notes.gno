package memba_notes_v1

import (
	"chain"
	"chain/banker"
	"chain/runtime"
)

// CreateNote is the only payable entrypoint; encrypted creation is atomic.
func CreateNote(cur realm, id [16]byte, mode uint8, title, body, access, commitment []byte, maxFee int64, opID [16]byte) {
	who := enter(cur, true)
	defer leave()
	if !cur.Previous().IsUserCall() {
		panic("notes: create directly from your account")
	}
	if paused {
		panic("notes: creation paused")
	}
	if id == ([16]byte{}) {
		panic("notes: empty note id")
	}
	if _, ok := notes.Get(idText(id)); ok {
		panic("notes: note id used")
	}
	if mode > ModePublicOpen || public(mode) && (len(access) != 0 || len(commitment) != 0) {
		panic("notes: unsupported creation mode")
	}
	if public(mode) {
		validatePublic(title, body)
	}
	operation(nil, opID)
	assertCreatePayment(cur, maxFee)
	if sequence == ^uint64(0) {
		panic("notes: sequence exhausted")
	}
	sequence++
	n := &note{ID: id, Owner: who, OwnerGeneration: 1, Mode: mode, TitleRevision: 1, BodyRevision: 1, Title: copied(title), Body: copied(body), BodyBytes: len(body), CreatedHeight: runtime.ChainHeight(), Sequence: sequence, Listed: public(mode)}
	if encrypted(mode) {
		initializeEncrypted(n, access, commitment)
	}
	bump(n, who, opID, "create")
	notes.Set(idText(id), n)
	index(n)
	if createFee > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), treasury, chain.Coins{chain.NewCoin("ugnot", createFee)})
	}
}

// fieldMask: 1 title, 2 body, 3 both. An unchanged field must be omitted (empty
// blob). The separate field revision advances only when that field changes.
func Commit(cur realm, id [16]byte, baseRevision uint64, expectedEpoch uint32, fieldMask uint8, title, body []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateCommit(cur, who, id, baseRevision, expectedEpoch, fieldMask, title, body, opID)
}
func mutateCommit(cur realm, who address, id [16]byte, baseRevision uint64, expectedEpoch uint32, fieldMask uint8, title, body []byte, opID [16]byte) {
	n := live(id)
	requireContentWrite(cur, n, who)
	expected(n, baseRevision)
	if n.Epoch != expectedEpoch {
		panic("notes: stale epoch")
	}
	privateWritable(n)
	if fieldMask < 1 || fieldMask > 3 || (fieldMask&1 == 0 && len(title) != 0) || (fieldMask&2 == 0 && len(body) != 0) {
		panic("notes: bad field mask")
	}
	if fieldMask&1 != 0 {
		if public(n.Mode) {
			validateTitle(title)
		} else {
			validateCipher(title, n.Epoch, 1, n.TitleRevision+1, MaxCipherTitleBytes)
		}
		if n.TitleRevision == ^uint64(0) {
			panic("notes: title revision exhausted")
		}
	}
	if fieldMask&2 != 0 {
		if public(n.Mode) {
			validatePublic(n.Title, body)
		} else {
			validateCipher(body, n.Epoch, 2, n.BodyRevision+1, MaxCipherBodyBytes)
		}
		if n.BodyRevision == ^uint64(0) {
			panic("notes: body revision exhausted")
		}
	}
	operation(n, opID)
	if fieldMask&1 != 0 {
		n.Title = copied(title)
		n.TitleRevision++
	}
	if fieldMask&2 != 0 {
		n.Body = copied(body)
		n.BodyBytes = len(body)
		n.BodyRevision++
	}
	bump(n, who, opID, "commit")
}
func Rename(cur realm, id [16]byte, baseRevision uint64, expectedEpoch uint32, title []byte, opID [16]byte) {
	Commit(cur, id, baseRevision, expectedEpoch, 1, title, nil, opID)
}

// Delete retains the ID and last operation receipt forever. Large collections
// are purged by bounded follow-up calls, never by an unbounded delete loop.
func Delete(cur realm, id [16]byte, baseRevision uint64, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateDelete(cur, who, id, baseRevision, opID)
}
func mutateDelete(cur realm, who address, id [16]byte, baseRevision uint64, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	operation(n, opID)
	unindex(n)
	resetPublicWrites(n)
	n.Deleted = true
	n.Listed = false
	n.Title = nil
	n.Body = nil
	n.BodyBytes = 0
	n.Commitment = nil
	n.PendingOwner = ""
	n.Writers = nil
	n.Readers = nil
	n.Policies = [3]string{}
	n.GovWriters = false
	bump(n, who, opID, "delete")
}
func SetCommentMode(cur realm, id [16]byte, baseRevision uint64, open bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateSetCommentMode(cur, who, id, baseRevision, open, opID)
}
func mutateSetCommentMode(cur realm, who address, id [16]byte, baseRevision uint64, open bool, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: public note required")
	}
	operation(n, opID)
	if open {
		n.Mode = ModePublicOpen
	} else {
		resetPublicWrites(n)
		n.Mode = ModePublic
	}
	bump(n, who, opID, "comments-mode")
}
