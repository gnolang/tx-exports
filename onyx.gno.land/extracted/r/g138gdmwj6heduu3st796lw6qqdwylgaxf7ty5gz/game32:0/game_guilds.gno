package game32

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ── Guilds ───────────────────────────────────────────────────────────────────

const maxGuildMembers = 10
const maxGuildNameLen = 24

func guildJSON(guildId, name, leader string, members int, createdAt int64) string {
	return `{"guildId":` + jsonStr(guildId) + `,"name":` + jsonStr(name) + `,"leader":` + jsonStr(leader) +
		`,"memberCount":` + strconv.Itoa(members) + `,"createdAt":` + strconv.FormatInt(createdAt, 10) + `}`
}

func guildMemberCount(gid string) int {
	n := 0
	guildMembers.Iterate(gid+":", gid+";", func(string, any) bool {
		n++
		return false
	})
	return n
}

type guildMeta struct {
	name, leader string
	createdAt    int64
}

// guild meta is stored alongside the JSON so it can be re-rendered safely.
var guildMetas = map[string]guildMeta{}

func rewriteGuild(gid string) {
	m, ok := guildMetas[gid]
	if !ok {
		return
	}
	guilds.Set(gid, guildJSON(gid, m.name, m.leader, guildMemberCount(gid), m.createdAt))
}

func CreateGuild(cur realm, name string) string {
	caller := requirePlayer(cur)
	if playerGuild.Has(caller) {
		panic("already in a guild")
	}
	name = sanitizeName(name)
	if len(name) < 3 {
		panic("guild name too short (min 3 chars)")
	}
	if len(name) > maxGuildNameLen {
		panic("guild name too long (max 24 chars)")
	}
	guildCounter++
	gid := "guild-" + zeroPad(guildCounter, 6)
	now := time.Now().Unix()
	guildMetas[gid] = guildMeta{name: name, leader: caller, createdAt: now}
	guildMembers.Set(gid+":"+caller, "1")
	playerGuild.Set(caller, gid)
	rewriteGuild(gid)
	return gid
}

func JoinGuild(cur realm, guildId string) {
	caller := requirePlayer(cur)
	if playerGuild.Has(caller) {
		panic("already in a guild — leave current guild first")
	}
	if !guilds.Has(guildId) {
		panic("guild not found")
	}
	if guildMemberCount(guildId) >= maxGuildMembers {
		panic("guild is full (max 10 members)")
	}
	guildMembers.Set(guildId+":"+caller, "1")
	playerGuild.Set(caller, guildId)
	rewriteGuild(guildId)
}

func LeaveGuild(cur realm) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if !playerGuild.Has(caller) {
		panic("not in a guild")
	}
	gid := playerGuild.Get(caller).(string)
	guildMembers.Remove(gid + ":" + caller)
	playerGuild.Remove(caller)
	if guildMemberCount(gid) == 0 {
		guilds.Remove(gid)
		delete(guildMetas, gid)
		return
	}
	if m, ok := guildMetas[gid]; ok && m.leader == caller {
		// hand leadership to the first remaining member
		guildMembers.Iterate(gid+":", gid+";", func(k string, _ any) bool {
			m.leader = strings.TrimPrefix(k, gid+":")
			return true
		})
		guildMetas[gid] = m
	}
	rewriteGuild(gid)
}

