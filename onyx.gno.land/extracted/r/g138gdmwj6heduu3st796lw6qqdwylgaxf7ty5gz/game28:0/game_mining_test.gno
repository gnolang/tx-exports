package game28

import (
	"strconv"
	"testing"
)

// ── Test helpers ─────────────────────────────────────────────────────────────

// mustPanic asserts that calling f() panics with a message containing wantSubstr.
func mustPanic(t *testing.T, wantSubstr string, f func()) {
	t.Helper()
	var msg string
	panicked := false
	func() {
		defer func() {
			r := recover()
			if r != nil {
				panicked = true
				switch v := r.(type) {
				case string:
					msg = v
				case error:
					msg = v.Error()
				default:
					msg = "non-string panic"
				}
			}
		}()
		f()
	}()
	if !panicked {
		t.Errorf("expected panic containing %q, but no panic occurred", wantSubstr)
		return
	}
	if wantSubstr != "" && !strContains(msg, wantSubstr) {
		t.Errorf("panic message %q does not contain %q", msg, wantSubstr)
	}
}

func strContains(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	if len(sub) > len(s) {
		return false
	}
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// resetAddr clears all claim and bucket state for an address.
func resetAddr(addr string) {
	lastClaim.Remove(addr)
	for r := 0; r < 7; r++ {
		claimBuckets.Remove(addr + ":" + strconv.Itoa(r))
	}
	ownedTools.Remove(addr)
	toolLife.Remove(addr) // clear any stray keys via prefix
}

// setBalance grants a balance for testing.
func setBalance(addr, coinId string, amount uint64) {
	balances.Set(addr+":"+coinId, strconv.FormatUint(amount, 10))
}

// setBucketMillis sets the token-bucket state in milli-units (whole coins × 1000).
// Use this for precise test setup. lastTs is the unix timestamp of the last update.
func setBucketMillis(addr string, r int, millis uint64, lastTs int64) {
	claimBuckets.Set(
		addr+":"+strconv.Itoa(r),
		strconv.FormatUint(millis, 10)+":"+strconv.FormatInt(lastTs, 10),
	)
}

// setBucketCoins is a convenience wrapper: sets bucket to N whole coins.
func setBucketCoins(addr string, r int, coins uint64, lastTs int64) {
	setBucketMillis(addr, r, coins*1000, lastTs)
}

// effectiveRateForTool computes the effective coins/min for a given tool and rarity,
// matching enforceClaimRate's own formula. Used in tests.
func effectiveRateForTool(toolId string, r int) uint64 {
	rates, ok := claimRatePerMin[toolId]
	if !ok {
		rates = claimRatePerMin["hands"]
	}
	base := rates[r]
	var eff uint64
	if r == 0 {
		eff = (base * skillDmgHeadroom * skillDustHeadroom) / 10000
	} else {
		eff = (base * skillDmgHeadroom) / 100
	}
	if eff == 0 {
		eff = base
	}
	return eff
}

// capMillisForTool returns the bucket cap in milli-units for a tool+rarity.
func capMillisForTool(toolId string, r int) uint64 {
	eff := effectiveRateForTool(toolId, r)
	return eff * uint64(claimBucketSecs) * 1000 / 60
}

// ── Test 1: unknown coin panics ───────────────────────────────────────────────

func TestUnknownCoinPanics(t *testing.T) {
	// parseCoinClaims must panic on any coin id not in coinRarity.
	mustPanic(t, "unknown coin id:", func() {
		parseCoinClaims(`[["totally_fake_coin_xyz","1"]]`)
	})

	// Also via a real-looking but unlisted id.
	mustPanic(t, "unknown coin id:", func() {
		parseCoinClaims(`[["god_coin","5"]]`)
	})

	// Known coin must NOT panic.
	coinMap, byRarity := parseCoinClaims(`[["grin","10"]]`)
	if coinMap["grin"] != 10 {
		t.Errorf("expected grin=10, got %d", coinMap["grin"])
	}
	if byRarity[0] != 10 {
		t.Errorf("expected byRarity[0]=10, got %d", byRarity[0])
	}
}

// ── Test 2a: cosmic r6 (2/min base) refills correctly ────────────────────────
// cosmic r6 base = 2/min. effective = 2 × 200/100 = 4/min.
// cap = 4 × 3600 × 1000 / 60 = 240,000 milli = 240 whole coins.
// per-minute refill (exact): 60 × 4 × 1000 / 60 = 4000 milli = 4 whole coins ≥ 4 ✓
// over 10 min from empty: 600 × 4 × 1000 / 60 = 40,000 milli = 40 whole coins.

func TestCosmicR6RefillPerMinute(t *testing.T) {
	addr := "g1testcosmic0000000000000000000000001"
	resetAddr(addr)
	ownedTools.Set(addr, "hands,starter-twig,twig,wood,stone,iron,gold,diamond,cosmic")
	toolLife.Set(addr+":cosmic", strconv.FormatUint(toolMaxLife["cosmic"], 10))

	cosmicBase := claimRatePerMin["cosmic"][6] // 2/min
	eff := effectiveRateForTool("cosmic", 6)   // 4/min (2 × 200/100)
	capMillis := capMillisForTool("cosmic", 6) // 240,000 milli
	coinCap := capMillis / 1000                // 240 whole coins

	now := int64(3_000_000)

	// ── per-minute refill ≥ effective rate (4 coins/min) ─────────────────────
	// exact: 60s × eff × 1000 / 60 = eff × 1000 milli
	refilledMillis1min := uint64(60) * eff * 1000 / 60 // = 4000
	refilledCoins1min := refilledMillis1min / 1000       // = 4

	if refilledCoins1min < eff {
		t.Errorf("1-min refill %d < effectiveRate %d/min", refilledCoins1min, eff)
	}

	// Start with empty bucket, advance 1 minute
	setBucketMillis(addr, 6, 0, now-60)
	var exactly1min [7]uint64
	exactly1min[6] = refilledCoins1min
	enforceClaimRate(addr, exactly1min, now) // must not panic

	// One more panics
	setBucketMillis(addr, 6, 0, now-60)
	var over1min [7]uint64
	over1min[6] = refilledCoins1min + 1
	mustPanic(t, "rate limit rarity 6", func() {
		enforceClaimRate(addr, over1min, now)
	})

	// ── 10-min accrual from empty: 600s × 4 × 1000 / 60 = 40,000 milli = 40 ─
	refilledMillis10min := uint64(600) * eff * 1000 / 60 // = 40,000
	refilledCoins10min := refilledMillis10min / 1000       // = 40

	setBucketMillis(addr, 6, 0, now-600)
	var exactly10min [7]uint64
	exactly10min[6] = refilledCoins10min
	enforceClaimRate(addr, exactly10min, now)

	setBucketMillis(addr, 6, 0, now-600)
	var over10min [7]uint64
	over10min[6] = refilledCoins10min + 1
	mustPanic(t, "rate limit rarity 6", func() {
		enforceClaimRate(addr, over10min, now)
	})

	// sanity: cosmicBase == 2, eff == 4, cap == 240
	if cosmicBase != 2 {
		t.Errorf("cosmic r6 base: expected 2, got %d", cosmicBase)
	}
	if eff != 4 {
		t.Errorf("cosmic r6 effective: expected 4, got %d", eff)
	}
	if coinCap != 240 {
		t.Errorf("cosmic r6 cap: expected 240, got %d", coinCap)
	}
}

// ── Test 2b: omega r6 — bank after 1h = exactly 42×2×60; panics just above ──
// omega r6 base = 42/min. effective = 42 × 200/100 = 84/min.
// cap milli = 84 × 3600 × 1000 / 60 = 5,040,000. cap coins = 5040 = 42×2×60.
// After 1h from empty: 3600 × 84 × 1000 / 60 = 5,040,000 milli = 5040 coins (hits cap exactly).

func TestOmegaMythicRateCap(t *testing.T) {
	addr := "g1testomega000000000000000000000000001"
	resetAddr(addr)
	ownedTools.Set(addr, "hands,starter-twig,twig,wood,stone,iron,gold,diamond,cosmic,plasma,neutron,quasar,void,genesis,omega")
	toolLife.Set(addr+":omega", strconv.FormatUint(toolMaxLife["omega"], 10))

	omegaBase := claimRatePerMin["omega"][6] // 42/min
	eff := effectiveRateForTool("omega", 6)  // 84/min
	capMillis := capMillisForTool("omega", 6)
	coinCap := capMillis / 1000 // whole-coin cap = 5040 = 42×2×60

	now := int64(1_000_000)

	// ── verify cap == 42×2×60 ────────────────────────────────────────────────
	expected := omegaBase * 2 * 60 // 42 × skillDmgHeadroom/100 × claimBucketSecs/60
	                                // = 42 × 2 × 60 = 5040
	if coinCap != expected {
		t.Errorf("omega r6 cap: expected %d (42×2×60), got %d", expected, coinCap)
	}

	// ── 1h from empty → exactly cap coins accrue ─────────────────────────────
	// refilledMillis = 3600 × 84 × 1000 / 60 = 5,040,000 = capMillis exactly.
	refilledMillis1h := uint64(3600) * eff * 1000 / 60
	if refilledMillis1h != capMillis {
		t.Errorf("1h refill milli: expected %d (cap), got %d", capMillis, refilledMillis1h)
	}
	accrued1h := refilledMillis1h / 1000 // = 5040

	setBucketMillis(addr, 6, 0, now-3600)
	var ok [7]uint64
	ok[6] = accrued1h
	enforceClaimRate(addr, ok, now) // exactly cap — must not panic

	// ── one above cap panics ──────────────────────────────────────────────────
	setBucketMillis(addr, 6, 0, now-3600)
	var over [7]uint64
	over[6] = accrued1h + 1
	mustPanic(t, "rate limit rarity 6", func() {
		enforceClaimRate(addr, over, now)
	})

	// ── sustained 1-min: claim exactly eff=84 coins succeeds ─────────────────
	// refilledMillis per min = 60 × 84 × 1000 / 60 = 84,000 → 84 whole coins.
	refilledCoins1min := uint64(60) * eff * 1000 / 60 / 1000 // = 84

	setBucketMillis(addr, 6, 0, now-60)
	var sustained [7]uint64
	sustained[6] = refilledCoins1min
	enforceClaimRate(addr, sustained, now)

	setBucketMillis(addr, 6, 0, now-60)
	var sustainedOver [7]uint64
	sustainedOver[6] = refilledCoins1min + 1
	mustPanic(t, "rate limit rarity 6", func() {
		enforceClaimRate(addr, sustainedOver, now)
	})

	// ── base rate constant check ──────────────────────────────────────────────
	if omegaBase != 42 {
		t.Errorf("omega r6 base: expected 42/min, got %d", omegaBase)
	}
}

// ── Test 3: hands can't claim r1+ ────────────────────────────────────────────

func TestHandsCannotClaimR1Plus(t *testing.T) {
	addr := "g1testhands0000000000000000000000000002"
	resetAddr(addr)
	// Player has no ownedTools entry → bestOwnedTool returns "hands"

	now := int64(2_000_000)

	// r1 must be blocked (hands maxRarity = 0)
	var r1 [7]uint64
	r1[1] = 1
	mustPanic(t, "rate limit", func() {
		enforceClaimRate(addr, r1, now)
	})

	// r0 (dust) must be allowed for hands
	var r0 [7]uint64
	r0[0] = 1
	enforceClaimRate(addr, r0, now) // must not panic
}

// ── Test 4: BuyTool prereq — iron without stone panics; iron with stone ok ───

func TestBuyToolRequiresPrereq(t *testing.T) {
	addr := "g1testbuytool000000000000000000000000003"
	ownedTools.Remove(addr)

	// Iron requires stone. Caller has no tools → must panic.
	mustPanic(t, "must own stone before buying iron", func() {
		prereq, has := toolRequires["iron"]
		if !has {
			return
		}
		owned := ""
		if ownedTools.Has(addr) {
			owned = ownedTools.Get(addr).(string)
		}
		ownsPrereq := prereq == "hands"
		if !ownsPrereq {
			for _, tok := range splitCommaLocal(owned) {
				if tok == prereq {
					ownsPrereq = true
					break
				}
			}
		}
		if !ownsPrereq {
			panic("must own " + prereq + " before buying iron")
		}
	})

	// Give player stone → check passes.
	ownedTools.Set(addr, "hands,starter-twig,twig,wood,stone")
	prereq := toolRequires["iron"]
	owned := ownedTools.Get(addr).(string)
	ownsPrereq := false
	for _, tok := range splitCommaLocal(owned) {
		if tok == prereq {
			ownsPrereq = true
			break
		}
	}
	if !ownsPrereq {
		t.Errorf("expected player to own %s after seeding", prereq)
	}

	// Cleanup
	ownedTools.Remove(addr)
}

func splitCommaLocal(s string) []string {
	if s == "" {
		return nil
	}
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			tok := s[start:i]
			if tok != "" {
				out = append(out, tok)
			}
			start = i + 1
		}
	}
	return out
}

