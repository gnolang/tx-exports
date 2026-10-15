package markets

import (
	"strconv"
	"strings"
)

// Gno 1.5.0 has no encoding/json. These read-only projections write explicit
// fields with JSON string escaping. Amounts in ugnot and micro-shares are
// strings, so JavaScript never rounds them; prices, times and counts are numbers.

// MarketJSON returns one market with its quote history.
func MarketJSON(id string) string {
	r := mustMarket(id)
	m := r.market
	var out strings.Builder
	out.WriteString(`{"id":` + jsonString(m.ID) + `,"question":` + jsonString(m.Question) + `,"rules":` + jsonString(m.Rules))
	out.WriteString(`,"rulesHash":` + jsonString(m.RulesHash) + `,"conditionId":` + jsonString(m.ConditionID))
	out.WriteString(`,"yesTokenId":` + jsonString(m.YesTokenID) + `,"noTokenId":` + jsonString(m.NoTokenID))
	out.WriteString(`,"yesLabel":` + jsonString(m.YesLabel) + `,"noLabel":` + jsonString(m.NoLabel))
	out.WriteString(`,"oracle":` + jsonString(string(m.Oracle)) + `,"treasury":` + jsonString(string(m.Treasury)) + `,"topic":` + jsonString(m.Topic))
	out.WriteString(`,"feePpm":` + decimal(m.FeePpm) + `,"createdAt":` + decimal(m.CreatedAt))
	out.WriteString(`,"tradingEndsAt":` + decimal(m.TradingEndsAt) + `,"abandonAt":` + decimal(m.AbandonAt))
	out.WriteString(`,"yesPricePpm":` + decimal(m.YesPricePpm) + `,"noPricePpm":` + decimal(m.NoPricePpm))
	out.WriteString(`,"quoteVersion":` + decimal(m.QuoteVersion) + `,"quotedAt":` + decimal(m.QuotedAt))
	out.WriteString(`,"state":` + jsonString(m.State) + `,"outcome":` + jsonString(m.Outcome) + `,"evidenceHash":` + jsonString(m.EvidenceHash))
	out.WriteString(`,"proposedAt":` + decimal(m.ProposedAt) + `,"finalizedAt":` + decimal(m.FinalizedAt))
	amounts := []struct {
		key   string
		value int64
	}{
		{"escrowUgnot", m.EscrowUgnot}, {"feesUgnot", m.FeesUgnot}, {"reserveUgnot", m.ReserveUgnot}, {"costUgnot", m.CostUgnot},
		{"feesCollectedUgnot", m.FeesCollectedUgnot}, {"yesMicroShares", m.YesMicroShares}, {"noMicroShares", m.NoMicroShares},
		{"paidUgnot", m.PaidUgnot}, {"refundedCostUgnot", m.RefundedCostUgnot}, {"refundedFeesUgnot", m.RefundedFeesUgnot},
		{"withdrawnUgnot", m.WithdrawnUgnot}, {"maxTradeMicroShares", m.MaxTradeMicroShares},
		{"maxHolderMicroShares", m.MaxHolderMicroShares}, {"maxSideMicroShares", m.MaxSideMicroShares}, {"volumeUgnot", m.VolumeUgnot},
	}
	for _, a := range amounts {
		out.WriteString(`,"` + a.key + `":` + jsonString(decimal(a.value)))
	}
	out.WriteString(`,"holders":` + decimal(m.Holders) + `,"trades":` + decimal(m.Trades))
	out.WriteString(`,"history":` + historyJSON(r.history) + `}`)
	return out.String()
}

// MarketsJSON returns every market in creation order as one JSON array.
func MarketsJSON() string {
	var out strings.Builder
	out.WriteByte('[')
	for i, id := range marketIDs {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(MarketJSON(id))
	}
	out.WriteByte(']')
	return out.String()
}

