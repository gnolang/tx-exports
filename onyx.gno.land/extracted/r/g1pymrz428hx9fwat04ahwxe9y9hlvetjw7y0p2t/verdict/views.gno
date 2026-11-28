package verdict

import (
	"strconv"
	"strings"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
)

const (
	maxListLimit     = uint64(100)
	maxActivityLimit = uint64(50)
)

func activityCount(market Market) uint64 {
	return market.NextActivityID
}

func boundedLimit(limit, maximum uint64) uint64 {
	if limit == 0 || limit > maximum {
		return maximum
	}
	return limit
}

func jsonString(value string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range value {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				hex := strconv.FormatInt(int64(r), 16)
				b.WriteString(`\u00`)
				for len(hex) < 2 {
					hex = "0" + hex
				}
				b.WriteString(hex)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func statusName(status MarketStatus) string {
	if status == MarketResolved {
		return "resolved"
	}
	return "open"
}

func outcomeName(outcome verdict.Outcome) string {
	switch outcome {
	case verdict.OutcomeYes:
		return "yes"
	case verdict.OutcomeNo:
		return "no"
	case verdict.OutcomeInvalid:
		return "invalid"
	default:
		return "unresolved"
	}
}

func resolverKindName(kind ResolverKind) string {
	if kind == ResolverCounter {
		return "counter"
	}
	return "balance"
}

func writeMarketJSON(b *strings.Builder, market Market) {
	b.WriteString(`{"id":"`)
	b.WriteString(strconv.FormatUint(market.ID, 10))
	b.WriteString(`","question":`)
	b.WriteString(jsonString(market.Question))
	b.WriteString(`,"creator":`)
	b.WriteString(jsonString(market.Creator.String()))
	b.WriteString(`,"closeHeight":"`)
	b.WriteString(strconv.FormatInt(market.CloseHeight, 10))
	b.WriteString(`","yesPoolUgnot":"`)
	b.WriteString(strconv.FormatInt(market.YesPool, 10))
	b.WriteString(`","noPoolUgnot":"`)
	b.WriteString(strconv.FormatInt(market.NoPool, 10))
	b.WriteString(`","totalPoolUgnot":"`)
	b.WriteString(strconv.FormatInt(totalPool(market), 10))
	b.WriteString(`","status":`)
	b.WriteString(jsonString(statusName(market.Status)))
	b.WriteString(`,"outcome":`)
	b.WriteString(jsonString(outcomeName(market.Outcome)))
	b.WriteString(`,"resolver":{"kind":`)
	b.WriteString(jsonString(resolverKindName(market.Resolver.Kind)))
	b.WriteString(`,"target":`)
	b.WriteString(jsonString(market.Resolver.Target))
	b.WriteString(`,"targetAmountUgnot":"`)
	b.WriteString(strconv.FormatInt(market.Resolver.TargetAmount, 10))
	b.WriteString(`","description":`)
	b.WriteString(jsonString(resolverDescription(market)))
	b.WriteString(`},"activityCount":`)
	b.WriteString(strconv.FormatUint(activityCount(market), 10))
	b.WriteByte('}')
}

func marketsInOrder() []Market {
	all := []Market{}
	markets.Iterate("", "", func(_ string, value any) bool {
		if market, ok := value.(Market); ok {
			all = append(all, market)
		}
		return false
	})
	return all
}

func GetMarketsJSON() string {
	var b strings.Builder
	b.WriteString(`{"markets":[`)
	for i, market := range marketsInOrder() {
		if i > 0 {
			b.WriteByte(',')
		}
		writeMarketJSON(&b, market)
	}
	b.WriteString(`]}`)
	return b.String()
}

func GetMarketJSON(marketID uint64) string {
	market, ok := marketByID(marketID)
	if !ok {
		return "null"
	}
	var b strings.Builder
	writeMarketJSON(&b, market)
	return b.String()
}

func GetPositionJSON(marketID uint64, account string) string {
	addr := address(account)
	if !addr.IsValid() || strings.ToLower(account) != account {
		return "null"
	}
	position, ok := positionByIDAndAddress(marketID, addr)
	if !ok {
		return "null"
	}
	var b strings.Builder
	b.WriteString(`{"marketId":"`)
	b.WriteString(strconv.FormatUint(marketID, 10))
	b.WriteString(`","account":`)
	b.WriteString(jsonString(addr.String()))
	b.WriteString(`","yesStakeUgnot":"`)
	b.WriteString(strconv.FormatInt(position.YesStake, 10))
	b.WriteString(`","noStakeUgnot":"`)
	b.WriteString(strconv.FormatInt(position.NoStake, 10))
	b.WriteString(`","claimed":`)
	if position.Claimed {
		b.WriteString("true")
	} else {
		b.WriteString("false")
	}
	b.WriteByte('}')
	return b.String()
}

func writeActivityJSON(b *strings.Builder, activity Activity) {
	b.WriteString(`{"id":"`)
	b.WriteString(strconv.FormatUint(activity.ID, 10))
	b.WriteString(`","marketId":"`)
	b.WriteString(strconv.FormatUint(activity.MarketID, 10))
	b.WriteString(`","bettor":`)
	b.WriteString(jsonString(activity.Bettor.String()))
	b.WriteString(`","side":`)
	if activity.Side {
		b.WriteString(`"yes"`)
	} else {
		b.WriteString(`"no"`)
	}
	b.WriteString(`,"stakeUgnot":"`)
	b.WriteString(strconv.FormatInt(activity.Stake, 10))
	b.WriteString(`","height":"`)
	b.WriteString(strconv.FormatInt(activity.Height, 10))
	b.WriteString(`"}`)
}

func insertNewest(list []Activity, activity Activity, limit uint64) []Activity {
	index := len(list)
	for i, existing := range list {
		if activity.Height > existing.Height || (activity.Height == existing.Height && activity.ID > existing.ID) {
			index = i
			break
		}
	}
	if index >= int(limit) {
		return list
	}
	list = append(list, Activity{})
	copy(list[index+1:], list[index:])
	list[index] = activity
	if uint64(len(list)) > limit {
		return list[:limit]
	}
	return list
}

func activitiesNewest(filter func(Activity) bool, limit uint64) []Activity {
	maximum := boundedLimit(limit, maxActivityLimit)
	top := []Activity{}
	activities.Iterate("", "", func(_ string, value any) bool {
		activity, ok := value.(Activity)
		if ok && filter(activity) {
			top = insertNewest(top, activity, maximum)
		}
		return false
	})
	return top
}

func writeActivityArrayJSON(b *strings.Builder, list []Activity) {
	b.WriteString(`{"activity":[`)
	for i, activity := range list {
		if i > 0 {
			b.WriteByte(',')
		}
		writeActivityJSON(b, activity)
	}
	b.WriteString(`]}`)
}

func GetActivityJSON(marketID uint64, limit uint64) string {
	list := activitiesNewest(func(activity Activity) bool {
		return activity.MarketID == marketID
	}, limit)
	var b strings.Builder
	writeActivityArrayJSON(&b, list)
	return b.String()
}

func GetAgentActivityJSON(agentAddress string, limit uint64) string {
	addr := address(agentAddress)
	if !addr.IsValid() || strings.ToLower(agentAddress) != agentAddress {
		return `{"activity":[]}`
	}
	list := activitiesNewest(func(activity Activity) bool {
		return activity.Bettor == addr
	}, limit)
	var b strings.Builder
	writeActivityArrayJSON(&b, list)
	return b.String()
}

type leaderboardEntry struct {
	account address
	net     int64
}

func leaderboardEntries(limit uint64) []leaderboardEntry {
	maximum := boundedLimit(limit, maxListLimit)
	entries := []leaderboardEntry{}
	participants.Iterate("", "", func(_ string, value any) bool {
		participant, ok := value.(Participant)
		if !ok || participant.RealizedNet == 0 {
			return false
		}
		index := len(entries)
		for i, existing := range entries {
			if participant.RealizedNet > existing.net {
				index = i
				break
			}
		}
		if index >= int(maximum) {
			return false
		}
		entries = append(entries, leaderboardEntry{})
		copy(entries[index+1:], entries[index:])
		entries[index] = leaderboardEntry{account: participant.Address, net: participant.RealizedNet}
		if uint64(len(entries)) > maximum {
			entries = entries[:maximum]
		}
		return false
	})
	return entries
}

func GetLeaderboardJSON(limit uint64) string {
	var b strings.Builder
	b.WriteString(`{"entries":[`)
	for i, item := range leaderboardEntries(limit) {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"rank":`)
		b.WriteString(strconv.Itoa(i + 1))
		b.WriteString(`,"address":`)
		b.WriteString(jsonString(item.account.String()))
		b.WriteString(`,"netUgnot":"`)
		b.WriteString(strconv.FormatInt(item.net, 10))
		b.WriteString(`"}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

func GetProtocolStatsJSON() string {
	var volume int64
	var open, resolved int
	var bets uint64
	for _, market := range marketsInOrder() {
		volume += totalPool(market)
		if market.Status == MarketResolved {
			resolved++
		} else {
			open++
		}
		bets += activityCount(market)
	}
	var b strings.Builder
	b.WriteString(`{"totalVolumeUgnot":"`)
	b.WriteString(strconv.FormatInt(volume, 10))
	b.WriteString(`","openMarkets":`)
	b.WriteString(strconv.Itoa(open))
	b.WriteString(`,"resolvedMarkets":`)
	b.WriteString(strconv.Itoa(resolved))
	b.WriteString(`,"totalBets":`)
	b.WriteString(strconv.FormatUint(bets, 10))
	b.WriteByte('}')
	return b.String()
}
