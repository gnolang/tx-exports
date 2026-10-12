package memba_notes_v1

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"gno.land/p/samcrew/daoauth"
	gov "gno.land/r/samcrew/memba_gov"
	"strconv"
)

const GovRealmPath = "gno.land/r/samcrew/memba_gov"

var govAddress = chain.PackageAddress(GovRealmPath)

func govMember(who address) bool { return gov.IsMember(who) }
func SetGovWriters(cur realm, id [16]byte, baseRevision uint64, on bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateSetGovWriters(cur, who, id, baseRevision, on, opID)
}
func mutateSetGovWriters(cur realm, who address, id [16]byte, baseRevision uint64, on bool, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if n.Owner != govAddress {
		panic("notes: gov owner required")
	}
	operation(n, opID)
	n.GovWriters = on
	bump(n, who, opID, "gov-writers")
}
func validGovAction(action string) bool {
	switch action {
	case "AcceptOwnership", "Commit", "Rename", "Rotate", "ApplyAccess", "Publish", "Reveal", "Delete", "AddWriter", "RemoveWriter", "ProposeOwner", "SetPolicy", "SetCommentMode", "SetPublicWrites", "SetListed", "ModerateListing", "SetGovWriters", "HideComment", "ResolveComment", "RejectAccessRequest", "Purge":
		return true
	}
	return false
}

