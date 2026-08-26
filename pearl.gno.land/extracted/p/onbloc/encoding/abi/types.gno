package abi

import "errors"

// Type identifies a Solidity ABI field kind supported by this package.
type Type int

const (
	TypeUint8 Type = iota
	TypeUint32
	TypeUint64
	TypeUint256
	TypeBytes32
	TypeBytes
	TypeString
	TypeBool
	TypeAddress
	TypeStruct
	TypeArray
)

var (
	ErrUnsupportedType = errors.New("abi: unsupported type")
	ErrInvalidSchema   = errors.New("abi: invalid schema")
	ErrInvalidValue    = errors.New("abi: invalid value")
	ErrInvalidData     = errors.New("abi: invalid data")
	ErrDepthLimit      = errors.New("abi: depth limit exceeded")
)

// Field describes one ABI tuple field.
type Field struct {
	Type Type
	Sub  *Schema
	Elem *Field
}

// Schema describes a Solidity ABI tuple.
type Schema struct {
	Fields []Field
}

const (
	wordSize        = 32
	maxDecodeDepth  = 256
)
