package kourt
import (
	"strconv"
	bptree "gno.land/p/nt/bptree/v0"
)
func lockedOf(c *Court, who address) int64 {
	if c.locked == nil {
		return 0
	}
	if v := c.locked.Get(string(who)); v != nil {
		return v.(int64)
	}
	return 0
}
func spendable(c *Court, who address) int64 {
	s := c.coin.BalanceOf(who) - lockedOf(c, who)
	if s < 0 {
		return 0
	}
	return s
}
func disposable(c *Court, who address) int64 {
	claim := lockedOf(c, who)
	if v := voteLockedOf(c, who); v > claim {
		claim = v
	}
	d := c.coin.BalanceOf(who) - claim
	if d < 0 {
		return 0
	}
	return d
}
func DisposableOf(courtSlug string, who address) int64 {
	return disposable(mustCourt(courtSlug), who)
}
func ccAmt(n int64) string {
	if n < 0 {
		return "-" + ccAmt(-n)
	}
	whole := strconv.FormatInt(n/1_000_000, 10)
	frac := n % 1_000_000
	if frac == 0 {
		return whole
	}
	f := strconv.FormatInt(frac, 10)
	for len(f) < 6 {
		f = "0" + f
	}
	for len(f) > 1 && f[len(f)-1] == '0' {
		f = f[:len(f)-1]
	}
	return whole + "." + f
}
func mustSpendable(c *Court, who address, amount int64) {
	if disposable(c, who) >= amount {
		return
	}
	vl, sl := voteLockedOf(c, who), lockedOf(c, who)
	short := "need " + ccAmt(amount) + " CC, you have " + ccAmt(disposable(c, who))
	switch {
	case vl <= 0 && sl <= 0:
		panic("kourtv2: not enough CC — " + short)
	case vl > sl:
		panic("kourtv2: not enough uncommitted CC — " + short +
			" free; " + ccAmt(vl) + " is committed by voting")
	case sl > vl:
		panic("kourtv2: not enough unstaked CC — " + short +
			" free; " + ccAmt(sl) + " is staked")
	default:
		panic("kourtv2: not enough free CC — " + short +
			" free; " + ccAmt(sl) + " is both staked and committed by voting")
	}
}
func mustStakable(c *Court, who address, amount int64) {
	if s := spendable(c, who); s < amount {
		tail := ""
		if l := lockedOf(c, who); l > 0 {
			tail = "; " + ccAmt(l) + " is staked"
		}
		panic("kourtv2: not enough unstaked CC — need " + ccAmt(amount) +
			" CC, you have " + ccAmt(s) + tail)
	}
}
func lockStake(c *Court, who address, amount int64) {
	if amount <= 0 {
		return
	}
	if c.locked == nil {
		c.locked = bptree.NewBPTree32()
	}
	c.locked.Set(string(who), mustAdd(lockedOf(c, who), amount))
}
func releaseStake(c *Court, who address, amount int64) {
	if amount <= 0 {
		return
	}
	l := lockedOf(c, who)
	if amount > l {
		panic("kourtv2: releasing more stake than is locked")
	}
	if amount == l {
		c.locked.Remove(string(who))
		return
	}
	c.locked.Set(string(who), l-amount)
}
func LockedOf(courtSlug string, who address) int64 {
	return lockedOf(mustCourt(courtSlug), who)
}
func SpendableOf(courtSlug string, who address) int64 {
	return spendable(mustCourt(courtSlug), who)
}
func TransferCC(cur realm, courtSlug string, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount <= 0 {
		panic("kourtv2: transfer amount must be positive")
	}
	from := cur.Previous().Address()
	if from == to {
		panic("kourtv2: cannot transfer to yourself")
	}
	c := mustCourt(courtSlug)
	if to == c.escrow || from == c.escrow {
		panic("kourtv2: the court escrow is not a transfer endpoint")
	}
	touch(c)
	mustSpendable(c, from, amount)
	c.coin.Transfer(from, to, amount)
}
func ApproveCC(cur realm, courtSlug string, spender address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount < 0 {
		panic("kourtv2: negative allowance")
	}
	c := mustCourt(courtSlug)
	owner := cur.Previous().Address()
	if spender == c.escrow || owner == c.escrow {
		panic("kourtv2: the court escrow is not a transfer endpoint")
	}
	touch(c)
	c.coin.Approve(owner, spender, amount)
}
func TransferFromCC(cur realm, courtSlug string, from, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount <= 0 {
		panic("kourtv2: transfer amount must be positive")
	}
	if from == to {
		panic("kourtv2: cannot transfer to yourself")
	}
	c := mustCourt(courtSlug)
	if to == c.escrow || from == c.escrow {
		panic("kourtv2: the court escrow is not a transfer endpoint")
	}
	touch(c)
	mustSpendable(c, from, amount)
	c.coin.TransferFrom(cur.Previous().Address(), from, to, amount)
}
func AllowanceCC(courtSlug string, owner, spender address) int64 {
	return mustCourt(courtSlug).coin.Allowance(owner, spender)
}
