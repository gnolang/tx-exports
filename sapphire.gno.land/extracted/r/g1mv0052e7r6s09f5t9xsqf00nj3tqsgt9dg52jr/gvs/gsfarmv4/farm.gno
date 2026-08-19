package gsfarmv4

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/alloc"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/corev2"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/poolkey"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Multi-pool WUGNOT factory. Each GnoSwap WUGNOT pair gets its own share
// book and LP position inside this realm. Opening a missing pool is
// Ensure / first Deposit — not a new MsgAddPackage (Gno cannot addpkg
// from a realm). v3 and earlier stay frozen on their paths.

type slot struct {
	spec           poolkey.Spec
	book           *corev2.Book
	cash           int64
	lpHeld         int64
	positionID     uint64
	protocolEarned int64
	lastHarvest    int64
	lastDeployed   int64
	guard          corev2.ReinvestGuard
}

type state struct {
	admin     address
	treasury  address
	self      address
	paused    bool
	bufferBPS int64
	fees      corev2.FeeConfig
	byPool    avl.Tree
}

var g *state

func init() {
	deployer := unsafe.OriginCaller()
	g = newState(deployer, unsafe.CurrentRealm().Address())
}

func newState(admin, self address) *state {
	return &state{
		admin:     admin,
		treasury:  admin,
		self:      self,
		bufferBPS: alloc.DefaultBufferBPS,
		fees:      corev2.DefaultFees(),
	}
}

func IsFactory() bool { return true }
func Admin() address  { return g.admin }
func Treasury() address { return g.treasury }
func VaultAddress() address { return g.self }
func Paused() bool    { return g.paused }
func BufferBPS() int64 { return g.bufferBPS }
func Count() int      { return g.byPool.Size() }
func Want() string    { return poolkey.WugnotKey }
func DefaultPool() string { return poolkey.DefaultGnsWugnot().Path }

func PoolPaths() []string {
	out := make([]string, 0, g.byPool.Size())
	g.byPool.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}

func Has(poolPath string) bool { return g.byPool.Has(poolPath) }

func TotalAssets() int64 {
	var sum int64
	g.byPool.Iterate("", "", func(_ string, v any) bool {
		sum += v.(*slot).book.TotalAssets()
		return false
	})
	return sum
}

func TotalShares() int64          { return totalSharesOf(DefaultPool()) }
func SharesOf(a address) int64    { return sharesOfPool(DefaultPool(), a) }
func PreviewDeposit(a int64) int64 { return previewDepositOf(DefaultPool(), a) }
func PreviewRedeem(s int64) int64 { return previewRedeemOf(DefaultPool(), s) }
func IdleWugnot() int64           { return idleOf(DefaultPool()) }
func TargetIdleWugnot() int64     { return targetIdleOf(DefaultPool()) }
func PositionID() uint64          { return positionIDOf(DefaultPool()) }
func ProtocolEarned() int64       { return protocolEarnedOf(DefaultPool()) }
func LastHarvest() int64          { return lastHarvestOf(DefaultPool()) }
func SharePriceE6() int64         { return sharePriceOf(DefaultPool()) }
func PendingGns() int64           { return pendingOtherOf(DefaultPool()) }
func CashWugnot() int64           { return idleOf(DefaultPool()) }

func TotalAssetsOf(poolPath string) int64  { return mustGet(poolPath).book.TotalAssets() }
func TotalSharesOf(poolPath string) int64  { return totalSharesOf(poolPath) }
func SharesOfPool(poolPath string, a address) int64 { return sharesOfPool(poolPath, a) }
func PreviewDepositOf(poolPath string, a int64) int64 { return previewDepositOf(poolPath, a) }
func PreviewRedeemOf(poolPath string, s int64) int64 { return previewRedeemOf(poolPath, s) }
func IdleOf(poolPath string) int64         { return idleOf(poolPath) }
func TargetIdleOf(poolPath string) int64   { return targetIdleOf(poolPath) }
func PositionIDOf(poolPath string) uint64  { return positionIDOf(poolPath) }
func ProtocolEarnedOf(poolPath string) int64 { return protocolEarnedOf(poolPath) }
func LastHarvestOf(poolPath string) int64  { return lastHarvestOf(poolPath) }
func SharePriceE6Of(poolPath string) int64 { return sharePriceOf(poolPath) }
func PendingOtherOf(poolPath string) int64 { return pendingOtherOf(poolPath) }

