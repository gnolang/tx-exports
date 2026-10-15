// Package markets is realm v2 of 67: fully collateralized markets on Gno with a
// service fee, two-sided expiring quotes, limits, pauses, a resolution window,
// void refunds and an abandonment exit. It does not discover outcomes: each
// market trusts its pinned oracle, and a guardian can cancel a proposal for 24
// hours before anyone can make it final.
//
// Money only leaves through Claim (to the holder who calls) and WithdrawSurplus
// (to the market's fixed treasury, after it is final). Nothing can pause them.
package markets

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	scale    int64 = 1000000
	maxInt64 int64 = 9223372036854775807

	// MaxFeePpm caps every market's service fee rate θ at 0.07. A rate is fixed
	// when a market is listed and can never change.
	MaxFeePpm int64 = 70000
	// Each side's price stays inside 0.03 to 0.97; outside it the quoter pauses.
	MinPricePpm int64 = 30000
	MaxPricePpm int64 = 970000
	// DisputeWindow is how long a proposed outcome waits before anyone can make
	// it final; the guardian can cancel it in that time.
	DisputeWindow int64 = 24 * 60 * 60
	// AbandonAfter: if no outcome is final this long after trading ends, anyone
	// can void the market and every holder takes a refund.
	AbandonAfter int64 = 60 * 24 * 60 * 60

	minQuoteTTL  int64 = 5 * 60
	maxQuoteTTL  int64 = 7 * 24 * 60 * 60
	maxMinSpread int64 = 100000
	maxHistory         = 96
)

// Market states. A market moves between open and paused, from either to
// proposed, and from proposed to final. A cancelled proposal returns it to
// paused; abandonment takes an open or paused market to final (Void).
const (
	StateOpen     = "open"
	StatePaused   = "paused"
	StateProposed = "proposed"
	StateFinal    = "final"
)

// All amounts are integer ugnot. One million micro-shares is one share; a
// winning micro-share pays one ugnot (one whole share pays one GNOT).
type Market struct {
	ID          string `json:"id"`
	Question    string `json:"question"`
	Rules       string `json:"rules"`
	RulesHash   string `json:"rulesHash"`
	ConditionID string `json:"conditionId"`
	YesTokenID  string `json:"yesTokenId"`
	NoTokenID   string `json:"noTokenId"`
	// The outcomes' names as Polymarket shows them, in token order: "Yes" and
	// "No", or two teams. Yes and No below always mean the first and second token.
	YesLabel  string  `json:"yesLabel"`
	NoLabel   string  `json:"noLabel"`
	Oracle    address `json:"oracle"`
	Treasury  address `json:"treasury"`
	Topic     string  `json:"topic"` // the 67 topic it is shown under, fixed at listing
	FeePpm    int64   `json:"feePpm"`
	CreatedAt int64   `json:"createdAt"`
	// TradingEndsAt is set at listing, before the source event.
	TradingEndsAt int64 `json:"tradingEndsAt"`
	AbandonAt     int64 `json:"abandonAt"`

	YesPricePpm  int64 `json:"yesPricePpm"`
	NoPricePpm   int64 `json:"noPricePpm"`
	QuoteVersion int64 `json:"quoteVersion"`
	QuotedAt     int64 `json:"quotedAt"`

	State        string `json:"state"`
	Outcome      string `json:"outcome"` // proposed or final: Yes, No or Void
	EvidenceHash string `json:"evidenceHash"`
	ProposedAt   int64  `json:"proposedAt"`
	FinalizedAt  int64  `json:"finalizedAt"`

	// EscrowUgnot is the collateral: reserve plus purchase costs, less payouts,
	// refunds and withdrawn surplus. FeesUgnot is held apart from it.
	EscrowUgnot        int64 `json:"escrowUgnot"`
	FeesUgnot          int64 `json:"feesUgnot"`
	ReserveUgnot       int64 `json:"reserveUgnot"`
	CostUgnot          int64 `json:"costUgnot"`
	FeesCollectedUgnot int64 `json:"feesCollectedUgnot"`
	YesMicroShares     int64 `json:"yesMicroShares"`
	NoMicroShares      int64 `json:"noMicroShares"`
	PaidUgnot          int64 `json:"paidUgnot"`
	RefundedCostUgnot  int64 `json:"refundedCostUgnot"`
	RefundedFeesUgnot  int64 `json:"refundedFeesUgnot"`
	WithdrawnUgnot     int64 `json:"withdrawnUgnot"`

	MaxTradeMicroShares  int64 `json:"maxTradeMicroShares"`
	MaxHolderMicroShares int64 `json:"maxHolderMicroShares"`
	MaxSideMicroShares   int64 `json:"maxSideMicroShares"`

	Holders     int64 `json:"holders"` // positions not yet settled
	VolumeUgnot int64 `json:"volumeUgnot"`
	Trades      int64 `json:"trades"`
}

