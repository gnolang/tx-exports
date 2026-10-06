// GnoMoji — Main Game Realm
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game5
//
// On-chain game engine for GnoMoji on Gno.land (v1.5.0 / Onyx testnet API).
// Tracks mined coins, casino rounds, PvP lobbies, tools, skills, achievements.
//
// Token minting is handled by gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/minter5.
// Unified coin balances live at gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/coins.
// Phase 2: On-chain cost enforcement for BuyTool, RepairTool, and TrainSkill.

package game5

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
	minterAddr     address  // authorized minter realm (minter5) — set via SetMinter
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
	lastClaim      avl.Tree // addr → unix timestamp of last ClaimMine (velocity limit)
	paused         bool
)

// ── Cost Tables ───────────────────────────────────────────────────────────────

// toolCosts maps toolId → slice of [coinId, amount] pairs.
// Copied from catalog.ts TOOLS array. Amounts are for qty=1.
var toolCosts = map[string][][2]string{
	"twig":    {{"grin", "120"}, {"joy", "75"}, {"cool", "60"}},
	"wood":    {{"seedling", "180"}, {"leaves", "150"}, {"fallen", "120"}, {"think", "105"}, {"sleep", "90"}, {"party", "75"}},
	"stone":   {{"rock", "600"}, {"log", "540"}, {"evergreen", "480"}, {"brick", "420"}, {"mushroom", "360"}, {"heart", "300"}},
	"iron":    {{"gear", "840"}, {"chains", "780"}, {"wrench", "720"}, {"hammer", "660"}, {"anchor", "630"}, {"pick", "570"}},
	"gold":    {{"gold-medal", "1140"}, {"crown", "1080"}, {"trophy", "1020"}, {"money-bag", "960"}, {"bolt", "930"}, {"sword", "870"}},
	"diamond": {{"gem", "1560"}, {"coin", "1440"}, {"ring", "1380"}, {"disco", "1320"}, {"kite", "1260"}, {"dodo", "1140"}},
	"cosmic":  {{"galaxy", "1950"}, {"moai", "1860"}, {"hamsa", "1800"}, {"mirror", "1740"}, {"atom", "1650"}, {"ufo", "1500"}},
	"plasma":  {{"galaxy", "2250"}, {"atom", "2100"}, {"moai", "2100"}, {"comet", "1950"}, {"jelly", "1800"}, {"peacock", "1800"}},
	"neutron": {{"jelly", "2850"}, {"peacock", "2700"}, {"unicorn", "2550"}, {"galaxy", "2400"}, {"hamsa", "2400"}, {"dna", "2100"}},
	"quasar":  {{"unicorn", "3450"}, {"peacock", "3300"}, {"jelly", "3300"}, {"lotus", "2550"}, {"galaxy", "2850"}, {"dragon", "2550"}},
	"void":    {{"lotus", "3600"}, {"unicorn", "4350"}, {"dragon", "4200"}, {"peacock", "4350"}, {"jelly", "4500"}, {"galaxy", "1500"}},
	"genesis": {{"lotus", "5400"}, {"dragon", "5400"}, {"unicorn", "5250"}, {"peacock", "4950"}, {"jelly", "4800"}, {"infinity", "4200"}},
	"omega":   {{"lotus", "6900"}, {"dragon", "6600"}, {"unicorn", "6300"}, {"peacock", "6000"}, {"jelly", "6000"}, {"infinity", "5700"}},
}

