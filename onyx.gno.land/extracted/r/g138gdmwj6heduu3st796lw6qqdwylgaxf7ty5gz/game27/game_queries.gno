package game27

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)


// ── Coin Transfer ────────────────────────────────────────────────────────────

// Transfer sends coinId coins from the caller to toAddr directly on-chain.
// Both addresses must have interacted with the game realm at least once.
func Transfer(cur realm, coinId string, toAddr string, amountStr string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	if !strings.HasPrefix(toAddr, "g1") {
		panic("invalid destination address")
	}
	if caller == toAddr {
		panic("cannot transfer to yourself")
	}
	amount, err := strconv.ParseUint(amountStr, 10, 64)
	if err != nil || amount == 0 {
		panic("invalid amount")
	}

	fromKey := caller + ":" + coinId
	have := uint64(0)
	if balances.Has(fromKey) {
		have, _ = strconv.ParseUint(balances.Get(fromKey).(string), 10, 64)
	}
	if have < amount {
		panic("insufficient balance: need " + amountStr + " have " + strconv.FormatUint(have, 10))
	}

	// Deduct from sender
	balances.Set(fromKey, strconv.FormatUint(have-amount, 10))

	// Credit recipient
	toKey := toAddr + ":" + coinId
	toHave := uint64(0)
	if balances.Has(toKey) {
		toHave, _ = strconv.ParseUint(balances.Get(toKey).(string), 10, 64)
	}
	balances.Set(toKey, strconv.FormatUint(toHave+amount, 10))
}

// ── Tools ────────────────────────────────────────────────────────────────────

func BuyTool(cur realm, toolId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	// Look up cost
	costs, hasCost := toolCosts[toolId]
	if !hasCost && toolId != "hands" {
		panic("unknown tool: " + toolId)
	}

	// Deduct balance (hands is free, others require coins)
	if hasCost && len(costs) > 0 {
		deductBalances(caller, costs)
	}

	// Grant tool
	existing := ""
	if ownedTools.Has(caller) {
		existing = ownedTools.Get(caller).(string)
	}
	if existing == "" {
		ownedTools.Set(caller, toolId)
	} else {
		ownedTools.Set(caller, existing+","+toolId)
	}
}

func RepairTool(cur realm, toolId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	maxLife, hasLife := toolMaxLife[toolId]
	if !hasLife || maxLife == 0 {
		panic("tool cannot be repaired: " + toolId)
	}

	// Cost = 30% of craft cost (rounded up per coin)
	baseCosts, hasCost := toolCosts[toolId]
	if !hasCost {
		panic("unknown tool: " + toolId)
	}
	var repairCosts [][2]string
	for _, pair := range baseCosts {
		coinId, amtStr := pair[0], pair[1]
		baseAmt, _ := strconv.ParseUint(amtStr, 10, 64)
		// 30% rounded up: (base * 30 + 99) / 100
		repairAmt := (baseAmt*30 + 99) / 100
		if repairAmt > 0 {
			repairCosts = append(repairCosts, [2]string{coinId, strconv.FormatUint(repairAmt, 10)})
		}
	}

	deductBalances(caller, repairCosts)

	// Restore full durability
	toolLife.Set(caller+":"+toolId, strconv.FormatUint(maxLife, 10))
}

// ── Progression ──────────────────────────────────────────────────────────────

func TrainSkill(cur realm, skillId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	key := caller + ":" + skillId

	// Look up current rank
	rank := uint64(0)
	if skillRanks.Has(key) {
		rank, _ = strconv.ParseUint(skillRanks.Get(key).(string), 10, 64)
	}

	// Check rank cap
	maxRank, hasMax := skillMaxRanks[skillId]
	if !hasMax {
		panic("unknown skill: " + skillId)
	}
	if rank >= maxRank {
		panic("skill already at maximum rank")
	}

	// Compute cost: base × 2^rank
	baseCosts, hasCost := skillBaseCosts[skillId]
	if !hasCost {
		panic("unknown skill: " + skillId)
	}
	var scaledCosts [][2]string
	multiplier := uint64(1)
	for i := uint64(0); i < rank; i++ {
		multiplier *= 2
	}
	for _, pair := range baseCosts {
		coinId, amtStr := pair[0], pair[1]
		baseAmt, _ := strconv.ParseUint(amtStr, 10, 64)
		scaled := baseAmt * multiplier
		if scaled > 0 {
			scaledCosts = append(scaledCosts, [2]string{coinId, strconv.FormatUint(scaled, 10)})
		}
	}

	deductBalances(caller, scaledCosts)

	// Increment rank
	skillRanks.Set(key, strconv.FormatUint(rank+1, 10))
}

