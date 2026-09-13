package nft57

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nftgen1"
)

// These tests cover v5.7's only behavioural change: the per-collection seed
// salt decided by commit-reveal.
//
// The property being defended is narrow and checkable: before the reveal,
// nobody - creator included - can know which token carries which traits;
// after the reveal, anybody can re-derive the salt from chain data and
// verify that the creator revealed the secret they committed to. Each test
// below is one half of that claim.

// TestSaltHashIsRealSha256 pins the hash itself against the published
// FIPS-180 vector. The commitment is only binding if it is a real
// pre-image-resistant hash: with an invertible mixer (fnv, splitmix) a
// creator could produce a second secret for the same commitment after
// seeing the entropy, and the whole scheme would be theatre.
func TestSaltHashIsRealSha256(t *testing.T) {
	uassert.Equal(t,
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		sha256Hex("abc"))
	uassert.Equal(t,
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		sha256Hex(""))
	uassert.Equal(t, 64, len(sha256Hex("anything")))
}

// TestSaltFromBindsBothHalves proves the final salt depends on the creator's
// secret AND the minters' entropy AND the collection ID, so neither party
// alone determines it and a secret reused on a second collection cannot
// reproduce the same trait map.
func TestSaltFromBindsBothHalves(t *testing.T) {
	base := saltFrom("secret", 42, "1")
	uassert.Equal(t, base, saltFrom("secret", 42, "1"))
	uassert.True(t, base != saltFrom("secret", 43, "1"))
	uassert.True(t, base != saltFrom("secret", 42, "2"))
	uassert.True(t, base != saltFrom("secrez", 42, "1"))
}

// TestMixEntropyIsDeterministicAndSensitive keeps the accumulator honest:
// replayable from chain data (so the reveal can be verified) but changed by
// every input a mint contributes.
func TestMixEntropyIsDeterministicAndSensitive(t *testing.T) {
	base := mixEntropy(0, testBuyer, 100, "1")
	uassert.Equal(t, base, mixEntropy(0, testBuyer, 100, "1"))
	uassert.True(t, base != mixEntropy(0, testBuyer, 101, "1"))
	uassert.True(t, base != mixEntropy(0, testBuyer, 100, "2"))
	uassert.True(t, base != mixEntropy(0, testCreator, 100, "1"))
	uassert.True(t, base != mixEntropy(base, testBuyer, 100, "1"))
}

// TestUncommittedCollectionKeepsV56Behaviour is the compatibility half: a
// creator who never commits a salt gets exactly the v5.6 collection, traits
// public from the first block, and pays nothing for a feature they did not
// ask for.
func TestUncommittedCollectionKeepsV56Behaviour(cur realm, t *testing.T) {
	c := newTestCollection(cur, "900", 0, 0)
	defer dropTestCollection("900")
	c.generative = true
	c.engine = Engine

	mintGenerativeOne(cur, testBuyer, "900")

	uassert.Equal(t, "none", SeedSaltState("900"))
	uassert.False(t, revealPending(c))
	uassert.Equal(t, "900:1", TokenSeed("900", "1"))
	uassert.Equal(t, 10, len(TokenAttributes("900", "1")))

	uri, err := TokenURI("900", "1")
	uassert.NoError(t, err)
	uassert.Equal(t, nftgen1.DataURI(nftgen1.SeedFor("900", "1")), uri)

	// No commitment means no entropy bookkeeping at all.
	uassert.Equal(t, int64(0), c.saltEntropy)
}

