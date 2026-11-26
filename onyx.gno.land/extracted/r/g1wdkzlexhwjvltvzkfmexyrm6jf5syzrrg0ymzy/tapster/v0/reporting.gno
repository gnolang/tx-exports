package tapster

import (
	"chain"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapmath/v0"
)

// Report outcomes.
const (
	OutcomeAccurate = "accurate"
	OutcomeNeutral  = "neutral"
	OutcomeOutlier  = "outlier"
	OutcomeNoQuorum = "no quorum"
)

// ----------------------------------------------------------------------
// Reporter lifecycle

// Stake adds the ugnot sent with the call to the caller's reporter stake,
// registering the caller as a reporter on first use. name is optional and
// shown on the leaderboard ("" keeps the current name).
func Stake(cur realm, name string) {
	assertCurrent(cur)
	amount := receivedUgnot(cur)
	if amount <= 0 {
		panic("send ugnot to stake, e.g. -send 1000000ugnot")
	}
	caller := cur.Previous().Address()
	// Validate everything before writing any state.
	if name != "" {
		name = cleanName(name)
	}
	r := getReporter(caller)
	var have int64
	if r != nil {
		if r.ExitAt != 0 {
			panic("this reporter is exiting; withdraw first, then stake again")
		}
		have = r.Stake
	}
	if have+amount < minStake {
		panic(ufmt.Sprintf("total stake must be at least %d ugnot", minStake))
	}
	if r == nil {
		r = &Reporter{Addr: caller, JoinedAt: now()}
		reporters.Set(caller.String(), r)
		logEvent("join", displayNameOr(caller, name)+" joined as a reporter")
	}
	if name != "" {
		r.Name = name
	}
	r.Stake += amount
	chain.Emit("Stake", "reporter", caller.String(), "amount", itoa(amount), "stake", itoa(r.Stake))
}

func displayNameOr(a address, name string) string {
	if name != "" {
		return cleanName(name)
	}
	return shortAddr(a)
}

// SetName changes the caller's display name.
func SetName(cur realm, name string) {
	assertCurrent(cur)
	r := getReporter(cur.Previous().Address())
	if r == nil {
		panic("not a reporter")
	}
	r.Name = cleanName(name)
}

// RequestExit stops the caller from reporting and starts the unbonding
// period. Stake stays slashable until it ends, so a reporter cannot submit
// a bad price and leave before the round closes.
func RequestExit(cur realm) {
	assertCurrent(cur)
	caller := cur.Previous().Address()
	r := getReporter(caller)
	if r == nil {
		panic("not a reporter")
	}
	if r.ExitAt != 0 {
		panic("exit already requested")
	}
	r.ExitAt = now() + unbondingSecs
	logEvent("exit", displayName(caller)+" requested exit")
	chain.Emit("RequestExit", "reporter", caller.String(), "withdrawableAt", itoa(r.ExitAt))
}

// Withdraw pays out stake and rewards after the unbonding period and
// removes the reporter.
func Withdraw(cur realm) {
	assertCurrent(cur)
	caller := cur.Previous().Address()
	r := getReporter(caller)
	if r == nil {
		panic("not a reporter")
	}
	if r.ExitAt == 0 {
		panic("call RequestExit first")
	}
	if now() < r.ExitAt {
		panic(ufmt.Sprintf("unbonding: withdrawable in %d seconds", r.ExitAt-now()))
	}
	settlePending(caller)
	amount := r.Stake + r.Rewards // read after settling: may have been slashed
	reporters.Remove(caller.String())
	logEvent("withdraw", displayNameOr(caller, r.Name)+" withdrew "+gnot(amount))
	send(cur, caller, amount)
	chain.Emit("Withdraw", "reporter", caller.String(), "amount", itoa(amount))
}

// settlePending finalizes every ended round that holds a report from addr,
// and refuses to continue while one of addr's reports sits in an open
// round. This closes the gap where a reporter could withdraw before a bad
// report was judged.
func settlePending(addr address) {
	t := now()
	feeds.Iterate("", "", func(_ string, v any) bool {
		f := v.(*Feed)
		if f.current == nil {
			return false
		}
		has := false
		for _, rep := range f.current.Reports {
			if rep.Reporter == addr {
				has = true
				break
			}
		}
		if !has {
			return false
		}
		if f.current.ID >= t/f.RoundSecs {
			panic("you have a report in an open round of " + f.Pair + "; try again after it closes")
		}
		finalize(f)
		return false
	})
}