// QuotePoint records one published quote, in block-time order.
type QuotePoint struct {
	At          int64 `json:"at"`
	YesPricePpm int64 `json:"yesPricePpm"`
	NoPricePpm  int64 `json:"noPricePpm"`
	Version     int64 `json:"version"`
}

// Position is an open holding. It is deleted when its holder claims, so the
// storage it used is released; the Claimed event keeps the record.
type Position struct {
	YesMicroShares int64 `json:"yesMicroShares"`
	NoMicroShares  int64 `json:"noMicroShares"`
	SpentUgnot     int64 `json:"spentUgnot"`
	FeeUgnot       int64 `json:"feeUgnot"`
}

type marketRecord struct {
	market    Market
	positions map[address]Position
	history   []QuotePoint
}

// Limits bound new purchases. They never affect claims.
type Limits struct {
	MaxTradeMicroShares  int64 `json:"maxTradeMicroShares"`
	MaxHolderMicroShares int64 `json:"maxHolderMicroShares"`
	MaxSideMicroShares   int64 `json:"maxSideMicroShares"`
}

// OriginCaller is used only at package initialization, to capture the deployer
// as the first holder of every role. Entry points use the live caller.
var (
	administrator        = unsafe.OriginCaller()
	pendingAdministrator address
	quoter               = unsafe.OriginCaller()
	pendingQuoter        address
	guardian             = unsafe.OriginCaller()
	pendingGuardian      address
	lister               address
	pendingLister        address

	// The terms a lister must list with; only the administrator sets them.
	listingOracle   address
	listingTreasury address
	listingFeePpm   int64

	realmPaused    bool
	quoteTTL       int64 = 60 * 60
	minSpreadPpm   int64
	maxExposure    int64 = 200000 * scale // micro-shares owed if every open market ends on its larger side
	openExposure   int64
	defaultLimits  = Limits{MaxTradeMicroShares: 500 * scale, MaxHolderMicroShares: 2000 * scale, MaxSideMicroShares: 20000 * scale}
	records        = make(map[string]*marketRecord)
	marketIDs      []string
	totalHeldUgnot int64 // every market's escrow plus fees still held
)

// ----- Roles -----

func Administrator() address { return administrator }
func Quoter() address        { return quoter }
func Guardian() address      { return guardian }
func Lister() address        { return lister }

// ProposeRole starts a two-step handover of "admin", "quoter", "guardian" or
// "lister".
// The proposed address accepts from its own direct call, so a mistyped
// address cannot take a role.
func ProposeRole(cur realm, role string, next address) {
	assertOwnKey(0, cur)
	require(caller(0, cur) == administrator, "administrator only")
	require(next.IsValid(), "invalid address")
	switch role {
	case "admin":
		require(next != administrator, "already the administrator")
		pendingAdministrator = next
	case "quoter":
		pendingQuoter = next
	case "guardian":
		pendingGuardian = next
	case "lister":
		pendingLister = next
	default:
		panic("unknown role")
	}
	chain.Emit("RoleProposed", "role", role, "next", string(next))
}

// AcceptRole completes a handover started by ProposeRole.
func AcceptRole(cur realm, role string) {
	assertOwnKey(0, cur)
	who := caller(0, cur)
	switch role {
	case "admin":
		require(pendingAdministrator != "" && who == pendingAdministrator, "pending administrator only")
		administrator, pendingAdministrator = who, ""
	case "quoter":
		require(pendingQuoter != "" && who == pendingQuoter, "pending quoter only")
		quoter, pendingQuoter = who, ""
	case "guardian":
		require(pendingGuardian != "" && who == pendingGuardian, "pending guardian only")
		guardian, pendingGuardian = who, ""
	case "lister":
		require(pendingLister != "" && who == pendingLister, "pending lister only")
		lister, pendingLister = who, ""
	default:
		panic("unknown role")
	}
	chain.Emit("RoleAccepted", "role", role, "holder", string(who))
}

// RevokeRole empties the quoter, guardian or lister role at once, for a lost or
// stolen key. The administrator role can only be handed over.
func RevokeRole(cur realm, role string) {
	assertOwnKey(0, cur)
	require(caller(0, cur) == administrator, "administrator only")
	switch role {
	case "quoter":
		quoter, pendingQuoter = "", ""
	case "guardian":
		guardian, pendingGuardian = "", ""
	case "lister":
		lister, pendingLister = "", ""
	default:
		panic("only the quoter, guardian or lister can be revoked")
	}
	chain.Emit("RoleRevoked", "role", role)
}

// ----- Settings -----