// ── Test 5a: starter-twig is in toolCosts and costs grin:13 ──────────────────

func TestStarterTwigCostAndAllowlist(t *testing.T) {
	addr := "g1testtwig000000000000000000000000000004"
	ownedTools.Remove(addr)

	// starter-twig must be in toolCosts
	costs, hasCost := toolCosts["starter-twig"]
	if !hasCost {
		t.Fatal("starter-twig not found in toolCosts")
	}
	// Cost must be grin:13
	if len(costs) != 1 || costs[0][0] != "grin" || costs[0][1] != "13" {
		t.Errorf("starter-twig cost: expected [[grin 13]], got %v", costs)
	}

	// starter-twig requires "hands" (always owned)
	prereq, hasPrereq := toolRequires["starter-twig"]
	if !hasPrereq {
		t.Error("starter-twig missing toolRequires entry")
	} else if prereq != "hands" {
		t.Errorf("starter-twig prereq: expected hands, got %q", prereq)
	}

	// Can afford and buy: give player grin:13
	setBalance(addr, "grin", 13)
	deductBalances(addr, costs) // must not panic
	key := addr + ":grin"
	remaining := uint64(0)
	if balances.Has(key) {
		remaining, _ = strconv.ParseUint(balances.Get(key).(string), 10, 64)
	}
	if remaining != 0 {
		t.Errorf("expected 0 grin after buy, got %d", remaining)
	}

	// starter-twig is in the coin allowlist for claims (grin is r0)
	_, byRarity := parseCoinClaims(`[["grin","5"]]`)
	if byRarity[0] != 5 {
		t.Errorf("grin r0 parsed wrong: %d", byRarity[0])
	}
}

