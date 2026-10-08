// Package curation records who curates the Launchpad marketplace and what
// they decided about a collection: applications, feature slots, temporary
// holds, verification and appeals. It holds no coins and no tokens, never
// changes a collection's terms and never blocks a transfer, sale, refund or
// claim: a client reads these records and decides what to show.
package curation

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

const (
	maxSeats = 5
	maxTerm  = 90 * 24 * 60 * 60 // seconds

	StatusSubmitted        = "submitted"
	StatusChangesRequested = "changes_requested"
	StatusRecommended      = "recommended"
	StatusDeclined         = "declined"
)

// A seat is active strictly before until. Lead is a public label and grants
// nothing.
type seat struct {
	lead  bool
	until int64
}

// An Application is a founder's request for review and the latest decision on
// it. Earlier revisions and decisions stay in the event log.
type Application struct {
	Founder       address // who filed the latest revision
	StatementHash string
	StatementCID  string
	Revision      int64 // 0: nobody applied
	Status        string
	Reviewer      address
	ReasonHash    string
	ReasonCID     string
	UpdatedAt     int64
}

var (
	admin        address
	pendingAdmin address
	seats        avl.Tree // manager address -> seat; at most maxSeats entries
	conflicts    avl.Tree // "<collection>/<address>" -> true; never removed
	applications avl.Tree // collection -> *Application
	lastFiling   seqid.ID
	filings      avl.Tree // seqid key -> collection, in order of first filing
)

// The account that publishes the package is the first admin.
func init() { admin = unsafe.OriginCaller() }

func now() int64 { return time.Now().Unix() }

// caller returns the immediate caller. Nothing here takes payment: coins a
// wallet attaches to a direct call would stay in this realm, so they are
// refused. A calling realm keeps whatever its own caller sent.
func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("launchpad/curation: stale realm context")
	}
	if cur.Previous().IsUserCall() {
		currency.AssertNoCoins(0, cur)
	}
	return cur.Previous().Address()
}

// direct returns the wallet that called this realm itself. Founders and
// managers act in person: no realm can apply, review or recuse for them.
func direct(cur realm) address {
	who := caller(cur)
	if !cur.Previous().IsUserCall() {
		panic("launchpad/curation: direct user call required")
	}
	return who
}

func requireAdmin(cur realm) {
	if caller(cur) != admin {
		panic("launchpad/curation: admin only")
	}
}

var zeroHash = strings.Repeat("0", 64)

// commitment checks a pointer to public text: the SHA-256 of its exact bytes
// as 64 lowercase hex digits, not all zero, and a bounded IPFS CID it can be
// fetched from (CIDv1 "bafy..." or "bafk..." in base32, or CIDv0 "Qm..." in
// base58). Clients must hash what they fetch before showing it. Private prose
// never goes on chain. Byte ranges, not alphabet lookups: this is most of the
// cost of a call that takes a pointer.
func commitment(hash, cid string) {
	ok := len(hash) == 64 && hash != zeroHash
	for i := 0; ok && i < len(hash); i++ {
		c := hash[i]
		ok = c >= '0' && c <= '9' || c >= 'a' && c <= 'f'
	}
	switch {
	case len(cid) >= 59 && len(cid) <= 90 && (cid[:4] == "bafy" || cid[:4] == "bafk"):
		for i := 4; ok && i < len(cid); i++ {
			c := cid[i]
			ok = c >= 'a' && c <= 'z' || c >= '2' && c <= '7'
		}
	case len(cid) == 46 && cid[:2] == "Qm":
		for i := 2; ok && i < len(cid); i++ {
			c := cid[i]
			ok = c >= '1' && c <= '9' || c >= 'A' && c <= 'H' || c >= 'J' && c <= 'N' ||
				c >= 'P' && c <= 'Z' || c >= 'a' && c <= 'k' || c >= 'm' && c <= 'z'
		}
	default:
		ok = false
	}
	if !ok {
		panic("launchpad/curation: invalid hash or CID")
	}
}

// ProposeAdmin starts a handoff to any account or realm. Nothing changes
// until that exact address accepts.
func ProposeAdmin(cur realm, next address) {
	requireAdmin(cur)
	if !meta.ValidAddress(next) || next == admin {
		panic("launchpad/curation: invalid next admin")
	}
	pendingAdmin = next
	chain.Emit("AdminProposed", "admin", admin.String(), "pending", next.String())
}

func CancelAdminProposal(cur realm) {
	requireAdmin(cur)
	if pendingAdmin == "" {
		panic("launchpad/curation: no pending admin")
	}
	pendingAdmin = ""
	chain.Emit("AdminProposalCancelled", "admin", admin.String())
}

