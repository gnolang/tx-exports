// GnoMoji — Main Game Realm
// gno.land/r/gnomoji/game
//
// On-chain game engine for GnoMoji on Gno.land (v1.5.0 / Onyx testnet API).
// Tracks mined coins, casino rounds, PvP lobbies, tools, skills, achievements.
//
// Token minting is handled by gno.land/r/gnomoji/minter (the treasury realm).
// GRC20 coin realms live at gno.land/r/gnomoji/coins/{coinId}.

package game2

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ── State ────────────────────────────────────────────────────────────────────

var (
	admin          address
	pendingMints   avl.Tree // addr+":"+coinId → amount string
	balances       avl.Tree // addr+":"+coinId → amount string
	veinSupply     avl.Tree // coinId → "remaining:max"
	casinoRounds   avl.Tree // roundId → JSON string
	pvpLobbies     avl.Tree // lobbyId → JSON string
	ownedTools     avl.Tree // addr → comma-separated tool IDs
	toolLife       avl.Tree // addr+":"+toolId → remaining life string
	lifetimeMined  avl.Tree // addr+":"+coinId → total mined string
	achievements   avl.Tree // addr+":"+achId → "1"
	dailyCheckins  avl.Tree // addr → unix seconds string
	skillRanks     avl.Tree // addr+":"+skillId → rank string
	miners         avl.Tree // addr → total mined all-time string
	paused         bool
)

func init(cur realm) {
	admin = cur.Previous().Address()
}

// ── Admin ────────────────────────────────────────────────────────────────────

func isAdmin(cur realm) bool {
	return cur.Previous().Address() == admin
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

// ── Mining ───────────────────────────────────────────────────────────────────

// ClaimMine records mined coins into pending mints for the caller.
// coinsJson format: [["coinId","amount"],...]
func ClaimMine(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

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

// ClearPendingMints is called by the minter realm after successful GRC20 minting.
func ClearPendingMints(cur realm, playerAddr string, coinsJson string) {
	if !isAdmin(cur) {
		panic("unauthorized: only admin/minter can clear pending mints")
	}
	coinsJson = strings.TrimSpace(coinsJson)
	coinsJson = strings.TrimPrefix(coinsJson, "[")
	coinsJson = strings.TrimSuffix(coinsJson, "]")
	for _, entry := range splitJsonArray(coinsJson) {
		coinId := strings.Trim(strings.TrimSpace(entry), `"`)
		if coinId != "" {
			pendingMints.Remove(playerAddr + ":" + coinId)
		}
	}
}

// ── Casino ───────────────────────────────────────────────────────────────────

func CommitCasinoSeed(cur realm, roundId string, seedHash string) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	casinoRounds.Set(roundId, `{"roundId":"`+roundId+`","seedHash":"`+seedHash+`","status":"committed","bets":[]}`)
}

func PlaceCasinoBet(cur realm, roundId string, game string, coinId string, betAmount string, choice string, clientSeed string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	amt, err := strconv.ParseUint(betAmount, 10, 64)
	if err != nil || amt == 0 {
		panic("invalid bet amount")
	}

	balKey := caller + ":" + coinId
	existing := uint64(0)
	if balances.Has(balKey) {
		existing, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
	}
	if existing < amt {
		panic("insufficient balance")
	}
	balances.Set(balKey, strconv.FormatUint(existing-amt, 10))

	if !casinoRounds.Has(roundId) {
		panic("round not found")
	}
	bet := `{"addr":"` + caller + `","game":"` + game + `","coinId":"` + coinId + `","amount":` + betAmount + `,"choice":"` + choice + `","clientSeed":"` + clientSeed + `"}`
	casinoRounds.Set(roundId+":bet:"+caller, bet)
}

func RevealCasinoSeed(cur realm, roundId string, serverSeed string) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	casinoRounds.Set(roundId+":serverSeed", serverSeed)
	casinoRounds.Set(roundId+":status", "revealed")
}

func RefundCasinoBet(cur realm, roundId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	betKey := roundId + ":bet:" + caller
	if !casinoRounds.Has(betKey) {
		panic("no bet found for this round")
	}
	casinoRounds.Remove(betKey)
}

// ── PvP Lobbies ──────────────────────────────────────────────────────────────

func CreatePvpLobby(cur realm, game string, coinId string, betAmount string) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	prefix := caller
	if len(prefix) > 8 {
		prefix = caller[:8]
	}
	lobbyId := ufmt.Sprintf("pvp-%s-%d", prefix, time.Now().Unix())
	lobby := `{"lobbyId":"` + lobbyId + `","creator":"` + caller + `","game":"` + game + `","coinId":"` + coinId + `","betAmount":` + betAmount + `,"status":"open","round":1,"createdAt":` + strconv.FormatInt(time.Now().Unix(), 10) + `}`
	pvpLobbies.Set(lobbyId, lobby)
	return lobbyId
}

func JoinPvpLobby(cur realm, lobbyId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	pvpLobbies.Set(lobbyId+":challenger", caller)
	pvpLobbies.Set(lobbyId+":status", "joined")
}

func CommitPvpMove(cur realm, lobbyId string, moveHash string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	pvpLobbies.Set(lobbyId+":commit:"+caller, moveHash)
}

func RevealPvpMove(cur realm, lobbyId string, choice string, salt string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	pvpLobbies.Set(lobbyId+":reveal:"+caller, choice+":"+salt)
	pvpLobbies.Set(lobbyId+":status", "revealed")
}

func ClaimPvpTimeout(cur realm, lobbyId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	pvpLobbies.Set(lobbyId+":winner", caller)
	pvpLobbies.Set(lobbyId+":status", "finished")
}

func ExpireLobbies(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
}

// ── Tools ────────────────────────────────────────────────────────────────────

func BuyTool(cur realm, toolId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
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
	toolLife.Set(caller+":"+toolId, "10000")
}

// ── Progression ──────────────────────────────────────────────────────────────

func TrainSkill(cur realm, skillId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	key := caller + ":" + skillId
	rank := uint64(0)
	if skillRanks.Has(key) {
		rank, _ = strconv.ParseUint(skillRanks.Get(key).(string), 10, 64)
	}
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

func DailyCheckin(cur realm) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	now := time.Now().Unix()
	if dailyCheckins.Has(caller) {
		last, _ := strconv.ParseInt(dailyCheckins.Get(caller).(string), 10, 64)
		if now-last < 72000 {
			panic("too soon for daily check-in")
		}
	}
	dailyCheckins.Set(caller, strconv.FormatInt(now, 10))
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
	done := now-last < 72000
	return ufmt.Sprintf(`{"ok":true,"done":%t,"streak":1,"next":%d}`, done, last+86400)
}

func ListTasks(_ string) string { return `{"ok":true,"tasks":[]}` }

// ── Render ───────────────────────────────────────────────────────────────────

func Render(_ string) string {
	return ufmt.Sprintf("# GnoMoji Game Realm\n\nAdmin: `%s`\n\nPath: `gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game2`\n\nMine emoji coins on Gno.land!\n", admin.String())
}

// ── Helpers ──────────────────────────────────────────────────────────────────

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
