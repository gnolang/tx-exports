package mpt

import (
	"bytes"
	"crypto/keccak256"
	"errors"

	"gno.land/p/onbloc/encoding/rlp"
)

var (
	ErrEmptyProof       = errors.New("mpt: empty proof")
	ErrInvalidRoot      = errors.New("mpt: invalid root length")
	ErrUnexpectedNode   = errors.New("mpt: unexpected node shape")
	ErrInvalidReference = errors.New("mpt: invalid child reference")
	ErrPathMismatch     = errors.New("mpt: path mismatch")
	ErrValueMismatch    = errors.New("mpt: value mismatch")
	ErrKeyPresent       = errors.New("mpt: key present")
	ErrKeyAbsent        = errors.New("mpt: key absent")
	ErrUnusedProof      = errors.New("mpt: unused proof nodes")
)

// EmptyRoot is keccak256(rlp("")), the root of an empty Ethereum MPT.
func EmptyRoot() [32]byte {
	return keccak256.Sum256(rlp.EncodeBytes(nil))
}

// Verify verifies an Ethereum Merkle Patricia Trie existence proof.
//
// root is the 32-byte trie root. key is expanded to nibbles and matched against
// the proof path. proof contains raw RLP-encoded nodes, ordered from root to
// leaf. value is the RLP string payload stored at the leaf or branch value slot.
func Verify(root []byte, key []byte, value []byte, proof [][]byte) error {
	result, err := walk(root, keybytesToNibbles(key), proof)
	if err != nil {
		return err
	}

	if !result.found {
		return ErrKeyAbsent
	}

	if !bytes.Equal(result.value, value) {
		return ErrValueMismatch
	}

	return nil
}

// VerifyAbsence verifies that key is absent from the trie under root.
func VerifyAbsence(root []byte, key []byte, proof [][]byte) error {
	result, err := walk(root, keybytesToNibbles(key), proof)
	if err != nil {
		return err
	}

	if result.found {
		return ErrKeyPresent
	}

	return nil
}

type walkResult struct {
	found bool
	value []byte
}

// isBytesNode reports whether an RLP value carries a byte payload (a string or
// single byte) rather than a nested list.
func isBytesNode(v rlp.Value) bool {
	return v.Kind == rlp.KindString || v.Kind == rlp.KindByte
}

func walk(root []byte, path []byte, proof [][]byte) (walkResult, error) {
	if len(root) != keccak256.Size {
		return walkResult{}, ErrInvalidRoot
	}

	if len(proof) == 0 {
		emptyRoot := EmptyRoot()
		if bytes.Equal(root, emptyRoot[:]) {
			return walkResult{found: false}, nil
		}

		return walkResult{}, ErrEmptyProof
	}

	if err := matchHash(root, proof[0]); err != nil {
		return walkResult{}, err
	}

	proofIndex := 0
	node := proof[0]
	pos := 0

	for {
		v, err := rlp.DecodeValue(node)
		if err != nil {
			return walkResult{}, err
		}

		if v.Kind != rlp.KindList {
			return walkResult{}, ErrUnexpectedNode
		}

		switch len(v.List) {
		case 17:
			if pos == len(path) {
				value := v.List[16]
				if !isBytesNode(value) {
					return walkResult{}, ErrUnexpectedNode
				}

				if len(value.Bytes) == 0 {
					return finishWalk(walkResult{found: false}, proofIndex, proof)
				}

				return finishWalk(walkResult{found: true, value: value.Bytes}, proofIndex, proof)
			}

			child := v.List[path[pos]]
			if !isBytesNode(child) {
				return walkResult{}, ErrUnexpectedNode
			}

			if len(child.Bytes) == 0 {
				return finishWalk(walkResult{found: false}, proofIndex, proof)
			}

			next, nextIndex, err := resolveReference(child.Bytes, proof, proofIndex)
			if err != nil {
				return walkResult{}, err
			}

			proofIndex = nextIndex
			node = next
			pos++

		case 2:
			if !isBytesNode(v.List[0]) {
				return walkResult{}, ErrUnexpectedNode
			}

			leaf, partial, err := compactDecode(v.List[0].Bytes)
			if err != nil {
				return walkResult{}, err
			}

			if !hasPrefix(path[pos:], partial) {
				return finishWalk(walkResult{found: false}, proofIndex, proof)
			}

			pos += len(partial)

			if leaf {
				if pos != len(path) {
					return finishWalk(walkResult{found: false}, proofIndex, proof)
				}

				value := v.List[1]
				if !isBytesNode(value) {
					return walkResult{}, ErrUnexpectedNode
				}

				return finishWalk(walkResult{found: true, value: value.Bytes}, proofIndex, proof)
			}

			child := v.List[1]
			if !isBytesNode(child) {
				return walkResult{}, ErrUnexpectedNode
			}

			next, nextIndex, err := resolveReference(child.Bytes, proof, proofIndex)
			if err != nil {
				return walkResult{}, err
			}

			proofIndex = nextIndex
			node = next

		default:
			return walkResult{}, ErrUnexpectedNode
		}
	}
}

func finishWalk(result walkResult, proofIndex int, proof [][]byte) (walkResult, error) {
	if proofIndex != len(proof)-1 {
		return walkResult{}, ErrUnusedProof
	}

	return result, nil
}

func resolveReference(ref []byte, proof [][]byte, proofIndex int) ([]byte, int, error) {
	if len(ref) == 0 {
		return nil, proofIndex, ErrInvalidReference
	}

	if len(ref) < keccak256.Size {
		return ref, proofIndex, nil
	}

	if len(ref) != keccak256.Size {
		return nil, proofIndex, ErrInvalidReference
	}

	nextIndex := proofIndex + 1
	if nextIndex >= len(proof) {
		return nil, proofIndex, ErrEmptyProof
	}

	if err := matchHash(ref, proof[nextIndex]); err != nil {
		return nil, proofIndex, err
	}

	return proof[nextIndex], nextIndex, nil
}

func matchHash(expected []byte, encodedNode []byte) error {
	h := keccak256.Sum256(encodedNode)
	if !bytes.Equal(expected, h[:]) {
		return ErrInvalidReference
	}

	return nil
}

func keybytesToNibbles(key []byte) []byte {
	out := make([]byte, 0, len(key)*2)
	for _, b := range key {
		out = append(out, b>>4, b&0x0f)
	}

	return out
}

func compactDecode(encoded []byte) (bool, []byte, error) {
	if len(encoded) == 0 {
		return false, nil, ErrPathMismatch
	}

	flag := encoded[0] >> 4
	if flag > 3 {
		return false, nil, ErrPathMismatch
	}

	leaf := (flag & 2) != 0
	odd := (flag & 1) != 0

	out := make([]byte, 0, len(encoded)*2)
	if odd {
		out = append(out, encoded[0]&0x0f)
	} else if encoded[0]&0x0f != 0 {
		return false, nil, ErrPathMismatch
	}

	for i := 1; i < len(encoded); i++ {
		out = append(out, encoded[i]>>4, encoded[i]&0x0f)
	}
	// extensions nodes must contain at least one path nibble.
	// empty extension paths are non-canonical because they admit
	// alternative proof encoding.
	if !leaf && len(out) == 0 {
		return false, nil, ErrPathMismatch
	}

	return leaf, out, nil
}

func hasPrefix(path []byte, prefix []byte) bool {
	if len(prefix) > len(path) {
		return false
	}

	for i := range prefix {
		if path[i] != prefix[i] {
			return false
		}
	}

	return true
}
