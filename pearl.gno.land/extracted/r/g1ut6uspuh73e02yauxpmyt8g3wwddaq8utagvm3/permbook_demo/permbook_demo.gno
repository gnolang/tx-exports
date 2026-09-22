// Package permbook_demo is the reference consumer for the permbook
// permission primitive. It exists to make permbook's central claim
// falsifiable on a live chain.
//
// That claim is: a permission revoked in transaction N is refused in
// transaction N+1. A pure package cannot demonstrate this — a vm/qeval is a
// single ephemeral evaluation and nothing it writes survives it. Only a
// realm, called across several transactions, can show a grant taking effect
// and then a revoke taking it away. So this realm is not a decoration on the
// primitive; it is the experiment.
//
// # What it does
//
// Two permission-gated actions, deliberately trivial so that the only
// interesting thing about them is the gate:
//
//   - bump   — increments a counter and records who did it
//   - notice — replaces a short public notice
//
// Neither action is reachable without the corresponding permission. The
// deployer is the book's admin and is the only account that may grant or
// revoke. Holding "bump" confers no authority over the book itself: a holder
// cannot grant, cannot revoke, and cannot nominate. That separation is the
// property being demonstrated.
//
// # How it wires permbook correctly
//
// This realm is also the worked example of permbook's consumer contract:
//
//   - every permbook mutator is called from a CROSSING entrypoint, passing
//     that entrypoint's own cur, so the principal permbook resolves is this
//     realm's immediate caller (contract 1);
//   - the *Book is an unexported package-level var and is never returned
//     across a realm boundary (contract 2);
//   - Has is asked about an address this realm derived itself from
//     cur.Previous().Address(), never about a parameter (contract 3);
//   - the limits are chosen once, at init, and documented below (contract 4).
//
// This realm holds no coins and imports no banker. Every crossing entrypoint
// rejects attached coins; the read views are non-crossing, which MsgCall will
// not dispatch to, so no transaction can attach coins to one.
package permbook_demo

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/permbook"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// The permission names this realm gates on. They are constants rather than
// caller-supplied strings for the gated actions, so a typo cannot silently
// create an unenforced gate.
const (
	PermBump   = "bump"
	PermNotice = "notice"
)

const (
	// The book's limits. Deliberately far below permbook's ceilings: this
	// realm needs two permissions and a handful of holders, and a bound
	// should describe what the application actually does rather than the
	// most the library would tolerate. A few spare slots are left so the
	// permission limit can be exercised on-chain without wedging the demo.
	MaxPermissions = 8
	MaxHolders     = 32
	MaxNameLen     = 24

	// MaxNoticeLen bounds the public notice. A BYTE length, not a rune
	// count, because its job is to bound storage.
	MaxNoticeLen = 200

	// MaxListed caps how many rows any single query or view returns, so no
	// read is unbounded regardless of how full the book is.
	MaxListed = 50
)

// book is the permission set. It is unexported and never returned: handing a
// *permbook.Book across a realm boundary would hand out every mutator on it,
// and borrow rule #2 commits those writes under THIS realm's authority
// (permbook consumer contract 2).
var book *permbook.Book

// The state the gated actions move. This is the observable evidence that a
// gate was open at one height and closed at another.
var (
	bumps          int64
	lastBumper     address
	lastBumpHeight int64

	notice           string
	noticeAuthor     address
	noticeSetAtBlock int64
)

// demoLimits are the limits every Book this realm constructs is given.
func demoLimits() permbook.Limits {
	return permbook.Limits{
		MaxPermissions:          MaxPermissions,
		MaxHoldersPerPermission: MaxHolders,
		MaxNameLen:              MaxNameLen,
	}
}

