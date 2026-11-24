package hearthcore

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestComputeSplitConservation(t *testing.T) {
	cases := []struct {
		escrow int64
		bps    uint64
		wantH  int64
		wantS  int64
	}{
		{1000000, 0, 0, 1000000},
		{1000000, 10000, 1000000, 0},
		{1000000, 5000, 500000, 500000},
		{1000000, 7500, 750000, 250000},
		{999999, 3333, 333299, 666700},
		{1, 5000, 0, 1},
		{0, 5000, 0, 0},
		{9000000000000000, 3333, 2999700000000000, 6000300000000000},
	}

	for _, tc := range cases {
		h, s := ComputeSplit(tc.escrow, tc.bps)
		uassert.Equal(t, tc.wantH, h)
		uassert.Equal(t, tc.wantS, s)
		uassert.Equal(t, tc.escrow, h+s)
	}
}

func TestFormatGNOT(t *testing.T) {
	uassert.Equal(t, "0.00 GNOT", FormatGNOT(0))
	uassert.Equal(t, "1.00 GNOT", FormatGNOT(1000000))
	uassert.Equal(t, "2.50 GNOT", FormatGNOT(2500000))
	uassert.Equal(t, "0.10 GNOT", FormatGNOT(100000))
	uassert.Equal(t, "0.123456 GNOT", FormatGNOT(123456))
	uassert.Equal(t, "42.05 GNOT", FormatGNOT(42050000))
}

func TestComputeTier(t *testing.T) {
	uassert.Equal(t, string(TierApprentice), string(ComputeTier(0, 0, 0, 0)))
	uassert.Equal(t, string(TierApprentice), string(ComputeTier(1, 5000000, 5, 1)))
	uassert.Equal(t, string(TierJourneyman), string(ComputeTier(2, 5000000, 9, 2)))
	uassert.Equal(t, string(TierJourneyman), string(ComputeTier(1, 10000000, 5, 1)))
	uassert.Equal(t, string(TierMaster), string(ComputeTier(5, 10000000, 23, 5)))
	uassert.Equal(t, string(TierMaster), string(ComputeTier(1, 100000000, 5, 1)))
	uassert.Equal(t, string(TierGuildmaster), string(ComputeTier(10, 50000000, 48, 10)))
	// Low rating blocks Guildmaster promotion.
	uassert.Equal(t, string(TierMaster), string(ComputeTier(10, 50000000, 30, 10)))
}

func TestFormatRating(t *testing.T) {
	uassert.Equal(t, "Unrated", FormatRating(0, 0))
	uassert.Equal(t, "5.0 / 5.0", FormatRating(15, 3))
	uassert.Equal(t, "4.7 / 5.0", FormatRating(14, 3))
}

func TestCategoryAndStatusHelpers(t *testing.T) {
	cat, ok := ParseCategory("  AGENT ")
	uassert.True(t, ok)
	uassert.Equal(t, string(CatAgent), string(cat))
	uassert.Equal(t, "AI Agent", cat.Label())
	uassert.Equal(t, "ai", cat.IconName())

	_, bad := ParseCategory("invalid")
	uassert.False(t, bad)

	uassert.True(t, StatusOpen.IsValid())
	uassert.False(t, Status("bogus").IsValid())
	uassert.Equal(t, 3, StatusSettled.StepIndex())
}

func TestValidationHelpers(t *testing.T) {
	uassert.Equal(t, "https://github.com/org/repo/pull/1", ValidateProofURL("  https://github.com/org/repo/pull/1  "))
	uassert.Equal(t, "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", ValidateProofURL("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"))
	uassert.Equal(t, DefaultDeadlineBlocks, ValidateDeadlineBlocks(0))
	uassert.Equal(t, int64(250), ValidateDeadlineBlocks(250))
	uassert.Equal(t, uint8(5), ValidateRating(5))
	uassert.Equal(t, `cost is \$50 and \$GNOT`, EscapeMath("cost is $50 and $GNOT"))
}

func TestJSONBuilder(t *testing.T) {
	obj := NewJSONObject().
		Str("title", "Build \"alpha\"\nrealm").
		Int64("escrow_ugnot", 2500000).
		Uint64("id", 7).
		Bool("active", true).
		Raw("tags", JoinJSONArray([]string{QuoteJSON("realm"), QuoteJSON("mcp")})).
		String()

	uassert.Equal(t, `{"title":"Build \"alpha\"\nrealm","escrow_ugnot":2500000,"id":7,"active":true,"tags":["realm","mcp"]}`, obj)
}

func TestSVGVisuals(t *testing.T) {
	hero := RenderHeroBannerSVG(3, 2, 1, 4, 12500000, 48000000)
	uassert.True(t, strings.HasPrefix(hero, "![HearthBounty Live On-Chain Escrow Dashboard](data:image/svg+xml;base64,"))

	step := RenderLifecycleSVG(StatusSubmitted, 3500000)
	uassert.True(t, strings.HasPrefix(step, "![Bounty Lifecycle Progress](data:image/svg+xml;base64,"))

	badge := RenderTierBadgeSVG("agent<script>", TierGuildmaster, 12, 600000000, true)
	uassert.True(t, strings.HasPrefix(badge, "![HearthBounty Reputation Badge](data:image/svg+xml;base64,"))
}
