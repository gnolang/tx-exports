package game33

import (
	"strconv"
	"strings"
	"time"

	"chain"
)

// ── Tool-life helpers ─────────────────────────────────────────────────────────

// effectiveMaxLife = toolMaxLife × (1000 + Σ rank × bonus‰) / 1000.
// FIX 1C: fast-path for players with no tool-life skills trained (the common
// case), avoiding 22 AVL reads (11 skills × Has+Get) that all return 0.
func effectiveMaxLife(callerAddr string, toolId string) uint64 {
	base, ok := toolMaxLife[toolId]
	if !ok || base == 0 {
		return 0
	}
	// Fast path: check the first skill only. Skills must be trained in order
	// (toolLifeSkillIds[0] = "tempered_grip" is always the entry-level skill).
	// If the player has no rank in it, they have no rank in any of the 11.
	if !skillRanks.Has(callerAddr + ":" + toolLifeSkillIds[0]) {
		return base
	}
	bonus := uint64(0)
	for _, skillId := range toolLifeSkillIds {
		if rank := getU(&skillRanks, callerAddr+":"+skillId); rank > 0 {
			bonus += rank * toolLifeSkillBonus[skillId]
		}
	}
	return base * (1000 + bonus) / 1000
}

func ownsTool(addr, toolId string) bool {
	if toolId == "hands" {
		return true
	}
	if !ownedTools.Has(addr) {
		return false
	}
	for _, t := range strings.Split(ownedTools.Get(addr).(string), ",") {
		if strings.TrimSpace(t) == toolId {
			return true
		}
	}
	return false
}

// ── Coin Transfer ────────────────────────────────────────────────────────────

// Transfer sends coins to another player. It is a player's own money, so the
// admin can't stop it: it works while the game is paused and for banned
// addresses (bans only stop earning). It needs a finalized migration
// (MigrateBatch SETs balances). There is no receive cap: any coin can be sent
// to any player, whatever tools they own.
func Transfer(cur realm, coinId string, toAddr string, amountStr string) {
	caller := cur.Previous().Address().String()
	if !migrationFinalized {
		panic("transfers open after FinalizeMigration")
	}
	if !address(toAddr).IsValid() {
		panic("invalid destination address")
	}
	if caller == toAddr {
		panic("cannot transfer to yourself")
	}
	if _, ok := coinRarity[coinId]; !ok {
		panic("unknown coin id: " + coinId)
	}
	amount, err := strconv.ParseUint(amountStr, 10, 64)
	if err != nil || amount == 0 || amount > maxAmount {
		panic("invalid amount")
	}
	debitBal(caller, coinId, amount)
	creditBal(toAddr, coinId, amount)
	chain.Emit("Transferred", "coin", coinId, "from", caller, "to", toAddr, "amount", u(amount))
}

// ── Tools ────────────────────────────────────────────────────────────────────

func BuyTool(cur realm, toolId string) {
	caller := requirePlayer(cur)
	costs, hasCost := toolCosts[toolId]
	if !hasCost {
		panic("unknown tool: " + toolId)
	}
	if ownsTool(caller, toolId) {
		panic("already own " + toolId + " — use RepairTool to restore durability")
	}
	if prereq, ok := toolRequires[toolId]; ok && !ownsTool(caller, prereq) {
		panic("must own " + prereq + " before buying " + toolId)
	}
	deductBalances(caller, costs)

	if !ownedTools.Has(caller) || ownedTools.Get(caller).(string) == "" {
		ownedTools.Set(caller, toolId)
	} else {
		ownedTools.Set(caller, ownedTools.Get(caller).(string)+","+toolId)
	}
	// Always initialise durability at purchase (skill-boosted max).
	if mx, ok := toolMaxLife[toolId]; ok && mx > 0 {
		setU(&toolLife, caller+":"+toolId, effectiveMaxLife(caller, toolId))
	}
}