// SetSettings changes the quote lifetime, the minimum spread and the realm-wide
// exposure cap. They apply to new quotes and purchases only.
func SetSettings(cur realm, quoteTTLSeconds, minimumSpreadPpm, maxExposureMicroShares int64) {
	assertOwnKey(0, cur)
	require(caller(0, cur) == administrator, "administrator only")
	require(quoteTTLSeconds >= minQuoteTTL && quoteTTLSeconds <= maxQuoteTTL, "quote lifetime out of range")
	require(minimumSpreadPpm >= 0 && minimumSpreadPpm <= maxMinSpread, "spread out of range")
	require(maxExposureMicroShares > 0, "invalid exposure cap")
	quoteTTL, minSpreadPpm, maxExposure = quoteTTLSeconds, minimumSpreadPpm, maxExposureMicroShares
	chain.Emit("SettingsChanged", "quoteTTL", decimal(quoteTTL), "minSpreadPpm", decimal(minSpreadPpm), "maxExposureMicroShares", decimal(maxExposure))
}

// SetLimits changes one market's purchase limits, or with id "" the limits new
// markets start with.
func SetLimits(cur realm, id string, maxTradeMicroShares, maxHolderMicroShares, maxSideMicroShares int64) {
	assertOwnKey(0, cur)
	require(caller(0, cur) == administrator, "administrator only")
	require(maxTradeMicroShares > 0 && maxHolderMicroShares > 0 && maxSideMicroShares > 0, "invalid limits")
	require(maxTradeMicroShares <= maxSideMicroShares, "a trade cannot exceed the market limit")
	l := Limits{MaxTradeMicroShares: maxTradeMicroShares, MaxHolderMicroShares: maxHolderMicroShares, MaxSideMicroShares: maxSideMicroShares}
	if id == "" {
		defaultLimits = l
	} else {
		r := mustMarket(id)
		require(r.market.State != StateFinal, "market is final")
		r.market.MaxTradeMicroShares, r.market.MaxHolderMicroShares, r.market.MaxSideMicroShares = l.MaxTradeMicroShares, l.MaxHolderMicroShares, l.MaxSideMicroShares
	}
	chain.Emit("LimitsChanged", "market", id, "maxTradeMicroShares", decimal(maxTradeMicroShares), "maxHolderMicroShares", decimal(maxHolderMicroShares), "maxSideMicroShares", decimal(maxSideMicroShares))
}

// ----- Listing and quotes -----

// SetListingTerms fixes the oracle, treasury and fee rate every market listed
// by the lister must carry. A lister key can then only add markets on these
// terms; it can never choose who settles them or where their surplus goes.
func SetListingTerms(cur realm, oracle, treasury address, feePpm int64) {
	assertOwnKey(0, cur)
	require(caller(0, cur) == administrator, "administrator only")
	require(oracle.IsValid() && treasury.IsValid(), "invalid address")
	require(oracle != administrator && oracle != quoter && oracle != lister, "the oracle must be a separate account")
	require(feePpm >= 0 && feePpm <= MaxFeePpm, "fee rate above the cap")
	listingOracle, listingTreasury, listingFeePpm = oracle, treasury, feePpm
	chain.Emit("ListingTermsChanged", "oracle", string(oracle), "treasury", string(treasury), "feePpm", decimal(feePpm))
}

