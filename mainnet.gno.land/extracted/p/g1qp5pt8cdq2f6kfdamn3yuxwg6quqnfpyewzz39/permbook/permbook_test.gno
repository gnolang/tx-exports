package permbook

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	admin   = testutils.TestAddress("permadmin")
	nominee = testutils.TestAddress("nominee")
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	mallory = testutils.TestAddress("mallory")
)

// --- test harness ---
//
// permbook's mutators identify their principal as rlm.Previous().Address()
// after proving rlm.IsCurrent(). A test function's own `cur` is current but
// has no previous frame — Previous() panics with "cannot seek beyond origin
// caller override". So every mutating call is made from inside a real
// crossing frame, entered with cross(cur), exactly as p/nt/ownable/v0's own
// tests do.
//
// testing.SetRealm(testing.NewUserRealm(addr)) sets the current realm to a
// user realm for addr, so the next crossing frame has
// Previous().Address() == addr — the principal the mutator authorizes
// against. It is written out at every call site on purpose: the override is
// scoped to the frame that installs it, so wrapping it in a helper makes it
// pop the moment the helper returns and the principal comes back empty.

func grant(cur realm, b *Book, perm string, addr address) error {
	var err error
	func(cur realm) { err = b.Grant(0, cur, perm, addr) }(cross(cur))
	return err
}

func revoke(cur realm, b *Book, perm string, addr address) error {
	var err error
	func(cur realm) { err = b.Revoke(0, cur, perm, addr) }(cross(cur))
	return err
}

func revokeAll(cur realm, b *Book, addr address) (int, error) {
	var (
		n   int
		err error
	)
	func(cur realm) { n, err = b.RevokeAll(0, cur, addr) }(cross(cur))
	return n, err
}

func dropPerm(cur realm, b *Book, perm string) error {
	var err error
	func(cur realm) { err = b.DropPermission(0, cur, perm) }(cross(cur))
	return err
}

func nominate(cur realm, b *Book, addr address) error {
	var err error
	func(cur realm) { err = b.NominateAdmin(0, cur, addr) }(cross(cur))
	return err
}

func cancelNom(cur realm, b *Book) error {
	var err error
	func(cur realm) { err = b.CancelNomination(0, cur) }(cross(cur))
	return err
}

func acceptAdmin(cur realm, b *Book) error {
	var err error
	func(cur realm) { err = b.AcceptAdmin(0, cur) }(cross(cur))
	return err
}

// newBook builds a book for tests.
func newBook(t *testing.T, owner address) *Book {
	t.Helper()
	b, err := NewDefault(owner)
	uassert.NoError(t, err)
	if b == nil {
		t.Fatal("NewDefault returned nil book")
	}
	return b
}

// --- construction ---

func TestNewDefault(cur realm, t *testing.T) {
	b := newBook(t, admin)
	uassert.Equal(t, admin.String(), b.Admin().String())
	uassert.Equal(t, "", b.PendingAdmin().String())
	uassert.Equal(t, 0, b.PermissionCount())
	uassert.True(t, b.IsAdmin(admin))
	uassert.False(t, b.IsAdmin(alice))

	l := b.Limits()
	uassert.Equal(t, DefaultMaxPermissions, l.MaxPermissions)
	uassert.Equal(t, DefaultMaxHoldersPerPermission, l.MaxHoldersPerPermission)
	uassert.Equal(t, DefaultMaxNameLen, l.MaxNameLen)
}

func TestNewRejectsInvalidAdmin(cur realm, t *testing.T) {
	b, err := NewDefault(address(""))
	uassert.ErrorIs(t, err, ErrInvalidAddress)
	uassert.True(t, b == nil)

	b, err = NewDefault(address("not-a-bech32-address"))
	uassert.ErrorIs(t, err, ErrInvalidAddress)
	uassert.True(t, b == nil)
}

