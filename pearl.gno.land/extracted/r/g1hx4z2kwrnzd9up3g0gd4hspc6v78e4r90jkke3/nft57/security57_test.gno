package nft57

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// These tests are written from the attacker's side: each one is an attempt
// to put something on chain that a client would later execute or
// mis-parse. A realm cannot assume every wallet, explorer and frontend
// sanitises what it reads, so the refusal has to happen at write time -
// once minted, a tokenURI is permanent.

// TestSafeURIAcceptsRenderableSchemes pins the schemes a legitimate mint
// still needs, so the hardening cannot silently break normal minting.
func TestSafeURIAcceptsRenderableSchemes(cur realm, t *testing.T) {
	for _, good := range []string{
		"", // no URI: inherits the collection baseURI
		"https://cdn.example.com/1.png",
		"ipfs://bafybeigdyrzt5example/1.json",
		"ar://abc123",
		"data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
		"data:application/json;base64,e30=",
	} {
		uri := good
		uassert.NotPanics(t, cur, func() { assertSafeURI(uri, "tokenURI") })
	}
}

// TestSafeURIRejectsExecutablePayloads is the actual attack: mint into a
// public collection with a script payload as the artwork URI and wait for
// a client to render it. Stored XSS on an immutable record.
func TestSafeURIRejectsExecutablePayloads(cur realm, t *testing.T) {
	for _, bad := range []string{
		"javascript:alert(document.cookie)",
		"JaVaScRiPt:alert(1)",
		"vbscript:msgbox(1)",
		"data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
		"data:text/javascript,alert(1)",
		"file:///etc/passwd",
	} {
		uri := bad
		uassert.PanicsContains(t, cur, "must start with https://", func() {
			assertSafeURI(uri, "tokenURI")
		})
	}
}

// TestMetadataEscapesControlCharacters covers the second half of the same
// idea: a collection name carrying a quote, a backslash or a raw control
// byte must not be able to break out of the JSON document the realm
// serves as token metadata.
func TestMetadataEscapesControlCharacters(t *testing.T) {
	escaped := jsonEscape("a\"b\\c\nd\x01e")
	uassert.Equal(t, `a\"b\\c\nd\u0001e`, escaped)

	// No raw control byte survives the escape.
	for i := 0; i < 0x20; i++ {
		out := jsonEscape(string(rune(i)))
		uassert.False(t, strings.ContainsRune(out, rune(i)))
	}
}

// TestRoyaltyCannotExceedSalePrice keeps the marketplace payout split
// solvent: the royalty is derived from an immutable collection field that
// CreateCollection bounds, so no sale can ever owe more than it took in.
func TestRoyaltyCannotExceedSalePrice(t *testing.T) {
	uassert.True(t, MaxRoyaltyPercent <= 100)
	for _, price := range []int64{1, 1_000_000, 1_000_000_000} {
		royalty := price * int64(MaxRoyaltyPercent) / 100
		uassert.True(t, royalty <= price)
		uassert.True(t, royalty >= 0)
	}
}