// CreateMarket freezes every field used to match an external result, the fee
// rate, the oracle and the treasury. Nothing but the quote and the limits can
// change later. The administrator chooses the terms; the lister must use the
// listing terms.
func CreateMarket(cur realm, id, question, rules, conditionID, yesTokenID, noTokenID, yesLabel, noLabel string, tradingEndsAt, yesPricePpm, noPricePpm, feePpm int64, oracle, treasury address, topic string) {
	assertOwnKey(0, cur)
	who := caller(0, cur)
	require(who == administrator || who != "" && who == lister, "administrator or lister only")
	if who != administrator {
		require(listingOracle != "" && oracle == listingOracle && treasury == listingTreasury && feePpm == listingFeePpm, "the lister must use the listing terms")
	}
	require(records[id] == nil, "market already exists")
	require(id != "" && len(id) <= 64 && isSlug(id), "invalid market ID")
	require(question != "" && len(question) <= 1024 && utf8.ValidString(question), "invalid question")
	require(rules != "" && len(rules) <= 20000 && utf8.ValidString(rules), "invalid rules")
	require(strings.HasPrefix(conditionID, "0x") && isHash(conditionID[2:]), "invalid condition ID")
	require(isTokenID(yesTokenID) && isTokenID(noTokenID) && yesTokenID != noTokenID, "invalid outcome token order")
	require(isLabel(yesLabel) && isLabel(noLabel) && yesLabel != noLabel, "invalid outcome names")
	now := time.Now().Unix()
	require(tradingEndsAt > now, "trading must end in the future")
	require(tradingEndsAt <= maxInt64-AbandonAfter, "invalid trading end")
	checkQuote(yesPricePpm, noPricePpm)
	require(feePpm >= 0 && feePpm <= MaxFeePpm, "fee rate above the cap")
	require(oracle.IsValid(), "invalid oracle address")
	require(oracle != administrator && oracle != quoter && oracle != lister, "the oracle must be a separate account")
	require(treasury.IsValid(), "invalid treasury address")
	require(isTopic(topic), "invalid topic")
	m := Market{ID: id, Question: question, Rules: rules, RulesHash: BindingHash(question, rules), ConditionID: conditionID,
		YesTokenID: yesTokenID, NoTokenID: noTokenID, YesLabel: yesLabel, NoLabel: noLabel, Oracle: oracle, Treasury: treasury, Topic: topic, FeePpm: feePpm, CreatedAt: now,
		TradingEndsAt: tradingEndsAt, AbandonAt: tradingEndsAt + AbandonAfter,
		YesPricePpm: yesPricePpm, NoPricePpm: noPricePpm, QuoteVersion: 1, QuotedAt: now, State: StateOpen,
		MaxTradeMicroShares: defaultLimits.MaxTradeMicroShares, MaxHolderMicroShares: defaultLimits.MaxHolderMicroShares, MaxSideMicroShares: defaultLimits.MaxSideMicroShares}
	r := &marketRecord{market: m, positions: make(map[address]Position)}
	r.history = append(r.history, QuotePoint{At: now, YesPricePpm: yesPricePpm, NoPricePpm: noPricePpm, Version: 1})
	records[id] = r
	marketIDs = append(marketIDs, id)
	chain.Emit("MarketCreated", "market", id, "yesPricePpm", decimal(yesPricePpm), "noPricePpm", decimal(noPricePpm),
		"feePpm", decimal(feePpm), "tradingEndsAt", decimal(tradingEndsAt), "oracle", string(oracle), "treasury", string(treasury), "topic", topic,
		"yesLabel", yesLabel, "noLabel", noLabel)
}

// SetQuote publishes both prices while trading is open or paused. The quoter
// may sign it with a session key. expectedVersion refuses a quote made from a
// stale view. The same prices again only renew the quote's time, so the keeper
// can keep an unchanged quote from expiring without a new version.
func SetQuote(cur realm, id string, yesPricePpm, noPricePpm, expectedVersion int64) {
	assertUser(0, cur)
	assertNoSend()
	who := caller(0, cur)
	require(who == quoter || who == administrator, "quoter only")
	r := mustMarket(id)
	m := r.market
	require(m.State == StateOpen || m.State == StatePaused, "trading closed")
	now := time.Now().Unix()
	require(now < m.TradingEndsAt, "trading closed")
	require(expectedVersion == m.QuoteVersion, "quote version changed")
	checkQuote(yesPricePpm, noPricePpm)
	r.market.QuotedAt = now
	if yesPricePpm == m.YesPricePpm && noPricePpm == m.NoPricePpm {
		chain.Emit("QuoteRenewed", "market", id, "version", decimal(m.QuoteVersion))
		return
	}
	r.market.YesPricePpm, r.market.NoPricePpm = yesPricePpm, noPricePpm
	r.market.QuoteVersion = checkedAdd(m.QuoteVersion, 1)
	if len(r.history) >= maxHistory {
		r.history = append([]QuotePoint{}, r.history[1:]...)
	}
	r.history = append(r.history, QuotePoint{At: now, YesPricePpm: yesPricePpm, NoPricePpm: noPricePpm, Version: r.market.QuoteVersion})
	chain.Emit("QuoteUpdated", "market", id, "yesPricePpm", decimal(yesPricePpm), "noPricePpm", decimal(noPricePpm), "version", decimal(r.market.QuoteVersion))
}

// Pause stops new purchases in one market, or with id "" in every market. The
// quoter (also with a session key), the guardian and the administrator can
// pause; only the administrator resumes. Claims are never paused.
func Pause(cur realm, id string) {
	assertUser(0, cur)
	assertNoSend()
	who := caller(0, cur)
	require(who == quoter || who == guardian || who == administrator, "quoter, guardian or administrator only")
	if id == "" {
		require(!realmPaused, "already paused")
		realmPaused = true
	} else {
		r := mustMarket(id)
		require(r.market.State == StateOpen, "market is not open")
		r.market.State = StatePaused
	}
	chain.Emit("Paused", "market", id, "by", string(who))
}

// Resume reopens one paused market, or with id "" lifts the realm-wide pause.
func Resume(cur realm, id string) {
	assertOwnKey(0, cur)
	require(caller(0, cur) == administrator, "administrator only")
	if id == "" {
		require(realmPaused, "not paused")
		realmPaused = false
	} else {
		r := mustMarket(id)
		require(r.market.State == StatePaused, "market is not paused")
		r.market.State = StateOpen
	}
	chain.Emit("Resumed", "market", id)
}

