package cards

import "errors"

// A hand-rolled strict standard-base64 decoder: the stdlib decoder costs about
// 35% more gas on a 13 KB deck, which every deck pass pays.

const b64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

var b64Rev = func() [256]byte {
	var t [256]byte
	for i := range t {
		t[i] = 0xff
	}
	for i := 0; i < 64; i++ {
		t[b64Alphabet[i]] = byte(i)
	}
	return t
}()

var errBase64 = errors.New("invalid base64")

// DecodeBase64 decodes padded standard base64 and rejects non-canonical input.
func DecodeBase64(s string) ([]byte, error) {
	if len(s)%4 != 0 {
		return nil, errBase64
	}
	if len(s) == 0 {
		return []byte{}, nil
	}
	pad := 0
	if s[len(s)-1] == '=' {
		pad++
		if s[len(s)-2] == '=' {
			pad++
		}
	}
	out := make([]byte, len(s)/4*3-pad)
	full := len(s) / 4
	if pad > 0 {
		full--
	}
	o := 0
	for g := 0; g < full; g++ {
		i := g * 4
		a, b, c, d := b64Rev[s[i]], b64Rev[s[i+1]], b64Rev[s[i+2]], b64Rev[s[i+3]]
		if (a|b|c|d)&0xc0 != 0 {
			return nil, errBase64
		}
		v := uint32(a)<<18 | uint32(b)<<12 | uint32(c)<<6 | uint32(d)
		out[o] = byte(v >> 16)
		out[o+1] = byte(v >> 8)
		out[o+2] = byte(v)
		o += 3
	}
	if pad > 0 {
		i := full * 4
		a, b := b64Rev[s[i]], b64Rev[s[i+1]]
		if a == 0xff || b == 0xff {
			return nil, errBase64
		}
		if pad == 2 {
			if b&0x0f != 0 {
				return nil, errBase64
			}
			out[o] = a<<2 | b>>4
		} else {
			c := b64Rev[s[i+2]]
			if c == 0xff || c&0x03 != 0 {
				return nil, errBase64
			}
			out[o] = a<<2 | b>>4
			out[o+1] = b<<4 | c>>2
		}
	}
	return out, nil
}
