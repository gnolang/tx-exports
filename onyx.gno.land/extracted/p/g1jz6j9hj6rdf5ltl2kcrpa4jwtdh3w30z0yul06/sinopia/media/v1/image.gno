package media

import (
	"strconv"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
)

// CheckImage checks a complete file against its declared type: the magic
// bytes and the header's pixel dimensions (each 1..MaxDim, the
// decompression-bomb guard). SVG has no header dimensions (w, h = 0) and
// must pass safe.AssertSVG with the on-chain cap MaxSVGBytes (§0a), the same
// allowlist core applies to every render. Nothing else of a raster file is
// parsed: raster bytes are only ever shown through <img> (SA-M3).
func CheckImage(mime int, data string) (w, h int, err error) {
	switch mime {
	case MimeSVG:
		if err := safe.AssertSVG(data, MaxSVGBytes); err != nil {
			return 0, 0, err
		}
		return 0, 0, nil
	case MimePNG:
		w, h, err = pngDims(data)
	case MimeWebP:
		w, h, err = webpDims(data)
	case MimeJPEG:
		w, h, err = jpegDims(data)
	case MimeGIF:
		w, h, err = gifDims(data)
	default:
		return 0, 0, mediaErr("unknown media type " + strconv.Itoa(mime))
	}
	if err != nil {
		return 0, 0, err
	}
	if w < 1 || h < 1 || w > MaxDim || h > MaxDim {
		return 0, 0, mediaErr(MimeName(mime) + ": dimensions " + strconv.Itoa(w) + "x" + strconv.Itoa(h) +
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
