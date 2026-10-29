package game28

import (
	"strconv"
	"strings"
	"time"

	"chain/runtime"
	"gno.land/p/nt/ufmt/v0"
)


func init() {
	admin = runtime.OriginCaller()
}

// ── Admin ────────────────────────────────────────────────────────────────────

func isAdmin(cur realm) bool {
	caller := cur.Previous().Address()
	return caller == admin || (minterAddr != address("") && caller == minterAddr)
}

// SetMinter registers the authorized minter realm address so it can call
// ClearPendingMints. Called once after minter5 is deployed.
func SetMinter(cur realm, newMinter string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can set minter")
	}
	minterAddr = address(newMinter)
}

func UpdateConfig(cur realm, newAdmin string) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	admin = address(newAdmin)
}

func SetPaused(cur realm, p bool) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	paused = p
}

func requireNotPaused() {
	if paused {
		panic("game is paused")
	}
}

// ── Blacklist ─────────────────────────────────────────────────────────────────

// BanAddress bans a player address. durationSecs=0 means permanent.
func BanAddress(cur realm, targetAddr string, reason string, durationSecs int64) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can ban")
	}
	if !strings.HasPrefix(targetAddr, "g1") {
		panic("invalid address")
	}
	expiry := int64(0) // 0 = permanent
	if durationSecs > 0 {
		expiry = time.Now().Unix() + durationSecs
	}
	timestamp := strconv.FormatInt(time.Now().Unix(), 10)
	blacklist.Set(targetAddr, reason+":"+timestamp)
	banExpiries.Set(targetAddr, strconv.FormatInt(expiry, 10))
}

// UnbanAddress removes a ban.
func UnbanAddress(cur realm, targetAddr string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can unban")
	}
	blacklist.Remove(targetAddr)
	banExpiries.Remove(targetAddr)
}

// BlacklistStatus returns the ban status of an address as a JSON string.
func BlacklistStatus(addr string) string {
	if !blacklist.Has(addr) {
		return `{"banned":false}`
	}
	entry := blacklist.Get(addr).(string)
	expiryStr := banExpiries.Get(addr).(string)
	expiry, _ := strconv.ParseInt(expiryStr, 10, 64)
	now := time.Now().Unix()
	if expiry > 0 && now >= expiry {
		// Expired ban — treat as clean
		return `{"banned":false}`
	}
	parts := strings.SplitN(entry, ":", 2)
	reason := parts[0]
	permanent := expiry == 0
	remainSecs := int64(0)
	if !permanent && expiry > 0 {
		remainSecs = expiry - now
	}
	if permanent {
		return `{"banned":true,"reason":"` + reason + `","permanent":true}`
	}
	return `{"banned":true,"reason":"` + reason + `","permanent":false,"remainingSecs":` + strconv.FormatInt(remainSecs, 10) + `}`
}

// isBlacklisted checks if an address is currently banned (unexpired).
func isBlacklisted(addr string) bool {
	if !blacklist.Has(addr) {
		return false
	}
	expiryStr := banExpiries.Get(addr).(string)
	expiry, _ := strconv.ParseInt(expiryStr, 10, 64)
	if expiry == 0 {
		return true // permanent
	}
	return time.Now().Unix() < expiry
}

// ── Guilds ───────────────────────────────────────────────────────────────────

const maxGuildMembers = 10
const maxGuildNameLen = 24

func CreateGuild(cur realm, name string) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	if playerGuild.Has(caller) {
		panic("already in a guild")
	}
	if len(name) < 3 {
		panic("guild name too short (min 3 chars)")
	}
	if len(name) > maxGuildNameLen {
		panic("guild name too long (max 24 chars)")
	}

	prefix := caller
	if len(prefix) > 8 {
		prefix = caller[:8]
	}
	guildId := "guild-" + prefix + "-" + strconv.FormatInt(time.Now().Unix(), 36)
	guild := `{"guildId":"` + guildId + `","name":"` + name + `","leader":"` + caller + `","memberCount":1,"createdAt":` + strconv.FormatInt(time.Now().Unix(), 10) + `}`
	guilds.Set(guildId, guild)
	guildMembers.Set(guildId+":"+caller, "1")
	playerGuild.Set(caller, guildId)
	return guildId
}

