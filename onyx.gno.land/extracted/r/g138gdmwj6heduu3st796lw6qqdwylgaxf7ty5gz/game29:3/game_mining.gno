package game29

import (
	"crypto/ed25519"
	"encoding/hex"
	"sort"
	"strconv"
	"strings"
	"time"

	"chain/runtime"

	"gno.land/p/nt/ufmt/v0"
)

// ── Vouchers ─────────────────────────────────────────────────────────────────
//
// The server's claim signer (ed25519) signs (v2 format):
//
//   gnomoji-voucher-v2|<chainId>|<kind>|<player>|<nonce>|<expiry>|<compactPayload>
//
// compactPayload for kind="claim": coinId:amount pairs sorted alphabetically by
//   coinId, comma-joined. e.g. "cool:7,grin:100,joy:50"
// compactPayload for kind="ach": achievement IDs sorted alphabetically,
//   comma-joined. e.g. "blocks_1,g.grin.10"
//
// The realm reconstructs compactPayload from the coinsJson/idsJson argument
// before calling ed25519.Verify, then uses coinsJson/idsJson for actual logic.
//
// v2 changes from v1: realmPkgPath removed; payload is now compact (not raw JSON).
// Replay protection is retained via per-player on-chain nonces (claimNonces) and
// chain ID — a voucher cannot be replayed on game30 (different nonce tree state).
//
// nonce must be strictly greater than the player's last nonce (one shared
// sequence for all kinds), expiry is unix seconds and at most voucherMaxTTL
// in the future. A voucher is single-use and bound to one player and chain.

// VoucherMessage builds the canonical message that the server signs and the
// realm verifies. Format: gnomoji-voucher-v2|chainId|kind|player|nonce|expiry|compactPayload
//
// v2 changes from v1: realmPkgPath removed; payload is now compact (not raw JSON).
// For kind="claim": compactPayload = coinId:amount pairs sorted by coinId, comma-joined.
//   e.g. [["grin","100"],["joy","50"]] → "grin:100,joy:50"
// For kind="ach": compactPayload = achievement IDs sorted, comma-joined.
//   e.g. ["blocks_1","g.grin.10"] → "blocks_1,g.grin.10"
func VoucherMessage(kind, player string, nonce, expiry int64, payload string) string {
	return "gnomoji-voucher-v2|" + runtime.ChainID() + "|" + kind + "|" + player + "|" +
		strconv.FormatInt(nonce, 10) + "|" + strconv.FormatInt(expiry, 10) + "|" + payload
}

// compactClaimPayload builds the canonical compact payload for a "claim" voucher
// from a coinsJson string: [["coinId","amount"],...].
// Output: "coinId:amount" pairs sorted alphabetically by coinId, comma-joined.
// Must produce the same output as the TypeScript claimVoucherPayload() function
// in src/lib/game/claim-voucher.ts.
func compactClaimPayload(coinsJson string) string {
	rows := parseStringRows(coinsJson)
	// Collect unique coinId:amount pairs (duplicate coinIds summed).
	sums := map[string]uint64{}
	var order []string
	for _, row := range rows {
		if len(row) != 2 {
			continue
		}
		amt, _ := strconv.ParseUint(row[1], 10, 64)
		if _, seen := sums[row[0]]; !seen {
			order = append(order, row[0])
		}
		sums[row[0]] += amt
	}
	// Sort alphabetically by coinId.
	sort.Strings(order)
	parts := make([]string, 0, len(order))
	for _, coinId := range order {
		parts = append(parts, coinId+":"+strconv.FormatUint(sums[coinId], 10))
	}
	return strings.Join(parts, ",")
}

// compactAchPayload builds the canonical compact payload for an "ach" voucher
// from an idsJson string: ["achId",...].
// Output: achievement IDs sorted alphabetically, comma-joined.
func compactAchPayload(idsJson string) string {
	rows := parseStringList(idsJson)
	sort.Strings(rows)
	return strings.Join(rows, ",")
}

// LastNonce returns the last voucher nonce used by addr (0 if none).
func LastNonce(addr string) int64 {
	if !claimNonces.Has(addr) {
		return 0
	}
	n, _ := strconv.ParseInt(claimNonces.Get(addr).(string), 10, 64)
	return n
}