func UserAssets(a address) int64 {
	if a == address("") {
		return 0
	}
	var sum int64
	g.byPool.Iterate("", "", func(_ string, v any) bool {
		f := v.(*slot)
		sh := f.book.SharesOf(a)
		if sh > 0 {
			sum += f.book.PreviewRedeem(sh)
		}
		return false
	})
	return sum
}

// Ensure opens a farm slot for a WUGNOT pair if it is not already open.
// Anyone may call it. First Deposit also opens. This is the factory
// "deploy" — a new isolated book, not a new realm path.
func Ensure(cur realm, poolPath string) string {
	mustLive()
	f := ensureSlot(poolPath)
	return f.spec.Path
}

func Deposit(cur realm, poolPath string, amount int64) int64 {
	mustLive()
	if amount <= 0 {
		panic("amount must be positive")
	}
	f := ensureSlot(poolPath)
	caller := cur.Previous().Address()
	pullWugnot(cur, caller, amount)
	f.cash += amount
	shares := f.book.Deposit(caller, amount)
	chain.Emit("Deposit",
		"pool", f.spec.Path,
		"user", caller.String(),
		"assets", strconv.FormatInt(amount, 10),
		"shares", strconv.FormatInt(shares, 10),
	)
	return shares
}

func Withdraw(cur realm, poolPath string, shares int64) int64 {
	return withdrawTo(cur, poolPath, shares, cur.Previous().Address())
}

// WithdrawTo burns the caller's shares and pays WUGNOT to dest.
func WithdrawTo(cur realm, poolPath string, shares int64, dest address) int64 {
	if dest == address("") {
		panic("empty dest")
	}
	return withdrawTo(cur, poolPath, shares, dest)
}

func Reinvest(cur realm, poolPath string) int64 {
	mustLive()
	f := mustGet(poolPath)
	now := time.Now().Unix()
	height := runtime.ChainHeight()
	if f.guard.LastHeight != 0 && height <= f.guard.LastHeight {
		panic("reinvest too soon")
	}

	profit := harvestLP(cur, f)
	rest := int64(0)
	if profit > 0 {
		callerAmt, protoAmt, compound := corev2.SplitHarvest(profit, g.fees)
		if compound > 0 {
			f.book.AddProfit(compound)
		}
		if callerAmt > 0 {
			if callerAmt > f.cash {
				callerAmt = f.cash
			}
			f.cash -= callerAmt
			pushWugnot(cur, cur.Previous().Address(), callerAmt)
		}
		if protoAmt > 0 {
			if protoAmt > f.cash {
				protoAmt = f.cash
			}
			f.cash -= protoAmt
			pushWugnot(cur, g.treasury, protoAmt)
			next, ok := addEarned(f.protocolEarned, protoAmt)
			if !ok {
				panic("protocol earned overflow")
			}
			f.protocolEarned = next
		}
		rest = compound
		f.lastHarvest = profit
		chain.Emit("Reinvest",
			"pool", f.spec.Path,
			"caller", cur.Previous().Address().String(),
			"profit", strconv.FormatInt(profit, 10),
			"compound", strconv.FormatInt(compound, 10),
			"protocol", strconv.FormatInt(protoAmt, 10),
		)
	}

	deployed := rebalance(cur, f)
	f.lastDeployed = deployed
	f.guard.LastUnix = now
	f.guard.LastHeight = height
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
	next := corev2.FeeConfig{CallerBPS: callerBPS, ProtocolBPS: protocolBPS}
	next.Validate()
	g.fees = next
}

func SetPaused(cur realm, next bool) {
	mustAdmin(cur)
	g.paused = next
}

