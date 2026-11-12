// Package cards implements the byte-level primitives of the gno poker protocol
// (docs/protocol.md sections 1 to 4): the group prime, seed derivations, the
// seed permutation, deck parsing and validation, deck Merkle trees and the
// derivation of official cards from revealed seeds. It does no modular
// exponentiation; callers that need it use crypto/modexp.
package cards

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
)

const (
	CardLen  = 256
	DeckSize = 52
	DeckLen  = CardLen * DeckSize
	ProofLen = 6 * 32

	// PHex is the RFC 3526 2048-bit MODP group (group 14) prime.
	PHex = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74" +
		"020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" +
		"4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" +
		"ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" +
		"98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb" +
		"9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" +
		"e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718" +
		"3995497cea956ae515d2261898fa051015728e5a8aacaa68ffffffffffffffff"

	// CanonRootHex is the Merkle root of the canonical deck [m_0 .. m_51].
	// TestCanonRoot recomputes it with crypto/modexp.
	CanonRootHex = "cbbd0f99d1b6d995ea84edbcf80a62c245ea59240ccee3fde85b87bd35077030"

	tagCard    = "gno-poker/card/v1"
	tagCommit  = "gno-poker/commit/v1"
	tagShufKey = "gno-poker/shufkey/v1"
	tagCardKey = "gno-poker/cardkey/v1"
	tagPerm    = "gno-poker/perm/v1"
)

var pBytes = mustHex(PHex)

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// P returns a copy of the prime as 256 big-endian bytes.
func P() []byte {
	out := make([]byte, CardLen)
	copy(out, pBytes)
	return out
}

// CanonRoot returns the hardcoded canonical deck root.
func CanonRoot() []byte {
	return mustHex(CanonRootHex)
}

func hashParts(parts ...[]byte) []byte {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	buf := make([]byte, 0, n)
	for _, p := range parts {
		buf = append(buf, p...)
	}
	h := sha256.Sum256(buf)
	return h[:]
}

func tweak(k []byte) []byte {
	k[0] |= 0x80
	k[31] |= 0x01
	return k
}

// Commit returns H("gno-poker/commit/v1" || seed).
func Commit(seed []byte) []byte {
	return hashParts([]byte(tagCommit), seed)
}

// ShuffleKey returns the shuffle exponent e derived from seed.
func ShuffleKey(seed []byte) []byte {
	return tweak(hashParts([]byte(tagShufKey), seed))
}

// CardKey returns the card key k_i derived from seed for deck position i.
func CardKey(seed []byte, i int) []byte {
	return tweak(hashParts([]byte(tagCardKey), seed, []byte{byte(i)}))
}

// CardPreimage returns the 256-byte value x of card c; the plaintext card is
// m_c = x^2 mod P.
func CardPreimage(c int) []byte {
	out := make([]byte, 0, CardLen)
	for k := 0; k < 8; k++ {
		out = append(out, hashParts([]byte(tagCard), []byte{byte(c), byte(k)})...)
	}
	return out
}

// Permutation returns the Fisher-Yates permutation of 0..51 determined by seed.
func Permutation(seed []byte) []int {
	a := make([]int, DeckSize)
	for i := range a {
		a[i] = i
	}
	prefix := make([]byte, 0, len(tagPerm)+len(seed)+4)
	prefix = append(prefix, []byte(tagPerm)...)
	prefix = append(prefix, seed...)
	var block []byte
	pos := 32
	ctr := uint32(0)
	next := func() uint64 {
		if pos >= 32 {
			ctrB := []byte{byte(ctr >> 24), byte(ctr >> 16), byte(ctr >> 8), byte(ctr)}
			block = hashParts(prefix, ctrB)
			ctr++
			pos = 0
		}
		w := uint64(block[pos])<<24 | uint64(block[pos+1])<<16 | uint64(block[pos+2])<<8 | uint64(block[pos+3])
		pos += 4
		return w
	}
	for i := DeckSize - 1; i >= 1; i-- {
		n := uint64(i + 1)
		limit := ((uint64(1) << 32) / n) * n
		x := next()
		for x >= limit {
			x = next()
		}
		j := int(x % n)
		a[i], a[j] = a[j], a[i]
	}
	return a
}

// IsValidElement reports whether 1 < v < P for a 256-byte big-endian v.
func IsValidElement(v []byte) bool {
	if len(v) != CardLen {
		return false
	}
	if bytes.Compare(v, pBytes) >= 0 {
		return false
	}
	for i := 0; i < CardLen-1; i++ {
		if v[i] != 0 {
			return true
		}
	}
	return v[CardLen-1] > 1
}

// DecodeElement decodes one base64 deck element and checks its range.
func DecodeElement(b64 string) ([]byte, error) {
	v, err := DecodeBase64(b64)
	if err != nil {
		return nil, errors.New("invalid base64 element")
	}
	if len(v) != CardLen {
		return nil, errors.New("element must be 256 bytes")
	}
	if !IsValidElement(v) {
		return nil, errors.New("element out of range")
	}
	return v, nil
}

