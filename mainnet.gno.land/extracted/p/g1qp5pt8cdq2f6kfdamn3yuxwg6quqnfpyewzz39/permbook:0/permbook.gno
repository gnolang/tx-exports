// Package permbook is a bounded, authorization-carrying facade over
// gno.land/p/nt/groups/v0. It lets a realm define named permissions, grant
// them to addresses, revoke them, and ask "does this address currently hold
// this permission" without iterating anything.
//
// It holds no coins, imports no banker, stores no callbacks, and owns no
// package-level state. The importing realm allocates a *Book and keeps it
// private.
//
// # What this package adds, and what it does not
//
// It adds exactly four things to groups, and deliberately nothing else:
//
//  1. an ADMIN bound to the book, with a two-step handoff;
//  2. BOUNDS on permission count, holders per permission, and name shape;
//  3. permission semantics instead of membership semantics — no base set, no
//     metadata slot, and an empty permission is pruned rather than kept;
//  4. a cross-realm surface that is safe by CONSTRUCTION — the *groups.Group
//     is unexported and no method returns a mutable handle to it.
//
// Everything else — the B+-tree registry, the member sets, ordered
// iteration, the readonly views — comes from groups. This package writes no
// data-structure code.
//
// # The query
//
//	if !book.Has("withdraw", who) {
//		panic("not authorized")
//	}
//
// Has costs two independent B+-tree descents: O(log P) to find the
// permission, O(log H) to find the holder. It is NOT a function of how many
// permissions `who` already holds. That matters: every other named-permission
// implementation surveyed answers this by iterating the subject's
// permissions, which makes the most-privileged address the most expensive to
// check — the wrong asymptotic for an authorization check on a hot path.
//
// # Authorization
//
// Mutators take (_ int, rlm realm) and identify the principal as
// rlm.Previous().Address(), after asserting rlm.IsCurrent(). The consuming
// realm threads its own cur:
//
//	func Grant(cur realm, perm string, addr address) {
//		if err := book.Grant(0, cur, perm, addr); err != nil {
//			panic(err)
//		}
//	}
//
// IsCurrent() rejects a stale or stashed realm value, so a hostile realm
// cannot replay an old cur to impersonate the admin. This is the same shape
// as p/nt/ownable/v0 and p/nt/ownable/v0/exts/authorizable.
//
// # Lifecycle of a permission
//
// A permission comes into existence on its first grant and ceases to exist
// when its last holder is revoked. There is no create step and no reserved
// name. Has returns false either way, so the distinction is invisible to a
// caller and the book does not accumulate empty buckets.
//
//	(absent) ──Grant──> held by 1..MaxHoldersPerPermission ──Revoke last──> (absent)
//	                              │
//	                              └── DropPermission ──> (absent)
//
// # Admin handoff is two-step
//
// NominateAdmin records a nominee; only AcceptAdmin, called by that nominee,
// moves the admin. A one-step transfer to a well-formed-but-unowned address
// is permanently fatal — address.IsValid only checks bech32 form, so a
// mistyped address passes validation and leaves a book nobody can ever grant
// or revoke on again. This is the Y4 finding from the audit of Cosmic Bull's
// own r/permission_registry, carried forward.
//
// # Consumer contract — the parts this package CANNOT enforce
//
//  1. THREAD A LIVE cur. rlm.IsCurrent() proves the realm value came from a
//     live crossing frame, and rlm.Previous().Address() is then the principal
//     that crossed into your realm. A consumer that wraps a permbook mutator
//     in a NON-crossing exported helper resolves its importer's caller
//     instead of its importer — Class-2 designation forgery, in the consumer.
//     Call permbook mutators from your own crossing entrypoints, passing that
//     entrypoint's own cur.
//
//  2. DO NOT LEAK THE *Book. No method here returns a mutable handle, but a
//     consumer that exports its *Book — or returns it from a function
//     reachable by another realm — hands out every mutator on it, and
//     borrow rule #2 commits those writes under YOUR realm's authority. Keep
//     it in an unexported package-level variable.
//
//  3. Has ANSWERS ABOUT AN ADDRESS, NOT ABOUT YOUR CALLER. It performs no
//     authentication. Derive the address from your own crossing entrypoint's
//     cur.Previous().Address() and pass it in.
//
//  4. CHOOSE LIMITS DELIBERATELY. They are fixed for the life of a Book. A
//     consumer that needs different bounds later must allocate a second Book;
//     nothing here migrates state between them.
//
// # Note on the groups base set
//
// A groups.Group carries a base address set alongside its named roles. This
// package never writes to it, so it is provably empty for any Book, and
// "in the base set" can never mean "holds a permission".
package permbook