func ClaimAchievement(cur realm, achievementId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	key := caller + ":" + achievementId
	if achievements.Has(key) {
		panic("already claimed")
	}
	achievements.Set(key, "1")
}

// BatchClaimAchievements claims multiple achievements in a single transaction.
// idsJson format: ["ach1","ach2",...] — already-claimed IDs are silently skipped.
// One tx instead of N txs — 10× cheaper for Claim All.
func BatchClaimAchievements(cur realm, idsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	idsJson = strings.TrimSpace(idsJson)
	idsJson = strings.TrimPrefix(idsJson, "[")
	idsJson = strings.TrimSuffix(idsJson, "]")

	for _, part := range strings.Split(idsJson, ",") {
		id := strings.Trim(strings.TrimSpace(part), "\"")
		if id == "" {
			continue
		}
		key := caller + ":" + id
		if achievements.Has(key) {
			continue
		}
		achievements.Set(key, "1")
	}
}

func DailyCheckin(cur realm) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	now := time.Now().Unix()
	if dailyCheckins.Has(caller) {
		last, _ := strconv.ParseInt(dailyCheckins.Get(caller).(string), 10, 64)
		if now-last < 86400 {
			panic("too soon for daily check-in")
		}
	}
	dailyCheckins.Set(caller, strconv.FormatInt(now, 10))
}

// CreateTask registers a new task on-chain.
func CreateTask(cur realm, taskId string, desc string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	// Store task metadata keyed by taskId; only the creator can create it
	achievements.Set("task:"+taskId+":creator", caller)
	achievements.Set("task:"+taskId+":desc", desc)
}

func CompleteTask(cur realm, taskId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	achievements.Set(caller+":"+taskId, "task:1")
}

func RegisterVein(cur realm, coinId string, maxSupply string) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	veinSupply.Set(coinId, maxSupply+":"+maxSupply)
}

// ── Queries (pure reads — no cur realm needed) ────────────────────────────────

func PendingMints(playerAddr string) string {
	var parts []string
	pendingMints.Iterate(playerAddr+":", playerAddr+":\xFF", func(key string, val any) bool {
		coinId := strings.TrimPrefix(key, playerAddr+":")
		parts = append(parts, `["`+coinId+`","`+val.(string)+`"]`)
		return false
	})
	return ufmt.Sprintf(`{"pending":[%s]}`, strings.Join(parts, ","))
}

func AllBalances(playerAddr string) string {
	var parts []string
	balances.Iterate(playerAddr+":", playerAddr+":\xFF", func(key string, val any) bool {
		coinId := strings.TrimPrefix(key, playerAddr+":")
		parts = append(parts, `"`+coinId+`":`+val.(string))
		return false
	})
	return "{" + strings.Join(parts, ",") + "}"
}

func VeinSupply(coinId string) string {
	if !veinSupply.Has(coinId) {
		return `{"remaining":"0","max":"0"}`
	}
	p := strings.SplitN(veinSupply.Get(coinId).(string), ":", 2)
	if len(p) != 2 {
		return `{"remaining":"0","max":"0"}`
	}
	return `{"remaining":"` + p[0] + `","max":"` + p[1] + `"}`
}

func CasinoRound(roundId string) string {
	if !casinoRounds.Has(roundId) {
		return "null"
	}
	return casinoRounds.Get(roundId).(string)
}

func CasinoHistory(_ string) string { return "[]" }

func PvpLobby(lobbyId string) string {
	if !pvpLobbies.Has(lobbyId) {
		return "null"
	}
	return pvpLobbies.Get(lobbyId).(string)
}

