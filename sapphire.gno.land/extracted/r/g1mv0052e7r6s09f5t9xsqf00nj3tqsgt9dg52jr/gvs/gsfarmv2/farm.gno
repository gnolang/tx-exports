package gsfarmv2

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/alloc"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/core"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Phase 1 machine: WUGNOT deposits, 15% idle buffer, rest in GnoSwap
// GNS/WUGNOT LP. Reinvest collects LP fees and redeploys. Withdraw
// unwinds the LP if the buffer is too small.

type state struct {
	admin          address
	treasury       address
	self           address
	paused         bool
	book           *core.Book
	fees           core.FeeConfig
	guard          core.ReinvestGuard
	bufferBPS      int64
	positionID     uint64
	protocolEarned int64
	lastHarvest    int64
	lastDeployed   int64
}

var g *state

func init() {
	deployer := unsafe.OriginCaller()
	g = &state{
		admin:     deployer,
		treasury:  deployer,
		self:      unsafe.CurrentRealm().Address(),
		book:      core.NewBook(),
		fees:      core.DefaultFees(),
		guard:     core.DefaultGuard(),
		bufferBPS: alloc.DefaultBufferBPS,
	}
	g.guard.MinProfit = 0
}

func Admin() address            { return g.admin }
func Treasury() address         { return g.treasury }
func VaultAddress() address     { return g.self }
func Paused() bool              { return g.paused }
func TotalAssets() int64        { return g.book.TotalAssets() }
func TotalShares() int64        { return g.book.TotalShares() }
func SharesOf(a address) int64  { return g.book.SharesOf(a) }
func PreviewDeposit(a int64) int64 { return g.book.PreviewDeposit(a) }
func PreviewRedeem(s int64) int64  { return g.book.PreviewRedeem(s) }
func Want() string              { return liveWugnotKey }
func IdleWugnot() int64         { return idleWugnot() }
func PendingGns() int64         { return pendingGns() }
func PositionID() uint64        { return g.positionID }
func ProtocolEarned() int64     { return g.protocolEarned }
func LastHarvest() int64        { return g.lastHarvest }
func BufferBPS() int64          { return g.bufferBPS }

func SharePriceE6() int64 {
	if g.book.TotalShares() == 0 {
		return 1_000_000
	}
	return g.book.PreviewRedeem(1_000_000)
}

func TargetIdleWugnot() int64 {
	return alloc.TargetIdle(g.book.TotalAssets(), g.bufferBPS)
}

func Deposit(cur realm, amount int64) int64 {
	mustLive()
	if amount <= 0 {
		panic("amount must be positive")
	}
	caller := cur.Previous().Address()
	pullWugnot(cur, caller, amount)
	shares := g.book.Deposit(caller, amount)
	chain.Emit("Deposit", "user", caller.String(), "assets", strconv.FormatInt(amount, 10), "shares", strconv.FormatInt(shares, 10))
	return shares
}

func Withdraw(cur realm, shares int64) int64 {
	caller := cur.Previous().Address()
	assets := g.book.Withdraw(caller, shares)
	ensureIdle(cur, assets)
	pushWugnot(cur, caller, assets)
	chain.Emit("Withdraw", "user", caller.String(), "shares", strconv.FormatInt(shares, 10), "assets", strconv.FormatInt(assets, 10))
	return assets
}

// Reinvest collects GnoSwap LP fees, compounds WUGNOT, then redeploys
// idle capital above the buffer into the LP.
func Reinvest(cur realm) int64 {
	mustLive()
	now := time.Now().Unix()
	height := runtime.ChainHeight()
	if g.guard.LastHeight != 0 && height <= g.guard.LastHeight {
		panic("reinvest too soon")
	}

	profit := harvestLP(cur)
	rest := int64(0)
	if profit > 0 {
		callerAmt, protoAmt, compound := core.SplitHarvest(profit, g.fees)
		if compound > 0 {
			g.book.AddProfit(compound)
		}
		if callerAmt > 0 {
			pushWugnot(cur, cur.Previous().Address(), callerAmt)
		}
		if protoAmt > 0 {
			pushWugnot(cur, g.treasury, protoAmt)
			next, ok := addEarned(g.protocolEarned, protoAmt)
			if !ok {
				panic("protocol earned overflow")
			}
			g.protocolEarned = next
		}
		rest = compound
		g.lastHarvest = profit
		chain.Emit("Reinvest",
			"caller", cur.Previous().Address().String(),
			"profit", strconv.FormatInt(profit, 10),
			"compound", strconv.FormatInt(compound, 10),
			"protocol", strconv.FormatInt(protoAmt, 10),
		)
	}

	deployed := rebalance(cur)
	g.lastDeployed = deployed
	g.guard.LastUnix = now
	g.guard.LastHeight = height
	if profit == 0 && deployed == 0 {
		panic("nothing to harvest or deploy")
	}
	return rest
}

func SetBufferBPS(cur realm, bps int64) {
	mustAdmin(cur)
	if bps < 500 || bps > 5_000 {
		panic("buffer must be 5%-50%")
	}
	g.bufferBPS = bps
}

func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty admin")
	}
	g.admin = next
}

func SetTreasury(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty treasury")
	}
	g.treasury = next
}

func SetFees(cur realm, callerBPS, protocolBPS int64) {
	mustAdmin(cur)
	next := core.FeeConfig{CallerBPS: callerBPS, ProtocolBPS: protocolBPS}
	next.Validate()
	g.fees = next
}

func SetPaused(cur realm, next bool) {
	mustAdmin(cur)
	g.paused = next
}

func mustAdmin(cur realm) {
	if cur.Previous().Address() != g.admin {
		panic("admin only")
	}
}

func mustLive() {
	if g.paused {
		panic("paused")
	}
}

func addEarned(a, b int64) (int64, bool) {
	if a > 0 && b > 9223372036854775807-a {
		return 0, false
	}
	return a + b, true
}

func Render(path string) string {
	_ = path
	out := "# Gno Vault Strategy — Phase 1 LP farm\n\n"
	out += "WUGNOT in. 15% idle buffer. Rest in GnoSwap GNS/WUGNOT LP. Reinvest collects swap fees.\n\n"
	out += ufmt.Sprintf("- **TVL (book)**: %d wugnot\n", g.book.TotalAssets())
	out += ufmt.Sprintf("- **Idle buffer**: %d (target %d)\n", idleWugnot(), TargetIdleWugnot())
	out += ufmt.Sprintf("- **Pending GNS**: %d\n", pendingGns())
	out += ufmt.Sprintf("- **Share price (1e6)**: %d\n", SharePriceE6())
	out += ufmt.Sprintf("- **Shares**: %d\n", g.book.TotalShares())
	out += ufmt.Sprintf("- **LP position**: %d\n", g.positionID)
	out += ufmt.Sprintf("- **Protocol earned**: %d wugnot\n", g.protocolEarned)
	out += ufmt.Sprintf("- **Last harvest**: %d wugnot\n", g.lastHarvest)
	out += "- **Vault**: " + sanitize.InlineText(g.self.String()) + "\n"
	out += "- **Admin**: " + sanitize.InlineText(g.admin.String()) + "\n"
	return out
}
