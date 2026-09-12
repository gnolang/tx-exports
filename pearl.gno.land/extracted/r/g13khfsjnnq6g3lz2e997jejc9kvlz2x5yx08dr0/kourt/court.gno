package kourt
import (
	"strings"
	checkpoint "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/checkpoint/v0"
	curve "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/curve/v0"
	governor "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/governor/v0"
	grc20votes "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)
const errStaleRealm = "kourtv2: stale realm; call through a crossing function"
const (
	coinDecimals = 6
	epochBlocks  = int64(720)
	curveCap   = (int64(9223372036854775807) / grc20votes.Bps) / 2
	curveDenom = int64(1_000_000_000)
)
const (
	periodBlocks = int64(120_960)
	budgetWeeklyBps = int64(38)
	stepDownPeriods = int64(104)
	rMaxPeriods     = int64(4)
	tierRefFloorBps = int64(40)
	tierFloorBps    = int64(2500)
	tierCeilBps     = int64(20000)
	tierRefDustCC   = int64(1_000_000)
	tierEMAN = int64(16)
	tierParBps = int64(10000)
	splitWinners, splitAuthor, splitAnswerer, splitCarrot = int64(80), int64(8), int64(5), int64(7)
)
const (
	answerBondBps = int64(600)
	disputeBondXBps, disputeBondOfAnswerBps = int64(2000), int64(4000)
	maxFailedRounds                         = 3
	compOwnX, compOfBurnBps = int64(2), int64(8000)
	decideWindowBlocks = int64(120_960)
	carrotClampXBps  = int64(200)
	carrotClampMinCC = int64(1_000_000)
	bondFloorFlatBps = int64(450)
	bondFloorConvBps = int64(10700)
	depositFeeBps    = int64(1000)
	priorityNetRecord    = 3
	priorityColdStartN   = 3
	priorityWindowBlocks = int64(17_280)
	settleDelay      = int64(51_840)
	deadClaimTimeout = int64(1_451_520)
	metaSlug = "meta"
	metaWeeklyBudget = int64(100_000_000)
	answerXFloorBps = int64(50)
	depositFloorBps = int64(2)
	ordAnswerXFloorBps = int64(10)
	ordDepositFloorBps = int64(1)
	maxCourtNameLen = 100
	maxSlugLen        = 11
	maxStakeOpenDelay = int64(17_280)
)
func mustInvariants() {
	maxSupply := int64(9223372036854775807) / grc20votes.Bps
	if curveCap > (maxSupply/1785)*1000 {
		panic("kourtv2: curveCap × emission growth bound exceeds the tally-safe supply ceiling")
	}
	if metaLifetimeEmission := metaWeeklyBudget * 151; curveCap > maxSupply-metaLifetimeEmission {
		panic("kourtv2: curveCap + meta's lifetime emission exceeds the tally-safe supply ceiling")
	}
	if tierFloorBps*tierRefFloorBps != tierParBps*ordAnswerXFloorBps {
		panic("kourtv2: the multiplier's floor no longer meets the answerability floor — " +
			"a band of answerable claims would have a rate their size cannot move")
	}
	if tierCeilBps != 2*tierParBps {
		panic("kourtv2: the multiplier ceiling is no longer the old HIGH band — " +
			"this raises the per-claim draw the emission bounds were fitted to")
	}
	if tierFloorBps <= 0 || tierFloorBps >= tierParBps || tierParBps >= tierCeilBps {
		panic("kourtv2: the multiplier clamps are out of order")
	}
	if tierRefFloorBps <= ordAnswerXFloorBps {
		panic("kourtv2: the reference floor must exceed the answerability floor")
	}
	if tierEMAN <= 0 {
		panic("kourtv2: the running average's memory must be positive")
	}
	parPoints := tierParBps / 100
	if bondFloorConvBps < (parPoints+splitCarrot)*100 {
		panic("kourtv2: the slash multiple does not cover the mid draw plus the carrot — the draw cap would cut the published MID rate")
	}
	if 2*disputeBondOfAnswerBps > compOfBurnBps {
		panic("kourtv2: dispute bond arm breaks the round-1 honest-dispute bar")
	}
	if budgetWeeklyBps*52 > 2000 {
		panic("kourtv2: the weekly budget exceeds the 20%/yr inflation ceiling")
	}
	if splitWinners+splitAuthor+splitAnswerer != 93 {
		panic("kourtv2: the tier-scaled split must sum to 93 points")
	}
	maxRateBpsFP := 255 * (r0WeeklyBps*1_000_000 + budgetBpsFPStart) / 100
	maxTcWeeks := deadClaimTimeout / periodBlocks
	maxMidGrossBps := maxRateBpsFP * maxTcWeeks / 1_000_000
	if bondFloorConvBps*maxMidGrossBps/10000 <= answerBondBps {
		panic("kourtv2: the draw arm never reaches the base bond — the collateralization floor is inert and the max-keying prices nothing")
	}
	maxBondBps := bondFloorConvBps * maxMidGrossBps / 10000
	if maxBondBps < answerBondBps {
		maxBondBps = answerBondBps
	}
	if bondFloorFlatBps*4/3 > answerBondBps {
		panic("kourtv2: the flat slash arm leaves the base answer bond no settle-refund margin")
	}
	if maxAnswerBondBps() != maxBondBps {
		panic("kourtv2: maxAnswerBondBps drifted from the deploy-time worst-case bond")
	}
	for _, l := range []struct {
		name    string
		floor   int64
		deposit int64
	}{
		{"meta", answerXFloorBps, depositFloorBps},
		{"ordinary", ordAnswerXFloorBps, ordDepositFloorBps},
	} {
		filing := l.floor * (grc20votes.Bps + maxBondBps) / grc20votes.Bps
		if filing >= quorumSupplyBps {
			panic("kourtv2: the " + l.name + " answerability floor prices filing above winning the vote — incumbency lock by price")
		}
		if 50*l.deposit < filing {
			panic("kourtv2: a 50-row flood is cheaper than the self-answer escape from it (§5.3), " + l.name + " lane")
		}
		if l.deposit >= l.floor {
			panic("kourtv2: the " + l.name + " deposit floor exceeds its answerability floor")
		}
	}
}
func init() { mustInvariants() }
type Params struct {
	disputeThresholdBps  int64
	votingBlocks         int64
	graceBlocks          int64
	minAnswerX           int64
	answerBondCapCC      int64
	minClaimDepositCC    int64
	escrowMinBlocks      int64
	escrowMaxBlocks      int64
	stakeOpenDelayBlocks int64
}
func defaultParams() Params {
	return Params{
		disputeThresholdBps:  5001,
		votingBlocks:         120_960,
		graceBlocks:          17_280,
		minAnswerX:           1_000_000,
		answerBondCapCC:      0,
		minClaimDepositCC:    1_000_000,
		escrowMinBlocks:      120_960,
		escrowMaxBlocks:      362_880,
		stakeOpenDelayBlocks: 0,
	}
}
func (p Params) mustSane() Params {
	if p.disputeThresholdBps < 5001 || p.disputeThresholdBps > 10000 {
		panic("kourtv2: the overturn threshold must be in [5001, 10000]")
	}
	if p.votingBlocks < 1 || p.graceBlocks < 1 {
		panic("kourtv2: vote and grace windows must be positive")
	}
	if p.minAnswerX < 1 {
		panic("kourtv2: minAnswerX must be positive")
	}
	if p.minClaimDepositCC < 1 {
		panic("kourtv2: the claim deposit must never be zero")
	}
	if p.escrowMinBlocks < 1 || p.escrowMaxBlocks < p.escrowMinBlocks {
		panic("kourtv2: the escrow window is malformed")
	}
	if ladderWindow(p) > p.escrowMaxBlocks {
		panic("kourtv2: the escrow ceiling cannot fit the failed-round ladder a defaulted verdict must walk")
	}
	if p.answerBondCapCC < 0 {
		panic("kourtv2: answerBondCapCC must be non-negative")
	}
	if p.stakeOpenDelayBlocks < 0 || p.stakeOpenDelayBlocks > maxStakeOpenDelay {
		panic("kourtv2: the polish window must be in [0, 24h]")
	}
	return p
}
type Court struct {
	xBarAcc int64
	id   string
	name string
	desc string
	image *mediaItem
	tier  uint8
	admin address
	coin *grc20votes.Ledger
	gov  *governor.Governor
	crv  curve.Curve
	escrow address
	minted int64
	claims  *bptree.BPTree
	nextID  uint64
	params  Params
	deposit int64
	cumAccrual      int64
	accrualRem      int64
	curPeriodBudget int64
	curBudgetBpsFP  int64
	dEffBpsFP       int64
	rateAccFP       int64
	emaMinted       int64
	emittedAtRoll   int64
	lastAccrual     int64
	periodIndex     int64
	createdAt       int64
	reservedTail    int64
	juniorReserved  int64
	seniorOwed      int64
	seniorPaid      int64
	emittedTotal    int64
	queue           *bptree.BPTree
	queueSeq        uint64
	records         *bptree.BPTree
	assocOut          *bptree.BPTree
	assocIn           *bptree.BPTree
	supOf           *bptree.BPTree
	supBy           *bptree.BPTree
	locked         *bptree.BPTree
	voteLocks      *bptree.BPTree
	stakeIdx       *bptree.BPTree
	qualifiedCount int
	mod *courtMod
	csArch *checkpoint.Archive
	stripIdx   *bptree.BPTree
	pendingIdx *bptree.BPTree
	burnedGNOT int64
	burnKey    string
	createdSeq uint64
	burnH checkpoint.Series
	priceH checkpoint.Series
	absBudget int64
	assocBond int64
	ladder *ladder
	creditRates *creditRates
	standings *bptree.BPTree
}
var courts = bptree.NewBPTree32()
func StartCourt(cur realm, slug, name string) string {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	takeCourtCreationBurn(cur)
	return startCourtUser(cur.Previous().Address(), cur.Address(), slug, name, 0)
}
func StartCourtP(cur realm, slug, name string, stakeOpenDelay int64) string {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	takeCourtCreationBurn(cur)
	return startCourtUser(cur.Previous().Address(), cur.Address(), slug, name, stakeOpenDelay)
}
func startCourtUser(admin, escrowAddr address, slug, name string, delay int64) string {
	if slug == metaSlug {
		panic("kourtv2: the 'meta' slug is reserved")
	}
	return startCourt(admin, escrowAddr, slug, name, delay)
}
func startCourt(admin, escrowAddr address, slug, name string, delay int64) string {
	mustSlug(slug)
	mustCourtName(name)
	if courts.Has(slug) {
		panic("kourtv2: that slug is taken")
	}
	p := defaultParams()
	p.stakeOpenDelayBlocks = delay
	coin := grc20votes.NewLedgerWithClock(name, courtSymbol(slug), coinDecimals, epochBlocks, realmClock{})
	c := &Court{
		id:             slug,
		name:           name,
		tier:           tierListed,
		admin:          admin,
		coin:           coin,
		gov:            governor.New(coin, coin),
		crv:            curve.New(curveDenom, curveCap),
		escrow:         escrowAddr,
		claims:         bptree.NewBPTree32(),
		queue:          bptree.NewBPTree32(),
		records:        bptree.NewBPTree32(),
		standings:      bptree.NewBPTree32(),
		locked:         bptree.NewBPTree32(),
		voteLocks:      bptree.NewBPTree32(),
		stakeIdx:       bptree.NewBPTree32(),
		params:         p.mustSane(),
		createdAt:      heightNow(),
		curBudgetBpsFP: budgetBpsFPStart,
	}
	c.lastAccrual = c.createdAt
	if slug == metaSlug {
		c.absBudget = metaWeeklyBudget
	}
	c.gov.Adopt(disputeKind{}, disputeRules(c.params))
	courts.Set(slug, c)
	indexNewCourt(c)
	if directoryAdmin == "" {
		directoryAdmin = admin
	}
	return slug
}
const maxCourtDescLen = 240
func SetCourtDesc(cur realm, courtSlug, desc string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireFolderMod(c, who)
	mustCourtDesc(desc)
	c.desc = desc
	emitModAct(c.id, 0, "court-desc", who)
}
func SetCourtImage(cur realm, courtSlug, media string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireFolderMod(c, who)
	items := parseMediaArg(media)
	if len(items) != 1 {
		panic("kourtv2: a court carries exactly one image")
	}
	if items[0].kind != mediaKindImage {
		panic("kourtv2: a court's image is an image, not a video link")
	}
	c.image = &items[0]
	emitModAct(c.id, 0, "court-image", who)
}
func ClearCourtImage(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireFolderMod(c, who)
	c.image = nil
	emitModAct(c.id, 0, "court-image-clear", who)
}
func CourtImage(courtSlug string) string {
	c := mustCourt(courtSlug)
	if c.image == nil {
		return "[]"
	}
	return encodeMedia([]mediaItem{*c.image})
}
func CourtImages(slugs string) string {
	out := strings.Builder{}
	sent := 0
	for _, sl := range strings.Split(slugs, ",") {
		if sent >= seriesPageMax {
			break
		}
		sl = strings.TrimSpace(sl)
		if sl == "" {
			continue
		}
		v := courts.Get(sl)
		if v == nil {
			continue
		}
		c := v.(*Court)
		if c.image == nil {
			continue
		}
		out.WriteString(sl + "\t" + encodeMedia([]mediaItem{*c.image}) + "\n")
		sent++
	}
	return out.String()
}
func mustCourtDesc(desc string) {
	if runeLen(desc) > maxCourtDescLen {
		panic("kourtv2: a court description is at most 240 characters")
	}
	for i := 0; i < len(desc); i++ {
		if desc[i] == '\n' || desc[i] == '\r' {
			panic("kourtv2: a court description is a single paragraph")
		}
	}
}
func mustCourtName(name string) {
	if runeLen(name) == 0 || runeLen(name) > maxCourtNameLen {
		panic("kourtv2: a court name is 1..100 characters")
	}
}
func CourtDesc(courtSlug string) string {
	return courtDescFor(mustCourt(courtSlug))
}
func CourtStakeOpenDelay(courtSlug string) int64 {
	return mustCourt(courtSlug).params.stakeOpenDelayBlocks
}
func CourtCount() int { return courts.Size() }
func Exists(slug string) bool { return courts.Has(slug) }
func CourtName(slug string) string { return mustCourt(slug).name }
func CourtSymbol(slug string) string { return mustCourt(slug).coin.Symbol() }
func CoinDecimals() int { return coinDecimals }
func CoinSupply(slug string) int64   { return mustCourt(slug).coin.TotalSupply() }
func CoinPrice(slug string) int64 { return mustCourt(slug).crv.Price(mustCourt(slug).minted) }
func CourtEscrow(slug string) address { return mustCourt(slug).escrow }
func EmittedTotal(slug string) int64 { return mustCourt(slug).emittedTotal }
func effMinAnswerX(c *Court) int64 {
	if c.id == metaSlug {
		return supplyFloor(c, answerXFloorBps, c.params.minAnswerX)
	}
	return supplyFloor(c, ordAnswerXFloorBps, c.params.minAnswerX)
}
func effMinDeposit(c *Court) int64 {
	if c.id == metaSlug {
		return supplyFloor(c, depositFloorBps, c.params.minClaimDepositCC)
	}
	return supplyFloor(c, ordDepositFloorBps, c.params.minClaimDepositCC)
}
func maxAnswerBondBps() int64 {
	maxRateBpsFP := 255 * (r0WeeklyBps*1_000_000 + budgetBpsFPStart) / 100
	maxMidGrossBps := maxRateBpsFP * (deadClaimTimeout / periodBlocks) / 1_000_000
	if arm := bondFloorConvBps * maxMidGrossBps / 10000; arm > answerBondBps {
		return arm
	}
	return answerBondBps
}
func supplyFloor(c *Court, bps, dust int64) int64 {
	var supply int64
	if at := c.coin.Epoch(); at > 1 {
		supply = c.coin.PastTotal(at - 1)
	}
	v := mulDiv128(supply, bps, grc20votes.Bps)
	if v < dust {
		v = dust
	}
	if lid := mulDiv128(supply, quorumSupplyBps, grc20votes.Bps) *
		(grc20votes.Bps - 1) / (grc20votes.Bps + maxAnswerBondBps()); lid > 0 && v > lid {
		v = lid
	}
	if v < 1 {
		v = 1
	}
	return v
}
func mustCourt(slug string) *Court {
	v := courts.Get(slug)
	if v == nil {
		panic("kourtv2: no such court")
	}
	return v.(*Court)
}
func courtSymbol(slug string) string { return strings.ToUpper(slug) }
var reservedSlugs = []string{
	"kourt", "court", "gno", "gnot", "ugnot",
	"btc", "eth", "usdc", "usdt",
}
func mustSlug(slug string) {
	if len(slug) == 0 || len(slug) > maxSlugLen {
		panic("kourtv2: a slug is 1..11 characters")
	}
	for _, r := range reservedSlugs {
		if slug == r {
			panic("kourtv2: that slug is reserved")
		}
	}
	for i := 0; i < len(slug); i++ {
		ch := slug[i]
		ok := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
		if !ok {
			panic("kourtv2: a slug is lowercase letters and digits only")
		}
	}
}