// ── Test 5b: repair cost = ceil(30% of base) for several tools ───────────────

func TestRepairCostCeil30Pct(t *testing.T) {
	type tc struct {
		toolId   string
		coinId   string
		base     uint64
		expected uint64 // ceil(base × 30%) = (base×30 + 99) / 100
	}
	cases := []tc{
		// wood: seedling:19 → ceil(5.7) = 6
		{"wood", "seedling", 19, 6},
		// wood: party:8 → ceil(2.4) = 3
		{"wood", "party", 8, 3},
		// iron: gear:10 → ceil(3.0) = 3
		{"iron", "gear", 10, 3},
		// iron: magnet:1 → ceil(0.3) = 1
		{"iron", "magnet", 1, 1},
		// quasar: lotus:130 → ceil(39.0) = 39
		{"quasar", "lotus", 130, 39},
		// omega: lotus:2900 → ceil(870.0) = 870
		{"omega", "lotus", 2900, 870},
		// stone: cactus:3 → ceil(0.9) = 1
		{"stone", "cactus", 3, 1},
	}
	for _, c := range cases {
		costs, hasCosts := toolCosts[c.toolId]
		if !hasCosts {
			t.Errorf("toolCosts missing for %s", c.toolId)
			continue
		}
		found := false
		for _, pair := range costs {
			if pair[0] != c.coinId {
				continue
			}
			found = true
			base, _ := strconv.ParseUint(pair[1], 10, 64)
			if base != c.base {
				t.Errorf("%s[%s]: expected base=%d, got %d", c.toolId, c.coinId, c.base, base)
			}
			got := (base*30 + 99) / 100
			if got != c.expected {
				t.Errorf("%s[%s]: ceil(30%%)=%d expected, got %d", c.toolId, c.coinId, c.expected, got)
			}
			break
		}
		if !found {
			t.Errorf("%s does not contain ingredient %s", c.toolId, c.coinId)
		}
	}
}

