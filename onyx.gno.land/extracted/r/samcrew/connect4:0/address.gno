package connect4

// The chain decodes four texts to the same address: the bech32 form it gives
// a caller, that form in capitals, and the bech32m checksum in either case.
// An address argument stored as text and later compared with a caller's
// address must be that first form. canonical reads the text itself, which
// costs far less gas than decoding and re-encoding it. It is the check of
// gno.land/p/samcrew/launchpad/meta/v1 (ValidAddress), copied so this realm
// does not depend on that package being published.

// bech32Value holds, for each character of the bech32 alphabet
// "qpzry9x8gf2tvdw0s3jn54khce6mua7l", its 5-bit value plus one. Zero marks
// every other byte, capitals included.
var bech32Value = [256]byte{
	'q': 1, 'p': 2, 'z': 3, 'r': 4, 'y': 5, '9': 6, 'x': 7, '8': 8,
	'g': 9, 'f': 10, '2': 11, 't': 12, 'v': 13, 'd': 14, 'w': 15, '0': 16,
	's': 17, '3': 18, 'j': 19, 'n': 20, '5': 21, '4': 22, 'k': 23, 'h': 24,
	'c': 25, 'e': 26, '6': 27, 'm': 28, 'u': 29, 'a': 30, '7': 31, 'l': 32,
}

// bech32Gen[t] is the XOR of the BIP-173 generators selected by the five
// bits of t: one table read per character instead of five tests.
var bech32Gen = [32]uint32{
	0x00000000, 0x3b6a57b2, 0x26508e6d, 0x1d3ad9df,
	0x1ea119fa, 0x25cb4e48, 0x38f19797, 0x039bc025,
	0x3d4233dd, 0x0628646f, 0x1b12bdb0, 0x2078ea02,
	0x23e32a27, 0x18897d95, 0x05b3a44a, 0x3ed9f3f8,
	0x2a1462b3, 0x117e3501, 0x0c44ecde, 0x372ebb6c,
	0x34b57b49, 0x0fdf2cfb, 0x12e5f524, 0x298fa296,
	0x1756516e, 0x2c3c06dc, 0x3106df03, 0x0a6c88b1,
	0x09f74894, 0x329d1f26, 0x2fa7c6f9, 0x14cd914b,
}

// The checksum state once the address prefix "g" has been absorbed, which
// BIP-173 expands to the values 3, 0, 7.
const bech32PrefixState uint32 = 0x8c07

// canonical reports whether a is "g1", then 38 lowercase bech32 characters
// whose checksum is the original bech32 one: the form a caller's address has.
func canonical(a address) bool {
	s := string(a)
	if len(s) != 40 || s[0] != 'g' || s[1] != '1' {
		return false
	}
	chk := bech32PrefixState
	for i := 2; i < 40; i++ {
		v := bech32Value[s[i]]
		if v == 0 {
			return false
		}
		chk = (chk&0x1ffffff)<<5 ^ uint32(v-1) ^ bech32Gen[chk>>25]
	}
	return chk == 1 // 1 is bech32; bech32m ends on 0x2bc830a3
}
