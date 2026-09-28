package otc

// Side says which half of the offer the maker escrowed.
type Side int

const (
	SellToken Side = 1 // maker escrows the token, taker pays GNOT
	SellGnot  Side = 2 // maker escrows GNOT, taker pays the token
)

func (s Side) String() string {
	switch s {
	case SellToken:
		return "SellToken"
	case SellGnot:
		return "SellGnot"
	}
	return "unknown"
}

// Status is Open until the offer is filled or cancelled. Both are terminal
// (R12).
type Status int

const (
	Open      Status = 1
	Filled    Status = 2
	Cancelled Status = 3
)

func (s Status) String() string {
	switch s {
	case Open:
		return "Open"
	case Filled:
		return "Filled"
	case Cancelled:
		return "Cancelled"
	}
	return "unknown"
}

// Offer is one escrowed trade: exactly one GRC20 side and one GNOT side (R1).
type Offer struct {
	ID        uint64
	Maker     address
	Taker     address // empty = public (R4), set = private (R5)
	Side      Side
	TokenKey  string // grc20reg key (W3)
	TokenAmt  int64  // base units of the token
	GnotAmt   int64  // ugnot
	FeeBps    int64  // copied at creation, never changed (F4, I4)
	ExpiresAt int64  // unix seconds, 0 = none (R9)
	CreatedAt int64
	Status    Status
}

// Errors are short and stable so that tests and the frontend can match them.
const (
	ErrPaused         = "otc: paused"
	ErrNotUser        = "otc: must be a direct user call"
	ErrNoCoins        = "otc: this call takes no coins"
	ErrBadPayment     = "otc: send exactly the required ugnot and nothing else"
	ErrBadAmount      = "otc: amounts must be positive"
	ErrBadExpiry      = "otc: expiry must be 0 or in the future"
	ErrBadAddress     = "otc: invalid address"
	ErrTakerIsMaker   = "otc: taker cannot be the maker"
	ErrTokenNotListed = "otc: token not whitelisted"
	ErrTokenDisabled  = "otc: token disabled"
	ErrTokenUnknown   = "otc: token not in grc20reg"
	ErrTokenExists    = "otc: token already whitelisted"
	ErrTooManyTokens  = "otc: token whitelist is full"
	ErrNoOffer        = "otc: no such offer"
	ErrNotOpen        = "otc: offer is not open"
	ErrNotMaker       = "otc: not maker"
	ErrNotTaker       = "otc: offer is reserved for another taker"
	ErrOwnOffer       = "otc: maker cannot fill own offer"
	ErrExpired        = "otc: offer expired"
	ErrNotAdmin       = "otc: not admin"
	ErrFeeAboveCap    = "otc: fee above cap"
	ErrFeeToRealm     = "otc: fee recipient cannot be the realm"
)
