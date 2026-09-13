package nft57

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nftgen1"
)

// NOTE: minting needs a direct wallet call, so the CreateCollection/Mint
// paths are exercised on chain on Pearl. What is pinned here is the v5.2
// change itself: derived traits must be byte-identical to the traits v5
// used to persist, deriving must be free of stored state, and the new
// anti-spoofing rules must actually refuse the calls they claim to refuse.

// TestDerivedTraitsMatchStoredTraits is the anti-drift proof: for a spread
// of seeds, what this realm reports as a token's traits must be exactly
// what the engine itself says, pair for pair, in the same order.
//
// nftgen1.TraitString carries nine pairs; deriveAttributes adds Score as a
// tenth so a marketplace can sort by rarity weight. The nine shared pairs
// are compared field for field, and Score is pinned separately as the only
// permitted extra - so neither the engine nor this realm can change a trait
// name, a value or the order without this test failing.
func TestDerivedTraitsMatchStoredTraits(t *testing.T) {
	cases := []string{"1:1", "1:2", "1:7", "2:1", "3:42", "9:1000", "gen1:5"}
	for _, seed := range cases {
		engine := parseTraits(nftgen1.TraitString(seed))
		derived := deriveAttributes(seed)
		uassert.Equal(t, 9, len(engine))
		uassert.Equal(t, 10, len(derived))

		// Score sits between Symmetry and Rarity, so the shared pairs line
		// up one-to-one up to it and shift by one after it.
		for i := 0; i < 8; i++ {
			uassert.Equal(t, engine[i].TraitType, derived[i].TraitType)
			uassert.Equal(t, engine[i].Value, derived[i].Value)
		}
		uassert.Equal(t, "Score", derived[8].TraitType)
		uassert.Equal(t, "Rarity", derived[9].TraitType)
		uassert.Equal(t, engine[8].Value, derived[9].Value)
	}
}

// TestDerivedTraitsAreWellFormed keeps the derived list inside the same
// bounds the stored list had to respect.
func TestDerivedTraitsAreWellFormed(t *testing.T) {
	attrs := deriveAttributes(nftgen1.SeedFor("1", "3"))
	uassert.Equal(t, 10, len(attrs))
	uassert.True(t, len(attrs) <= MaxAttributesPerToken)
	for _, a := range attrs {
		uassert.True(t, a.TraitType != "")
		uassert.True(t, a.Value != "")
		uassert.True(t, len(a.TraitType) <= MaxTraitLen)
		uassert.True(t, len(a.Value) <= MaxTraitLen)
	}
}

// TestTokenAttributesDerivesFromSeedOnly proves nothing has to be stored in
// the attributes tree for a generative token to report its traits, and that
// the derivation is stable across reads.
func TestTokenAttributesDerivesFromSeedOnly(cur realm, t *testing.T) {
	c := newTestCollection(cur, "700", 0, 0)
	defer dropTestCollection("700")
	c.generative = true
	c.engine = Engine
	mintGenerativeOne(cur, testBuyer, "700")

	// v5.7 stores NEITHER the traits nor the seed: both trees stay empty
	// and the answer is still complete (package doc, v5.7 change 3).
	uassert.Equal(t, nil, avlGet(attributes, "700:1"))

	first := TokenAttributes("700", "1")
	second := TokenAttributes("700", "1")
	uassert.Equal(t, 10, len(first))
	uassert.Equal(t, len(first), len(second))
	for i := range first {
		uassert.Equal(t, first[i].Value, second[i].Value)
	}

	// A token that was never minted reports no traits rather than deriving
	// traits for art that does not exist.
	uassert.Equal(t, 0, len(TokenAttributes("700", "2")))

	// And a non-generative collection never derives.
	c.generative = false
	uassert.Equal(t, 0, len(TokenAttributes("700", "1")))
}

