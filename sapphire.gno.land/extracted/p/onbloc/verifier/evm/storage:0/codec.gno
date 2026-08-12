package storage

import (
	"encoding/binary"
	"errors"
)

var (
	ErrInvalidProofBytes  = errors.New("storage: invalid proof bytes")
	ErrTrailingProofBytes = errors.New("storage: trailing proof bytes")
)

// DecodeProof decodes Union's ethereum_light_client_types::StorageProof
// bincode wire form into the normalized Proof shape used by this package.
//
// Wire layout with fixed-int/little-endian bincode:
//   - key: U256 as 32 little-endian bytes
//   - value: U256 as 32 little-endian bytes
//   - proof: Vec<Bytes> as u64 length followed by repeated byte vectors
func DecodeProof(buf []byte) (Proof, error) {
	d := proofDecoder{buf: buf}

	key, err := d.readU256()
	if err != nil {
		return Proof{}, err
	}

	value, err := d.readU256()
	if err != nil {
		return Proof{}, err
	}

	count, err := d.readUint64()
	if err != nil {
		return Proof{}, err
	}

	if count > uint64(len(buf)) {
		return Proof{}, ErrInvalidProofBytes
	}

	proof := make([][]byte, int(count))
	for i := 0; i < int(count); i++ {
		proof[i], err = d.readBytes()
		if err != nil {
			return Proof{}, err
		}
	}

	if d.pos != len(buf) {
		return Proof{}, ErrTrailingProofBytes
	}

	return Proof{Key: key, Value: value, Proof: proof}, nil
}

func EncodeProof(proof Proof) []byte {
	var out []byte

	out = append(out, reverse32(proof.Key)...)
	out = append(out, reverse32(proof.Value)...)
	out = appendUint64LE(out, uint64(len(proof.Proof)))

	for _, node := range proof.Proof {
		out = appendUint64LE(out, uint64(len(node)))
		out = append(out, node...)
	}

	return out
}

type proofDecoder struct {
	buf []byte
	pos int
}

func (d *proofDecoder) readU256() ([]byte, error) {
	if d.pos+32 > len(d.buf) {
		return nil, ErrInvalidProofBytes
	}

	le := d.buf[d.pos : d.pos+32]
	d.pos += 32

	out := make([]byte, 32)
	for i := 0; i < 32; i++ {
		out[i] = le[31-i]
	}

	return out, nil
}

func (d *proofDecoder) readBytes() ([]byte, error) {
	n, err := d.readUint64()
	if err != nil {
		return nil, err
	}

	if n > uint64(len(d.buf)-d.pos) {
		return nil, ErrInvalidProofBytes
	}

	out := make([]byte, int(n))
	copy(out, d.buf[d.pos:d.pos+int(n)])
	d.pos += int(n)

	return out, nil
}

func (d *proofDecoder) readUint64() (uint64, error) {
	if d.pos+8 > len(d.buf) {
		return 0, ErrInvalidProofBytes
	}

	v := binary.LittleEndian.Uint64(d.buf[d.pos : d.pos+8])
	d.pos += 8

	return v, nil
}

func appendUint64LE(out []byte, v uint64) []byte {
	var word [8]byte
	binary.LittleEndian.PutUint64(word[:], v)

	return append(out, word[:]...)
}

func reverse32(b []byte) []byte {
	out := make([]byte, 32)

	n := len(b)
	if n > 32 {
		n = 32
	}

	for i := 0; i < n; i++ {
		out[i] = b[len(b)-1-i]
	}

	return out
}