func JoinGuild(cur realm, guildId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	if playerGuild.Has(caller) {
		panic("already in a guild — leave current guild first")
	}
	if !guilds.Has(guildId) {
		panic("guild not found")
	}

	// Count current members
	memberCount := 0
	guildMembers.Iterate(guildId+":", guildId+":\xFF", func(key string, val any) bool {
		memberCount++
		return false
	})
	if memberCount >= maxGuildMembers {
		panic("guild is full (max 10 members)")
	}

	// Increment memberCount in guild JSON (simple string replacement)
	guildJson := guilds.Get(guildId).(string)
	oldCount := `"memberCount":` + strconv.Itoa(memberCount)
	newCount := `"memberCount":` + strconv.Itoa(memberCount+1)
	guilds.Set(guildId, strings.Replace(guildJson, oldCount, newCount, 1))

	guildMembers.Set(guildId+":"+caller, "1")
	playerGuild.Set(caller, guildId)
}

func LeaveGuild(cur realm) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if !playerGuild.Has(caller) {
		panic("not in a guild")
	}
	guildId := playerGuild.Get(caller).(string)

	// Count members to determine if guild dissolves
	memberCount := 0
	guildMembers.Iterate(guildId+":", guildId+":\xFF", func(key string, val any) bool {
		memberCount++
		return false
	})

	guildMembers.Remove(guildId + ":" + caller)
	playerGuild.Remove(caller)

	if memberCount <= 1 {
		// Last member — dissolve the guild
		guilds.Remove(guildId)
	} else {
		// Update member count
		guildJson := guilds.Get(guildId).(string)
		oldCount := `"memberCount":` + strconv.Itoa(memberCount)
		newCount := `"memberCount":` + strconv.Itoa(memberCount-1)
		guilds.Set(guildId, strings.Replace(guildJson, oldCount, newCount, 1))
	}
}

func PlayerGuild(addr string) string {
	if !playerGuild.Has(addr) {
		return ""
	}
	guildId := playerGuild.Get(addr).(string)
	if !guilds.Has(guildId) {
		return ""
	}
	return guilds.Get(guildId).(string)
}

func GuildInfo(guildId string) string {
	if !guilds.Has(guildId) {
		return ""
	}
	return guilds.Get(guildId).(string)
}

