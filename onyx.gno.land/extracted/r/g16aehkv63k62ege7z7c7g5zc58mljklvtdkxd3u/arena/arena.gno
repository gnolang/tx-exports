// Package arena implements the on-chain economy for Arena Ledger, a
// play-to-earn 3D shooter. Every token value is an integer count of
// millitokens (mtok): 1 token == 1000 mtok, so fractional rewards stay
// exact. All balances live in this realm's internal ledger; no external
// GRC20 package is imported.
package arena

import (
	"strconv"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Token amounts, in millitokens (mtok).
const (
	unitPerToken int64 = 1000 // 1 token = 1000 mtok

	entryFee    int64 = 2000 // 2.0 tokens: cost of one match
	baseBounty  int64 = 1200 // 1.2 tokens: escrowed kill bounty
	poolShare   int64 = 800  // 0.8 tokens: community-pool contribution
	boostBounty int64 = 2400 // 2.4 tokens: doubled boosted kill bounty

	startingBalance int64 = entryFee // onboarding grant: one free first entry

	xpPerKill int64 = 40 // base XP for a kill
	xpPerWin  int64 = 60 // base XP for a win

	level1XP int64 = 100 // XP needed for level 1
	level2XP int64 = 300 // XP needed for level 2
	level3XP int64 = 700 // XP needed for level 3

	leaderboardSize = 10
)

// boostedHours are the three UTC hours -- 06:00, 12:00 and 18:00 -- in
// which the kill bounty doubles to 2.4 tokens. The extra 1.2 tokens come
// out of the community pool, not out of the victim's entry allocation.
var boostedHours = []int{6, 12, 18}

// multiplierPct is the XP multiplier applied to kills and wins using the
// player's level BEFORE the award: level 0 = 100% (no bonus),
// level 1 = 110%, level 2 = 120%, level 3 = 130%.
var multiplierPct = []int64{100, 110, 120, 130}

// Player is a single account in the realm's internal token ledger.
type Player struct {
	Addr    address
	Balance int64 // spendable tokens (mtok)
	Pending int64 // earned bounty not yet claimed (mtok)
	Bounty  int64 // bounty escrowed on this player from entries (mtok)
	XP      int64 // cumulative XP
	Kills   int
	Deaths  int
	Wins    int
	Entries int
}

var (
	players          *avl.Tree
	pool             int64 // community pool (mtok)
	totalPlayers     int
	totalEntries     int64
	totalKills       int64
	totalBoostKills  int64
	totalDistributed int64
)

func init() {
	players = avl.NewTree()
}

// callerOf validates a realm token and returns the EOA that crossed into
// this realm. Any helper receiving a realm token must check IsCurrent;
// the exported crossing functions additionally check Previous().IsUserCall().
func callerOf(cur realm) address {
	if !cur.IsCurrent() {
		panic("invalid realm token")
	}
	return cur.Previous().Address()
}

func playerFor(a address) *Player {
	key := a.String()
	if !players.Has(key) {
		return nil
	}
	p, _ := players.Get(key).(*Player)
	return p
}

func getOrCreate(a address) *Player {
	p := playerFor(a)
	if p == nil {
		// A small onboarding grant lets a new player enter their first match.
		p = &Player{Addr: a, Balance: startingBalance}
		players.Set(a.String(), p)
		totalPlayers++
	}
	return p
}

// formatTokens renders millitokens as a decimal token string, trimming
// trailing zeros: 1200 -> "1.2", 2400 -> "2.4", 800 -> "0.8", 2000 -> "2".
// The game client prefixes this with "+" to display "+1.2" in the HUD.
func formatTokens(mtok int64) string {
	sign := ""
	if mtok < 0 {
		sign = "-"
		mtok = -mtok
	}
	whole := mtok / unitPerToken
	frac := mtok % unitPerToken
	if frac == 0 {
		return sign + strconv.FormatInt(whole, 10)
	}
	fs := strconv.FormatInt(frac, 10)
	for len(fs) < 3 {
		fs = "0" + fs
	}
	for len(fs) > 0 && fs[len(fs)-1] == '0' {
		fs = fs[:len(fs)-1]
	}
	return sign + strconv.FormatInt(whole, 10) + "." + fs
}

// entrySplit returns the bounty and community-pool parts of an entry fee.
// Their sum is exactly entryFee (1.2 + 0.8 = 2.0 tokens).
func entrySplit() (bounty, community int64) {
	return baseBounty, poolShare
}

// isBoosted reports whether t is inside one of the three boosted UTC hours.
func isBoosted(t time.Time) bool {
	h := t.UTC().Hour()
	for _, bh := range boostedHours {
		if h == bh {
			return true
		}
	}
	return false
}

// bountyForKill returns the payout and the portion funded by the community
// pool for a kill at time t. A normal kill pays 1.2 tokens entirely from
// the victim's bounty allocation. A boosted kill pays 2.4 tokens: 1.2 from
// the victim and 1.2 from the community pool.
func bountyForKill(t time.Time) (payout, fromPool int64) {
	if isBoosted(t) {
		return boostBounty, boostBounty - baseBounty
	}
	return baseBounty, 0
}

// levelForXP maps cumulative XP to a level. Players start unranked (0) and
// reach level 1 at 100 XP, level 2 at 300 XP and level 3 at 700 XP.
func levelForXP(xp int64) int {
	switch {
	case xp >= level3XP:
		return 3
	case xp >= level2XP:
		return 2
	case xp >= level1XP:
		return 1
	default:
		return 0
	}
}

// awardXP grants base XP modified by the player's current level and
// returns the amount actually awarded.
func awardXP(p *Player, base int64) int64 {
	lvl := levelForXP(p.XP)
	gained := base * multiplierPct[lvl] / 100
	p.XP += gained
	return gained
}

// Enter charges the caller 2 tokens to join a match. Of that, 1.2 tokens
// become a bounty on the entrant and 0.8 tokens go to the community pool.
func Enter(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("Enter: EOA calls only")
	}
	a := callerOf(cur)
	p := getOrCreate(a)
	if p.Balance < entryFee {
		panic("Enter: not enough balance (need 2 tokens)")
	}
	bounty, community := entrySplit()
	p.Balance -= entryFee
	p.Bounty += bounty
	pool += community
	p.Entries++
	totalEntries++
	chain.Emit("Enter", "player", a.String(), "cost", formatTokens(entryFee),
		"bounty", formatTokens(bounty), "pool", formatTokens(community))
}

