package nftpresets

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

func TestQueueAndRevealInOrder(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pre-alice")

	var collID string
	t.Run("alice creates a collection and queues three pieces", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID = nft.CreateCollection(cross(cur), "Preset Test", "PRE", "", "", 10, 0, true)

		uassert.False(t, HasQueue(collID), "no queue yet")

		QueuePresetURI(cross(cur), collID, "ipfs://one")
		QueuePresetURI(cross(cur), collID, "ipfs://two")
		QueuePresetURI(cross(cur), collID, "ipfs://three")

		uassert.True(t, HasQueue(collID), "queue should exist now")
		uassert.Equal(t, 3, TotalPresets(collID))
		uassert.Equal(t, 3, RemainingPresets(collID))
	})

	t.Run("minting draws pieces strictly in queued order", func(t *testing.T) {
		tid1 := MintNext(cross(cur), collID)
		uri1, err := nft.TokenURI(collID, tid1)
		uassert.NoError(t, err)
		uassert.Equal(t, "ipfs://one", uri1)
		uassert.Equal(t, 2, RemainingPresets(collID))

		tid2 := MintNext(cross(cur), collID)
		uri2, err := nft.TokenURI(collID, tid2)
		uassert.NoError(t, err)
		uassert.Equal(t, "ipfs://two", uri2)
		uassert.Equal(t, 1, RemainingPresets(collID))
	})

	t.Run("queue is exhausted after the last piece", func(t *testing.T) {
		MintNext(cross(cur), collID)
		uassert.Equal(t, 0, RemainingPresets(collID))
		uassert.True(t, HasQueue(collID), "queue still 'exists', just exhausted")

		uassert.AbortsWithMessage(t, cur, "no preset artwork left to reveal — the queue is exhausted", func() {
			MintNext(cross(cur), collID)
		})
	})
}

func TestOnlyCreatorCanQueue(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pre-alice2")
	bob := testutils.TestAddress("pre-bob2")

	testing.SetOriginCaller(alice)
	collID := nft.CreateCollection(cross(cur), "Preset Test 2", "PRE2", "", "", 10, 0, true)

	testing.SetOriginCaller(bob)
	uassert.AbortsWithMessage(t, cur, "only the collection's creator can queue preset artwork", func() {
		QueuePresetURI(cross(cur), collID, "ipfs://intruder")
	})
}

func TestMintNextWithoutQueueAborts(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pre-alice3")

	testing.SetOriginCaller(alice)
	collID := nft.CreateCollection(cross(cur), "Preset Test 3", "PRE3", "", "", 10, 0, true)

	uassert.AbortsWithMessage(t, cur, "this collection has no preset artwork queue — mint normally instead", func() {
		MintNext(cross(cur), collID)
	})
}

func TestMintNextRespectsPublicMintRule(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pre-alice4")
	bob := testutils.TestAddress("pre-bob4")

	testing.SetOriginCaller(alice)
	// publicMint = false: only alice (the creator) may mint.
	collID := nft.CreateCollection(cross(cur), "Preset Test 4", "PRE4", "", "", 10, 0, false)
	QueuePresetURI(cross(cur), collID, "ipfs://only-creator")

	testing.SetOriginCaller(bob)
	uassert.AbortsWithMessage(t, cur, "minting into this collection is restricted to its creator", func() {
		MintNext(cross(cur), collID)
	})
}
