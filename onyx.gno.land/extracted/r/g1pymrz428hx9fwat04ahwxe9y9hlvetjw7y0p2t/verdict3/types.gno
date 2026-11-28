package verdict3

import verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"

type MarketStatus uint8

const (
	MarketOpen MarketStatus = iota
	MarketResolved
)

type ResolverKind uint8

const (
	ResolverBalance ResolverKind = iota + 1
	ResolverCounter
)

type ResolverConfig struct {
	Kind         ResolverKind
	Target       string
	TargetAmount int64
}

type Market struct {
	ID                     uint64
	Question               string
	Creator                address
	CloseHeight            int64
	YesPool                int64
	NoPool                 int64
	Status                 MarketStatus
	Outcome                verdict.Outcome
	Resolver               ResolverConfig
	RemainingClaimable     int64
	RemainingWinningShares int64
	NextActivityID         uint64
}

type Position struct {
	YesStake int64
	NoStake  int64
	Claimed  bool
}

type Activity struct {
	ID       uint64
	MarketID uint64
	Bettor   address
	Side     bool
	Stake    int64
	Height   int64
}

type Participant struct {
	Address     address
	RealizedNet int64
}