func init() {
	// The package deployer becomes the book's admin: on-chain, AddPackage
	// runs init with the message creator as origin caller, and a
	// MsgAddPackage's creator is never zero.
	//
	// Under `gno test` there is no MsgAddPackage, so the origin context is
	// empty and the address is invalid; the test file's own init constructs
	// the book instead. On-chain that branch is unreachable, and if it ever
	// were reached the realm would deploy INERT — book stays nil and every
	// entrypoint aborts rather than running ungated. For a realm that holds
	// no value and gates two trivial actions, inert is the safe direction.
	// TestInertRealmFailsClosed exercises exactly that state, so the claim
	// is test-backed rather than argued.
	//
	// An audit of this file recommended panicking here instead, to make the
	// invariant structural. That was tried and rejected on evidence: the
	// realm's init runs before the test file's, so a panic makes the whole
	// package unloadable under `gno test` —
	//
	//	permbook_demo: no deploy-time admin (code=gnoUnknownError)
	//	FAIL: 0 build errors, 1 test errors
	//
	// which trades all 16 tests, including the central authorization claim,
	// for a guard on a branch the audit itself could not reach on-chain.
	// The early return plus a fail-closed test is the better trade.
	//
	// The deploy-time obligation this leaves is real and belongs in the
	// runbook, not in the code: check Ready() immediately after deploying
	// and treat false as a FAILED deploy, because it is unrecoverable —
	// nothing assigns book after init, so a fresh path is the only remedy.
	deployer := unsafe.OriginCaller()
	if !deployer.IsValid() {
		return
	}
	b, err := permbook.New(deployer, demoLimits())
	if err != nil {
		panic(err)
	}
	book = b
}

// Ready reports whether init captured a deploy-time admin and constructed
// the book. False means the realm is inert; see the note in init.
func Ready() bool { return book != nil }

// rejectStraySend aborts if an EOA attached coins to an entrypoint that has
// no use for them. This realm never holds value; without this guard a
// mistyped send would be silently absorbed by the realm bank.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- the gated actions ----------------------------------------------------
//
// Each one asks permbook about an address IT derived from its own crossing
// frame. The address is never a parameter (consumer contract 3).

// Bump increments the counter. Requires the "bump" permission.
//
// This is the experiment: call it with the permission and it succeeds; have
// the admin revoke, call it again in a later transaction, and it aborts.
func Bump(cur realm) string {
	rejectStraySend(cur)

	caller := cur.Previous().Address()
	if !book.Has(PermBump, caller) {
		panic("permission denied: " + PermBump)
	}

	now := runtime.ChainHeight()
	bumps++
	lastBumper = caller
	lastBumpHeight = now

	chain.Emit("Bumped",
		"by", caller.String(),
		"count", itoa(bumps),
		"height", itoa(now),
	)
	return "bump " + itoa(bumps) + " at height " + itoa(now)
}

// SetNotice replaces the public notice. Requires the "notice" permission.
//
// It exists so the demo shows two INDEPENDENT permissions on one book:
// holding "bump" does not let an address set the notice, and revoking one
// leaves the other intact.
func SetNotice(cur realm, text string) string {
	rejectStraySend(cur)

	caller := cur.Previous().Address()
	if !book.Has(PermNotice, caller) {
		panic("permission denied: " + PermNotice)
	}
	if text == "" {
		panic("notice must not be empty")
	}
	if len(text) > MaxNoticeLen {
		panic("notice exceeds " + itoa(MaxNoticeLen) + " bytes")
	}

	now := runtime.ChainHeight()
	notice = text
	noticeAuthor = caller
	noticeSetAtBlock = now

	chain.Emit("NoticeSet", "by", caller.String(), "height", itoa(now))
	return "notice set at height " + itoa(now)
}

// --- administration -------------------------------------------------------
//
// Every one of these is a crossing entrypoint that threads its OWN cur into
// permbook, so permbook resolves this realm's immediate caller as the
// principal (consumer contract 1). None of them takes a caller address as an
// argument; there is nothing here to forge.

