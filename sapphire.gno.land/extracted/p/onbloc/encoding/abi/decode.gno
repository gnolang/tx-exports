package abi

import (
	"encoding/binary"

	u256 "gno.land/p/onbloc/math/uint256"
)

// Decode ABI-decodes data according to schema using Solidity's params tuple form.
func Decode(schema Schema, data []byte) ([]any, error) {
	if len(data)%wordSize != 0 {
		return nil, ErrInvalidData
	}

	d := decoder{data: data, maxDepth: maxDecodeDepth}

	return d.tupleAt(schema.Fields, 0, len(data), 0)
}

type decoder struct {
	data     []byte
	maxDepth int
}

func (d *decoder) tupleAt(fields []Field, start, end, depth int) ([]any, error) {
	depth++
	if depth > d.maxDepth {
		return nil, ErrDepthLimit
	}

	if start < 0 || end < start || end > len(d.data) {
		return nil, ErrInvalidData
	}

	out := make([]any, len(fields))
	cursor := start

	for i, field := range fields {
		dyn := isDynamic(field)
		size := wordSize

		if !dyn {
			s, err := staticHeadSize(field)
			if err != nil {
				return nil, err
			}

			size = s
		}

		// prevent `cursor+size` overflow
		if size < 0 || cursor > end || size > end-cursor {
			return nil, ErrInvalidData
		}

		if dyn {
			offset, err := decodeWordUint64(d.data[cursor : cursor+wordSize])
			if err != nil {
				return nil, err
			}

			if offset > uint64(end-start) || offset%wordSize != 0 {
				return nil, ErrInvalidData
			}

			pos := start + int(offset)

			out[i], err = d.valueAt(field, pos, end, depth)
			if err != nil {
				return nil, err
			}

			cursor += wordSize
		} else {
			v, err := d.staticValue(field, cursor, end, depth)
			if err != nil {
				return nil, err
			}

			out[i] = v
			cursor += size
		}
	}

	return out, nil
}

func (d *decoder) valueAt(field Field, pos, end, depth int) (any, error) {
	switch field.Type {
	case TypeBytes:
		return d.bytesAt(pos, end)
	case TypeString:
		bz, err := d.bytesAt(pos, end)
		if err != nil {
			return nil, err
		}

		return string(bz), nil
	case TypeStruct:
		if field.Sub == nil {
			return nil, ErrInvalidSchema
		}

		return d.tupleAt(field.Sub.Fields, pos, end, depth)
	case TypeArray:
		if field.Elem == nil {
			return nil, ErrInvalidSchema
		}

		return d.arrayAt(*field.Elem, pos, end, depth)
	default:
		return d.staticValue(field, pos, end, depth)
	}
}

func (d *decoder) staticValue(field Field, pos, end, depth int) (any, error) {
	if pos+wordSize > end {
		return nil, ErrInvalidData
	}

	switch field.Type {
	case TypeUint8:
		v, err := decodeWordUint64(d.data[pos : pos+wordSize])
		if err != nil || v > 255 {
			return nil, ErrInvalidData
		}

		return uint8(v), nil
	case TypeUint32:
		v, err := decodeWordUint64(d.data[pos : pos+wordSize])
		if err != nil || v > 0xFFFFFFFF {
			return nil, ErrInvalidData
		}

		return uint32(v), nil
	case TypeUint64:
		v, err := decodeWordUint64(d.data[pos : pos+wordSize])
		if err != nil {
			return nil, err
		}

		return v, nil
	case TypeUint256:
		var out u256.Uint
		out.SetBytes32(d.data[pos : pos+wordSize])

		return &out, nil
	case TypeBytes32:
		var out [32]byte
		copy(out[:], d.data[pos:pos+wordSize])

		return out, nil
	case TypeBool:
		v, err := decodeWordUint64(d.data[pos : pos+wordSize])
		if err != nil || v > 1 {
			return nil, ErrInvalidData
		}

		return v == 1, nil
	case TypeAddress:
		for i := pos; i < pos+12; i++ {
			if d.data[i] != 0 {
				return nil, ErrInvalidData
			}
		}

		out := make([]byte, 20)
		copy(out, d.data[pos+12:pos+wordSize])

		return out, nil
	case TypeStruct:
		if field.Sub == nil {
			return nil, ErrInvalidSchema
		}

		return d.tupleAt(field.Sub.Fields, pos, end, depth)
	default:
		return nil, ErrUnsupportedType
	}
}

func (d *decoder) arrayAt(elem Field, pos, end, depth int) ([]any, error) {
	depth++
	if depth > d.maxDepth {
		return nil, ErrDepthLimit
	}

	if pos > end || wordSize > end-pos {
		return nil, ErrInvalidData
	}

	length, err := decodeWordUint64(d.data[pos : pos+wordSize])
	if err != nil {
		return nil, err
	}

	if length > uint64((end-pos)/wordSize) {
		return nil, ErrInvalidData
	}

	n := int(length)
	out := make([]any, n)

	headStart := pos + wordSize
	if isDynamic(elem) {
		if n > (end-headStart)/wordSize {
			return nil, ErrInvalidData
		}

		for i := 0; i < n; i++ {
			offset, err := decodeWordUint64(d.data[headStart+i*wordSize : headStart+(i+1)*wordSize])
			if err != nil {
				return nil, err
			}

			if offset > uint64(end-headStart) || offset%wordSize != 0 {
				return nil, ErrInvalidData
			}

			elemPos := headStart + int(offset)

			out[i], err = d.valueAt(elem, elemPos, end, depth)
			if err != nil {
				return nil, err
			}
		}

		return out, nil
	}

	elemSize, err := staticHeadSize(elem)
	if err != nil {
		return nil, err
	}

	if elemSize <= 0 || n > (end-headStart)/elemSize {
		return nil, ErrInvalidData
	}

	for i := 0; i < n; i++ {
		out[i], err = d.staticValue(elem, headStart+i*elemSize, end, depth)
		if err != nil {
			return nil, err
		}
	}

	return out, nil
}

func (d *decoder) bytesAt(pos, end int) ([]byte, error) {
	if pos+wordSize > end {
		return nil, ErrInvalidData
	}

	length, err := decodeWordUint64(d.data[pos : pos+wordSize])
	if err != nil {
		return nil, err
	}

	start := pos + wordSize
	remaining := uint64(end - start)

	padded := roundUp32(length)
	if padded < length || length > remaining || padded > remaining {
		return nil, ErrInvalidData
	}

	out := make([]byte, int(length))
	copy(out, d.data[start:start+int(length)])

	return out, nil
}

func decodeWordUint64(word []byte) (uint64, error) {
	if len(word) != wordSize {
		return 0, ErrInvalidData
	}

	for i := 0; i < 24; i++ {
		if word[i] != 0 {
			return 0, ErrInvalidData
		}
	}

	return binary.BigEndian.Uint64(word[24:32]), nil
}

func roundUp32(v uint64) uint64 {
	if v%wordSize == 0 {
		return v
	}

	return v + wordSize - v%wordSize
}
