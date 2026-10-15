package factory_v6

import (
	"chain"
	"strings"
	"testing"
)

func launchV6Fixture(cur realm, symbol string) *tokenEntry {
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	LaunchToken(cross(cur), symbol, "V6 Fixture", "", "", "", "", "", "", "")
	return getTokenEntry(symbol)
}

func TestV6CanonicalTokenIdentity(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V6I")
	tokenID := GetTokenID("V6I")
	wantPrefix := "gno.land/r/g1qkz0adydx8l6tfc9s6xaam07jumvjw9jy2srna/factory_v6.V6I."
	if tokenID != entry.token.ID() || !strings.HasPrefix(tokenID, wantPrefix) {
		t.Fatalf("V6-ID-1: canonical token ID %q does not use factory realm + symbol", tokenID)
	}
}

func TestV6KeepsLogoAndBannerMetadataSeparate(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	logo := "https://media.example/logo.png"
	banner := "https://media.example/banner.jpg"
	LaunchToken(cross(cur), "V6M", "V6 Media", "Media fixture", logo, banner, "", "", "", "")

	entry := getTokenEntry("V6M")
	if entry.meta.ImageURL != logo || entry.meta.BannerURL != banner {
		t.Fatalf("V6-MEDIA-1: logo/banner metadata collapsed: %q / %q", entry.meta.ImageURL, entry.meta.BannerURL)
	}
	rendered := Render("V6M")
	if !strings.Contains(rendered, "Image: "+logo) || !strings.Contains(rendered, "Banner: "+banner) {
		t.Fatalf("V6-MEDIA-1: render omitted artwork metadata: %s", rendered)
	}
}

func TestV6FullGraduationToInternalDEX(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V6D")
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)

	buys := 0
	for buys < 120 && !entry.meta.IsGraduated {
		testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", MAX_BUY_UGNOT)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", MAX_BUY_UGNOT)))
		quoted, _, _ := QuoteBuy("V6D", MAX_BUY_UGNOT)
		if quoted <= 0 {
			t.Fatal("V6-DEX-1: valid pre-graduation buy returned no tokens")
		}
		Buy(cross(cur), "V6D", quoted)
		buys++
	}
	if !entry.meta.IsGraduated || entry.meta.Reserves < GRADUATION_THRESHOLD {
		t.Fatalf("V6-DEX-1: actual buys did not graduate token after %d iterations", buys)
	}
	if GetTradeRoute("V6D") != "graduated" {
		t.Fatalf("V6-DEX-1: graduated token route is %q, want graduated", GetTradeRoute("V6D"))
	}
	if out, fee, route := QuoteTrade("V6D", true, 1000000); out != 0 || fee != 0 || route != "graduated" {
		t.Fatalf("V6-DEX-1: graduated quote must expose a closed curve, got %d/%d/%q", out, fee, route)
	}
	if r := revive(func() { Buy(cross(cur), "V6D", 1) }); r == nil {
		t.Fatal("V6-DEX-1: bonding buy remained open after graduation")
	}
	testing.SetOriginSend(chain.Coins{})
	if r := revive(func() { Sell(cross(cur), "V6D", 1, 1) }); r == nil {
		t.Fatal("V6-DEX-1: bonding sell remained open after graduation")
	}

	// A non-admin activates the only supported DEX venue from deterministic
	// on-chain inputs; the curve remains closed throughout the transition.
	testing.SetRealm(testing.NewUserRealm(eoaB))
	testing.SetOriginCaller(eoaB)
	InitializeAMMPool(cross(cur), "V6D")
	pool := ammPools["V6D"]
	if GetTradeRoute("V6D") != "amm" || pool == nil || !pool.Active {
		t.Fatal("V6-DEX-1: permissionless activation did not open the internal DEX")
	}
	if entry.meta.Reserves != 0 || GetProtocolLockedLP("V6D") <= 0 || GetProtocolLockedLP("V6D") != pool.TotalLP {
		t.Fatal("V6-DEX-1: graduated reserves or seed LP were not locked into the DEX")
	}

	const swapIn = int64(1000000)
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", swapIn)))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", swapIn)))
	quotedBuy, _ := QuoteAMMBuy("V6D", swapIn)
	bought := SwapGNOTForToken(cross(cur), "V6D", quotedBuy)
	if bought != quotedBuy || bought <= 0 {
		t.Fatal("V6-DEX-1: first internal-DEX buy diverged from quote")
	}
	testing.SetOriginSend(chain.Coins{})
	quotedSell, _ := QuoteAMMSell("V6D", bought)
	if got := SwapTokenForGNOT(cross(cur), "V6D", bought, quotedSell); got != quotedSell || got <= 0 {
		t.Fatal("V6-DEX-1: first internal-DEX sell diverged from quote")
	}
}