// ----- Money in -----

// Fund adds reserve capital to one market. It backs that market's sales and
// returns to the market's treasury only after the market is final.
func Fund(cur realm, id string) {
	runtime.AssertOriginCall()
	assertUser(0, cur)
	r := mustMarket(id)
	require(r.market.State == StateOpen || r.market.State == StatePaused, "market funding closed")
	require(time.Now().Unix() < r.market.TradingEndsAt, "market funding closed")
	amount := singleSend()
	nextTotal := checkedAdd(totalHeldUgnot, amount)
	assertBankCoverage(0, cur, nextTotal)
	r.market.EscrowUgnot = checkedAdd(r.market.EscrowUgnot, amount)
	r.market.ReserveUgnot = checkedAdd(r.market.ReserveUgnot, amount)
	totalHeldUgnot = nextTotal
	chain.Emit("Funded", "market", id, "amountUgnot", decimal(amount))
}

// Buy creates a position after exact payment of cost plus fee, within the
// limits, and only while the market's escrow covers its larger side.
// expectedPricePpm is the price of the chosen outcome that the buyer reviewed.
// A buyer may sign with a session key: the position is always the account's.
func Buy(cur realm, id, outcome string, microShares, expectedPricePpm int64) {
	runtime.AssertOriginCall()
	assertUser(0, cur)
	r := mustMarket(id)
	m := r.market
	now := time.Now().Unix()
	require(!realmPaused && m.State != StatePaused, "trading paused")
	require(m.State == StateOpen && now < m.TradingEndsAt, "trading closed")
	require(now-m.QuotedAt <= quoteTTL, "the price expired")
	price := outcomePrice(m, outcome)
	require(expectedPricePpm == price, "price does not match review")
	require(microShares > 0 && microShares <= m.MaxTradeMicroShares, "above the trade limit")
	cost := quoteCost(microShares, price)
	fee := Fee(microShares, price, m.FeePpm)
	require(singleSend() == checkedAdd(cost, fee), "send the exact cost plus fee")

	owner := caller(0, cur)
	p, held := r.positions[owner]
	nextYes, nextNo := m.YesMicroShares, m.NoMicroShares
	if outcome == "Yes" {
		nextYes = checkedAdd(nextYes, microShares)
		p.YesMicroShares = checkedAdd(p.YesMicroShares, microShares)
	} else {
		nextNo = checkedAdd(nextNo, microShares)
		p.NoMicroShares = checkedAdd(p.NoMicroShares, microShares)
	}
	require(checkedAdd(p.YesMicroShares, p.NoMicroShares) <= m.MaxHolderMicroShares, "above the holder limit")
	require(maximum(nextYes, nextNo) <= m.MaxSideMicroShares, "above the market limit")
	nextEscrow := checkedAdd(m.EscrowUgnot, cost)
	require(maximum(nextYes, nextNo) <= nextEscrow, "insufficient market collateral")
	nextExposure := checkedAdd(openExposure-maximum(m.YesMicroShares, m.NoMicroShares), maximum(nextYes, nextNo))
	require(nextExposure <= maxExposure, "above the realm exposure limit")
	nextTotal := checkedAdd(totalHeldUgnot, checkedAdd(cost, fee))
	assertBankCoverage(0, cur, nextTotal)

	p.SpentUgnot = checkedAdd(p.SpentUgnot, cost)
	p.FeeUgnot = checkedAdd(p.FeeUgnot, fee)
	r.positions[owner] = p
	if !held {
		r.market.Holders++
	}
	r.market.YesMicroShares, r.market.NoMicroShares = nextYes, nextNo
	r.market.EscrowUgnot = nextEscrow
	r.market.FeesUgnot = checkedAdd(m.FeesUgnot, fee)
	r.market.CostUgnot = checkedAdd(m.CostUgnot, cost)
	r.market.FeesCollectedUgnot = checkedAdd(m.FeesCollectedUgnot, fee)
	r.market.VolumeUgnot = checkedAdd(m.VolumeUgnot, cost)
	r.market.Trades = checkedAdd(m.Trades, 1)
	openExposure = nextExposure
	totalHeldUgnot = nextTotal
	chain.Emit("Bought", "market", id, "buyer", string(owner), "outcome", outcome, "microShares", decimal(microShares),
		"pricePpm", decimal(price), "costUgnot", decimal(cost), "feeUgnot", decimal(fee), "version", decimal(m.QuoteVersion))
}

// ----- Resolution -----

