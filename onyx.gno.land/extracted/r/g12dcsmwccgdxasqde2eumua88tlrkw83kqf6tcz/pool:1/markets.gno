package pool

import (
	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

// CreateMarket opens a market with `amount` mUSD (pulled from the caller,
// less the entry fee) staked on `side` (SideA or SideB). `referrer` is the
// copied basket's creator, or "" for none. Returns the new market's id.
func CreateMarket(cur realm, question, labelA, labelB, resolutionURL, category string,
	deadline int64, side int, referrer string, amount int64) int64 {
	assertNotPaused()
	if question == "" {
		panic("EmptyQuestion")
	}
	// At most a year out, so a staked market never locks funds indefinitely.
	if deadline < now()+LockSeconds || deadline > now()+MaxDeadlineAhead {
		panic("BadDeadline")
	}
	marketCount++
	id := marketCount
	m := &Market{
		ID:            id,
		Creator:       caller(cur),
		Deadline:      deadline,
		CreatedAt:     now(),
		Question:      question,
		LabelA:        labelA,
		LabelB:        labelB,
		ResolutionURL: resolutionURL,
		Category:      category,
	}
	markets.Set(key(id), m)
	emit("MarketCreated", "id", itoa(id), "creator", m.Creator.String(), "deadline", itoa(deadline), "category", category)
	addStake(cur, m, side, parseReferrer(referrer), amount)
	return id
}

// Stake puts `amount` mUSD (less the entry fee) on `side`. Repeated stakes add up.
func Stake(cur realm, id int64, side int, referrer string, amount int64) {
	assertNotPaused()
	m := getMarket(id)
	if m.State != StOpen {
		panic("NotOpen")
	}
	if now()+LockSeconds > m.Deadline {
		panic("BettingClosed")
	}
	if m.LockAt != 0 && now() >= m.LockAt {
		panic("BettingClosed")
	}
	addStake(cur, m, side, parseReferrer(referrer), amount)
}

func addStake(cur realm, m *Market, side int, referrer address, amount int64) {
	if amount < MinStake {
		panic("StakeTooSmall")
	}
	user := caller(cur)
	pull(cur, user, amount)
	bps := entryBps(user)
	if bps > MaxEntryBps {
		panic("EntryFeeTooHigh")
	}
	fee := mimir.MulDiv(amount, bps, 10_000)
	if fee != 0 {
		m.EntryFees += fee
		accrue(m.ID, roles.FeeRecipient, fee)
	}
	net := amount - fee
	p := m.mustPosition(user)
	switch side {
	case SideA:
		p.A = mimir.Add(p.A, net)
		m.TotalA = mimir.Add(m.TotalA, net)
		if referrer != "" {
			p.CopyA += net
		}
	case SideB:
		p.B = mimir.Add(p.B, net)
		m.TotalB = mimir.Add(m.TotalB, net)
		if referrer != "" {
			p.CopyB += net
		}
	default:
		panic("BadSide")
	}
	if referrer != "" && p.Referrer == "" {
		p.Referrer = referrer
		emit("ReferrerSet", "id", itoa(m.ID), "user", user.String(), "referrer", referrer.String())
	}
	mine := p.A + p.B
	roles.CheckCaps(mine, m.TotalA+m.TotalB)
	m.history.Record(now(), mimir.Amounts{A: m.TotalA, B: m.TotalB})
	p.history.Record(now(), mimir.Amounts{A: p.A, B: p.B, CopiedA: p.CopyA, CopiedB: p.CopyB})
	emit("Staked", "id", itoa(m.ID), "user", user.String(), "side", itoa(int64(side)), "amount", itoa(net))
}