func TestNewRejectsInvalidLimits(cur realm, t *testing.T) {
	cases := []Limits{
		{MaxPermissions: 0, MaxHoldersPerPermission: 10, MaxNameLen: 10},
		{MaxPermissions: 10, MaxHoldersPerPermission: 0, MaxNameLen: 10},
		{MaxPermissions: 10, MaxHoldersPerPermission: 10, MaxNameLen: 0},
		{MaxPermissions: -1, MaxHoldersPerPermission: 10, MaxNameLen: 10},
		{MaxPermissions: MaxPermissionsCeiling + 1, MaxHoldersPerPermission: 10, MaxNameLen: 10},
		{MaxPermissions: 10, MaxHoldersPerPermission: MaxHoldersCeiling + 1, MaxNameLen: 10},
		{MaxPermissions: 10, MaxHoldersPerPermission: 10, MaxNameLen: MaxNameLenCeiling + 1},
	}
	for i, lim := range cases {
		b, err := New(admin, lim)
		uassert.ErrorIs(t, err, ErrInvalidLimits)
		if b != nil {
			t.Errorf("case %d: expected nil book", i)
		}
	}
}

func TestNewAcceptsCeilingLimits(cur realm, t *testing.T) {
	b, err := New(admin, Limits{
		MaxPermissions:          MaxPermissionsCeiling,
		MaxHoldersPerPermission: MaxHoldersCeiling,
		MaxNameLen:              MaxNameLenCeiling,
	})
	uassert.NoError(t, err)
	uassert.Equal(t, MaxPermissionsCeiling, b.Limits().MaxPermissions)
}

// --- grant / query / revoke, the core objective ---

func TestGrantThenHas(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.False(t, b.Has("withdraw", alice))
	uassert.NoError(t, grant(cur, b, "withdraw", alice))
	uassert.True(t, b.Has("withdraw", alice))

	// granting to alice does not grant to bob
	uassert.False(t, b.Has("withdraw", bob))
	// nor does it create any other permission
	uassert.False(t, b.Has("deposit", alice))
	uassert.Equal(t, 1, b.PermissionCount())
	uassert.Equal(t, 1, b.HolderCount("withdraw"))
}

func TestRevokeRemovesTheGrant(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "withdraw", alice))
	uassert.NoError(t, grant(cur, b, "withdraw", bob))
	uassert.True(t, b.Has("withdraw", alice))

	uassert.NoError(t, revoke(cur, b, "withdraw", alice))
	uassert.False(t, b.Has("withdraw", alice))
	// bob is untouched
	uassert.True(t, b.Has("withdraw", bob))
	uassert.Equal(t, 1, b.HolderCount("withdraw"))
	// the permission still exists because bob holds it
	uassert.Equal(t, 1, b.PermissionCount())
}

func TestRevokingLastHolderPrunesThePermission(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "withdraw", alice))
	uassert.Equal(t, 1, b.PermissionCount())

	uassert.NoError(t, revoke(cur, b, "withdraw", alice))
	// the empty bucket is gone, so it does not consume a MaxPermissions slot
	uassert.Equal(t, 0, b.PermissionCount())
	uassert.Equal(t, 0, b.HolderCount("withdraw"))
	// and the query is still well-defined
	uassert.False(t, b.Has("withdraw", alice))
}

func TestGrantAfterPruneWorks(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "withdraw", alice))
	uassert.NoError(t, revoke(cur, b, "withdraw", alice))
	// re-creating a pruned permission must not collide with a stale bucket
	uassert.NoError(t, grant(cur, b, "withdraw", bob))
	uassert.True(t, b.Has("withdraw", bob))
	uassert.False(t, b.Has("withdraw", alice))
	uassert.Equal(t, 1, b.PermissionCount())
}

func TestDuplicateGrantIsAnError(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "withdraw", alice))
	uassert.ErrorIs(t, grant(cur, b, "withdraw", alice), ErrAlreadyGranted)
	// the failed duplicate did not grow state
	uassert.Equal(t, 1, b.HolderCount("withdraw"))
}

func TestRevokeWhatIsNotHeld(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	// unknown permission
	uassert.ErrorIs(t, revoke(cur, b, "nope", alice), ErrNotGranted)
	// known permission, wrong holder
	uassert.NoError(t, grant(cur, b, "withdraw", alice))
	uassert.ErrorIs(t, revoke(cur, b, "withdraw", bob), ErrNotGranted)
	uassert.True(t, b.Has("withdraw", alice))
}