// ClaimRewards pays out the caller's accumulated rewards.
func ClaimRewards(cur realm) {
	assertCurrent(cur)
	caller := cur.Previous().Address()
	r := getReporter(caller)
	if r == nil {
		panic("not a reporter")
	}
	amount := r.Rewards
	if amount == 0 {
		panic("no rewards to claim")
	}
	r.Rewards = 0
	send(cur, caller, amount)
	chain.Emit("ClaimRewards", "reporter", caller.String(), "amount", itoa(amount))
}

// Fund adds the ugnot sent with the call to a feed's reward pool. Anyone
// can sponsor a feed they rely on.
func Fund(cur realm, pair string) {
	assertCurrent(cur)
	amount := receivedUgnot(cur)
	if amount <= 0 {
		panic("send ugnot to fund the pool")
	}
	f := mustFeed(pair)
	f.Pool += amount
	logEvent("fund", displayName(cur.Previous().Address())+" funded "+pair+" with "+gnot(amount))
	chain.Emit("Fund", "pair", pair, "amount", itoa(amount))
}

// ----------------------------------------------------------------------
// Reporting

// Submit records the caller's price for pair in the current round. price
// is an integer with the feed's decimals (6 for the default feeds), so
// $0.061234 is 61234. If the previous round has ended, it is finalized
// first.
func Submit(cur realm, pair string, price int64) {
	assertCurrent(cur)
	caller := cur.Previous().Address()
	r := getReporter(caller)
	if r == nil {
		panic("not a reporter: call Stake first")
	}
	if r.ExitAt != 0 {
		panic("reporter is exiting")
	}
	if r.Stake < minStake {
		panic(ufmt.Sprintf("stake below minimum %d ugnot: top up with Stake", minStake))
	}
	if price <= 0 {
		panic("price must be positive")
	}
	f := mustFeed(pair)
	if f.Paused {
		panic("feed is paused")
	}
	t := now()
	rid := t / f.RoundSecs
	if f.current != nil && f.current.ID < rid {
		finalize(f)
	}
	if f.current == nil {
		f.current = &Round{ID: rid}
	}
	for _, rep := range f.current.Reports {
		if rep.Reporter == caller {
			panic("already reported this round")
		}
	}
	if len(f.current.Reports) >= maxReportsRound {
		panic("round is full")
	}
	f.current.Reports = append(f.current.Reports, Report{
		Reporter: caller,
		Price:    price,
		Weight:   r.Stake,
		At:       t,
	})
	r.Reports++
	chain.Emit("Submit", "pair", pair, "reporter", caller.String(), "price", itoa(price), "round", itoa(rid))
}

// Finalize closes the feed's current round if its time is up. Anyone can
// call it; reporters do it implicitly with the first submit of a new round.
// It returns true if a round was closed.
func Finalize(cur realm, pair string) bool {
	assertCurrent(cur)
	f := mustFeed(pair)
	if f.current == nil {
		return false
	}
	if f.current.ID >= now()/f.RoundSecs {
		return false // round still open
	}
	finalize(f)
	return true
}

