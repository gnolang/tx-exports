// Package markets keeps collateral, positions and winning payouts on Gno.
// It does not discover external outcomes: each market trusts its pinned oracle.
package markets

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const scale int64 = 1000000
const maxInt64 int64 = 9223372036854775807

// All amounts are integer ugnot. One million micro-shares is one share;
// a winning micro-share pays one ugnot (one whole share pays one GNOT).
type Market struct {
	ID             string  `json:"id"`
	Question       string  `json:"question"`
	Rules          string  `json:"rules"`
	RulesHash      string  `json:"rulesHash"`
	ConditionID    string  `json:"conditionId"`
	YesTokenID     string  `json:"yesTokenId"`
	NoTokenID      string  `json:"noTokenId"`
	ClosesAt       int64   `json:"closesAt"`
	YesPricePpm    int64   `json:"yesPricePpm"`
	Oracle         address `json:"oracle"`
	EscrowUgnot    int64   `json:"escrowUgnot"`
	YesMicroShares int64   `json:"yesMicroShares"`
	NoMicroShares  int64   `json:"noMicroShares"`
	Finalized      bool    `json:"finalized"`
	Winner         string  `json:"winner"`
	EvidenceHash   string  `json:"evidenceHash"`
	FinalizedAt    int64   `json:"finalizedAt"`
	PaidUgnot      int64   `json:"paidUgnot"`
	QuoteVersion   int64   `json:"quoteVersion"`
	CreatedAt      int64   `json:"createdAt"`
	VolumeUgnot    int64   `json:"volumeUgnot"`
	Trades         int64   `json:"trades"`
}

// QuotePoint records one published fixed quote. The history contains the
// creation quote and every later administrator requote, in block-time order.
type QuotePoint struct {
	At          int64 `json:"at"`
	YesPricePpm int64 `json:"yesPricePpm"`
	Version     int64 `json:"version"`
}

type Position struct {
	YesMicroShares int64 `json:"yesMicroShares"`
	NoMicroShares  int64 `json:"noMicroShares"`
	SpentUgnot     int64 `json:"spentUgnot"`
	Claimed        bool  `json:"claimed"`
	PaidUgnot      int64 `json:"paidUgnot"`
}

type marketRecord struct {
	market    Market
	positions map[address]Position
	owners    []address
	history   []QuotePoint
}

const maxHistory = 240

// OriginCaller is used only at package initialization, to capture the deployer.
// Entry-point authorization always uses the live immediate caller.
var administrator = unsafe.OriginCaller()
var pendingAdministrator address
var records = make(map[string]*marketRecord)
var marketIDs []string
var totalEscrowUgnot int64

func Administrator() address        { return administrator }
func PendingAdministrator() address { return pendingAdministrator }

// ProposeAdministrator starts a two-step handover. The proposed address must
// accept from its own direct user call, so a mistyped address cannot take over.
// Each market keeps the oracle it was created with.
func ProposeAdministrator(cur realm, next address) {
	assertUser(0, cur)
	assertNoSend()
	require(cur.Previous().Address() == administrator, "administrator only")
	require(next.IsValid() && next != administrator, "invalid administrator")
	pendingAdministrator = next
	chain.Emit("AdministratorProposed", "next", string(next))
}

// AcceptAdministrator completes the handover started by ProposeAdministrator.
func AcceptAdministrator(cur realm) {
	assertUser(0, cur)
	assertNoSend()
	caller := cur.Previous().Address()
	require(pendingAdministrator != "" && caller == pendingAdministrator, "pending administrator only")
	administrator = caller
	pendingAdministrator = ""
	chain.Emit("AdministratorAccepted", "administrator", string(caller))
}

// CreateMarket freezes every field used to match an external result.
// There are deliberately no question/rules/source/oracle/price update functions.
func CreateMarket(cur realm, id, question, rules, conditionID, yesTokenID, noTokenID string, closesAt, yesPricePpm int64, oracle address) {
	assertUser(0, cur)
	assertNoSend()
	require(cur.Previous().Address() == administrator, "administrator only")
	require(records[id] == nil, "market already exists")
	require(id != "" && len(id) <= 64 && utf8.ValidString(id), "invalid market ID")
	require(question != "" && len(question) <= 1024 && utf8.ValidString(question), "invalid question")
	require(rules != "" && len(rules) <= 20000 && utf8.ValidString(rules), "invalid rules")
	require(strings.HasPrefix(conditionID, "0x") && isHash(conditionID[2:]), "invalid condition ID")
	require(isTokenID(yesTokenID) && isTokenID(noTokenID) && yesTokenID != noTokenID, "invalid outcome token order")
	require(closesAt > time.Now().Unix(), "closing time must be in the future")
	require(yesPricePpm > 0 && yesPricePpm < scale, "invalid fixed price")
	require(oracle.IsValid(), "invalid oracle address")
	now := time.Now().Unix()
	m := Market{ID: id, Question: question, Rules: rules, RulesHash: BindingHash(question, rules), ConditionID: conditionID, YesTokenID: yesTokenID, NoTokenID: noTokenID, ClosesAt: closesAt, YesPricePpm: yesPricePpm, Oracle: oracle, QuoteVersion: 1, CreatedAt: now}
	r := &marketRecord{market: m, positions: make(map[address]Position)}
	r.history = append(r.history, QuotePoint{At: now, YesPricePpm: yesPricePpm, Version: 1})
	records[id] = r
	marketIDs = append(marketIDs, id)
	chain.Emit("MarketCreated", "market", id, "yesPricePpm", decimal(yesPricePpm), "closesAt", decimal(closesAt))
}

