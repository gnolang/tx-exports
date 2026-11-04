// Package media is the pure half of Sinopia's uploaded collections
// (docs/uploaded-collections.md §5.1, §0a): media kinds and types, the CIDv1
// grammar the platform accepts, image header checks, and the salt-keyed
// permutation that assigns tokens to artworks. It has no state; the asset
// store (r/…/assets/v1), the upload engine (r/…/engines/upload) and the
// frontend (chain/cid.ts, chain/perm.ts) share these definitions, pinned by
// the golden vectors in docs/test-vectors/upload-v1.json.
package media

import (
	"errors"
	"strconv"
)

// Storage kinds of one artwork.
const (
	KindChain      = 1 // bytes stored in assets/v1
	KindIPFSRaw    = 2 // raw-leaf CIDv1: the CID's digest is the file's sha256 (checked on chain)
	KindIPFSUnixFS = 3 // dag-pb CIDv1: digest of the root node, file sha256 stored separately
)

// Media types. GIF is defined for completeness but refused by ParseMime
// (decision D5: svg, png, webp, jpeg only).
const (
	MimeSVG  = 1
	MimePNG  = 2
	MimeWebP = 3
	MimeJPEG = 4
	MimeGIF  = 5
)

// Limits (decision D4 and design §4).
const (
	MaxDim         = 4096   // px per side, decompression-bomb guard
	MaxSVGBytes    = 16384  // on-chain SVG: AssertSVG costs ~30-50k gas/B (WP0)
	MaxRasterBytes = 262144 // on-chain png/webp/jpeg per artwork
	MaxIPFSRaw     = 1 << 20  // single raw block
	MaxIPFSUnixFS  = 50 << 20 // declared; the frontend enforces it while streaming
)

// CID codecs.
const (
	CodecRaw   = 0x55
	CodecDagPB = 0x70
)

// PermDomain separates the permutation key from every other platform hash
// (under safe.Domain "art").
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

// MimeType is the IANA type of a media constant ("" for an unknown one).
func MimeType(m int) string {
	switch m {
	case MimeSVG:
		return "image/svg+xml"
	case MimePNG:
		return "image/png"
	case MimeWebP:
		return "image/webp"
	case MimeJPEG:
		return "image/jpeg"
	case MimeGIF:
		return "image/gif"
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

func mediaErr(msg string) error { return errors.New("media: " + msg) }