// ReportKill credits the caller for killing victim. The caller is the
// killer; the victim must already have an entry bounty escrowed. During a
// boosted hour the payout is 2.4 tokens, with the extra 1.2 taken from the
// community pool. The Kill event carries the numeric "amount" (e.g. 1.2)
// so the client can display "+1.2".
func ReportKill(cur realm, victim string) {
	if !cur.Previous().IsUserCall() {
		panic("ReportKill: EOA calls only")
	}
	killerAddr := callerOf(cur)
	victimAddr := address(victim)
	if victimAddr == killerAddr {
		panic("ReportKill: cannot score a kill on yourself")
	}
	victimPlayer := playerFor(victimAddr)
	if victimPlayer == nil {
		panic("ReportKill: unknown victim")
	}
	killer := getOrCreate(killerAddr)

	payout, fromPool := bountyForKill(time.Now())
	if victimPlayer.Bounty < baseBounty {
		panic("ReportKill: victim has no bounty allocation")
	}
	if fromPool > pool {
		panic("ReportKill: community pool cannot fund the boost")
	}

	// Settle: consume the victim's base bounty, draw any boost from the pool.
	victimPlayer.Bounty -= baseBounty
	pool -= fromPool
	killer.Pending += payout
	killer.Kills++
	victimPlayer.Deaths++
	totalKills++
	totalDistributed += payout
	boosted := fromPool > 0
	if boosted {
		totalBoostKills++
	}
	gained := awardXP(killer, xpPerKill)

	chain.Emit("Kill", "killer", killerAddr.String(), "victim", victim,
		"amount", formatTokens(payout), "boosted", strconv.FormatBool(boosted),
		"xp", strconv.FormatInt(gained, 10))
	if boosted {
		chain.Emit("Boost", "killer", killerAddr.String(),
			"amount", formatTokens(payout), "hour", strconv.Itoa(time.Now().UTC().Hour()))
	}
}

// ReportWin records a match win for the caller. Wins grant XP (with the
// caller's level multiplier) but do not move tokens.
func ReportWin(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("ReportWin: EOA calls only")
	}
	a := callerOf(cur)
	p := getOrCreate(a)
	p.Wins++
	gained := awardXP(p, xpPerWin)
	chain.Emit("Win", "player", a.String(), "xp", strconv.FormatInt(gained, 10))
}

// Claim moves the caller's pending kill rewards into their spendable
// balance so they can pay for another entry.
func Claim(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("Claim: EOA calls only")
	}
	a := callerOf(cur)
	p := playerFor(a)
	if p == nil {
		panic("Claim: no player record")
	}
	amount := p.Pending
	if amount <= 0 {
		panic("Claim: nothing to claim")
	}
	p.Pending = 0
	p.Balance += amount
	chain.Emit("Claim", "player", a.String(), "amount", formatTokens(amount),
		"amount_mtok", strconv.FormatInt(amount, 10))
}

// better ranks a above b by XP, then kills, then wins, then address.
// It is the strict ordering used to build the leaderboard.
func better(a, b *Player) bool {
	if a.XP != b.XP {
		return a.XP > b.XP
	}
	if a.Kills != b.Kills {
		return a.Kills > b.Kills
	}
	if a.Wins != b.Wins {
		return a.Wins > b.Wins
	}
	return a.Addr.String() < b.Addr.String()
}