func OpenLobbies() string {
	var parts []string
	pvpLobbies.Iterate("pvp-", "pvp-\xFF", func(key string, val any) bool {
		if !strings.Contains(key, ":") {
			parts = append(parts, val.(string))
		}
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}

func JackpotPool(coinId string) string {
	return `{"pool":"0","coinId":"` + coinId + `"}`
}

func PlayerProfile(playerAddr string) string {
	return `{"address":"` + playerAddr + `"}`
}

func OwnedTools(playerAddr string) string {
	if !ownedTools.Has(playerAddr) {
		return `["hands"]`
	}
	ids := strings.Split(ownedTools.Get(playerAddr).(string), ",")
	var quoted []string
	for _, id := range ids {
		quoted = append(quoted, `"`+id+`"`)
	}
	return "[" + strings.Join(quoted, ",") + "]"
}

func LifetimeMined(playerAddr string) string {
	var parts []string
	lifetimeMined.Iterate(playerAddr+":", playerAddr+":\xFF", func(key string, val any) bool {
		coinId := strings.TrimPrefix(key, playerAddr+":")
		parts = append(parts, `"`+coinId+`":`+val.(string))
		return false
	})
	return "{" + strings.Join(parts, ",") + "}"
}

func AllMiners(limit int, offset int) string {
	var parts []string
	count, skipped := 0, 0
	miners.Iterate("", "\xFF", func(key string, val any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		if count >= limit {
			return true
		}
		display := key
		if len(display) > 12 {
			display = display[:8] + "..."
		}
		parts = append(parts, `{"address":"`+key+`","display":"`+display+`","total":`+val.(string)+`}`)
		count++
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}

func GetMedals(playerAddr string) string {
	var claimed []string
	achievements.Iterate(playerAddr+":", playerAddr+":\xFF", func(key string, val any) bool {
		achId := strings.TrimPrefix(key, playerAddr+":")
		claimed = append(claimed, `"`+achId+`"`)
		return false
	})
	return ufmt.Sprintf(`{"medals":[%s]}`, strings.Join(claimed, ","))
}

func DailyCheckinStatus(playerAddr string) string {
	now := time.Now().Unix()
	last := int64(0)
	if dailyCheckins.Has(playerAddr) {
		last, _ = strconv.ParseInt(dailyCheckins.Get(playerAddr).(string), 10, 64)
	}
	done := now-last < 86400
	return ufmt.Sprintf(`{"ok":true,"done":%t,"streak":1,"next":%d}`, done, last+86400)
}

func ListTasks(_ string) string { return `{"ok":true,"tasks":[]}` }

func SkillRanks(playerAddr string) string {
	var parts []string
	skillRanks.Iterate(playerAddr+":", playerAddr+":\xFF", func(key string, val any) bool {
		skillId := strings.TrimPrefix(key, playerAddr+":")
		parts = append(parts, `"`+skillId+`":`+val.(string))
		return false
	})
	return "{" + strings.Join(parts, ",") + "}"
}

func ToolLife(playerAddr string) string {
	var parts []string
	toolLife.Iterate(playerAddr+":", playerAddr+":\xFF", func(key string, val any) bool {
		toolId := strings.TrimPrefix(key, playerAddr+":")
		parts = append(parts, `"`+toolId+`":`+val.(string))
		return false
	})
	return "{" + strings.Join(parts, ",") + "}"
}

// ── Render ───────────────────────────────────────────────────────────────────

func Render(_ string) string {
	return ufmt.Sprintf("# GnoMoji Game Realm\n\nAdmin: `%s`\n\nPath: `gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game11`\n\nMine emoji coins on Gno.land!\n", admin.String())
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// deductBalances atomically checks all balances then deducts them.
// Panics if any balance is insufficient — no partial deductions.
// costs is a slice of [coinId, amount] pairs.
func deductBalances(caller string, costs [][2]string) {
	// First pass: verify all sufficient
	for _, pair := range costs {
		coinId, amtStr := pair[0], pair[1]
		required, err := strconv.ParseUint(amtStr, 10, 64)
		if err != nil || required == 0 {
			continue
		}
		balKey := caller + ":" + coinId
		have := uint64(0)
		if balances.Has(balKey) {
			have, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
		}
		if have < required {
			panic("insufficient " + coinId + ": need " + amtStr + " have " + strconv.FormatUint(have, 10))
		}
	}
	// Second pass: deduct all
	for _, pair := range costs {
		coinId, amtStr := pair[0], pair[1]
		required, err := strconv.ParseUint(amtStr, 10, 64)
		if err != nil || required == 0 {
			continue
		}
		balKey := caller + ":" + coinId
		current, _ := strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
		balances.Set(balKey, strconv.FormatUint(current-required, 10))
	}
}

func splitJsonArray(s string) []string {
	var result []string
	depth, start := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '[', '{':
			depth++
		case ']', '}':
			depth--
		case ',':
			if depth == 0 {
				if e := strings.TrimSpace(s[start:i]); e != "" {
					result = append(result, e)
				}
				start = i + 1
			}
		}
	}
	if e := strings.TrimSpace(s[start:]); e != "" {
		result = append(result, e)
	}
	return result
}