// ProposeOutcome records the oracle's Yes, No or Void with the market's entire
// source binding and an evidence hash. Trading stops at once. After the
// dispute window anyone can make it final; within it the guardian can cancel.
// A Polymarket 50-50 result is proposed as Void.
func ProposeOutcome(cur realm, id, conditionID, rulesHash, yesTokenID, noTokenID, outcome, evidenceHash string) {
	assertOwnKey(0, cur)
	r := mustMarket(id)
	m := r.market
	require(caller(0, cur) == m.Oracle, "oracle only")
	require(m.State == StateOpen || m.State == StatePaused, "an outcome is already proposed or final")
	require(conditionID == m.ConditionID && rulesHash == m.RulesHash && yesTokenID == m.YesTokenID && noTokenID == m.NoTokenID, "source binding mismatch")
	require(outcome == "Yes" || outcome == "No" || outcome == "Void", "invalid outcome")
	require(isHash(evidenceHash), "invalid evidence hash")
	r.market.State = StateProposed
	r.market.Outcome = outcome
	r.market.EvidenceHash = evidenceHash
	r.market.ProposedAt = time.Now().Unix()
	chain.Emit("OutcomeProposed", "market", id, "outcome", outcome, "evidenceHash", evidenceHash, "finalFrom", decimal(r.market.ProposedAt+DisputeWindow))
}

// CancelProposal lets the guardian reject a proposed outcome within the
// dispute window. The market returns to paused; the oracle can propose again.
func CancelProposal(cur realm, id string) {
	assertOwnKey(0, cur)
	r := mustMarket(id)
	m := r.market
	require(caller(0, cur) == guardian, "guardian only")
	require(m.State == StateProposed, "no proposed outcome")
	require(time.Now().Unix() < m.ProposedAt+DisputeWindow, "the dispute window has passed")
	r.market.State = StatePaused
	r.market.Outcome, r.market.EvidenceHash, r.market.ProposedAt = "", "", 0
	chain.Emit("ProposalCancelled", "market", id, "outcome", m.Outcome)
}

// Finalize makes a proposed outcome final once the dispute window has passed.
// Anyone can call it.
func Finalize(cur realm, id string) {
	assertUser(0, cur)
	assertNoSend()
	r := mustMarket(id)
	require(r.market.State == StateProposed, "no proposed outcome")
	require(time.Now().Unix() >= r.market.ProposedAt+DisputeWindow, "the dispute window is still open")
	settle(r, r.market.Outcome)
	assertBankCoverage(0, cur, totalHeldUgnot)
}

// VoidAbandoned voids a market that is still unsettled AbandonAfter trading
// ended. Anyone can call it; every holder then takes back what they paid.
func VoidAbandoned(cur realm, id string) {
	assertUser(0, cur)
	assertNoSend()
	r := mustMarket(id)
	require(r.market.State == StateOpen || r.market.State == StatePaused, "an outcome is already proposed or final")
	require(time.Now().Unix() >= r.market.AbandonAt, "not abandoned yet")
	r.market.Outcome, r.market.EvidenceHash = "Void", ""
	settle(r, "Void")
	assertBankCoverage(0, cur, totalHeldUgnot)
}

func settle(r *marketRecord, outcome string) {
	m := r.market
	require(m.EscrowUgnot >= owedCollateral(m, outcome), "insufficient market collateral")
	r.market.State = StateFinal
	r.market.Outcome = outcome
	r.market.FinalizedAt = time.Now().Unix()
	openExposure -= maximum(m.YesMicroShares, m.NoMicroShares)
	chain.Emit("Finalized", "market", m.ID, "outcome", outcome, "evidenceHash", r.market.EvidenceHash)
}

// ----- Money out -----

// Claim settles the caller's position in a final market and deletes it. On Yes
// or No each winning micro-share pays one ugnot; on Void the holder gets back
// the cost and the fee they paid. A losing position closes with zero.
func Claim(cur realm, id string) int64 {
	assertUser(0, cur)
	assertNoSend()
	r := mustMarket(id)
	m := r.market
	require(m.State == StateFinal, "outcome is not final")
	owner := caller(0, cur)
	p, held := r.positions[owner]
	require(held, "no position")
	var fromEscrow, fromFees int64
	switch m.Outcome {
	case "Yes":
		fromEscrow = p.YesMicroShares
	case "No":
		fromEscrow = p.NoMicroShares
	default:
		fromEscrow, fromFees = p.SpentUgnot, p.FeeUgnot
	}
	require(fromEscrow <= m.EscrowUgnot && fromFees <= m.FeesUgnot, "insufficient market collateral")
	payout := fromEscrow + fromFees
	assertBankCoverage(0, cur, totalHeldUgnot)
	delete(r.positions, owner)
	r.market.Holders--
	r.market.EscrowUgnot -= fromEscrow
	r.market.FeesUgnot -= fromFees
	if m.Outcome == "Void" {
		r.market.RefundedCostUgnot = checkedAdd(m.RefundedCostUgnot, fromEscrow)
		r.market.RefundedFeesUgnot = checkedAdd(m.RefundedFeesUgnot, fromFees)
	} else {
		r.market.PaidUgnot = checkedAdd(m.PaidUgnot, fromEscrow)
	}
	totalHeldUgnot -= payout
	if payout > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), owner, chain.Coins{{Denom: "ugnot", Amount: payout}})
	}
	chain.Emit("Claimed", "market", id, "owner", string(owner), "outcome", m.Outcome, "payoutUgnot", decimal(payout),
		"yesMicroShares", decimal(p.YesMicroShares), "noMicroShares", decimal(p.NoMicroShares), "spentUgnot", decimal(p.SpentUgnot), "feeUgnot", decimal(p.FeeUgnot))
	return payout
}

