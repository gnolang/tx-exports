package kourt
import (
	"chain"
	"strconv"
)
const (
	seniorEnqueuedEvent = "SeniorEnqueued"
	seniorPaidEvent     = "SeniorPaid"
)
type entitlement struct {
	to      address
	amount  int64
	start   int64
	paid    int64
	purpose string
}
func touch(c *Court) {
	now := heightNow()
	for c.lastAccrual < now {
		boundary := c.createdAt + (c.periodIndex+1)*periodBlocks
		segEnd := now
		if boundary < segEnd {
			segEnd = boundary
		}
		accrueSegment(c, segEnd-c.lastAccrual)
		advanceRateAcc(c, segEnd-c.lastAccrual)
		c.lastAccrual = segEnd
		if segEnd == boundary {
			rollPeriod(c)
		}
	}
}
func accrueSegment(c *Court, blocks int64) {
	if blocks <= 0 || c.curPeriodBudget <= 0 {
		return
	}
	if c.reservoirR() >= c.rMax() && c.cumAccrual >= c.reservedTail {
		return
	}
	num := mustAdd(mustMul(c.curPeriodBudget, blocks), c.accrualRem)
	c.cumAccrual = mustAdd(c.cumAccrual, num/periodBlocks)
	c.accrualRem = num % periodBlocks
}
func advanceRateAcc(c *Court, blocks int64) {
	if blocks <= 0 {
		return
	}
	c.rateAccFP = mustAdd(c.rateAccFP, mustMul(rateBpsFP(c), blocks))
}
func rollPeriod(c *Court) {
	c.periodIndex++
	c.curBudgetBpsFP = c.curBudgetBpsFP * stepDownNum / stepDownDen
	minted := c.emittedTotal - c.emittedAtRoll
	c.emittedAtRoll = c.emittedTotal
	c.emaMinted = (3*c.emaMinted + minted) / 4
	s := c.coin.TotalSupply()
	if s > 0 {
		if c.emaMinted < 0 {
			panic("kourtv2: negative realized mint")
		}
		dReal := mulDiv128(c.emaMinted, 10_000*1_000_000, s)
		if dReal < c.curBudgetBpsFP {
			c.dEffBpsFP = dReal
		} else {
			c.dEffBpsFP = c.curBudgetBpsFP
		}
		if c.absBudget > 0 {
			c.absBudget = c.absBudget * stepDownNum / stepDownDen
			c.curPeriodBudget = c.absBudget
		} else {
			c.curPeriodBudget = mulDiv128(s, c.curBudgetBpsFP, 10_000*1_000_000)
		}
	} else {
		c.dEffBpsFP = 0
		c.curPeriodBudget = 0
	}
}
func (c *Court) reservoirR() int64 {
	past := c.cumAccrual - c.reservedTail
	if past < 0 {
		past = 0
	}
	r := past - c.juniorReserved
	if r < 0 {
		r = 0
	}
	return r
}
func (c *Court) rMax() int64 { return rMaxPeriods * c.curPeriodBudget }
func enqueueSenior(c *Court, to address, amount int64, purpose string) uint64 {
	if amount <= 0 {
		panic("kourtv2: a senior entitlement must be positive")
	}
	start := mustAdd(c.reservedTail, c.juniorReserved)
	e := &entitlement{to: to, amount: amount, start: start, purpose: purpose}
	c.reservedTail = mustAdd(c.reservedTail, amount)
	c.seniorOwed = mustAdd(c.seniorOwed, amount)
	c.queueSeq++
	c.queue.Set(beClaimKey(c.queueSeq), e)
	chain.Emit(seniorEnqueuedEvent,
		"court", c.id,
		"seq", strconv.FormatUint(c.queueSeq, 10),
		"to", to.String(),
		"amount", strconv.FormatInt(amount, 10),
		"purpose", purpose,
	)
	return c.queueSeq
}
func reserveJunior(c *Court, want int64) int64 {
	touch(c)
	r := c.reservoirR()
	if want > r {
		want = r
	}
	if want < 0 {
		want = 0
	}
	c.juniorReserved = mustAdd(c.juniorReserved, want)
	return want
}
func mintEmission(c *Court, to address, amount int64) {
	if amount <= 0 {
		return
	}
	c.coin.Mint(to, amount)
	c.emittedTotal = mustAdd(c.emittedTotal, amount)
}
func PullSenior(cur realm, courtSlug string, seq uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	touch(c)
	v := c.queue.Get(beClaimKey(seq))
	if v == nil {
		panic("kourtv2: no such entitlement")
	}
	e := v.(*entitlement)
	covered := c.cumAccrual - e.start
	if covered > e.amount {
		covered = e.amount
	}
	pay := covered - e.paid
	if pay <= 0 {
		return 0
	}
	e.paid += pay
	c.seniorOwed -= pay
	c.seniorPaid = mustAdd(c.seniorPaid, pay)
	mintEmission(c, e.to, pay)
	chain.Emit(seniorPaidEvent,
		"court", c.id,
		"seq", strconv.FormatUint(seq, 10),
		"to", e.to.String(),
		"paid", strconv.FormatInt(pay, 10),
		"remaining", strconv.FormatInt(e.amount-e.paid, 10),
	)
	return pay
}
func Reservoir(courtSlug string) int64  { return mustCourt(courtSlug).reservoirR() }
func SeniorOwed(courtSlug string) int64 { return mustCourt(courtSlug).seniorOwed }
func SeniorEntitlement(courtSlug string, seq uint64) (to address, amount, paid, payable int64) {
	c := mustCourt(courtSlug)
	v := c.queue.Get(beClaimKey(seq))
	if v == nil {
		panic("kourtv2: no such entitlement")
	}
	e := v.(*entitlement)
	covered := c.cumAccrual - e.start
	if covered > e.amount {
		covered = e.amount
	}
	p := covered - e.paid
	if p < 0 {
		p = 0
	}
	return e.to, e.amount, e.paid, p
}
func QueueLen(courtSlug string) uint64 { return mustCourt(courtSlug).queueSeq }
func Poke(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	touch(mustCourt(courtSlug))
}
