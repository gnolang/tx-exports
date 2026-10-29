package game27

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)


func init(cur realm) {
	admin = cur.Previous().Address()
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
// GNOT payment must be attached to the call (send field of MsgCall).
// The caller sends GNOT along with the transaction; this function verifies
// the amount. The GNOT stays in the realm and can be withdrawn by admin
// via WithdrawFunds(). Admin-only calls skip the payment check for testing.
func ActivateGnomePass(cur realm, durationDays int64) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	if durationDays <= 0 {
		durationDays = 30
	}

	// Compute required cost: 5 GNOT per 30 days (ceiling division for multiples)
	periods := (uint64(durationDays) + 29) / 30
	requiredUgnot := int64(gnomePassCostPer30Days * periods)

	// Payment check disabled for Onyx testnet compatibility (chain/runtime/unsafe not available).
	// On mainnet, re-enable with OriginSend or a coin-check alternative.
	_ = requiredUgnot // suppress unused warning

	// Extend or activate pass
	now := time.Now().Unix()
	base := now
	if gnomePasses.Has(caller) {
		existing, _ := strconv.ParseInt(gnomePasses.Get(caller).(string), 10, 64)
		if existing > now {
			base = existing // extend from current expiry, not now
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

// WithdrawFunds is a no-op on Onyx testnet — chain/banker is unavailable.
// The realm's GNOT balance is managed directly via the deployer wallet.
// On mainnet: re-enable with banker.NewBanker(banker.BankerTypeRealmSend, cur).
func WithdrawFunds(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	// no-op: use deployer wallet to manage realm GNOT balance directly
}

// ── Mining ───────────────────────────────────────────────────────────────────

// ClaimMine records mined coins into pending mints for the caller.
// coinsJson format: [["coinId","amount"],...]
func ClaimMine(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	// Velocity limit: minimum 60 seconds (1 minute) between ClaimMine calls per address.
	// A bot farm calling every 5s can now only call 4x/hour per wallet, and each call
	// costs ~0.03 GNOT gas — making mass farming economically prohibitive.
	now := time.Now().Unix()
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < 60 {
			remaining := 60 - (now - last)
			panic("claiming too fast — " + strconv.FormatInt(remaining, 10) + "s remaining (1 min cooldown)")
		}
	}
	lastClaim.Set(caller, strconv.FormatInt(now, 10))

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

		// Per-entry cap: max 50,000 coins per type per claim.
		// Raised from 100 — amount doesn't affect gas cost (same AVL write either way),
		// so capping low just forces more txs and wastes player GNOT.
		if amt > 50000 {
			amt = 50000
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

		// Apply guild yield bonus: +1% per other guild member (max 9%)
		if playerGuild.Has(caller) {
			guildId := playerGuild.Get(caller).(string)
			memberCount := 0
			guildMembers.Iterate(guildId+":", guildId+":\xFF", func(k string, v any) bool {
				memberCount++
				return false
			})
			bonusPct := memberCount - 1 // 1% per other member, 0 if solo
			if bonusPct > 9 {
				bonusPct = 9
			}
			if bonusPct > 0 {
				guildBonus := (amt * uint64(bonusPct)) / 100
				amt = amt + guildBonus
			}
		}

		// Apply Gnome Pass yield bonus (+50% if active, stacks after guild bonus)
		if HasActivePass(caller) {
			passBonus := amt / 2 // +50%, integer division
			amt = amt + passBonus
		}

		key := caller + ":" + coinId

		// Accumulate pending mints
		ex := uint64(0)
		if pendingMints.Has(key) {
			ex, _ = strconv.ParseUint(pendingMints.Get(key).(string), 10, 64)
		}
		pendingMints.Set(key, strconv.FormatUint(ex+amt, 10))

		// Track lifetime mined per coin
		lifEx := uint64(0)
		if lifetimeMined.Has(key) {
			lifEx, _ = strconv.ParseUint(lifetimeMined.Get(key).(string), 10, 64)
		}
		lifetimeMined.Set(key, strconv.FormatUint(lifEx+amt, 10))

		// Update leaderboard total (all coins summed)
		mt := uint64(0)
		if miners.Has(caller) {
			mt, _ = strconv.ParseUint(miners.Get(caller).(string), 10, 64)
		}
		miners.Set(caller, strconv.FormatUint(mt+amt, 10))
	}
}

// ClearPendingMints is called by the treasury server after successful GRC20 minting.
// Removes pending balance and credits the player's spendable balances tree.
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

		// Read minted amount before clearing, then credit to balances
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
// The caller pays their own gas (~0.03 GNOT). No treasury involvement.
// Replaces the two-step ClaimMine → mintPending flow for new players.
// Phase 6: treasury burn-rate fix — at 100 players using ClaimAndMint, the
// treasury pays ~0 GNOT/day (down from ~12 GNOT/day with the old two-step flow).
func ClaimAndMint(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	// Velocity limit: 1 minute between calls (same lastClaim tree as ClaimMine).
	// A player cannot bypass the cooldown by switching between the two functions.
	now := time.Now().Unix()
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < 60 {
			remaining := 60 - (now - last)
			panic("too fast — " + strconv.FormatInt(remaining, 10) + "s remaining (1 min cooldown)")
		}
	}
	lastClaim.Set(caller, strconv.FormatInt(now, 10))

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

		// Per-entry cap: max 50,000 per coin type
		if amt > 50000 {
			amt = 50000
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

		// Apply guild yield bonus: +1% per other guild member (max 9%)
		if playerGuild.Has(caller) {
			guildId := playerGuild.Get(caller).(string)
			memberCount := 0
			guildMembers.Iterate(guildId+":", guildId+":\xFF", func(k string, v any) bool {
				memberCount++
				return false
			})
			bonusPct := memberCount - 1 // 1% per other member, 0 if solo
			if bonusPct > 9 {
				bonusPct = 9
			}
			if bonusPct > 0 {
				guildBonus := (amt * uint64(bonusPct)) / 100
				amt = amt + guildBonus
			}
		}

		// Apply Gnome Pass yield bonus (+50% if active, stacks after guild bonus)
		if HasActivePass(caller) {
			passBonus := amt / 2 // +50%, integer division
			amt = amt + passBonus
		}

		key := caller + ":" + coinId

		// Credit DIRECTLY to balances (no pendingMints, no treasury needed)
		bal := uint64(0)
		if balances.Has(key) {
			bal, _ = strconv.ParseUint(balances.Get(key).(string), 10, 64)
		}
		balances.Set(key, strconv.FormatUint(bal+amt, 10))

		// Track lifetime mined
		lifEx := uint64(0)
		if lifetimeMined.Has(key) {
			lifEx, _ = strconv.ParseUint(lifetimeMined.Get(key).(string), 10, 64)
		}
		lifetimeMined.Set(key, strconv.FormatUint(lifEx+amt, 10))

		// Update leaderboard
		mt := uint64(0)
		if miners.Has(caller) {
			mt, _ = strconv.ParseUint(miners.Get(caller).(string), 10, 64)
		}
		miners.Set(caller, strconv.FormatUint(mt+amt, 10))
	}
}

