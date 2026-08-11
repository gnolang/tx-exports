package rlp

import "errors"

// Kind identifies the RLP item kind after reading the leading tag.
type Kind int

const (
	KindByte Kind = iota
	KindString
	KindList
)

// Value is a decoded RLP item. Bytes holds the payload for byte/string items.
// List holds child items for lists.
type Value struct {
	Kind  Kind
	Bytes []byte
	List  []Value
}

var (
	ErrExpectedString = errors.New("rlp: expected string")
	ErrExpectedList   = errors.New("rlp: expected list")
	ErrCanonSize      = errors.New("rlp: non-canonical size")
	ErrCanonInt       = errors.New("rlp: non-canonical integer")
	ErrValueTooLarge  = errors.New("rlp: value too large")
	ErrTrailingBytes  = errors.New("rlp: trailing bytes")
	ErrUnexpectedEOF  = errors.New("rlp: unexpected eof")
	ErrDepthLimit     = errors.New("rlp: depth limit exceeded")
)

const (
	maxDecodeDepth = 256
	maxInt         = int(^uint(0) >> 1)
)
