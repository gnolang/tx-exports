package mpt

import (
	"bytes"
	"crypto/keccak256"
	"errors"

	"gno.land/p/onbloc/encoding/rlp"
)

var (
	ErrInvalidRoot      = errors.New("mpt: invalid root length")
	ErrMissingNode      = errors.New("mpt: proof node missing")
	ErrUnexpectedNode   = errors.New("mpt: unexpected node shape")
	ErrInvalidReference = errors.New("mpt: invalid child reference")
	ErrValueMismatch    = errors.New("mpt: value mismatch")
	ErrKeyPresent       = errors.New("mpt: key present")
	ErrKeyAbsent        = errors.New("mpt: key absent")
)

// EmptyRoot is keccak256(rlp("")), the root of an empty Ethereum MPT.
func EmptyRoot() [32]byte {
	return keccak256.Sum256(rlp.EncodeBytes(nil))
}

// Verify verifies an Ethereum Merkle Patricia Trie existence proof. Thin
// wrapper around verifyProof: go-ethereum has no combined verify+compare
// function of its own (callers compare inline at each VerifyProof call site).
func Verify(root []byte, key []byte, value []byte, proof [][]byte) error {
	if len(root) != keccak256.Size {
		return ErrInvalidRoot
	}

	var rootHash [32]byte
	copy(rootHash[:], root)

	// Intentional Gno/onbloc-specific deviation: go-ethereum's VerifyProof
	// has no empty-trie shortcut and errors instead ("proof node 0 ...
	// missing", confirmed by running it against a real empty trie), which
	// would break storage.VerifyAbsence for a slot that was never written.
	if rootHash == EmptyRoot() {
		return ErrKeyAbsent
	}

	found, err := verifyProof(rootHash, key, buildProofDb(proof))
	if err != nil {
		return err
	}

	if found == nil {
		return ErrKeyAbsent
	}

	if !bytes.Equal(found, value) {
		return ErrValueMismatch
	}

	return nil
}

// VerifyAbsence verifies that key is absent from the trie under root. Thin
// wrapper around verifyProof (see Verify).
func VerifyAbsence(root []byte, key []byte, proof [][]byte) error {
	if len(root) != keccak256.Size {
		return ErrInvalidRoot
	}

	var rootHash [32]byte
	copy(rootHash[:], root)

	if rootHash == EmptyRoot() {
		return nil
	}

	found, err := verifyProof(rootHash, key, buildProofDb(proof))
	if err != nil {
		return err
	}

	if found != nil {
		return ErrKeyPresent
	}

	return nil
}

// buildProofDb indexes proof by hash. No go-ethereum counterpart: VerifyProof
// assumes its caller already holds a populated ethdb.KeyValueReader (usually
// via Prove, which this verify-only package doesn't port). This bridges our
// external proof [][]byte contract (what eth_getProof/IBC relaying deliver)
// into that hash-keyed form.
func buildProofDb(proof [][]byte) map[[32]byte][]byte {
	db := make(map[[32]byte][]byte, len(proof))
	for _, n := range proof {
		db[keccak256.Sum256(n)] = n
	}

	return db
}
