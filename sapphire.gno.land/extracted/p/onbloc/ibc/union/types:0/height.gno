package types

import (
	"encoding/binary"
	"errors"
	"strconv"
	"strings"
)

// Height is a blockchain height, optionally prefixed with a revision number as
// per the IBC specification. A revision of zero is treated as "no revision":
// it is omitted from the string form and ignored during comparison, mirroring
// the Rust `Option<NonZeroU64>` revision semantics.
type Height struct {
	// the revision that the client is currently on
	RevisionNumber uint64
	// the height within the given revision
	RevisionHeight uint64
}

// NewHeight returns a Height with no revision.
func NewHeight(height uint64) Height {
	return Height{RevisionNumber: 0, RevisionHeight: height}
}

// NewHeightWithRevision returns a Height carrying both a revision and a height.
func NewHeightWithRevision(revision, height uint64) Height {
	return Height{RevisionNumber: revision, RevisionHeight: height}
}

// IsZero reports whether the height is the zero value (no revision, zero
// height). Union packets require a zero timeout height.
func (h Height) IsZero() bool {
	return h.RevisionNumber == 0 && h.RevisionHeight == 0
}

// HasRevision reports whether the height carries a non-zero revision number.
func (h Height) HasRevision() bool {
	return h.RevisionNumber != 0
}

// GetRevision returns the revision number, or zero when unset.
func (h Height) GetRevision() uint64 {
	return h.RevisionNumber
}

// GetHeight returns the height number.
func (h Height) GetHeight() uint64 {
	return h.RevisionHeight
}

// RevisionMatches reports whether two heights share the same revision. When
// either side has no revision the revisions are considered compatible.
func (h Height) RevisionMatches(other Height) bool {
	if h.RevisionNumber == 0 || other.RevisionNumber == 0 {
		return true
	}

	return h.RevisionNumber == other.RevisionNumber
}

// Increment returns a copy of the height advanced by one, preserving revision.
func (h Height) Increment() Height {
	return Height{RevisionNumber: h.RevisionNumber, RevisionHeight: h.RevisionHeight + 1}
}

// IncrementBy returns a copy of the height advanced by n, preserving revision.
func (h Height) IncrementBy(n uint64) Height {
	return Height{RevisionNumber: h.RevisionNumber, RevisionHeight: h.RevisionHeight + n}
}

// Cmp compares two heights, returning -1, 0, or 1. When both heights carry a
// revision, revisions are compared first and heights break the tie; otherwise
// only the height numbers are compared.
func (h Height) Cmp(other Height) int {
	if h.RevisionNumber != 0 && other.RevisionNumber != 0 {
		switch {
		case h.RevisionNumber < other.RevisionNumber:
			return -1
		case h.RevisionNumber > other.RevisionNumber:
			return 1
		}
	}

	switch {
	case h.RevisionHeight < other.RevisionHeight:
		return -1
	case h.RevisionHeight > other.RevisionHeight:
		return 1
	default:
		return 0
	}
}

// LT reports whether h is strictly less than other.
func (h Height) LT(other Height) bool { return h.Cmp(other) < 0 }

// LTE reports whether h is less than or equal to other.
func (h Height) LTE(other Height) bool { return h.Cmp(other) <= 0 }

// GT reports whether h is strictly greater than other.
func (h Height) GT(other Height) bool { return h.Cmp(other) > 0 }

// GTE reports whether h is greater than or equal to other.
func (h Height) GTE(other Height) bool { return h.Cmp(other) >= 0 }

// EQ reports whether h equals other under height comparison semantics.
func (h Height) EQ(other Height) bool { return h.Cmp(other) == 0 }

// String renders the height as "revision-height" when a revision is set, or as
// the bare height otherwise.
func (h Height) String() string {
	if h.RevisionNumber != 0 {
		return strconv.FormatUint(h.RevisionNumber, 10) + "-" + strconv.FormatUint(h.RevisionHeight, 10)
	}

	return strconv.FormatUint(h.RevisionHeight, 10)
}

// Bytes returns a 16-byte big-endian encoding of the height (revision then
// height), suitable as a BPTree key with correct lexicographic ordering when
// cast to string.
func (h Height) Bytes() []byte {
	buf := make([]byte, 16)
	binary.BigEndian.PutUint64(buf[:8], h.RevisionNumber)
	binary.BigEndian.PutUint64(buf[8:], h.RevisionHeight)

	return buf
}

// ParseHeight parses a height string of the form "revision-height" or a bare
// "height". A "revision-height" form always carries its revision, even when it
// is zero.
func ParseHeight(s string) (Height, error) {
	if s == "" {
		return Height{}, errors.New("types: invalid height string")
	}

	revStr, heightStr, found := strings.Cut(s, "-")
	if !found {
		height, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			return Height{}, err
		}

		return Height{RevisionNumber: 0, RevisionHeight: height}, nil
	}

	revision, err := strconv.ParseUint(revStr, 10, 64)
	if err != nil {
		return Height{}, err
	}

	height, err := strconv.ParseUint(heightStr, 10, 64)
	if err != nil {
		return Height{}, err
	}

	return Height{RevisionNumber: revision, RevisionHeight: height}, nil
}