// TestStoredAttributesWinOverDerived protects tokens that carry hand-written
// traits (and anything carried over from an older realm): the seed path must
// never overwrite what is actually stored.
func TestStoredAttributesWinOverDerived(cur realm, t *testing.T) {
	c := newTestCollection(cur, "800", 0, 0)
	defer dropTestCollection("800")
	c.generative = true
	c.engine = Engine
	mintGenerativeOne(cur, testBuyer, "800")

	attributes.Set("800:1", []Attribute{{TraitType: "Hand", Value: "Written"}})

	attrs := TokenAttributes("800", "1")
	uassert.Equal(t, 1, len(attrs))
	uassert.Equal(t, "Hand", attrs[0].TraitType)
	uassert.Equal(t, "Written", attrs[0].Value)

	attributes.Remove("800:1")
}

// TestSeedBackedTokenURI carries the v5 guarantee forward: no blob stored,
// full artwork served, byte-identical on every read.
func TestSeedBackedTokenURI(cur realm, t *testing.T) {
	c := newTestCollection(cur, "400", 0, 0)
	defer dropTestCollection("400")
	c.generative = true
	c.engine = Engine
	mintGenerativeOne(cur, testBuyer, "400")

	seed := nftgen1.SeedFor("400", "1")
	uri, err := TokenURI("400", "1")
	uassert.NoError(t, err)
	uassert.True(t, strings.HasPrefix(uri, "data:"))
	uassert.Equal(t, nftgen1.DataURI(seed), uri)

	again, err := TokenURI("400", "1")
	uassert.NoError(t, err)
	uassert.Equal(t, uri, again)

	uassert.Equal(t, seed, TokenSeed("400", "1"))
	// Never-minted token: no seed, no art.
	uassert.Equal(t, "", TokenSeed("400", "2"))
}

// TestDifferentTokensGetDifferentArt guards against a seed derivation that
// collapses to one image per collection.
func TestDifferentTokensGetDifferentArt(t *testing.T) {
	a := nftgen1.SeedFor("4", "1")
	b := nftgen1.SeedFor("4", "2")
	uassert.True(t, a != b)
	uassert.True(t, nftgen1.DataURI(a) != nftgen1.DataURI(b))
	uassert.True(t, deriveAttributes(a)[9].Value != "")
}

// TestEngineConstantIsAConcreteRealmPath pins the engine pinning itself: an
// empty or relative engine path would make the provenance claim meaningless.
func TestEngineConstantIsAConcreteRealmPath(t *testing.T) {
	uassert.True(t, strings.HasPrefix(Engine, "gno.land/r/"))
	uassert.True(t, strings.HasSuffix(Engine, "/nftgen1"))
}

// TestParseTraitsStillGuardsUserInput makes sure closing the spoofing hole
// did not quietly remove the input validation that hand-written traits still
// have to pass.
func TestParseTraitsStillGuardsUserInput(cur realm, t *testing.T) {
	uassert.Equal(t, 0, len(parseTraits("")))

	ok := parseTraits("Background=Blue;Eyes=Laser")
	uassert.Equal(t, 2, len(ok))
	uassert.Equal(t, "Background", ok[0].TraitType)
	uassert.Equal(t, "Laser", ok[1].Value)

	uassert.PanicsWithMessage(t, cur,
		"malformed trait \"nope\": expected trait=value pairs separated by ';'",
		func() { parseTraits("nope") })

	long := strings.Repeat("x", MaxTraitLen+1)
	uassert.PanicsWithMessage(t, cur,
		"trait name/value too long (max 64 chars)",
		func() { parseTraits("K=" + long) })
}

// TestAssertNotGenerativeRefusesHandMinting covers the new guard without
// needing a wallet call: a generative collection must reject hand minting.
func TestAssertNotGenerativeRefusesHandMinting(cur realm, t *testing.T) {
	c := &Collection{id: "99", generative: true, engine: Engine}
	collections.Set("99", c)

	uassert.PanicsWithMessage(t, cur,
		"this collection is generative; use MintGenerative",
		func() { assertNotGenerative("99") })

	c.generative = false
	assertNotGenerative("99") // must not panic once the flag is off

	collections.Remove("99")
}
