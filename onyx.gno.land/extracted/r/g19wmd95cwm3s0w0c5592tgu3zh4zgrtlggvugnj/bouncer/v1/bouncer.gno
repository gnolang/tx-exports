// Package bouncer is Bouncer's on-chain registry: scan requests,
// attestations, disputes and author replies, plus the reads other realms use
// (Check, Score) and the Tavern pages in Render.
//
// One realm holds all state and every write, and every logic-data type is
// declared here (security guide §3A). Writes are crossing functions that
// check cur.IsCurrent() and take the caller from cur.Previous(). Reads are
// plain functions that return values or copies, never pointers into state,
// and never take callbacks.
package bouncer

import (
	"chain"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	admin     address
	attesters = avl.NewTree() // address -> true
	// selfPath is this realm's package path, for links in Render.
	selfPath string

	// Scan requests.
	requests        = avl.NewTree() // request id -> *request
	openByRequester = avl.NewTree() // address -> request id (one open each)
	openRequests    = avl.NewTree() // request id -> true, open ones only
	requestID       seqid.ID

	// Attestations.
	records       = avl.NewTree() // pkgpath -> *record
	byAuthor      = avl.NewTree() // author address -> *avl.Tree (pkgpath -> true)
	attestationID seqid.ID
	recent        []string // pkgpaths, most recently attested first

	// Disputes.
	disputes  = avl.NewTree() // dispute id -> *dispute
	disputeID seqid.ID

	// Totals over the latest attestation of each package.
	totalFindings int
	totalProven   int
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("bouncer must be deployed by a user")
	}
	// The deployer becomes admin and the first attester. Under gno test
	// the deploying user has no address; then no admin is set, which
	// locks every admin action rather than opening it.
	if deployer := prev.Address(); deployer.IsValid() {
		admin = deployer
		attesters.Set(string(admin), true)
	}
}

// ---- admin and attesters ----

func assertAdmin(cur realm) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

func assertAttester(cur realm) address {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	caller := cur.Previous().Address()
	if !attesters.Has(string(caller)) {
		panic("attester only")
	}
	return caller
}

// AddAttester allows addr to post attestations.
func AddAttester(cur realm, addr address) {
	assertAdmin(cur)
	if !addr.IsValid() {
		panic("invalid address")
	}
	attesters.Set(string(addr), true)
	chain.Emit("AttesterAdded", "address", addr.String())
}

// RemoveAttester revokes addr. Its past attestations stay on record.
func RemoveAttester(cur realm, addr address) {
	assertAdmin(cur)
	if _, removed := attesters.Remove(string(addr)); !removed {
		panic("not an attester")
	}
	chain.Emit("AttesterRemoved", "address", addr.String())
}

// TransferAdmin hands the admin role to next.
func TransferAdmin(cur realm, next address) {
	assertAdmin(cur)
	if !next.IsValid() {
		panic("invalid address")
	}
	prev := admin
	admin = next
	chain.Emit("AdminTransferred", "from", prev.String(), "to", next.String())
}

// Admin returns the admin address.
func Admin() address { return admin }

// IsAttester reports whether addr may post attestations.
func IsAttester(addr address) bool { return attesters.Has(string(addr)) }

// Attesters returns the attester allowlist, sorted.
func Attesters() []address {
	out := make([]address, 0, attesters.Size())
	attesters.Iterate("", "", func(k string, _ any) bool {
		out = append(out, address(k))
		return false
	})
	return out
}

// ---- package paths ----

const maxPkgPathLen = 200

// validPkgPath accepts gno.land/r/... and gno.land/p/... paths of at least
// a namespace and a name, made of lowercase letters, digits and underscores.
func validPkgPath(p string) bool {
	if len(p) > maxPkgPathLen {
		return false
	}
	rest, ok := strings.CutPrefix(p, "gno.land/")
	if !ok {
		return false
	}
	segs := strings.Split(rest, "/")
	if len(segs) < 3 || (segs[0] != "r" && segs[0] != "p") {
		return false
	}
	for _, s := range segs[1:] {
		if s == "" {
			return false
		}
		for _, c := range s {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
				return false
			}
		}
	}
	return true
}

// authorOf returns the address that owns an address-namespace path
// (gno.land/r/<address>/... or gno.land/p/<address>/...). Only that address
// can deploy there, so authorship is verified by the path alone. Other
// namespaces have no verified author.
func authorOf(pkgpath string) (address, bool) {
	segs := strings.Split(pkgpath, "/")
	if len(segs) < 4 {
		return "", false
	}
	a := address(segs[2])
	if !a.IsValid() {
		return "", false
	}
	return a, true
}