// TestPendingSaltHidesSeedTraitsAndArt is the anti-sniping half, written the
// way an attacker would attack it: mint, then try every read path that could
// betray which token is the good one.
func TestPendingSaltHidesSeedTraitsAndArt(cur realm, t *testing.T) {
	c := newTestCollection(cur, "901", 0, 0)
	defer dropTestCollection("901")
	c.generative = true
	c.engine = Engine
	c.saltCommit = sha256Hex("my-secret-901")

	mintGenerativeOne(cur, testBuyer, "901")
	mintGenerativeOne(cur, testBuyer, "901")

	uassert.Equal(t, "pending", SeedSaltState("901"))
	uassert.True(t, revealPending(c))

	// The seed is the whole map: it must not be readable, by any route.
	uassert.Equal(t, "", TokenSeed("901", "1"))
	uassert.Equal(t, "", TokenSeed("901", "2"))
	uassert.Equal(t, "", seedOf(c, "1"))

	// Traits report an honest placeholder instead of real ones.
	attrs := TokenAttributes("901", "1")
	uassert.Equal(t, 1, len(attrs))
	uassert.Equal(t, "Status", attrs[0].TraitType)
	uassert.Equal(t, "Unrevealed", attrs[0].Value)

	// Every token renders the SAME placeholder, so rarity cannot be read
	// out of the artwork either.
	one, err := TokenURI("901", "1")
	uassert.NoError(t, err)
	two, err := TokenURI("901", "2")
	uassert.NoError(t, err)
	uassert.Equal(t, one, two)
	uassert.Equal(t, preRevealURI(c), one)
	uassert.True(t, strings.HasPrefix(one, "data:"))

	// Each mint fed the accumulator the creator could not predict.
	uassert.True(t, c.saltEntropy != 0)

	// And an unrevealed collection is not "verified" by omission.
	uassert.False(t, VerifySeedSalt("901"))

	// A never-minted token still reports nothing at all.
	uassert.Equal(t, "", TokenSeed("901", "3"))
	uassert.Equal(t, 0, len(TokenAttributes("901", "3")))
}

// TestRevealMakesArtSaltedAndVerifiable walks the full lifecycle and pins
// both gates: no reveal before the supply is gone, no reveal with a secret
// that does not match the commitment, and exactly one reveal ever.
func TestRevealMakesArtSaltedAndVerifiable(cur realm, t *testing.T) {
	c := newTestCollection(cur, "902", 0, 0)
	defer dropTestCollection("902")
	c.maxSupply = 2
	c.generative = true
	c.engine = Engine
	c.creator = callerOf(cur)
	secret := "reveal-me-902"
	c.saltCommit = sha256Hex(secret)

	mintGenerativeOne(cur, testBuyer, "902")

	// Revealing now would hand the creator the map of the token still
	// unminted, so the chain refuses rather than trusting restraint.
	uassert.PanicsContains(t, cur, "once the supply is minted out", func() {
		RevealSeedSalt(cur, "902", secret)
	})

	mintGenerativeOne(cur, testBuyer, "902")

	// Gate open, but the commitment still has to hold.
	uassert.PanicsContains(t, cur, "does not match", func() {
		RevealSeedSalt(cur, "902", "wrong-secret")
	})

	salt := RevealSeedSalt(cur, "902", secret)
	uassert.Equal(t, saltFrom(secret, c.saltEntropy, "902"), salt)
	uassert.Equal(t, "revealed", SeedSaltState("902"))
	uassert.True(t, VerifySeedSalt("902"))
	uassert.False(t, revealPending(c))

	// The art is now the salted art - and demonstrably NOT the unsalted
	// art anybody could have precomputed before the sale.
	uassert.Equal(t, nftgen1.SeedForSalted("902", "1", salt), TokenSeed("902", "1"))
	uassert.True(t, TokenSeed("902", "1") != "902:1")
	uassert.Equal(t, 10, len(TokenAttributes("902", "1")))

	uri, err := TokenURI("902", "1")
	uassert.NoError(t, err)
	uassert.Equal(t, nftgen1.DataURI(nftgen1.SeedForSalted("902", "1", salt)), uri)
	uassert.True(t, uri != preRevealURI(c))

	// Deterministic from here to forever, and the two tokens differ.
	again, err := TokenURI("902", "1")
	uassert.NoError(t, err)
	uassert.Equal(t, uri, again)
	other, err := TokenURI("902", "2")
	uassert.NoError(t, err)
	uassert.True(t, other != uri)

	// One-way latch: a second reveal cannot rewrite anybody's artwork.
	uassert.PanicsContains(t, cur, "already revealed", func() {
		RevealSeedSalt(cur, "902", secret)
	})
}