// WithdrawSurplus sends what a final market no longer owes anyone to its fixed
// treasury: the escrow above unclaimed payouts or refunds, and on Yes or No the
// fees. Anyone can call it; the destination was fixed at listing.
func WithdrawSurplus(cur realm, id string) int64 {
	assertUser(0, cur)
	assertNoSend()
	r := mustMarket(id)
	m := r.market
	require(m.State == StateFinal, "outcome is not final")
	collateral, fees := Surplus(id)
	require(collateral >= 0 && fees >= 0, "insufficient market collateral")
	amount := checkedAdd(collateral, fees)
	require(amount > 0, "no surplus")
	assertBankCoverage(0, cur, totalHeldUgnot)
	r.market.EscrowUgnot -= collateral
	r.market.FeesUgnot -= fees
	r.market.WithdrawnUgnot = checkedAdd(m.WithdrawnUgnot, amount)
	totalHeldUgnot -= amount
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), m.Treasury, chain.Coins{{Denom: "ugnot", Amount: amount}})
	chain.Emit("SurplusWithdrawn", "market", id, "treasury", string(m.Treasury), "collateralUgnot", decimal(collateral), "feesUgnot", decimal(fees))
	return amount
}

// Surplus returns what WithdrawSurplus would send now: collateral and fees.
// It is zero for a market that is not final.
func Surplus(id string) (collateralUgnot, feesUgnot int64) {
	m := mustMarket(id).market
	if m.State != StateFinal {
		return 0, 0
	}
	return m.EscrowUgnot - owedCollateral(m, m.Outcome), m.FeesUgnot - owedFees(m, m.Outcome)
}

// owedCollateral is what the escrow must still pay holders for an outcome.
func owedCollateral(m Market, outcome string) int64 {
	switch outcome {
	case "Yes":
		return m.YesMicroShares - m.PaidUgnot
	case "No":
		return m.NoMicroShares - m.PaidUgnot
	}
	return m.CostUgnot - m.RefundedCostUgnot
}

// owedFees is what the fees must still return to holders: all of them on Void.
func owedFees(m Market, outcome string) int64 {
	if outcome == "Void" {
		return m.FeesCollectedUgnot - m.RefundedFeesUgnot
	}
	return 0
}

// ----- Reads -----

func GetMarket(id string) Market                    { return mustMarket(id).market }
func GetPosition(id string, owner address) Position { return mustMarket(id).positions[owner] }
func IsPaused() bool                                { return realmPaused }
func QuoteTTL() int64                               { return quoteTTL }

// Quote returns the exact cost and fee for buying microShares of an outcome at
// the current price. A buyer sends cost + fee.
func Quote(id, outcome string, microShares int64) (costUgnot, feeUgnot int64) {
	m := mustMarket(id).market
	price := outcomePrice(m, outcome)
	return quoteCost(microShares, price), Fee(microShares, price, m.FeePpm)
}

// Fee is the service fee in ugnot for microShares at pricePpm and rate feePpm:
// θ × shares × price × (1 − price) GNOT, rounded up to the ugnot. It is computed
// exactly as ceil(microShares × feePpm × price × (10^6 − price) / 10^18).
func Fee(microShares, pricePpm, feePpm int64) int64 {
	require(microShares > 0 && pricePpm > 0 && pricePpm < scale, "invalid quote amount")
	require(feePpm >= 0 && feePpm <= MaxFeePpm, "fee rate above the cap")
	if feePpm == 0 {
		return 0
	}
	// pricePpm × (10^6 − pricePpm) ≤ 2.5 × 10^11; times feePpm ≤ 1.75 × 10^16.
	rate := uint64(pricePpm) * uint64(scale-pricePpm) * uint64(feePpm)
	hi, lo := bits.Mul64(uint64(microShares), rate)
	const denominator uint64 = 1000000000000000000
	quotient, remainder := bits.Div64(hi, lo, denominator) // hi < denominator for any int64 microShares
	if remainder != 0 {
		quotient++
	}
	require(quotient <= uint64(maxInt64), "fee overflow")
	return int64(quotient)
}