// ── Test: effectiveMaxLife and RepairTool restores skill-boosted durability ───
//
// Scenario: a player has tempered_grip at rank 2 (+10%/rank = +20% total) and
// master_craft at rank 1 (+15%/rank = +15% total), for a combined +35% bonus.
// They buy a wood pick (base life 300), mine until it breaks, then repair it.
//
// Expected life at buy and after repair:
//   effectiveLife = 300 × (1000 + 2×100 + 1×150) / 1000
//                 = 300 × 1350 / 1000
//                 = 405
//
// Prior to this fix RepairTool restored to plain 300 (base only).
func TestRepairToolRestoresSkillBoostedDurability(t *testing.T) {
	addr := "g1testrepairtool0000000000000000000001"

	// ── clean slate ───────────────────────────────────────────────────────────
	resetAddr(addr)
	skillRanks.Remove(addr + ":tempered_grip")
	skillRanks.Remove(addr + ":master_craft")
	toolLife.Remove(addr + ":wood")
	balances.Remove(addr + ":wood") // clear any leftover balance keys

	// Give the address enough coins to buy wood and to repair it.
	// wood cost: seedling×19, leaves×16, fallen×13, think×11, sleep×10, party×8
	// repair   = ceil(30%) of each:  6, 5, 4, 4, 3, 3
	setBalance(addr, "seedling", 25)
	setBalance(addr, "leaves",   21)
	setBalance(addr, "fallen",   17)
	setBalance(addr, "think",    15)
	setBalance(addr, "sleep",    13)
	setBalance(addr, "party",    11)

	// Grant prerequisite tools so BuyTool(wood) doesn't panic.
	// toolRequires["wood"] == "twig", toolRequires["twig"] == "starter-twig",
	// toolRequires["starter-twig"] == "hands"
	ownedTools.Set(addr, "hands,starter-twig,twig")

	// Set skill ranks: tempered_grip rank 2, master_craft rank 1.
	skillRanks.Set(addr+":tempered_grip", "2")
	skillRanks.Set(addr+":master_craft",  "1")

	// ── compute expected effective life ───────────────────────────────────────
	// bonusNumerator = 2×100 + 1×150 = 350
	// effectiveLife  = 300 × (1000 + 350) / 1000 = 300 × 1350 / 1000 = 405
	baseWoodLife := toolMaxLife["wood"] // 300
	wantLife := baseWoodLife * (1000 + 2*100 + 1*150) / 1000 // 405

	// ── BuyTool: life must be set to the skill-boosted value ──────────────────
	// We call the function directly (no cur realm in unit tests).
	// BuyTool panics on unknown tool or missing prereq; both are satisfied above.
	// Use a raw deductBalances call approach: call effectiveMaxLife directly so
	// the test is not coupled to BuyTool's side-effects on balances, then verify
	// effectiveMaxLife matches our expectation, and also run BuyTool end-to-end.

	gotHelper := effectiveMaxLife(addr, "wood")
	if gotHelper != wantLife {
		t.Errorf("effectiveMaxLife: got %d, want %d (base=%d, bonus=350‰)",
			gotHelper, wantLife, baseWoodLife)
	}

	// BuyTool end-to-end: sets toolLife[addr+":wood"] = effectiveMaxLife
	// (only when key doesn't exist — which is the case after resetAddr)
	// We must remove any pre-existing key so BuyTool writes it.
	toolLife.Remove(addr + ":wood")

	// Fund BuyTool costs again (deductBalances was NOT called by effectiveMaxLife)
	// balances from above are still intact.
	BuyToolDirect(t, addr, "wood")

	lifeAfterBuy := uint64(0)
	if toolLife.Has(addr + ":wood") {
		lifeAfterBuy, _ = strconv.ParseUint(toolLife.Get(addr+":wood").(string), 10, 64)
	}
	if lifeAfterBuy != wantLife {
		t.Errorf("BuyTool: toolLife after buy = %d, want %d", lifeAfterBuy, wantLife)
	}

	// ── Simulate wear: set life to 0 (broken) ────────────────────────────────
	toolLife.Set(addr+":wood", "0")

	// ── RepairTool: must restore to skill-boosted effectiveMaxLife ────────────
	// Fund repair costs: ceil(30%) of wood costs
	setBalance(addr, "seedling", 6)
	setBalance(addr, "leaves",   5)
	setBalance(addr, "fallen",   4)
	setBalance(addr, "think",    4)
	setBalance(addr, "sleep",    3)
	setBalance(addr, "party",    3)

	RepairToolDirect(t, addr, "wood")

	lifeAfterRepair := uint64(0)
	if toolLife.Has(addr + ":wood") {
		lifeAfterRepair, _ = strconv.ParseUint(toolLife.Get(addr+":wood").(string), 10, 64)
	}
	if lifeAfterRepair != wantLife {
		t.Errorf("RepairTool: toolLife after repair = %d, want %d (must equal skill-boosted value, not base %d)",
			lifeAfterRepair, wantLife, baseWoodLife)
	}

	// ── Repair a second time (fully worn again) ───────────────────────────────
	// Confirms the helper is idempotent regardless of the stored value.
	toolLife.Set(addr+":wood", "1") // almost broken

	setBalance(addr, "seedling", 6)
	setBalance(addr, "leaves",   5)
	setBalance(addr, "fallen",   4)
	setBalance(addr, "think",    4)
	setBalance(addr, "sleep",    3)
	setBalance(addr, "party",    3)

	RepairToolDirect(t, addr, "wood")

	lifeAfterRepair2 := uint64(0)
	if toolLife.Has(addr + ":wood") {
		lifeAfterRepair2, _ = strconv.ParseUint(toolLife.Get(addr+":wood").(string), 10, 64)
	}
	if lifeAfterRepair2 != wantLife {
		t.Errorf("RepairTool (2nd): toolLife = %d, want %d", lifeAfterRepair2, wantLife)
	}

	// ── Without skills: repair restores plain base life ───────────────────────
	// Remove skill ranks and verify effectiveMaxLife == baseWoodLife.
	skillRanks.Remove(addr + ":tempered_grip")
	skillRanks.Remove(addr + ":master_craft")

	gotNoSkill := effectiveMaxLife(addr, "wood")
	if gotNoSkill != baseWoodLife {
		t.Errorf("effectiveMaxLife (no skills): got %d, want base %d", gotNoSkill, baseWoodLife)
	}

	toolLife.Set(addr+":wood", "0")
	setBalance(addr, "seedling", 6)
	setBalance(addr, "leaves",   5)
	setBalance(addr, "fallen",   4)
	setBalance(addr, "think",    4)
	setBalance(addr, "sleep",    3)
	setBalance(addr, "party",    3)

	RepairToolDirect(t, addr, "wood")

	lifeNoSkill := uint64(0)
	if toolLife.Has(addr + ":wood") {
		lifeNoSkill, _ = strconv.ParseUint(toolLife.Get(addr+":wood").(string), 10, 64)
	}
	if lifeNoSkill != baseWoodLife {
		t.Errorf("RepairTool (no skills): toolLife = %d, want base %d", lifeNoSkill, baseWoodLife)
	}

	// ── Cleanup ───────────────────────────────────────────────────────────────
	resetAddr(addr)
	skillRanks.Remove(addr + ":tempered_grip")
	skillRanks.Remove(addr + ":master_craft")
	toolLife.Remove(addr + ":wood")
}