func TestMultiplePermissionsAreIndependent(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.NoError(t, grant(cur, b, "write", alice))
	uassert.NoError(t, grant(cur, b, "write", bob))

	uassert.True(t, b.Has("read", alice))
	uassert.True(t, b.Has("write", alice))
	uassert.False(t, b.Has("read", bob))
	uassert.True(t, b.Has("write", bob))
	uassert.Equal(t, 2, b.PermissionCount())

	uassert.NoError(t, revoke(cur, b, "write", alice))
	// revoking one permission leaves the other intact
	uassert.True(t, b.Has("read", alice))
	uassert.False(t, b.Has("write", alice))
	uassert.True(t, b.Has("write", bob))
}

// --- authorization ---

func TestNonAdminCannotGrant(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(mallory))
	b := newBook(t, admin)

	uassert.ErrorIs(t, grant(cur, b, "withdraw", mallory), ErrUnauthorized)
	uassert.False(t, b.Has("withdraw", mallory))
	uassert.Equal(t, 0, b.PermissionCount())
}

func TestNonAdminCannotRevoke(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)
	uassert.NoError(t, grant(cur, b, "withdraw", alice))

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.ErrorIs(t, revoke(cur, b, "withdraw", alice), ErrUnauthorized)
	uassert.True(t, b.Has("withdraw", alice))
}

// A holder of a permission has no authority over the book. This is the
// property that p/thox/accesscontrol loses by exporting Role.Holders and
// returning *Role: there, any holder can self-grant.
func TestHolderIsNotAdmin(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)
	uassert.NoError(t, grant(cur, b, "withdraw", alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.ErrorIs(t, grant(cur, b, "withdraw", mallory), ErrUnauthorized)
	uassert.ErrorIs(t, revoke(cur, b, "withdraw", alice), ErrUnauthorized)
	uassert.ErrorIs(t, dropPerm(cur, b, "withdraw"), ErrUnauthorized)
	uassert.ErrorIs(t, nominate(cur, b, alice), ErrUnauthorized)
	_, err := revokeAll(cur, b, alice)
	uassert.ErrorIs(t, err, ErrUnauthorized)

	uassert.False(t, b.Has("withdraw", mallory))
	uassert.True(t, b.Has("withdraw", alice))
	uassert.Equal(t, admin.String(), b.Admin().String())
}

func TestNonAdminCannotDropOrRevokeAll(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)
	uassert.NoError(t, grant(cur, b, "a", alice))
	uassert.NoError(t, grant(cur, b, "b", alice))

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.ErrorIs(t, dropPerm(cur, b, "a"), ErrUnauthorized)
	n, err := revokeAll(cur, b, alice)
	uassert.ErrorIs(t, err, ErrUnauthorized)
	uassert.Equal(t, 0, n)
	uassert.Equal(t, 2, b.PermissionCount())
}

// --- name validation ---

func TestInvalidPermissionNames(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	bad := []string{
		"",           // empty
		"Withdraw",   // uppercase
		"with draw",  // space
		"with-draw",  // hyphen
		"with.draw",  // dot
		"with/draw",  // path separator
		"with,draw",  // comma — a delimiter in rendered lists
		"[link](x)",  // markdown
		"with\ndraw", // newline
		"withdraw!",  // punctuation
		"wíthdraw",   // non-ascii
	}
	for _, name := range bad {
		uassert.ErrorIs(t, grant(cur, b, name, alice), ErrInvalidName)
	}
	uassert.Equal(t, 0, b.PermissionCount())

	good := []string{"a", "withdraw", "with_draw", "perm2", "_leading", "trailing_"}
	for _, name := range good {
		uassert.NoError(t, grant(cur, b, name, alice))
	}
	uassert.Equal(t, len(good), b.PermissionCount())
}

func TestNameLengthBound(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b, err := New(admin, Limits{MaxPermissions: 8, MaxHoldersPerPermission: 8, MaxNameLen: 4})
	uassert.NoError(t, err)

	uassert.NoError(t, grant(cur, b, "abcd", alice))
	uassert.ErrorIs(t, grant(cur, b, "abcde", alice), ErrInvalidName)
	uassert.Equal(t, 1, b.PermissionCount())
}