// SetQuote publishes a new fixed quote while trading is open. expectedVersion
// prevents an operator from overwriting a quote it has not seen. Every Buy
// still checks the exact price its buyer reviewed.
func SetQuote(cur realm, id string, yesPricePpm, expectedVersion int64) {
	assertUser(0, cur)
	assertNoSend()
	require(cur.Previous().Address() == administrator, "administrator only")
	r := mustMarket(id)
	require(!r.market.Finalized && time.Now().Unix() < r.market.ClosesAt, "trading closed")
	require(expectedVersion == r.market.QuoteVersion, "quote version changed")
	require(yesPricePpm > 0 && yesPricePpm < scale, "invalid fixed price")
	require(yesPricePpm != r.market.YesPricePpm, "quote unchanged")
	r.market.YesPricePpm = yesPricePpm
	r.market.QuoteVersion = checkedAdd(r.market.QuoteVersion, 1)
	if len(r.history) >= maxHistory {
		r.history = append([]QuotePoint{}, r.history[1:]...)
	}
	r.history = append(r.history, QuotePoint{At: time.Now().Unix(), YesPricePpm: yesPricePpm, Version: r.market.QuoteVersion})
	chain.Emit("QuoteUpdated", "market", id, "yesPricePpm", decimal(yesPricePpm), "version", decimal(r.market.QuoteVersion))
}

// Fund adds non-refundable reserve capital, allocated solely to this market.
// No withdrawal or banker capability is exposed, even to the administrator.
func Fund(cur realm, id string) {
	runtime.AssertOriginCall()
	assertUser(0, cur)
	r := mustMarket(id)
	require(!r.market.Finalized && time.Now().Unix() < r.market.ClosesAt, "market funding closed")
	amount := singleSend()
	nextEscrow := checkedAdd(r.market.EscrowUgnot, amount)
	nextTotal := checkedAdd(totalEscrowUgnot, amount)
	assertBankCoverage(0, cur, nextTotal)
	r.market.EscrowUgnot = nextEscrow
	totalEscrowUgnot = nextTotal
	chain.Emit("Funded", "market", id, "amountUgnot", decimal(amount))
}

// Buy creates positions only after exact payment and full market-specific
// collateral coverage. expectedPricePpm is the selected outcome's captured price.
func Buy(cur realm, id, outcome string, microShares, expectedPricePpm int64) {
	runtime.AssertOriginCall()
	assertUser(0, cur)
	r := mustMarket(id)
	m := r.market
	require(!m.Finalized && time.Now().Unix() < m.ClosesAt, "trading closed")
	price := outcomePrice(m, outcome)
	require(expectedPricePpm == price, "price does not match review")
	cost := quoteCost(microShares, price)
	require(singleSend() == cost, "send the exact quoted ugnot amount")
	nextYes, nextNo := m.YesMicroShares, m.NoMicroShares
	if outcome == "Yes" {
		nextYes = checkedAdd(nextYes, microShares)
	} else {
		nextNo = checkedAdd(nextNo, microShares)
	}
	nextEscrow := checkedAdd(m.EscrowUgnot, cost)
	require(maximum(nextYes, nextNo) <= nextEscrow, "insufficient market collateral")
	nextTotal := checkedAdd(totalEscrowUgnot, cost)
	assertBankCoverage(0, cur, nextTotal)
	owner := cur.Previous().Address()
	p, held := r.positions[owner]
	require(!p.Claimed, "position already claimed")
	nextVolume := checkedAdd(m.VolumeUgnot, cost)
	nextTrades := checkedAdd(m.Trades, 1)
	if outcome == "Yes" {
		p.YesMicroShares = checkedAdd(p.YesMicroShares, microShares)
	} else {
		p.NoMicroShares = checkedAdd(p.NoMicroShares, microShares)
	}
	p.SpentUgnot = checkedAdd(p.SpentUgnot, cost)
	r.positions[owner] = p
	if !held {
		r.owners = append(r.owners, owner)
	}
	r.market.YesMicroShares, r.market.NoMicroShares = nextYes, nextNo
	r.market.EscrowUgnot = nextEscrow
	r.market.VolumeUgnot, r.market.Trades = nextVolume, nextTrades
	totalEscrowUgnot = nextTotal
	chain.Emit("Bought", "market", id, "buyer", string(owner), "outcome", outcome, "microShares", decimal(microShares), "costUgnot", decimal(cost), "pricePpm", decimal(price))
}

