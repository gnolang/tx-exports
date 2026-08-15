package gnoswap

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/core"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/gsconfig"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// First-protocol strategy: GnoSwap. User API matches r/gvs/vault so a later
// allocator vault can treat every adapter the same.
//
// pullWant / pushWant / harvestProtocol / wantBalance are provided by
// harvest_local.gno (tests / idle) or harvest_sapphire.gno (live Sapphire).

type state struct {
	admin     address
	treasury  address
	paused    bool
	book      *core.Book
	fees      core.FeeConfig
	guard     core.ReinvestGuard
	cfg       gsconfig.Config
	positions avl.Tree
}

var g *state

func init() {
	deployer := unsafe.OriginCaller()
	g = &state{
		admin:    deployer,
		treasury: deployer,
		book:     core.NewBook(),
		fees:     core.DefaultFees(),
		guard:    core.DefaultGuard(),
		cfg:      gsconfig.DefaultConfig(),
	}
}

func Admin() address      { return g.admin }
func Treasury() address   { return g.treasury }
func Paused() bool        { return g.paused }
func TotalAssets() int64  { return g.book.TotalAssets() }
func TotalShares() int64  { return g.book.TotalShares() }
func SharesOf(a address) int64 { return g.book.SharesOf(a) }
func PreviewDeposit(a int64) int64 { return g.book.PreviewDeposit(a) }
func PreviewRedeem(s int64) int64  { return g.book.PreviewRedeem(s) }
func PendingYield() int64 { return pendingProtocol() }
func Want() string        { return g.cfg.WantToken }
func Route() string       { return g.cfg.Route }

func SharePriceE6() int64 {
	if g.book.TotalShares() == 0 {
		return 1_000_000
	}
	return g.book.PreviewRedeem(1_000_000)
}

// Deposit pulls `amount` of the adapter want token and mints shares.
func Deposit(cur realm, amount int64) int64 {
	mustLive()
	if amount <= 0 {
		panic("amount must be positive")
	}
	caller := cur.Previous().Address()
	pullWant(cur, caller, amount)
	shares := g.book.Deposit(caller, amount)
	chain.Emit("Deposit", "user", caller.String(), "assets", strconv.FormatInt(amount, 10), "shares", strconv.FormatInt(shares, 10))
	return shares
}

// Withdraw burns shares and pushes want tokens back to the caller.
func Withdraw(cur realm, shares int64) int64 {
	caller := cur.Previous().Address()
	assets := g.book.Withdraw(caller, shares)
	pushWant(cur, caller, assets)
	chain.Emit("Withdraw", "user", caller.String(), "shares", strconv.FormatInt(shares, 10), "assets", strconv.FormatInt(assets, 10))
	return assets
}

// Reinvest harvests the adapter (GnoSwap collect+swap on Sapphire) and compounds.
func Reinvest(cur realm) int64 {
	mustLive()
	profit := harvestProtocol(cur)
	now := time.Now().Unix()
	height := runtime.ChainHeight()
	g.guard.Check(profit, now, height)

	callerAmt, protoAmt, rest := core.SplitHarvest(profit, g.fees)
	if rest > 0 {
		g.book.AddProfit(rest)
	}
	if callerAmt > 0 {
		pushWant(cur, cur.Previous().Address(), callerAmt)
	}
	if protoAmt > 0 {
		pushWant(cur, g.treasury, protoAmt)
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

// AttachPosition records a GnoSwap staked position NFT this vault owns.
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

// DetachPosition drops a tracked position id (does not unstake on GnoSwap).
func DetachPosition(cur realm, positionID uint64) {
	mustAdmin(cur)
	key := strconv.FormatUint(positionID, 10)
	if !g.positions.Has(key) {
		panic("unknown position")
	}
	g.positions.Remove(key)
}

// PositionIDs lists attached GnoSwap position ids.
func PositionIDs() []uint64 {
	out := make([]uint64, 0, g.positions.Size())
	g.positions.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(uint64))
		return false
	})
	return out
}

// SetRoute updates the harvest swap route (tokenIn:tokenOut:fee).
func SetRoute(cur realm, route string, amountOutMin int64, fee uint32) {
	mustAdmin(cur)
	if route == "" {
		panic("empty route")
	}
	g.cfg.Route = route
	g.cfg.AmountOutMin = amountOutMin
	if fee != 0 {
		g.cfg.Fee = fee
	}
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
	out := "# Gno Vault Strategy — GnoSwap\n\n"
	out += "First DeFi adapter. Harvest collects staked-position rewards and swaps them to the want token via GnoSwap router.\n\n"
	out += ufmt.Sprintf("- **Want**: `%s`\n", sanitize.InlineText(g.cfg.WantToken))
	out += ufmt.Sprintf("- **Reward**: `%s`\n", sanitize.InlineText(g.cfg.RewardToken))
	out += ufmt.Sprintf("- **Route**: `%s`\n", sanitize.InlineText(g.cfg.Route))
	out += ufmt.Sprintf("- **TVL**: %d\n", g.book.TotalAssets())
	out += ufmt.Sprintf("- **Shares**: %d\n", g.book.TotalShares())
	out += ufmt.Sprintf("- **Share price (1e6)**: %d\n", SharePriceE6())
	out += ufmt.Sprintf("- **Pending**: %d\n", pendingProtocol())
	out += ufmt.Sprintf("- **Positions**: %d\n", g.positions.Size())
	out += "- **Admin**: " + sanitize.InlineText(g.admin.String()) + "\n"
	if g.paused {
		out += "\n> [!WARNING]\n> Strategy is paused. Withdraw still works.\n"
	}
	return out
}
