// Package media is the pure half of Sinopia's uploaded collections, version
// 2 (docs/uploaded-collections.md §5.1, §0a; mainnet plan §2.1, §3.2 WP-F):
// storage kinds and media types, the typed views of a store (Artwork,
// StoreInfo), the storage badge and the salt-keyed permutation that assigns
// tokens to artworks. It has no state.
//
// v2 against v1: the image header checks and the CIDv1 grammar moved into
// p/safe/v2 (core validates engine media with them, I-15). The functions of
// the same name here delegate to safe/v2, so the asset store
// (r/…/assets/v1), the upload engine (r/…/engines/upload) and core apply
// one implementation. Everything else is v1's code unchanged; the
// permutation keeps its domain "art|upload|perm|v1|" (same algorithm, same
// golden vectors). Frontend twins: chain/perm.ts (Permute, PermKey, Slot),
// chain/cid.ts (CIDv1) and checkImage in chain/upload.ts, pinned by
// docs/test-vectors/upload-v2.json (docs/test-vectors/gen-upload-v2.py).
package media

import (
	"errors"
	"strconv"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
)

// Storage kinds of one artwork.
const (
	KindChain      = 1 // bytes stored in assets/v1
	KindIPFSRaw    = 2 // raw-leaf CIDv1: the CID's digest is the file's sha256 (checked on chain)
	KindIPFSUnixFS = 3 // dag-pb CIDv1: digest of the root node, file sha256 stored separately
)

// Media types (the record byte of assets/v1). GIF is defined for
// completeness but refused by ParseMime (decision D5: svg, png, webp, jpeg).
const (
	MimeSVG  = 1
	MimePNG  = 2
	MimeWebP = 3
	MimeJPEG = 4
	MimeGIF  = 5
)

// Limits (decision D4 and design §4).
const (
	MaxDim         = safe.MaxDim           // 4096 px per side, decompression-bomb guard
	MaxSVGBytes    = safe.MaxSVGImageBytes // 16,384: on-chain SVG (= engine/v2 MaxMediaSVGBytes)
	MaxRasterBytes = 262144                // on-chain png/webp/jpeg per artwork (= engine/v2 MaxMediaBytes)
	MaxIPFSRaw     = 1 << 20               // single raw block
	MaxIPFSUnixFS  = 50 << 20              // declared; the frontend enforces it while streaming
)

// CID codecs (safe/v2).
const (
	CodecRaw   = safe.CodecRaw
	CodecDagPB = safe.CodecDagPB
)

// IPFSScheme prefixes an IPFS URI ("ipfs://<CIDv1>").
const IPFSScheme = safe.IPFSScheme

// PermDomain separates the permutation key from every other platform hash
// (under safe.Domain "art"). Unchanged from v1: same algorithm, same keys.
const PermDomain = "art|upload|perm|v1|"

// Artwork is one record of a store as plain data. It crosses realm
// boundaries as a copy and never points into store state.
type Artwork struct {
	Index                            int64
	Kind, Mime                       int
	Size, Have, Editions, SlotEnd    int64
	SHA256, Digest, CID, Title, Tier string
	Traits                           []string // one value per store trait type ("" = none)
	Complete                         bool
	// JSON escaped once by the store (filled by assets/v1 reads, "" otherwise):
	// TierJSON is the tier name as a JSON string ("" = no tier); TraitsJSON the
	// creator traits as comma-joined {"trait_type":…,"value":…} items in store
	// order ("" = none). Lets token reads avoid per-call escaping (review UP-M1).
	TierJSON, TraitsJSON string
}

// SlotStart is the first slot of the artwork's range [SlotStart, SlotEnd).
func (a Artwork) SlotStart() int64 { return a.SlotEnd - a.Editions }

// MimeType is the artwork's IANA media type.
func (a Artwork) MimeType() string { return MimeType(a.Mime) }

// OnChain reports whether the artwork's bytes live in the store.
func (a Artwork) OnChain() bool { return a.Kind == KindChain }

// URI is "ipfs://<cid>" for an IPFS artwork, "" for on-chain bytes.
func (a Artwork) URI() string {
	if a.Kind == KindChain || a.CID == "" {
		return ""
	}
	return IPFSScheme + a.CID
}

// MimeVerified reports whether the chain checked the file against its
// declared type (UP-I6): on-chain bytes passed CheckImage when their last
// chunk arrived; an IPFS file's type is the creator's claim (the chain never
// sees the bytes; a raw CID binds the bytes, not the type).
func (a Artwork) MimeVerified() bool { return a.Kind == KindChain && a.Complete }

