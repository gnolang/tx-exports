package tavernwagers

import (
	"strconv"
	"strings"
)

// Read-only JSON views for the web app (query them with vm/qeval).

// TablesJSON lists the newest 30 tables.
func TablesJSON() string {
	var items []string
	tables.ReverseIterate("", "", func(_ string, v any) bool {
		items = append(items, tableSummary(v.(*Table)))
		return len(items) >= 30
	})
	return "[" + strings.Join(items, ",") + "]"
}

// StatsJSON returns all-time numbers for the home page.
func StatsJSON() string {
	return obj(
		"tables", itoa(tables.Size()),
		"bets", itoa(bets.Size()+pools.Size()),
		"settled", itoa(totalSettled),
		"locked", i64(totalLocked),
		"liarsCaught", itoa(liarsCaught),
		"biggestPot", i64(biggestPot),
		"judgesPaid", i64(judgesPaid),
	)
}

// MyTablesJSON lists the tables an address belongs to.
func MyTablesJSON(who address) string {
	var items []string
	tables.ReverseIterate("", "", func(_ string, v any) bool {
		t := v.(*Table)
		if t.isMember(who) {
			items = append(items, tableSummary(t))
		}
		return len(items) >= 50
	})
	return "[" + strings.Join(items, ",") + "]"
}

// TableJSON returns a table with its members, stats and newest 30 bets.
func TableJSON(tableID int) string {
	t := mustTable(tableID)
	var members []string
	for _, m := range t.Members {
		s := &Stats{}
		if v := t.Stats.Get(m.String()); v != nil {
			s = v.(*Stats)
		}
		members = append(members, obj(
			"address", q(m.String()),
			"nick", q(t.Nick(m)),
			"net", i64(s.Net),
			"wins", itoa(s.Wins),
			"losses", itoa(s.Losses),
			"draws", itoa(s.Draws),
			"disputesLost", itoa(s.DisputesLost),
			"judged", itoa(s.Judged),
		))
	}
	var betList []string
	for i := len(t.BetIDs) - 1; i >= 0 && i >= len(t.BetIDs)-30; i-- {
		betList = append(betList, betJSON(mustBet(t.BetIDs[i])))
	}
	var poolList []string
	for i := len(t.PoolIDs) - 1; i >= 0 && i >= len(t.PoolIDs)-30; i-- {
		poolList = append(poolList, poolJSON(mustPool(t.PoolIDs[i])))
	}
	return obj(
		"id", itoa(t.ID),
		"name", q(t.Name),
		"owner", q(t.Owner.String()),
		"members", "["+strings.Join(members, ",")+"]",
		"bets", "["+strings.Join(betList, ",")+"]",
		"pools", "["+strings.Join(poolList, ",")+"]",
	)
}

// BetJSON returns one bet with reports, judges, votes and payouts.
func BetJSON(betID int) string {
	return betJSON(mustBet(betID))
}

// PoolJSON returns one group bet.
func PoolJSON(poolID int) string {
	return poolJSON(mustPool(poolID))
}

func poolJSON(p *Pool) string {
	var players []string
	for _, a := range p.Players {
		rep, _ := p.Reports.Get(a.String()).(string)
		players = append(players, obj(
			"address", q(a.String()),
			"joined", boolStr(p.Joined.Has(a.String())),
			"report", q(rep),
		))
	}
	var judges []string
	for _, j := range p.Judges {
		vote, _ := p.Votes.Get(j.String()).(string)
		judges = append(judges, obj("address", q(j.String()), "vote", q(vote)))
	}
	var shares []string
	for _, sh := range p.Shares {
		shares = append(shares, i64(sh))
	}
	var payouts []string
	for _, x := range p.Payouts {
		payouts = append(payouts, obj("to", q(x.To.String()), "amount", i64(x.Amount), "why", q(x.Why)))
	}
	deadline := ""
	if p.Status == StatusDisputed {
		deadline = p.Deadline.UTC().Format("2006-01-02T15:04:05Z")
	}
	firstReport := ""
	if !p.FirstReportAt.IsZero() {
		firstReport = p.FirstReportAt.UTC().Format("2006-01-02T15:04:05Z")
	}
	return obj(
		"id", itoa(p.ID),
		"kind", q("pool"),
		"tableId", itoa(p.TableID),
		"title", q(p.Title),
		"creator", q(p.Creator.String()),
		"stake", i64(p.Stake),
		"bond", i64(p.Bond),
		"shares", "["+strings.Join(shares, ",")+"]",
		"status", q(p.Status.String()),
		"players", "["+strings.Join(players, ",")+"]",
		"judges", "["+strings.Join(judges, ",")+"]",
		"final", q(p.Final),
		"fewJudges", boolStr(p.FewJudges),
		"deadline", q(deadline),
		"firstReportAt", q(firstReport),
		"payouts", "["+strings.Join(payouts, ",")+"]",
	)
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func tableSummary(t *Table) string {
	return obj(
		"id", itoa(t.ID),
		"name", q(t.Name),
		"owner", q(t.Owner.String()),
		"ownerNick", q(t.Nick(t.Owner)),
		"members", itoa(len(t.Members)),
		"bets", itoa(len(t.BetIDs)+len(t.PoolIDs)),
	)
}

func betJSON(b *Bet) string {
	var judges []string
	for _, j := range b.Judges {
		vote := ""
		if v, ok := b.Votes.Get(j.String()).(string); ok {
			vote = v
		}
		judges = append(judges, obj("address", q(j.String()), "vote", q(vote)))
	}
	var payouts []string
	for _, p := range b.Payouts {
		payouts = append(payouts, obj("to", q(p.To.String()), "amount", i64(p.Amount), "why", q(p.Why)))
	}
	deadline := ""
	if b.Status == StatusDisputed {
		deadline = b.Deadline.UTC().Format("2006-01-02T15:04:05Z")
	}
	firstReport := ""
	if !b.FirstReportAt.IsZero() {
		firstReport = b.FirstReportAt.UTC().Format("2006-01-02T15:04:05Z")
	}
	return obj(
		"id", itoa(b.ID),
		"tableId", itoa(b.TableID),
		"title", q(b.Title),
		"playerA", q(b.PlayerA.String()),
		"playerB", q(b.PlayerB.String()),
		"stake", i64(b.Stake),
		"bond", i64(b.Bond),
		"status", q(b.Status.String()),
		"reportA", q(b.ReportA),
		"reportB", q(b.ReportB),
		"final", q(b.Final),
		"judges", "["+strings.Join(judges, ",")+"]",
		"deadline", q(deadline),
		"firstReportAt", q(firstReport),
		"payouts", "["+strings.Join(payouts, ",")+"]",
	)
}

// obj builds a JSON object from key, raw-value pairs.
func obj(kv ...string) string {
	var parts []string
	for i := 0; i+1 < len(kv); i += 2 {
		parts = append(parts, q(kv[i])+":"+kv[i+1])
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// q quotes a string as JSON. Inputs never contain control characters
// (titles and names are validated), so strconv.Quote is JSON-safe here.
func q(s string) string { return strconv.Quote(s) }

func itoa(n int) string  { return strconv.Itoa(n) }
func i64(n int64) string  { return strconv.FormatInt(n, 10) }