// TestVerifyCatchesATamperedReveal is the check a buyer actually runs. It
// must fail for a salt that does not follow from the published inputs, and
// for a secret that does not hash to the commitment - otherwise "verified"
// would mean nothing.
func TestVerifyCatchesATamperedReveal(cur realm, t *testing.T) {
	c := newTestCollection(cur, "903", 0, 0)
	defer dropTestCollection("903")
	c.generative = true
	c.engine = Engine
	c.saltCommit = sha256Hex("honest-903")
	c.saltSecret = "honest-903"
	c.saltEntropy = 77
	c.seedSalt = saltFrom("honest-903", 77, "903")
	c.saltRevealed = true
	uassert.True(t, verifySalt(c))

	// Salt that does not follow from (secret, entropy, id).
	c.seedSalt = saltFrom("honest-903", 78, "903")
	uassert.False(t, verifySalt(c))
	c.seedSalt = saltFrom("honest-903", 77, "903")
	uassert.True(t, verifySalt(c))

	// Secret swapped after the fact: the commitment no longer matches.
	c.saltSecret = "swapped"
	uassert.False(t, verifySalt(c))
}

// TestCommitGuards covers the input validation on the commitment, including
// the case-insensitivity that stops a creator from "failing" verification
// later purely because their tool emitted uppercase hex.
func TestCommitGuards(cur realm, t *testing.T) {
	c := newTestCollection(cur, "904", 0, 0)
	defer dropTestCollection("904")
	c.creator = callerOf(cur)

	uassert.PanicsContains(t, cur, "only apply to generative collections", func() {
		CommitSeedSalt(cur, "904", sha256Hex("s"))
	})

	c.generative = true
	c.engine = Engine

	uassert.PanicsContains(t, cur, "64-character hex", func() {
		CommitSeedSalt(cur, "904", "abc")
	})
	uassert.PanicsContains(t, cur, "valid hex", func() {
		CommitSeedSalt(cur, "904", strings.Repeat("z", 64))
	})

	CommitSeedSalt(cur, "904", strings.ToUpper(sha256Hex("s")))
	uassert.Equal(t, sha256Hex("s"), c.saltCommit)
	uassert.Equal(t, "pending", SeedSaltState("904"))

	uassert.PanicsContains(t, cur, "already has a seed salt commitment", func() {
		CommitSeedSalt(cur, "904", sha256Hex("t"))
	})
}

// TestCommitRefusedAfterFirstMint protects existing owners: a salt committed
// after a token exists would rewrite artwork somebody already bought.
func TestCommitRefusedAfterFirstMint(cur realm, t *testing.T) {
	c := newTestCollection(cur, "905", 0, 0)
	defer dropTestCollection("905")
	c.creator = callerOf(cur)
	c.generative = true
	c.engine = Engine

	mintGenerativeOne(cur, testBuyer, "905")

	uassert.PanicsContains(t, cur, "before the first mint", func() {
		CommitSeedSalt(cur, "905", sha256Hex("late"))
	})
}

// TestOnlyCreatorControlsTheSalt keeps both salt entry points creator-only,
// so a stranger can neither pre-empt a commitment nor force an early reveal
// of somebody else's drop.
func TestOnlyCreatorControlsTheSalt(cur realm, t *testing.T) {
	c := newTestCollection(cur, "906", 0, 0) // creator is testCreator
	defer dropTestCollection("906")
	c.generative = true
	c.engine = Engine
	c.saltCommit = sha256Hex("x")

	uassert.PanicsContains(t, cur, "only the collection's creator", func() {
		CommitSeedSalt(cur, "906", sha256Hex("y"))
	})
	uassert.PanicsContains(t, cur, "only the collection's creator", func() {
		RevealSeedSalt(cur, "906", "x")
	})
}

// TestSetGenerativeDropsAnUnusedCommitment covers the small housekeeping
// path: turning generative mode off before any mint must not leave a stale
// commitment that would silently apply to a later run.
func TestSetGenerativeDropsAnUnusedCommitment(cur realm, t *testing.T) {
	c := newTestCollection(cur, "907", 0, 0)
	defer dropTestCollection("907")
	c.creator = callerOf(cur)
	c.generative = true
	c.engine = Engine
	c.saltCommit = sha256Hex("stale")
	c.saltEntropy = 5

	SetGenerative(cur, "907", false)
	uassert.Equal(t, "", c.saltCommit)
	uassert.Equal(t, int64(0), c.saltEntropy)
	uassert.Equal(t, "", c.engine)
	uassert.Equal(t, "none", SeedSaltState("907"))

	SetGenerative(cur, "907", true)
	uassert.Equal(t, Engine, c.engine)
	uassert.True(t, strings.HasSuffix(c.engine, "/nftgen1"))
}
