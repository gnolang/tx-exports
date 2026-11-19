package safe

import (
	"encoding/hex"
	"errors"
	"strconv"
)

// Media checks, moved in from p/media/v1 (image.gno, cid.gno) so core can
// validate an engine's media (mainnet plan §2.1, M-3) without importing an
// upload package. Behaviour and error texts are unchanged ("media: …");
// the frontend twins are chain/cid.ts and the image header check of the
// upload layer (docs/test-vectors/upload-v1.json).

// IANA media types CheckImage and ImageDims understand. GIF is parsed for
// completeness; callers decide which types they accept.
const (
	MimeSVG  = "image/svg+xml"
	MimePNG  = "image/png"
	MimeWebP = "image/webp"
	MimeJPEG = "image/jpeg"
	MimeGIF  = "image/gif"
)

// Media limits.
const (
	MaxDim           = 4096  // px per side, decompression-bomb guard
	MaxSVGImageBytes = 16384 // CheckImage's AssertSVG cap for an SVG file
)

// CID codecs.
const (
	CodecRaw   = 0x55
	CodecDagPB = 0x70
)

// IPFSScheme prefixes an IPFS URI.
const IPFSScheme = "ipfs://"

func mediaErr(msg string) error { return errors.New("media: " + msg) }

// mimeShort is the short name used in error texts ("png", …), "" when the
// type is not a raster type ImageDims parses.
func mimeShort(mime string) string {
	switch mime {
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

// CheckImage checks a complete file against its declared IANA type: an SVG
// must pass AssertSVG with MaxSVGImageBytes; a raster file must carry the
// type's magic bytes and header dimensions of 1..MaxDim per side
// (ImageDims). Nothing else of a raster file is parsed: raster bytes are
// only ever shown through <img> (SA-M3).
func CheckImage(mime, data string) error {
	if mime == MimeSVG {
		return AssertSVG(data, MaxSVGImageBytes)
	}
	_, _, err := ImageDims(mime, data)
	return err
}

// ImageDims returns a raster file's pixel dimensions after checking its
// magic bytes and header (PNG IHDR, WebP VP8/VP8L/VP8X, JPEG SOFn, GIF
// logical screen) and the 1..MaxDim bound per side.
func ImageDims(mime, data string) (w, h int, err error) {
	switch mime {
	case MimePNG:
		w, h, err = pngDims(data)
	case MimeWebP:
		w, h, err = webpDims(data)
	case MimeJPEG:
		w, h, err = jpegDims(data)
	case MimeGIF:
		w, h, err = gifDims(data)
	default:
		return 0, 0, mediaErr("unknown media type " + strconv.Quote(mime))
	}
	if err != nil {
		return 0, 0, err
	}
	if w < 1 || h < 1 || w > MaxDim || h > MaxDim {
		return 0, 0, mediaErr(mimeShort(mime) + ": dimensions " + strconv.Itoa(w) + "x" + strconv.Itoa(h) +
			" outside 1.." + strconv.Itoa(MaxDim))
	}
	return w, h, nil
}

func be16(s string, i int) int { return int(s[i])<<8 | int(s[i+1]) }
func le16(s string, i int) int { return int(s[i]) | int(s[i+1])<<8 }
func le24(s string, i int) int { return int(s[i]) | int(s[i+1])<<8 | int(s[i+2])<<16 }
func be32(s string, i int) int64 {
	return int64(s[i])<<24 | int64(s[i+1])<<16 | int64(s[i+2])<<8 | int64(s[i+3])
}
func le32(s string, i int) int64 {
	return int64(s[i]) | int64(s[i+1])<<8 | int64(s[i+2])<<16 | int64(s[i+3])<<24
}

// pngDims: signature, then the IHDR chunk (length 13) with big-endian
// width and height. The 4-byte CRC after IHDR must be present.
func pngDims(s string) (int, int, error) {
	if len(s) < 33 || s[:8] != "\x89PNG\r\n\x1a\n" {
		return 0, 0, mediaErr("png: bad signature or truncated header")
	}
	if be32(s, 8) != 13 || s[12:16] != "IHDR" {
		return 0, 0, mediaErr("png: first chunk must be IHDR")
	}
	return int(be32(s, 16)), int(be32(s, 20)), nil
}

// webpDims: RIFF container whose size field covers the whole file, form
// type WEBP, then one of the three bitstream headers.
func webpDims(s string) (int, int, error) {
	if len(s) < 30 || s[:4] != "RIFF" || s[8:12] != "WEBP" {
		return 0, 0, mediaErr("webp: bad RIFF/WEBP header or truncated")
	}
	if le32(s, 4)+8 != int64(len(s)) {
		return 0, 0, mediaErr("webp: RIFF size does not match the file size")
	}
	switch s[12:16] {
	case "VP8 ": // lossy: 3-byte frame tag, start code 9d 01 2a, 14-bit dims
		if s[23:26] != "\x9d\x01\x2a" {
			return 0, 0, mediaErr("webp: bad VP8 start code")
		}
		return le16(s, 26) & 0x3fff, le16(s, 28) & 0x3fff, nil
	case "VP8L": // lossless: signature 0x2f, 14-bit width-1 and height-1
		if s[20] != 0x2f {
			return 0, 0, mediaErr("webp: bad VP8L signature")
		}
		bits := le32(s, 21)
		return int(bits&0x3fff) + 1, int((bits>>14)&0x3fff) + 1, nil
	case "VP8X": // extended: 24-bit canvas width-1 and height-1
		return le24(s, 24) + 1, le24(s, 27) + 1, nil
	}
	return 0, 0, mediaErr("webp: unknown bitstream chunk")
}

// jpegDims walks the marker segments after SOI up to the first SOFn
// (C0..CF except C4 DHT, C8 JPG, CC DAC). Reaching SOS or EOI first, or
// running out of bytes, is an error.
func jpegDims(s string) (int, int, error) {
	if len(s) < 4 || s[0] != 0xff || s[1] != 0xd8 || s[2] != 0xff {
		return 0, 0, mediaErr("jpeg: bad SOI")
	}
	i := 2
	for i < len(s) {
		if s[i] != 0xff {
			return 0, 0, mediaErr("jpeg: expected a marker at byte " + strconv.Itoa(i))
		}
		for i < len(s) && s[i] == 0xff { // fill bytes
			i++
		}
		if i >= len(s) {
			break
		}
		m := s[i]
		i++
		switch {
		case m == 0xd8 || m == 0x01 || (m >= 0xd0 && m <= 0xd7):
			continue // standalone markers
		case m == 0xd9 || m == 0xda:
			return 0, 0, mediaErr("jpeg: no frame header before scan data")
		}
		if i+2 > len(s) {
			break
		}
		n := be16(s, i)
		if n < 2 || i+n > len(s) {
			return 0, 0, mediaErr("jpeg: bad segment length")
		}
		if m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc {
			if n < 8 {
				return 0, 0, mediaErr("jpeg: short frame header")
			}
			return be16(s, i+5), be16(s, i+3), nil // width after height
		}
		i += n
	}
	return 0, 0, mediaErr("jpeg: truncated before the frame header")
}

func gifDims(s string) (int, int, error) {
	if len(s) < 13 || (s[:6] != "GIF87a" && s[:6] != "GIF89a") {
		return 0, 0, mediaErr("gif: bad signature or truncated")
	}
	return le16(s, 6), le16(s, 8), nil
}

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

// IsIPFSURI reports whether s is IPFSScheme followed by a CIDv1 that
// ParseCIDv1 accepts.
func IsIPFSURI(s string) bool {
	if len(s) <= len(IPFSScheme) || s[:len(IPFSScheme)] != IPFSScheme {
		return false
	}
	_, _, err := ParseCIDv1(s[len(IPFSScheme):])
	return err == nil
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
// (one pass, table lookups).
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
