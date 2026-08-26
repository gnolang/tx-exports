package zkgm

import (
	"crypto/keccak256"
	"encoding/binary"

	u256 "gno.land/p/onbloc/math/uint256"
)

func DeriveBatchSalt(index *u256.Uint, salt [32]byte) [32]byte {
	var input [64]byte

	putUint256BE(input[:32], index)
	copy(input[32:], salt[:])

	return keccak256.Sum256(input[:])
}

func TintForwardSalt(salt [32]byte) [32]byte {
	var out [32]byte
	for i := range salt {
		out[i] = salt[i] | FORWARD_SALT_MAGIC[i]
	}

	return out
}

func IsForwardedPacket(salt [32]byte) bool {
	for i := range salt {
		if salt[i]&FORWARD_SALT_MAGIC[i] != FORWARD_SALT_MAGIC[i] {
			return false
		}
	}

	return true
}

func DeriveForwardSalt(salt [32]byte) [32]byte {
	hash := keccak256.Sum256(salt[:])
	return TintForwardSalt(hash)
}

// Uint256ToBytes32 returns the big-endian 32-byte encoding of x.
func Uint256ToBytes32(x *u256.Uint) [32]byte {
	var out [32]byte

	putUint256BE(out[:], x)

	return out
}

// DeriveSenderSalt computes:
//
//	keccak256((sender, salt).abi_encode())
//
// matching Union's alloy-sol-types encoding of a top-level dynamic tuple.
// Callers must pass the raw UTF-8 bytes of the bech32 account string.
func DeriveSenderSalt(sender []byte, salt [32]byte) [32]byte {
	// ABI layout for alloy `(bytes, bytes32).abi_encode()`:
	//
	//   word 0: offset to top-level tuple body (0x20)
	//   word 1: offset to sender data within tuple body (0x40)
	//   word 2: salt
	//   word 3: len(sender)
	//   word 4+: sender bytes, right-padded to a 32-byte boundary
	//
	// The inner offset is relative to the start of the tuple body.
	pad := (32 - len(sender)%32) % 32
	buf := make([]byte, 4*32+len(sender)+pad)
	buf[31] = 0x20
	buf[63] = 0x40
	copy(buf[64:96], salt[:])
	binary.BigEndian.PutUint64(buf[120:128], uint64(len(sender)))
	copy(buf[128:], sender)

	return keccak256.Sum256(buf)
}

// NOTE: depends on gnoswap/uint256's internal [4]uint64 layout (mirror of
// SetBytes32). Replace with the upstream Bytes32() method once it exists.
func putUint256BE(dst []byte, x *u256.Uint) {
	binary.BigEndian.PutUint64(dst[0:8], x[3])
	binary.BigEndian.PutUint64(dst[8:16], x[2])
	binary.BigEndian.PutUint64(dst[16:24], x[1])
	binary.BigEndian.PutUint64(dst[24:32], x[0])
}