// AcceptAdmin completes the handoff. No caller has the empty address, so
// nobody accepts while nothing is proposed. The admin holds no seat: a
// manager who accepts gives its seat up.
func AcceptAdmin(cur realm) {
	who := caller(cur)
	if who != pendingAdmin {
		panic("launchpad/curation: pending admin only")
	}
	previous := admin
	admin, pendingAdmin = who, ""
	if _, held := seats.Remove(who.String()); held {
		chain.Emit("ManagerRemoved", "manager", who.String())
	}
	chain.Emit("AdminAccepted", "admin", who.String(), "previous", previous.String())
}

func GetAdmin() address        { return admin }
func GetPendingAdmin() address { return pendingAdmin }

// checkAccount refuses an address the chain never gives a caller: another
// spelling of an account would read as a stranger.
func checkAccount(who address) {
	if !meta.ValidAddress(who) {
		panic("launchpad/curation: invalid account")
	}
}

func active(who address) bool {
	s := seats.Get(who.String())
	return s != nil && now() < s.(seat).until
}

func ActiveManager(who address) bool {
	checkAccount(who)
	return active(who)
}

func ActiveManagerCount() int {
	n, at := 0, now()
	seats.Iterate("", "", func(_ string, v any) bool {
		if at < v.(seat).until {
			n++
		}
		return false
	})
	return n
}

// AppointManager seats a manager until a time at most 90 days ahead, or
// replaces the term of one already seated. Expired seats are dropped first,
// so the tree never holds more than maxSeats entries.
func AppointManager(cur realm, who address, lead bool, until int64) {
	requireAdmin(cur)
	at := now()
	if !meta.ValidAddress(who) || who == admin || until <= at || until > at+maxTerm {
		panic("launchpad/curation: invalid manager term")
	}
	var expired []string
	seats.Iterate("", "", func(key string, v any) bool {
		if v.(seat).until <= at {
			expired = append(expired, key)
		}
		return false
	})
	for _, key := range expired {
		seats.Remove(key)
	}
	if !seats.Has(who.String()) && seats.Size() >= maxSeats {
		panic("launchpad/curation: every seat is taken")
	}
	seats.Set(who.String(), seat{lead, until})
	chain.Emit("ManagerAppointed", "manager", who.String(),
		"lead", strconv.FormatBool(lead), "until", strconv.FormatInt(until, 10))
}

func RemoveManager(cur realm, who address) {
	requireAdmin(cur)
	if !ActiveManager(who) {
		panic("launchpad/curation: no active manager")
	}
	seats.Remove(who.String())
	chain.Emit("ManagerRemoved", "manager", who.String())
}

func conflictKey(collection string, who address) string {
	return collection + "/" + who.String()
}

func recorded(collection string, who address) bool {
	return conflicts.Has(conflictKey(collection, who))
}

// HasConflict reports a recorded conflict only: a filing, a recusal or an
// admin's mark. Conflicted is the full rule.
func HasConflict(collection string, who address) bool {
	checkAccount(who)
	return recorded(collection, who)
}

// Conflicted reports whether an account may not act as a manager on a
// collection: it created the collection, holds or is proposed for its
// creator role now, or has a recorded conflict. It aborts on an unknown
// collection.
func Conflicted(collection string, who address) bool {
	checkAccount(who)
	return conflicted(nft.GetInfo(collection), who)
}

func conflicted(info nft.Info, who address) bool {
	return info.Originator == who || info.Creator == who ||
		info.PendingCreator == who || recorded(info.ID, who)
}

func seated(cur realm) address {
	who := direct(cur)
	if !active(who) {
		panic("launchpad/curation: active manager only")
	}
	return who
}

// manager returns the calling manager, who must hold an active seat and have
// no conflict on the collection.
func manager(cur realm, collection string) address {
	who := seated(cur)
	if conflicted(nft.GetInfo(collection), who) {
		panic("launchpad/curation: conflicted manager")
	}
	return who
}

// Resign gives up the calling manager's own seat at once.
func Resign(cur realm) {
	who := seated(cur)
	seats.Remove(who.String())
	chain.Emit("ManagerResigned", "manager", who.String())
}

// reopen voids the decision of a manager found conflicted after making it:
// the application awaits review again, so a conflict cannot be dodged by
// deciding first and disclosing later.
func reopen(collection string, who address) {
	a := applicationOf(collection)
	if a != nil && a.Reviewer == who {
		a.Status, a.Reviewer, a.ReasonHash, a.ReasonCID = StatusSubmitted, "", "", ""
		a.UpdatedAt = now()
		chain.Emit("ApplicationReopened", "collection", collection,
			"revision", strconv.FormatInt(a.Revision, 10), "reason", "conflict")
	}
}