func ListMarkets() []Market {
	result := make([]Market, len(marketIDs))
	for i, id := range marketIDs {
		result[i] = records[id].market
	}
	return result
}

// QuoteHistory returns a detached copy of the published quotes.
func QuoteHistory(id string) []QuotePoint {
	points := mustMarket(id).history
	result := make([]QuotePoint, len(points))
	copy(result, points)
	return result
}

// Hash UTF-8 length-framed text, shared exactly with the backend source binding.
func BindingHash(question, rules string) string {
	framed := strconv.FormatInt(int64(len(question)), 10) + ":" + question + strconv.FormatInt(int64(len(rules)), 10) + ":" + rules
	sum := sha256.Sum256([]byte(framed))
	return hex.EncodeToString(sum[:])
}

// ----- Checks -----

func caller(_ int, context realm) address { return context.Previous().Address() }

func assertUser(_ int, context realm) {
	require(context.IsCurrent(), "invalid current realm")
	require(context.Previous().IsUserCall(), "direct user call required")
}

// assertOwnKey also refuses a session key: listing, settings, roles, resuming
// and resolution need the account's own signature. Session keys may only
// quote, pause, buy and claim.
func assertOwnKey(_ int, context realm) {
	assertUser(0, context)
	assertNoSend()
	_, _, _, isSession := runtime.GetSessionInfo()
	require(!isSession, "this action needs the account's own key, not a session key")
}

func assertNoSend() { require(len(unsafe.OriginSend()) == 0, "this action does not accept coins") }
func singleSend() int64 {
	sent := unsafe.OriginSend()
	require(len(sent) == 1 && sent[0].Denom == "ugnot" && sent[0].Amount > 0, "send positive ugnot only")
	return sent[0].Amount
}
func assertBankCoverage(_ int, context realm, required int64) {
	require(banker.NewReadonlyBanker().GetCoin(context.Address(), "ugnot") >= required, "payment not credited to realm")
}
func mustMarket(id string) *marketRecord {
	r := records[id]
	require(r != nil, "unknown market")
	return r
}

// checkQuote keeps each side inside the band and the pair at or above one
// GNOT plus the minimum spread, so buying both sides can never be a sure gain.
func checkQuote(yesPricePpm, noPricePpm int64) {
	require(yesPricePpm >= MinPricePpm && yesPricePpm <= MaxPricePpm && noPricePpm >= MinPricePpm && noPricePpm <= MaxPricePpm, "price outside 0.03 to 0.97")
	require(yesPricePpm+noPricePpm >= scale+minSpreadPpm, "Yes and No must add up to at least 1")
}
func outcomePrice(m Market, outcome string) int64 {
	require(outcome == "Yes" || outcome == "No", "invalid outcome")
	if outcome == "Yes" {
		return m.YesPricePpm
	}
	return m.NoPricePpm
}
func quoteCost(microShares, price int64) int64 {
	require(microShares > 0 && price > 0 && price < scale, "invalid quote amount")
	require(microShares <= maxInt64/price, "quote overflow")
	product := microShares * price
	cost := product / scale
	if product%scale != 0 {
		cost = checkedAdd(cost, 1)
	}
	return cost
}
func checkedAdd(a, b int64) int64 {
	require(a >= 0 && b >= 0 && a <= maxInt64-b, "amount overflow")
	return a + b
}
func maximum(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
func require(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func isHash(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// isSlug keeps market IDs safe in paths and links: lowercase letters, digits
// and single hyphens.
func isSlug(s string) bool {
	for i, c := range s {
		ok := c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' && i > 0 && i < len(s)-1 && s[i-1] != '-'
		if !ok {
			return false
		}
	}
	return true
}

// isTopic allows an empty topic or up to 24 letters and spaces, such as "Politics".
func isTopic(s string) bool {
	if len(s) > 24 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == ' ') {
			return false
		}
	}
	return true
}

// isLabel allows an outcome name of 1 to 48 bytes of printable UTF-8 without
// surrounding spaces or markup characters, such as "Yes" or "Los Angeles Dodgers".
func isLabel(s string) bool {
	if s == "" || len(s) > 48 || !utf8.ValidString(s) || strings.TrimSpace(s) != s {
		return false
	}
	for _, c := range s {
		if c < 0x20 || c == 0x7f || c >= 0x80 && c < 0xa0 || strings.ContainsRune("<>[]*_`|\\#", c) {
			return false
		}
	}
	return true
}
func isTokenID(s string) bool {
	if len(s) == 0 || len(s) > 78 || len(s) > 1 && s[0] == '0' {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
func decimal(value int64) string { return strconv.FormatInt(value, 10) }