// Grant gives addr a permission. Admin only.
func Grant(cur realm, perm string, addr address) string {
	rejectStraySend(cur)
	if err := book.Grant(0, cur, perm, addr); err != nil {
		panic(err)
	}
	chain.Emit("Granted", "permission", perm, "to", addr.String())
	return "granted " + perm + " to " + addr.String()
}

// Revoke removes a permission from addr. Admin only.
//
// The revoke is committed by this transaction. Any later transaction that
// reaches a gate on that permission is refused — that is the claim.
func Revoke(cur realm, perm string, addr address) string {
	rejectStraySend(cur)
	if err := book.Revoke(0, cur, perm, addr); err != nil {
		panic(err)
	}
	chain.Emit("Revoked", "permission", perm, "from", addr.String())
	return "revoked " + perm + " from " + addr.String()
}

// RevokeAll removes every permission addr holds and reports how many.
// Admin only.
func RevokeAll(cur realm, addr address) string {
	rejectStraySend(cur)
	n, err := book.RevokeAll(0, cur, addr)
	if err != nil {
		panic(err)
	}
	chain.Emit("RevokedAll", "from", addr.String(), "count", itoa(int64(n)))
	return "revoked " + itoa(int64(n)) + " permission(s) from " + addr.String()
}

// DropPermission removes a permission and every grant of it. Admin only.
func DropPermission(cur realm, perm string) string {
	rejectStraySend(cur)
	if err := book.DropPermission(0, cur, perm); err != nil {
		panic(err)
	}
	chain.Emit("PermissionDropped", "permission", perm)
	return "dropped " + perm
}

// NominateAdmin records a nominee for the admin role. Admin only. The
// handoff does not take effect until the nominee calls AcceptAdmin.
func NominateAdmin(cur realm, nominee address) string {
	rejectStraySend(cur)
	if err := book.NominateAdmin(0, cur, nominee); err != nil {
		panic(err)
	}
	chain.Emit("AdminNominated", "nominee", nominee.String())
	return "nominated " + nominee.String()
}

// CancelNomination withdraws a pending nomination. Admin only.
func CancelNomination(cur realm) string {
	rejectStraySend(cur)
	if err := book.CancelNomination(0, cur); err != nil {
		panic(err)
	}
	chain.Emit("AdminNominationCancelled")
	return "nomination cancelled"
}

// AcceptAdmin completes a pending handoff. Only the nominee may call it.
func AcceptAdmin(cur realm) string {
	rejectStraySend(cur)
	if err := book.AcceptAdmin(0, cur); err != nil {
		panic(err)
	}
	who := cur.Previous().Address()
	chain.Emit("AdminAccepted", "admin", who.String())
	return "admin is now " + who.String()
}

// --- read-only views ------------------------------------------------------
//
// None of these authorizes anything, and none of them authenticates its
// caller. They answer questions about an address (permbook consumer
// contract 3).

// Height returns the chain height this realm is reading as "now".
func Height() int64 { return runtime.ChainHeight() }

// Admin returns the book's current admin.
func Admin() string { return book.Admin().String() }

// PendingAdmin returns the nominated-but-not-yet-accepted admin, or "".
func PendingAdmin() string { return book.PendingAdmin().String() }

// Has reports whether addr holds perm. This is the primitive's core query,
// exposed verbatim so it can be checked from off-chain.
func Has(perm string, addr address) bool { return book.Has(perm, addr) }

// CanBump reports whether addr would be allowed to call Bump right now.
func CanBump(addr address) bool { return book.Has(PermBump, addr) }

// PermissionsOf returns the permissions addr holds, comma-separated in
// lexicographic order, or "" for none. Names are restricted by permbook to
// lowercase alphanumerics and underscore, so a comma can never appear in
// one and this encoding is unambiguous.
func PermissionsOf(addr address) string {
	return join(book.Permissions(addr))
}

// PermissionCount returns how many distinct permissions currently exist.
func PermissionCount() int { return book.PermissionCount() }

// Permissions returns up to MaxListed permission names, comma-separated in
// lexicographic order.
func Permissions() string {
	return join(book.PermissionNames(0, MaxListed))
}