func withdrawTo(cur realm, poolPath string, shares int64, dest address) int64 {
	f := mustGet(poolPath)
	caller := cur.Previous().Address()
	need := f.book.PreviewRedeem(shares)
	if f.cash < need {
		unwindAll(cur, f)
		syncBookToCash(f)
	}
	assets := f.book.Withdraw(caller, shares)
	if assets > f.cash {
		assets = f.cash
	}
	f.cash -= assets
	pushWugnot(cur, dest, assets)
	chain.Emit("Withdraw",
		"pool", f.spec.Path,
		"user", caller.String(),
		"dest", dest.String(),
		"shares", strconv.FormatInt(shares, 10),
		"assets", strconv.FormatInt(assets, 10),
	)
	return assets
}

func ensureSlot(poolPath string) *slot {
	if g.byPool.Has(poolPath) {
		return g.byPool.Get(poolPath).(*slot)
	}
	spec := poolkey.MustWugnot(poolPath)
	assertPoolTokens(spec)
	f := &slot{
		spec:  spec,
		book:  corev2.NewBook(),
		guard: corev2.DefaultGuard(),
	}
	f.guard.MinProfit = 0
	g.byPool.Set(spec.Path, f)
	chain.Emit("VaultOpen", "pool", spec.Path, "other", spec.Other)
	return f
}

func mustGet(poolPath string) *slot {
	v := g.byPool.Get(poolPath)
	if v == nil {
		panic("unknown pool")
	}
	return v.(*slot)
}

func totalSharesOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return v.(*slot).book.TotalShares()
}

func sharesOfPool(poolPath string, a address) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return v.(*slot).book.SharesOf(a)
}

func previewDepositOf(poolPath string, a int64) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return a
	}
	return v.(*slot).book.PreviewDeposit(a)
}

func previewRedeemOf(poolPath string, s int64) int64 {
	return mustGet(poolPath).book.PreviewRedeem(s)
}

func idleOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return v.(*slot).cash
}

func targetIdleOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return alloc.TargetIdle(v.(*slot).book.TotalAssets(), g.bufferBPS)
}

func positionIDOf(poolPath string) uint64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return v.(*slot).positionID
}

func protocolEarnedOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return v.(*slot).protocolEarned
}

func lastHarvestOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return v.(*slot).lastHarvest
}

func sharePriceOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 1_000_000
	}
	f := v.(*slot)
	if f.book.TotalShares() == 0 {
		return 1_000_000
	}
	return f.book.PreviewRedeem(1_000_000)
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
	out := "# Gno Vault Strategy — v4 multi-pool factory\n\n"
	out += "WUGNOT in. One isolated book + LP per GnoSwap WUGNOT pair. "
	out += "`Ensure` / first `Deposit` opens a missing pool (no new realm).\n\n"
	out += ufmt.Sprintf("- **Open farms**: %d\n", g.byPool.Size())
	out += ufmt.Sprintf("- **TVL (all books)**: %d wugnot\n", TotalAssets())
	out += "- **Vault**: " + sanitize.InlineText(g.self.String()) + "\n"
	out += "- **Admin**: " + sanitize.InlineText(g.admin.String()) + "\n\n"
	if g.byPool.Size() == 0 {
		out += "> [!NOTE]\n> No pool opened yet. Call `Ensure` or `Deposit` with a WUGNOT pool path.\n"
		return out
	}
	out += "| Pool | TVL | Idle | Shares | LP |\n|---|---:|---:|---:|---:|\n"
	g.byPool.Iterate("", "", func(key string, value any) bool {
		f := value.(*slot)
		out += "| `" + sanitize.InlineText(key) + "` | " +
			strconv.FormatInt(f.book.TotalAssets(), 10) + " | " +
			strconv.FormatInt(f.cash, 10) + " | " +
			strconv.FormatInt(f.book.TotalShares(), 10) + " | " +
			strconv.FormatInt(int64(f.positionID), 10) + " |\n"
		return false
	})
	return out
}
