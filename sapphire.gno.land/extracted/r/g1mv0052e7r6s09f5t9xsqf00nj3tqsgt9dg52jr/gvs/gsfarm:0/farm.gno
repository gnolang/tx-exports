package gsfarm

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/core"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Live GnoSwap farm. Deposits are WUGNOT. Reinvest collects GNS (and LP fees
// from attached positions) then swaps GNS to WUGNOT on the real router.

type state struct {
	admin     address
	treasury  address
	self      address
	paused    bool
	book      *core.Book
	fees      core.FeeConfig
	guard     core.ReinvestGuard
	positions avl.Tree
	route     string
	minOut    int64
}

var g *state

func init() {
	deployer := unsafe.OriginCaller()
	g = &state{
		admin:    deployer,
		treasury: deployer,
		self:     unsafe.CurrentRealm().Address(),
		book:     core.NewBook(),
		fees:     core.DefaultFees(),
		guard:    core.DefaultGuard(),
		route:    liveGnsToWugnot,
	}
}

func Admin() address               { return g.admin }
func Treasury() address            { return g.treasury }
func VaultAddress() address        { return g.self }
func Paused() bool                 { return g.paused }
func TotalAssets() int64           { return g.book.TotalAssets() }
func TotalShares() int64           { return g.book.TotalShares() }
func SharesOf(a address) int64     { return g.book.SharesOf(a) }
func PreviewDeposit(a int64) int64 { return g.book.PreviewDeposit(a) }
func PreviewRedeem(s int64) int64  { return g.book.PreviewRedeem(s) }
func PendingYield() int64          { return pendingGns() }
func Want() string                 { return liveWugnotKey }
func Route() string                { return g.route }
func IdleWugnot() int64            { return idleWugnot() }
func PendingGns() int64            { return pendingGns() }

func SharePriceE6() int64 {
	if g.book.TotalShares() == 0 {
		return 1_000_000
	}
	return g.book.PreviewRedeem(1_000_000)
}

// Deposit pulls WUGNOT the user already approved and mints shares.
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

// Withdraw burns shares and returns WUGNOT.
func Withdraw(cur realm, shares int64) int64 {
	caller := cur.Previous().Address()
	assets := g.book.Withdraw(caller, shares)
	pushWugnot(cur, caller, assets)
	chain.Emit("Withdraw", "user", caller.String(), "shares", strconv.FormatInt(shares, 10), "assets", strconv.FormatInt(assets, 10))
	return assets
}

// Reinvest collects GnoSwap rewards/fees, swaps GNS to WUGNOT, then compounds.
func Reinvest(cur realm) int64 {
	mustLive()
	profit := harvestGnoswap(cur)
	now := time.Now().Unix()
	height := runtime.ChainHeight()
	g.guard.Check(profit, now, height)

	callerAmt, protoAmt, rest := core.SplitHarvest(profit, g.fees)
	if rest > 0 {
		g.book.AddProfit(rest)
	}
	if callerAmt > 0 {
		pushWugnot(cur, cur.Previous().Address(), callerAmt)
	}
	if protoAmt > 0 {
		pushWugnot(cur, g.treasury, protoAmt)
	}
	g.guard.LastUnix = now
	g.guard.LastHeight = height
	chain.Emit("Reinvest",
		"caller", cur.Previous().Address().String(),
		"profit", strconv.FormatInt(profit, 10),
		"compound", strconv.FormatInt(rest, 10),
	)
	return rest
}

// AttachPosition records a GnoSwap position NFT this vault owns.
func AttachPosition(cur realm, positionID uint64) {
	mustAdmin(cur)
	if positionID == 0 {
		panic("position id")
	}
	key := strconv.FormatUint(positionID, 10)
	if g.positions.Has(key) {
		panic("already attached")
	}
	g.positions.Set(key, positionID)
	chain.Emit("AttachPosition", "id", key)
}

func DetachPosition(cur realm, positionID uint64) {
	mustAdmin(cur)
	key := strconv.FormatUint(positionID, 10)
	if !g.positions.Has(key) {
		panic("unknown position")
	}
	g.positions.Remove(key)
}

func PositionIDs() []uint64 {
	out := make([]uint64, 0, g.positions.Size())
	g.positions.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(uint64))
		return false
	})
	return out
}

func SetRoute(cur realm, route string, amountOutMin int64) {
	mustAdmin(cur)
	if route == "" {
		panic("empty route")
	}
	g.route = route
	g.minOut = amountOutMin
}

func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty admin")
	}
	prev := g.admin
	g.admin = next
	chain.Emit("OwnershipChange", "old", prev.String(), "new", next.String())
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

func SetGuard(cur realm, minProfit, minInterval int64) {
	mustAdmin(cur)
	if minProfit < 0 || minInterval < 0 {
		panic("negative guard")
	}
	g.guard.MinProfit = minProfit
	g.guard.MinInterval = minInterval
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

func Render(path string) string {
	_ = path
	out := "# Gno Vault Strategy — GnoSwap farm\n\n"
	out += "Real harvest: collect GNS / LP fees, swap to WUGNOT on GnoSwap router.\n\n"
	out += ufmt.Sprintf("- **Want**: `%s`\n", sanitize.InlineText(liveWugnotKey))
	out += ufmt.Sprintf("- **Reward**: `%s`\n", sanitize.InlineText(liveGnsKey))
	out += ufmt.Sprintf("- **Route**: `%s`\n", sanitize.InlineText(g.route))
	out += ufmt.Sprintf("- **TVL (book)**: %d wugnot\n", g.book.TotalAssets())
	out += ufmt.Sprintf("- **Idle WUGNOT**: %d\n", idleWugnot())
	out += ufmt.Sprintf("- **Pending GNS**: %d\n", pendingGns())
	out += ufmt.Sprintf("- **Shares**: %d\n", g.book.TotalShares())
	out += ufmt.Sprintf("- **Share price (1e6)**: %d\n", SharePriceE6())
	out += ufmt.Sprintf("- **Positions**: %d\n", g.positions.Size())
	out += "- **Vault**: " + sanitize.InlineText(g.self.String()) + "\n"
	out += "- **Admin**: " + sanitize.InlineText(g.admin.String()) + "\n"
	return out
}
