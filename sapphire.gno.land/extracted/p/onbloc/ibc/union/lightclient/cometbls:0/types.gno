package cometbls

import (
	"crypto/sha256"

	"gno.land/p/nt/ufmt/v0"
)

// MerkleRoot is the commitment root (app hash).
// Mirrors ibc.core.commitment.v1.MerkleRoot.
type MerkleRoot struct {
	Hash []byte
}

// GetHash implements RootI interface
func (mr MerkleRoot) GetHash() []byte {
	return mr.Hash
}

// Empty returns true if the root is empty
func (mr MerkleRoot) Empty() bool {
	return len(mr.GetHash()) == 0
}

// validateHash returns an error if the hash is not empty, but its
// size != tmhash.Size.
func validateHash(h []byte) error {
	if len(h) > 0 && len(h) != sha256.Size {
		return ufmt.Errorf(
			"expected size to be %d bytes, got %d bytes",
			sha256.Size,
			len(h),
		)
	}

	return nil
}
