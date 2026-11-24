package bouncer

import (
	"chain"
	"chain/runtime"

	"gno.land/p/nt/seqid/v0"
)

// DisputeRecord is a challenge to an attestation, backed by a different report.
type DisputeRecord struct {
	ID            uint64
	PkgPath       string
	AttestationID uint64 // the attestation disputed (the latest at filing time)
	ReportHash    string // the disputer's report
	Note          string
	Filer         address
	Height        int64
	Resolved      bool
	Resolution    string
}

type dispute struct {
	d DisputeRecord
}

func disputeKey(id uint64) string { return seqid.ID(id).String() }

// Dispute files a challenge against the latest attestation of pkgpath,
// backed by a report with a different hash. One open dispute per filer
// per package.
func Dispute(cur realm, pkgpath, reportHash, note string) uint64 {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	filer := cur.Previous().Address()
	rec := getRecord(pkgpath)
	if rec == nil {
		panic("no attestation to dispute")
	}
	latest := rec.history[len(rec.history)-1]
	if !isHex64(reportHash) {
		panic("report hash must be 64 lowercase hex characters")
	}
	if reportHash == latest.ReportHash {
		panic("a dispute needs a report that differs from the attested one")
	}
	if note == "" || len(note) > maxNoteLen {
		panic("note must be 1 to 280 bytes")
	}
	if hasOpenDispute(pkgpath, filer) {
		panic("you already have an open dispute on this package")
	}
	id := uint64(disputeID.Next())
	disputes.Set(disputeKey(id), &dispute{d: DisputeRecord{
		ID:            id,
		PkgPath:       pkgpath,
		AttestationID: latest.ID,
		ReportHash:    reportHash,
		Note:          note,
		Filer:         filer,
		Height:        runtime.ChainHeight(),
	}})
	chain.Emit("Disputed", "id", disputeKey(id), "pkgpath", pkgpath, "filer", filer.String(), "report_hash", reportHash)
	return id
}

// ResolveDispute closes a dispute with a resolution note. Admin or an
// attester.
func ResolveDispute(cur realm, id uint64, resolution string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	caller := cur.Previous().Address()
	if caller != admin && !attesters.Has(string(caller)) {
		panic("admin or attester only")
	}
	if resolution == "" || len(resolution) > maxNoteLen {
		panic("resolution must be 1 to 280 bytes")
	}
	v := disputes.Get(disputeKey(id))
	if v == nil {
		panic("no such dispute")
	}
	d := v.(*dispute)
	if d.d.Resolved {
		panic("dispute already resolved")
	}
	d.d.Resolved = true
	d.d.Resolution = resolution
	chain.Emit("DisputeResolved", "id", disputeKey(id), "pkgpath", d.d.PkgPath)
}

func hasOpenDispute(pkgpath string, filer address) bool {
	found := false
	disputes.Iterate("", "", func(_ string, v any) bool {
		d := v.(*dispute).d
		if d.PkgPath == pkgpath && !d.Resolved && (filer == "" || d.Filer == filer) {
			found = true
		}
		return found
	})
	return found
}

// DisputesFor returns copies of every dispute on pkgpath, oldest first.
func DisputesFor(pkgpath string) []DisputeRecord {
	out := []DisputeRecord{}
	disputes.Iterate("", "", func(_ string, v any) bool {
		if d := v.(*dispute).d; d.PkgPath == pkgpath {
			out = append(out, d)
		}
		return false
	})
	return out
}

// Reply lets the author of an address-namespace package answer its
// Passport and, optionally, name the fixed version (successor) in the same
// namespace.
func Reply(cur realm, pkgpath, note, successor string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	caller := cur.Previous().Address()
	author, ok := authorOf(pkgpath)
	if !ok {
		panic("only address-namespace packages have a verified author")
	}
	if caller != author {
		panic("author only")
	}
	rec := getRecord(pkgpath)
	if rec == nil {
		panic("no attestation to reply to")
	}
	if note == "" || len(note) > maxNoteLen {
		panic("note must be 1 to 280 bytes")
	}
	if successor != "" {
		if !validPkgPath(successor) || successor == pkgpath {
			panic("invalid successor path")
		}
		if sa, ok := authorOf(successor); !ok || sa != author {
			panic("the successor must be in the same address namespace")
		}
	}
	if len(rec.replies) >= maxReplies {
		panic("reply limit reached for this package")
	}
	rec.replies = append(rec.replies, AuthorReply{Author: caller, Note: note, Successor: successor, Height: runtime.ChainHeight()})
	chain.Emit("Replied", "pkgpath", pkgpath, "author", caller.String(), "successor", successor)
}
