package game29

import (
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

func init(cur realm) {
	// The deployer (tx signer of addpkg) becomes admin and default operator.
	admin = address(cur.Previous().Address())
	operator = admin
}

// ── Roles ────────────────────────────────────────────────────────────────────

func isAdmin(cur realm) bool {
	return admin != address("") && cur.Previous().Address() == admin
}

func requireAdmin(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized: admin only")
	}
}


// TransferAdmin hands the admin role to another address.
func TransferAdmin(cur realm, newAdmin string) {
	requireAdmin(cur)
	transferAdmin(newAdmin)
}

func transferAdmin(newAdmin string) {
	a := address(newAdmin)
	if !a.IsValid() {
		panic("invalid address")
	}
	admin = a
}

// UpdateConfig is kept for game27/28 API compatibility (= TransferAdmin).
func UpdateConfig(cur realm, newAdmin string) {
	requireAdmin(cur)
	transferAdmin(newAdmin)
}


// SetClaimSigner registers the ed25519 public key (64 hex chars) of the
// server's claim signer. Pass "" to disable all vouchered calls (kill switch).
func SetClaimSigner(cur realm, pubKeyHex string) {
	requireAdmin(cur)
	if pubKeyHex == "" {
		claimSignerPubKey = nil
		return
	}
	b, err := hex.DecodeString(pubKeyHex)
	if err != nil || len(b) != 32 {
		panic("claim signer must be a 32-byte ed25519 public key in hex")
	}
	claimSignerPubKey = b
}

func ClaimSigner() string { return hex.EncodeToString(claimSignerPubKey) }
func Admin() string       { return admin.String() }

func SetPaused(cur realm, p bool) {
	requireAdmin(cur)
	paused = p
}

func IsPaused() bool { return paused }

func requireNotPaused() {
	if paused {
		panic("game is paused")
	}
}

// ── Blacklist ─────────────────────────────────────────────────────────────────

// BanAddress bans a player address. durationSecs=0 means permanent.
func BanAddress(cur realm, targetAddr string, reason string, durationSecs int64) {
	requireAdmin(cur)
	if !address(targetAddr).IsValid() {
		panic("invalid address")
	}
	expiry := int64(0)
	if durationSecs > 0 {
		expiry = time.Now().Unix() + durationSecs
	}
	blacklist.Set(targetAddr, strings.ReplaceAll(reason, ":", " ")+":"+strconv.FormatInt(time.Now().Unix(), 10))
	banExpiries.Set(targetAddr, strconv.FormatInt(expiry, 10))
}

func UnbanAddress(cur realm, targetAddr string) {
	requireAdmin(cur)
	blacklist.Remove(targetAddr)
	banExpiries.Remove(targetAddr)
}

func BlacklistStatus(addr string) string {
	if !blacklist.Has(addr) {
		return `{"banned":false}`
	}
	entry := blacklist.Get(addr).(string)
	expiry, _ := strconv.ParseInt(banExpiries.Get(addr).(string), 10, 64)
	now := time.Now().Unix()
	if expiry > 0 && now >= expiry {
		return `{"banned":false}`
	}
	reason := strings.SplitN(entry, ":", 2)[0]
	if expiry == 0 {
		return `{"banned":true,"reason":` + jsonStr(reason) + `,"permanent":true}`
	}
	return `{"banned":true,"reason":` + jsonStr(reason) + `,"permanent":false,"remainingSecs":` + strconv.FormatInt(expiry-now, 10) + `}`
}

func isBlacklisted(addr string) bool {
	if !blacklist.Has(addr) {
		return false
	}
	expiry, _ := strconv.ParseInt(banExpiries.Get(addr).(string), 10, 64)
	if expiry == 0 {
		return true
	}
	return time.Now().Unix() < expiry
}

func requirePlayer(cur realm) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	return caller
}

// ── Veins ────────────────────────────────────────────────────────────────────

func veinMax(coinId string) uint64 {
	// FIX 2B: skip AVL read when no overrides have ever been set.
	if veinOverrideActive && veinMaxOverride.Has(coinId) {
		v, _ := strconv.ParseUint(veinMaxOverride.Get(coinId).(string), 10, 64)
		return v
	}
	r, ok := coinRarity[coinId]
	if !ok {
		return 0
	}
	if v, ok := veinCoinDefault[coinId]; ok {
		return v
	}
	return veinDefaultMax[r]
}

func veinMintedOf(coinId string) uint64 {
	if !veinMinted.Has(coinId) {
		return 0
	}
	v, _ := strconv.ParseUint(veinMinted.Get(coinId).(string), 10, 64)
	return v
}

