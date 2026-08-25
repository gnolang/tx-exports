package lens

import (
	"strconv"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	v4 "gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/gsfarmv4"
)

// One-shot reads so the UI does not issue dozens of qeval calls.
// Does not hold funds.

func FactoryCount() int           { return v4.Count() }
func FactoryTvl() int64           { return v4.TotalAssets() }
func FactoryAddress() address     { return v4.VaultAddress() }
func FactoryAdmin() address       { return v4.Admin() }
func FactoryTreasury() address    { return v4.Treasury() }
func DefaultPool() string         { return v4.DefaultPool() }
func PoolPaths() []string         { return v4.PoolPaths() }

func SlotTvl(pool string) int64 {
	if !v4.Has(pool) {
		return 0
	}
	return v4.TotalAssetsOf(pool)
}

func SlotShares(pool string) int64 {
	if !v4.Has(pool) {
		return 0
	}
	return v4.TotalSharesOf(pool)
}

func SlotIdle(pool string) int64 {
	if !v4.Has(pool) {
		return 0
	}
	return v4.IdleOf(pool)
}

func SlotPos(pool string) uint64 {
	if !v4.Has(pool) {
		return 0
	}
	return v4.PositionIDOf(pool)
}

func SlotPrice(pool string) int64 {
	if !v4.Has(pool) {
		return 1_000_000
	}
	return v4.SharePriceE6Of(pool)
}

// Dump is one string: v4|count|tvlAll|addr|pool:tvl:shares:idle:pos:price,...
func Dump() string {
	out := "v4|" +
		strconv.Itoa(v4.Count()) + "|" +
		strconv.FormatInt(v4.TotalAssets(), 10) + "|" +
		v4.VaultAddress().String()
	paths := v4.PoolPaths()
	if len(paths) > 0 {
		out += "|"
		for i, p := range paths {
			if i > 0 {
				out += ","
			}
			out += p + "#" +
				strconv.FormatInt(v4.TotalAssetsOf(p), 10) + "#" +
				strconv.FormatInt(v4.TotalSharesOf(p), 10) + "#" +
				strconv.FormatInt(v4.IdleOf(p), 10) + "#" +
				strconv.FormatInt(int64(v4.PositionIDOf(p)), 10) + "#" +
				strconv.FormatInt(v4.SharePriceE6Of(p), 10)
		}
	}
	return out
}

func Render(path string) string {
	_ = path
	out := "# GVS lens\n\n"
	out += "Read-only view over v2 / v3 / v4. No deposits.\n\n"
	out += ufmt.Sprintf("- **v4 slots**: %d · TVL %d\n", v4.Count(), v4.TotalAssets())
	out += "- **v4**: `" + sanitize.InlineText(v4.VaultAddress().String()) + "`\n"
	return out
}
