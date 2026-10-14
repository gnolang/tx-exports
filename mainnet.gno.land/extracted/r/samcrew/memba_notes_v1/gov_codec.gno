package memba_notes_v1

import (
	"encoding/binary"
)

const MaxGovPayloadBytes = MaxCipherTitleBytes + MaxCipherBodyBytes + MaxManifestBytes + 128

type govReader struct {
	bytes []byte
	pos   int
}

func payloadReader(payload []byte) *govReader {
	if len(payload) < 1 || len(payload) > MaxGovPayloadBytes || payload[0] != 1 {
		panic("notes: gov payload format")
	}
	return &govReader{payload, 1}
}
func (r *govReader) take(n int) []byte {
	if n < 0 || n > len(r.bytes)-r.pos {
		panic("notes: gov payload truncated")
	}
	b := r.bytes[r.pos : r.pos+n]
	r.pos += n
	return b
}
func (r *govReader) byte() uint8 { return r.take(1)[0] }
func (r *govReader) boolean() bool {
	v := r.byte()
	if v > 1 {
		panic("notes: gov bool")
	}
	return v == 1
}
func (r *govReader) u64() uint64  { return binary.BigEndian.Uint64(r.take(8)) }
func (r *govReader) u32() uint32  { return binary.BigEndian.Uint32(r.take(4)) }
func (r *govReader) id() [16]byte { var v [16]byte; copy(v[:], r.take(16)); return v }
func (r *govReader) blob(cap int) []byte {
	n := r.u32()
	if n > uint32(cap) {
		panic("notes: gov field cap")
	}
	return r.take(int(n))
}
func (r *govReader) done() {
	if r.pos != len(r.bytes) {
		panic("notes: gov trailing bytes")
	}
}
