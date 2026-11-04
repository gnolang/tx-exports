package media

import (
	"encoding/hex"
	"strconv"
)

// CIDv1 grammar (design §12.1; frontend chain/cid.ts is the twin):
// multibase 'b' (RFC 4648 base32, lower case, no padding) over exactly
// 0x01 · codec · 0x12 · 0x20 · digest[32], codec 0x55 (raw) or 0x70
// (dag-pb). That is 36 bytes = 58 base32 characters + 'b'. The unused two
// trailing bits must be zero, so every CID has exactly one spelling. CIDv0
// ("Qm…"), upper case, other bases, codecs or hash functions are refused.

const (
	b32Alphabet = "abcdefghijklmnopqrstuvwxyz234567"
	cidBytes    = 36
	cidChars    = 58 // ceil(36*8/5)
	mhSha256    = 0x12
	digestLen   = 32
)

// ParseCIDv1 returns the codec (CodecRaw or CodecDagPB) and the sha2-256
// digest as lower-case hex.
func ParseCIDv1(s string) (codec int, digestHex string, err error) {
	if s == "" {
		return 0, "", mediaErr("cid: empty")
	}
	if len(s) >= 2 && s[0] == 'Q' && s[1] == 'm' {
		return 0, "", mediaErr("cid: CIDv0 is not accepted; convert it to CIDv1")
	}
	if s[0] != 'b' {
		return 0, "", mediaErr("cid: multibase must be 'b' (base32 lower case)")
	}
	if len(s) != cidChars+1 {
		return 0, "", mediaErr("cid: expected " + strconv.Itoa(cidChars+1) + " characters, got " + strconv.Itoa(len(s)))
	}
	bz, derr := base32Decode(s[1:])
	if derr != nil {
		return 0, "", derr
	}
	if len(bz) != cidBytes {
		return 0, "", mediaErr("cid: wrong length")
	}
	if bz[0] != 1 {
		return 0, "", mediaErr("cid: version must be 1")
	}
	c := int(bz[1])
	if c != CodecRaw && c != CodecDagPB {
		return 0, "", mediaErr("cid: codec must be raw (0x55) or dag-pb (0x70)")
	}
	if bz[2] != mhSha256 || bz[3] != digestLen {
		return 0, "", mediaErr("cid: multihash must be sha2-256")
	}
	return c, hex.EncodeToString(bz[4:]), nil
}

// CIDFromDigest is the inverse of ParseCIDv1. It panics on an unsupported
// codec or a digest that is not 64 lower-case hex characters.
func CIDFromDigest(codec int, digestHex string) string {
	if codec != CodecRaw && codec != CodecDagPB {
		panic("media: cid: unsupported codec")
	}
	d, ok := Raw32(digestHex)
	if !ok {
		panic("media: cid: digest must be 64 lower-case hex characters")
	}
	bz := make([]byte, 0, cidBytes)
	bz = append(bz, 1, byte(codec), mhSha256, digestLen)
	bz = append(bz, d...)
	return "b" + base32Encode(bz)
}

// IsHex32 reports whether s is exactly 64 lower-case hex characters.
func IsHex32(s string) bool {
	_, ok := Raw32(s)
	return ok
}

// Raw32 decodes exactly 64 lower-case hex characters into 32 raw bytes
// (one pass, table lookups: VM loops cost ~5k gas per character).
func Raw32(s string) (string, bool) {
	if len(s) != 64 {
		return "", false
	}
	out := make([]byte, 32)
	for i := 0; i < 32; i++ {
		hi, lo := hexRev[s[2*i]], hexRev[s[2*i+1]]
		if hi > 15 || lo > 15 {
			return "", false
		}
		out[i] = hi<<4 | lo
	}
	return string(out), true
}

// hexRev and b32Rev map a byte to its digit value, 0xff when it is not a
// lower-case hex / base32 digit.
const (
	hexRev = "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x0a\x0b\x0c\x0d\x0e\x0f\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
	b32Rev = "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x1a\x1b\x1c\x1d\x1e\x1f\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
)

func base32Encode(bz []byte) string {
	out := make([]byte, 0, (len(bz)*8+4)/5)
	var buf uint32
	bits := uint(0)
	for _, b := range bz {
		buf = buf<<8 | uint32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			out = append(out, b32Alphabet[(buf>>bits)&31])
		}
		buf &= (1 << bits) - 1
	}
	if bits > 0 {
		out = append(out, b32Alphabet[(buf<<(5-bits))&31])
	}
	return string(out)
}

// base32Decode is strict: lower-case alphabet only, and the unused
// trailing bits must be zero.
func base32Decode(s string) ([]byte, error) {
	out := make([]byte, 0, len(s)*5/8)
	var buf uint32
	bits := uint(0)
	for i := 0; i < len(s); i++ {
		v := b32Rev[s[i]]
		if v > 31 {
			return nil, mediaErr("cid: invalid base32 character " + strconv.Quote(s[i:i+1]))
		}
		buf = buf<<5 | uint32(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(buf>>bits))
			buf &= (1 << bits) - 1
		}
	}
	if bits >= 5 || buf != 0 {
		return nil, mediaErr("cid: non-canonical base32 padding bits")
	}
	return out, nil
}
