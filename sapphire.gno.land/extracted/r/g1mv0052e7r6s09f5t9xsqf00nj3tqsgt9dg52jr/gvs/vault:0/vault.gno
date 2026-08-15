package vault

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/core"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/mockfarm"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

const wantDenom = "ugnot"

type state struct {
	admin     address
	treasury  address
	paused    bool
	book      *core.Book
	fees      core.FeeConfig
	guard     core.ReinvestGuard
	farm      *mockfarm.Farm
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
		farm:     mockfarm.New(),
	}
}

// Admin is the operator address.
func Admin() address { return g.admin }

// Treasury receives the protocol harvest cut.
func Treasury() address { return g.treasury }

// Paused is true when deposits and harvests are frozen. Withdraw always works.
func Paused() bool { return g.paused }

// TotalAssets is want tokens attributed to depositors.
func TotalAssets() int64 { return g.book.TotalAssets() }

// TotalShares is the outstanding share supply.
func TotalShares() int64 { return g.book.TotalShares() }

// SharesOf is the share balance of addr.
func SharesOf(addr address) int64 { return g.book.SharesOf(addr) }

// PendingYield is harvestable mock profit (donations + seeded yield).
func PendingYield() int64 { return g.farm.Pending() }

// PreviewDeposit returns shares for an asset deposit at the current price.
func PreviewDeposit(assets int64) int64 { return g.book.PreviewDeposit(assets) }

// PreviewRedeem returns assets for a share redemption at the current price.
func PreviewRedeem(shares int64) int64 { return g.book.PreviewRedeem(shares) }

// SharePriceE6 is assets per share * 1e6. Zero supply returns 1e6.
func SharePriceE6() int64 {
	if g.book.TotalShares() == 0 {
		return 1_000_000
	}
	return g.book.PreviewRedeem(1_000_000)
}

// Deposit mints shares against OriginSend ugnot. EOA MsgCall only.
func Deposit(cur realm) int64 {
	mustLive()
	if !cur.Previous().IsUserCall() {
		panic("only EOA via MsgCall can fund this")
	}
	sent := unsafe.OriginSend().AmountOf(wantDenom)
	if sent <= 0 {
		panic("send ugnot")
	}
	caller := cur.Previous().Address()
	shares := g.book.Deposit(caller, sent)
	chain.Emit("Deposit", "user", caller.String(), "assets", strconv.FormatInt(sent, 10), "shares", strconv.FormatInt(shares, 10))
	return shares
}

// Withdraw burns shares and returns ugnot. Always available, even when paused.
func Withdraw(cur realm, shares int64) int64 {
	caller := cur.Previous().Address()
	assets := g.book.Withdraw(caller, shares)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), caller, chain.Coins{{Denom: wantDenom, Amount: assets}})
	chain.Emit("Withdraw", "user", caller.String(), "shares", strconv.FormatInt(shares, 10), "assets", strconv.FormatInt(assets, 10))
	return assets
}

// Donate adds OriginSend ugnot to pending harvest (not immediately to share price).
func Donate(cur realm) {
	mustLive()
	if !cur.Previous().IsUserCall() {
		panic("only EOA via MsgCall can fund this")
	}
	sent := unsafe.OriginSend().AmountOf(wantDenom)
	if sent <= 0 {
		panic("send ugnot")
	}
	g.farm.Accrue(sent)
	chain.Emit("Donate", "user", cur.Previous().Address().String(), "amount", strconv.FormatInt(sent, 10))
}

// Reinvest compounds pending yield. Anyone may call; the caller earns CallerBPS.
func Reinvest(cur realm) int64 {
	mustLive()
	profit := g.farm.Harvest()
	now := time.Now().Unix()
	height := runtime.ChainHeight()
	g.guard.Check(profit, now, height)

	callerAmt, protoAmt, rest := core.SplitHarvest(profit, g.fees)
	if rest > 0 {
		g.book.AddProfit(rest)
	}

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	pkg := cur.Address()
	if callerAmt > 0 {
		bk.SendCoins(pkg, cur.Previous().Address(), chain.Coins{{Denom: wantDenom, Amount: callerAmt}})
	}
	if protoAmt > 0 {
		bk.SendCoins(pkg, g.treasury, chain.Coins{{Denom: wantDenom, Amount: protoAmt}})
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

// TransferAdmin rotates the operator.
func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty admin")
	}
	prev := g.admin
	g.admin = next
	chain.Emit("OwnershipChange", "old", prev.String(), "new", next.String())
}

// SetTreasury sets the protocol-fee recipient.
func SetTreasury(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty treasury")
	}
	g.treasury = next
}

// SetFees updates the harvest split.
func SetFees(cur realm, callerBPS, protocolBPS int64) {
	mustAdmin(cur)
	next := core.FeeConfig{CallerBPS: callerBPS, ProtocolBPS: protocolBPS}
	next.Validate()
	g.fees = next
}

// SetGuard updates min harvest size and interval (seconds).
func SetGuard(cur realm, minProfit, minInterval int64) {
	mustAdmin(cur)
	if minProfit < 0 || minInterval < 0 {
		panic("negative guard")
	}
	g.guard.MinProfit = minProfit
	g.guard.MinInterval = minInterval
}

// SetPaused freezes deposits, donations, and reinvests.
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

// Render is the gnoweb home for the idle ugnot vault.
func Render(path string) string {
	_ = path
	out := "# Gno Vault Strategy — Idle ugnot\n\n"
	out += "Auto-compounder primitive. Deposit ugnot, anyone can `Reinvest`.\n\n"
	out += ufmt.Sprintf("- **TVL**: %d ugnot\n", g.book.TotalAssets())
	out += ufmt.Sprintf("- **Shares**: %d\n", g.book.TotalShares())
	out += ufmt.Sprintf("- **Share price (1e6)**: %d\n", SharePriceE6())
	out += ufmt.Sprintf("- **Pending yield**: %d ugnot\n", g.farm.Pending())
	out += ufmt.Sprintf("- **Fees**: %d bps caller / %d bps protocol\n", g.fees.CallerBPS, g.fees.ProtocolBPS)
	out += "- **Admin**: " + sanitize.InlineText(g.admin.String()) + "\n"
	if g.paused {
		out += "\n> [!WARNING]\n> Vault is paused. Withdraw still works.\n"
	}
	out += "\n<gno-form exec=\"Deposit\">\n<gno-input name=\"\" placeholder=\"send ugnot with the tx\" readonly=\"true\" />\n</gno-form>\n"
	out += "\n<gno-form exec=\"Reinvest\"></gno-form>\n"
	return out
}