// skillBaseCosts maps skillId → base cost at rank 0.
// Actual cost at rank N = base × 2^N (doubles per rank).
var skillBaseCosts = map[string][][2]string{
	// STRIKE branch
	"wrist":               {{"grin", "80"}, {"joy", "20"}},
	"palm_strike":         {{"cool", "60"}, {"think", "40"}},
	"follow":              {{"fire", "40"}, {"up", "40"}},
	"knuckle_wrap":        {{"rock", "45"}, {"log", "40"}},
	"heavy_swing":         {{"brick", "35"}, {"evergreen", "30"}},
	"stone_breaker":       {{"rock", "70"}, {"hammer", "25"}, {"gear", "20"}},
	"anvil_force":         {{"chains", "35"}, {"wrench", "30"}, {"brick", "60"}},
	"point_drive":         {{"pick", "35"}, {"gear", "40"}, {"log", "90"}},
	"kinetic_thrust":      {{"rocket", "20"}, {"bolt", "12"}, {"fire", "70"}},
	"crushing_blow":       {{"crown", "10"}, {"trophy", "12"}, {"hammer", "45"}, {"bolt", "15"}},
	"shatter_spike":       {{"sword", "18"}, {"pick", "45"}, {"chains", "45"}, {"gold-medal", "12"}},
	"ironclad_cleave":     {{"anchor", "40"}, {"gear", "60"}, {"wrench", "50"}, {"money-bag", "15"}},
	"thunder_jab":         {{"bolt", "25"}, {"rocket", "30"}, {"fire", "120"}, {"wand", "15"}},
	"titan_hammer":        {{"gem", "14"}, {"coin", "18"}, {"crown", "22"}, {"trophy", "22"}, {"sword", "28"}},
	"diamond_cleave":      {{"gem", "20"}, {"ring", "12"}, {"disco", "15"}, {"pick", "70"}, {"gold-medal", "24"}},
	"hyper_drive":         {{"kite", "15"}, {"dodo", "12"}, {"bolt", "35"}, {"rocket", "45"}, {"gear", "70"}},
	"quasar_impact":       {{"galaxy", "18"}, {"moai", "18"}, {"atom", "20"}, {"ufo", "16"}, {"comet", "18"}},
	"black_hole_crush":    {{"galaxy", "30"}, {"atom", "28"}, {"moai", "24"}, {"gem", "35"}, {"ring", "28"}, {"comet", "22"}},
	"mythic_annihilation": {{"dragon", "8"}, {"unicorn", "10"}, {"jelly", "12"}, {"peacock", "12"}, {"galaxy", "35"}, {"moai", "30"}},
	"singularity_fist":    {{"infinity", "6"}, {"lotus", "8"}, {"dragon", "10"}, {"unicorn", "12"}, {"jelly", "14"}, {"galaxy", "40"}},
	// FORTUNE branch
	"fortune":             {{"clover", "16"}, {"heart", "40"}},
	"four_leaf":           {{"seedling", "60"}, {"leaves", "50"}},
	"edge":                {{"pizza", "20"}, {"spark", "30"}},
	"glint":               {{"spark", "50"}, {"star", "12"}},
	"spark_chaser":        {{"fire", "45"}, {"tada", "25"}},
	"razor_focus":         {{"coffee", "25"}, {"game", "25"}, {"hundred", "30"}},
	"precision_cut":       {{"eyes", "40"}, {"skull", "35"}, {"flutter", "18"}},
	"aurora_gaze":         {{"rainbow", "15"}, {"spark", "60"}, {"moon", "20"}},
	"starlight_gleam":     {{"star", "25"}, {"clover", "20"}, {"heart", "80"}},
	"double_haul":         {{"gear", "30"}, {"anchor", "20"}, {"up", "70"}},
	"twin_strike":         {{"chains", "25"}, {"wrench", "25"}, {"pick", "20"}},
	"executioner":         {{"skull", "60"}, {"sword", "18"}, {"crown", "10"}, {"orb", "8"}},
	"celestial_sight":     {{"planet", "10"}, {"moon", "30"}, {"star", "30"}, {"bead", "8"}},
	"helix_harmony":       {{"dna", "12"}, {"spark", "80"}, {"rainbow", "25"}, {"orb", "10"}},
	"fortune_split":       {{"money-bag", "15"}, {"gold-medal", "12"}, {"clover", "35"}, {"chains", "40"}},
	"critical_surge":      {{"gem", "15"}, {"disco", "14"}, {"ring", "12"}, {"orb", "20"}, {"planet", "18"}},
	"astral_scintillation": {{"ring", "14"}, {"gem", "16"}, {"dna", "20"}, {"star", "60"}, {"moon", "50"}},
	"plunder_frenzy":      {{"coin", "25"}, {"money-bag", "30"}, {"gem", "12"}, {"crown", "25"}, {"trophy", "25"}},
	"singularity_edge":    {{"lotus", "6"}, {"dragon", "8"}, {"galaxy", "25"}, {"hamsa", "20"}, {"atom", "22"}, {"mirror", "20"}},
	"cosmic_fortune":      {{"peacock", "10"}, {"unicorn", "8"}, {"comet", "25"}, {"disco", "30"}, {"galaxy", "30"}, {"gem", "35"}},
	// POCKET branch
	"dustbag":             {{"grin", "200"}, {"sleep", "40"}},
	"rhythm":              {{"music", "16"}, {"clap", "30"}},
	"pocket_expansion":    {{"fallen", "45"}, {"herb", "35"}},
	"steady_tempo":        {{"party", "40"}, {"wow", "30"}},
	"cadence":             {{"music", "30"}, {"coffee", "20"}, {"clap", "50"}},
	"deep_pouch":          {{"log", "70"}, {"rock", "60"}, {"mushroom", "35"}},
	"vein_resonator":      {{"flutter", "20"}, {"rainbow", "15"}, {"tada", "40"}},
	"cart_bed":            {{"log", "120"}, {"rock", "100"}, {"brick", "80"}, {"money-bag", "10"}},
	"bounty_overflow":     {{"trophy", "15"}, {"crown", "12"}, {"pick", "45"}, {"game", "35"}},
	"fracture_pulse":      {{"bolt", "25"}, {"wand", "15"}, {"hammer", "50"}, {"rocket", "25"}},
	"metro_pulse":         {{"music", "45"}, {"coffee", "35"}, {"raise", "30"}, {"bolt", "15"}},
	"hoarders_tote":       {{"coin", "22"}, {"gem", "10"}, {"money-bag", "35"}, {"rock", "150"}, {"log", "150"}},
	"shatter_strike":      {{"gem", "14"}, {"bolt", "35"}, {"wand", "25"}, {"sword", "30"}, {"hammer", "60"}},
	"super_conductor":     {{"coin", "20"}, {"ring", "12"}, {"music", "60"}, {"bolt", "30"}, {"coffee", "50"}},
	"dodo_instinct":       {{"dodo", "14"}, {"kite", "14"}, {"crown", "22"}, {"trophy", "22"}, {"eyes", "80"}},
	"void_rend":           {{"infinity", "6"}, {"jelly", "12"}, {"dragon", "8"}, {"atom", "30"}, {"comet", "25"}, {"bolt", "60"}},
	"celestial_duplication": {{"infinity", "5"}, {"lotus", "6"}, {"dragon", "8"}, {"peacock", "10"}, {"coin", "40"}, {"gem", "35"}},
	"eternity_flow":       {{"infinity", "5"}, {"lotus", "6"}, {"peacock", "8"}, {"hamsa", "25"}, {"mirror", "25"}, {"music", "100"}},
	"abyssal_reserve":     {{"unicorn", "6"}, {"jelly", "10"}, {"moai", "25"}, {"ufo", "25"}, {"money-bag", "50"}, {"rock", "300"}},
	"singularity_snap":    {{"infinity", "8"}, {"lotus", "8"}, {"dragon", "10"}, {"galaxy", "40"}, {"moai", "30"}, {"bolt", "80"}},
}