func TestV6InitializesDeterministicLockedAMM(cur realm, t *testing.T) {
	admin = eoaA
	globalPaused = false
	entry := launchV6Fixture(cur, "V61")
	if err := entry.ledger.Mint(eoaA, 1000); err != nil {
		t.Fatal(err)
	}
	entry.meta.IsGraduated = true
	entry.meta.Reserves = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", entry.meta.Reserves)))

	// Activation is permissionless: a non-admin can finalize the deterministic
	// transition, so the admin cannot strand a graduated market.
	testing.SetRealm(testing.NewUserRealm(eoaB))
	testing.SetOriginCaller(eoaB)
	testing.SetOriginSend(chain.Coins{})
	InitializeAMMPool(cross(cur), "V61")

	pool := ammPools["V61"]
	wantSeed := int64(1000000) / spotPrice(1000)
	if pool == nil || !pool.Active {
		t.Fatal("V6-AMM-1: pool must be active after atomic initialization")
	}
	if pool.TokenReserve != wantSeed || pool.GNOTReserve != 1000000 {
		t.Fatalf("V6-AMM-1: deterministic seed got token=%d gnot=%d, want token=%d gnot=1000000", pool.TokenReserve, pool.GNOTReserve, wantSeed)
	}
	if !entry.meta.MigrationComplete || entry.meta.Reserves != 0 {
		t.Fatal("V6-AMM-1: migration flags or reserves were not finalized atomically")
	}
	if GetProtocolLockedLP("V61") != 1000000 || pool.TotalLP != 1000000 {
		t.Fatal("V6-AMM-1: initial LP must be entirely protocol locked")
	}
}

func TestV6AMMActivationRejectsMissingReserves(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V62")
	entry.meta.IsGraduated = true

	testing.SetRealm(testing.NewUserRealm(eoaB))
	testing.SetOriginCaller(eoaB)
	testing.SetOriginSend(chain.Coins{})
	if r := revive(func() { InitializeAMMPool(cross(cur), "V62") }); r == nil {
		t.Fatal("V6-MIGRATE-1: AMM activation without custodied reserves must fail")
	}
	if entry.meta.MigrationComplete || ammPools["V62"] != nil {
		t.Fatal("V6-MIGRATE-1: rejected activation changed lifecycle state")
	}
}

func TestV6LiquidityBoundsRejectChangedState(cur realm, t *testing.T) {
	admin = eoaA
	entry := launchV6Fixture(cur, "V63")
	entry.meta.MigrationComplete = true
	if err := entry.ledger.Mint(realmAddr, 1000000); err != nil {
		t.Fatal(err)
	}
	ammPools["V63"] = &AMMPool{TokenReserve: 1000000, GNOTReserve: 1000000, KLast: 1000000000000, TotalLP: 1000000, Active: true}
	lpBalances["V63"] = make(map[address]int64)
	lpBalances["V63"][realmAddr] = 900000
	lpBalances["V63"][eoaA] = 100000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))

	quotedTokens, quotedGNOT := QuoteRemoveLiquidity("V63", 100000)
	if quotedTokens != 100000 || quotedGNOT != 100000 {
		t.Fatal("V6-LP-1: unexpected fixture quote")
	}
	poolBefore := *ammPools["V63"]
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.Coins{})
	if r := revive(func() { RemoveLiquidity(cross(cur), "V63", 100000, quotedTokens+1, quotedGNOT) }); r == nil {
		t.Fatal("V6-LP-1: liquidity exit must enforce both minimum outputs")
	}
	poolAfter := ammPools["V63"]
	if poolAfter.TokenReserve != poolBefore.TokenReserve || poolAfter.GNOTReserve != poolBefore.GNOTReserve || poolAfter.TotalLP != poolBefore.TotalLP {
		t.Fatal("V6-LP-1: rejected exit changed pool state")
	}
}