import (
	"errors"

	"gno.land/p/nt/groups/v0"
)

// Ceilings on what Limits may be configured to. They bound worst-case gas
// and storage for any Book, however the consumer configures it.
//
// MaxPermissionsCeiling is the one that bounds GAS rather than merely
// storage. Three operations walk every permission in the book at O(P log H)
// — Permissions, HasAny, and RevokeAll — and this ceiling is what bounds
// them. Everything else is logarithmic or paginated; see each method's own
// doc for its cost, which is authoritative.
//
// In particular HasAny is NOT a cheap variant of Has. Has is two tree
// descents; HasAny is a full walk of the registry. Do not put HasAny on a
// hot authorization path or inside a per-item render loop.
//
// These ceilings are not the objection this package raises against a shared
// registry. A shared registry's caps are rivalrous and unraisable because
// one immutable realm holds every tenant's state; here a consumer that needs
// more simply allocates another Book in its own realm, at no cost to anyone
// else.
const (
	MaxPermissionsCeiling = 256
	MaxHoldersCeiling     = 10000
	MaxNameLenCeiling     = 64
)

// Default limits, used by NewDefault.
const (
	DefaultMaxPermissions          = 64
	DefaultMaxHoldersPerPermission = 1024
	DefaultMaxNameLen              = 32
)

var (
	ErrUnauthorized      = errors.New("permbook: caller is not the admin")
	ErrNotLiveRealm      = errors.New("permbook: rlm is not the caller's live cur")
	ErrInvalidAddress    = errors.New("permbook: invalid address")
	ErrInvalidName       = errors.New("permbook: permission name must be 1..MaxNameLen chars, lowercase alphanumeric and underscore only")
	ErrInvalidLimits     = errors.New("permbook: limits must be positive and within the package ceilings")
	ErrAlreadyGranted    = errors.New("permbook: address already holds this permission")
	ErrNotGranted        = errors.New("permbook: address does not hold this permission")
	ErrPermissionLimit   = errors.New("permbook: permission limit reached for this book")
	ErrHolderLimit       = errors.New("permbook: holder limit reached for this permission")
	ErrNoPendingAdmin    = errors.New("permbook: no pending admin nomination")
	ErrNotPendingAdmin   = errors.New("permbook: caller is not the pending admin")
	ErrSameAdmin         = errors.New("permbook: nominee is already the admin")
	ErrUnknownPermission = errors.New("permbook: no such permission")
)

// Limits are fixed at construction and never change for the life of a Book.
type Limits struct {
	// MaxPermissions bounds how many distinct permission names may exist at
	// once. Because Permissions and RevokeAll walk all of them, this bounds
	// gas, not just storage.
	MaxPermissions int

	// MaxHoldersPerPermission bounds how many addresses may hold any one
	// permission. No operation iterates holders unpaginated, so this bounds
	// storage rather than gas.
	MaxHoldersPerPermission int

	// MaxNameLen bounds permission-name length.
	MaxNameLen int
}

// DefaultLimits returns the limits used by NewDefault.
func DefaultLimits() Limits {
	return Limits{
		MaxPermissions:          DefaultMaxPermissions,
		MaxHoldersPerPermission: DefaultMaxHoldersPerPermission,
		MaxNameLen:              DefaultMaxNameLen,
	}
}

func (l Limits) valid() bool {
	return l.MaxPermissions > 0 && l.MaxPermissions <= MaxPermissionsCeiling &&
		l.MaxHoldersPerPermission > 0 && l.MaxHoldersPerPermission <= MaxHoldersCeiling &&
		l.MaxNameLen > 0 && l.MaxNameLen <= MaxNameLenCeiling
}

// Book is a bounded set of named permissions with an admin. The zero value
// is not usable; construct with New or NewDefault.
//
// SECURITY: keep a *Book in an unexported variable. It is the capability.
// Every mutator on it is gated on the admin, but a realm that receives the
// pointer itself can invoke those mutators, and borrow rule #2 commits the
// writes under the ALLOCATING realm's authority.
type Book struct {
	g            *groups.Group
	admin        address
	pendingAdmin address
	lim          Limits
}

// New constructs an empty Book owned by admin, with explicit limits.
func New(admin address, lim Limits) (*Book, error) {
	if !admin.IsValid() {
		return nil, ErrInvalidAddress
	}
	if !lim.valid() {
		return nil, ErrInvalidLimits
	}
	return &Book{
		g:     groups.NewGroup(),
		admin: admin,
		lim:   lim,
	}, nil
}