func RepairTool(cur realm, toolId string) {
	caller := requirePlayer(cur)
	maxLife, ok := toolMaxLife[toolId]
	if !ok || maxLife == 0 {
		panic("tool cannot be repaired: " + toolId)
	}
	if !ownsTool(caller, toolId) {
		panic("you don't own " + toolId)
	}
	var repairCosts [][2]string
	for _, pair := range toolCosts[toolId] {
		baseAmt, _ := strconv.ParseUint(pair[1], 10, 64)
		if amt := (baseAmt*30 + 99) / 100; amt > 0 {
			repairCosts = append(repairCosts, [2]string{pair[0], strconv.FormatUint(amt, 10)})
		}
	}
	deductBalances(caller, repairCosts)
	setU(&toolLife, caller+":"+toolId, effectiveMaxLife(caller, toolId))
}

// ── Progression ──────────────────────────────────────────────────────────────

func TrainSkill(cur realm, skillId string) {
	caller := requirePlayer(cur)
	key := caller + ":" + skillId
	rank := getU(&skillRanks, key)
	maxRank, ok := skillMaxRanks[skillId]
	if !ok {
		panic("unknown skill: " + skillId)
	}
	if rank >= maxRank {
		panic("skill already at maximum rank")
	}
	baseCosts, ok := skillBaseCosts[skillId]
	if !ok {
		panic("unknown skill: " + skillId)
	}
	mult := uint64(1) << rank
	var scaled [][2]string
	for _, pair := range baseCosts {
		baseAmt, _ := strconv.ParseUint(pair[1], 10, 64)
		if s := baseAmt * mult; s > 0 {
			scaled = append(scaled, [2]string{pair[0], strconv.FormatUint(s, 10)})
		}
	}
	deductBalances(caller, scaled)
	setU(&skillRanks, key, rank+1)
}

// ── Achievements (allowlisted, fixed rewards, vouchered) ─────────────────────

func parseGrindId(id string) (string, uint64, bool) {
	if !strings.HasPrefix(id, "g.") {
		return "", 0, false
	}
	rest := id[2:]
	dot := strings.LastIndex(rest, ".")
	if dot <= 0 {
		return "", 0, false
	}
	coin := rest[:dot]
	need, err := strconv.ParseUint(rest[dot+1:], 10, 64)
	if err != nil {
		return "", 0, false
	}
	if _, ok := coinRarity[coin]; !ok {
		return "", 0, false
	}
	for _, r := range grindRungs {
		if r == need {
			return coin, need, true
		}
	}
	return "", 0, false
}

func isValidAchievementId(id string) bool {
	if _, ok := achievementRewards[id]; ok {
		return true
	}
	_, _, ok := parseGrindId(id)
	return ok
}

// achievementReward returns the fixed reward for id, checking any on-chain
// predicate (grind: lifetimeMined ≥ need; "<tool>_own": tool owned).
// ok=false means the id is unknown or not earned on chain.
func achievementReward(addr, id string) ([]coinAmt, string) {
	if coin, need, isGrind := parseGrindId(id); isGrind {
		if getU(&lifetimeMined, addr+":"+coin) < need {
			return nil, "not earned: mined " + strconv.FormatUint(getU(&lifetimeMined, addr+":"+coin), 10) + "/" + strconv.FormatUint(need, 10) + " " + coin
		}
		return []coinAmt{{coin, grindPay(need)}}, ""
	}
	rw, ok := achievementRewards[id]
	if !ok {
		return nil, "unknown achievement: " + id
	}
	if strings.HasSuffix(id, "_own") {
		tool := strings.TrimSuffix(id, "_own")
		if _, isTool := toolCosts[tool]; isTool && !ownsTool(addr, tool) {
			return nil, "not earned: you don't own " + tool
		}
	}
	return rw, ""
}