func TestV6AddLiquidityRequiresPositiveMinimum(cur realm, t *testing.T) {
	admin = eoaA
	entry := launchV6Fixture(cur, "V64")
	entry.meta.MigrationComplete = true
	if err := entry.ledger.Mint(realmAddr, 1000000); err != nil {
		t.Fatal(err)
	}
	if err := entry.ledger.Mint(eoaA, 1000); err != nil {
		t.Fatal(err)
	}
	ammPools["V64"] = &AMMPool{TokenReserve: 1000000, GNOTReserve: 1000000, KLast: 1000000000000, TotalLP: 1000000, Active: true}
	lpBalances["V64"] = make(map[address]int64)
	lpBalances["V64"][realmAddr] = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))

	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	if r := revive(func() { AddLiquidity(cross(cur), "V64", 1000, 0) }); r == nil {
		t.Fatal("V6-LP-2: unbounded liquidity entry must be rejected")
	}
}

func TestV6AdminProposalCanBeCancelled(cur realm, t *testing.T) {
	admin = eoaA
	pendingAdmin = ""
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	ProposeAdmin(cross(cur), eoaB)
	CancelAdminProposal(cross(cur))
	if GetAdmin() != eoaA || GetPendingAdmin() != "" {
		t.Fatal("V6-ADMIN-1: cancellation must preserve current admin and clear proposal")
	}
}

func TestCalculateBpsAtInt64Boundary(t *testing.T) {
	const max = int64(9223372036854775807)
	got := calculateBps(max, 100)
	if got != 92233720368547758 {
		t.Fatalf("V6-MATH-1: 1%% of MaxInt64 = %d, want 92233720368547758", got)
	}
}

func TestV6TradesRequireOutputBounds(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V65")
	if err := entry.ledger.Mint(eoaA, 1000); err != nil {
		t.Fatal(err)
	}
	entry.meta.Reserves = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))

	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	if r := revive(func() { Buy(cross(cur), "V65", 0) }); r == nil {
		t.Fatal("V6-SLIPPAGE-1: bonding buy without a minimum must fail")
	}
	testing.SetOriginSend(chain.Coins{})
	if r := revive(func() { Sell(cross(cur), "V65", 1, 0) }); r == nil {
		t.Fatal("V6-SLIPPAGE-1: bonding sell without a minimum must fail")
	}

	entry.meta.IsGraduated = true
	InitializeAMMPool(cross(cur), "V65")
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	if r := revive(func() { SwapGNOTForToken(cross(cur), "V65", 0) }); r == nil {
		t.Fatal("V6-SLIPPAGE-1: AMM buy without a minimum must fail")
	}
	testing.SetOriginSend(chain.Coins{})
	if r := revive(func() { SwapTokenForGNOT(cross(cur), "V65", 1, 0) }); r == nil {
		t.Fatal("V6-SLIPPAGE-1: AMM sell without a minimum must fail")
	}
}

