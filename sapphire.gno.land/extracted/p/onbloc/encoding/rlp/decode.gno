package rlp

// DecodeValue decodes exactly one RLP item.
func DecodeValue(b []byte) (Value, error) {
	v, rest, err := decodeValue(b, 0)
	if err != nil {
		return Value{}, err
	}

	if len(rest) != 0 {
		return Value{}, ErrTrailingBytes
	}

	return v, nil
}

func split(b []byte) (Kind, []byte, []byte, error) {
	k, tagSize, contentSize, err := readKind(b)
	if err != nil {
		return 0, nil, b, err
	}

	end := tagSize + contentSize

	return k, b[tagSize:end], b[end:], nil
}

func decodeValue(b []byte, depth int) (Value, []byte, error) {
	if depth > maxDecodeDepth {
		return Value{}, b, ErrDepthLimit
	}

	k, content, rest, err := split(b)
	if err != nil {
		return Value{}, b, err
	}

	if k != KindList {
		return Value{Kind: k, Bytes: content}, rest, nil
	}

	var items []Value
	for len(content) > 0 {
		var item Value

		item, content, err = decodeValue(content, depth+1)
		if err != nil {
			return Value{}, b, err
		}

		items = append(items, item)
	}

	return Value{Kind: KindList, List: items}, rest, nil
}

func readKind(b []byte) (Kind, int, int, error) {
	if len(b) == 0 {
		return 0, 0, 0, ErrUnexpectedEOF
	}

	prefix := b[0]
	switch {
	case prefix < 0x80:
		return KindByte, 0, 1, nil
	case prefix < 0xB8:
		size := int(prefix - 0x80)
		if size == 1 && len(b) > 1 && b[1] < 0x80 {
			return 0, 0, 0, ErrCanonSize
		}

		if len(b) < 1+size {
			return 0, 0, 0, ErrValueTooLarge
		}

		return KindString, 1, size, nil
	case prefix < 0xC0:
		return readLongItem(b, int(prefix-0xB7), KindString)
	case prefix < 0xF8:
		size := int(prefix - 0xC0)
		if len(b) < 1+size {
			return 0, 0, 0, ErrValueTooLarge
		}

		return KindList, 1, size, nil
	default:
		return readLongItem(b, int(prefix-0xF7), KindList)
	}
}

func readLongItem(b []byte, sizeLen int, kind Kind) (Kind, int, int, error) {
	size, err := readSize(b[1:], sizeLen)
	if err != nil {
		return 0, 0, 0, err
	}

	if size > len(b)-1-sizeLen {
		return 0, 0, 0, ErrValueTooLarge
	}

	return kind, 1 + sizeLen, size, nil
}

func readSize(b []byte, sizeLen int) (int, error) {
	if sizeLen == 0 || sizeLen > 8 || len(b) < sizeLen {
		return 0, ErrUnexpectedEOF
	}

	if b[0] == 0 {
		return 0, ErrCanonSize
	}

	var size uint64
	for i := 0; i < sizeLen; i++ {
		size = (size << 8) | uint64(b[i])
	}

	if size < 56 {
		return 0, ErrCanonSize
	}

	if size > uint64(maxInt) {
		return 0, ErrValueTooLarge
	}

	return int(size), nil
}