// PositionJSON returns one open position; an empty one if the owner holds
// nothing there or has claimed.
func PositionJSON(id string, owner address) string {
	p := GetPosition(id, owner)
	return `{"yesMicroShares":` + jsonString(decimal(p.YesMicroShares)) + `,"noMicroShares":` + jsonString(decimal(p.NoMicroShares)) +
		`,"spentUgnot":` + jsonString(decimal(p.SpentUgnot)) + `,"feeUgnot":` + jsonString(decimal(p.FeeUgnot)) + `}`
}

// PositionsJSON returns the owner's open positions in market creation order.
// Claimed positions are gone; their record is in the Claimed events.
func PositionsJSON(owner address) string {
	var out strings.Builder
	out.WriteByte('[')
	first := true
	for _, id := range marketIDs {
		if _, ok := records[id].positions[owner]; !ok {
			continue
		}
		if !first {
			out.WriteByte(',')
		}
		first = false
		out.WriteString(`{"marketId":` + jsonString(id) + `,"position":` + PositionJSON(id, owner) + `}`)
	}
	out.WriteByte(']')
	return out.String()
}

// RealmJSON returns the roles, settings, limits and totals.
func RealmJSON() string {
	return `{"administrator":` + jsonString(string(administrator)) + `,"pendingAdministrator":` + jsonString(string(pendingAdministrator)) +
		`,"quoter":` + jsonString(string(quoter)) + `,"pendingQuoter":` + jsonString(string(pendingQuoter)) +
		`,"guardian":` + jsonString(string(guardian)) + `,"pendingGuardian":` + jsonString(string(pendingGuardian)) +
		`,"lister":` + jsonString(string(lister)) + `,"pendingLister":` + jsonString(string(pendingLister)) +
		`,"listingTerms":{"oracle":` + jsonString(string(listingOracle)) + `,"treasury":` + jsonString(string(listingTreasury)) + `,"feePpm":` + decimal(listingFeePpm) + `}` +
		`,"paused":` + strconv.FormatBool(realmPaused) + `,"quoteTtl":` + decimal(quoteTTL) + `,"minSpreadPpm":` + decimal(minSpreadPpm) +
		`,"maxExposureMicroShares":` + jsonString(decimal(maxExposure)) + `,"openExposureMicroShares":` + jsonString(decimal(openExposure)) +
		`,"heldUgnot":` + jsonString(decimal(totalHeldUgnot)) +
		`,"defaultLimits":{"maxTradeMicroShares":` + jsonString(decimal(defaultLimits.MaxTradeMicroShares)) +
		`,"maxHolderMicroShares":` + jsonString(decimal(defaultLimits.MaxHolderMicroShares)) +
		`,"maxSideMicroShares":` + jsonString(decimal(defaultLimits.MaxSideMicroShares)) + `}` +
		`,"maxFeePpm":` + decimal(MaxFeePpm) + `,"minPricePpm":` + decimal(MinPricePpm) + `,"maxPricePpm":` + decimal(MaxPricePpm) +
		`,"disputeWindow":` + decimal(DisputeWindow) + `,"abandonAfter":` + decimal(AbandonAfter) + `,"markets":` + strconv.Itoa(len(marketIDs)) + `}`
}

func historyJSON(points []QuotePoint) string {
	var out strings.Builder
	out.WriteByte('[')
	for i, point := range points {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteString(`{"at":` + decimal(point.At) + `,"yesPricePpm":` + decimal(point.YesPricePpm) + `,"noPricePpm":` + decimal(point.NoPricePpm) + `,"version":` + decimal(point.Version) + `}`)
	}
	out.WriteByte(']')
	return out.String()
}

func jsonString(value string) string {
	var out strings.Builder
	out.WriteByte('"')
	for _, character := range value {
		switch character {
		case '"', '\\':
			out.WriteByte('\\')
			out.WriteRune(character)
		case '\b':
			out.WriteString(`\b`)
		case '\f':
			out.WriteString(`\f`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		default:
			if character < 32 {
				const digits = "0123456789abcdef"
				out.WriteString(`\u00`)
				out.WriteByte(digits[byte(character)/16])
				out.WriteByte(digits[byte(character)%16])
			} else {
				out.WriteRune(character)
			}
		}
	}
	out.WriteByte('"')
	return out.String()
}