// skillMaxRanks maps skillId → maximum rank allowed.
// Most skills cap at 3 or 4 — see catalog.ts SKILLS[*].max.
var skillMaxRanks = map[string]uint64{
	// Strike branch (max varies: 3–5)
	"wrist": 5, "palm_strike": 4, "follow": 3, "knuckle_wrap": 4, "heavy_swing": 4,
	"stone_breaker": 4, "anvil_force": 4, "point_drive": 4, "kinetic_thrust": 4,
	"crushing_blow": 4, "shatter_spike": 4, "ironclad_cleave": 3, "thunder_jab": 3,
	"titan_hammer": 3, "diamond_cleave": 3, "hyper_drive": 3, "quasar_impact": 3,
	"black_hole_crush": 3, "mythic_annihilation": 3, "singularity_fist": 3,
	// Fortune branch (all max 3 or 4)
	"fortune": 4, "four_leaf": 3, "edge": 3, "glint": 3, "spark_chaser": 3,
	"razor_focus": 3, "precision_cut": 3, "aurora_gaze": 3, "starlight_gleam": 3,
	"double_haul": 3, "twin_strike": 3, "executioner": 3, "celestial_sight": 3,
	"helix_harmony": 3, "fortune_split": 3, "critical_surge": 3,
	"astral_scintillation": 3, "plunder_frenzy": 3, "singularity_edge": 3, "cosmic_fortune": 3,
	// Pocket branch (all max 3)
	"dustbag": 3, "rhythm": 3, "pocket_expansion": 3, "steady_tempo": 3, "cadence": 3,
	"deep_pouch": 3, "vein_resonator": 3, "cart_bed": 3, "bounty_overflow": 3,
	"fracture_pulse": 3, "metro_pulse": 3, "hoarders_tote": 3, "shatter_strike": 3,
	"super_conductor": 3, "dodo_instinct": 3, "void_rend": 3, "celestial_duplication": 3,
	"eternity_flow": 3, "abyssal_reserve": 3, "singularity_snap": 3,
}

// toolMaxLife maps toolId → maximum durability (from catalog.ts tool.life).
// Tools with life=0 are indestructible (hands, twig).
var toolMaxLife = map[string]uint64{
	"hands": 0, "twig": 0, "wood": 1200, "stone": 2500, "iron": 4000,
	"gold": 6000, "diamond": 8000, "cosmic": 10000, "plasma": 10000,
	"neutron": 10000, "quasar": 10000, "void": 12000, "genesis": 15000, "omega": 25000,
}

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

// ── Mining ───────────────────────────────────────────────────────────────────