// HolderCount returns how many addresses hold perm, or 0 if it does not
// exist.
func HolderCount(perm string) int { return book.HolderCount(perm) }

// Holders returns up to MaxListed holders of perm, comma-separated in
// sorted order.
func Holders(perm string) string {
	hs := book.Holders(perm, 0, MaxListed)
	out := ""
	for i, h := range hs {
		if i > 0 {
			out += ","
		}
		out += h.String()
	}
	return out
}

// Bumps returns how many times Bump has succeeded.
func Bumps() int64 { return bumps }

// LastBump describes the most recent successful Bump, or "none".
func LastBump() string {
	if bumps == 0 {
		return "none"
	}
	return lastBumper.String() + " at height " + itoa(lastBumpHeight)
}

// Notice returns the current public notice, or "".
func Notice() string { return notice }

// Limits reports the book's fixed limits.
func Limits() string {
	l := book.Limits()
	return "permissions=" + itoa(int64(l.MaxPermissions)) +
		" holders=" + itoa(int64(l.MaxHoldersPerPermission)) +
		" namelen=" + itoa(int64(l.MaxNameLen))
}

// --- rendering ------------------------------------------------------------

// realmPath is this realm's gnoweb prefix, used to build view links.
const realmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/permbook_demo"

// Render serves three views, selected by path.
//
//	(empty)  summary, the permission table, and the gated state
//	holders  every permission with its holders, up to MaxListed each
//	about    what this realm is and why it exists
//
// An inert realm (see init) reports that instead of rendering. Every view
// reads the book, so without this the gnoweb page would abort on a nil
// dereference — which is exactly the moment an operator needs it to say what
// is wrong. The typed read functions still abort when inert; Ready is the
// probe that answers the question without panicking.
func Render(path string) string {
	if !Ready() {
		return "# Permission demo\n\n" +
			"This realm is **inert**: init captured no deploy-time admin, so " +
			"no permission book exists. Every entrypoint aborts and nothing " +
			"runs ungated. The state is unrecoverable — redeploy to a fresh " +
			"path.\n"
	}

	switch normalizePath(path) {
	case "holders":
		return renderHeader() + renderHolders()
	case "about":
		return renderHeader() + renderAbout()
	default:
		return renderHeader() + renderPermissions() + renderState()
	}
}

func renderHeader() string {
	s := "# Permission demo\n\n"
	s += "Reference consumer for [permbook](/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/permbook).\n\n"
	s += "- height: " + itoa(runtime.ChainHeight()) + "\n"
	s += "- admin: " + sanitize.InlineText(book.Admin().String()) + "\n"
	if p := book.PendingAdmin(); p != address("") {
		s += "- pending admin: " + sanitize.InlineText(p.String()) + "\n"
	}
	s += "- permissions: " + itoa(int64(book.PermissionCount())) +
		" / " + itoa(int64(MaxPermissions)) + "\n\n"
	s += "[summary](" + realmPath + ") · "
	s += "[holders](" + realmPath + ":holders) · "
	s += "[about](" + realmPath + ":about)\n\n"
	return s
}

func renderPermissions() string {
	names := book.PermissionNames(0, MaxListed)

	s := "## Permissions\n\n"
	if len(names) == 0 {
		return s + "_none granted yet._\n\n"
	}
	s += "| permission | holders | gates |\n|---|---|---|\n"
	for _, n := range names {
		s += "| " + sanitize.InlineText(n) +
			" | " + itoa(int64(book.HolderCount(n))) +
			" | " + gateFor(n) + " |\n"
	}
	if book.PermissionCount() > len(names) {
		s += "\nShowing the first " + itoa(int64(len(names))) + " of " +
			itoa(int64(book.PermissionCount())) + ".\n"
	}
	return s + "\n"
}