// NewDefault constructs an empty Book owned by admin, with DefaultLimits.
func NewDefault(admin address) (*Book, error) {
	return New(admin, DefaultLimits())
}

// --- authorization ---

// principal returns the address that crossed into the caller's realm, after
// proving rlm is a live crossing frame rather than a stashed value.
func principal(_ int, rlm realm) (address, error) {
	if !rlm.IsCurrent() {
		return address(""), ErrNotLiveRealm
	}
	return rlm.Previous().Address(), nil
}

// assertAdmin resolves the principal from rlm and requires it to be the
// book's admin.
func (b *Book) assertAdmin(_ int, rlm realm) error {
	who, err := principal(0, rlm)
	if err != nil {
		return err
	}
	if who != b.admin {
		return ErrUnauthorized
	}
	return nil
}

// --- grant and revoke ---

// Grant gives addr the named permission. Admin only.
//
// The permission is created if it does not exist. Granting a permission the
// address already holds returns ErrAlreadyGranted rather than silently
// succeeding, so a consumer cannot mistake a no-op for a state change.
func (b *Book) Grant(_ int, rlm realm, perm string, addr address) error {
	if err := b.assertAdmin(0, rlm); err != nil {
		return err
	}
	if !b.validName(perm) {
		return ErrInvalidName
	}
	if !addr.IsValid() {
		return ErrInvalidAddress
	}

	r, found := b.g.GetRole(perm)
	if !found {
		if b.g.RoleCount() >= b.lim.MaxPermissions {
			return ErrPermissionLimit
		}
		var err error
		r, err = b.g.AddRole(perm)
		if err != nil {
			return err
		}
	}

	members := r.Members()
	if members.Has(addr) {
		return ErrAlreadyGranted
	}
	if members.Size() >= b.lim.MaxHoldersPerPermission {
		// No rollback is needed here, and adding one would be dead code.
		//
		// Reaching this branch requires Size() >= MaxHoldersPerPermission,
		// and Limits.valid guarantees MaxHoldersPerPermission >= 1, so
		// Size() >= 1. A permission created moments ago above has Size() 0
		// and therefore cannot reach this branch at all. So the permission
		// this rejects always pre-existed with holders, and returning leaves
		// no orphan empty bucket occupying a MaxPermissions slot.
		//
		// That argument depends on Limits.valid rejecting a zero holder
		// limit. If that ever changes, this branch needs an undo.
		return ErrHolderLimit
	}

	members.Add(addr)
	return nil
}

// Revoke removes the named permission from addr. Admin only.
//
// Revoking the last holder removes the permission itself, freeing its slot
// against MaxPermissions. Has reports false either way, so this is invisible
// to a caller and keeps the book from accumulating empty buckets.
func (b *Book) Revoke(_ int, rlm realm, perm string, addr address) error {
	if err := b.assertAdmin(0, rlm); err != nil {
		return err
	}
	if !b.revokeOne(perm, addr) {
		return ErrNotGranted
	}
	return nil
}

// revokeOne removes addr from perm and prunes the permission if it is left
// empty. Reports whether addr actually held it. No authorization: every
// caller is inside this package and has already gated on the admin.
func (b *Book) revokeOne(perm string, addr address) bool {
	r, found := b.g.GetRole(perm)
	if !found {
		return false
	}
	members := r.Members()
	if !members.Remove(addr) {
		return false
	}
	if members.Size() == 0 {
		b.g.RemoveRole(perm)
	}
	return true
}

// RevokeAll removes addr from every permission in the book and reports how
// many were removed. Admin only.
//
// Cost is O(P log H) in the book's permission count — bounded by
// MaxPermissions, which is why that limit has a ceiling.
//
// Implementation note: the permission names are collected FIRST, into a
// value slice, and the registry is mutated only after that walk returns.
// groups documents that mutating the role registry mid-iteration can panic
// and abort the transaction.
func (b *Book) RevokeAll(_ int, rlm realm, addr address) (int, error) {
	if err := b.assertAdmin(0, rlm); err != nil {
		return 0, err
	}
	names := b.g.RolesContaining(addr)
	n := 0
	for _, perm := range names {
		if b.revokeOne(perm, addr) {
			n++
		}
	}
	return n, nil
}

// DropPermission removes a permission and every grant of it. Admin only.
//
// Cost is O(log P): groups discards the whole member set with the role and
// does not walk it, so this is safe for a permission with many holders.
func (b *Book) DropPermission(_ int, rlm realm, perm string) error {
	if err := b.assertAdmin(0, rlm); err != nil {
		return err
	}
	if !b.g.RemoveRole(perm) {
		return ErrUnknownPermission
	}
	return nil
}