// FinalizeByOracle accepts only the pinned oracle and the entire immutable
// source binding. EvidenceHash commits to an externally verified final record.
// Neither a price threshold nor an unverified API response can call this by itself.
// A source can resolve before the planned closing date. Oracle finalization
// therefore closes trading immediately, without waiting for that deadline.
func FinalizeByOracle(cur realm, id, conditionID, rulesHash, yesTokenID, noTokenID, winner, evidenceHash string) {
	assertUser(0, cur)
	assertNoSend()
	r := mustMarket(id)
	m := r.market
	require(cur.Previous().Address() == m.Oracle, "oracle only")
	require(!m.Finalized, "outcome already final")
	require(conditionID == m.ConditionID && rulesHash == m.RulesHash && yesTokenID == m.YesTokenID && noTokenID == m.NoTokenID, "source binding mismatch")
	require(winner == "Yes" || winner == "No", "invalid final outcome")
	require(isHash(evidenceHash), "invalid evidence hash")
	require(maximum(m.YesMicroShares, m.NoMicroShares) <= m.EscrowUgnot, "insufficient market collateral")
	assertBankCoverage(0, cur, totalEscrowUgnot)
	r.market.Finalized = true
	r.market.Winner = winner
	r.market.EvidenceHash = evidenceHash
	r.market.FinalizedAt = time.Now().Unix()
	chain.Emit("Finalized", "market", id, "winner", winner, "evidenceHash", evidenceHash)
}

// Claim pays only the immediate caller's winning shares. Repeated calls abort;
// a losing position can be closed once with zero payout. A panic rolls back both
// state and bank effects in the Gno transaction.
func Claim(cur realm, id string) int64 {
	assertUser(0, cur)
	assertNoSend()
	r := mustMarket(id)
	m := r.market
	require(m.Finalized, "outcome is not final")
	owner := cur.Previous().Address()
	p := r.positions[owner]
	require(p.YesMicroShares > 0 || p.NoMicroShares > 0, "no position")
	require(!p.Claimed, "position already claimed")
	payout := p.YesMicroShares
	if m.Winner == "No" {
		payout = p.NoMicroShares
	}
	require(payout <= m.EscrowUgnot && payout <= totalEscrowUgnot, "insufficient market collateral")
	assertBankCoverage(0, cur, totalEscrowUgnot)
	paid := checkedAdd(m.PaidUgnot, payout)
	p.Claimed, p.PaidUgnot = true, payout
	r.positions[owner] = p
	r.market.EscrowUgnot -= payout
	r.market.PaidUgnot = paid
	totalEscrowUgnot -= payout
	if payout > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), owner, chain.Coins{{Denom: "ugnot", Amount: payout}})
	}
	chain.Emit("Claimed", "market", id, "owner", string(owner), "payoutUgnot", decimal(payout))
	return payout
}

func GetMarket(id string) Market                    { return mustMarket(id).market }
func GetPosition(id string, owner address) Position { return mustMarket(id).positions[owner] }
func Quote(id, outcome string, microShares int64) int64 {
	return quoteCost(microShares, outcomePrice(mustMarket(id).market, outcome))
}
func ListMarkets() []Market {
	result := make([]Market, len(marketIDs))
	for i, id := range marketIDs {
		result[i] = records[id].market
	}
	return result
}

// Gno 1.5.0 does not include encoding/json. These read-only projections use
// explicit fields and JSON string escaping, without an external package.
func MarketJSON(id string) string {
	m := GetMarket(id)
	return `{"id":` + jsonString(m.ID) + `,"question":` + jsonString(m.Question) + `,"rules":` + jsonString(m.Rules) +
		`,"rulesHash":` + jsonString(m.RulesHash) + `,"conditionId":` + jsonString(m.ConditionID) +
		`,"yesTokenId":` + jsonString(m.YesTokenID) + `,"noTokenId":` + jsonString(m.NoTokenID) +
		`,"closesAt":` + decimal(m.ClosesAt) + `,"yesPricePpm":` + decimal(m.YesPricePpm) + `,"oracle":` + jsonString(string(m.Oracle)) +
		`,"escrowUgnot":` + jsonString(decimal(m.EscrowUgnot)) + `,"yesMicroShares":` + jsonString(decimal(m.YesMicroShares)) + `,"noMicroShares":` + jsonString(decimal(m.NoMicroShares)) +
		`,"finalized":` + strconv.FormatBool(m.Finalized) + `,"winner":` + jsonString(m.Winner) + `,"evidenceHash":` + jsonString(m.EvidenceHash) +
		`,"finalizedAt":` + decimal(m.FinalizedAt) + `,"paidUgnot":` + jsonString(decimal(m.PaidUgnot)) +
		`,"quoteVersion":` + decimal(m.QuoteVersion) + `,"createdAt":` + decimal(m.CreatedAt) +
		`,"volumeUgnot":` + jsonString(decimal(m.VolumeUgnot)) + `,"trades":` + decimal(m.Trades) +
		`,"holders":` + strconv.Itoa(len(mustMarket(id).owners)) +
		`,"history":` + historyJSON(mustMarket(id).history) + `}`
}

