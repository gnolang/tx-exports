package telescope

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// ownerAddr must match the owner configured in telescope.gno's init().
var ownerAddr = address("g13kytw9mpyutwmyg5eq7arqxqcszfl6uq4p89zg")

func TestSubmitCommandValid(cur realm, t *testing.T) {
	telescope.CommandQueue = nil

	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SubmitCommand(cross(cur), "capture", "5.5", "22.5", "60")

	uassert.Equal(t, 1, GetCommandCount())
	uassert.Equal(t, "busy", GetStatus())
}

func TestSubmitCommandRejectsMalformedNumber(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ownerAddr))

	// A non-numeric RA must be rejected, not silently coerced to 0.
	uassert.AbortsContains(t, cur, "invalid RA", func() {
		SubmitCommand(cross(cur), "capture", "notanumber", "22.5", "60")
	})
}

func TestSubmitCommandAccessDenied(cur realm, t *testing.T) {
	// A stranger with no grant cannot submit.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("stranger")))
	uassert.AbortsContains(t, cur, "access denied", func() {
		SubmitCommand(cross(cur), "capture", "5.5", "22.5", "60")
	})
}

func TestGrantThenSubmit(cur realm, t *testing.T) {
	telescope.CommandQueue = nil
	friend := testutils.TestAddress("friend")

	// Owner grants access to the friend.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	GrantAccess(cross(cur), friend.String(), 0)
	uassert.Equal(t, 1, GetAccessRuleCount())

	// Friend can now submit a stop command.
	testing.SetRealm(testing.NewUserRealm(friend))
	SubmitCommand(cross(cur), "stop", "", "", "")
	uassert.Equal(t, 1, GetCommandCount())

	// Owner revokes; friend is denied again.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	RevokeAccess(cross(cur), friend.String())
	uassert.Equal(t, 0, GetAccessRuleCount())

	testing.SetRealm(testing.NewUserRealm(friend))
	uassert.AbortsContains(t, cur, "access denied", func() {
		SubmitCommand(cross(cur), "stop", "", "", "")
	})
}

// --- Adversarial ("steal a telescope") tests -------------------------------
// An attacker tries to take over or misuse a telescope they do not own. Every
// privileged path must reject them, and ownership must be unchanged afterwards.

// TestStrangerCannotControlTelescope: an EOA with no relationship to the
// telescope cannot use or control it through any entrypoint.
func TestStrangerCannotControlTelescope(cur realm, t *testing.T) {
	intruder := testutils.TestAddress("intruder")
	testing.SetRealm(testing.NewUserRealm(intruder))

	// Use is denied (no access grant).
	uassert.AbortsContains(t, cur, "access denied", func() {
		SubmitCommand(cross(cur), "capture", "5", "5", "30")
	})

	// Every owner-only entrypoint is denied.
	uassert.AbortsContains(t, cur, "owner only", func() {
		GrantAccess(cross(cur), intruder.String(), 0) // grant self
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		RevokeAccess(cross(cur), ownerAddr.String()) // revoke the real owner
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		GetNextCommand(cross(cur)) // drain the queue
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		ClearCommandQueue(cross(cur))
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		UpdateStatus(cross(cur), "offline")
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		RecordCapture(cross(cur), "https://evil/forged.png", 1, 1, 10, intruder.String())
	})

	// The telescope still belongs to its owner.
	uassert.Equal(t, ownerAddr.String(), GetOwner())
}

// TestAccessIsNotOwnership: a user who has been granted *access* can use the
// telescope, but cannot escalate to control it. This is the core "steal"
// scenario — proving a granted friend can't quietly take over.
func TestAccessIsNotOwnership(cur realm, t *testing.T) {
	friend := testutils.TestAddress("friend")
	accomplice := testutils.TestAddress("accomplice")

	// Owner grants the friend use-access.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	GrantAccess(cross(cur), friend.String(), 0)

	// The friend can submit commands (legitimate use)...
	telescope.CommandQueue = nil
	testing.SetRealm(testing.NewUserRealm(friend))
	SubmitCommand(cross(cur), "stop", "", "", "")
	uassert.Equal(t, 1, GetCommandCount())

	// ...but cannot perform any owner-only action to take control.
	uassert.AbortsContains(t, cur, "owner only", func() {
		GrantAccess(cross(cur), accomplice.String(), 0) // invite an accomplice
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		RevokeAccess(cross(cur), ownerAddr.String()) // lock out the owner
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		GetNextCommand(cross(cur)) // read/consume the queue
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		ClearCommandQueue(cross(cur))
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		UpdateStatus(cross(cur), "error")
	})
	uassert.AbortsContains(t, cur, "owner only", func() {
		RecordCapture(cross(cur), "https://evil/forged.png", 1, 1, 10, friend.String())
	})

	// The accomplice was never granted access, so they remain locked out.
	testing.SetRealm(testing.NewUserRealm(accomplice))
	uassert.AbortsContains(t, cur, "access denied", func() {
		SubmitCommand(cross(cur), "stop", "", "", "")
	})

	// Cleanup: owner revokes the grant and clears the queue.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	RevokeAccess(cross(cur), friend.String())
	telescope.CommandQueue = nil

	// Ownership unchanged throughout.
	uassert.Equal(t, ownerAddr.String(), GetOwner())
}
