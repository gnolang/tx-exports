package competition

import (
	"strconv"
	"strings"
	"time"
)

const pageSize = 20

// Render emits bounded, pipe-delimited records for the Altair browser.
func Render(path string) string {
	require(len(path) < 150, "view path too long")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 1 && parts[0] == "" {
		return "# Altair\n\nStrait Run weekly league and native ugnot economy.\n"
	}
	now := time.Now().Unix()
	switch parts[0] {
	case "status":
		require(len(parts) == 1, "invalid status path")
		return row("status", decimal(now), decimal(weekID(now)), decimal(firstSeason), decimal(nextSnapshot), strconv.FormatBool(paused), ruleset, denom, duelVerifierKey,
			string(verifier), string(treasury), decimal(retainedClaimable))
	case "weekly":
		require(len(parts) == 4, "invalid weekly path")
		return renderWeekly(viewID(parts[1]), viewOffset(parts[2]), parts[3])
	case "duel":
		require(len(parts) == 2, "invalid duel path")
		if d := duels[viewID(parts[1])]; d != nil {
			return renderDuel(d)
		}
	case "duels":
		require(len(parts) == 3, "invalid duel history path")
		pilot := viewPilot(parts[1])
		ids := pilotDuels[pilot]
		start := viewOffset(parts[2])
		var result string
		for i := start; i < len(ids) && i-start < pageSize; i++ {
			result += renderDuel(duels[ids[len(ids)-1-i]])
		}
		return result
	case "livery":
		require(len(parts) == 2, "invalid livery path")
		pilot := viewPilot(parts[1])
		if item := catalog[equipped[pilot]]; item != nil {
			return row("livery", decimal(item.ID), item.Style)
		}
	case "shop":
		require(len(parts) == 3, "invalid shop path")
		return renderShop(viewOffset(parts[1]), viewPilot(parts[2]), now)
	default:
		panic("unknown Altair view")
	}
	return ""
}

func renderWeekly(id int64, offset int, pilot string) string {
	if firstSeason == 0 || id < firstSeason || id > weekID(time.Now().Unix())+52 {
		return ""
	}
	s := seasons[id]
	if s == nil {
		s = newSeason(id, sharesFor(id))
	}
	revenue := s.Revenue
	carryPending := id > nextSnapshot
	projectedPool := checkedAdd(s.CarryIn, revenue.Allocation)
	opens := weekStart(id)
	if id == firstSeason {
		opens = firstSeasonOpenedAt
	}
	var result = row("weekly", decimal(id), decimal(opens), decimal(weekStart(id+1)), decimal(s.Seed),
		decimal(s.FinalizedAt), decimal(projectedPool), decimal(s.Snapshot), decimal(s.CarryIn), decimal(s.CarryOut),
		decimal(revenue.Shop), decimal(revenue.DuelFees), decimal(revenue.Deductions), decimal(revenue.Realized),
		decimal(revenue.Allocation), decimal(revenue.Retained), decimal(s.Reserved), decimal(s.Claimed),
		decimal(int64(s.ranking.Size())), strconv.FormatBool(carryPending))
	for i, share := range s.Shares {
		result += row("share", decimal(int64(i+1)), decimal(share))
	}
	for i := offset; i < s.ranking.Size() && i-offset < pageSize; i++ {
		_, entry := s.ranking.GetByIndex(i)
		owner := entry.(address)
		result += renderPilot(s.pilots[owner], owner, "pilot", i+1)
	}
	owner := viewPilot(pilot)
	if p := s.pilots[owner]; p != nil {
		result += renderPilot(p, owner, "self", s.pilotRank(owner, p))
	}
	return result
}

func renderPilot(p *WeeklyPilot, owner address, kind string, rank int) string {
	if p.Rank > 0 {
		rank = p.Rank
	}
	result := row(kind, string(owner), decimal(int64(rank)), decimal(int64(p.Attempts)), decimal(int64(p.Best.Score)),
		decimal(p.Best.AcceptedAt), decimal(p.Prize), strconv.FormatBool(p.Claimed))
	if kind == "pilot" {
		return result
	}
	for i := 0; i < p.Attempts; i++ {
		result += renderScore("flight", string(owner), p.Flights[i])
	}
	return result
}

func renderScore(kind, owner string, score ScoreSubmission) string {
	return row(kind, owner, decimal(score.Seed), decimal(int64(score.Score)), score.Digest,
		string(score.Verifier), decimal(score.ExpiresAt), decimal(score.AcceptedAt), score.VerifierKey, score.Proof)
}

func renderDuel(d *Duel) string {
	result := row("duel", decimal(d.ID), string(d.Creator), string(d.Rival), decimal(d.Stake), decimal(d.Seed),
		decimal(d.JoinDeadline), decimal(d.RunDeadline), strconv.FormatBool(d.Joined), decimal(d.SettledAt),
		d.Outcome, string(d.Winner), decimal(d.Fee), decimal(d.CreatorCredit), decimal(d.RivalCredit),
		strconv.FormatBool(d.CreatorClaimed), strconv.FormatBool(d.RivalClaimed))
	if d.CreatorScore != nil {
		result += renderScore("duel-flight", string(d.Creator), *d.CreatorScore)
	}
	if d.RivalScore != nil {
		result += renderScore("duel-flight", string(d.Rival), *d.RivalScore)
	}
	return result
}

func renderShop(offset int, pilot address, now int64) string {
	var result string
	for i := int64(offset)+1; i < nextCosmeticID && i-int64(offset) <= pageSize; i++ {
		item := catalog[i]
		result += row("item", decimal(item.ID), item.Style, decimal(item.Price), decimal(item.StartsAt),
			decimal(item.EndsAt), strconv.FormatBool(item.available(now)), strconv.FormatBool(equipped[pilot] == i))
		if p := purchases[purchaseKey(pilot, i)]; p != nil {
			result += row("purchase", decimal(i), string(p.Buyer), decimal(p.Amount), p.Denom, decimal(p.PurchasedAt))
		}
	}
	return result
}

func viewPilot(raw string) address {
	if raw == "-" {
		return ""
	}
	pilot := address(raw)
	require(pilot.IsValid(), "invalid pilot address")
	return pilot
}

func viewID(raw string) int64 {
	id, err := strconv.ParseInt(raw, 10, 64)
	require(err == nil && id > 0, "invalid record id")
	return id
}

func viewOffset(raw string) int {
	offset, err := strconv.ParseInt(raw, 10, 32)
	require(err == nil && offset >= 0, "invalid page offset")
	return int(offset)
}

func row(fields ...string) string {
	return strings.Join(fields, "|")+"\n"
}
