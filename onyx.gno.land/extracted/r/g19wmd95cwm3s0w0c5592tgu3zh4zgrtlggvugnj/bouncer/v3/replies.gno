package bouncer

import (
	"chain"
	"chain/runtime"
)

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
