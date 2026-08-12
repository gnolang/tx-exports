package abi

import (
	"encoding/binary"

	u256 "gno.land/p/onbloc/math/uint256"
)

// Encode ABI-encodes values according to schema using Solidity's params tuple form.
func Encode(schema Schema, values []any) ([]byte, error) {
	return encodeTuple(schema.Fields, values)
}

func encodeTuple(fields []Field, values []any) ([]byte, error) {
	if len(fields) != len(values) {
		return nil, ErrInvalidValue
	}

	dyn := make([]bool, len(fields))
	headLen := 0

	for i, field := range fields {
		dyn[i] = isDynamic(field)
		if dyn[i] {
			headLen += wordSize
			continue
		}

		size, err := staticHeadSize(field)
		if err != nil {
			return nil, err
		}

		headLen += size
	}

	head := make([]byte, 0, headLen)

	var tail []byte

	for i, field := range fields {
		encoded, err := encodeValue(field, values[i])
		if err != nil {
			return nil, err
		}

		if dyn[i] {
			head = append(head, encodeUint64Word(uint64(headLen+len(tail)))...)
			tail = append(tail, encoded...)
		} else {
			head = append(head, encoded...)
		}
	}

	return append(head, tail...), nil
}

func encodeValue(field Field, value any) ([]byte, error) {
	switch field.Type {
	case TypeUint8:
		v, ok := value.(uint8)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeUint64Word(uint64(v)), nil
	case TypeUint32:
		v, ok := value.(uint32)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeUint64Word(uint64(v)), nil
	case TypeUint64:
		v, ok := value.(uint64)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeUint64Word(v), nil
	case TypeUint256:
		v, ok := value.(*u256.Uint)
		if !ok || v == nil {
			return nil, ErrInvalidValue
		}

		return encodeUint256Word(v), nil
	case TypeBytes32:
		v, ok := value.([32]byte)
		if !ok {
			return nil, ErrInvalidValue
		}

		out := make([]byte, wordSize)
		copy(out, v[:])

		return out, nil
	case TypeBytes:
		v, ok := value.([]byte)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeBytes(v), nil
	case TypeString:
		v, ok := value.(string)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeBytes([]byte(v)), nil
	case TypeBool:
		v, ok := value.(bool)
		if !ok {
			return nil, ErrInvalidValue
		}

		if v {
			return encodeUint64Word(1), nil
		}

		return encodeUint64Word(0), nil
	case TypeAddress:
		v, ok := value.([]byte)
		if !ok || len(v) != 20 {
			return nil, ErrInvalidValue
		}

		out := make([]byte, wordSize)
		copy(out[12:], v)

		return out, nil
	case TypeStruct:
		if field.Sub == nil {
			return nil, ErrInvalidSchema
		}

		v, ok := value.([]any)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeTuple(field.Sub.Fields, v)
	case TypeArray:
		if field.Elem == nil {
			return nil, ErrInvalidSchema
		}

		v, ok := value.([]any)
		if !ok {
			return nil, ErrInvalidValue
		}

		return encodeArray(*field.Elem, v)
	default:
		return nil, ErrUnsupportedType
	}
}

func encodeArray(elem Field, values []any) ([]byte, error) {
	out := encodeUint64Word(uint64(len(values)))
	if len(values) == 0 {
		return out, nil
	}

	if isDynamic(elem) {
		headLen := len(values) * wordSize
		head := make([]byte, 0, headLen)

		var tail []byte

		for _, value := range values {
			encoded, err := encodeValue(elem, value)
			if err != nil {
				return nil, err
			}

			head = append(head, encodeUint64Word(uint64(headLen+len(tail)))...)
			tail = append(tail, encoded...)
		}

		out = append(out, head...)

		return append(out, tail...), nil
	}

	for _, value := range values {
		encoded, err := encodeValue(elem, value)
		if err != nil {
			return nil, err
		}

		out = append(out, encoded...)
	}

	return out, nil
}

func encodeBytes(v []byte) []byte {
	pad := (wordSize - len(v)%wordSize) % wordSize
	out := make([]byte, 0, wordSize+len(v)+pad)
	out = append(out, encodeUint64Word(uint64(len(v)))...)

	out = append(out, v...)
	if pad > 0 {
		out = append(out, make([]byte, pad)...)
	}

	return out
}

func encodeUint64Word(v uint64) []byte {
	out := make([]byte, wordSize)
	binary.BigEndian.PutUint64(out[24:], v)

	return out
}

// NOTE: depends on gnoswap/uint256's internal [4]uint64 layout (mirror of
// SetBytes32). Replace with the upstream Bytes32() method once it exists.
// Same workaround lives in ibc/union/zkgm/salt.gno; consolidate when fixed.
func encodeUint256Word(v *u256.Uint) []byte {
	out := make([]byte, wordSize)
	binary.BigEndian.PutUint64(out[0:8], v[3])
	binary.BigEndian.PutUint64(out[8:16], v[2])
	binary.BigEndian.PutUint64(out[16:24], v[1])
	binary.BigEndian.PutUint64(out[24:32], v[0])

	return out
}

func isDynamic(field Field) bool {
	switch field.Type {
	case TypeBytes, TypeString, TypeArray:
		return true
	case TypeStruct:
		if field.Sub == nil {
			return true
		}

		for _, sub := range field.Sub.Fields {
			if isDynamic(sub) {
				return true
			}
		}

		return false
	default:
		return false
	}
}

func staticHeadSize(field Field) (int, error) {
	if isDynamic(field) {
		return wordSize, nil
	}

	if field.Type == TypeStruct {
		if field.Sub == nil {
			return 0, ErrInvalidSchema
		}

		size := 0

		for _, sub := range field.Sub.Fields {
			subSize, err := staticHeadSize(sub)
			if err != nil {
				return 0, err
			}

			size += subSize
		}

		return size, nil
	}

	return wordSize, nil
}