// takeFromVein returns how much of amt can still be minted for coinId and
// records it as minted.
func takeFromVein(coinId string, amt uint64) uint64 {
	mx := veinMax(coinId)
	mi := veinMintedOf(coinId)
	if mi >= mx {
		return 0
	}
	if amt > mx-mi {
		amt = mx - mi
	}
	veinMinted.Set(coinId, strconv.FormatUint(mi+amt, 10))
	if half := mx / 2; mi < half && mi+amt >= half {
		std.Emit("VeinHalfMinted", "coin", coinId,
			"minted", strconv.FormatUint(mi+amt, 10), "max", strconv.FormatUint(mx, 10))
	}
	if mi+amt == mx {
		std.Emit("VeinExhausted", "coin", coinId, "max", strconv.FormatUint(mx, 10))
	}
	return amt
}

// SetVeinMax overrides a coin's vein size. It can't go below what was minted.
func SetVeinMax(cur realm, coinId string, maxSupply string) {
	requireAdmin(cur)
	setVeinMax(coinId, maxSupply)
}

func setVeinMax(coinId string, maxSupply string) {
	if _, ok := coinRarity[coinId]; !ok {
		panic("unknown coin id: " + coinId)
	}
	mx, err := strconv.ParseUint(maxSupply, 10, 64)
	if err != nil {
		panic("invalid max supply")
	}
	if mx < veinMintedOf(coinId) {
		panic("vein max below already-minted supply")
	}
	veinMaxOverride.Set(coinId, strconv.FormatUint(mx, 10))
	veinOverrideActive = true
}

// RegisterVein is the game28 name for SetVeinMax.
func RegisterVein(cur realm, coinId string, maxSupply string) {
	requireAdmin(cur)
	setVeinMax(coinId, maxSupply)
}

func VeinSupply(coinId string) string {
	if _, ok := coinRarity[coinId]; !ok {
		return `{"remaining":"0","max":"0"}`
	}
	mx := veinMax(coinId)
	mi := veinMintedOf(coinId)
	rem := uint64(0)
	if mx > mi {
		rem = mx - mi
	}
	return `{"remaining":"` + strconv.FormatUint(rem, 10) + `","max":"` + strconv.FormatUint(mx, 10) + `","minted":"` + strconv.FormatUint(mi, 10) + `","halfMinted":` + strconv.FormatBool(mx > 0 && mi >= mx/2) + `,"exhausted":` + strconv.FormatBool(mx > 0 && mi >= mx) + `}`
}

// ── Gnome Pass (paid) ────────────────────────────────────────────────────────

// SetPassPrice sets the ugnot price per 30-day period.
func SetPassPrice(cur realm, ugnotPer30Days int64) {
	requireAdmin(cur)
	if ugnotPer30Days <= 0 {
		panic("price must be > 0")
	}
	passPriceUgnot = ugnotPer30Days
}

func PassPrice() int64 { return passPriceUgnot }

// ActivateGnomePass buys durationDays (30..360, multiple of 30) of Gnome Pass.
// The tx must attach exactly passPrice × durationDays/30 ugnot (MsgCall send).
func ActivateGnomePass(cur realm, durationDays int64) {
	caller := requirePlayer(cur)
	// Payment verification must only trust the origin envelope when the
	// caller is the signer itself (no intermediate realm can consume it).
	if cur.Previous().PkgPath() != "" {
		panic("Gnome Pass must be bought directly by the player")
	}
	if durationDays <= 0 || durationDays%30 != 0 || durationDays > 360 {
		panic("durationDays must be 30, 60, ... 360")
	}
	periods := durationDays / 30
	required := passPriceUgnot * periods
	sent := std.GetOrigSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != required {
		panic("Gnome Pass costs " + strconv.FormatInt(required, 10) + "ugnot for " + strconv.FormatInt(durationDays, 10) + " days — attach exactly that amount")
	}
	passRevenueUgnot += required

	now := time.Now().Unix()
	base := now
	if gnomePasses.Has(caller) {
		existing, _ := strconv.ParseInt(gnomePasses.Get(caller).(string), 10, 64)
		if existing > now {
			base = existing
		}
	}
	gnomePasses.Set(caller, strconv.FormatInt(base+durationDays*86400, 10))
}

func GnomePassExpiry(addr string) int64 {
	if !gnomePasses.Has(addr) {
		return 0
	}
	expiry, _ := strconv.ParseInt(gnomePasses.Get(addr).(string), 10, 64)
	return expiry
}