// The typed payload is bounded and hashed as bytes, including its version.
// Every precondition and opID is domain-bound; no raw large/Unicode content is
// put in daoauth's 1024-byte printable-ASCII argument envelope.
func govDigest(n *note, baseRevision, ownerGeneration uint64, expectedEpoch uint32, action string, payload []byte, opID [16]byte) string {
	if !validGovAction(action) || len(payload) < 1 || len(payload) > MaxGovPayloadBytes {
		panic("notes: unknown/oversize gov operation")
	}
	b := appendText(nil, "memba-notes/v1/gov-operation")
	b = appendText(b, runtime.ChainID())
	b = appendText(b, RealmPath)
	b = append(b, n.ID[:]...)
	number := make([]byte, 8)
	binary.BigEndian.PutUint64(number, ownerGeneration)
	b = append(b, number...)
	binary.BigEndian.PutUint64(number, baseRevision)
	b = append(b, number...)
	ep := make([]byte, 4)
	binary.BigEndian.PutUint32(ep, expectedEpoch)
	b = append(b, ep...)
	b = append(b, n.Mode)
	b = appendText(b, string(n.Owner))
	b = appendText(b, string(n.PendingOwner))
	b = appendText(b, string(n.Commitment))
	b = appendText(b, action)
	hash := sha256.Sum256(payload)
	b = append(b, hash[:]...)
	b = append(b, opID[:]...)
	digest := sha256.Sum256(b)
	return hex.EncodeToString(digest[:])
}
func GovDigest(idHex string, baseRevision, ownerGeneration uint64, expectedEpoch uint32, action string, payload []byte, opID [16]byte) string {
	return govDigest(find(readID(idHex)), baseRevision, ownerGeneration, expectedEpoch, action, payload, opID)
}
func GovApply(cur realm, pid uint64, id [16]byte, baseRevision, ownerGeneration uint64, expectedEpoch uint32, action string, payload []byte, opID [16]byte) {
	executor := enter(cur, false)
	defer leave()
	if !cur.Previous().IsUserCall() {
		panic("notes: direct governance executor required")
	}
	operation(nil, opID)
	n := find(id)
	expected(n, baseRevision)
	if ownerGeneration != n.OwnerGeneration || expectedEpoch != n.Epoch {
		panic("notes: stale governance generation/epoch")
	}
	if action == "AcceptOwnership" {
		if n.PendingOwner != govAddress {
			panic("notes: pending gov owner required")
		}
	} else if n.Owner != govAddress && !((action == "ModerateListing" || action == "HideComment") && moderator(govAddress)) {
		panic("notes: gov owner required")
	}
	digest := govDigest(n, baseRevision, ownerGeneration, expectedEpoch, action, payload, opID)
	// Failure in dispatch also rolls back Consume in the same transaction.
	gov.Consume(cross(cur), pid, "notes."+action, daoauth.New().Str(digest).String(), "note:"+idText(id), gov.Routine, executor)
	historyGov = &historyCall{executor, pid, opID, action}
	defer func() { historyGov = nil }()
	dispatchGov(cur, n, baseRevision, expectedEpoch, action, payload, opID)
	if n.Revision > baseRevision && n.Last.Operation == opID {
		n.LastExecutor = executor
	}
	chain.Emit("NoteGoverned", "id", idText(id), "action", action, "pid", strconv.FormatUint(pid, 10), "executor", string(executor), "op_id", idText(opID))
}
func dispatchGov(cur realm, n *note, rev uint64, epoch uint32, action string, payload []byte, op [16]byte) {
	r := payloadReader(payload)
	id := n.ID
	who := govAddress
	switch action {
	case "AcceptOwnership":
		r.done()
		mutateAcceptOwnership(cur, who, id, rev, op)
	case "Commit":
		mask := r.byte()
		title := r.blob(MaxCipherTitleBytes)
		body := r.blob(MaxCipherBodyBytes)
		r.done()
		mutateCommit(cur, who, id, rev, epoch, mask, title, body, op)
	case "Rename":
		title := r.blob(MaxCipherTitleBytes)
		r.done()
		mutateCommit(cur, who, id, rev, epoch, 1, title, nil, op)
	case "Rotate":
		mode := r.byte()
		title := r.blob(MaxCipherTitleBytes)
		body := r.blob(MaxCipherBodyBytes)
		manifest := r.blob(MaxManifestBytes)
		kc := r.blob(32)
		r.done()
		mutateRotate(cur, who, id, rev, epoch, mode, title, body, manifest, kc, op)
	case "ApplyAccess":
		mode := r.byte()
		manifest := r.blob(MaxManifestBytes)
		r.done()
		mutateApplyAccess(cur, who, id, rev, epoch, mode, manifest, op)
	case "Publish":
		mode := r.byte()
		title := r.blob(MaxTitleBytes)
		body := r.blob(MaxBodyBytes)
		r.done()
		mutatePublish(cur, who, id, rev, mode, title, body, op)
	case "Reveal":
		ep := r.u32()
		key := r.take(32)
		r.done()
		mutateReveal(cur, who, id, rev, ep, key, op)
	case "Delete":
		r.done()
		mutateDelete(cur, who, id, rev, op)
	case "AddWriter", "RemoveWriter", "ProposeOwner":
		to := address(string(r.blob(90)))
		r.done()
		if action == "AddWriter" {
			mutateAddWriter(cur, who, id, rev, to, op)
		} else if action == "RemoveWriter" {
			mutateRemoveWriter(cur, who, id, rev, to, op)
		} else {
			mutateProposeOwner(cur, who, id, rev, to, op)
		}
	case "SetPolicy":
		kind := r.byte()
		key := string(r.blob(233))
		r.done()
		mutateSetPolicy(cur, who, id, rev, kind, key, op)
	case "SetPublicWrites":
		on := r.boolean()
		r.done()
		mutateSetPublicWrites(cur, who, id, rev, on, op)
	case "SetCommentMode":
		on := r.boolean()
		r.done()
		mutateSetCommentMode(cur, who, id, rev, on, op)
	case "SetListed":
		on := r.boolean()
		r.done()
		mutateSetListed(cur, who, id, rev, on, op)
	case "ModerateListing":
		on := r.boolean()
		r.done()
		mutateModerateListing(cur, who, id, rev, on, op)
	case "SetGovWriters":
		on := r.boolean()
		r.done()
		mutateSetGovWriters(cur, who, id, rev, on, op)
	case "HideComment", "ResolveComment":
		cid := r.id()
		commentRev := r.u64()
		on := r.boolean()
		r.done()
		if action == "HideComment" {
			mutateHideComment(cur, who, id, cid, commentRev, on, op)
		} else {
			mutateResolveComment(cur, who, id, cid, commentRev, on, op)
		}
	case "RejectAccessRequest":
		to := address(string(r.blob(90)))
		priorOp := r.id()
		r.done()
		v, ok := requests.Get(requestKey(id, to))
		if !ok || v.(*accessRequest).Last.Operation != priorOp {
			panic("notes: stale request approval")
		}
		mutateRejectAccessRequest(cur, who, id, to, op)
	case "Purge":
		limit := r.byte()
		r.done()
		mutatePurge(cur, who, id, int(limit))
	default:
		panic("notes: unknown governance action")
	}
}
