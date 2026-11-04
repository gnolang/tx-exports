package assets

import (
	"encoding/hex"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
)

// Fixed artwork record, recBytes long, bucketSize records per avl value
// (design §4; one key per 64 artworks instead of one per artwork):
//
//	off  0  kind u8          (media.Kind*)
//	     1  mime u8          (media.Mime*)
//	     2  size u32         declared byte size
//	     6  have u32         bytes received (= size when complete; ipfs: = size at add)
//	    10  editions u32
//	    14  slotEnd u32      prefix sum of editions, exclusive
//	    18  logOff u32       chain: offset in the byte log (= declared on-chain bytes before it)
//	    22  tier u8          0 = none, else 1-based index into tiers
//	    23  traits [8]u8     per trait type: dictionary index + 1, 0 = none (MaxTraitTypes)
//	    31  sha256 [32]      of the file bytes
//	    63  digest [32]      dag-pb root digest (UnixFS), zero otherwise
//
// All fields are big-endian. A raw CID is derived from sha256.
const (
	recBytes   = 95
	bucketSize = 64

	offKind     = 0
	offMime     = 1
	offSize     = 2
	offHave     = 6
	offEditions = 10
	offSlotEnd  = 14
	offLogOff   = 18
	offTier     = 22
	offTraits   = 23
	offSHA      = offTraits + MaxTraitTypes // 31
	offDigest   = offSHA + 32             // 63
)

type record struct {
	kind, mime                            int
	size, have, editions, slotEnd, logOff int64
	tier                                  int
	traits                                [MaxTraitTypes]int
	sha, digest                           string // 32 raw bytes each
}

func putU32(b []byte, off int, v int64) {
	if v < 0 || v > 0xFFFFFFFF {
		panic("assets: value out of uint32 range")
	}
	b[off], b[off+1], b[off+2], b[off+3] = byte(v>>24), byte(v>>16), byte(v>>8), byte(v)
}

func getU32(s string, off int) int64 {
	return int64(s[off])<<24 | int64(s[off+1])<<16 | int64(s[off+2])<<8 | int64(s[off+3])
}

func (r *record) encode() string {
	b := make([]byte, recBytes)
	b[offKind] = byte(r.kind)
	b[offMime] = byte(r.mime)
	putU32(b, offSize, r.size)
	putU32(b, offHave, r.have)
	putU32(b, offEditions, r.editions)
	putU32(b, offSlotEnd, r.slotEnd)
	putU32(b, offLogOff, r.logOff)
	b[offTier] = byte(r.tier)
	for i := 0; i < MaxTraitTypes; i++ {
		b[offTraits+i] = byte(r.traits[i])
	}
	copy(b[offSHA:offSHA+32], []byte(r.sha))
	copy(b[offDigest:offDigest+32], []byte(r.digest))
	return string(b)
}

func decodeRecord(s string) record {
	r := record{
		kind:     int(s[offKind]),
		mime:     int(s[offMime]),
		size:     getU32(s, offSize),
		have:     getU32(s, offHave),
		editions: getU32(s, offEditions),
		slotEnd:  getU32(s, offSlotEnd),
		logOff:   getU32(s, offLogOff),
		tier:     int(s[offTier]),
		sha:      s[offSHA : offSHA+32],
		digest:   s[offDigest : offDigest+32],
	}
	for i := 0; i < MaxTraitTypes; i++ {
		r.traits[i] = int(s[offTraits+i])
	}
	return r
}

func (r *record) complete() bool { return r.have == r.size }

func (r *record) shaHex() string { return hex.EncodeToString([]byte(r.sha)) }

func (r *record) cid() string {
	switch r.kind {
	case media.KindIPFSRaw:
		return media.CIDFromDigest(media.CodecRaw, r.shaHex())
	case media.KindIPFSUnixFS:
		return media.CIDFromDigest(media.CodecDagPB, hex.EncodeToString([]byte(r.digest)))
	}
	return ""
}

func (r *record) digestHex() string {
	if r.kind != media.KindIPFSUnixFS {
		return ""
	}
	return hex.EncodeToString([]byte(r.digest))
}

// bucket holds up to bucketSize packed records and their titles
// (concatenated, each prefixed by its byte length as one byte).
type bucket struct {
	rec    string
	titles string
}

func (b *bucket) count() int { return len(b.rec) / recBytes }

func (b *bucket) raw(i int) string { return b.rec[i*recBytes : (i+1)*recBytes] }

func (b *bucket) setRaw(i int, enc string) {
	b.rec = b.rec[:i*recBytes] + enc + b.rec[(i+1)*recBytes:]
}

func (b *bucket) title(i int) string {
	off := 0
	for k := 0; k < i; k++ {
		off += 1 + int(b.titles[off])
	}
	n := int(b.titles[off])
	return b.titles[off+1 : off+1+n]
}

// keep trims the bucket to its first n records and titles.
func (b *bucket) keep(n int) {
	off := 0
	for k := 0; k < n; k++ {
		off += 1 + int(b.titles[off])
	}
	b.rec = b.rec[:n*recBytes]
	b.titles = b.titles[:off]
}