func TestGrantRejectsInvalidAddress(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.ErrorIs(t, grant(cur, b, "withdraw", address("")), ErrInvalidAddress)
	uassert.ErrorIs(t, grant(cur, b, "withdraw", address("g1nonsense")), ErrInvalidAddress)
	// a rejected grant must not have created the permission bucket
	uassert.Equal(t, 0, b.PermissionCount())
}

// --- bounds ---

func TestPermissionLimit(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b, err := New(admin, Limits{MaxPermissions: 3, MaxHoldersPerPermission: 8, MaxNameLen: 16})
	uassert.NoError(t, err)

	uassert.NoError(t, grant(cur, b, "p1", alice))
	uassert.NoError(t, grant(cur, b, "p2", alice))
	uassert.NoError(t, grant(cur, b, "p3", alice))
	uassert.ErrorIs(t, grant(cur, b, "p4", alice), ErrPermissionLimit)
	uassert.Equal(t, 3, b.PermissionCount())

	// granting an EXISTING permission to a new address is not blocked by the
	// permission limit
	uassert.NoError(t, grant(cur, b, "p1", bob))

	// freeing a slot re-opens it
	uassert.NoError(t, dropPerm(cur, b, "p3"))
	uassert.NoError(t, grant(cur, b, "p4", alice))
	uassert.Equal(t, 3, b.PermissionCount())
}

func TestHolderLimit(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b, err := New(admin, Limits{MaxPermissions: 4, MaxHoldersPerPermission: 2, MaxNameLen: 16})
	uassert.NoError(t, err)

	uassert.NoError(t, grant(cur, b, "p", alice))
	uassert.NoError(t, grant(cur, b, "p", bob))
	uassert.ErrorIs(t, grant(cur, b, "p", mallory), ErrHolderLimit)
	uassert.Equal(t, 2, b.HolderCount("p"))
	uassert.False(t, b.Has("p", mallory))

	// a revoke frees a slot
	uassert.NoError(t, revoke(cur, b, "p", alice))
	uassert.NoError(t, grant(cur, b, "p", mallory))
	uassert.True(t, b.Has("p", mallory))
}

// A rejected grant must leave no bucket behind that occupies a
// MaxPermissions slot without holding anything.
//
// Two rejection routes exist and they are NOT the same case. A holder-limit
// rejection can only happen on a permission that already had holders, so
// nothing was created to clean up — Grant documents that argument where it
// returns ErrHolderLimit. An invalid-name or invalid-address rejection
// happens before any bucket is created. This asserts the invariant on both
// routes rather than on a branch.
func TestFailedGrantLeavesNoEmptyBucket(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b, err := New(admin, Limits{MaxPermissions: 2, MaxHoldersPerPermission: 1, MaxNameLen: 16})
	uassert.NoError(t, err)

	// route 1: holder limit, on a permission that already has its holder
	uassert.NoError(t, grant(cur, b, "p1", alice))
	uassert.ErrorIs(t, grant(cur, b, "p1", bob), ErrHolderLimit)
	// p1 still has exactly its one holder and no second bucket appeared
	uassert.Equal(t, 1, b.PermissionCount())
	uassert.Equal(t, 1, b.HolderCount("p1"))
	uassert.True(t, b.Has("p1", alice))
	uassert.False(t, b.Has("p1", bob))

	// route 2: a rejection that happens before creation. The one free slot
	// is still free afterwards, which is what proves nothing was consumed.
	uassert.ErrorIs(t, grant(cur, b, "BAD", alice), ErrInvalidName)
	uassert.ErrorIs(t, grant(cur, b, "p2", address("")), ErrInvalidAddress)
	uassert.Equal(t, 1, b.PermissionCount())
	uassert.NoError(t, grant(cur, b, "p2", alice))
	uassert.Equal(t, 2, b.PermissionCount())
}

// --- RevokeAll and DropPermission ---

func TestRevokeAll(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.NoError(t, grant(cur, b, "write", alice))
	uassert.NoError(t, grant(cur, b, "admin_panel", alice))
	uassert.NoError(t, grant(cur, b, "read", bob))

	n, err := revokeAll(cur, b, alice)
	uassert.NoError(t, err)
	uassert.Equal(t, 3, n)

	uassert.False(t, b.HasAny(alice))
	uassert.False(t, b.Has("read", alice))
	uassert.False(t, b.Has("write", alice))
	uassert.False(t, b.Has("admin_panel", alice))

	// bob is untouched, and "read" survives because he still holds it
	uassert.True(t, b.Has("read", bob))
	// "write" and "admin_panel" were emptied and therefore pruned
	uassert.Equal(t, 1, b.PermissionCount())
}