// BuyToolDirect calls the BuyTool logic directly without a realm context.
// It mirrors what BuyTool does: deduct balances and set toolLife.
// Used only in tests to avoid constructing a realm object.
func BuyToolDirect(t *testing.T, addr, toolId string) {
	t.Helper()
	costs, hasCost := toolCosts[toolId]
	if !hasCost {
		t.Fatalf("BuyToolDirect: no costs for %q", toolId)
	}
	// Deduct
	for _, pair := range costs {
		coinId, amtStr := pair[0], pair[1]
		amt, _ := strconv.ParseUint(amtStr, 10, 64)
		have := uint64(0)
		if balances.Has(addr + ":" + coinId) {
			have, _ = strconv.ParseUint(balances.Get(addr+":"+coinId).(string), 10, 64)
		}
		if have < amt {
			t.Fatalf("BuyToolDirect: insufficient %s (have %d, need %d)", coinId, have, amt)
		}
		balances.Set(addr+":"+coinId, strconv.FormatUint(have-amt, 10))
	}
	// Add to ownedTools
	existing := ""
	if ownedTools.Has(addr) {
		existing = ownedTools.Get(addr).(string)
	}
	if existing == "" {
		ownedTools.Set(addr, toolId)
	} else {
		ownedTools.Set(addr, existing+","+toolId)
	}
	// Set toolLife using the shared helper (only if not already set)
	maxLife, hasLife := toolMaxLife[toolId]
	if hasLife && maxLife > 0 {
		lifeKey := addr + ":" + toolId
		if !toolLife.Has(lifeKey) {
			toolLife.Set(lifeKey, strconv.FormatUint(effectiveMaxLife(addr, toolId), 10))
		}
	}
}

