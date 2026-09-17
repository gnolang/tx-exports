package kourt
import (
	"math/bits"
	"math/overflow"
)
const r0WeeklyBps = int64(25)
const (
	stepDownNum = int64(9_933_575)
	stepDownDen = int64(10_000_000)
)
const budgetBpsFPStart = budgetWeeklyBps * 1_000_000
type stakePos struct {
	stake       int64
	convHi      uint64
	convLo      uint64
	lastRateAcc int64
	rawHi, rawLo uint64
	lastRawAt    int64
	bonusPaid    bool
}
func rateBpsFP(c *Court) int64 {
	return 255 * (r0WeeklyBps*1_000_000 + c.dEffBpsFP) / 100
}
func effectiveRateAcc(c *Court, cs *claimState) int64 {
	acc := c.rateAccFP
	if cs.frozenAt != 0 && cs.rateAccAtFreeze < acc {
		acc = cs.rateAccAtFreeze
	}
	return acc
}
func accrue(c *Court, cs *claimState, p *stakePos, side int) {
	acc := effectiveRateAcc(c, cs)
	delta := acc - p.lastRateAcc
	p.lastRateAcc = acc
	if delta > 0 && p.stake > 0 {
		hi, lo := bits.Mul64(uint64(p.stake), uint64(delta))
		p.convHi, p.convLo = add128(p.convHi, p.convLo, hi, lo)
	}
	rh := rawHeight(cs)
	rawDelta := rh - p.lastRawAt
	p.lastRawAt = rh
	if rawDelta > 0 && p.stake > 0 {
		hi, lo := bits.Mul64(uint64(p.stake), uint64(rawDelta))
		p.rawHi, p.rawLo = add128(p.rawHi, p.rawLo, hi, lo)
	}
	_ = side
}
func advancePools(c *Court, cs *claimState) {
	acc := effectiveRateAcc(c, cs)
	rh := rawHeight(cs)
	if d := acc - cs.yesLastAcc; d > 0 && cs.yesStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.yesStake), uint64(d))
		cs.yesConvHi, cs.yesConvLo = add128(cs.yesConvHi, cs.yesConvLo, hi, lo)
	}
	if d := acc - cs.noLastAcc; d > 0 && cs.noStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.noStake), uint64(d))
		cs.noConvHi, cs.noConvLo = add128(cs.noConvHi, cs.noConvLo, hi, lo)
	}
	if d := rh - cs.yesLastRawAt; d > 0 && cs.yesStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.yesStake), uint64(d))
		cs.yesRawHi, cs.yesRawLo = add128(cs.yesRawHi, cs.yesRawLo, hi, lo)
	}
	if d := rh - cs.noLastRawAt; d > 0 && cs.noStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.noStake), uint64(d))
		cs.noRawHi, cs.noRawLo = add128(cs.noRawHi, cs.noRawLo, hi, lo)
	}
	cs.yesLastAcc, cs.noLastAcc = acc, acc
	cs.yesLastRawAt, cs.noLastRawAt = rh, rh
}
func rawHeight(cs *claimState) int64 {
	h := heightNow()
	if cs.frozenAt != 0 && cs.frozenAt < h {
		h = cs.frozenAt
	}
	return h
}
func lifeAvgStake(cs *claimState, now int64) int64 {
	hi, lo := add128(cs.yesRawHi, cs.yesRawLo, cs.noRawHi, cs.noRawLo)
	den := now - cs.openedAt
	if den < 1 {
		den = 1
	}
	return div128(hi, lo, den)
}
func Stake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if amount <= 0 {
		panic("kourtv2: stake must be positive")
	}
	if cs.closed {
		panic("kourtv2: this claim is closed")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: staking is frozen — this claim has an answer")
	}
	if passed, known := pastDeadline(cs.openedAtTime, blocksToSecs(c.params.stakeOpenDelayBlocks)); (known && !passed) ||
		(!known && heightNow() < cs.openedAt+c.params.stakeOpenDelayBlocks) {
		panic("kourtv2: the polish window is open; staking has not started yet")
	}
	touch(c)
	mustStakable(c, who, amount)
	lockStake(c, who, amount)
	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	accrue(c, cs, p, side)
	p.stake = mustAdd(p.stake, amount)
	if side == sideYES {
		cs.yesStake = mustAdd(cs.yesStake, amount)
	} else {
		cs.noStake = mustAdd(cs.noStake, amount)
	}
	observePools(cs)
	recordPools(c, cs)
}
func Unstake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if amount <= 0 {
		panic("kourtv2: unstake must be positive")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: stakes are frozen — withdraw at settlement (principal is never withheld)")
	}
	touch(c)
	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	if p.stake < amount {
		panic("kourtv2: unstaking more than is staked")
	}
	accrue(c, cs, p, side)
	if amount > 0 && p.stake > 0 {
		keep := p.stake - amount
		convPer := div128(p.convHi, p.convLo, p.stake)
		nCHi, nCLo := bits.Mul64(uint64(convPer), uint64(keep))
		dCHi, dCLo := sub128(p.convHi, p.convLo, nCHi, nCLo)
		p.convHi, p.convLo = nCHi, nCLo
		if side == sideYES {
			cs.yesConvHi, cs.yesConvLo = sub128(cs.yesConvHi, cs.yesConvLo, dCHi, dCLo)
		} else {
			cs.noConvHi, cs.noConvLo = sub128(cs.noConvHi, cs.noConvLo, dCHi, dCLo)
		}
	}
	p.stake -= amount
	releaseStake(c, who, amount)
	if side == sideYES {
		cs.yesStake -= amount
	} else {
		cs.noStake -= amount
	}
	observePools(cs)
	recordPools(c, cs)
}
func observePools(cs *claimState) {
	h := heightNow()
	cs.oi = cs.oi.Observe(h, mustAdd(cs.yesStake, cs.noStake))
	cs.yes = cs.yes.Observe(h, cs.yesStake)
}
func StakeOf(courtSlug string, claimID uint64, side int, who address) int64 {
	mustSide(side)
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if v := cs.stakers.Get(posKey(who, side)); v != nil {
		return v.(*stakePos).stake
	}
	return 0
}
func ConvictionOf(courtSlug string, claimID uint64, side int, who address) int64 {
	mustSide(side)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	v := cs.stakers.Get(posKey(who, side))
	if v == nil {
		return 0
	}
	return convPreviewCC(cs, v.(*stakePos), ratePreview(c))
}
func ratePreview(c *Court) int64 {
	acc := c.rateAccFP
	if tail := heightNow() - c.lastAccrual; tail > 0 {
		acc = mustAdd(acc, mustMul(rateBpsFP(c), tail))
	}
	return acc
}
func convPreviewCC(cs *claimState, p *stakePos, acc int64) int64 {
	if cs.frozenAt != 0 && cs.rateAccAtFreeze < acc {
		acc = cs.rateAccAtFreeze
	}
	hi, lo := p.convHi, p.convLo
	if delta := acc - p.lastRateAcc; delta > 0 && p.stake > 0 {
		mh, ml := bits.Mul64(uint64(p.stake), uint64(delta))
		hi, lo = add128(hi, lo, mh, ml)
	}
	return convToCC(hi, lo)
}
func convToCC(hi, lo uint64) int64 {
	den := uint64(periodBlocks) * 10_000 * 1_000_000
	if hi >= den {
		panic("kourtv2: conviction exceeds payable range")
	}
	q, _ := bits.Div64(hi, lo, den)
	return int64(q)
}
func getPos(c *Court, cs *claimState, who address, side int) *stakePos {
	k := posKey(who, side)
	if v := cs.stakers.Get(k); v != nil {
		return v.(*stakePos)
	}
	p := &stakePos{lastRateAcc: c.rateAccFP, lastRawAt: rawHeight(cs)}
	cs.stakers.Set(k, p)
	indexPosition(c, cs.id, who, side)
	return p
}
func posKey(who address, side int) string {
	if side == sideYES {
		return string(who) + "|y"
	}
	return string(who) + "|n"
}
func mustSide(side int) {
	if side != sideYES && side != sideNO {
		panic("kourtv2: side is 0 (YES) or 1 (NO)")
	}
}
func mustMul(a, b int64) int64 {
	m, ok := overflow.Mul64(a, b)
	if !ok {
		panic("kourtv2: multiply overflow")
	}
	return m
}
func mulDiv128(a, b, den int64) int64 {
	if a < 0 || b < 0 || den <= 0 {
		panic("kourtv2: mulDiv128 domain")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(den) {
		panic("kourtv2: mulDiv128 quotient overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(den))
	if q > 9223372036854775807 {
		panic("kourtv2: mulDiv128 quotient exceeds int64")
	}
	return int64(q)
}
func mustAdd(a, b int64) int64 {
	s, ok := overflow.Add64(a, b)
	if !ok {
		panic("kourtv2: amount overflow")
	}
	return s
}
func sub128(aHi, aLo, bHi, bLo uint64) (hi, lo uint64) {
	if aHi < bHi || (aHi == bHi && aLo < bLo) {
		panic("kourtv2: 128-bit conviction underflow")
	}
	lo = aLo - bLo
	hi = aHi - bHi
	if aLo < bLo {
		hi--
	}
	return hi, lo
}
func add128(aHi, aLo, bHi, bLo uint64) (hi, lo uint64) {
	lo = aLo + bLo
	carry := uint64(0)
	if lo < aLo {
		carry = 1
	}
	hi = aHi + bHi + carry
	if hi < aHi || (hi == aHi && carry == 1 && bHi == ^uint64(0)) {
		panic("kourtv2: 128-bit conviction overflow")
	}
	return hi, lo
}