// Recuse records the calling manager's own conflict on a collection and voids
// its decision there, if it made the latest one. A recorded conflict is
// permanent: nobody, the admin included, can clear it, and recusing again
// records and emits nothing.
func Recuse(cur realm, collection string) {
	who := seated(cur)
	nft.GetInfo(collection)
	if !recorded(collection, who) {
		conflicts.Set(conflictKey(collection, who), true)
		chain.Emit("ManagerRecused", "collection", collection, "manager", who.String())
		reopen(collection, who)
	}
}

// MarkConflict records a conflict the admin knows of, on a manager or on an
// account that may become one, and voids that account's latest decision on
// the collection as Recuse does. Marking a recorded conflict again records
// and emits nothing.
func MarkConflict(cur realm, collection string, who address) {
	requireAdmin(cur)
	nft.GetInfo(collection)
	checkAccount(who)
	if !recorded(collection, who) {
		conflicts.Set(conflictKey(collection, who), true)
		chain.Emit("ConflictMarked", "collection", collection, "account", who.String())
		reopen(collection, who)
	}
}

// founder returns the calling wallet, which must hold the collection's
// creator role.
func founder(cur realm, collection string) address {
	who := direct(cur)
	if nft.GetInfo(collection).Creator != who {
		panic("launchpad/curation: collection creator only")
	}
	return who
}

func applicationOf(collection string) *Application {
	if a := applications.Get(collection); a != nil {
		return a.(*Application)
	}
	return nil
}

// GetApplication returns a copy of a collection's application, the zero value
// (revision 0) when nobody applied, as ApplicationJSON answers null.
func GetApplication(collection string) Application {
	if a := applicationOf(collection); a != nil {
		return *a
	}
	return Application{}
}

// Apply files the founder's application for a collection. The founder may
// file again at any time before a recommendation, to correct a pointer or
// after a manager asked for changes or declined. Each filing is a new
// revision awaiting review. Filing records the filer's conflict on the
// collection for good. A realm that holds the creator role never applies: the
// founder calls in person.
func Apply(cur realm, collection, statementHash, statementCID string) {
	who := founder(cur, collection)
	commitment(statementHash, statementCID)
	a := applicationOf(collection)
	if a == nil {
		a = &Application{}
		applications.Set(collection, a)
		filings.Set(lastFiling.Next().String(), collection)
	} else if a.Status == StatusRecommended {
		panic("launchpad/curation: application recommended")
	}
	a.Founder = who // the creator role may have changed hands since the last filing
	if !recorded(collection, who) {
		conflicts.Set(conflictKey(collection, who), true)
	}
	a.Revision++
	a.StatementHash, a.StatementCID = statementHash, statementCID
	a.Status, a.Reviewer, a.ReasonHash, a.ReasonCID = StatusSubmitted, "", "", ""
	a.UpdatedAt = now()
	chain.Emit("ApplicationSubmitted", "collection", collection,
		"founder", who.String(), "revision", strconv.FormatInt(a.Revision, 10),
		"statement_hash", statementHash, "statement_cid", statementCID)
}

// Review records one manager's decision on the revision it read, which must
// still be the latest. Any unconflicted manager may decide again, whatever the
// latest decision. A recommendation is advice to the admin and gives the
// collection nothing by itself.
func Review(cur realm, collection string, revision int64, status, reasonHash, reasonCID string) {
	who := manager(cur, collection)
	a := applicationOf(collection)
	if a == nil {
		panic("launchpad/curation: no application open for review")
	}
	if revision != a.Revision {
		panic("launchpad/curation: application changed")
	}
	if status != StatusChangesRequested && status != StatusRecommended &&
		status != StatusDeclined {
		panic("launchpad/curation: invalid review status")
	}
	commitment(reasonHash, reasonCID)
	a.Status, a.Reviewer, a.ReasonHash, a.ReasonCID = status, who, reasonHash, reasonCID
	a.UpdatedAt = now()
	chain.Emit("ApplicationReviewed", "collection", collection,
		"manager", who.String(), "revision", strconv.FormatInt(a.Revision, 10),
		"status", status, "reason_hash", reasonHash, "reason_cid", reasonCID)
}

func Render(_ string) string {
	return "# Launchpad curation\n\n" + strconv.Itoa(ActiveManagerCount()) +
		" active managers, " + strconv.Itoa(applications.Size()) + " applications.\n"
}
