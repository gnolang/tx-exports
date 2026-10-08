package nft

import (
	"chain"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/samcrew/launchpad/meta/v1"
)

const (
	MetadataStatic  = "static"  // base URI fixed at creation
	MetadataReveal  = "reveal"  // placeholder until one committed reveal
	MetadataMutable = "mutable" // creator may change the base URI until frozen
)

// metadata decides what TokenURI answers. Once frozen, the base URI can never
// change again; only then can traits be committed.
type metadata struct {
	mode           string
	baseURI        string  // empty until a reveal
	placeholderURI string  // reveal: served for every token until Reveal
	commitment     string  // reveal: RevealCommitment of the base URI to come
	committer      address // reveal: the creator who made the commitment
	provenance     string  // reveal: SHA-256 of the ordered metadata manifest
	frozen         bool
	revision       int64 // base URI changes since creation
}

// contentAddressed accepts an IPFS path that resolves to the same files for
// good: a server behind any other scheme could change them at will, and an
// empty CID, a "." or ".." segment, an escape, a query or a fragment could
// make a gateway resolve it elsewhere, a mutable IPNS name included.
func contentAddressed(s string) bool {
	return strings.HasPrefix(s, "ipfs://") && len(s) > 7 && s[7] != '/' &&
		!strings.Contains(s, "/.") && !strings.ContainsAny(s, "%?#") && meta.Image(s) == nil
}

// A base URI is a directory: token n resolves to <base><n>.json.
func validBaseURI(s string) bool {
	return contentAddressed(s) && s[len(s)-1] == '/'
}

func validHash(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// RevealCommitment is what a creator commits to at creation and opens at
// Reveal: sha256("launchpad-reveal-v1|<creator>|<salt>|<base URI>"), with a
// salt of 64 hex digits the creator keeps secret until then. The salt keeps a
// guessed URI from being confirmed before the reveal. The creator's address
// keeps another account from reusing the commitment: a collection's ID does
// not exist yet when its creator commits, so the account stands in for it.
func RevealCommitment(creator address, salt, baseURI string) string {
	h := sha256.Sum256([]byte("launchpad-reveal-v1|" + creator.String() + "|" + salt + "|" + baseURI))
	return hex.EncodeToString(h[:])
}

func newMetadata(mode, baseURI, placeholderURI, commitment, provenance string, creator address) metadata {
	ok := false
	switch mode {
	case MetadataStatic, MetadataMutable:
		ok = validBaseURI(baseURI) && placeholderURI == "" && commitment == "" && provenance == ""
	case MetadataReveal:
		// What is hidden must be content-addressed, or the commitment would
		// say nothing about the files behind it.
		ok = baseURI == "" && contentAddressed(placeholderURI) &&
			strings.HasSuffix(placeholderURI, ".json") &&
			validHash(commitment) && commitment != strings.Repeat("0", 64) &&
			validHash(provenance)
	}
	if !ok {
		panic("launchpad/nft: invalid metadata terms")
	}
	m := metadata{mode: mode, baseURI: baseURI, placeholderURI: placeholderURI,
		commitment: commitment, provenance: provenance, frozen: mode == MetadataStatic}
	if mode == MetadataReveal {
		m.committer = creator
	}
	return m
}

func (m metadata) tokenURI(number int64) string {
	if m.baseURI == "" {
		return m.placeholderURI
	}
	return m.baseURI + strconv.FormatInt(number, 10) + ".json"
}

func emitMetadata(id string, m metadata) {
	chain.Emit("MetadataChanged", "collection", id, "base_uri", m.baseURI,
		"revision", strconv.FormatInt(m.revision, 10),
		"frozen", strconv.FormatBool(m.frozen))
}

// Reveal publishes the base URI committed at creation, with the salt that
// opens the commitment, and fixes it for good. The commitment stays bound to
// the account that created the collection, whoever holds the creator role now.
func Reveal(cur realm, id, baseURI, salt string) {
	m := &creatorOf(cur, id).metadata
	if m.mode != MetadataReveal || m.frozen {
		panic("launchpad/nft: nothing to reveal")
	}
	if !validBaseURI(baseURI) || !validHash(salt) ||
		RevealCommitment(m.committer, salt, baseURI) != m.commitment {
		panic("launchpad/nft: reveal does not match the commitment")
	}
	m.baseURI, m.frozen, m.revision = baseURI, true, 1
	emitMetadata(id, *m)
}

func mutable(cur realm, id string) *metadata {
	m := &creatorOf(cur, id).metadata
	if m.mode != MetadataMutable || m.frozen {
		panic("launchpad/nft: metadata is fixed")
	}
	return m
}

// SetBaseURI points a mutable collection at new metadata. Every change is
// announced with its revision number.
func SetBaseURI(cur realm, id, baseURI string) {
	m := mutable(cur, id)
	if !validBaseURI(baseURI) || baseURI == m.baseURI {
		panic("launchpad/nft: invalid base URI")
	}
	m.baseURI = baseURI
	m.revision++
	emitMetadata(id, *m)
}

// FreezeMetadata gives up the right to change a mutable collection's base URI.
func FreezeMetadata(cur realm, id string) {
	m := mutable(cur, id)
	m.frozen = true
	emitMetadata(id, *m)
}

// CommitTraits records, once, the Merkle root of the collection's traits. It
// waits for frozen metadata so the root cannot outlive the files it describes.
// A leaf is sha256(0x00 || "launchpad-trait-v1|<collection>|<number>|<type>=<value>")
// in a p/samcrew/launchpad/merkle/v1 tree, where neither the type nor the
// value contains "=" or "|": a leaf has then one reading only, and a leaf
// that breaks the rule matches no trait offer. The ledger cannot check the
// root against the files; whoever relies on it must recompute it from them.
func CommitTraits(cur realm, id, root string) {
	c := creatorOf(cur, id)
	if !c.metadata.frozen || c.traitsRoot != "" || !validHash(root) {
		panic("launchpad/nft: traits cannot be committed")
	}
	c.traitsRoot = root
	chain.Emit("TraitsCommitted", "collection", id, "root", root)
}

// TraitsRoot is empty until the creator commits one.
func TraitsRoot(id string) string { return mustCollection(id).traitsRoot }