func TestV6AMMSwapQuotesMatchExecutionAndKDoesNotDecrease(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V66")
	entry.meta.IsGraduated = true
	entry.meta.MigrationComplete = true
	entry.meta.PoolID = "gnopump-amm-V66"
	if err := entry.ledger.Mint(realmAddr, 1000000); err != nil {
		t.Fatal(err)
	}
	if err := entry.ledger.Mint(eoaA, 10000); err != nil {
		t.Fatal(err)
	}
	ammPools["V66"] = &AMMPool{TokenReserve: 1000000, GNOTReserve: 1000000, KLast: 1000000000000, TotalLP: 1000000, Active: true}
	lpBalances["V66"] = make(map[address]int64)
	lpBalances["V66"][realmAddr] = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))

	buyIn := int64(100000)
	wantBuy, _ := QuoteAMMBuy("V66", buyIn)
	kBeforeBuy := safeMul(ammPools["V66"].TokenReserve, ammPools["V66"].GNOTReserve)
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", buyIn)))
	gotBuy := SwapGNOTForToken(cross(cur), "V66", wantBuy)
	if gotBuy != wantBuy || entry.token.BalanceOf(eoaA) != 10000+wantBuy {
		t.Fatal("V6-CONSERVE-1: AMM buy execution diverged from its quote or token credit")
	}
	kAfterBuy := safeMul(ammPools["V66"].TokenReserve, ammPools["V66"].GNOTReserve)
	if kAfterBuy < kBeforeBuy {
		t.Fatal("V6-CONSERVE-1: AMM buy decreased constant product")
	}

	sellIn := int64(1000)
	testing.SetOriginSend(chain.Coins{})
	wantSell, _ := QuoteAMMSell("V66", sellIn)
	kBeforeSell := safeMul(ammPools["V66"].TokenReserve, ammPools["V66"].GNOTReserve)
	beforeTokens := entry.token.BalanceOf(eoaA)
	gotSell := SwapTokenForGNOT(cross(cur), "V66", sellIn, wantSell)
	if gotSell != wantSell || entry.token.BalanceOf(eoaA) != beforeTokens-sellIn {
		t.Fatal("V6-CONSERVE-1: AMM sell execution diverged from its quote or token debit")
	}
	kAfterSell := safeMul(ammPools["V66"].TokenReserve, ammPools["V66"].GNOTReserve)
	if kAfterSell < kBeforeSell {
		t.Fatal("V6-CONSERVE-1: AMM sell decreased constant product")
	}
}

func TestV6LiquidityQuotesMatchExecution(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V67")
	entry.meta.IsGraduated = true
	entry.meta.MigrationComplete = true
	entry.meta.PoolID = "gnopump-amm-V67"
	if err := entry.ledger.Mint(realmAddr, 500000); err != nil {
		t.Fatal(err)
	}
	if err := entry.ledger.Mint(eoaA, 1000); err != nil {
		t.Fatal(err)
	}
	ammPools["V67"] = &AMMPool{TokenReserve: 500000, GNOTReserve: 1000000, KLast: 500000000000, TotalLP: 1000000, Active: true}
	lpBalances["V67"] = make(map[address]int64)
	lpBalances["V67"][realmAddr] = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))

	gnotIn := int64(1000)
	wantTokens, wantLP := QuoteAddLiquidity("V67", gnotIn)
	lockedBefore := GetProtocolLockedLP("V67")
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", gnotIn)))
	gotLP := AddLiquidity(cross(cur), "V67", wantTokens, wantLP)
	if gotLP != wantLP || GetLPBalance("V67", eoaA) != wantLP {
		t.Fatal("V6-LP-3: add-liquidity execution diverged from quote")
	}
	if GetProtocolLockedLP("V67") != lockedBefore {
		t.Fatal("V6-LP-3: user deposit changed locked protocol LP")
	}

	testing.SetOriginSend(chain.Coins{})
	wantTokensOut, wantGNOTOut := QuoteRemoveLiquidity("V67", gotLP)
	gotTokensOut, gotGNOTOut := RemoveLiquidity(cross(cur), "V67", gotLP, wantTokensOut, wantGNOTOut)
	if gotTokensOut != wantTokensOut || gotGNOTOut != wantGNOTOut || GetLPBalance("V67", eoaA) != 0 {
		t.Fatal("V6-LP-3: remove-liquidity execution diverged from quote")
	}
	if GetProtocolLockedLP("V67") != lockedBefore {
		t.Fatal("V6-LP-3: user exit changed locked protocol LP")
	}
}

