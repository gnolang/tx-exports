package rlp

// EncodeBytes returns the RLP string encoding of b.
func EncodeBytes(b []byte) []byte {
	out := make([]byte, 0, bytesSize(b))
	return appendBytes(out, b)
}

// EncodeList returns the RLP list encoding of already-encoded items.
func EncodeList(items ...[]byte) []byte {
	size := 0
	for _, item := range items {
		size += len(item)
	}

	out := make([]byte, 0, listSize(size))

	out = appendHeader(out, 0xC0, uint64(size))
	for _, item := range items {
		out = append(out, item...)
	}

	return out
}

func appendBytes(out []byte, b []byte) []byte {
	if len(b) == 1 && b[0] <= 0x7f {
		return append(out, b[0])
	}

	out = appendHeader(out, 0x80, uint64(len(b)))

	return append(out, b...)
}

func bytesSize(b []byte) int {
	n := len(b)
	if n == 1 && b[0] <= 0x7f {
		return 1
	}

	return headerSize(n) + n
}

func listSize(contentSize int) int {
	return headerSize(contentSize) + contentSize
}

func appendHeader(out []byte, baseTag byte, size uint64) []byte {
	if size < 56 {
		return append(out, baseTag+byte(size))
	}

	n := intSize(size)
	out = append(out, baseTag+55+byte(n))

	return appendBigEndianUint(out, size, n)
}

// appendBigEndianUint appends the n low-order bytes of x to out, big-endian.
func appendBigEndianUint(out []byte, x uint64, n int) []byte {
	for i := n - 1; i >= 0; i-- {
		out = append(out, byte(x>>uint(i*8)))
	}

	return out
}

func headerSize(payloadSize int) int {
	if payloadSize < 56 {
		return 1
	}

	return 1 + intSize(uint64(payloadSize))
}

func intSize(x uint64) int {
	switch {
	case x < 1<<8:
		return 1
	case x < 1<<16:
		return 2
	case x < 1<<24:
		return 3
	case x < 1<<32:
		return 4
	case x < 1<<40:
		return 5
	case x < 1<<48:
		return 6
	case x < 1<<56:
		return 7
	default:
		return 8
	}
}