func TestRevokeAllOnAddressWithNothing(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)
	uassert.NoError(t, grant(cur, b, "read", bob))

	n, err := revokeAll(cur, b, alice)
	uassert.NoError(t, err)
	uassert.Equal(t, 0, n)
	uassert.True(t, b.Has("read", bob))
}

func TestDropPermission(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.NoError(t, grant(cur, b, "read", bob))
	uassert.NoError(t, grant(cur, b, "write", alice))

	uassert.NoError(t, dropPerm(cur, b, "read"))
	uassert.False(t, b.Has("read", alice))
	uassert.False(t, b.Has("read", bob))
	uassert.Equal(t, 0, b.HolderCount("read"))
	// the other permission survives
	uassert.True(t, b.Has("write", alice))
	uassert.Equal(t, 1, b.PermissionCount())

	uassert.ErrorIs(t, dropPerm(cur, b, "read"), ErrUnknownPermission)
	uassert.ErrorIs(t, dropPerm(cur, b, "never_existed"), ErrUnknownPermission)
}

// --- admin handoff ---

func TestTwoStepAdminHandoff(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, nominate(cur, b, nominee))
	// nomination alone does NOT move the admin
	uassert.Equal(t, admin.String(), b.Admin().String())
	uassert.Equal(t, nominee.String(), b.PendingAdmin().String())
	// and the incumbent still has authority
	uassert.NoError(t, grant(cur, b, "read", alice))

	// the nominee cannot yet act
	testing.SetRealm(testing.NewUserRealm(nominee))
	uassert.ErrorIs(t, grant(cur, b, "write", alice), ErrUnauthorized)

	uassert.NoError(t, acceptAdmin(cur, b))
	uassert.Equal(t, nominee.String(), b.Admin().String())
	uassert.Equal(t, "", b.PendingAdmin().String())
	uassert.NoError(t, grant(cur, b, "write", alice))

	// the former admin has lost authority
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.ErrorIs(t, grant(cur, b, "other", alice), ErrUnauthorized)

	// grants made under the previous admin survive the handoff
	uassert.True(t, b.Has("read", alice))
}

func TestOnlyNomineeCanAccept(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)
	uassert.NoError(t, nominate(cur, b, nominee))

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.ErrorIs(t, acceptAdmin(cur, b), ErrNotPendingAdmin)
	uassert.Equal(t, admin.String(), b.Admin().String())

	// not even the incumbent admin can accept on the nominee's behalf
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.ErrorIs(t, acceptAdmin(cur, b), ErrNotPendingAdmin)
	uassert.Equal(t, admin.String(), b.Admin().String())
}

func TestAcceptWithoutNomination(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(nominee))
	b := newBook(t, admin)
	uassert.ErrorIs(t, acceptAdmin(cur, b), ErrNoPendingAdmin)
	uassert.Equal(t, admin.String(), b.Admin().String())
}

func TestCancelNomination(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.ErrorIs(t, cancelNom(cur, b), ErrNoPendingAdmin)

	uassert.NoError(t, nominate(cur, b, nominee))
	uassert.NoError(t, cancelNom(cur, b))
	uassert.Equal(t, "", b.PendingAdmin().String())

	// the withdrawn nominee can no longer accept
	testing.SetRealm(testing.NewUserRealm(nominee))
	uassert.ErrorIs(t, acceptAdmin(cur, b), ErrNoPendingAdmin)
	uassert.Equal(t, admin.String(), b.Admin().String())
}

func TestRenominationReplacesPending(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, nominate(cur, b, nominee))
	uassert.NoError(t, nominate(cur, b, bob))
	uassert.Equal(t, bob.String(), b.PendingAdmin().String())

	// the superseded nominee cannot accept
	testing.SetRealm(testing.NewUserRealm(nominee))
	uassert.ErrorIs(t, acceptAdmin(cur, b), ErrNotPendingAdmin)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.NoError(t, acceptAdmin(cur, b))
	uassert.Equal(t, bob.String(), b.Admin().String())
}

