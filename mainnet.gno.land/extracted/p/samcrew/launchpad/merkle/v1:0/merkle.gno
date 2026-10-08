// Package merkle verifies sorted-pair SHA-256 Merkle proofs with domain-separated leaves.
package merkle

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

const MaxDepth = 32

type Hash = [32]byte

var ErrHash = errors.New("launchpad/merkle: hash must be 64 hex characters")

func Leaf(data []byte) Hash {
	buf := make([]byte, 0, len(data)+1)
	buf = append(buf, 0x00)
	buf = append(buf, data...)
	return sha256.Sum256(buf)
}

func node(a, b Hash) Hash {
	if bytes.Compare(a[:], b[:]) > 0 {
		a, b = b, a
	}
	buf := make([]byte, 0, 65)
	buf = append(buf, 0x01)
	buf = append(buf, a[:]...)
	buf = append(buf, b[:]...)
	return sha256.Sum256(buf)
}

func Root(leaves []Hash) Hash {
	if len(leaves) == 0 {
		panic("launchpad/merkle: no leaves")
	}
	level := append([]Hash{}, leaves...)
	for len(level) > 1 {
		next := make([]Hash, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				next = append(next, level[i])
			} else {
				next = append(next, node(level[i], level[i+1]))
			}
		}
		level = next
	}
	return level[0]
}

func Proof(leaves []Hash, index int) []Hash {
	if index < 0 || index >= len(leaves) {
		panic("launchpad/merkle: index out of range")
	}
	level := append([]Hash{}, leaves...)
	proof := []Hash{}
	for len(level) > 1 {
		next := make([]Hash, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				next = append(next, level[i])
				continue
			}
			if i == index {
				proof = append(proof, level[i+1])
			} else if i+1 == index {
				proof = append(proof, level[i])
			}
			next = append(next, node(level[i], level[i+1]))
		}
		index /= 2
		level = next
	}
	return proof
}

func Verify(root, leaf Hash, proof []Hash) bool {
	if len(proof) > MaxDepth {
		return false
	}
	h := leaf
	for _, p := range proof {
		h = node(h, p)
	}
	return h == root
}

func ParseHash(s string) (Hash, error) {
	var h Hash
	if len(s) != 64 {
		return h, ErrHash
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return h, ErrHash
	}
	copy(h[:], b)
	return h, nil
}

func ParseProof(s string) ([]Hash, error) {
	if s == "" {
		return []Hash{}, nil
	}
	parts := strings.Split(s, ",")
	if len(parts) > MaxDepth {
		return nil, errors.New("launchpad/merkle: proof too long")
	}
	out := make([]Hash, len(parts))
	for i, p := range parts {
		h, err := ParseHash(p)
		if err != nil {
			return nil, err
		}
		out[i] = h
	}
	return out, nil
}

func FormatHash(h Hash) string { return hex.EncodeToString(h[:]) }