func useVoucher(kind, player string, nonce, expiry int64, payload, sigHex string) {
	if len(claimSignerPubKey) != 32 {
		panic("claims are disabled: no claim signer set")
	}
	now := time.Now().Unix()
	if expiry < now {
		panic("voucher expired")
	}
	if expiry > now+voucherMaxTTL {
		panic("voucher expiry too far in the future")
	}
	// FIX 1D: cache lastN to avoid calling LastNonce (2 AVL reads) twice.
	lastN := LastNonce(player)
	if nonce <= lastN {
		panic("voucher already used (nonce " + strconv.FormatInt(nonce, 10) + " ≤ last " + strconv.FormatInt(lastN, 10) + ")")
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != 64 {
		panic("invalid voucher signature encoding")
	}
	compact := payload
	if kind == "claim" {
		compact = compactClaimPayload(payload)
	} else if kind == "ach" {
		compact = compactAchPayload(payload)
	}
	if !ed25519.Verify(claimSignerPubKey, []byte(VoucherMessage(kind, player, nonce, expiry, compact)), sig) {
		panic("invalid voucher signature")
	}
	claimNonces.Set(player, strconv.FormatInt(nonce, 10))
}

// ── Claim-rate helpers ────────────────────────────────────────────────────────

// bestOwnedTool returns the highest-tier tool the caller owns that still has
// durability (or is indestructible). "hands" if none.
func bestOwnedTool(callerAddr string) string {
	if !ownedTools.Has(callerAddr) {
		return "hands"
	}
	ownedSet := map[string]bool{}
	for _, t := range strings.Split(ownedTools.Get(callerAddr).(string), ",") {
		if t = strings.TrimSpace(t); t != "" {
			ownedSet[t] = true
		}
	}
	for i := len(toolOrder) - 1; i >= 0; i-- {
		tid := toolOrder[i]
		if !ownedSet[tid] {
			continue
		}
		maxLife, hasMax := toolMaxLife[tid]
		if !hasMax || maxLife == 0 {
			return tid
		}
		lifeKey := callerAddr + ":" + tid
		if !toolLife.Has(lifeKey) || getU(&toolLife, lifeKey) > 0 {
			return tid
		}
	}
	return "hands"
}

func effectiveRateFor(tool string, r int) uint64 {
	rates, ok := claimRatePerMin[tool]
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

// loadPackedBuckets reads the packed claimBuckets entry for addr, or creates
// a fresh one. Returns [7][2]uint64 where [r][0]=accruedMillis, [r][1]=lastTs.
// Lazy-migrates from the old per-rarity key format (addr+":"+r) on first read
// after an upgrade.
func loadPackedBuckets(addr string, nowTs int64) [7][2]uint64 {
	var buckets [7][2]uint64
	// Set default initial values (will be overwritten if stored data exists).
	for r := 0; r < 7; r++ {
		buckets[r][0] = 0 // accruedMillis: start at zero, will refill on next bucketState call
		buckets[r][1] = uint64(nowTs)
	}

	// Try new packed format first.
	if claimBuckets.Has(addr) {
		packed := claimBuckets.Get(addr).(string)
		parts := strings.Split(packed, "|")
		for r := 0; r < 7 && r < len(parts); r++ {
			sub := strings.SplitN(parts[r], ":", 2)
			if len(sub) == 2 {
				buckets[r][0], _ = strconv.ParseUint(sub[0], 10, 64)
				ts, _ := strconv.ParseInt(sub[1], 10, 64)
				buckets[r][1] = uint64(ts)
			}
		}
		return buckets
	}

	// Lazy migration: check for old per-rarity keys.
	foundOld := false
	for r := 0; r < 7; r++ {
		oldKey := addr + ":" + strconv.Itoa(r)
		if claimBuckets.Has(oldKey) {
			foundOld = true
			parts := strings.SplitN(claimBuckets.Get(oldKey).(string), ":", 2)
			if len(parts) == 2 {
				buckets[r][0], _ = strconv.ParseUint(parts[0], 10, 64)
				ts, _ := strconv.ParseInt(parts[1], 10, 64)
				buckets[r][1] = uint64(ts)
			}
			claimBuckets.Remove(oldKey)
		}
	}
	if foundOld {
		// Write the migrated packed entry immediately so future reads are fast.
		claimBuckets.Set(addr, formatPackedBuckets(buckets))
	}
	return buckets
}

// formatPackedBuckets serializes [7][2]uint64 to "m0:t0|m1:t1|...|m6:t6".
func formatPackedBuckets(buckets [7][2]uint64) string {
	parts := make([]string, 7)
	for r := 0; r < 7; r++ {
		parts[r] = strconv.FormatUint(buckets[r][0], 10) + ":" + strconv.FormatInt(int64(buckets[r][1]), 10)
	}
	return strings.Join(parts, "|")
}

// bucketState returns (accruedMillis, capMillis) for rarity r at nowTs.
// allBuckets is the result of loadPackedBuckets — pass it in to avoid
// re-reading the AVL entry for each rarity check.
func bucketState(allBuckets [7][2]uint64, r int, tool string, nowTs int64) (uint64, uint64) {
	eff := effectiveRateFor(tool, r)
	capMillis := eff * uint64(claimBucketSecs) * 1000 / 60
	stored := allBuckets[r][0]
	lastTs := int64(allBuckets[r][1])
	// A new rarity bucket defaults to lastTs=nowTs, stored=0.
	// Give it the initial grace allowance so first-ever claims aren't blocked.
	if lastTs == nowTs && stored == 0 {
		stored = eff * uint64(claimInitialGraceSec) * 1000 / 60
	}
	if elapsed := nowTs - lastTs; elapsed > 0 {
		stored += uint64(elapsed) * eff * 1000 / 60
	}
	if stored > capMillis {
		stored = capMillis
	}
	return stored, capMillis
}

// enforceClaimRate checks every rarity first, then deducts (no partial writes).
// FIX 2A: reads claimBuckets once (packed format) instead of once per rarity.
func enforceClaimRate(callerAddr string, byRarity [7]uint64, nowTs int64, tool string) {
	maxR, ok := toolMaxRarity[tool]
	if !ok {
		maxR = 0
	}
	// Load all 7 rarity buckets in one AVL read (or lazy-migrate from old format).
	allBuckets := loadPackedBuckets(callerAddr, nowTs)
	var after [7]uint64
	for r := 0; r < 7; r++ {
		claimed := byRarity[r]
		if claimed == 0 {
			continue
		}
		if r > maxR {
			panic(ufmt.Sprintf("rate limit: %s tool cannot mine rarity %d coins", tool, r))
		}
		stored, capMillis := bucketState(allBuckets, r, tool, nowTs)
		if claimed*1000 > stored {
			panic(ufmt.Sprintf("rate limit rarity %d: tried %d, allowed %d (refills at %d/min, max bank %d)",
				r, claimed, stored/1000, effectiveRateFor(tool, r), capMillis/1000))
		}
		after[r] = stored - claimed*1000
	}
	// Compute new packed state and write once.
	var newBuckets [7][2]uint64
	for r := 0; r < 7; r++ {
		if byRarity[r] > 0 {
			newBuckets[r][0] = after[r]
			newBuckets[r][1] = uint64(nowTs)
		} else {
			newBuckets[r][0] = allBuckets[r][0]
			newBuckets[r][1] = allBuckets[r][1]
		}
	}
	claimBuckets.Set(callerAddr, formatPackedBuckets(newBuckets))
}

// decrementToolLife wears the best tool by the number of non-dust coins.
// FIX 1A: accepts pre-computed tool to avoid a second bestOwnedTool call.
func decrementToolLife(callerAddr string, totalCoins uint64, tool string) {
	if totalCoins == 0 {
		return
	}
	maxLife, hasMax := toolMaxLife[tool]
	if !hasMax || maxLife == 0 {
		return
	}
	lifeKey := callerAddr + ":" + tool
	current := effectiveMaxLife(callerAddr, tool)
	if toolLife.Has(lifeKey) {
		current = getU(&toolLife, lifeKey)
	}
	if totalCoins >= current {
		setU(&toolLife, lifeKey, 0)
	} else {
		setU(&toolLife, lifeKey, current-totalCoins)
	}
}

// parseCoinClaims parses [["coinId","amount"],...]. Unknown ids panic
// (allowlist); duplicate ids are summed; at most 20 entries.
func parseCoinClaims(coinsJson string) ([]string, map[string]uint64, [7]uint64) {
	coinMap := map[string]uint64{}
	var order []string
	var byRarity [7]uint64
	rows := parseStringRows(coinsJson)
	if len(rows) == 0 {
		panic("no coins to claim")
	}
	if len(rows) > 20 {
		panic("too many coin entries (max 20)")
	}
	for _, row := range rows {
		if len(row) != 2 {
			panic("each claim entry must be [coinId, amount]")
		}
		rarity, known := coinRarity[row[0]]
		if !known {
			panic("unknown coin id: " + row[0])
		}
		amt, err := strconv.ParseUint(row[1], 10, 64)
		if err != nil || amt == 0 || amt > 1000000 {
			panic("invalid amount for " + row[0])
		}
		if _, seen := coinMap[row[0]]; !seen {
			order = append(order, row[0])
		}
		coinMap[row[0]] += amt
		byRarity[rarity] += amt
	}
	return order, coinMap, byRarity
}

func guildBonusPct(addr string) uint64 {
	if !playerGuild.Has(addr) {
		return 0
	}
	gid := playerGuild.Get(addr).(string)
	n := 0
	guildMembers.Iterate(gid+":", gid+";", func(string, any) bool {
		n++
		return false
	})
	if n <= 1 {
		return 0
	}
	if n-1 > 9 {
		return 9
	}
	return uint64(n - 1)
}

// creditMined credits a mined/reward amount to addr, capped by the vein, and
// records lifetime total. Returns the amount credited.
// FIX 1B: miners update removed — caller must addU(&miners, addr, total) after the loop.
func creditMined(addr, coinId string, amt uint64) uint64 {
	amt = takeFromVein(coinId, amt)
	if amt == 0 {
		return 0
	}
	creditBal(addr, coinId, amt)
	addU(&lifetimeMined, addr+":"+coinId, amt)
	return amt
}

// creditReward credits a reward (medal/achievement or any future event). It
// still draws from the vein (so rewards can't exceed supply caps) but is
// tracked in its own counter: it never touches lifetimeMined or the miners
// leaderboard, so rewards can't unlock grind medals or inflate rankings.
func creditReward(addr, coinId string, amt uint64) uint64 {
	amt = takeFromVein(coinId, amt)
	if amt == 0 {
		return 0
	}
	creditBal(addr, coinId, amt)
	addU(&rewarded, addr+":"+coinId, amt)
	return amt
}

// ── Claims ───────────────────────────────────────────────────────────────────

// ClaimAndMint credits mined coins to the caller's on-chain balance.
// coinsJson: [["coinId","amount"],...]. Requires a server voucher
// (see VoucherMessage) for exactly this coinsJson, plus the on-chain rate cap
// for the caller's best tool, the coin allowlist and the vein caps.
// Returns a JSON object of what was actually credited (after bonuses/veins).
func ClaimAndMint(cur realm, coinsJson string, nonce int64, expiry int64, sigHex string) string {
	caller := requirePlayer(cur)
	now := time.Now().Unix()
	// Voucher first (clear errors for forged/replayed vouchers); a failed tx
	// reverts, so a valid voucher isn't burned by the cooldown below.
	useVoucher("claim", caller, nonce, expiry, coinsJson, sigHex)
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < claimCooldownSec {
			panic("too fast — " + strconv.FormatInt(claimCooldownSec-(now-last), 10) + "s remaining (1 min cooldown)")
		}
	}
	lastClaim.Set(caller, strconv.FormatInt(now, 10))

	order, coinMap, byRarity := parseCoinClaims(coinsJson)

	// FIX 1A: compute tool once and pass to both functions.
	tool := bestOwnedTool(caller)
	enforceClaimRate(caller, byRarity, now, tool)

	nonDust := uint64(0)
	for r := 1; r < 7; r++ {
		nonDust += byRarity[r]
	}
	decrementToolLife(caller, nonDust, tool)

	bonus := guildBonusPct(caller)
	pass := HasActivePass(caller)
	// rarityXpWeights maps rarity index (0=dust … 6=mythic) to XP per credited coin.
	// Matches the client-side rarityXp() table in store/helpers.ts exactly.
	rarityXpWeights := [7]uint64{3, 8, 20, 50, 120, 300, 800}
	var out []string
	sessionXp := uint64(0)
	// FIX 1B: accumulate miners total outside the loop.
	totalCredited := uint64(0)
	for _, coinId := range order {
		amt := coinMap[coinId]
		if bonus > 0 {
			amt += amt * bonus / 100
		}
		if pass {
			amt += amt / 2
		}
		got := creditMined(caller, coinId, amt)
		totalCredited += got
		out = append(out, jsonStr(coinId)+":"+strconv.FormatUint(got, 10))
		// Accumulate rarity-weighted XP for each credited coin.
		r := coinRarity[coinId]
		if r < 0 {
			r = 0
		} else if r > 6 {
			r = 6
		}
		sessionXp += got * rarityXpWeights[r]
	}
	// FIX 1B: single miners write after loop instead of N writes inside loop.
	if totalCredited > 0 {
		addU(&miners, caller, totalCredited)
	}
	if sessionXp > 0 {
		addU(&playerXp, caller, sessionXp)
	}
	return "{" + strings.Join(out, ",") + "}"
}

// ClaimMine (game27/28 two-step flow) is retired: pending mints are gone.
func ClaimMine(cur realm, coinsJson string) {
	panic("ClaimMine is retired in game29 — use ClaimAndMint with a server voucher")
}

// PendingMints is kept for client compatibility; game29 has no pending step.
func PendingMints(playerAddr string) string { return `{"pending":[]}` }

// ClaimAllowance returns the current per-rarity allowance for addr.
func ClaimAllowance(playerAddr string) string {
	tool := bestOwnedTool(playerAddr)
	now := time.Now().Unix()
	// Load packed buckets once for all 7 rarities.
	allBuckets := loadPackedBuckets(playerAddr, now)
	var parts []string
	for r := 0; r < 7; r++ {
		stored, _ := bucketState(allBuckets, r, tool, now)
		maxR, ok := toolMaxRarity[tool]
		if !ok || r > maxR {
			stored = 0
		}
		parts = append(parts, `"r`+strconv.Itoa(r)+`":`+strconv.FormatUint(stored/1000, 10))
	}
	return "{" + strings.Join(parts, ",") + `,"tool":` + jsonStr(tool) + `,"nextNonce":` + strconv.FormatInt(LastNonce(playerAddr)+1, 10) + "}"
}
