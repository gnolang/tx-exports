// Package pool is Mimir's two-sided pool prediction market, settled by an AI
// oracle: the gno.land port of contracts/MimirPoolErc20.sol. Stakes are mUSD
// (gno.land/r/.../musd, 6 decimals).
//
// Model
//   - A market has two sides, A and B (YES / NO). The creator opens it with a
//     stake on one side. Anyone, the creator included, can then stake on either
//     side until LockSeconds before the deadline. Stakes by the same address
//     add up per side.
//   - After the deadline the oracle proposes A, B, DRAW or UNRESOLVABLE. A
//     participant can dispute within the dispute window by posting
//     DisputeBond; the arbiter then rules. The bond comes back if the ruling
//     changes the verdict and goes to the platform otherwise. An undisputed
//     proposal is finalized by anyone.
//   - Escape hatch: ResolutionGraceSeconds after the deadline (or after the
//     proposal or dispute), anyone can refund the market in full. From that
//     moment the oracle and the arbiter can no longer rule.
//   - Fees: every stake pays an entry fee, fees.EntryBps(caller) of the amount
//     (0.5% by default, less with a signed ticket); the rest is staked. The
//     entry fee is kept on refunds. Winnings pay no fee, except copy trades: a
//     stake made with a referrer pays ReferrerFeeBps of its net profit to the
//     referrer and CopyFeeBps to the platform.
//   - Payout: a winner gets their stake back plus a pro-rata share of the
//     losing side, rounded down (dust stays in the realm). If either side is
//     empty, or on DRAW / UNRESOLVABLE, everyone gets their stake back.
//   - Settlement only records the outcome. Each staker is then paid by
//     Claim(id), or by anyone through ClaimFor(id, user).
//   - Roles: owner, arbiter (rules disputes), oracle (may never also be owner,
//     arbiter or fee recipient), fee recipient, and an optional audit agent
//     that may dispute. Ownership, oracle and fee-recipient changes are
//     timelocked; the owner can revoke the oracle at once, veto a proposal to
//     the arbiter, cap stakes, set an early lock and pause.
//   - Pause stops new markets and stakes AND settlement and winners' payouts;
//     refunds are still paid, and RefundExpired while paused refunds instead of
//     honouring a proposal.
//
// Differences from the EVM contract, all from the transport:
//   - Amounts are mUSD units in int64; MinStake, DisputeBond and caps are in
//     those units. The caller approves this realm on mUSD first; Adena sends
//     the approve and the call in one transaction, so there are no *WithPermit
//     variants.
//   - mUSD has no blacklist and no callbacks, so a payout cannot be refused and
//     cannot re-enter: payouts are sent directly (no parked withdrawals, no
//     gas stipend, no reentrancy lock).
//   - Times are block-time unix seconds.
package pool

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

// Market states.
const (
	StOpen     = 0
	StProposed = 1
	StDisputed = 2
	StResolved = 3
)

// Sides and outcomes.
const (
	SideA        = 1
	SideB        = 2
	Draw         = 3
	Unresolvable = 4
)

const (
	// MinStake is the smallest gross stake: 0.1 mUSD.
	MinStake = int64(100_000)
	// DisputeBond is 2 mUSD, independent of the stake minimum so disputes stay costly to spam.
	DisputeBond = int64(2_000_000)
	// No new stakes in the final LockSeconds before the deadline (anti-sniping).
	LockSeconds      = int64(60)
	MaxDeadlineAhead = int64(365 * 24 * 60 * 60)
	// Entry fees above 1% are refused, whatever the fee realm answers.
	MaxEntryBps            = int64(100)
	ReferrerFeeBps         = int64(100)
	CopyFeeBps             = int64(100)
	ResolutionGraceSeconds = int64(7 * 24 * 60 * 60)
	MaxDisputeWindow       = int64(7 * 24 * 60 * 60)
	// On mainnet a proposal stays disputable at least this long.
	MinLiveDisputeWindow = int64(24 * 60 * 60)
	// TestnetDisputeWindow lets a testnet show the whole flow in minutes.
	TestnetDisputeWindow = int64(10 * 60)
)

// Initial roles. The owner can change each one afterwards.
const (
	Deployer       = address("g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz")
	InitialOracle  = address("g18pnec3atge4msr5hhanm790tljtdyd87s0wguh")
	InitialArbiter = address("g1af78r3tuv84mf3cd0kxrssmw6g2v2mvvc6phpv")
)

type Market struct {
	ID            int64
	Creator       address
	Deadline      int64
	CreatedAt     int64
	State         int
	Outcome       int // final, once resolved
	Proposed      int // the oracle's proposal
	ProposedAt    int64
	DisputedAt    int64
	Disputer      address
	Bond          int64
	TotalA        int64
	TotalB        int64
	EvidenceHash  string // hex sha256 of the oracle's evidence
	Question      string
	LabelA        string
	LabelB        string
	ResolutionURL string
	Category      string
	Summary       string
	// 0 includes all deposits; otherwise only deposits strictly before it compete.
	SettlementCutoff int64
	// Optional early close: stakes stop at LockAt instead of LockSeconds before the deadline.
	LockAt    int64
	EntryFees int64

	history   mimir.History // market totals over time
	positions avl.Tree      // address -> *Position
}

type Position struct {
	A, B         int64 // net stakes
	CopyA, CopyB int64 // the copied part of each
	Referrer     address
	Claimed      bool
	history      mimir.History
}

var (
	markets     avl.Tree // padded id -> *Market
	marketCount int64

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

func now() int64 { return time.Now().Unix() }

func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func key(id int64) string {
	s := itoa(id)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func getMarket(id int64) *Market {
	v := markets.Get(key(id))
	if v == nil {
		panic("NoMarket")
	}
	return v.(*Market)
}

func (m *Market) position(user address) *Position {
	if v := m.positions.Get(user.String()); v != nil {
		return v.(*Position)
	}
	return nil
}

func (m *Market) mustPosition(user address) *Position {
	p := m.position(user)
	if p == nil {
		p = &Position{}
		m.positions.Set(user.String(), p)
	}
	return p
}

func feesOf(a address) int64 {
	if v := accruedFees.Get(a.String()); v != nil {
		return v.(int64)
	}
	return 0
}

func accrue(id int64, to address, amount int64) {
	accruedFees.Set(to.String(), mimir.Add(feesOf(to), amount))
	lifetimeFeesAccrued = mimir.Add(lifetimeFeesAccrued, amount)
	emit("FeeAccrued", "id", itoa(id), "recipient", to.String(), "amount", itoa(amount))
}

// pull moves exactly amount mUSD from the caller into this realm (needs an allowance).
func pull(cur realm, from address, amount int64) {
	musd.TransferFrom(cross(cur), from, cur.Address(), amount)
}

func push(cur realm, to address, amount int64) {
	if amount == 0 {
		return
	}
	musd.Transfer(cross(cur), to, amount)
}

func caller(cur realm) address { return cur.Previous().Address() }

func assertOwner(cur realm) { roles.AssertOwner(caller(cur)) }

func assertNotPaused() { roles.AssertNotPaused() }

func parseReferrer(s string) address { return mimir.ParseOptional(s) }

func entryBps(a address) int64 { return fees.EntryBps(a) }
