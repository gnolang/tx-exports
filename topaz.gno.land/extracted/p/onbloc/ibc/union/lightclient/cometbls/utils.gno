package cometbls

// maxChainIDLen bounds the source length. The original Solidity routine packs
// the identifier into a single EVM word, so it is never larger than 32 bytes.
const maxChainIDLen = 32

// chainIdToString converts a byte identifier into a string by trimming the
// leading zero padding and returning the remaining bytes. It returns an error
// when the source is empty, longer than maxChainIDLen, or contains only zero
// padding, since none of those yield a valid chain-id.
func chainIdToString(source []byte) (string, error) {
	if len(source) == 0 {
		return "", errorWithDetails(ErrInvalidChainID, "empty source")
	}

	if len(source) > maxChainIDLen {
		return "", errorWithDetails(ErrInvalidChainID, "source exceeds max length")
	}

	offset := 0
	for offset < len(source) && source[offset] == 0 {
		offset++
	}

	if offset == len(source) {
		return "", errorWithDetails(ErrInvalidChainID, "source is all zero padding")
	}

	return string(source[offset:]), nil
}
