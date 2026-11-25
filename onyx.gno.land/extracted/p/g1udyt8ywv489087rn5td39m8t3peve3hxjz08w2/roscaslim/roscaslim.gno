// Package rosca is a dependency-free toolkit for building rotating savings
// and credit associations (ROSCA - "arisan", "tanda", "chit fund", "susus")
// on Gno.land.
//
// It contains no state and no realm capability of its own: the economics,
// the deterministic payout schedule and the presentation helpers are pure
// functions, so any realm can import this package and add a savings circle
// to its own state machine without re-deriving the hard parts.
//
// The companion realm gno.land/r/<addr>/kolektif is the reference
// implementation; it imports exactly these helpers.
package roscaslim

import (
	"errors"
	"strconv"
	"strings"
)

// Status is the lifecycle stage of a circle.
type Status uint8

const (
	// StatusOpen collects members and collateral. Nothing is paid out.
	StatusOpen Status = iota
	// StatusActive is a full circle that is paying round by round.
	StatusActive
	// StatusComplete means every payout happened and collateral was returned.
	StatusComplete
)

// String renders a status as a short label.
func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusActive:
		return "ACTIVE"
	case StatusComplete:
		return "COMPLETE"
	}
	return "UNKNOWN"
}

// Limits keep a circle inside numbers the reference realm can render and
// settle safely. They are advisory: an importing realm may enforce others.
const (
	MinSize          = 3
	MaxSize          = 50
	MinContribution  = int64(1000)         // 0.001 GNOT
	MaxContribution  = int64(100000000000) // 100,000 GNOT
	MinRoundSpan     = int64(60)           // 1 minute
	MaxRoundSpan     = int64(2592000)      // 30 days
	MaxNameLen       = 64
	DefaultRoundSpan = int64(604800) // 7 days
	UgnotPerGnot     = int64(1000000)
)

// Params is the immutable economics of a circle.
//
// Contribution is what each member pays every round. Collateral is what a
// member locks when joining; it is returned at completion and slashed into
// the penalty fund when the member defaults.
type Params struct {
	Contribution int64
	Collateral   int64
	Size         int
	RoundSpan    int64 // seconds per round
}

// Validate checks the parameters of a circle.
func (p Params) Validate() error {
	if p.Size < MinSize || p.Size > MaxSize {
		return errors.New("size must be between 3 and 50 members")
	}
	if p.Contribution < MinContribution || p.Contribution > MaxContribution {
		return errors.New("contribution out of range")
	}
	if p.Collateral != p.Contribution {
		return errors.New("collateral must equal one round contribution")
	}
	if p.RoundSpan < MinRoundSpan || p.RoundSpan > MaxRoundSpan {
		return errors.New("round span must be between 1 minute and 30 days")
	}
	return nil
}

// Pot is the payout one round produces when every seat pays.
func (p Params) Pot() int64 {
	return p.Contribution * int64(p.Size)
}

// Locked is the capital a circle needs at rest: every seat's collateral.
func (p Params) Locked() int64 {
	return p.Collateral * int64(p.Size)
}

// NetPerMember is the net cash flow of an ideal circle (no defaults) for a
// member who stays to the end: they pay Size contributions and receive one
// pot of Size contributions. It is always zero, which is the point of a
// ROSCA: it is a savings rotation, not a loan.
func (p Params) NetPerMember() int64 {
	return p.Pot() - p.Contribution*int64(p.Size)
}

