package kourt
import (
	"chain"
	"strconv"
	"strings"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)
const (
	ladderT1BpsInit = int64(5)
	ladderT2BpsInit = int64(25)
	ladderT3BpsInit = int64(100)
	postsEntryInit = int64(3)
	postsT2Init    = int64(10)
	postsT3Init    = int64(30)
	ladderTopRatio = int64(10)
	passPriceMinCC = int64(100_000)
	passPriceBps   = int64(1)
	passPriceOfT3 = int64(100)
)
func mustPostingInvariants() {
	if postsT3Init != postsEntryInit*ladderTopRatio {
		panic("kourtv2: the top rung must be exactly ladderTopRatio x entry — the ratio is the bound, not a suggestion")
	}
	if !(0 < ladderT1BpsInit && ladderT1BpsInit < ladderT2BpsInit && ladderT2BpsInit < ladderT3BpsInit) {
		panic("kourtv2: the ladder must be strictly increasing")
	}
	if !(0 < postsEntryInit && postsEntryInit < postsT2Init && postsT2Init < postsT3Init) {
		panic("kourtv2: the rates must be strictly increasing")
	}
	if ladderT3BpsInit < passPriceOfT3*passPriceBps {
		panic("kourtv2: t3 must be at least 100x the pass price, or a unit of standing is worth more than the flag lane's burn can cover")
	}
}
func init() { mustPostingInvariants() }
type ladder struct {
	t1Bps, t2Bps, t3Bps int64
	postsEntry, postsT2 int64
}
var ladderDefault = ladder{
	t1Bps: ladderT1BpsInit, t2Bps: ladderT2BpsInit, t3Bps: ladderT3BpsInit,
	postsEntry: postsEntryInit, postsT2: postsT2Init,
}
func (l ladder) postsT3() int64 { return l.postsEntry * ladderTopRatio }
func ladderFor(c *Court) ladder {
	if c.ladder != nil {
		return *c.ladder
	}
	return ladderDefault
}
func mustLadder(l ladder) {
	if !(0 < l.t1Bps && l.t1Bps < l.t2Bps && l.t2Bps < l.t3Bps && l.t3Bps <= 10_000) {
		panic("kourtv2: the ladder must be strictly increasing within 0..10000 bps")
	}
	if !(0 < l.postsEntry && l.postsEntry < l.postsT2 && l.postsT2 < l.postsT3()) {
		panic("kourtv2: the posting rates must be strictly increasing")
	}
	if l.t3Bps < passPriceOfT3*passPriceBps {
		panic("kourtv2: t3 must stay at least 100x the pass price — lowering it alone would make a unit of standing worth more than the flag lane's burn can cover")
	}
}
func SetLadderDefault(cur realm, t1Bps, t2Bps, t3Bps, postsEntry, postsT2 int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the default ladder")
	}
	l := ladder{t1Bps, t2Bps, t3Bps, postsEntry, postsT2}
	mustLadder(l)
	ladderDefault = l
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-ladder-default:"+ladderKey(l),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func SetCourtLadder(cur realm, courtSlug string, t1Bps, t2Bps, t3Bps, postsEntry, postsT2 int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	l := ladder{t1Bps, t2Bps, t3Bps, postsEntry, postsT2}
	mustLadder(l)
	if fire, _ := approveAction(cm.pending, "setladder:"+ladderKey(l), who, "",
		speechM(cm)); !fire {
		return
	}
	c.ladder = &l
	cm.appendCourtLog(who, "setladder:"+ladderKey(l), "")
	emitModAct(c.id, 0, "setladder", who)
}
func ladderKey(l ladder) string {
	return strconv.FormatInt(l.t1Bps, 10) + ":" + strconv.FormatInt(l.t2Bps, 10) +
		":" + strconv.FormatInt(l.t3Bps, 10) + ":" +
		strconv.FormatInt(l.postsEntry, 10) + ":" + strconv.FormatInt(l.postsT2, 10)
}
func ClearCourtLadder(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who)
	if c.ladder == nil {
		panic("kourtv2: this court has no ladder override")
	}
	if fire, _ := approveAction(cm.pending, "clearladder:"+c.id, who, "",
		speechM(cm)); !fire {
		return
	}
	c.ladder = nil
	cm.appendCourtLog(who, "clearladder", "")
	emitModAct(c.id, 0, "clearladder", who)
}
func boardSupply(c *Court) (int64, bool) {
	if c.coin.Epoch() < 2 {
		return 0, false
	}
	return c.coin.PastTotal(c.coin.Epoch() - 1), true
}
func passPriceFor(c *Court) int64 {
	sup, sealed := boardSupply(c)
	if !sealed {
		return 0
	}
	p := sup * passPriceBps / 10_000
	if p < passPriceMinCC {
		p = passPriceMinCC
	}
	if lid := sup * ladderFor(c).t3Bps / 10_000 / passPriceOfT3; p > lid {
		p = lid
	}
	if p < 0 {
		p = 0
	}
	return p
}
func PassPrice(courtSlug string) int64 { return passPriceFor(mustCourt(courtSlug)) }
func Ladder(courtSlug string) string {
	c := mustCourt(courtSlug)
	l := ladderFor(c)
	inherited := "1"
	if c.ladder != nil {
		inherited = "0"
	}
	return "t1:" + strconv.FormatInt(l.t1Bps, 10) +
		";t2:" + strconv.FormatInt(l.t2Bps, 10) +
		";t3:" + strconv.FormatInt(l.t3Bps, 10) +
		";entry:" + strconv.FormatInt(l.postsEntry, 10) +
		";l2:" + strconv.FormatInt(l.postsT2, 10) +
		";l3:" + strconv.FormatInt(l.postsT3(), 10) +
		";inherited:" + inherited
}
func postLevel(c *Court, who address) int64 {
	l := ladderFor(c)
	sup, sealed := boardSupply(c)
	if !sealed {
		return 0
	}
	var s int64
	if r := lookupStanding(c, who); r != nil {
		s = r.score
	}
	switch {
	case s >= sup*l.t3Bps/10_000:
		return 3
	case s >= sup*l.t2Bps/10_000:
		return 2
	case s >= sup*l.t1Bps/10_000:
		return 1
	}
	if r := lookupStanding(c, who); r != nil && r.passHeld {
		return 1
	}
	return 0
}
func postsPerDayAt(l ladder, level int64) int64 {
	switch level {
	case 3:
		return l.postsT3()
	case 2:
		return l.postsT2
	case 1:
		return l.postsEntry
	}
	return 0
}
func PostLevel(courtSlug string, who address) int64 {
	return postLevel(mustCourt(courtSlug), who)
}
func PostsPerDay(courtSlug string, who address) int64 {
	c := mustCourt(courtSlug)
	return postsPerDayAt(ladderFor(c), postLevel(c, who))
}
func BuyCommentPass(cur realm, courtSlug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	touch(c)
	if r := lookupStanding(c, who); r != nil && r.passHeld {
		panic("kourtv2: this address already holds a pass in this court")
	}
	price := passPriceFor(c)
	if price <= 0 {
		if _, sealed := boardSupply(c); !sealed {
			panic("kourtv2: this court has not completed a sealed epoch yet; its board is not open")
		}
		panic("kourtv2: this court cannot price a pass yet — it has no supply")
	}
	mustSpendable(c, who, price)
	c.coin.Burn(who, price)
	getStanding(c, who).passHeld = true
	return price
}
func HoldsPass(courtSlug string, who address) bool {
	r := lookupStanding(mustCourt(courtSlug), who)
	return r != nil && r.passHeld
}
const secsPerDay = int64(86_400)
func bucketAt(tokens, lastRefill, rate, now int64) (avail, stamp int64) {
	if rate <= 0 {
		return 0, lastRefill
	}
	if lastRefill == 0 {
		return rate, now
	}
	stamp = lastRefill
	if gain := (now - lastRefill) * rate / secsPerDay; gain > 0 {
		tokens = satAdd(tokens, gain)
		stamp += gain * secsPerDay / rate
	}
	if tokens > rate {
		tokens = rate
	}
	if tokens < 0 {
		tokens = 0
	}
	return tokens, stamp
}
func refill(c *Court, who address, r *standingRow) int64 {
	rate := postsPerDayAt(ladderFor(c), postLevel(c, who))
	r.tokens, r.lastRefill = bucketAt(r.tokens, r.lastRefill, rate, nowTime())
	return r.tokens
}
func mustSpendPost(c *Court, who address) {
	lvl := postLevel(c, who)
	if lvl == 0 {
		if _, sealed := boardSupply(c); !sealed {
			panic("kourtv2: this court has not completed a sealed epoch yet; its board is not open")
		}
		panic("kourtv2: you cannot post in this court yet — earn standing, or buy an entry pass")
	}
	r := getStanding(c, who)
	if refill(c, who, r) < 1 {
		panic("kourtv2: your posting allowance for now is spent — level " +
			strconv.FormatInt(lvl, 10) + " allows " +
			strconv.FormatInt(postsPerDayAt(ladderFor(c), lvl), 10) + " a day")
	}
	r.tokens--
}
func PostsAvailable(courtSlug string, who address) int64 {
	c := mustCourt(courtSlug)
	r := lookupStanding(c, who)
	if r == nil {
		return 0
	}
	avail, _ := bucketAt(r.tokens, r.lastRefill, postsPerDayAt(ladderFor(c), postLevel(c, who)), nowTime())
	return avail
}
func renderStanding(slug, addrArg string) string {
	c := mustCourt(slug)
	who := address(addrArg)
	if !who.IsValid() {
		return "## Not found\nThat is not a valid address."
	}
	l := ladderFor(c)
	sup, sealed := boardSupply(c)
	lvl := postLevel(c, who)
	var b strings.Builder
	b.WriteString("# Standing in " + courtNameFor(c) + "\n\n")
	b.WriteString("`" + sanitize.InlineText(who.String()) + "`\n\n")
	if !sealed {
		b.WriteString("This court is too new to have a board. Its thresholds are quoted\n" +
			"against a sealed epoch and it has not completed one yet; comments open\n" +
			"as soon as it has.\n\n")
		b.WriteString(helpLink + "\n")
		return b.String()
	}
	var score, hw int64
	if r := lookupStanding(c, who); r != nil {
		score, hw = r.score, r.highWater
	}
	frozenAt, frozenUntil := boardFrozenAt(c, who)
	if frozenUntil != 0 {
		when := "block " + strconv.FormatInt(frozenUntil, 10)
		if frozenAt != 0 {
			when = strconv.FormatInt(frozenAt, 10) + " (" + when + ")"
		}
		b.WriteString("> **This court's moderators have frozen you out of its boards**\n" +
			"> until " + when + ".\n>\n" +
			"> It reaches comments and upvotes and nothing else: you may still stake,\n" +
			"> vote, answer, dispute, flag, open claims, withdraw, draw emission, and\n" +
			"> take every election action. An entry pass will not lift it, and buying\n" +
			"> one now would burn coin for nothing.\n>\n" +
			"> The court's [moderation log](/r/kourt/kourtv2:" + slug +
			"/mod) records who acted and why.\n\n")
	}
	b.WriteString("## What you may do\n\n")
	b.WriteString("- level: **" + strconv.FormatInt(lvl, 10) + "** of 3\n")
	b.WriteString("- comments: **" + strconv.FormatInt(postsPerDayAt(l, lvl), 10) +
		" a day**, " + strconv.FormatInt(PostsAvailable(slug, who), 10) + " available now\n")
	b.WriteString("- per claim: at most " + strconv.Itoa(maxBoardRowsPerAuthor) + " comments\n")
	if lvl == 0 {
		if hw > score {
			b.WriteString("\nA moderator slash took your standing to zero, and with it the\n" +
				"entry pass if you held one — the burn is not refunded. A successor\n" +
				"set, or the platform, can restore up to the high-water mark below.\n")
		}
		if frozenUntil == 0 {
			if hw > score {
				b.WriteString("You can also earn back from zero, or buy a new pass for " +
					strconv.FormatInt(passPriceFor(c), 10) + " " + qualifiedSymbol(c) + ".\n")
			} else {
				b.WriteString("\nYou cannot comment here yet. Earn standing below, or buy an entry\n" +
					"pass for " + strconv.FormatInt(passPriceFor(c), 10) + " " +
					qualifiedSymbol(c) + " (burned, one-off).\n")
			}
		}
	}
	b.WriteString("\n## Standing\n\n")
	b.WriteString("- earned: **" + strconv.FormatInt(score, 10) + "**\n")
	b.WriteString("- high-water mark: " + strconv.FormatInt(hw, 10) +
		" — what a moderator slash can be restored toward\n")
	b.WriteString("- entry pass: " + yesNo(HoldsPass(slug, who)) + "\n")
	writeStandingFrom(&b, c, who)
	b.WriteString("\n## The rungs, in this court\n\n")
	for _, k := range []struct {
		name string
		bps  int64
		rate int64
	}{{"1", l.t1Bps, l.postsEntry}, {"2", l.t2Bps, l.postsT2}, {"3", l.t3Bps, l.postsT3()}} {
		b.WriteString("- level " + k.name + ": " + strconv.FormatInt(sup*k.bps/10_000, 10) +
			" standing (" + strconv.FormatInt(k.bps, 10) + " bps of supply) → " +
			strconv.FormatInt(k.rate, 10) + " a day\n")
	}
	b.WriteString("\nEach rung is a **share of this court's supply**, not a fixed " +
		"number, so the bar rises as the court grows. Standing itself is never " +
		"taken except by a logged moderator slash — but a score that does not " +
		"move can still fall below a rung it used to clear.\n")
	b.WriteString("\n## How standing is earned\n\n")
	b.WriteString("Only where the court adjudicated something, and always in proportion\n" +
		"to your own capital that the act committed or destroyed:\n\n")
	b.WriteString("- a quality flag whose slash **settled** — the full bar, two thirds low\n")
	b.WriteString("- **prevailing in a dispute** — an uphold against real opposition, or an overturn\n")
	b.WriteString("- authoring a claim the court rated **HIGH** — seeded claims earn nothing\n")
	b.WriteString("- **winning conviction** on a resolved claim; half where nobody disputed it\n\n")
	b.WriteString("Never earned: commenting, being upvoted, buying " +
		qualifiedSymbol(c) + ", or buying the pass.\n")
	b.WriteString("Standing does not decay. A moderator may slash it for abuse; the\n")
	b.WriteString("high-water mark above is what a successor set can restore.\n")
	b.WriteString("\n## The answer record\n\n")
	b.WriteString("- contested-and-upheld answers: **" +
		strconv.FormatInt(int64(AnswerRecord(slug, who)), 10) + "**\n")
	b.WriteString("\n_Adjudicated — moderators cannot change this._\n")
	return b.String()
}
func renderStandingIndex(slug string) string {
	c := mustCourt(slug)
	l := ladderFor(c)
	var b strings.Builder
	b.WriteString("# Standing in " + courtNameFor(c) + "\n\n")
	b.WriteString("To see an address's standing, put it on the end of this " +
		"page's path: `/r/kourt/kourtv2:" + sanitize.InlineText(slug) +
		"/me/<address>`\n\n")
	b.WriteString("An entry pass costs " + strconv.FormatInt(passPriceFor(c), 10) +
		" " + qualifiedSymbol(c) + ", burned, once. Standing is earned and " +
		"cannot be bought.\n\n")
	b.WriteString("Standing is measured against this court's coin supply, in " +
		"basis points — one bp is a hundredth of a percent.\n\n")
	b.WriteString("- level 1 at " + strconv.FormatInt(l.t1Bps, 10) + " bps of supply → " +
		strconv.FormatInt(l.postsEntry, 10) + " comments a day\n")
	b.WriteString("- level 2 at " + strconv.FormatInt(l.t2Bps, 10) + " bps → " +
		strconv.FormatInt(l.postsT2, 10) + " a day\n")
	b.WriteString("- level 3 at " + strconv.FormatInt(l.t3Bps, 10) + " bps → " +
		strconv.FormatInt(l.postsT3(), 10) + " a day\n")
	return b.String()
}
func writeStandingFrom(b *strings.Builder, c *Court, who address) {
	r := lookupStanding(c, who)
	if r == nil {
		return
	}
	labels := [standingCatN]string{
		"quality flags whose slash settled",
		"disputes you prevailed in",
		"claims of yours the court rated HIGH",
		"conviction on resolved claims",
	}
	listed := false
	for i := 0; i < standingCatN; i++ {
		if r.from[i] == 0 {
			continue
		}
		if !listed {
			b.WriteString("- from: ")
			listed = true
		} else {
			b.WriteString("; ")
		}
		b.WriteString(strconv.FormatInt(r.from[i], 10) + " from " + labels[i])
	}
	if listed {
		b.WriteString("\n")
	}
}
func yesNo(b bool) string {
	if b {
		return "held"
	}
	return "none"
}
