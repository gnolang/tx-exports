// Package nftread1 is a read-only aggregation realm for nft58.
//
// Why this exists
//
// The gallery's collection page needs, for every token it shows: the token
// ID, its owner, its traits and its tokenURI. nft58 exposes all four, but
// only one token at a time. Reading a 25-token page therefore cost the
// aggregator ~50 separate `vm/qeval` calls.
//
// Measured on pearl-1 (2026-09-15), a qeval against this node costs about
// 2.4s of fixed overhead before any realm code runs, and only ~0.4s of
// actual work for an SVG-rendering read:
//
//	OwnerOf          2457 ms   (trivial read)
//	TokenAttributes  2529 ms
//	TokenURI         2873 ms   (renders an SVG on chain)
//	GetCollection   21310 ms   (cold)
//
// So the cost is dominated by per-call overhead, not by the work. That is
// exactly the shape of problem batching fixes: one call that loops inside
// the VM pays the 2.4s once instead of 50 times. Collection pages took
// 18.7s (50 tokens), 46.5s (150) and 98.9s (1000-supply) before this.
//
// Why a separate realm instead of an nft59
//
// Adding batch readers to the factory itself would mean a new factory
// realm, which means a new marketplace and offers realm to match, and
// abandoning every collection already minted in nft58. nft58's readers are
// public and pure, so a second realm can call them and aggregate. Nothing
// here holds state or mutates anything: no `cur realm` parameters, no
// writes. If the render pipeline ever changes, this realm can be replaced
// on its own without touching custody of a single token.
//
// Output format
//
// Records are newline-separated and fields are tab-separated, because the
// payload includes data: URIs (which contain commas, semicolons, slashes
// and base64 padding) and trait values (which are user-supplied). Tabs and
// newlines cannot appear in either: nft58 bounds traits to MaxTraitLen and
// rejects control characters in URIs via assertSafeURI. Any field that
// fails to read is emitted empty rather than aborting the batch, so one bad
// token cannot blank out a whole page.
package nftread1

import (
	"strconv"
	"strings"

	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft58"
)

// MaxBatch bounds one call. The binding constraint is not gas (queries are
// metered but generous) but response size: a fully on-chain token URI can
// be hundreds of KB, so 50 of them is already a large HTTP body. The
// gallery pages 25 at a time.
const MaxBatch = 50

func clampLimit(limit int64) int64 {
	if limit <= 0 {
		return 0
	}
	if limit > MaxBatch {
		return MaxBatch
	}
	return limit
}

// traitString flattens a token's attributes into "k=v;k=v".
func traitString(collectionID, tokenID string) string {
	attrs := nft58.TokenAttributes(collectionID, tokenID)
	if len(attrs) == 0 {
		return ""
	}
	var b strings.Builder
	for i, a := range attrs {
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(a.TraitType)
		b.WriteString("=")
		b.WriteString(a.Value)
	}
	return b.String()
}

func ownerString(collectionID, tokenID string) string {
	owner, err := nft58.OwnerOf(collectionID, tokenID)
	if err != nil {
		return ""
	}
	return owner.String()
}

func uriString(collectionID, tokenID string) string {
	uri, err := nft58.TokenURI(collectionID, tokenID)
	if err != nil {
		return ""
	}
	return uri
}

// Cards returns everything a token grid needs, one token per line:
//
//	tokenID \t owner \t traits \t tokenURI
//
// This is the call the collection page should use.
func Cards(collectionID string, offset, limit int64) string {
	ids := nft58.TokensOfCollection(collectionID, offset, clampLimit(limit))
	var b strings.Builder
	for i, id := range ids {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(id)
		b.WriteString("\t")
		b.WriteString(ownerString(collectionID, id))
		b.WriteString("\t")
		b.WriteString(traitString(collectionID, id))
		b.WriteString("\t")
		b.WriteString(uriString(collectionID, id))
	}
	return b.String()
}

// Traits is Cards without the artwork: tokenID \t owner \t traits.
//
// Trait filtering and rarity tables need every token in a collection, but
// not a single pixel of it. Dropping the URIs makes the response small
// enough to cover a 1000-token collection in 20 calls.
func Traits(collectionID string, offset, limit int64) string {
	ids := nft58.TokensOfCollection(collectionID, offset, clampLimit(limit))
	var b strings.Builder
	for i, id := range ids {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(id)
		b.WriteString("\t")
		b.WriteString(ownerString(collectionID, id))
		b.WriteString("\t")
		b.WriteString(traitString(collectionID, id))
	}
	return b.String()
}

// URIs returns tokenID \t tokenURI only.
func URIs(collectionID string, offset, limit int64) string {
	ids := nft58.TokensOfCollection(collectionID, offset, clampLimit(limit))
	var b strings.Builder
	for i, id := range ids {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(id)
		b.WriteString("\t")
		b.WriteString(uriString(collectionID, id))
	}
	return b.String()
}

// Owners returns tokenID \t owner only, for owner counts and "held by"
// views that do not need traits or artwork.
func Owners(collectionID string, offset, limit int64) string {
	ids := nft58.TokensOfCollection(collectionID, offset, clampLimit(limit))
	var b strings.Builder
	for i, id := range ids {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(id)
		b.WriteString("\t")
		b.WriteString(ownerString(collectionID, id))
	}
	return b.String()
}

// Source names the factory this realm reads, so a caller can prove which
// family it is looking at instead of trusting the pkgpath it happened to
// query.
func Source() string {
	return "gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft58"
}

func Render(path string) string {
	if path == "" {
		return "# nftread1\n\nRead-only batch reader for `nft58`.\n\n" +
			"Functions: `Cards`, `Traits`, `URIs`, `Owners` " +
			"(collectionID, offset, limit), max " +
			strconv.Itoa(MaxBatch) + " tokens per call.\n\n" +
			"Records are newline-separated, fields tab-separated.\n"
	}
	return "# nftread1\n\nUnknown path.\n"
}
