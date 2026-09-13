package nft57

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// These tests pin the v5.7 changes. The rule is the same one the earlier
// cost work followed: a cheaper or more flexible path is only acceptable if
// nothing a buyer reads becomes less trustworthy. So each test here checks
// both halves - the new capability works, AND the guarantee it could have
// weakened still holds.

// TestBaseURIFallbackResolvesTokens covers v5.7 change 1: an IPFS-style
// collection writes ONE baseURI and every token derives its URI from it.
// This is what makes a 1000-piece collection cost one write instead of
// one transaction per token.
func TestBaseURIFallbackResolvesTokens(cur realm, t *testing.T) {
	c := newTestCollection(cur, "600", 0, 0)
	defer dropTestCollection("600")
	c.baseURI = "ipfs://QmFolderCID/"

	// Three tokens, no per-token URI stored anywhere.
	mint(cur, testBuyer, "600", "", "")
	mint(cur, testBuyer, "600", "", "")
	mint(cur, testBuyer, "600", "", "")

	for i := 1; i <= 3; i++ {
		id := strconv.Itoa(i)
		uri, err := TokenURI("600", id)
		uassert.NoError(t, err)
		uassert.Equal(t, "ipfs://QmFolderCID/"+id, uri)
	}

	// A token that was never minted must NOT resolve to a plausible-looking
	// baseURI: the existence gate runs first.
	_, err := TokenURI("600", "4")
	uassert.Error(t, err)
}

// TestStoredTokenURIWinsOverBaseURI keeps the resolution order honest: a
// token that carries its own URI must never be overridden by a
// collection-level default.
func TestStoredTokenURIWinsOverBaseURI(cur realm, t *testing.T) {
	c := newTestCollection(cur, "601", 0, 0)
	defer dropTestCollection("601")
	c.baseURI = "ipfs://QmFolderCID/"

	mint(cur, testBuyer, "601", "ipfs://QmSpecificToken", "")

	uri, err := TokenURI("601", "1")
	uassert.NoError(t, err)
	uassert.Equal(t, "ipfs://QmSpecificToken", uri)
}

// TestGenerativeBeatsBaseURI proves a generative collection is never
// diverted to off-chain art even if a baseURI happens to be set: on-chain
// provenance outranks a collection-level default.
func TestGenerativeBeatsBaseURI(cur realm, t *testing.T) {
	c := newTestCollection(cur, "602", 0, 0)
	defer dropTestCollection("602")
	c.baseURI = "ipfs://QmFolderCID/"
	c.generative = true
	c.engine = Engine

	mintGenerativeOne(cur, testBuyer, "602")

	uri, err := TokenURI("602", "1")
	uassert.NoError(t, err)
	uassert.True(t, strings.HasPrefix(uri, "data:"))
}

// TestBaseURIIsOneShot is the security half of the reveal feature (v5.7
// change 2). The creator may reveal exactly once; the second attempt is
// refused forever, so a buyer's artwork cannot be rewritten after purchase
// the way it can on an Ethereum contract with a permanently callable
// setBaseURI.
func TestBaseURIIsOneShot(cur realm, t *testing.T) {
	c := newTestCollection(cur, "603", 0, 0)
	defer dropTestCollection("603")
	c.baseURI = "ipfs://QmPlaceholder/"
	c.creator = callerOf(cur)

	uassert.False(t, c.baseURILocked)

	SetBaseURI(cur, "603", "ipfs://QmRealCID/")
	uassert.Equal(t, "ipfs://QmRealCID/", c.baseURI)
	uassert.True(t, c.baseURILocked)

	uassert.PanicsWithMessage(t, cur,
		"this collection's baseURI is locked and can never be changed again",
		func() { SetBaseURI(cur, "603", "ipfs://QmAttackerCID/") })

	// The locked value survived the refused call.
	uassert.Equal(t, "ipfs://QmRealCID/", c.baseURI)
}

// TestLockBaseURIWithoutReveal covers the creator who needs no reveal and
// wants to prove immutability up front.
func TestLockBaseURIWithoutReveal(cur realm, t *testing.T) {
	c := newTestCollection(cur, "604", 0, 0)
	defer dropTestCollection("604")
	c.baseURI = "ipfs://QmFinalCID/"
	c.creator = callerOf(cur)

	LockBaseURI(cur, "604")
	uassert.True(t, c.baseURILocked)
	uassert.Equal(t, "ipfs://QmFinalCID/", c.baseURI)

	uassert.PanicsWithMessage(t, cur,
		"this collection's baseURI is already locked",
		func() { LockBaseURI(cur, "604") })

	uassert.PanicsWithMessage(t, cur,
		"this collection's baseURI is locked and can never be changed again",
		func() { SetBaseURI(cur, "604", "ipfs://QmSomethingElse/") })
}