func HasActivePass(addr string) bool { return GnomePassExpiry(addr) > time.Now().Unix() }

func GnomePassCount() int {
	count := 0
	now := time.Now().Unix()
	gnomePasses.Iterate("", "", func(_ string, val any) bool {
		e, _ := strconv.ParseInt(val.(string), 10, 64)
		if e > now {
			count++
		}
		return false
	})
	return count
}

func PassRevenue() int64 { return passRevenueUgnot }

// TreasuryBalance returns the ugnot held by this realm (pass revenue not yet withdrawn).
func TreasuryBalance() int64 {
	realmAddr := std.CurrentRealm().Addr()
	coins := std.GetBanker(std.BankerTypeReadonly).GetCoins(realmAddr)
	for _, c := range coins {
		if c.Denom == "ugnot" {
			return c.Amount
		}
	}
	return 0
}

// WithdrawFunds sends GNOT the admin is OWED — Gnome Pass revenue not yet
// withdrawn — to `to`. It can never touch other ugnot the realm holds
// (donations, anything a future feature would hold for players).
func WithdrawFunds(cur realm, to string, amountUgnot int64) {
	requireAdmin(cur)
	dst := std.Address(to)
	if !dst.IsValid() {
		panic("invalid address")
	}
	if amountUgnot <= 0 {
		panic("amount must be > 0")
	}
	if amountUgnot > passRevenueUgnot-adminGnotWithdrawn {
		panic("can only withdraw unwithdrawn pass revenue: " + strconv.FormatInt(passRevenueUgnot-adminGnotWithdrawn, 10) + "ugnot")
	}
	adminGnotWithdrawn += amountUgnot
	b := std.GetBanker(std.BankerTypeRealmSend)
	b.SendCoins(std.CurrentRealm().Addr(), dst, std.Coins{std.NewCoin("ugnot", amountUgnot)})
	std.Emit("FundsWithdrawn", "to", to, "ugnot", strconv.FormatInt(amountUgnot, 10))
}

// WithdrawableFunds = pass revenue the admin may still withdraw (ugnot).
func WithdrawableFunds() int64 { return passRevenueUgnot - adminGnotWithdrawn }

// ── Migration (game27 / game28 → game29) ────────────────────────────────────
//
// MigrateBatch(batchId, kind, rowsJson) imports one batch. rowsJson is a JSON
// array of string arrays. Kinds and row shapes:
//   balance  [addr, coinId, amount]       → balances (SET, not add)
//   lifetime [addr, coinId, amount]       → lifetimeMined (SET) + miners total
//   tools    [addr, "t1,t2,..."]          → ownedTools (SET, unknown ids dropped)
//   toollife [addr, toolId, life]         → toolLife (SET, clamped to max)
//   skill    [addr, skillId, rank]        → skillRanks (SET, clamped to max)
//   medal    [addr, achievementId]        → achievements (allowlisted ids only)
//   pass     [addr, expiryUnix]           → gnomePasses (SET)
//   guild    [guildId, name, leader, "m1,m2,..."] → guilds + members
//   ban      [addr, reason, expiryUnix]   → blacklist (expiry 0 = permanent)
// A batchId that was already applied is skipped, and every write is a SET, so
// re-running a whole migration is a no-op. FinalizeMigration locks it forever.
func MigrateBatch(cur realm, batchId string, kind string, rowsJson string) int {
	requireAdmin(cur)
	if migrationFinalized {
		panic("migration is finalized")
	}
	if batchId == "" {
		panic("batchId required")
	}
	if migrationBatches.Has(batchId) {
		return 0
	}
	rows := parseStringRows(rowsJson)
	n := 0
	for _, r := range rows {
		if migrateRow(kind, r) {
			n++
		}
	}
	migrationBatches.Set(batchId, kind+":"+strconv.Itoa(n))
	return n
}

func FinalizeMigration(cur realm) {
	requireAdmin(cur)
	migrationFinalized = true
}

func MigrationStatus() string {
	return `{"finalized":` + strconv.FormatBool(migrationFinalized) + `,"batches":` + strconv.Itoa(migrationBatches.Size()) + `}`
}

func MigrationBatch(batchId string) string {
	if !migrationBatches.Has(batchId) {
		return ""
	}
	return migrationBatches.Get(batchId).(string)
}

func validAddr(s string) bool { return address(s).IsValid() }