// ClaimMine records mined coins into pending mints for the caller.
// coinsJson format: [["coinId","amount"],...]
func ClaimMine(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	// Velocity limit: minimum 5 seconds between ClaimMine calls per address
	now := time.Now().Unix()
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < 5 {
			panic("claiming too fast — please wait 5 seconds between claims")
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

	// Parse bet JSON to recover coinId and amount before removing the record.
	// Bet JSON format: {"addr":"...","game":"...","coinId":"...","amount":N,...}
	betJson := casinoRounds.Get(betKey).(string)

	// Extract coinId (quoted string value)
	coinId := ""
	coinIdStart := strings.Index(betJson, `"coinId":"`) + len(`"coinId":"`)
	if coinIdStart > len(`"coinId":"`) {
		coinIdEnd := strings.Index(betJson[coinIdStart:], `"`) + coinIdStart
		if coinIdEnd > coinIdStart {
			coinId = betJson[coinIdStart:coinIdEnd]
		}
	}

	// Extract amount (unquoted numeric value)
	amountStr := ""
	amountStart := strings.Index(betJson, `"amount":`) + len(`"amount":`)
	if amountStart > len(`"amount":`) {
		amountEnd := strings.IndexAny(betJson[amountStart:], `,}`) + amountStart
		if amountEnd > amountStart {
			amountStr = betJson[amountStart:amountEnd]
		}
	}

	amount, _ := strconv.ParseUint(amountStr, 10, 64)
	if amount > 0 && coinId != "" {
		// Restore the deducted balance
		balKey := caller + ":" + coinId
		current := uint64(0)
		if balances.Has(balKey) {
			current, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
		}
		balances.Set(balKey, strconv.FormatUint(current+amount, 10))
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

// RevealPvpMove requires both players to have committed before either can reveal.
func RevealPvpMove(cur realm, lobbyId string, choice string, salt string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	// Verify lobby exists and both players have committed
	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	lobbyJson := pvpLobbies.Get(lobbyId).(string)
	// Extract creator address from JSON
	creatorStart := strings.Index(lobbyJson, `"creator":"`) + len(`"creator":"`)
	creatorEnd := strings.Index(lobbyJson[creatorStart:], `"`) + creatorStart
	creator := lobbyJson[creatorStart:creatorEnd]

	// Require challenger has joined
	if !pvpLobbies.Has(lobbyId + ":challenger") {
		panic("no opponent has joined yet")
	}
	challenger := pvpLobbies.Get(lobbyId + ":challenger").(string)

	// Require both commits are present
	if !pvpLobbies.Has(lobbyId+":commit:"+creator) || !pvpLobbies.Has(lobbyId+":commit:"+challenger) {
		panic("both players must commit moves before revealing")
	}

	pvpLobbies.Set(lobbyId+":reveal:"+caller, choice+":"+salt)
	pvpLobbies.Set(lobbyId+":status", "revealed")
}

// ClaimPvpTimeout allows a lobby participant to claim a timeout win.
// Only the creator or challenger may call this.
func ClaimPvpTimeout(cur realm, lobbyId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	lobbyJson := pvpLobbies.Get(lobbyId).(string)

	// Extract creator address
	creatorStart := strings.Index(lobbyJson, `"creator":"`) + len(`"creator":"`)
	creatorEnd := strings.Index(lobbyJson[creatorStart:], `"`) + creatorStart
	creator := lobbyJson[creatorStart:creatorEnd]

	// Get challenger (may not exist yet)
	challenger := ""
	if pvpLobbies.Has(lobbyId + ":challenger") {
		challenger = pvpLobbies.Get(lobbyId + ":challenger").(string)
	}

	// Verify caller is a participant
	if caller != creator && caller != challenger {
		panic("not a lobby participant")
	}

	// Require minimum 10 minutes since lobby creation
	createdAtStart := strings.Index(lobbyJson, `"createdAt":`) + len(`"createdAt":`)
	createdAtEnd := strings.IndexAny(lobbyJson[createdAtStart:], `,}`) + createdAtStart
	createdAt, _ := strconv.ParseInt(lobbyJson[createdAtStart:createdAtEnd], 10, 64)
	if time.Now().Unix()-createdAt < 600 {
		panic("timeout not yet claimable — minimum 10 minutes must elapse")
	}

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

	// Require that the caller has actually played (mined at least 1 coin lifetime)
	if !miners.Has(caller) {
		panic("no mining activity — play the game first")
	}
	total, _ := strconv.ParseUint(miners.Get(caller).(string), 10, 64)
	if total == 0 {
		panic("no mining activity — play the game first")
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
	done := now-last < 72000
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
	return ufmt.Sprintf("# GnoMoji Game Realm\n\nAdmin: `%s`\n\nPath: `gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game5`\n\nMine emoji coins on Gno.land!\n", admin.String())
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
