package fees

import (
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// ed25519 keys from seeds "aaaa..." and "bbbb..." (32 bytes); the signatures
// are over TicketMessage for alice at the test chain's genesis time + 3600.
const (
	keyA            = "af06a3e3291714e4f356c19c9b15cd1951ec6e6662aa77be07547f289383341d"
	keyB            = "2df04125f0015afb47ce853aef8772094ff9498c14cb1b9e12973c2927da0fa6"
	sigATier2       = "96ec6f0b7ee676f5577e107a7edb1b2aba49aec6aae262be787d0199b880b14b63ceb8fdc553b2d60084a527afb160e9851ed00b9aaaa5747fa47f76ca54a602"
	sigATier1       = "79294a555bfcbb14222586c1ea488b6c6eaa5822844d1c269d7c4a54ce2110630e47b87e2b9db9fce8b3ff122d495915f74b437dbdcf6a62131e69bbb0b3c40a"
	sigBTier2       = "0e4b90aead6c2b3a6dfbdb604bb68482f45ccb6011ef7ecbb543eb8205bb4251588b649d1586349fac1344df38232e13bd8077ce97961bbd6aebbba23ba03b01"
	timelockHeights = 2*24*60*60/5 + 1 // a block is 5s in tests
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
)

func TestTickets(cur realm, t *testing.T) {
	exp := time.Now().Unix() + 3600
	admin := Owner()

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "NotOwner", func() { SetInitialSigner(cross(cur), keyA) })

	testing.SetRealm(testing.NewUserRealm(admin))
	SetInitialSigner(cross(cur), keyA)
	uassert.AbortsContains(t, cur, "SignerAlreadySet", func() { SetInitialSigner(cross(cur), keyB) })

	uassert.Equal(t, BaseBps, EntryBps(alice))

	// A ticket is bound to its account: bob cannot apply alice's.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "BadSignature", func() { ApplyTicket(cross(cur), 2, exp, sigATier2) })

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "BadSignature", func() { ApplyTicket(cross(cur), 1, exp, sigATier2) })
	uassert.AbortsContains(t, cur, "BadTier", func() { ApplyTicket(cross(cur), 3, exp, sigATier2) })
	uassert.AbortsContains(t, cur, "BadExpiry", func() { ApplyTicket(cross(cur), 2, time.Now().Unix(), sigATier2) })
	ApplyTicket(cross(cur), 2, exp, sigATier2)
	uassert.Equal(t, WhaleBps, EntryBps(alice))
	ApplyTicket(cross(cur), 1, exp, sigATier1)
	uassert.Equal(t, HolderBps, EntryBps(alice))
	uassert.Equal(t, BaseBps, EntryBps(bob))

	// Revoking retires every applied ticket and verifies nothing.
	testing.SetRealm(testing.NewUserRealm(admin))
	RevokeSigner(cross(cur))
	uassert.Equal(t, BaseBps, EntryBps(alice))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "BadSignature", func() { ApplyTicket(cross(cur), 1, exp, sigATier1) })
}

func TestSignerTimelockAndExpiry(cur realm, t *testing.T) {
	admin := Owner()
	testing.SetRealm(testing.NewUserRealm(admin))
	QueueSigner(cross(cur), keyB)
	uassert.AbortsContains(t, cur, "Timelocked", func() { ExecuteSigner(cross(cur)) })
	testing.SkipHeights(timelockHeights)
	testing.SetRealm(testing.NewUserRealm(bob)) // permissionless once due
	epoch := SignerEpoch()
	ExecuteSigner(cross(cur))
	uassert.Equal(t, epoch+1, SignerEpoch())
	uassert.Equal(t, keyB, Signer())
	uassert.AbortsContains(t, cur, "NothingQueued", func() { ExecuteSigner(cross(cur)) })
	// The fixed signatures were made for genesis + 3600; that time has passed.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "BadExpiry", func() { ApplyTicket(cross(cur), 2, 1234571490, sigBTier2) })
}

func TestOwnershipTimelock(cur realm, t *testing.T) {
	admin := Owner()
	testing.SetRealm(testing.NewUserRealm(admin))
	TransferOwnership(cross(cur), bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "Timelocked", func() { AcceptOwnership(cross(cur)) })
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "NotPendingOwner", func() { AcceptOwnership(cross(cur)) })
	testing.SkipHeights(timelockHeights)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptOwnership(cross(cur))
	uassert.Equal(t, bob, Owner())
	uassert.Equal(t, address(""), PendingOwner())
}