func TestV6TransferFromRequiresAllowance(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V68")
	if err := entry.ledger.Mint(eoaA, 100); err != nil {
		t.Fatal(err)
	}
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.Coins{})
	Approve(cross(cur), "V68", eoaB, 30)

	testing.SetRealm(testing.NewUserRealm(eoaB))
	testing.SetOriginCaller(eoaB)
	if r := revive(func() { TransferFrom(cross(cur), "V68", eoaA, eoaB, 31) }); r == nil {
		t.Fatal("V6-GRC20-1: transfer above allowance must fail")
	}
	TransferFrom(cross(cur), "V68", eoaA, eoaB, 30)
	if entry.token.BalanceOf(eoaA) != 70 || entry.token.BalanceOf(eoaB) != 30 || Allowance("V68", eoaA, eoaB) != 0 {
		t.Fatal("V6-GRC20-1: allowance transfer accounting mismatch")
	}
}

func TestV6GlobalPauseCoversUserMutations(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V69")
	if err := entry.ledger.Mint(eoaA, 1000); err != nil {
		t.Fatal(err)
	}
	entry.meta.Reserves = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))
	globalPaused = true
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))

	blocked := 0
	if revive(func() { Buy(cross(cur), "V69", 1) }) != nil {
		blocked++
	}
	testing.SetOriginSend(chain.Coins{})
	if revive(func() { Sell(cross(cur), "V69", 1, 1) }) != nil {
		blocked++
	}
	if revive(func() { Transfer(cross(cur), "V69", eoaB, 1) }) != nil {
		blocked++
	}
	if revive(func() { Approve(cross(cur), "V69", eoaB, 1) }) != nil {
		blocked++
	}
	if revive(func() { TransferFrom(cross(cur), "V69", eoaA, eoaB, 1) }) != nil {
		blocked++
	}
	if revive(func() { InitializeAMMPool(cross(cur), "V69") }) != nil {
		blocked++
	}
	if revive(func() { SwapTokenForGNOT(cross(cur), "V69", 1, 1) }) != nil {
		blocked++
	}
	if revive(func() { RemoveLiquidity(cross(cur), "V69", 1, 1, 1) }) != nil {
		blocked++
	}
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	if revive(func() { SwapGNOTForToken(cross(cur), "V69", 1) }) != nil {
		blocked++
	}
	if revive(func() { AddLiquidity(cross(cur), "V69", 1, 1) }) != nil {
		blocked++
	}
	if revive(func() { LaunchToken(cross(cur), "V6P", "Paused Launch", "", "", "", "", "", "", "") }) != nil {
		blocked++
	}
	if revive(func() { LaunchTemplate(cross(cur), "V6Q", "Paused Template", "", "", "", "", "", "", "", 100) }) != nil {
		blocked++
	}
	if revive(func() { ForkToken(cross(cur), "V69", "V6R", "Paused Fork", "", "", "", "", "", "", "") }) != nil {
		blocked++
	}
	if blocked != 13 {
		t.Fatalf("V6-PAUSE-1: global pause blocked %d/13 user mutations", blocked)
	}
	globalPaused = false
}

func TestV6RejectsUnexpectedAttachedCoins(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(
		chain.NewCoin("ugnot", CREATE_FEE),
		chain.NewCoin("other", 1),
	))
	if r := revive(func() { LaunchToken(cross(cur), "V70", "Mixed Payment", "", "", "", "", "", "", "") }); r == nil {
		t.Fatal("V6-PAY-2: payment-bearing calls must reject extra denominations")
	}
	if tokenRegistry["V70"] != nil {
		t.Fatal("V6-PAY-2: rejected mixed payment created token state")
	}

	entry := launchV6Fixture(cur, "V71")
	entry.meta.IsGraduated = true
	entry.meta.Reserves = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000000)))
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
	if r := revive(func() { InitializeAMMPool(cross(cur), "V71") }); r == nil {
		t.Fatal("V6-PAY-2: non-payable calls must reject attached coins")
	}
	if entry.meta.MigrationComplete || ammPools["V71"] != nil {
		t.Fatal("V6-PAY-2: rejected attached coins changed migration state")
	}
}

