// Package vs is Mimir's VS (duel) market, settled by an AI oracle: the
// gno.land port of contracts/MimirV3Erc20.sol. Stakes are mUSD.
//
// A creator opens a claim with a stake on their position. Challengers take the
// other side, each once, up to the claim's maxChallengers (at most 100):
//   - pool odds: challengers share the creator's stake pro rata, and together
//     may stake at most MaxPoolMultiple times the creator's stake;
//   - fixed odds: each challenger is paid challengerPayoutBps of their stake
//     (2x by default, at most 10x), and the creator's unreserved stake must
//     cover every challenger's profit when they join.
//
// After the deadline the oracle proposes CREATOR, CHALLENGERS, DRAW or
// UNRESOLVABLE with a confidence and the hash of its evidence. A participant
// may dispute within the dispute window by posting DisputeBond; the arbiter
// rules. An undisputed proposal is finalized by anyone. Settlement pays every
// participant in the same transaction. Draws, unresolvable questions and
// claims nobody challenged before the cutoff refund every stake.
//
// Fees: an entry fee on every stake that opens or joins a claim
// (fees.EntryBps, 0.5% by default), kept on refunds. No fee on winnings,
// except copy trades: ReferrerFeeBps of the profit to the referrer and
// CopyFeeBps to the platform.
//
// Private claims: only wallets the creator invites may challenge. Market data
// and transactions stay public.
//
// Differences from the EVM contract come from the transport, as in the pool
// realm: mUSD with an approve in the same transaction (no permit variants),
// payouts sent directly (mUSD cannot refuse or re-enter), block-time seconds.
// SetInvited takes a comma-separated address list.
package vs

import (
	"chain"
	"chain/runtime"
	"strconv"
	"time"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/fees"
	"gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/musd"
)

// Claim states.
const (
	StOpen      = 0
	StActive    = 1
	StResolved  = 2
	StCancelled = 3
	StProposed  = 4 // the oracle has proposed a verdict; disputable until the window closes
	StDisputed  = 5 // a participant disputed; the arbiter decides
)

// Winner sides.
const (
	SideNone         = 0
	SideCreator      = 1
	SideChallengers  = 2
	SideDraw         = 3
	SideUnresolvable = 4
)

const (
	MaxChallengers  = 100
	MaxPoolMultiple = int64(5)
	// MinStake is the smallest gross stake that opens or joins a claim: 0.1 mUSD.
	MinStake         = int64(100_000)
	DisputeBond      = int64(2_000_000)
	DefaultPayoutBps = int64(20_000) // 2x
	// Fixed odds pay at most 10x.
	MaxPayoutBps     = int64(100_000)
	MaxDeadlineAhead = int64(365 * 24 * 60 * 60)
	MaxEntryBps      = int64(100)
	// Anti-sniping: no new challenges in the final seconds before the deadline.
	ChallengeLockSeconds   = int64(60)
	ReferrerFeeBps         = int64(100)
	CopyFeeBps             = int64(100)
	ResolutionGraceSeconds = int64(7 * 24 * 60 * 60)
	MinLiveDisputeWindow   = int64(24 * 60 * 60)
	TestnetDisputeWindow   = int64(10 * 60)
)

const (
	Deployer       = address("g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz")
	InitialOracle  = address("g18pnec3atge4msr5hhanm790tljtdyd87s0wguh")
	InitialArbiter = address("g1af78r3tuv84mf3cd0kxrssmw6g2v2mvvc6phpv")
)

type Challenger struct {
	Addr     address
	Stake    int64 // net
	At       int64
	Referrer address
}

type Proposal struct {
	WinnerSide   int
	Confidence   int
	ProposedAt   int64
	DisputedAt   int64
	Disputer     address
	Bond         int64
	EvidenceHash string
	Summary      string
}

type Claim struct {
	ID                       int64
	Creator                  address
	Question                 string
	CreatorPosition          string
	CounterPosition          string
	ResolutionURL            string
	CreatorStake             int64
	TotalChallengerStake     int64
	ReservedCreatorLiability int64
	Deadline                 int64
	State                    int
	WinnerSide               int
	ResolutionSummary        string
	Confidence               int
	Category                 string
	ParentID                 int64
	CreatedAt                int64
	MarketType               string // binary | moneyline | spread | total | prop | custom
	OddsMode                 string // pool | fixed
	ChallengerPayoutBps      int64  // fixed odds, e.g. 20000 = 2x
	HandicapLine             string
	SettlementRule           string
	MaxChallengers           int
	IsPrivate                bool
	EvidenceHash             string
	Referrer                 address // the creator's referrer
	EntryFees                int64
	SettlementCutoff         int64
	LockAt                   int64
	Proposal                 Proposal

	challengers []*Challenger
	joined      avl.Tree // address -> true
	invited     avl.Tree // address -> bool
}