// TestSetBaseURIRejectsUnsafeSchemes makes sure the reveal path did not open
// a hole around the v5.5 URI validation: an immutable javascript: or
// data:text/html payload would be stored XSS living on chain forever.
func TestSetBaseURIRejectsUnsafeSchemes(cur realm, t *testing.T) {
	c := newTestCollection(cur, "605", 0, 0)
	defer dropTestCollection("605")
	c.creator = callerOf(cur)

	uassert.PanicsWithMessage(t, cur,
		"baseURI must start with https://, ipfs://, ar://, data:image/ or data:application/json",
		func() { SetBaseURI(cur, "605", "javascript:alert(1)") })

	// A refused reveal must not consume the one-shot right.
	uassert.False(t, c.baseURILocked)
}

// TestMintBatchMintsManyInOneCall covers v5.7 change 5.
func TestMintBatchMintsManyInOneCall(cur realm, t *testing.T) {
	c := newTestCollection(cur, "606", 0, 0)
	defer dropTestCollection("606")
	c.baseURI = "ipfs://QmFolderCID/"

	ids := mintBatch(cur, testBuyer, "606", 5)
	uassert.Equal(t, "1,2,3,4,5", ids)
	uassert.Equal(t, int64(5), c.mintedTotal)
	uassert.Equal(t, int64(6), c.nextTokenID)

	// Every batched token resolves exactly like a singly minted one.
	uri, err := TokenURI("606", "5")
	uassert.NoError(t, err)
	uassert.Equal(t, "ipfs://QmFolderCID/5", uri)
}

// TestMintBatchGenerative proves a batch of generative mints is identical to
// the same mints done one at a time - same seeds, same traits, nothing
// stored.
func TestMintBatchGenerative(cur realm, t *testing.T) {
	c := newTestCollection(cur, "607", 0, 0)
	defer dropTestCollection("607")
	c.generative = true
	c.engine = Engine

	mintBatch(cur, testBuyer, "607", 3)
	uassert.Equal(t, int64(3), c.mintedTotal)
	uassert.Equal(t, int64(3), c.onchainTokens)

	for i := 1; i <= 3; i++ {
		id := strconv.Itoa(i)
		uassert.Equal(t, "607:"+id, TokenSeed("607", id))
		uassert.Equal(t, 10, len(TokenAttributes("607", id)))
		uassert.Equal(t, nil, avlGet(attributes, "607:"+id))
	}
}

// TestMintBatchRespectsEveryLimit is the important half: batching must not
// become a way around the checks a single mint has to pass.
func TestMintBatchRespectsEveryLimit(cur realm, t *testing.T) {
	// Per-wallet cap still bites mid-batch.
	capped := newTestCollection(cur, "608", 0, 2)
	defer dropTestCollection("608")
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 2",
		func() { mintBatch(cur, testBuyer, "608", 3) })
	_ = capped

	// Max supply still bites mid-batch.
	small := newTestCollection(cur, "609", 0, 0)
	defer dropTestCollection("609")
	small.maxSupply = 2
	uassert.PanicsWithMessage(t, cur,
		"collection has reached its max supply",
		func() { mintBatch(cur, testBuyer, "609", 4) })

	// And the batch size itself is bounded.
	big := newTestCollection(cur, "610", 0, 0)
	defer dropTestCollection("610")
	uassert.PanicsWithMessage(t, cur,
		"count must be at most 25 per call",
		func() { mintBatch(cur, testBuyer, "610", MaxMintBatch+1) })
	uassert.PanicsWithMessage(t, cur,
		"count must be positive",
		func() { mintBatch(cur, testBuyer, "610", 0) })
	uassert.Equal(t, int64(0), big.mintedTotal)
}

// TestCollectionURIRoundTrips covers v5.7 change 4, including the fact that
// it is validated like every other URI this realm persists.
func TestCollectionURIRoundTrips(cur realm, t *testing.T) {
	c := newTestCollection(cur, "611", 0, 0)
	defer dropTestCollection("611")
	c.creator = callerOf(cur)

	SetCollectionURI(cur, "611", "ipfs://QmCollectionMeta")
	uassert.Equal(t, "ipfs://QmCollectionMeta", GetCollection("611").CollectionURI)

	uassert.PanicsWithMessage(t, cur,
		"uri must start with https://, ipfs://, ar://, data:image/ or data:application/json",
		func() { SetCollectionURI(cur, "611", "data:text/html,<script>") })
}

// TestCollectionInfoExposesLockState makes sure the UI can badge a
// collection honestly: "can this art still change?" must be answerable from
// a plain read.
func TestCollectionInfoExposesLockState(cur realm, t *testing.T) {
	c := newTestCollection(cur, "612", 0, 0)
	defer dropTestCollection("612")
	c.baseURI = "ipfs://QmFolderCID/"
	c.creator = callerOf(cur)

	uassert.False(t, GetCollection("612").BaseURILocked)
	LockBaseURI(cur, "612")
	uassert.True(t, GetCollection("612").BaseURILocked)
}