func TestV6DeterministicEconomicSequencePreservesAMMInvariants(cur realm, t *testing.T) {
	entry := launchV6Fixture(cur, "V72")
	entry.meta.IsGraduated = true
	entry.meta.MigrationComplete = true
	entry.meta.PoolID = "gnopump-amm-V72"
	if err := entry.ledger.Mint(realmAddr, 10000000); err != nil {
		t.Fatal(err)
	}
	if err := entry.ledger.Mint(eoaA, 500000); err != nil {
		t.Fatal(err)
	}
	ammPools["V72"] = &AMMPool{TokenReserve: 10000000, GNOTReserve: 10000000, KLast: 100000000000000, TotalLP: 10000000, Active: true}
	lpBalances["V72"] = make(map[address]int64)
	lpBalances["V72"][realmAddr] = 10000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 10000000)))

	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	seed := int64(1779033703)
	lockedLP := GetProtocolLockedLP("V72")
	for i := 0; i < 32; i++ {
		seed = (seed*1103515245 + 12345) & 2147483647
		buyIn := int64(1000 + seed%9000)
		wantBuy, _ := QuoteAMMBuy("V72", buyIn)
		kBefore := safeMul(ammPools["V72"].TokenReserve, ammPools["V72"].GNOTReserve)
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", buyIn)))
		if got := SwapGNOTForToken(cross(cur), "V72", wantBuy); got != wantBuy {
			t.Fatalf("V6-PROP-1: iteration %d buy quote mismatch", i)
		}
		if safeMul(ammPools["V72"].TokenReserve, ammPools["V72"].GNOTReserve) < kBefore {
			t.Fatalf("V6-PROP-1: iteration %d buy decreased k", i)
		}

		seed = (seed*1103515245 + 12345) & 2147483647
		sellIn := int64(1000 + seed%4000)
		wantSell, _ := QuoteAMMSell("V72", sellIn)
		kBefore = safeMul(ammPools["V72"].TokenReserve, ammPools["V72"].GNOTReserve)
		testing.SetOriginSend(chain.Coins{})
		if got := SwapTokenForGNOT(cross(cur), "V72", sellIn, wantSell); got != wantSell {
			t.Fatalf("V6-PROP-1: iteration %d sell quote mismatch", i)
		}
		if safeMul(ammPools["V72"].TokenReserve, ammPools["V72"].GNOTReserve) < kBefore {
			t.Fatalf("V6-PROP-1: iteration %d sell decreased k", i)
		}

		if i%8 == 0 {
			gnotIn := int64(1000 + seed%2000)
			tokensRequired, lpOut := QuoteAddLiquidity("V72", gnotIn)
			testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", gnotIn)))
			if got := AddLiquidity(cross(cur), "V72", tokensRequired, lpOut); got != lpOut {
				t.Fatalf("V6-PROP-1: iteration %d LP add quote mismatch", i)
			}
			tokensOut, gnotOut := QuoteRemoveLiquidity("V72", lpOut)
			testing.SetOriginSend(chain.Coins{})
			gotTokens, gotGNOT := RemoveLiquidity(cross(cur), "V72", lpOut, tokensOut, gnotOut)
			if gotTokens != tokensOut || gotGNOT != gnotOut {
				t.Fatalf("V6-PROP-1: iteration %d LP remove quote mismatch", i)
			}
		}

		pool := ammPools["V72"]
		if pool.TokenReserve <= 0 || pool.GNOTReserve <= 0 || pool.TotalLP < lockedLP {
			t.Fatalf("V6-PROP-1: iteration %d invalid reserve or LP state", i)
		}
		if entry.token.BalanceOf(realmAddr) != pool.TokenReserve {
			t.Fatalf("V6-PROP-1: iteration %d pool token accounting diverged", i)
		}
		if GetProtocolLockedLP("V72") != lockedLP {
			t.Fatalf("V6-PROP-1: iteration %d changed locked protocol LP", i)
		}
	}
}