func finalize(f *Feed) {
	rd := f.current
	f.current = nil
	if rd == nil || len(rd.Reports) == 0 {
		return
	}
	if len(rd.Reports) < f.MinReports {
		f.roundsMissed++
		for i := range rd.Reports {
			rd.Reports[i].Outcome = OutcomeNoQuorum
		}
		f.lastReports = rd.Reports
		chain.Emit("NoQuorum", "pair", f.Pair, "round", itoa(rd.ID), "reports", itoa(int64(len(rd.Reports))))
		return
	}

	prices := make([]int64, len(rd.Reports))
	weights := make([]int64, len(rd.Reports))
	lo, hi := rd.Reports[0].Price, rd.Reports[0].Price
	for i, rep := range rd.Reports {
		prices[i] = rep.Price
		weights[i] = rep.Weight
		if rep.Price < lo {
			lo = rep.Price
		}
		if rep.Price > hi {
			hi = rep.Price
		}
	}
	answer := tapmath.WeightedMedian(prices, weights)

	for i := range rd.Reports {
		rep := &rd.Reports[i]
		dev := tapmath.DeviationBps(rep.Price, answer)
		rep.DevBps = dev
		rr := getReporter(rep.Reporter)
		switch {
		case dev <= f.ToleranceBps:
			rep.Outcome = OutcomeAccurate
			if rr != nil {
				rr.Accurate++
				reward := f.RewardPerReport
				if reward > f.Pool {
					reward = f.Pool
				}
				f.Pool -= reward
				rr.Rewards += reward
				rr.Earned += reward
				totalRewards += reward
			}
		case dev > f.OutlierBps:
			rep.Outcome = OutcomeOutlier
			if rr != nil {
				rr.Outliers++
				slash := tapmath.ApplyBps(rr.Stake, f.SlashBps)
				rr.Stake -= slash
				rr.Slashed += slash
				f.Pool += slash
				totalSlashed += slash
				logEvent("slash", ufmt.Sprintf("%s slashed %s on %s: reported %s vs answer %s (%s off)",
					displayName(rep.Reporter), gnot(slash), f.Pair,
					tapmath.FormatFixed(rep.Price, f.Decimals), tapmath.FormatFixed(answer, f.Decimals), bpsPct(dev)))
				chain.Emit("Slash", "pair", f.Pair, "reporter", rep.Reporter.String(), "amount", itoa(slash), "devBps", itoa(dev))
			}
		default:
			rep.Outcome = OutcomeNeutral
		}
	}

	var spread int64
	if lo > 0 {
		spread = tapmath.DeviationBps(hi, lo)
	}
	a := Answer{Round: rd.ID, Price: answer, At: now(), Reports: len(rd.Reports), Spread: spread}
	f.latest = a
	f.hasAnswer = true
	f.history = append(f.history, a)
	if len(f.history) > maxHistory {
		f.history = f.history[len(f.history)-maxHistory:]
	}
	f.lastReports = rd.Reports
	chain.Emit("Answer", "pair", f.Pair, "price", itoa(answer), "round", itoa(rd.ID), "reports", itoa(int64(len(rd.Reports))))
}

// ----------------------------------------------------------------------
// Admin (bounded)

// AddFeed creates a new price feed.
func AddFeed(cur realm, pair, description string, decimals int, roundSecs int64, minReports int) {
	assertAdmin(cur)
	addFeed(pair, description, decimals, roundSecs, minReports)
	logEvent("feed", "new feed "+pair)
}

// SetFeedParams tunes a feed. Slashing is capped at 20% per outlier and
// tolerance must be below the outlier threshold.
func SetFeedParams(cur realm, pair string, roundSecs int64, minReports int, toleranceBps, outlierBps, slashBps, rewardPerReport int64) {
	assertAdmin(cur)
	f := mustFeed(pair)
	checkRoundSecs(roundSecs)
	if minReports < 1 || minReports > maxReportsRound {
		panic("minReports out of range")
	}
	if toleranceBps < 0 || outlierBps <= toleranceBps || outlierBps > tapmath.BPS {
		panic("need 0 <= toleranceBps < outlierBps <= 10000")
	}
	if slashBps < 0 || slashBps > maxSlashBps {
		panic("slashBps must be between 0 and 2000")
	}
	if rewardPerReport < 0 {
		panic("rewardPerReport must not be negative")
	}
	if f.current != nil && roundSecs != f.RoundSecs {
		finalize(f) // close the open round under the old schedule
	}
	f.RoundSecs = roundSecs
	f.MinReports = minReports
	f.ToleranceBps = toleranceBps
	f.OutlierBps = outlierBps
	f.SlashBps = slashBps
	f.RewardPerReport = rewardPerReport
	logEvent("params", "updated parameters of "+pair)
}

// SetPaused pauses or resumes a feed.
func SetPaused(cur realm, pair string, paused bool) {
	assertAdmin(cur)
	mustFeed(pair).Paused = paused
}

// SetProtocol sets the minimum stake and unbonding period.
func SetProtocol(cur realm, newMinStake, newUnbondingSecs int64) {
	assertAdmin(cur)
	if newMinStake < 1 {
		panic("minimum stake must be positive")
	}
	if newUnbondingSecs < 60 || newUnbondingSecs > 30*86400 {
		panic("unbonding must be between 60 seconds and 30 days")
	}
	minStake = newMinStake
	unbondingSecs = newUnbondingSecs
}

// TransferAdmin hands the admin role to another address.
func TransferAdmin(cur realm, newAdmin address) {
	assertAdmin(cur)
	if !newAdmin.IsValid() {
		panic("invalid address")
	}
	admin = newAdmin
}

// ----------------------------------------------------------------------
// helpers

func itoa(v int64) string { return tapmath.FormatFixed(v, 0) }

func gnot(u int64) string { return tapmath.FormatRounded(u, 6, 3) + " GNOT" }

func bpsPct(bps int64) string { return tapmath.FormatFixed(bps, 2) + "%" }