// ParseDeck decodes a base64 deck, validates every element (1 < v < P, no
// duplicates) and returns the raw deck bytes and its Merkle root.
func ParseDeck(b64 string) ([]byte, []byte, error) {
	deck, err := DecodeBase64(b64)
	if err != nil {
		return nil, nil, errors.New("invalid base64 deck")
	}
	if len(deck) != DeckLen {
		return nil, nil, errors.New("deck must be 13312 bytes")
	}
	leaves := make([][]byte, 64)
	seen := make(map[string]bool, DeckSize)
	for i := 0; i < DeckSize; i++ {
		el := deck[i*CardLen : (i+1)*CardLen]
		if !IsValidElement(el) {
			return nil, nil, errors.New("deck element out of range")
		}
		leaf := LeafHash(el)
		if seen[string(leaf)] {
			return nil, nil, errors.New("duplicate deck element")
		}
		seen[string(leaf)] = true
		leaves[i] = leaf
	}
	return deck, rootFromLeaves(leaves), nil
}

// EncodeDeck returns the standard base64 encoding of raw deck bytes.
func EncodeDeck(deck []byte) string {
	return base64.StdEncoding.EncodeToString(deck)
}

// LeafHash returns H(0x00 || element).
func LeafHash(el []byte) []byte {
	return hashParts([]byte{0}, el)
}

func nodeHash(l, r []byte) []byte {
	return hashParts([]byte{1}, l, r)
}

func rootFromLeaves(leaves [][]byte) []byte {
	level := make([][]byte, 64)
	zero := make([]byte, 32)
	for i := 0; i < 64; i++ {
		if i < DeckSize {
			level[i] = leaves[i]
		} else {
			level[i] = zero
		}
	}
	for len(level) > 1 {
		next := make([][]byte, len(level)/2)
		for i := range next {
			next[i] = nodeHash(level[2*i], level[2*i+1])
		}
		level = next
	}
	return level[0]
}

func deckLeaves(deck []byte) [][]byte {
	leaves := make([][]byte, 64)
	for i := 0; i < DeckSize; i++ {
		leaves[i] = LeafHash(deck[i*CardLen : (i+1)*CardLen])
	}
	return leaves
}

// MerkleRoot returns the root of a raw 13312-byte deck.
func MerkleRoot(deck []byte) []byte {
	if len(deck) != DeckLen {
		panic("deck must be 13312 bytes")
	}
	return rootFromLeaves(deckLeaves(deck))
}

// MerkleProof returns the 192-byte proof for position i of a raw deck.
func MerkleProof(deck []byte, i int) []byte {
	if len(deck) != DeckLen || i < 0 || i >= DeckSize {
		panic("invalid proof request")
	}
	level := make([][]byte, 64)
	leaves := deckLeaves(deck)
	zero := make([]byte, 32)
	for k := 0; k < 64; k++ {
		if k < DeckSize {
			level[k] = leaves[k]
		} else {
			level[k] = zero
		}
	}
	proof := make([]byte, 0, ProofLen)
	idx := i
	for len(level) > 1 {
		proof = append(proof, level[idx^1]...)
		next := make([][]byte, len(level)/2)
		for k := range next {
			next[k] = nodeHash(level[2*k], level[2*k+1])
		}
		level = next
		idx >>= 1
	}
	return proof
}

// VerifyProof checks that el sits at position i under root.
func VerifyProof(root, el []byte, i int, proof []byte) bool {
	if len(root) != 32 || len(el) != CardLen || len(proof) != ProofLen || i < 0 || i >= DeckSize {
		return false
	}
	h := LeafHash(el)
	for l := 0; l < 6; l++ {
		sib := proof[l*32 : (l+1)*32]
		if (i>>uint(l))&1 == 0 {
			h = nodeHash(h, sib)
		} else {
			h = nodeHash(sib, h)
		}
	}
	return bytes.Equal(h, root)
}

// OfficialCards maps every deck position to its card index given the
// permutations of hand players 0..n-1.
func OfficialCards(perms [][]int) []int {
	out := make([]int, DeckSize)
	for i := 0; i < DeckSize; i++ {
		idx := i
		for j := len(perms) - 1; j >= 0; j-- {
			idx = perms[j][idx]
		}
		out[i] = idx
	}
	return out
}

// DecodeHex decodes lowercase hex of exactly n bytes.
func DecodeHex(s string, n int) ([]byte, error) {
	if len(s) != 2*n {
		return nil, errors.New("hex value has wrong length")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return nil, errors.New("hex must be lowercase")
		}
	}
	return hex.DecodeString(s)
}

// EncodeHex returns lowercase hex.
func EncodeHex(b []byte) string {
	return hex.EncodeToString(b)
}

// CardString renders card index c as e.g. "As", "Td", "2c".
func CardString(c int) string {
	if c < 0 || c >= DeckSize {
		return "??"
	}
	return string("23456789TJQKA"[c%13]) + string("cdhs"[c/13])
}
