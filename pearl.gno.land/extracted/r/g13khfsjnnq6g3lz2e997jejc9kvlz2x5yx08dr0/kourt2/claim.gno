package kourt2
import (
	"chain"
	"strconv"
	"strings"
	checkpoint "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/checkpoint/v0"
	twap "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/twap/v0"
	bptree "gno.land/p/nt/bptree/v0"
)
const (
	sideYES = 0
	sideNO  = 1
)
const twapBuckets = 168
const maxClaimBodyLen = 2000
func runeLen(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}
type claimState struct {
	id     uint64
	title  string
	body   string
	media  []mediaItem
	author address
	deposit  int64
	fee      int64
	seeded   bool
	noAccuracy bool
	openedAt int64
	openedAtTime   int64
	answeredAtTime int64
	verdictAtTime  int64
	escrowUntilAt  int64
	closed         bool
	board      *bptree.BPTree
	boardTop   *bptree.BPTree
	boardKids  *bptree.BPTree
	boardWrote *bptree.BPTree
	boardScore *bptree.BPTree
	boardVoted *bptree.BPTree
	boardNextID uint64
	inStrip   bool
	inPending bool
	yesStake, noStake int64
	stakers           *bptree.BPTree
	yesConvHi, yesConvLo uint64
	noConvHi, noConvLo   uint64
	yesRawHi, yesRawLo   uint64
	noRawHi, noRawLo     uint64
	yesLastAcc, noLastAcc     int64
	yesLastRawAt, noLastRawAt int64
	oi  twap.Ring
	yes twap.Ring
	yesH, noH     checkpoint.Series
	yesD, noD     checkpoint.Series
	histTrimmedTo uint32
	frozenAt        int64
	rateAccAtFreeze int64
	xBarFrozen      int64
	yesStakeAtFreeze, noStakeAtFreeze int64
	answer       int8
	answerer     address
	answerBond   int64
	answerBond0  int64
	answerHeight int64
	verdictAt int64
	route     string
	tierRef int64
	disputeOpen   bool
	disputeOpenedTime int64
	round         int64
	failedRounds  int64
	decidedRounds int64
	disputer      address
	disputeBond   int64
	overturnBy address
	overturnBond int64
	proposalID    int64
	provisional   int8
	escrowUntil   int64
	provClose     bool
	credEligible bool
	voted          *bptree.BPTree
	rewardsOpened bool
	drawWinners   int64
	drawAuthor    int64
	drawAnswerer  int64
	winPoolConvCC int64
	openBlocks    int64
	carrotTotal   int64
	carrotPool    int64
	carrotChoice  string
	carrotDenom   int64
	decidedPID    int64
	spamW      int64
	spamTotalW int64
	spamClosed bool
	authorPaid    bool
	answererPaid  bool
}
func OpenClaim(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	return openClaim(c, cur.Previous().Address(), title, "", false)
}
func OpenClaimIn(cur realm, courtSlug string, folderID uint64, title, body string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	cm := ensureMod(c)
	f := cm.mustFolder(folderID)
	if f.retired || f.purged {
		panic("kourtv2: that set is retired; a claim filed there would be unreachable")
	}
	who := cur.Previous().Address()
	id := openClaim(c, who, title, body, false)
	fileInto(f, id)
	emitModAct(c.id, id, "folder-add", who)
	return id
}
func OpenClaimP(cur realm, courtSlug, title, body string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	return openClaim(c, cur.Previous().Address(), title, body, false)
}
func OpenClaimSeeded(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	if cm.installedByMeta {
		panic("kourtv2: a meta-installed moderator set may not seed claims; seed after a local election")
	}
	return openClaim(c, who, title, "", true)
}
func OpenClaimPM(cur realm, courtSlug, title, body, media string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	items := parseMediaArg(media)
	id := openClaim(c, cur.Previous().Address(), title, body, false)
	if len(items) > 0 {
		mustClaim(c, id).media = items
	}
	return id
}
func openClaim(c *Court, who address, title, body string, seeded bool) uint64 {
	if runeLen(title) == 0 || runeLen(title) > 200 {
		panic("kourtv2: a claim title is 1..200 characters")
	}
	if runeLen(body) > maxClaimBodyLen {
		panic("kourtv2: a claim body is at most " + strconv.Itoa(maxClaimBodyLen) + " characters")
	}
	var dep, fee int64
	if !seeded {
		dep = effMinDeposit(c)
		fee = dep * depositFeeBps / 10000
		mustSpendable(c, who, dep+fee)
		c.coin.Transfer(who, c.escrow, dep+fee)
		c.deposit += dep + fee
	}
	c.nextID++
	id := c.nextID
	cs := &claimState{
		id:           id,
		title:        title,
		body:         body,
		author:       who,
		deposit:      dep,
		fee:          fee,
		seeded:       seeded,
		openedAt:     heightNow(),
		openedAtTime: nowTime(),
		stakers:      bptree.NewBPTree32(),
		oi:           twap.New(epochBlocks, twapBuckets, 8),
		yes:          twap.New(epochBlocks, twapBuckets, 8),
		provisional:  -1,
	}
	c.claims.Set(beClaimKey(id), cs)
	if seeded {
		pendingEnter(c, cs)
	}
	onClaimOpened(c, cs)
	chain.Emit("ClaimOpened",
		"court", c.id,
		"claim", strconv.FormatUint(id, 10),
		"author", who.String(),
		"seeded", strconv.FormatBool(seeded),
	)
	return id
}
func EditClaimTitle(cur realm, courtSlug string, claimID uint64, newTitle string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if who != cs.author {
		panic("kourtv2: only the author may edit the title")
	}
	if len(newTitle) == 0 || len(newTitle) > 200 {
		panic("kourtv2: a claim title is 1..200 characters")
	}
	if cs.closed || cs.frozenAt != 0 {
		panic("kourtv2: the claim is no longer editable")
	}
	if passed, known := pastDeadline(cs.openedAtTime, blocksToSecs(c.params.stakeOpenDelayBlocks)); (known && passed) ||
		(!known && heightNow() >= cs.openedAt+c.params.stakeOpenDelayBlocks) {
		panic("kourtv2: the polish window has closed; the title is frozen")
	}
	if cs.yesStake != 0 || cs.noStake != 0 {
		panic("kourtv2: staking has begun; the title is frozen")
	}
	cs.title = newTitle
	onTitleEdited(c, cs)
	chain.Emit("ClaimTitleEdited", "court", c.id, "claim", strconv.FormatUint(claimID, 10))
}
func CloseDeadClaim(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.closed {
		panic("kourtv2: already closed")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: this claim has an answer; it settles, it does not die")
	}
	if passed, known := pastDeadline(cs.openedAtTime, deadClaimSecs); (known && !passed) ||
		(!known && heightNow() < cs.openedAt+deadClaimTimeout) {
		panic("kourtv2: the dead-claim timeout has not passed")
	}
	cs.closed = true
	pendingExit(c, cs)
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Burn(c.escrow, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
}
func ClaimCount(courtSlug string) uint64 { return mustCourt(courtSlug).nextID }
func ClaimTitle(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	return claimTitleFor(c, mustClaim(c, claimID))
}
func ClaimBody(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	return claimBodyFor(c, mustClaim(c, claimID))
}
func ClaimMedia(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	return encodeMedia(claimMediaVisible(c, mustClaim(c, claimID)))
}
func ClaimAuthor(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).author
}
func ClaimClosed(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).closed
}
func ClaimSeeded(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).seeded
}
func StakePools(courtSlug string, claimID uint64) (yes, no int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.yesStake, cs.noStake
}
func TrailingOI(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.oi.Average(heightNow(), window)
}
func PoolConviction(courtSlug string, claimID uint64) (yes, no int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return convToCC(cs.yesConvHi, cs.yesConvLo), convToCC(cs.noConvHi, cs.noConvLo)
}
func TrailingYes(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.yes.Average(heightNow(), window)
}
func DocketSeries(courtSlug string, ids string, window int64) string {
	c := mustCourt(courtSlug)
	now := heightNow()
	out := strings.Builder{}
	sent := 0
	for _, part := range strings.Split(ids, ",") {
		if sent >= seriesPageMax {
			break
		}
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			continue
		}
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			continue
		}
		cs := v.(*claimState)
		oi, oiMature := cs.oi.Average(now, window)
		yes, yesMature := cs.yes.Average(now, window)
		if sent > 0 {
			out.WriteString(";")
		}
		out.WriteString(strconv.FormatUint(id, 10))
		out.WriteString(":" + strconv.FormatInt(cs.yesStake, 10))
		out.WriteString(":" + strconv.FormatInt(cs.noStake, 10))
		out.WriteString(":" + strconv.FormatInt(convToCC(cs.yesConvHi, cs.yesConvLo), 10))
		out.WriteString(":" + strconv.FormatInt(convToCC(cs.noConvHi, cs.noConvLo), 10))
		out.WriteString(":" + strconv.FormatInt(oi, 10))
		out.WriteString(":" + boolDigit(oiMature))
		out.WriteString(":" + strconv.FormatInt(yes, 10))
		out.WriteString(":" + boolDigit(yesMature))
		sent++
	}
	return out.String()
}
const seriesPageMax = 60
func boolDigit(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
func mustClaim(c *Court, id uint64) *claimState {
	v := c.claims.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such claim")
	}
	return v.(*claimState)
}
func beClaimKey(id uint64) string {
	b := [8]byte{
		byte(id >> 56), byte(id >> 48), byte(id >> 40), byte(id >> 32),
		byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id),
	}
	return string(b[:])
}