func migrateRow(kind string, r []string) bool {
	switch kind {
	case "balance", "lifetime":
		if len(r) != 3 || !validAddr(r[0]) {
			return false
		}
		if _, ok := coinRarity[r[1]]; !ok {
			return false
		}
		amt, err := strconv.ParseUint(r[2], 10, 64)
		if err != nil {
			return false
		}
		key := r[0] + ":" + r[1]
		if kind == "balance" {
			old := getU(&balances, key)
			// Imported balances count against the vein (delta on re-run).
			if amt > old {
				mi := veinMintedOf(r[1])
				veinMinted.Set(r[1], strconv.FormatUint(mi+(amt-old), 10))
			}
			setU(&balances, key, amt)
		} else {
			old := getU(&lifetimeMined, key)
			setU(&lifetimeMined, key, amt)
			tot := getU(&miners, r[0])
			if tot >= old {
				tot -= old
			} else {
				tot = 0
			}
			setU(&miners, r[0], tot+amt)
		}
		return true
	case "tools":
		if len(r) != 2 || !validAddr(r[0]) {
			return false
		}
		var keep []string
		seen := map[string]bool{}
		for _, t := range strings.Split(r[1], ",") {
			t = strings.TrimSpace(t)
			if t == "" || t == "hands" || seen[t] {
				continue
			}
			if _, ok := toolCosts[t]; !ok {
				continue
			}
			seen[t] = true
			keep = append(keep, t)
		}
		if len(keep) == 0 {
			ownedTools.Remove(r[0])
		} else {
			ownedTools.Set(r[0], strings.Join(keep, ","))
		}
		return true
	case "toollife":
		if len(r) != 3 || !validAddr(r[0]) {
			return false
		}
		mx, ok := toolMaxLife[r[1]]
		if !ok || mx == 0 {
			return false
		}
		life, err := strconv.ParseUint(r[2], 10, 64)
		if err != nil {
			return false
		}
		if em := effectiveMaxLife(r[0], r[1]); life > em {
			life = em
		}
		setU(&toolLife, r[0]+":"+r[1], life)
		return true
	case "skill":
		if len(r) != 3 || !validAddr(r[0]) {
			return false
		}
		mx, ok := skillMaxRanks[r[1]]
		if !ok {
			return false
		}
		rank, err := strconv.ParseUint(r[2], 10, 64)
		if err != nil {
			return false
		}
		if rank > mx {
			rank = mx
		}
		setU(&skillRanks, r[0]+":"+r[1], rank)
		return true
	case "medal":
		if len(r) != 2 || !validAddr(r[0]) || !isValidAchievementId(r[1]) {
			return false
		}
		achievements.Set(r[0]+":"+r[1], "1")
		return true
	case "pass":
		if len(r) != 2 || !validAddr(r[0]) {
			return false
		}
		e, err := strconv.ParseInt(r[1], 10, 64)
		if err != nil || e <= 0 {
			return false
		}
		gnomePasses.Set(r[0], strconv.FormatInt(e, 10))
		return true
	case "guild":
		if len(r) != 4 || r[0] == "" || !validAddr(r[2]) {
			return false
		}
		name := sanitizeName(r[1])
		if len(name) < 3 {
			return false
		}
		members := []string{}
		for _, m := range strings.Split(r[3], ",") {
			m = strings.TrimSpace(m)
			if validAddr(m) && len(members) < maxGuildMembers {
				members = append(members, m)
			}
		}
		if len(members) == 0 {
			return false
		}
		// Drop stale membership rows of this guild, then write fresh ones.
		var stale []string
		guildMembers.Iterate(r[0]+":", r[0]+";", func(k string, _ any) bool {
			stale = append(stale, k)
			return false
		})
		for _, k := range stale {
			guildMembers.Remove(k)
		}
		for _, m := range members {
			guildMembers.Set(r[0]+":"+m, "1")
			playerGuild.Set(m, r[0])
		}
		guildMetas[r[0]] = guildMeta{name: name, leader: r[2], createdAt: time.Now().Unix()}
		rewriteGuild(r[0])
		return true
	case "ban":
		if len(r) != 3 || !validAddr(r[0]) {
			return false
		}
		e, err := strconv.ParseInt(r[2], 10, 64)
		if err != nil || e < 0 {
			return false
		}
		blacklist.Set(r[0], strings.ReplaceAll(r[1], ":", " ")+":"+strconv.FormatInt(time.Now().Unix(), 10))
		banExpiries.Set(r[0], strconv.FormatInt(e, 10))
		return true
	}
	panic("unknown migration kind: " + kind)
}