// StoreInfo is a store's header as plain data.
type StoreInfo struct {
	ID                                             string
	Owner                                          address
	Label                                          string
	Sealed                                         bool
	SealedHeight                                   int64
	Artworks, Slots, OnchainN, IPFSN, OnchainBytes int64
	TraitTypes, Tiers                              []string
}

// HasEditions reports whether some artwork of the store has more than one
// edition (slots > artworks).
func (s StoreInfo) HasEditions() bool { return s.Slots > s.Artworks }

// Badge is the store's storage badge (see Badge).
func (s StoreInfo) Badge() string { return Badge(s.OnchainN, s.IPFSN) }

// MimeType is the IANA type of a media constant ("" for an unknown one).
func MimeType(m int) string {
	switch m {
	case MimeSVG:
		return safe.MimeSVG
	case MimePNG:
		return safe.MimePNG
	case MimeWebP:
		return safe.MimeWebP
	case MimeJPEG:
		return safe.MimeJPEG
	case MimeGIF:
		return safe.MimeGIF
	}
	return ""
}

// MimeName is the short name ParseMime accepts ("svg", "png", …).
func MimeName(m int) string {
	switch m {
	case MimeSVG:
		return "svg"
	case MimePNG:
		return "png"
	case MimeWebP:
		return "webp"
	case MimeJPEG:
		return "jpeg"
	case MimeGIF:
		return "gif"
	}
	return ""
}

// ParseMime maps "svg" | "png" | "webp" | "jpeg" to its constant and panics
// on anything else, "gif" included (D5).
func ParseMime(s string) int {
	switch s {
	case "svg":
		return MimeSVG
	case "png":
		return MimePNG
	case "webp":
		return MimeWebP
	case "jpeg":
		return MimeJPEG
	case "gif":
		panic("mime: gif is not supported (svg, png, webp, jpeg)")
	}
	panic("mime: must be svg, png, webp or jpeg, got " + strconv.Quote(s))
}

// KindName is "chain" or "ipfs".
func KindName(k int) string {
	switch k {
	case KindChain:
		return "chain"
	case KindIPFSRaw, KindIPFSUnixFS:
		return "ipfs"
	}
	return ""
}

// MaxBytes is the size cap of one artwork of this kind and type.
func MaxBytes(kind, mime int) int64 {
	switch kind {
	case KindChain:
		if mime == MimeSVG {
			return MaxSVGBytes
		}
		return MaxRasterBytes
	case KindIPFSRaw:
		return MaxIPFSRaw
	case KindIPFSUnixFS:
		return MaxIPFSUnixFS
	}
	return 0
}

// Badge is a store's storage badge from its counters (design §9):
// "onchain", "ipfs", "mixed", or "empty" for a store without artworks.
func Badge(onchainN, ipfsN int64) string {
	switch {
	case onchainN == 0 && ipfsN == 0:
		return "empty"
	case ipfsN == 0:
		return "onchain"
	case onchainN == 0:
		return "ipfs"
	}
	return "mixed"
}

// --- delegated to safe/v2 (one implementation for store, adapter and core) ---

// CheckImage checks a complete file against its declared type (v1
// signature): SVG must pass safe.AssertSVG with MaxSVGBytes (w = h = 0); a
// raster file must carry its type's magic bytes and header dimensions of
// 1..MaxDim per side (safe.ImageDims). Error texts are v1's.
func CheckImage(mime int, data string) (w, h int, err error) {
	switch mime {
	case MimeSVG:
		if err := safe.AssertSVG(data, MaxSVGBytes); err != nil {
			return 0, 0, err
		}
		return 0, 0, nil
	case MimePNG, MimeWebP, MimeJPEG, MimeGIF:
		return safe.ImageDims(MimeType(mime), data)
	}
	return 0, 0, errors.New("media: unknown media type " + strconv.Itoa(mime))
}

// ParseCIDv1 returns the codec (CodecRaw or CodecDagPB) and the sha2-256
// digest as lower-case hex (safe/v2 grammar, unchanged from media/v1).
func ParseCIDv1(s string) (codec int, digestHex string, err error) { return safe.ParseCIDv1(s) }

// CIDFromDigest is the inverse of ParseCIDv1; it panics on an unsupported
// codec or a digest that is not 64 lower-case hex characters.
func CIDFromDigest(codec int, digestHex string) string { return safe.CIDFromDigest(codec, digestHex) }

// IsIPFSURI reports whether s is "ipfs://" + a CIDv1 ParseCIDv1 accepts.
func IsIPFSURI(s string) bool { return safe.IsIPFSURI(s) }

// IsHex32 reports whether s is exactly 64 lower-case hex characters.
func IsHex32(s string) bool { return safe.IsHex32(s) }

// Raw32 decodes exactly 64 lower-case hex characters into 32 raw bytes.
func Raw32(s string) (string, bool) { return safe.Raw32(s) }
