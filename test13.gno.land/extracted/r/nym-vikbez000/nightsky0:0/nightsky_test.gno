package nightsky

import (
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	nightsky "gno.land/p/nym-vikbez000/nightsky0"
)

const scopeA = "gno.land/r/test/scopea"

func reset() {
	telescopes = avl.NewTree()
	recentCaptures = nightsky.NewCaptureFeed(maxRecentCaptures)
}

func cfg(name, owner string) nightsky.TelescopeConfig {
	return nightsky.NewTelescopeConfig(name, "Seestar S50", 1, 2, owner, "")
}

// registerAs simulates a telescope code realm at pkgPath crossing into the
// registry to register itself.
func registerAs(cur realm, pkgPath string, c nightsky.TelescopeConfig) {
	testing.SetRealm(testing.NewCodeRealm(pkgPath))
	Register(cross(cur), c)
}

func TestRegisterAndDedup(cur realm, t *testing.T) {
	reset()

	registerAs(cur, scopeA, cfg("Scope A", "g1owner"))
	urequire.Equal(t, 1, GetTelescopeCount())

	// RealmPath is stamped from the caller's pkgPath, not the (empty) input.
	stored, ok := telescopes.Get(scopeA)
	urequire.True(t, ok)
	uassert.Equal(t, scopeA, stored.(nightsky.TelescopeConfig).RealmPath)

	// Duplicate registration from the same realm is ignored.
	registerAs(cur, scopeA, cfg("Scope A", "g1owner"))
	uassert.Equal(t, 1, GetTelescopeCount())

	// A second telescope from a different realm is added.
	registerAs(cur, "gno.land/r/test/scopeb", cfg("Scope B", "g1owner2"))
	uassert.Equal(t, 2, GetTelescopeCount())
}

func TestRegisterRejectsUserCall(cur realm, t *testing.T) {
	reset()

	// A direct user transaction (no intermediary realm) must be rejected.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("eoa")))
	uassert.AbortsContains(t, cur, "realm code", func() {
		Register(cross(cur), cfg("Bad", "g1owner"))
	})
	uassert.Equal(t, 0, GetTelescopeCount())
}

func TestOnlineCountAndStatus(cur realm, t *testing.T) {
	reset()

	c := cfg("Scope A", "g1owner")
	c.UpdateStatus("online")
	registerAs(cur, scopeA, c)
	uassert.Equal(t, 1, GetOnlineTelescopeCount())

	// The telescope realm updates its status to offline.
	testing.SetRealm(testing.NewCodeRealm(scopeA))
	UpdateTelescopeStatus(cross(cur), "offline")
	uassert.Equal(t, 0, GetOnlineTelescopeCount())
	uassert.Equal(t, 1, GetTelescopeCount())
}

func TestSubmitCaptureFeed(cur realm, t *testing.T) {
	reset()
	registerAs(cur, scopeA, cfg("Scope A", "g1owner"))

	testing.SetRealm(testing.NewCodeRealm(scopeA))
	SubmitCapture(cross(cur), "https://img/1.png", 5, 10, 30, "g1owner")
	SubmitCapture(cross(cur), "https://img/2.png", 6, 11, 40, "g1owner")

	latest, ok := recentCaptures.Latest()
	urequire.True(t, ok)
	uassert.Equal(t, "https://img/2.png", latest.ImageURL)
	uassert.Equal(t, 2, recentCaptures.Len())
}

func TestAdminRemoveAndAuth(cur realm, t *testing.T) {
	reset()
	registerAs(cur, scopeA, cfg("Scope A", "g1owner"))
	urequire.Equal(t, 1, GetTelescopeCount())

	// Non-admin cannot remove.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("intruder")))
	uassert.AbortsContains(t, cur, "not owner", func() {
		RemoveTelescope(cross(cur), scopeA)
	})
	uassert.Equal(t, 1, GetTelescopeCount())

	// Admin can remove.
	testing.SetRealm(testing.NewUserRealm(OwnableMain.Owner()))
	RemoveTelescope(cross(cur), scopeA)
	uassert.Equal(t, 0, GetTelescopeCount())

	// Removing a missing telescope aborts.
	uassert.AbortsContains(t, cur, "not found", func() {
		RemoveTelescope(cross(cur), scopeA)
	})
}

