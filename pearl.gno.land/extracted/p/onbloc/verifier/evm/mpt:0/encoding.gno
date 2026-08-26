package mpt

// keybytesToHex mirrors keybytesToHex.
// Reference:
// https://github.com/ethereum/go-ethereum/blob/v1.10.26/trie/encoding.go#L96-L104
func keybytesToHex(str []byte) []byte {
	l := len(str)*2 + 1
	nibbles := make([]byte, l)

	for i, b := range str {
		nibbles[i*2] = b / 16
		nibbles[i*2+1] = b % 16
	}

	nibbles[l-1] = 16

	return nibbles
}

// compactToHex mirrors compactToHex exactly, reusing keybytesToHex the same
// way: base[0] is compact's flag nibble, <2 means extension (drop the
// terminator keybytesToHex appended), and the low bit of the flag says
// whether to chop 1 or 2 leading nibbles (odd vs even length).
// Reference:
// https://github.com/ethereum/go-ethereum/blob/v1.10.26/trie/encoding.go#L82-L92
func compactToHex(compact []byte) []byte {
	if len(compact) == 0 {
		return compact
	}

	base := keybytesToHex(compact)
	if base[0] < 2 {
		base = base[:len(base)-1]
	}

	chop := 2 - base[0]&1

	return base[chop:]
}

// hasTerm reports whether a hex key has the terminator flag.
// Reference:
// https://github.com/ethereum/go-ethereum/blob/v1.10.26/trie/encoding.go#L143-L145
func hasTerm(s []byte) bool {
	return len(s) > 0 && s[len(s)-1] == 16
}
