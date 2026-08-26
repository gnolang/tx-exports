package types

import "encoding/binary"

// wrapABIEncode wraps an already-encoded dynamic ABI payload with the
// 32-byte offset header that Solidity prepends when a single dynamic value is
// returned at the top level.
func wrapABIEncode(encoded []byte) []byte {
	out := make([]byte, 0, 32+len(encoded))
	out = append(out, u64ToH256(32)...)

	return append(out, encoded...)
}

func encodeABIPacketArray(packets []Packet) ([]byte, error) {
	out := make([]byte, 0)
	out = append(out, u64ToH256(uint64(len(packets)))...)

	headLen := len(packets) * 32
	tail := make([]byte, 0)

	for _, packet := range packets {
		encoded, err := packet.EncodeABI()
		if err != nil {
			return nil, err
		}

		out = append(out, u64ToH256(uint64(headLen+len(tail)))...)
		tail = append(tail, encoded...)
	}

	return append(out, tail...), nil
}

func encodeABIBytesArray(items [][]byte) []byte {
	out := make([]byte, 0)
	out = append(out, u64ToH256(uint64(len(items)))...)

	headLen := len(items) * 32
	tail := make([]byte, 0)

	for _, item := range items {
		encoded := encodeABIBytes(item)

		out = append(out, u64ToH256(uint64(headLen+len(tail)))...)
		tail = append(tail, encoded...)
	}

	return append(out, tail...)
}

// encodeABIBytes encodes bz as a Solidity `bytes` value: a 32-byte length word
// followed by the data right-padded to a 32-byte boundary.
func encodeABIBytes(bz []byte) []byte {
	pad := (32 - len(bz)%32) % 32
	out := make([]byte, 0, 32+len(bz)+pad)
	out = append(out, u64ToH256(uint64(len(bz)))...)

	out = append(out, bz...)
	if pad > 0 {
		out = append(out, make([]byte, pad)...)
	}

	return out
}

// u32ToH256 left-pads a uint32 into a 32-byte big-endian word.
func u32ToH256(n uint32) []byte {
	bz := [32]byte{}
	binary.BigEndian.PutUint32(bz[28:], n)

	return bz[:]
}

// u64ToH256 left-pads a uint64 into a 32-byte big-endian word.
func u64ToH256(n uint64) []byte {
	bz := [32]byte{}
	binary.BigEndian.PutUint64(bz[24:], n)

	return bz[:]
}