func TestNominateRejectsBadAddress(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.ErrorIs(t, nominate(cur, b, address("")), ErrInvalidAddress)
	uassert.ErrorIs(t, nominate(cur, b, address("g1bogus")), ErrInvalidAddress)
	uassert.ErrorIs(t, nominate(cur, b, admin), ErrSameAdmin)
	uassert.Equal(t, "", b.PendingAdmin().String())
}

// --- read-side queries ---

func TestPermissionsOfAddress(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.Equal(t, 0, len(b.Permissions(alice)))

	uassert.NoError(t, grant(cur, b, "write", alice))
	uassert.NoError(t, grant(cur, b, "audit", alice))
	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.NoError(t, grant(cur, b, "read", bob))

	got := b.Permissions(alice)
	uassert.Equal(t, 3, len(got))
	// lexicographic order, which is what makes rendered output deterministic
	uassert.Equal(t, "audit", got[0])
	uassert.Equal(t, "read", got[1])
	uassert.Equal(t, "write", got[2])

	uassert.Equal(t, 1, len(b.Permissions(bob)))
	uassert.Equal(t, 0, len(b.Permissions(mallory)))
}

func TestHasAny(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.False(t, b.HasAny(alice))
	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.True(t, b.HasAny(alice))
	uassert.False(t, b.HasAny(bob))

	uassert.NoError(t, revoke(cur, b, "read", alice))
	uassert.False(t, b.HasAny(alice))
}

func TestPermissionNamesPagination(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	for _, p := range []string{"e", "a", "d", "b", "c"} {
		uassert.NoError(t, grant(cur, b, p, alice))
	}

	all := b.PermissionNames(0, 10)
	uassert.Equal(t, 5, len(all))
	uassert.Equal(t, "a", all[0])
	uassert.Equal(t, "e", all[4])

	page := b.PermissionNames(1, 2)
	uassert.Equal(t, 2, len(page))
	uassert.Equal(t, "b", page[0])
	uassert.Equal(t, "c", page[1])

	uassert.Equal(t, 0, len(b.PermissionNames(0, 0)))
	uassert.Equal(t, 0, len(b.PermissionNames(0, -1)))
	uassert.Equal(t, 0, len(b.PermissionNames(99, 5)))
}

func TestHoldersPagination(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.NoError(t, grant(cur, b, "read", bob))
	uassert.NoError(t, grant(cur, b, "read", mallory))

	all := b.Holders("read", 0, 10)
	uassert.Equal(t, 3, len(all))

	page := b.Holders("read", 0, 2)
	uassert.Equal(t, 2, len(page))
	// sorted order, so pages do not overlap or skip
	uassert.True(t, page[0].String() < page[1].String())

	uassert.Equal(t, 0, len(b.Holders("read", 0, 0)))
	uassert.Equal(t, 0, len(b.Holders("nope", 0, 10)))
}

// Queries perform no authentication at all — consumer-contract clause 3.
// Anyone may read; that is deliberate and is asserted so a future change
// that adds a gate is caught as a behavioral break.
func TestQueriesAreUnauthenticated(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)
	uassert.NoError(t, grant(cur, b, "read", alice))

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.True(t, b.Has("read", alice))
	uassert.Equal(t, 1, b.HolderCount("read"))
	uassert.Equal(t, 1, len(b.Permissions(alice)))
	uassert.Equal(t, admin.String(), b.Admin().String())
}

// --- the groups base set is never used ---

// permbook never writes to the Group's base address set, so "in the base
// set" can never be confused with "holds a permission". HasAny consults
// base OR roles; if base were ever written, this would report true.
func TestBaseSetStaysEmpty(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	b := newBook(t, admin)

	uassert.NoError(t, grant(cur, b, "read", alice))
	uassert.NoError(t, revoke(cur, b, "read", alice))

	// with every role gone, HasAny can only be true via the base set
	uassert.Equal(t, 0, b.PermissionCount())
	uassert.False(t, b.HasAny(alice))
	uassert.False(t, b.HasAny(admin))
}
