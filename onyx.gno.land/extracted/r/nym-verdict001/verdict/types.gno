package verdict

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nym-verdict001/fpmm"
)

const (
	// Denom is the native collateral and bond denomination.
	Denom = "ugnot"

	// MinInitialLiquidity requires at least 0.1 GNOT when seeding a new market.
	MinInitialLiquidity int64 = 100_000

	// DefaultBondAmount is 1 GNOT required to propose or dispute an outcome.
	DefaultBondAmount int64 = 1_000_000

	// MinAllowedBond and MaxAllowedBond bound admin bond updates.
	MinAllowedBond int64 = 100_000
	MaxAllowedBond int64 = 100_000_000

	// DefaultDisputeWindow, MinDisputeWindow, and MaxDisputeWindow bound optimistic challenge periods (seconds).
	DefaultDisputeWindow int64 = 3600
	MinDisputeWindow     int64 = 60
	MaxDisputeWindow     int64 = 7 * 86400

	// MinMarketDuration and MaxMarketDuration bound market lifetime from creation (seconds).
	MinMarketDuration int64 = 60
	MaxMarketDuration int64 = 365 * 86400

	// ArbiterTimeout allows permissionless INVALID resolution if arbiters stall for 7 days.
	ArbiterTimeout int64 = 7 * 86400

	// Input length and storage bounds.
	MaxQuestionLen    = 200
	MaxDescriptionLen = 1000
	MaxCategoryLen    = 32
	MaxPriceHistory   = 64
	MaxArbiters       = 21
	MaxPageLimit      = 50
)

// MarketStatus represents the lifecycle state of a prediction market.
type MarketStatus uint8

const (
	StatusOpen     MarketStatus = 0
	StatusProposed MarketStatus = 1
	StatusDisputed MarketStatus = 2
	StatusResolved MarketStatus = 3
)

// String returns a human-readable market status label.
func (s MarketStatus) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusProposed:
		return "PROPOSED"
	case StatusDisputed:
		return "DISPUTED"
	case StatusResolved:
		return "RESOLVED"
	default:
		return "UNKNOWN"
	}
}

// Outcome represents the resolution state of a binary market.
type Outcome uint8

const (
	OutcomeUnresolved Outcome = 0
	OutcomeYes        Outcome = 1
	OutcomeNo         Outcome = 2
	OutcomeInvalid    Outcome = 3
)

// ValidResolution reports whether o is a terminal resolution outcome (YES, NO, or INVALID).
func (o Outcome) ValidResolution() bool {
	return o == OutcomeYes || o == OutcomeNo || o == OutcomeInvalid
}

// String returns a human-readable outcome label.
func (o Outcome) String() string {
	switch o {
	case OutcomeUnresolved:
		return "UNRESOLVED"
	case OutcomeYes:
		return "YES"
	case OutcomeNo:
		return "NO"
	case OutcomeInvalid:
		return "INVALID"
	default:
		return "UNKNOWN"
	}
}

type position struct {
	yesShares   int64
	noShares    int64
	lpShares    int64
	feeDebt     int64
	pendingFees int64
	claimed     bool
}

type pricePoint struct {
	timestamp  int64
	yesProbBps int64
	volume     int64
}

// MarketView is a read-only value copy of market state safe for vm/qeval_json.
type MarketView struct {
	ID                 uint64
	Question           string
	Description        string
	Category           string
	Creator            address
	CreatedAt          int64
	CloseTime          int64
	DisputeWindow      int64
	BondAmount         int64
	Status             MarketStatus
	StatusLabel        string
	ReserveYes         int64
	ReserveNo          int64
	TotalLP            int64
	FeeBps             int64
	YesProbBps         int64
	NoProbBps          int64
	Collateral         int64
	FeePool            int64
	TotalYesOut        int64
	TotalNoOut         int64
	TotalVolume        int64
	TradeCount         int64
	ProposedOutcome    Outcome
	Proposer           address
	ProposedAt         int64
	DisputeDeadline    int64
	ProposerBond       int64
	Disputer           address
	DisputedAt         int64
	DisputerBond       int64
	FinalOutcome       Outcome
	FinalOutcomeLabel  string
	ResolvedAt         int64
	ArbiterQuorum      int
	YesVotes           int
	NoVotes            int
	InvalidVotes       int
	RemainingLP        int64
	RemainingWinShares int64
}

// PositionView is a read-only value copy of a user's position in a market.
type PositionView struct {
	MarketID     uint64
	Address      address
	YesShares    int64
	NoShares     int64
	LPShares     int64
	PendingFees  int64
	EstClaimable int64
	Claimed      bool
}

// PricePointView is a value copy of an on-chain probability tick.
type PricePointView struct {
	Timestamp  int64
	YesProbBps int64
	Volume     int64
}

// ProtocolStats summarizes protocol-wide balances and activity.
type ProtocolStats struct {
	Admin               address
	RealmAddress        address
	MarketCount         int
	ResolvedMarketCount int
	TotalCollateral     int64
	TotalFeePool        int64
	TotalActiveBonds    int64
	TotalClaimableBonds int64
	ProtocolDustPool    int64
	VaultBalance        int64
	TotalVolume         int64
	TotalTrades         int64
	DefaultBond         int64
	ArbiterCount        int
	ArbiterQuorum       int
}

// market is stored exclusively inside unexported realm state.
type market struct {
	id            uint64
	question      string
	description   string
	category      string
	creator       address
	createdAt     int64
	closeTime     int64
	disputeWindow int64
	bondAmount    int64

	pool        fpmm.Pool
	feeAcc      fpmm.FeeAccumulator
	collateral  int64
	feePool     int64
	totalYesOut int64
	totalNoOut  int64
	totalVolume int64
	tradeCount  int64

	status          MarketStatus
	proposedOutcome Outcome
	proposer        address
	proposedAt      int64
	disputeDeadline int64
	proposerBond    int64
	disputer        address
	disputedAt      int64
	disputerBond    int64
	finalOutcome    Outcome
	resolvedAt      int64

	arbiterQuorum int
	arbiterVotes  *avl.Tree // addr.String() -> Outcome (lazy-initialized on dispute)
	yesVotes      int
	noVotes       int
	invalidVotes  int

	settlementYes      int64
	settlementNo       int64
	settlementLP       int64
	remainingLP        int64
	remainingWinShares int64

	positions    *avl.Tree // addr.String() -> *position
	priceHistory []pricePoint
}
