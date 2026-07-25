package cometbls

import (
	"errors"

	"gno.land/p/aib/encoding/proto"
	"gno.land/p/aib/ics23"
)

// DecodeProofs decodes a protobuf-encoded MerkleProof (repeated CommitmentProof field 1).
func DecodeProofs(buf []byte) ([]ics23.CommitmentProof, error) {
	var out []ics23.CommitmentProof

	pos := 0

	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		if wireType != proto.LEN {
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}

			continue
		}

		s, newPos, err := proto.DecodeString(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos
		b := []byte(s)

		if fieldNum != 1 {
			continue
		}

		cp, err := decodeCommitmentProof(b)
		if err != nil {
			return nil, err
		}

		out = append(out, cp)
	}

	return out, nil
}

func decodeCommitmentProof(buf []byte) (ics23.CommitmentProof, error) {
	pos := 0

	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		if wireType != proto.LEN {
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}

			continue
		}

		s, newPos, err := proto.DecodeString(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos
		b := []byte(s)

		switch fieldNum {
		case 1:
			ep, err := decodeExistenceProof(b)
			if err != nil {
				return nil, err
			}

			return ics23.CommitmentProof_Exist{Exist: ep}, nil
		case 2:
			nep, err := decodeNonExistenceProof(b)
			if err != nil {
				return nil, err
			}

			return ics23.CommitmentProof_Nonexist{Nonexist: nep}, nil
		}
	}

	return nil, errors.New("empty commitment proof")
}

func decodeExistenceProof(buf []byte) (*ics23.ExistenceProof, error) {
	ep := &ics23.ExistenceProof{Path: make([]*ics23.InnerOp, 0, 32)}
	pos := 0

	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		switch {
		case (fieldNum == 1 || fieldNum == 2) && wireType == proto.LEN:
			s, newPos, err := proto.DecodeString(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos
			b := []byte(s)

			if fieldNum == 1 {
				ep.Key = b
			} else {
				ep.Value = b
			}

		case fieldNum == 3 && wireType == proto.LEN:
			s, newPos, err := proto.DecodeString(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos
			b := []byte(s)

			ep.Leaf, err = decodeLeafOp(b)
			if err != nil {
				return nil, err
			}
		case fieldNum == 4 && wireType == proto.LEN:
			s, newPos, err := proto.DecodeString(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos
			b := []byte(s)

			inner, err := decodeInnerOp(b)
			if err != nil {
				return nil, err
			}

			ep.Path = append(ep.Path, inner)
		default:
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}
		}
	}

	return ep, nil
}

func decodeLeafOp(buf []byte) (*ics23.LeafOp, error) {
	lop := &ics23.LeafOp{}
	pos := 0

	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		switch {
		case fieldNum >= 1 && fieldNum <= 4 && wireType == proto.VARINT:
			v, newPos, err := proto.DecodeVarint(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos

			switch fieldNum {
			case 1:
				lop.Hash = ics23.HashOp(v)
			case 2:
				lop.PrehashKey = ics23.HashOp(v)
			case 3:
				lop.PrehashValue = ics23.HashOp(v)
			case 4:
				lop.Length = ics23.LengthOp(v)
			}
		case fieldNum == 5 && wireType == proto.LEN:
			s, newPos, err := proto.DecodeString(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos
			b := []byte(s)
			lop.Prefix = b
		default:
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}
		}
	}

	return lop, nil
}

func decodeInnerOp(buf []byte) (*ics23.InnerOp, error) {
	iop := &ics23.InnerOp{}

	pos := 0
	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		switch {
		case fieldNum == 1 && wireType == proto.VARINT:
			v, newPos, err := proto.DecodeVarint(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos
			iop.Hash = ics23.HashOp(v)
		case (fieldNum == 2 || fieldNum == 3) && wireType == proto.LEN:
			s, newPos, err := proto.DecodeString(buf, pos)
			if err != nil {
				return nil, err
			}

			pos = newPos

			b := []byte(s)
			if fieldNum == 2 {
				iop.Prefix = b
			} else {
				iop.Suffix = b
			}
		default:
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}
		}
	}

	return iop, nil
}

func decodeNonExistenceProof(buf []byte) (*ics23.NonExistenceProof, error) {
	nep := &ics23.NonExistenceProof{}
	pos := 0

	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos
		if wireType != proto.LEN {
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}

			continue
		}

		s, newPos, err := proto.DecodeString(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos
		b := []byte(s)

		switch fieldNum {
		case 1:
			nep.Key = b
		case 2:
			ep, err := decodeExistenceProof(b)
			if err != nil {
				return nil, err
			}

			nep.Left = ep
		case 3:
			ep, err := decodeExistenceProof(b)
			if err != nil {
				return nil, err
			}

			nep.Right = ep
		}
	}

	return nep, nil
}

// decodeTag reads a protobuf tag at pos and splits it into the field number and
// wire type. It is built on top of proto.DecodeVarint.
func decodeTag(buf []byte, pos int) (fieldNum int, wireType proto.WireType, newPos int, err error) {
	tag, newPos, err := proto.DecodeVarint(buf, pos)
	if err != nil {
		return 0, 0, newPos, err
	}

	return int(tag >> 3), proto.WireType(tag & 0x7), newPos, nil
}

// skipField advances pos past a field whose value should be ignored, according
// to its wire type. Only the wire types used by the ICS23 proof messages are
// supported.
func skipField(buf []byte, pos int, wireType proto.WireType) (int, error) {
	switch wireType {
	case proto.VARINT:
		_, newPos, err := proto.DecodeVarint(buf, pos)

		return newPos, err
	case proto.LEN:
		_, newPos, err := proto.DecodeString(buf, pos)

		return newPos, err
	case proto.FIXED64:
		if pos+8 > len(buf) {
			return pos, errors.New("buffer underflow while skipping fixed64")
		}

		return pos + 8, nil
	case proto.FIXED32:
		if pos+4 > len(buf) {
			return pos, errors.New("buffer underflow while skipping fixed32")
		}

		return pos + 4, nil
	default:
		return pos, errors.New("unsupported wire type")
	}
}