// gateFor names the entrypoint a permission opens, or says it opens none.
// A permission with no gate is not a bug: the admin may grant a name this
// realm does not read, and saying so plainly is better than implying every
// permission is enforced somewhere.
func gateFor(perm string) string {
	switch perm {
	case PermBump:
		return "`Bump`"
	case PermNotice:
		return "`SetNotice`"
	default:
		return "_no entrypoint reads this_"
	}
}

func renderHolders() string {
	names := book.PermissionNames(0, MaxListed)

	s := "## Holders\n\n"
	if len(names) == 0 {
		return s + "_none granted yet._\n\n"
	}
	for _, n := range names {
		total := book.HolderCount(n)
		s += "**" + sanitize.InlineText(n) + "** — " + itoa(int64(total)) + " holder(s)\n\n"
		for _, h := range book.Holders(n, 0, MaxListed) {
			s += "- " + sanitize.InlineText(h.String()) + "\n"
		}
		if total > MaxListed {
			s += "\n_Showing the first " + itoa(int64(MaxListed)) + " of " +
				itoa(int64(total)) + "._\n"
		}
		s += "\n"
	}
	return s
}

func renderState() string {
	s := "## Gated state\n\n"
	s += "- bumps: " + itoa(bumps) + "\n"
	s += "- last bump: "
	if bumps == 0 {
		s += "_none_\n"
	} else {
		s += sanitize.InlineText(lastBumper.String()) +
			" at height " + itoa(lastBumpHeight) + "\n"
	}
	s += "\n### Notice\n\n"
	if notice == "" {
		return s + "_none set._\n\n"
	}
	// Blockquote, not InlineText: the slot IS a blockquote, so the helper
	// whose contract covers the slot is the one to use. Blockquote emits
	// its own envelope, so no manual "> " prefix here.
	s += sanitize.Blockquote(notice)
	s += "set by " + sanitize.InlineText(noticeAuthor.String()) +
		" at height " + itoa(noticeSetAtBlock) + "\n\n"
	return s
}

func renderAbout() string {
	return "## About\n\n" +
		"Two permission-gated entrypoints, deliberately trivial so that the " +
		"only interesting thing about them is the gate:\n\n" +
		"- `Bump` requires `" + PermBump + "`\n" +
		"- `SetNotice` requires `" + PermNotice + "`\n\n" +
		"The deployer is the book's admin and is the only account that may " +
		"grant or revoke. **Holding a permission confers no authority over " +
		"the book**: a holder cannot grant, cannot revoke, and cannot " +
		"nominate an admin.\n\n" +
		"The claim this realm makes falsifiable is that a permission revoked " +
		"in one transaction is refused in the next. Grant `" + PermBump +
		"`, call `Bump` — it succeeds. Revoke, call `Bump` again — it " +
		"aborts. A pure package cannot show that; only a realm called across " +
		"several transactions can.\n\n" +
		"This realm holds no coins and imports no banker. Every crossing " +
		"entrypoint rejects attached coins, and the read views are " +
		"non-crossing so no transaction can attach coins to one.\n\n" +
		"- max permissions: " + itoa(int64(MaxPermissions)) + "\n" +
		"- max holders per permission: " + itoa(int64(MaxHolders)) + "\n" +
		"- max permission name length: " + itoa(int64(MaxNameLen)) + "\n" +
		"- max notice length: " + itoa(int64(MaxNoticeLen)) + " bytes\n"
}

// normalizePath reduces a gnoweb render path to a bare view name, so "",
// "/", "holders" and "/holders/" all select the same view.
func normalizePath(path string) string {
	for len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	for len(path) > 0 && path[len(path)-1] == '/' {
		path = path[:len(path)-1]
	}
	return path
}

// --- helpers --------------------------------------------------------------

// join comma-separates names. Safe because permbook restricts permission
// names to lowercase alphanumerics and underscore, so no name can contain
// the delimiter.
func join(names []string) string {
	out := ""
	for i, n := range names {
		if i > 0 {
			out += ","
		}
		out += n
	}
	return out
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