// Top returns the ten highest-ranked players according to better.
func Top() []*Player {
	list := []*Player{}
	players.Iterate("", "", func(key string, value any) bool {
		if p, ok := value.(*Player); ok {
			list = append(list, p)
		}
		return false
	})
	for i := 1; i < len(list); i++ {
		j := i
		for j > 0 && better(list[j], list[j-1]) {
			list[j], list[j-1] = list[j-1], list[j]
			j--
		}
	}
	if len(list) > leaderboardSize {
		return list[:leaderboardSize]
	}
	return list
}

// Pool returns the community pool balance in millitokens.
func Pool() int64 { return pool }

// Players returns the number of registered players.
func Players() int { return totalPlayers }

// TotalEntries returns the number of paid entries.
func TotalEntries() int64 { return totalEntries }

// TotalKills returns the number of reported kills.
func TotalKills() int64 { return totalKills }

// TotalBoostKills returns the number of kills settled in a boosted window.
func TotalBoostKills() int64 { return totalBoostKills }

// TotalDistributed returns the total tokens paid out as bounties (mtok).
func TotalDistributed() int64 { return totalDistributed }

// Balance returns a player's spendable internal balance in millitokens.
func Balance(a address) int64 {
	if p := playerFor(a); p != nil {
		return p.Balance
	}
	return 0
}

// Render draws the realm documentation, gno-forms for every public
// crossing function, and the current leaderboard.
func Render(path string) string {
	out := "# Arena Ledger\n\n"
	out += "Pay 2 tokens to drop into the arena, take down opponents, and earn their bounty. "
	out += "Every entry, kill and payout is settled in this realm's internal token ledger.\n\n"

	out += "## Economy\n\n"
	out += "| Event | Tokens | Detail |\n|---|---:|---|\n"
	out += "| Entry | " + formatTokens(entryFee) + " | 2 tokens per match |\n"
	out += "| Kill bounty | " + formatTokens(baseBounty) + " | from the victim's entry allocation; shown as +" + formatTokens(baseBounty) + " |\n"
	out += "| Community pool | " + formatTokens(poolShare) + " | from each entry; funds boost windows |\n"
	out += "| Boosted kill | " + formatTokens(boostBounty) + " | 1.2 from the victim + 1.2 from the community pool |\n\n"
	out += "Boosted windows are the UTC hours 06:00, 12:00 and 18:00 (each lasts one hour). "

	out += "## Levels\n\n"
	out += "Level 1 at 100 XP, level 2 at 300 XP, level 3 at 700 XP. Kills grant "
	out += strconv.FormatInt(xpPerKill, 10) + " base XP and wins grant "
	out += strconv.FormatInt(xpPerWin, 10) + " base XP; the current level multiplies both by "
	out += "100% / 110% / 120% / 130% (levels 0 / 1 / 2 / 3).\n\n"

	out += "## Stats\n\n"
	out += "| Players | Entries | Kills | Boosted kills | Pool | Distributed |\n"
	out += "|---:|---:|---:|---:|---:|---:|\n"
	out += "| " + strconv.Itoa(totalPlayers) + " | " + strconv.FormatInt(totalEntries, 10) +
		" | " + strconv.FormatInt(totalKills, 10) + " | " + strconv.FormatInt(totalBoostKills, 10) +
		" | " + formatTokens(pool) + " | " + formatTokens(totalDistributed) + " |\n\n"

	out += "## Actions\n\n"
	out += "<gno-form exec=\"Enter\">\n<gno-button label=\"Enter match (2 tokens)\" />\n</gno-form>\n\n"
	out += "<gno-form exec=\"ReportKill\">\n<gno-input name=\"victim\" type=\"text\" placeholder=\"Victim g1... address\" required=\"true\" />\n<gno-button label=\"Report kill\" />\n</gno-form>\n\n"
	out += "<gno-form exec=\"ReportWin\">\n<gno-button label=\"Report win\" />\n</gno-form>\n\n"
	out += "<gno-form exec=\"Claim\">\n<gno-button label=\"Claim pending bounty\" />\n</gno-form>\n\n"

	out += "## Leaderboard\n\n"
	out += "| # | Player | Level | XP | Kills | Wins | Balance |\n"
	out += "|---:|---|---:|---:|---:|---:|---:|\n"
	for i, p := range Top() {
		// Addresses originate from user calls, so sanitize before rendering.
		who := sanitize.InlineText(p.Addr.String())
		out += "| " + strconv.Itoa(i+1) + " | " + who + " | " + strconv.Itoa(levelForXP(p.XP)) +
			" | " + strconv.FormatInt(p.XP, 10) + " | " + strconv.Itoa(p.Kills) +
			" | " + strconv.Itoa(p.Wins) + " | " + formatTokens(p.Balance) + " |\n"
	}
	return out
}