// --- Adversarial ("steal a telescope") tests -------------------------------
// An attacker realm or EOA tries to hijack, impersonate, or wipe telescopes
// that are not theirs.

const (
	victimPath   = "gno.land/r/victim/scope"
	attackerPath = "gno.land/r/attacker/evil"
)

// TestAttackerRealmCannotTouchVictim: registry mutations are keyed by the
// caller's own pkgPath (cur.Previous().PkgPath()). An unregistered attacker
// realm therefore cannot update, capture-to, or unregister a victim's entry —
// it only ever addresses its own (nonexistent) registration.
func TestAttackerRealmCannotTouchVictim(cur realm, t *testing.T) {
	reset()
	registerAs(cur, victimPath, cfg("Victim Scope", "g1victim"))
	urequire.Equal(t, 1, GetTelescopeCount())

	testing.SetRealm(testing.NewCodeRealm(attackerPath))
	uassert.AbortsContains(t, cur, "not registered", func() {
		UpdateTelescopeStatus(cross(cur), "error")
	})
	uassert.AbortsContains(t, cur, "not registered", func() {
		SubmitCapture(cross(cur), "https://evil/forged.png", 1, 1, 10, "g1victim")
	})
	uassert.AbortsContains(t, cur, "not registered", func() {
		UnregisterTelescope(cross(cur))
	})

	// Victim's entry is untouched.
	stored, ok := telescopes.Get(victimPath)
	urequire.True(t, ok)
	uassert.Equal(t, "Victim Scope", stored.(nightsky.TelescopeConfig).Name)
	uassert.Equal(t, 1, GetTelescopeCount())
}

// TestAttackerCannotUnregisterVictim: even when the attacker is itself
// registered, UnregisterTelescope removes only the caller's own entry — it
// cannot take down a neighbour.
func TestAttackerCannotUnregisterVictim(cur realm, t *testing.T) {
	reset()
	registerAs(cur, victimPath, cfg("Victim Scope", "g1victim"))
	registerAs(cur, attackerPath, cfg("Evil Scope", "g1attacker"))
	urequire.Equal(t, 2, GetTelescopeCount())

	testing.SetRealm(testing.NewCodeRealm(attackerPath))
	UnregisterTelescope(cross(cur)) // removes the attacker, nothing else

	uassert.False(t, telescopes.Has(attackerPath))
	uassert.True(t, telescopes.Has(victimPath)) // victim survives
	uassert.Equal(t, 1, GetTelescopeCount())
}

// TestAttackerCaptureCannotImpersonateVictim: the network feed stamps each
// capture's TelescopeID from the caller's own registration, so an attacker
// cannot make a forged image appear to come from the victim's telescope —
// regardless of the capturedBy value they pass.
func TestAttackerCaptureCannotImpersonateVictim(cur realm, t *testing.T) {
	reset()
	registerAs(cur, victimPath, cfg("Victim Scope", "g1victim"))
	registerAs(cur, attackerPath, cfg("Evil Scope", "g1attacker"))

	testing.SetRealm(testing.NewCodeRealm(attackerPath))
	SubmitCapture(cross(cur), "https://evil/forged.png", 1, 1, 10, "g1victim")

	latest, ok := recentCaptures.Latest()
	urequire.True(t, ok)
	uassert.Equal(t, "Evil Scope", latest.TelescopeID) // not "Victim Scope"
}

// TestNonAdminCannotUseAdminPowers: the network-admin functions reject anyone
// who is not the ownable owner, so an intruder cannot wipe the registry or the
// capture feed.
func TestNonAdminCannotUseAdminPowers(cur realm, t *testing.T) {
	reset()
	registerAs(cur, victimPath, cfg("Victim Scope", "g1victim"))
	urequire.Equal(t, 1, GetTelescopeCount())

	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("intruder")))
	uassert.AbortsContains(t, cur, "not owner", func() {
		RemoveTelescope(cross(cur), victimPath)
	})
	uassert.AbortsContains(t, cur, "not owner", func() {
		ClearAllTelescopes(cross(cur))
	})
	uassert.AbortsContains(t, cur, "not owner", func() {
		RemoveCapture(cross(cur), 0)
	})

	// Nothing was removed.
	uassert.Equal(t, 1, GetTelescopeCount())
}