// --- admin handoff ---

// NominateAdmin records a nominee for the admin role. Admin only. The
// handoff does NOT take effect until the nominee calls AcceptAdmin, and a
// nomination may be withdrawn with CancelNomination until then.
func (b *Book) NominateAdmin(_ int, rlm realm, nominee address) error {
	if err := b.assertAdmin(0, rlm); err != nil {
		return err
	}
	if !nominee.IsValid() {
		return ErrInvalidAddress
	}
	if nominee == b.admin {
		return ErrSameAdmin
	}
	b.pendingAdmin = nominee
	return nil
}

// CancelNomination withdraws a pending nomination. Admin only.
func (b *Book) CancelNomination(_ int, rlm realm) error {
	if err := b.assertAdmin(0, rlm); err != nil {
		return err
	}
	if b.pendingAdmin == address("") {
		return ErrNoPendingAdmin
	}
	b.pendingAdmin = address("")
	return nil
}

// AcceptAdmin completes a pending handoff. Only the nominee may call it.
func (b *Book) AcceptAdmin(_ int, rlm realm) error {
	who, err := principal(0, rlm)
	if err != nil {
		return err
	}
	if b.pendingAdmin == address("") {
		return ErrNoPendingAdmin
	}
	if who != b.pendingAdmin {
		return ErrNotPendingAdmin
	}
	b.admin = who
	b.pendingAdmin = address("")
	return nil
}

// --- queries ---
//
// Queries perform NO caller authentication. They answer questions about an
// address, not about your caller. See consumer-contract clause 3.

// Has reports whether addr currently holds the named permission.
//
// Two B+-tree descents, O(log P + log H). Independent of how many other
// permissions addr holds. Never panics; unknown permissions report false.
func (b *Book) Has(perm string, addr address) bool {
	r, found := b.g.GetRole(perm)
	if !found {
		return false
	}
	return r.Members().Has(addr)
}

// HasAny reports whether addr holds any permission at all. O(P log H).
func (b *Book) HasAny(addr address) bool {
	return b.g.HasAny(addr)
}

// Permissions returns the names addr holds, in lexicographic order, or nil.
// O(P log H) — bounded by MaxPermissions.
func (b *Book) Permissions(addr address) []string {
	return b.g.RolesContaining(addr)
}

// PermissionCount returns how many distinct permissions currently exist.
func (b *Book) PermissionCount() int {
	return b.g.RoleCount()
}

// PermissionNames returns up to count permission names in lexicographic
// order, starting at offset. Paginated so the caller, not the book, chooses
// how much work a single call does.
func (b *Book) PermissionNames(offset, count int) []string {
	if count <= 0 {
		return nil
	}
	var out []string
	b.g.IterateRoles(offset, count, func(rr *groups.ReadonlyRole) bool {
		out = append(out, rr.Name())
		return false
	})
	return out
}

// HolderCount returns how many addresses hold the named permission, or 0 if
// it does not exist.
func (b *Book) HolderCount(perm string) int {
	r, found := b.g.GetRole(perm)
	if !found {
		return 0
	}
	return r.Members().Size()
}

// Holders returns up to count holders of the named permission, in sorted
// order, starting at offset. Paginated for the same reason as
// PermissionNames. Returns nil for an unknown permission.
func (b *Book) Holders(perm string, offset, count int) []address {
	if count <= 0 {
		return nil
	}
	r, found := b.g.GetRole(perm)
	if !found {
		return nil
	}
	var out []address
	r.Members().IterateByOffset(offset, count, func(a address) bool {
		out = append(out, a)
		return false
	})
	return out
}

// Admin returns the book's current admin.
func (b *Book) Admin() address {
	return b.admin
}

// PendingAdmin returns the nominated-but-not-yet-accepted admin, or the
// empty address if there is no pending nomination.
func (b *Book) PendingAdmin() address {
	return b.pendingAdmin
}

// IsAdmin reports whether addr is the book's admin.
func (b *Book) IsAdmin(addr address) bool {
	return addr == b.admin
}

// Limits returns the book's fixed limits.
func (b *Book) Limits() Limits {
	return b.lim
}

// --- names ---

// validName restricts permission names to lowercase alphanumerics and
// underscores, within the book's MaxNameLen.
//
// Beyond hygiene this is a security property: permission names end up in
// composite trust decisions and in rendered output, so no delimiter,
// whitespace, or markdown character may enter one.
func (b *Book) validName(name string) bool {
	if name == "" || len(name) > b.lim.MaxNameLen {
		return false
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}
