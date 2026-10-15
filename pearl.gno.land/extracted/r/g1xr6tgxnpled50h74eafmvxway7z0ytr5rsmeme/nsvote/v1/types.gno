// Package nsvote holds domain requests and the votes on them.
//
// A SEPARATE REALM, and deliberately so. It never writes to nsdata: it
// only reads it, to answer two questions — does this address hold a
// name, and who is the admin. So it needs no trusted-logic grant, it
// cannot corrupt the registry however wrong its own logic turns out to
// be, and it can be replaced or abandoned without touching a single
// name anybody owns.
//
// WHAT IT DOES NOT DO
//
// It does not create domains. A vote is advice; creating the domain
// stays a deliberate admin call in nslogic. Wiring the two together
// would mean a majority could add a domain nobody had looked at, and
// the vault has no undo.
//
// It holds no funds, at any point, for anybody. The only cost of
// proposing or voting is the storage each writer pays for their own
// bytes, which the chain moves directly and which comes back if the
// record is ever deleted.
package nsvote

import (
	"gno.land/p/nt/avl/v0"
)

// Two things get asked for here, and they are not the same request.
//
//	domain  a new *domain to sell names under
//	chain   a new blockchain to accept an address for on profiles
//
// The kind is stored rather than inferred from the label, because
// "solana" is a plausible request of either sort and guessing wrong
// files somebody's vote under the wrong question.
type Proposal struct {
	kind     string  // "domain" | "chain"
	label    string  // the domain, or the chain's ticker
	reason   string  // why, capped: this is storage somebody is paying for
	proposer address
	created  int64 // unix seconds
	yes      int64
	no       int64
	status   string // "open" | "accepted" | "rejected" | "withdrawn"
	decided  int64  // unix seconds, 0 while open
}

var (
	proposals avl.Tree // id (zero-padded) -> *Proposal
	votes     avl.Tree // id + "/" + voter -> "y" | "n"
	nextID    int64    = 1

	// A reason is a sentence, not an essay. Every character is storage
	// the proposer pays for and the chain keeps.
	maxReason = 280
	// Reading a page walks every name in it, so the ceiling protects the
	// node rather than the caller.
	maxPage = 200
)