func TopGuilds(limit int) string {
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	var parts []string
	count := 0
	guilds.Iterate("", "\xFF", func(key string, val any) bool {
		if count >= limit {
			return true
		}
		parts = append(parts, val.(string))
		count++
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}

// ── Gnome Pass ────────────────────────────────────────────────────────────────

// gnomePassCostPer30Days is the cost per 30-day pass in ugnot (5 GNOT).
const gnomePassCostPer30Days = uint64(5000000)

// ActivateGnomePass purchases a Gnome Pass for the caller.
func ActivateGnomePass(cur realm, durationDays int64) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	if durationDays <= 0 {
		durationDays = 30
	}

	periods := (uint64(durationDays) + 29) / 30
	requiredUgnot := int64(gnomePassCostPer30Days * periods)
	_ = requiredUgnot // no-op on Onyx testnet

	now := time.Now().Unix()
	base := now
	if gnomePasses.Has(caller) {
		existing, _ := strconv.ParseInt(gnomePasses.Get(caller).(string), 10, 64)
		if existing > now {
			base = existing
		}
	}
	expiry := base + durationDays*86400
	gnomePasses.Set(caller, strconv.FormatInt(expiry, 10))
}

// GnomePassExpiry returns the unix timestamp when the pass expires (0 = no pass).
func GnomePassExpiry(addr string) int64 {
	if !gnomePasses.Has(addr) {
		return 0
	}
	expiry, _ := strconv.ParseInt(gnomePasses.Get(addr).(string), 10, 64)
	return expiry
}

// HasActivePass returns true if the address has an active (non-expired) pass.
func HasActivePass(addr string) bool {
	expiry := GnomePassExpiry(addr)
	return expiry > time.Now().Unix()
}

// GnomePassCount returns the total number of addresses with an active pass (admin-only).
func GnomePassCount(cur realm) int {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	count := 0
	gnomePasses.Iterate("", "\xFF", func(key string, val any) bool {
		expiry, _ := strconv.ParseInt(val.(string), 10, 64)
		if expiry > time.Now().Unix() {
			count++
		}
		return false
	})
	return count
}

// WithdrawFunds is a no-op on Onyx testnet.
func WithdrawFunds(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
}

// ── Claim-rate helpers ────────────────────────────────────────────────────────

// bestOwnedTool returns the highest-tier tool the caller owns that still has
// durability (life > 0, or life = 0 meaning indestructible). Returns "hands"
// if no other tool qualifies.
func bestOwnedTool(callerAddr string) string {
	if !ownedTools.Has(callerAddr) {
		return "hands"
	}
	owned := ownedTools.Get(callerAddr).(string)
	ownedSet := make(map[string]bool)
	for _, t := range strings.Split(owned, ",") {
		t = strings.TrimSpace(t)
		if t != "" {
			ownedSet[t] = true
		}
	}

	// Walk toolOrder in reverse (best to worst) to find the highest viable tool.
	best := "hands"
	for i := len(toolOrder) - 1; i >= 0; i-- {
		tid := toolOrder[i]
		if !ownedSet[tid] {
			continue
		}
		maxLife, hasMax := toolMaxLife[tid]
		if !hasMax {
			// Not in toolMaxLife — treat as indestructible (hands, etc.)
			best = tid
			break
		}
		if maxLife == 0 {
			// Indestructible
			best = tid
			break
		}
		// Consumable — check remaining life
		lifeKey := callerAddr + ":" + tid
		if !toolLife.Has(lifeKey) {
			// Life not set yet (tool just bought, life will be set on first claim)
			best = tid
			break
		}
		life, _ := strconv.ParseUint(toolLife.Get(lifeKey).(string), 10, 64)
		if life > 0 {
			best = tid
			break
		}
		// life == 0 → broken, try next best
	}
	return best
}

// enforceClaimRate enforces the per-rarity token-bucket rate cap for a claim.
// byRarity[r] = total coins claimed of rarity r BEFORE guild/pass bonuses.
// Panics if any rarity bucket is exhausted.
// Also decrements claimBuckets state.
func enforceClaimRate(callerAddr string, byRarity [7]uint64, nowTs int64) {
	tool := bestOwnedTool(callerAddr)
	rates, hasRates := claimRatePerMin[tool]
	if !hasRates {
		// Unknown tool — fall back to hands rates
		rates = claimRatePerMin["hands"]
	}

	for r := 0; r < 7; r++ {
		claimed := byRarity[r]
		if claimed == 0 {
			continue
		}

		// Max rarity check: the best tool must be able to mine this rarity
		maxR, hasTool := toolMaxRarity[tool]
		if !hasTool {
			maxR = 0
		}
		if r > maxR {
			panic(ufmt.Sprintf("rate limit: %s tool cannot mine rarity %d coins", tool, r))
		}

		// Token bucket: bucketKey = "addr:r"
		// State stored as "accruedMillis:lastTs" where accruedMillis = whole-coin
		// allowance × 1000. Milli-units let fractional-per-second rates accumulate
		// without integer truncation: refill = elapsedSecs × effectiveRate × 1000 / 60,
		// which is exact for any integer effectiveRate (coins/min).
		bucketKey := callerAddr + ":" + strconv.Itoa(r)

		// Effective rate (coins/min) with skill headroom multiplied in.
		baseRate := rates[r] // coins/min from table
		var effectiveRate uint64
		if r == 0 {
			// dust: dmg headroom × dust-yield headroom
			effectiveRate = (baseRate * skillDmgHeadroom * skillDustHeadroom) / 10000
		} else {
			// common–mythic: dmg headroom only
			effectiveRate = (baseRate * skillDmgHeadroom) / 100
		}
		if effectiveRate == 0 {
			effectiveRate = baseRate // guard: indestructible tools at r0 still refill
		}

		// Cap in milli-units: effectiveRate coins/min × claimBucketSecs seconds × 1000 / 60
		capMillis := effectiveRate * uint64(claimBucketSecs) * 1000 / 60
		// Whole-coin cap (for error messages)
		maxBucket := capMillis / 1000

		// Load stored milli-units; default to full cap (first claim after deploy).
		storedMillis := capMillis
		lastTs := nowTs
		if claimBuckets.Has(bucketKey) {
			state := claimBuckets.Get(bucketKey).(string)
			parts := strings.SplitN(state, ":", 2)
			if len(parts) == 2 {
				storedMillis, _ = strconv.ParseUint(parts[0], 10, 64)
				lastTs, _ = strconv.ParseInt(parts[1], 10, 64)
			}
		}

		// Refill: add elapsedSecs × effectiveRate × 1000 / 60 milli-units.
		// Single multiply-then-divide — no intermediate per-second truncation.
		elapsed := nowTs - lastTs
		if elapsed > 0 {
			// refilledMillis = elapsed × effectiveRate × 1000 / 60
			refilledMillis := uint64(elapsed) * effectiveRate * 1000 / 60
			storedMillis += refilledMillis
			if storedMillis > capMillis {
				storedMillis = capMillis
			}
		}

		// Convert to whole coins for the claim check (floor).
		accrued := storedMillis / 1000

		// Check and deduct
		if claimed > accrued {
			panic(ufmt.Sprintf(
				"rate limit rarity %d: tried %d, allowed %d (refills at %d/min, max bank %d)",
				r, claimed, accrued, effectiveRate, maxBucket,
			))
		}
		// Deduct in milli-units (exact: claimed coins × 1000 milli each)
		storedMillis -= claimed * 1000

		// Persist
		claimBuckets.Set(bucketKey, strconv.FormatUint(storedMillis, 10)+":"+strconv.FormatInt(nowTs, 10))
	}
}

// decrementToolLife decrements the equipped tool's remaining life by totalCoins
// (proxy for blocks broken; each claimed coin ≈ 1 block of wear).
// Only affects consumable tools (life > 0 in toolMaxLife).
// Does NOT panic when life reaches 0 — the tool simply breaks and falls back
// to a worse tool on the next claim.
func decrementToolLife(callerAddr string, totalCoins uint64) {
	if totalCoins == 0 {
		return
	}
	tool := bestOwnedTool(callerAddr)
	maxLife, hasMax := toolMaxLife[tool]
	if !hasMax || maxLife == 0 {
		return // indestructible
	}
	lifeKey := callerAddr + ":" + tool
	current := maxLife
	if toolLife.Has(lifeKey) {
		current, _ = strconv.ParseUint(toolLife.Get(lifeKey).(string), 10, 64)
	}
	if totalCoins >= current {
		toolLife.Set(lifeKey, "0")
	} else {
		toolLife.Set(lifeKey, strconv.FormatUint(current-totalCoins, 10))
	}
}

// ── Mining ───────────────────────────────────────────────────────────────────

// parseCoinClaims parses a coinsJson array into (coinId → amount) and
// (byRarity[0..6]) maps. Panics on unknown coin ids (allowlist enforcement).
// Does NOT apply any bonuses — call before guild/pass bonus application.
func parseCoinClaims(coinsJson string) (map[string]uint64, [7]uint64) {
	coinMap := make(map[string]uint64)
	var byRarity [7]uint64

	coinsJson = strings.TrimSpace(coinsJson)
	coinsJson = strings.TrimPrefix(coinsJson, "[")
	coinsJson = strings.TrimSuffix(coinsJson, "]")

	for _, entry := range splitJsonArray(coinsJson) {
		entry = strings.TrimSpace(entry)
		entry = strings.TrimPrefix(entry, "[")
		entry = strings.TrimSuffix(entry, "]")
		parts := strings.SplitN(entry, ",", 2)
		if len(parts) != 2 {
			continue
		}
		coinId := strings.Trim(strings.TrimSpace(parts[0]), `"`)
		amtStr := strings.Trim(strings.TrimSpace(parts[1]), `"`)
		amt, err := strconv.ParseUint(amtStr, 10, 64)
		if err != nil || amt == 0 {
			continue
		}

		// ── Coin allowlist: panic on any id not in the catalog ───────────────
		rarity, known := coinRarity[coinId]
		if !known {
			panic("unknown coin id: " + coinId)
		}

		coinMap[coinId] += amt
		byRarity[rarity] += amt
	}

	return coinMap, byRarity
}

// applyGuildAndPassBonuses applies guild yield bonus and Gnome Pass bonus
// to a per-coin map. Returns a new map with the final amounts.
func applyGuildAndPassBonuses(callerAddr string, coinMap map[string]uint64) map[string]uint64 {
	// Guild yield bonus: +1% per other member, max 9%
	bonusPct := 0
	if playerGuild.Has(callerAddr) {
		guildId := playerGuild.Get(callerAddr).(string)
		memberCount := 0
		guildMembers.Iterate(guildId+":", guildId+":\xFF", func(k string, v any) bool {
			memberCount++
			return false
		})
		bonusPct = memberCount - 1
		if bonusPct > 9 {
			bonusPct = 9
		}
	}
	hasPass := HasActivePass(callerAddr)

	result := make(map[string]uint64, len(coinMap))
	for coinId, amt := range coinMap {
		if bonusPct > 0 {
			amt = amt + (amt*uint64(bonusPct))/100
		}
		if hasPass {
			amt = amt + amt/2 // +50%
		}
		result[coinId] = amt
	}
	return result
}

// ClaimMine records mined coins into pending mints for the caller.
// coinsJson format: [["coinId","amount"],...]
func ClaimMine(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	// Velocity limit: minimum 60 seconds between ClaimMine calls.
	now := time.Now().Unix()
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < 60 {
			remaining := 60 - (now - last)
			panic("claiming too fast — " + strconv.FormatInt(remaining, 10) + "s remaining (1 min cooldown)")
		}
	}
	lastClaim.Set(caller, strconv.FormatInt(now, 10))

	// Parse + allowlist check
	coinMap, byRarity := parseCoinClaims(coinsJson)

	// Rate-cap enforcement (BEFORE guild/pass bonuses)
	enforceClaimRate(caller, byRarity, now)

	// Decrement tool life (proxy: total non-r0 coins = blocks worn)
	totalNonDust := uint64(0)
	for r := 1; r < 7; r++ {
		totalNonDust += byRarity[r]
	}
	decrementToolLife(caller, totalNonDust)

	// Apply guild + pass bonuses
	finalMap := applyGuildAndPassBonuses(caller, coinMap)

	// Credit to pendingMints
	for coinId, amt := range finalMap {
		if amt == 0 {
			continue
		}
		// Cap at vein supply if registered
		if veinSupply.Has(coinId) {
			vsStr := veinSupply.Get(coinId).(string)
			p2 := strings.SplitN(vsStr, ":", 2)
			if len(p2) == 2 {
				rem, _ := strconv.ParseUint(p2[0], 10, 64)
				if rem == 0 {
					continue
				}
				if amt > rem {
					amt = rem
				}
				maxV, _ := strconv.ParseUint(p2[1], 10, 64)
				veinSupply.Set(coinId, ufmt.Sprintf("%d:%d", rem-amt, maxV))
			}
		}
		key := caller + ":" + coinId
		ex := uint64(0)
		if pendingMints.Has(key) {
			ex, _ = strconv.ParseUint(pendingMints.Get(key).(string), 10, 64)
		}
		pendingMints.Set(key, strconv.FormatUint(ex+amt, 10))
		lifEx := uint64(0)
		if lifetimeMined.Has(key) {
			lifEx, _ = strconv.ParseUint(lifetimeMined.Get(key).(string), 10, 64)
		}
		lifetimeMined.Set(key, strconv.FormatUint(lifEx+amt, 10))
		mt := uint64(0)
		if miners.Has(caller) {
			mt, _ = strconv.ParseUint(miners.Get(caller).(string), 10, 64)
		}
		miners.Set(caller, strconv.FormatUint(mt+amt, 10))
	}
}

