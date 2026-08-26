package cometbls

import (
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/ibc/union/types"
)

var FrozenHeight = types.NewHeightWithRevision(0, 1)

type Misbehaviour struct {
	Header1 *Header
	Header2 *Header
}

func NewMisbehaviour(header1 *Header, header2 *Header) *Misbehaviour {
	return &Misbehaviour{Header1: header1, Header2: header2}
}

func (Misbehaviour) ClientType() string {
	return ClientType
}

// GetTime returns the timestamp at which misbehaviour occurred. It uses the
// maximum value from both headers to prevent producing an invalid header outside
// of the misbehaviour age range.
func (m *Misbehaviour) GetTime() time.Time {
	t1, t2 := m.Header1.GetTime(), m.Header2.GetTime()
	if t1.After(t2) {
		return t1
	}

	return t2
}

// ValidateBasic implements Misbehaviour interface
func (m *Misbehaviour) ValidateBasic() error {
	if m.Header1 == nil {
		return errorWithDetails(ErrInvalidHeader, "misbehaviour Header_1 cannot be nil")
	}

	if m.Header2 == nil {
		return errorWithDetails(ErrInvalidHeader, "misbehaviour Header_2 cannot be nil")
	}

	if m.Header1.TrustedHeight.RevisionHeight == 0 {
		return errorWithDetails(ErrInvalidHeaderHeight, "misbehaviour Header_1 cannot have zero revision height")
	}

	if m.Header2.TrustedHeight.RevisionHeight == 0 {
		return errorWithDetails(ErrInvalidHeaderHeight, "misbehaviour Header_2 cannot have zero revision height")
	}

	// ValidateBasic on both validators
	if err := m.Header1.ValidateBasic(); err != nil {
		return errorWithDetails(
			ErrInvalidMisbehaviour,
			ufmt.Sprintf("header 1 failed validation: %v", err),
		)
	}

	if err := m.Header2.ValidateBasic(); err != nil {
		return errorWithDetails(
			ErrInvalidMisbehaviour,
			ufmt.Sprintf("header 2 failed validation: %v", err),
		)
	}

	// Ensure that Height1 is greater than or equal to Height2
	if m.Header1.GetHeight().LT(m.Header2.GetHeight()) {
		return errorWithDetails(
			ErrInvalidMisbehaviour,
			ufmt.Sprintf("Header_1 height is less than Header_2 height (%s < %s)", m.Header1.GetHeight(), m.Header2.GetHeight()),
		)
	}

	return nil
}