// claimAchievementsFor claims ids for addr. strict=true panics on any bad id;
// otherwise bad/claimed ids are skipped. Returns the number claimed.
func claimAchievementsFor(addr string, ids []string, strict bool) int {
	if len(ids) > 200 {
		panic("too many achievements in one call (max 200)")
	}
	n := 0
	for _, id := range ids {
		key := addr + ":" + id
		if achievements.Has(key) {
			if strict {
				panic("already claimed")
			}
			continue
		}
		rw, why := achievementReward(addr, id)
		if why != "" {
			if strict {
				panic(why)
			}
			continue
		}
		achievements.Set(key, "1")
		for _, ca := range rw {
			creditReward(addr, ca.coin, ca.amt)
		}
		n++
	}
	return n
}

// ClaimAchievement claims one allowlisted achievement and credits its fixed
// reward. Needs a server voucher of kind "ach" with payload = `["<id>"]`.
func ClaimAchievement(cur realm, achievementId string, nonce int64, expiry int64, sigHex string) {
	caller := requirePlayer(cur)
	payload := `[` + jsonStr(achievementId) + `]`
	useVoucher("ach", caller, nonce, expiry, payload, sigHex)
	claimAchievementsFor(caller, []string{achievementId}, true)
}

// BatchClaimAchievements claims several ids (already-claimed / not-earned ids
// are skipped). idsJson must be exactly the voucher payload.
func BatchClaimAchievements(cur realm, idsJson string, nonce int64, expiry int64, sigHex string) int {
	caller := requirePlayer(cur)
	useVoucher("ach", caller, nonce, expiry, idsJson, sigHex)
	return claimAchievementsFor(caller, parseStringList(idsJson), false)
}

func HasAchievement(addr, id string) bool { return achievements.Has(addr + ":" + id) }

// parseDailyCheckin reads the stored value for an address and returns
// (lastDay, streak). It handles both the new "<lastDay>:<streak>" format
// and the legacy "<unix seconds>" format (which stores raw epoch seconds;
// treated as lastDay = seconds/86400, streak = 1).
func parseDailyCheckin(raw string) (int64, int64) {
	for i := 0; i < len(raw); i++ {
		if raw[i] == ':' {
			lastDay, errD := strconv.ParseInt(raw[:i], 10, 64)
			streak, errS := strconv.ParseInt(raw[i+1:], 10, 64)
			if errD == nil && errS == nil {
				return lastDay, streak
			}
			break
		}
	}
	// Legacy format: raw is a plain unix-seconds timestamp
	seconds, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, 0
	}
	return seconds / 86400, 1
}

func DailyCheckin(cur realm) {
	caller := requirePlayer(cur)
	today := time.Now().Unix() / 86400

	var lastDay, streak int64
	if dailyCheckins.Has(caller) {
		raw := dailyCheckins.Get(caller).(string)
		lastDay, streak = parseDailyCheckin(raw)
	}

	if lastDay == today {
		panic("already checked in today")
	}
	if lastDay == today-1 {
		streak = streak + 1
	} else {
		streak = 1
	}

	val := strconv.FormatInt(today, 10) + ":" + strconv.FormatInt(streak, 10)
	dailyCheckins.Set(caller, val)
}

// Tasks: game28 let anyone mark any task done. In game29 tasks are created
// and completed for a player only by the operator (server) — no free medals.
func CreateTask(cur realm, taskId string, desc string) {
	if !isOperator(cur) {
		panic("unauthorized: operator only")
	}
	if !isSafeId(taskId, 64) {
		panic("invalid task id")
	}
	achievements.Set("task:"+taskId+":desc", sanitizeName(desc))
}

func CompleteTask(cur realm, taskId string) {
	panic("CompleteTask is operator-only in game29 — use CompleteTaskFor")
}

func CompleteTaskFor(cur realm, player string, taskId string) {
	if !isOperator(cur) {
		panic("unauthorized: operator only")
	}
	if !achievements.Has("task:" + taskId + ":desc") {
		panic("unknown task")
	}
	achievements.Set(player+":task."+taskId, "1")
}