// MarketsJSON returns every market in creation order as one JSON array.
func MarketsJSON() string {
	var result strings.Builder
	result.WriteByte('[')
	for i, id := range marketIDs {
		if i > 0 {
			result.WriteByte(',')
		}
		result.WriteString(MarketJSON(id))
	}
	result.WriteByte(']')
	return result.String()
}

// PositionsJSON returns the owner's positions across all markets, in market
// creation order. Markets where the owner never bought are omitted.
func PositionsJSON(owner address) string {
	var result strings.Builder
	result.WriteByte('[')
	first := true
	for _, id := range marketIDs {
		if _, ok := records[id].positions[owner]; !ok {
			continue
		}
		if !first {
			result.WriteByte(',')
		}
		first = false
		result.WriteString(`{"marketId":` + jsonString(id) + `,"position":` + PositionJSON(id, owner) + `}`)
	}
	result.WriteByte(']')
	return result.String()
}

func historyJSON(points []QuotePoint) string {
	var result strings.Builder
	result.WriteByte('[')
	for i, point := range points {
		if i > 0 {
			result.WriteByte(',')
		}
		result.WriteString(`{"at":` + decimal(point.At) + `,"yesPricePpm":` + decimal(point.YesPricePpm) + `,"version":` + decimal(point.Version) + `}`)
	}
	result.WriteByte(']')
	return result.String()
}

// QuoteHistory returns a detached copy of the published quotes.
func QuoteHistory(id string) []QuotePoint {
	points := mustMarket(id).history
	result := make([]QuotePoint, len(points))
	copy(result, points)
	return result
}

// ppmPrice formats an integer in millionths with six fixed decimals.
func ppmPrice(value int64) string {
	whole := value / scale
	fraction := strconv.FormatInt(value%scale, 10)
	for len(fraction) < 6 {
		fraction = "0" + fraction
	}
	return strconv.FormatInt(whole, 10) + "." + fraction
}
func PositionJSON(id string, owner address) string {
	p := GetPosition(id, owner)
	return `{"yesMicroShares":` + jsonString(decimal(p.YesMicroShares)) + `,"noMicroShares":` + jsonString(decimal(p.NoMicroShares)) +
		`,"spentUgnot":` + jsonString(decimal(p.SpentUgnot)) + `,"claimed":` + strconv.FormatBool(p.Claimed) + `,"paidUgnot":` + jsonString(decimal(p.PaidUgnot)) + `}`
}
func decimal(value int64) string { return strconv.FormatInt(value, 10) }
func jsonString(value string) string {
	var result strings.Builder
	result.WriteByte('"')
	for _, character := range value {
		switch character {
		case '"', '\\':
			result.WriteByte('\\')
			result.WriteRune(character)
		case '\b':
			result.WriteString(`\b`)
		case '\f':
			result.WriteString(`\f`)
		case '\n':
			result.WriteString(`\n`)
		case '\r':
			result.WriteString(`\r`)
		case '\t':
			result.WriteString(`\t`)
		default:
			if character < 32 {
				const digits = "0123456789abcdef"
				result.WriteString(`\u00`)
				result.WriteByte(digits[byte(character)/16])
				result.WriteByte(digits[byte(character)%16])
			} else {
				result.WriteRune(character)
			}
		}
	}
	result.WriteByte('"')
	return result.String()
}

// Hash UTF-8 length-framed text, shared exactly with the backend source binding.
func BindingHash(question, rules string) string {
	framed := strconv.FormatInt(int64(len(question)), 10) + ":" + question + strconv.FormatInt(int64(len(rules)), 10) + ":" + rules
	sum := sha256.Sum256([]byte(framed))
	return hex.EncodeToString(sum[:])
}

func assertUser(_ int, context realm) {
	require(context.IsCurrent(), "invalid current realm")
	require(context.Previous().IsUserCall(), "direct user call required")
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
func outcomePrice(m Market, outcome string) int64 {
	require(outcome == "Yes" || outcome == "No", "invalid outcome")
	if outcome == "Yes" {
		return m.YesPricePpm
	}
	return scale - m.YesPricePpm
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