func PlayerGuild(addr string) string {
	if !playerGuild.Has(addr) {
		return ""
	}
	gid := playerGuild.Get(addr).(string)
	if !guilds.Has(gid) {
		return ""
	}
	return guilds.Get(gid).(string)
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
	var all guildRows
	guilds.Iterate("", "", func(k string, v any) bool {
		all = append(all, guildRow{v.(string), guildMemberCount(k)})
		return false
	})
	sort.Stable(all)
	var parts []string
	for i := 0; i < len(all) && i < limit; i++ {
		parts = append(parts, all[i].js)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// ── Queries ──────────────────────────────────────────────────────────────────

func kvJSON(prefixAddr string, t *avl.Tree) string {
	var parts []string
	t.Iterate(prefixAddr+":", prefixAddr+";", func(key string, val any) bool {
		parts = append(parts, jsonStr(strings.TrimPrefix(key, prefixAddr+":"))+":"+val.(string))
		return false
	})
	return "{" + strings.Join(parts, ",") + "}"
}

func AllBalances(playerAddr string) string   { return kvJSON(playerAddr, &balances) }
func LifetimeMined(playerAddr string) string { return kvJSON(playerAddr, &lifetimeMined) }

// PlayerXp returns the caller's cumulative rarity-weighted XP earned from
// ClaimAndMint calls as a plain decimal string (e.g. "12345"). Returns "0"
// for players who have not yet minted anything on this realm version.
func PlayerXp(playerAddr string) string {
	return strconv.FormatUint(getU(&playerXp, playerAddr), 10)
}

// Rewarded returns what rewards (medals etc.) credited, per coin. Separate
// from LifetimeMined.
func Rewarded(playerAddr string) string { return kvJSON(playerAddr, &rewarded) }
func SkillRanks(playerAddr string) string    { return kvJSON(playerAddr, &skillRanks) }
func ToolLife(playerAddr string) string      { return kvJSON(playerAddr, &toolLife) }

func OwnedTools(playerAddr string) string {
	if !ownedTools.Has(playerAddr) || ownedTools.Get(playerAddr).(string) == "" {
		return `["hands"]`
	}
	var quoted []string
	for _, id := range strings.Split(ownedTools.Get(playerAddr).(string), ",") {
		quoted = append(quoted, jsonStr(id))
	}
	return "[" + strings.Join(quoted, ",") + "]"
}

func PlayerProfile(playerAddr string) string {
	return `{"address":` + jsonStr(playerAddr) + `,"bestTool":` + jsonStr(bestOwnedTool(playerAddr)) +
		`,"total":` + strconv.FormatUint(getU(&miners, playerAddr), 10) + `,"passExpiry":` + strconv.FormatInt(GnomePassExpiry(playerAddr), 10) + `}`
}

// AllMiners returns the leaderboard sorted by total mined (desc), paginated.
// (game28 returned it in address order.)
func AllMiners(limit int, offset int) string {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	var rows minerRows
	miners.Iterate("", "", func(k string, v any) bool {
		t, _ := strconv.ParseUint(v.(string), 10, 64)
		rows = append(rows, minerRow{k, t})
		return false
	})
	sort.Sort(rows)
	var parts []string
	for i := offset; i < len(rows) && i < offset+limit; i++ {
		d := rows[i].addr
		if len(d) > 12 {
			d = d[:8] + "..."
		}
		parts = append(parts, `{"address":`+jsonStr(rows[i].addr)+`,"display":`+jsonStr(d)+`,"total":`+strconv.FormatUint(rows[i].total, 10)+`,"rank":`+strconv.Itoa(i+1)+`}`)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func GetMedals(playerAddr string) string {
	var claimed []string
	achievements.Iterate(playerAddr+":", playerAddr+";", func(key string, _ any) bool {
		claimed = append(claimed, jsonStr(strings.TrimPrefix(key, playerAddr+":")))
		return false
	})
	return `{"medals":[` + strings.Join(claimed, ",") + `]}`
}

func DailyCheckinStatus(playerAddr string) string {
	today := time.Now().Unix() / 86400
	var lastDay, streak int64
	if dailyCheckins.Has(playerAddr) {
		raw := dailyCheckins.Get(playerAddr).(string)
		lastDay, streak = parseDailyCheckin(raw)
	}
	done := lastDay == today
	// Streak is live only if the player checked in today or yesterday.
	// If they missed a day, report 0 so the client knows the streak is broken.
	liveStreak := streak
	if lastDay < today-1 {
		liveStreak = 0
	}
	nextMidnight := (today + 1) * 86400
	return ufmt.Sprintf(`{"ok":true,"done":%t,"streak":%d,"next":%d}`, done, liveStreak, nextMidnight)
}

func ListTasks(_ string) string {
	var parts []string
	achievements.Iterate("task:", "task;", func(k string, v any) bool {
		if strings.HasSuffix(k, ":desc") {
			id := strings.TrimSuffix(strings.TrimPrefix(k, "task:"), ":desc")
			parts = append(parts, `{"id":`+jsonStr(id)+`,"desc":`+jsonStr(v.(string))+`}`)
		}
		return false
	})
	return `{"ok":true,"tasks":[` + strings.Join(parts, ",") + `]}`
}

// ── Render ───────────────────────────────────────────────────────────────────

func Render(_ string) string {
	return ufmt.Sprintf("# GnoMoji Game Realm — game32\n\nAdmin: `%s`\n\nPath: `%s`\n\nClaims: server-vouchered (%s)\n\nMigration finalized: %t\n\nMine emoji coins on Gno.land!\n",
		admin.String(), realmPkgPath, func() string {
			if len(claimSignerPubKey) == 32 {
				return "signer set"
			}
			return "disabled — no signer"
		}(), migrationFinalized)
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// deductBalances checks all balances, then deducts (no partial deductions).
func deductBalances(caller string, costs [][2]string) {
	for _, pair := range costs {
		required, err := strconv.ParseUint(pair[1], 10, 64)
		if err != nil || required == 0 {
			continue
		}
		if have := balOf(caller, pair[0]); have < required {
			panic("insufficient " + pair[0] + ": need " + pair[1] + " have " + strconv.FormatUint(have, 10))
		}
	}
	for _, pair := range costs {
		required, err := strconv.ParseUint(pair[1], 10, 64)
		if err != nil || required == 0 {
			continue
		}
		debitBal(caller, pair[0], required)
	}
}

type guildRow struct {
	js string
	n  int
}
type guildRows []guildRow

func (g guildRows) Len() int           { return len(g) }
func (g guildRows) Less(i, j int) bool { return g[i].n > g[j].n }
func (g guildRows) Swap(i, j int)      { g[i], g[j] = g[j], g[i] }

type minerRow struct {
	addr  string
	total uint64
}
type minerRows []minerRow

func (m minerRows) Len() int { return len(m) }
func (m minerRows) Less(i, j int) bool {
	if m[i].total != m[j].total {
		return m[i].total > m[j].total
	}
	return m[i].addr < m[j].addr
}
func (m minerRows) Swap(i, j int) { m[i], m[j] = m[j], m[i] }
