package kourt
import (
	"chain"
	"strconv"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
)
const (
	standingFlagBps = int64(10_000)
	standingDisputeBps = int64(10_000)
	standingAuthorHighBps = int64(2_000)
	standingConvictionBps = int64(1_000)
	standingUnadjudicatedBps = int64(5_000)
)
type creditRates struct {
	flag, dispute, authorHigh, conviction, unadjudicated int64
}
var creditRatesDefault = creditRates{
	flag:          standingFlagBps,
	dispute:       standingDisputeBps,
	authorHigh:    standingAuthorHighBps,
	conviction:    standingConvictionBps,
	unadjudicated: standingUnadjudicatedBps,
}
func creditRatesFor(c *Court) creditRates {
	if c.creditRates != nil {
		return *c.creditRates
	}
	return creditRatesDefault
}
func mustCreditRates(r creditRates) {
	for _, v := range []int64{r.flag, r.dispute, r.authorHigh, r.conviction, r.unadjudicated} {
		if v < 0 || v > 10_000 {
			panic("kourtv2: a standing rate is 0..10000 bps")
		}
	}
	if r.flag < r.authorHigh || r.dispute < r.authorHigh {
		panic("kourtv2: policing must credit at least as much as authorship")
	}
	if r.authorHigh <= r.conviction {
		panic("kourtv2: authorship must credit more than staking — it is the harder gate")
	}
	if r.unadjudicated <= 0 || r.unadjudicated >= 10_000 {
		panic("kourtv2: the unadjudicated rate must be a real fraction of the adjudicated one")
	}
}
func SetCreditRatesDefault(cur realm, flag, dispute, authorHigh, conviction, unadjudicated int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the default standing rates")
	}
	r := creditRates{flag, dispute, authorHigh, conviction, unadjudicated}
	mustCreditRates(r)
	creditRatesDefault = r
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-rates-default:"+creditRatesKey(r),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func SetCourtCreditRates(cur realm, courtSlug string, flag, dispute, authorHigh, conviction, unadjudicated int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	r := creditRates{flag, dispute, authorHigh, conviction, unadjudicated}
	mustCreditRates(r)
	if fire, _ := approveAction(cm.pending, "setrates:"+creditRatesKey(r), who, "",
		speechM(cm)); !fire {
		return
	}
	c.creditRates = &r
	cm.appendCourtLog(who, "setrates:"+creditRatesKey(r), "")
	emitModAct(c.id, 0, "setrates", who)
}
func creditRatesKey(r creditRates) string {
	return strconv.FormatInt(r.flag, 10) + ":" + strconv.FormatInt(r.dispute, 10) +
		":" + strconv.FormatInt(r.authorHigh, 10) + ":" +
		strconv.FormatInt(r.conviction, 10) + ":" +
		strconv.FormatInt(r.unadjudicated, 10)
}
func ClearCourtCreditRates(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who)
	if c.creditRates == nil {
		panic("kourtv2: this court has no standing-rate override")
	}
	if fire, _ := approveAction(cm.pending, "clearrates:"+c.id, who, "",
		speechM(cm)); !fire {
		return
	}
	c.creditRates = nil
	cm.appendCourtLog(who, "clearrates", "")
	emitModAct(c.id, 0, "clearrates", who)
}
func CreditRates(courtSlug string) string {
	c := mustCourt(courtSlug)
	r := creditRatesFor(c)
	inherited := "1"
	if c.creditRates != nil {
		inherited = "0"
	}
	return "flag:" + strconv.FormatInt(r.flag, 10) +
		";dispute:" + strconv.FormatInt(r.dispute, 10) +
		";author:" + strconv.FormatInt(r.authorHigh, 10) +
		";conviction:" + strconv.FormatInt(r.conviction, 10) +
		";unadjudicated:" + strconv.FormatInt(r.unadjudicated, 10) +
		";inherited:" + inherited
}
var standingCats = [standingCatN]string{"flag", "dispute", "author", "conviction"}
const (
	standingCatFlag = iota
	standingCatDispute
	standingCatAuthor
	standingCatConv
	standingCatN
)
type standingRow struct {
	score int64
	highWater int64
	passHeld bool
	tokens     int64
	lastRefill int64
	frozenUntil     int64
	frozenUntilTime int64
	frozenEpoch     int64
	frozenGapUntil     int64
	frozenGapUntilTime int64
	from [standingCatN]int64
}
func getStanding(c *Court, who address) *standingRow {
	if c.standings == nil {
		c.standings = bptree.NewBPTree32()
	}
	if v := c.standings.Get(string(who)); v != nil {
		return v.(*standingRow)
	}
	r := &standingRow{}
	c.standings.Set(string(who), r)
	return r
}
func lookupStanding(c *Court, who address) *standingRow {
	if c.standings == nil {
		return nil
	}
	if v := c.standings.Get(string(who)); v != nil {
		return v.(*standingRow)
	}
	return nil
}
func creditStanding(c *Court, who address, amount int64, cat int) {
	if amount <= 0 || who == "" || cat < 0 || cat >= standingCatN {
		return
	}
	r := getStanding(c, who)
	r.score = satAdd(r.score, amount)
	r.from[cat] = satAdd(r.from[cat], amount)
	if r.score > r.highWater {
		r.highWater = r.score
	}
}
func satAdd(a, b int64) int64 {
	const maxInt64 = int64(9223372036854775807)
	if b > 0 && a > maxInt64-b {
		return maxInt64
	}
	return a + b
}
func scaleBps(base, bps int64) int64 {
	if base <= 0 || bps <= 0 {
		return 0
	}
	if bps > 10_000 {
		bps = 10_000
	}
	return mulDiv128(base, bps, 10_000)
}
func creditDisputeResolved(c *Court, cs *claimState) {
	if cs.decidedRounds <= 0 {
		return
	}
	if cs.provisional != cs.answer {
		creditStanding(c, cs.overturnBy, scaleBps(cs.overturnBond, creditRatesFor(c).dispute), standingCatDispute)
		return
	}
	if cs.credEligible {
		creditStanding(c, cs.answerer, scaleBps(cs.answerBond0, creditRatesFor(c).dispute), standingCatDispute)
	}
}
func creditWinConviction(c *Court, cs *claimState, who address, p *stakePos) {
	r := creditRatesFor(c)
	bps := r.conviction
	if !adjudicated(cs) {
		bps = bps * r.unadjudicated / 10_000
	}
	creditStanding(c, who, scaleBps(timeAvgStake(cs, p.rawHi, p.rawLo), bps), standingCatConv)
}
func adjudicated(cs *claimState) bool { return cs.decidedPID != 0 }
func Standing(courtSlug string, who address) int64 {
	if r := lookupStanding(mustCourt(courtSlug), who); r != nil {
		return r.score
	}
	return 0
}
func StandingBreakdown(courtSlug string, who address) string {
	var row standingRow
	if r := lookupStanding(mustCourt(courtSlug), who); r != nil {
		row = *r
	}
	var b strings.Builder
	b.WriteString("score:" + strconv.FormatInt(row.score, 10))
	b.WriteString(";highwater:" + strconv.FormatInt(row.highWater, 10))
	for i, name := range standingCats {
		b.WriteString(";" + name + ":" + strconv.FormatInt(row.from[i], 10))
	}
	return b.String()
}
