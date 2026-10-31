// Package types holds the value types shared by core, the minters, the
// market and the readers. Every type is plain data (no pointers into realm
// state), so passing one across a realm boundary hands over a copy and
// never a capability.
package types

import (
	"errors"
)

// State is a collection's lifecycle (design §4.1):
//
//	Draft -> Scheduled -> Minting -> Closed -> Final
//
// Scheduled->Minting and Minting->Closed happen by block height; core
// reports the effective state and materializes it on the next write.
type State int

const (
	StateDraft State = iota
	StateScheduled
	StateMinting
	StateClosed
	StateFinal
)

func (s State) String() string {
	switch s {
	case StateDraft:
		return "draft"
	case StateScheduled:
		return "scheduled"
	case StateMinting:
		return "minting"
	case StateClosed:
		return "closed"
	case StateFinal:
		return "final"
	}
	return "unknown"
}

// MaxUnitPrice caps every price (ugnot) so price*count and fee math stay
// far from int64 overflow: 1e15 ugnot = 1e9 GNOT.
const MaxUnitPrice = 1_000_000_000_000_000

// Payee receives Bps/10000 of a payment.
type Payee struct {
	Addr address
	Bps  int64
}

// CollectionSpec is what a minter asks core to create. Payees travel as
// "addr:bps,…" strings and are parsed by core, so core never stores a slice
// allocated by another realm.
type CollectionSpec struct {
	Name, Symbol, Description string
	EngineID, Params          string
	MaxSupply, RoyaltyBps     int64
	PrimaryPayees             string
	RoyaltyPayees             string
}

// LaunchSpec freezes a collection's sale window and commitments (I-6).
type LaunchSpec struct {
	StartHeight, EndHeight int64
	RevealWindow           int64 // blocks after close; core bounds it
	CreatorCommit          string
	UseBeacon              bool
}

// CollectionInfo is core's typed read model for other realms.
type CollectionInfo struct {
	ID, Name, Symbol, Description string
	Creator                       address
	Minter, EngineID, Params      string
	State                         State
	MaxSupply, Minted, Reserved   int64
	StartHeight, EndHeight        int64
	RevealDeadline                int64 // 0 before Launch
	RoyaltyBps                    int64
	Badge                         string // provenance badge once Final
}

// Fees are the protocol's fee parameters; core enforces hard caps.
type Fees struct {
	CreateFee    int64 // ugnot per collection
	PrimaryBps   int64 // of every primary sale
	SecondaryBps int64 // of every market sale
	Treasury     address
}

// Phase kinds.
const (
	PhaseAllow  = "allow"
	PhasePublic = "public"
)

// Phase is one sale window. A fixed price has StartPrice == FloorPrice and
// no steps; a Dutch auction starts at StartPrice and drops StepAmount every
// StepBlocks until FloorPrice (design §4.5). WalletCap counts lifetime
// mints of the collection (I-9); 0 means no cap.
type Phase struct {
	Kind, Set                string
	StartHeight, EndHeight   int64
	StartPrice, FloorPrice   int64
	StepBlocks, StepAmount   int64
	WalletCap                int64
}

// Validate checks a phase in isolation; the minter checks the set grammar
// and how phases relate to each other.
func (p Phase) Validate() error {
	switch p.Kind {
	case PhasePublic:
		if p.Set != "" {
			return errors.New("a public phase has no allowlist set")
		}
	case PhaseAllow:
		if p.Set == "" {
			return errors.New("an allow phase needs a set")
		}
	default:
		return errors.New("phase kind must be allow or public")
	}
	if p.StartHeight <= 0 || p.EndHeight < p.StartHeight {
		return errors.New("phase heights must satisfy 0 < start <= end")
	}
	if p.FloorPrice < 0 || p.StartPrice < p.FloorPrice || p.StartPrice > MaxUnitPrice {
		return errors.New("prices must satisfy 0 <= floor <= start <= MaxUnitPrice")
	}
	if p.StartPrice == p.FloorPrice {
		if p.StepBlocks != 0 || p.StepAmount != 0 {
			return errors.New("a fixed-price phase has no steps")
		}
	} else if p.StepBlocks <= 0 || p.StepAmount <= 0 {
		return errors.New("a Dutch phase needs positive stepBlocks and stepAmount")
	}
	if p.WalletCap < 0 {
		return errors.New("walletCap must be >= 0")
	}
	return nil
}

// Covers reports whether height h is inside the phase window.
func (p Phase) Covers(h int64) bool {
	return h >= p.StartHeight && h <= p.EndHeight
}

// PriceAt is the unit price at height h:
//
//	max(floor, start - floor((h-startH)/stepBlocks) * stepAmount)
//
// computed so that no intermediate value can overflow.
func (p Phase) PriceAt(h int64) int64 {
	if p.StartPrice == p.FloorPrice || h <= p.StartHeight {
		return p.StartPrice
	}
	steps := (h - p.StartHeight) / p.StepBlocks
	if steps > (p.StartPrice-p.FloorPrice)/p.StepAmount {
		return p.FloorPrice
	}
	price := p.StartPrice - steps*p.StepAmount
	if price < p.FloorPrice {
		return p.FloorPrice
	}
	return price
}