// ClearPendingMints is called by the treasury server after successful GRC20 minting.
func ClearPendingMints(cur realm, playerAddr string, coinsJson string) {
	if !isAdmin(cur) {
		panic("unauthorized: only admin/minter can clear pending mints")
	}
	coinsJson = strings.TrimSpace(coinsJson)
	coinsJson = strings.TrimPrefix(coinsJson, "[")
	coinsJson = strings.TrimSuffix(coinsJson, "]")
	for _, entry := range splitJsonArray(coinsJson) {
		coinId := strings.Trim(strings.TrimSpace(entry), `"`)
		if coinId == "" {
			continue
		}
		pendingKey := playerAddr + ":" + coinId
		if pendingMints.Has(pendingKey) {
			amtStr := pendingMints.Get(pendingKey).(string)
			amt, err := strconv.ParseUint(amtStr, 10, 64)
			if err == nil && amt > 0 {
				balKey := playerAddr + ":" + coinId
				existing := uint64(0)
				if balances.Has(balKey) {
					existing, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
				}
				balances.Set(balKey, strconv.FormatUint(existing+amt, 10))
			}
		}
		pendingMints.Remove(pendingKey)
	}
}

// ClaimAndMint records mined coins AND immediately credits them to balances.
func ClaimAndMint(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	// Velocity limit: 1 minute cooldown shared with ClaimMine.
	now := time.Now().Unix()
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < 60 {
			remaining := 60 - (now - last)
			panic("too fast — " + strconv.FormatInt(remaining, 10) + "s remaining (1 min cooldown)")
		}
	}
	lastClaim.Set(caller, strconv.FormatInt(now, 10))

	// Parse + allowlist check
	coinMap, byRarity := parseCoinClaims(coinsJson)

	// Rate-cap enforcement (BEFORE guild/pass bonuses)
	enforceClaimRate(caller, byRarity, now)

	// Decrement tool life
	totalNonDust := uint64(0)
	for r := 1; r < 7; r++ {
		totalNonDust += byRarity[r]
	}
	decrementToolLife(caller, totalNonDust)

	// Apply guild + pass bonuses
	finalMap := applyGuildAndPassBonuses(caller, coinMap)

	// Credit directly to balances (no pendingMints)
	for coinId, amt := range finalMap {
		if amt == 0 {
			continue
		}
		// Cap at vein supply if registered
		if veinSupply.Has(coinId) {
			vsStr := veinSupply.Get(coinId).(string)
			p2 := strings.SplitN(vsStr, ":", 2)
			if len(p2) == 2 {
				rem, _ := strconv.ParseUint(p2[0], 10, 64)
				if rem == 0 {
					continue
				}
				if amt > rem {
					amt = rem
				}
				maxV, _ := strconv.ParseUint(p2[1], 10, 64)
				veinSupply.Set(coinId, ufmt.Sprintf("%d:%d", rem-amt, maxV))
			}
		}
		key := caller + ":" + coinId
		bal := uint64(0)
		if balances.Has(key) {
			bal, _ = strconv.ParseUint(balances.Get(key).(string), 10, 64)
		}
		balances.Set(key, strconv.FormatUint(bal+amt, 10))
		lifEx := uint64(0)
		if lifetimeMined.Has(key) {
			lifEx, _ = strconv.ParseUint(lifetimeMined.Get(key).(string), 10, 64)
		}
		lifetimeMined.Set(key, strconv.FormatUint(lifEx+amt, 10))
		mt := uint64(0)
		if miners.Has(caller) {
			mt, _ = strconv.ParseUint(miners.Get(caller).(string), 10, 64)
		}
		miners.Set(caller, strconv.FormatUint(mt+amt, 10))
	}
}
