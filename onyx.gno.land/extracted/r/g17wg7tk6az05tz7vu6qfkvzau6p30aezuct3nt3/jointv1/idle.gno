package jointv1

// The idle pass. A pub whose owner has not acted for IdleAfterHours game
// hours still dilutes every other pub's share of the customer pool, so
// anyone may prune it: it is settled up to now (it was in the totals while
// it earned), then leaves the totals and becomes dormant. A dormant pub
// earns nothing; its gold, stock, score and leaderboard entry are kept. The
// owner's next own action rejoins it, with no credit for the dormant hours.

// IdleAfterHours is how many game hours without an own action make a pub
// prunable.
const IdleAfterHours int64 = 48

// Prune removes owner's idle pub from the town totals. Anyone may call it,
// including other realms. Pubs only; the pub must not be dormant already and
// its owner's last own action must be at least IdleAfterHours game hours ago.
func Prune(cur realm, owner string) {
	assertNoSend()
	assertNotPaused()
	t := mustTavern(owner)
	assertPub(t)
	if t.Dormant != 0 {
		panic("town: already dormant")
	}
	if CurrentGameHour()-t.LastActionHour < IdleAfterHours {
		panic("town: not idle")
	}
	settleTavern(t) // credits up to now at today's shares
	leaveTotals(t)
	t.Dormant = 1
	writeSnapshot(CurrentGameHour())
}

// joinTotals recomputes t's weight and adds the pub to the town totals.
func joinTotals(t *Tavern) {
	t.Weight = pubWeight(t)
	pubCount++
	totalWeight += t.Weight
	totalPriceCg += t.PriceCg
	totalPriceWeight += t.PriceCg * t.Weight
}

// leaveTotals removes the pub from the town totals with the exact values it
// added (its stored Weight and PriceCg, kept in the record).
func leaveTotals(t *Tavern) {
	pubCount--
	totalWeight -= t.Weight
	totalPriceCg -= t.PriceCg
	totalPriceWeight -= t.PriceCg * t.Weight
}

// settleDormant is what Settle does to a dormant pub (settleTavern leaves
// it unchanged): no hours, revenue, tax or reputation are credited; LastHour
// moves to now and a new game day starts the day's books (ProfitTodayCg 0,
// ScoreDayStart the current score), as a settle with no sales would.
func settleDormant(t *Tavern, now int64) {
	if t.LastHour >= now {
		return
	}
	if now/24 != t.LastHour/24 {
		t.ProfitTodayCg = 0
		t.ScoreDayStart = t.SeasonScore
	}
	t.LastHour = now
}

// ownerActs records an own action of a pub's owner. Call it after the
// settle and after every check of the action passed, before the action
// mutates: a dormant pub rejoins the totals first (LastHour moves to now
// without crediting the dormant hours), then LastActionHour moves.
func ownerActs(t *Tavern) {
	now := CurrentGameHour()
	if t.Dormant != 0 {
		settleDormant(t, now)
		joinTotals(t)
		t.Dormant = 0
		writeSnapshot(now)
	}
	t.LastActionHour = now
}
