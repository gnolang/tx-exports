package memba_notes_rc1

import (
	keys "gno.land/r/samcrew/enckeys_v1"
	"strings"
)

func writer(n *note, who address) bool {
	for _, a := range n.Writers {
		if a == who {
			return true
		}
	}
	return false
}
func canWrite(cur realm, n *note, who address) bool {
	if who == n.Owner {
		return true
	}
	if n.Mode == ModePublicOpen {
		return false
	}
	if writer(n, who) {
		return true
	}
	if encrypted(n.Mode) && !contains(n.Readers, who) {
		return false
	}
	if n.GovWriters && n.Owner == govAddress && govMember(who) {
		return true
	}
	return policyAllows(cur, n, who, OpWrite)
}
func requireWrite(cur realm, n *note, who address) {
	if !canWrite(cur, n, who) {
		panic("notes: writer required")
	}
}
func AddWriter(cur realm, id [16]byte, baseRevision uint64, to address, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateAddWriter(cur, who, id, baseRevision, to, opID)
}
func mutateAddWriter(cur realm, who address, id [16]byte, baseRevision uint64, to address, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: encrypted ACL requires atomic manifest")
	}
	to = keys.CanonicalAddress(to)
	if to == n.Owner || writer(n, to) {
		panic("notes: writer already present")
	}
	if len(n.Writers) >= MaxReaders {
		panic("notes: too many writers")
	}
	operation(n, opID)
	n.Writers = append(n.Writers, to)
	sharedIndex.Set(string(to)+":"+indexKey(n), idText(id))
	bump(n, who, opID, "writer-add")
}
func RemoveWriter(cur realm, id [16]byte, baseRevision uint64, to address, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateRemoveWriter(cur, who, id, baseRevision, to, opID)
}
func mutateRemoveWriter(cur realm, who address, id [16]byte, baseRevision uint64, to address, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: encrypted ACL requires rotation")
	}
	to = keys.CanonicalAddress(to)
	if !writer(n, to) {
		panic("notes: writer missing")
	}
	operation(n, opID)
	for i, a := range n.Writers {
		if a == to {
			n.Writers = append(n.Writers[:i], n.Writers[i+1:]...)
			break
		}
	}
	sharedIndex.Remove(string(to) + ":" + indexKey(n))
	bump(n, who, opID, "writer-remove")
}
func ProposeOwner(cur realm, id [16]byte, baseRevision uint64, to address, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateProposeOwner(cur, who, id, baseRevision, to, opID)
}
func mutateProposeOwner(cur realm, who address, id [16]byte, baseRevision uint64, to address, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if to != "" {
		to = keys.CanonicalAddress(to)
	}
	if to == n.Owner {
		panic("notes: already owner")
	}
	operation(n, opID)
	n.PendingOwner = to
	bump(n, who, opID, "owner-propose")
}
func AcceptOwnership(cur realm, id [16]byte, baseRevision uint64, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateAcceptOwnership(cur, who, id, baseRevision, opID)
}
func mutateAcceptOwnership(cur realm, who address, id [16]byte, baseRevision uint64, opID [16]byte) {
	n := live(id)
	expected(n, baseRevision)
	if n.PendingOwner == "" || who != n.PendingOwner {
		panic("notes: pending owner required")
	}
	isRealm := strings.HasPrefix(cur.Previous().PkgPath(), "gno.land/r/") || who == govAddress
	if encrypted(n.Mode) && (!isRealm && !contains(n.Readers, who) || isRealm && n.Mode == ModePrivate) {
		panic("notes: encrypted ownership requires current wrap/shared mode")
	}
	if n.OwnerGeneration == ^uint64(0) {
		panic("notes: owner generation exhausted")
	}
	operation(n, opID)
	unindex(n)
	n.OwnerIsRealm = isRealm
	resetPublicWrites(n)
	n.Owner = who
	n.PendingOwner = ""
	n.OwnerGeneration++
	n.GovWriters = false
	if encrypted(n.Mode) {
		preserveTransferredWriters(n)
	}
	index(n)
	bump(n, who, opID, "owner-accept")
}
func SetListed(cur realm, id [16]byte, baseRevision uint64, listed bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateSetListed(cur, who, id, baseRevision, listed, opID)
}
func mutateSetListed(cur realm, who address, id [16]byte, baseRevision uint64, listed bool, opID [16]byte) {
	n := live(id)
	if who != n.Owner && moderator(who) {
		mutateModerateListing(cur, who, id, baseRevision, listed, opID)
		return
	}
	owner(n, who)
	expected(n, baseRevision)
	if !public(n.Mode) {
		panic("notes: public note required")
	}
	operation(n, opID)
	unindex(n)
	n.Listed = listed
	index(n)
	bump(n, who, opID, "listing")
}
func WritersJSON(idHex string) string {
	n := find(readID(idHex))
	out := "["
	for i, a := range n.Writers {
		if i > 0 {
			out += ","
		}
		out += q(string(a))
	}
	return out + "]"
}
func ListSharedWithJSON(addr address, cursor string, limit int) string {
	return page(sharedIndex, string(keys.CanonicalAddress(addr))+":", cursor, limit)
}