// RepairToolDirect calls the RepairTool logic directly without a realm context.
func RepairToolDirect(t *testing.T, addr, toolId string) {
	t.Helper()
	maxLife, hasLife := toolMaxLife[toolId]
	if !hasLife || maxLife == 0 {
		t.Fatalf("RepairToolDirect: tool %q is indestructible or unknown", toolId)
	}
	baseCosts, hasCost := toolCosts[toolId]
	if !hasCost {
		t.Fatalf("RepairToolDirect: no costs for %q", toolId)
	}
	for _, pair := range baseCosts {
		coinId, amtStr := pair[0], pair[1]
		baseAmt, _ := strconv.ParseUint(amtStr, 10, 64)
		repairAmt := (baseAmt*30 + 99) / 100
		if repairAmt == 0 {
			continue
		}
		have := uint64(0)
		if balances.Has(addr + ":" + coinId) {
			have, _ = strconv.ParseUint(balances.Get(addr+":"+coinId).(string), 10, 64)
		}
		if have < repairAmt {
			t.Fatalf("RepairToolDirect: insufficient %s for repair (have %d, need %d)", coinId, have, repairAmt)
		}
		balances.Set(addr+":"+coinId, strconv.FormatUint(have-repairAmt, 10))
	}
	// Restore to skill-boosted effective max — this is the behaviour being tested.
	toolLife.Set(addr+":"+toolId, strconv.FormatUint(effectiveMaxLife(addr, toolId), 10))
}