var (
	claims        avl.Tree // padded id -> *Claim
	claimCount    int64
	totalResolved int64

	wins   avl.Tree // address -> int64
	losses avl.Tree

	accruedFees         avl.Tree // address -> int64
	lifetimeFeesAccrued int64
	lifetimeFeesClaimed int64

	roles         *mimir.Roles
	disputeWindow int64
)

func init(cur realm) {
	roles = mimir.NewRoles(Deployer, InitialArbiter, InitialOracle, Deployer)
	disputeWindow = TestnetDisputeWindow
	if runtime.ChainID() == "gnoland-1" {
		disputeWindow = MinLiveDisputeWindow
	}
}

func now() int64                       { return time.Now().Unix() }
func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }
func itoa(n int64) string              { return strconv.FormatInt(n, 10) }
func caller(cur realm) address         { return cur.Previous().Address() }

func key(id int64) string {
	s := itoa(id)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func getClaim(id int64) *Claim {
	v := claims.Get(key(id))
	if v == nil {
		panic("ClaimNotFound")
	}
	return v.(*Claim)
}

func (c *Claim) hasJoined(a address) bool { return c.joined.Has(a.String()) }

func (c *Claim) isInvited(a address) bool {
	v := c.invited.Get(a.String())
	return v != nil && v.(bool)
}

func counter(t *avl.Tree, a address) int64 {
	if v := t.Get(a.String()); v != nil {
		return v.(int64)
	}
	return 0
}

func bump(t *avl.Tree, a address) { t.Set(a.String(), counter(t, a)+1) }

func accrue(id int64, to address, amount int64) {
	accruedFees.Set(to.String(), mimir.Add(counter(&accruedFees, to), amount))
	lifetimeFeesAccrued = mimir.Add(lifetimeFeesAccrued, amount)
	emit("FeeAccrued", "id", itoa(id), "recipient", to.String(), "amount", itoa(amount))
}

func pull(cur realm, from address, amount int64) {
	musd.TransferFrom(cross(cur), from, cur.Address(), amount)
}

func push(cur realm, to address, amount int64) {
	if amount == 0 {
		return
	}
	musd.Transfer(cross(cur), to, amount)
}

// takeEntry pulls `amount` from the caller, keeps the caller's entry fee and
// returns the rest: the stake that is recorded and can be won or refunded.
func takeEntry(cur realm, c *Claim, user address, amount int64) int64 {
	pull(cur, user, amount)
	bps := fees.EntryBps(user)
	if bps > MaxEntryBps {
		panic("EntryFeeTooHigh")
	}
	fee := mimir.MulDiv(amount, bps, 10_000)
	if fee != 0 {
		accrue(c.ID, roles.FeeRecipient, fee)
		c.EntryFees += fee
	}
	return amount - fee
}

func grossPayout(stake, bps int64) int64 { return mimir.MulDiv(stake, bps, 10_000) }

// payWinner pays a winner. Only a copy trade pays a fee on winnings:
// ReferrerFeeBps of the profit to the referrer and CopyFeeBps to the platform.
// Profit is gross - principal floored at zero, so a refund and a break-even
// win are free. Nobody pays themselves.
func payWinner(cur realm, id int64, to address, gross, principal int64, referrer address) (paid, taken int64) {
	profit := int64(0)
	if gross > principal {
		profit = gross - principal
	}
	if profit != 0 && referrer != "" && referrer != to {
		refFee := mimir.MulDiv(profit, ReferrerFeeBps, 10_000)
		if refFee != 0 {
			accrue(id, referrer, refFee)
		}
		copyFee := int64(0)
		if roles.FeeRecipient != to {
			copyFee = mimir.MulDiv(profit, CopyFeeBps, 10_000)
		}
		if copyFee != 0 {
			accrue(id, roles.FeeRecipient, copyFee)
		}
		taken = refFee + copyFee
	}
	paid = gross - taken
	push(cur, to, paid)
	return paid, taken
}
