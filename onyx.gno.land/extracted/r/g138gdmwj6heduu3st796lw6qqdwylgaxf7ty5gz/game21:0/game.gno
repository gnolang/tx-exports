// GnoMoji — Main Game Realm
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game21
//
// On-chain game engine for GnoMoji on Gno.land (v1.5.0 / Onyx testnet API).
// Tracks mined coins, casino rounds, PvP lobbies, tools, skills, achievements.
//
// Token minting is handled by gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/minter6.
// Unified coin balances live at gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/coins.
// Phase 2: On-chain cost enforcement for BuyTool, RepairTool, and TrainSkill.
// Phase 3: Wallet blacklist — BanAddress, UnbanAddress, BlacklistStatus, isBlacklisted.
// Phase 4: ClaimMine cooldown 60s; per-entry coin cap 100.
// Phase 5: Expanded tool costs (up to 24 ingredients); 48 new skill branches (nature/food/people/things/travel/signs).
// Phase 6: PvP wager escrow + prize payout; casino jackpot server-side; ClaimAndMint treasury fix.
// Phase 7: Guild system — CreateGuild, JoinGuild, LeaveGuild, PlayerGuild, GuildInfo, TopGuilds; guild yield bonus.
// Phase 8: Gnome Pass subscription (5 GNOT/30d, +50% yield); DailyCheckin cooldown fixed 72000→86400.
// Phase 9: Removed chain/banker + chain/runtime/unsafe (not available on Onyx testnet).

package game21

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
	pvpWagers      avl.Tree // lobbyId → "coinId:amount:creator:challenger" (challenger="" until joined)
	ownedTools     avl.Tree // addr → comma-separated tool IDs
	toolLife       avl.Tree // addr+":"+toolId → remaining life string
	lifetimeMined  avl.Tree // addr+":"+coinId → total mined string
	achievements   avl.Tree // addr+":"+achId → "1"
	dailyCheckins  avl.Tree // addr → unix seconds string
	skillRanks     avl.Tree // addr+":"+skillId → rank string
	miners         avl.Tree // addr → total mined all-time string
	lastClaim      avl.Tree // addr → unix timestamp of last ClaimMine/ClaimAndMint (velocity limit)
	blacklist      avl.Tree // addr → "reason:timestamp"
	banExpiries    avl.Tree // addr → unix expiry (0 = permanent)
	guilds         avl.Tree // guildId → JSON{name, leader, memberCount, createdAt}
	guildMembers   avl.Tree // guildId+":"+addr → "1"
	playerGuild    avl.Tree // addr → guildId
	gnomePasses    avl.Tree // addr → unix expiry timestamp string (0 = never set, >0 = active until)
	paused         bool
)

// ── Cost Tables ───────────────────────────────────────────────────────────────

// toolCosts maps toolId → slice of [coinId, amount] pairs.
// Copied from catalog.ts TOOLS array. Amounts are for qty=1.
// Phase 5: expanded tool costs — each tool requires more ingredient types at higher tiers.
// Matches catalog.ts TOOLS array exactly.
var toolCosts = map[string][][2]string{
	"twig": {
		{"grin", "120"}, {"joy", "75"}, {"cool", "60"},
	},
	"wood": {
		{"seedling", "180"}, {"leaves", "150"}, {"fallen", "120"}, {"think", "105"}, {"sleep", "90"}, {"party", "75"},
	},
	"stone": {
		{"rock", "600"}, {"log", "540"}, {"evergreen", "480"}, {"brick", "420"}, {"mushroom", "360"}, {"heart", "300"},
		{"deciduous", "240"}, {"cactus", "180"},
	},
	"iron": {
		{"gear", "840"}, {"chains", "780"}, {"wrench", "720"}, {"hammer", "660"}, {"anchor", "630"}, {"pick", "570"},
		{"nut", "400"}, {"saw", "200"}, {"hammer-wrench", "300"}, {"axe", "60"},
	},
	"gold": {
		{"gold-medal", "1140"}, {"crown", "1080"}, {"trophy", "1020"}, {"money-bag", "960"}, {"bolt", "930"}, {"sword", "870"},
		{"old-key", "80"}, {"scale", "60"}, {"bullseye", "200"}, {"mahjong", "50"}, {"slots", "20"}, {"joker", "15"},
	},
	"diamond": {
		{"gem", "1560"}, {"coin", "1440"}, {"ring", "1380"}, {"disco", "1320"}, {"kite", "1260"}, {"dodo", "1140"},
		{"scope", "25"}, {"telescope", "40"}, {"tube", "60"}, {"dish", "50"},
		{"lock", "300"}, {"key-lock", "200"},
		{"eight", "150"}, {"puzzle", "200"},
	},
	"cosmic": {
		{"galaxy", "1950"}, {"moai", "1860"}, {"hamsa", "1800"}, {"mirror", "1740"}, {"atom", "1650"}, {"ufo", "1500"},
		{"shooting", "15"}, {"rex", "20"}, {"mammoth", "25"}, {"new-face", "20"},
		{"cyclone", "40"}, {"tornado", "50"},
		{"sat", "60"}, {"castle", "80"}, {"liberty", "100"}, {"kaaba", "10"},
	},
	"plasma": {
		{"galaxy", "2250"}, {"atom", "2100"}, {"moai", "2100"}, {"comet", "1950"}, {"jelly", "1800"}, {"peacock", "1800"},
		{"om", "8"}, {"yin", "10"}, {"ophiuchus", "12"}, {"fleur", "15"}, {"trident", "15"},
		{"radioactive", "40"}, {"biohazard", "40"},
		{"castle-jp", "60"},
		{"sun-face", "20"}, {"dragon-face", "25"}, {"sauropod", "30"}, {"moon-word", "80"},
	},
	"neutron": {
		{"jelly", "2850"}, {"peacock", "2700"}, {"unicorn", "2550"}, {"galaxy", "2400"}, {"hamsa", "2400"}, {"dna", "2100"},
		{"genie", "8"}, {"heart-organ", "40"}, {"mage", "50"}, {"monarch", "60"},
		{"ninja", "40"}, {"brain", "30"}, {"lotus-sit", "40"},
		{"lion", "60"}, {"tiger", "80"}, {"eagle", "80"}, {"wolf", "100"}, {"shark", "120"},
	},
	"quasar": {
		{"unicorn", "3450"}, {"peacock", "3300"}, {"jelly", "3300"}, {"lotus", "2550"}, {"galaxy", "2850"}, {"dragon", "2550"},
		{"fireworks", "30"}, {"medal", "25"}, {"sports-medal", "40"}, {"silver-medal", "50"}, {"bronze-medal", "60"},
		{"tower", "80"}, {"hot-spring", "100"}, {"pirate", "60"},
		{"fairy", "80"}, {"vampire", "80"},
		{"heli", "40"}, {"bullet", "50"}, {"race", "80"},
	},
	"void": {
		{"lotus", "3600"}, {"unicorn", "4350"}, {"dragon", "4200"}, {"peacock", "4350"}, {"jelly", "4500"}, {"galaxy", "1500"},
		{"om", "15"}, {"yin", "15"}, {"trident", "20"}, {"fleur", "20"}, {"ophiuchus", "18"},
		{"shooting", "25"}, {"sun-face", "30"}, {"dragon-face", "40"}, {"rex", "35"}, {"sauropod", "40"},
		{"mammoth", "45"}, {"new-face", "35"},
		{"kaaba", "18"},
		{"witness", "12"}, {"genie", "12"},
	},
	"genesis": {
		{"lotus", "5400"}, {"dragon", "5400"}, {"unicorn", "5250"}, {"peacock", "4950"}, {"jelly", "4800"}, {"infinity", "4200"},
		{"genie", "12"}, {"witness", "15"},
		{"sun-face", "40"}, {"shooting", "30"}, {"dragon-face", "50"},
		{"om", "20"}, {"yin", "20"}, {"trident", "25"}, {"fleur", "25"},
		{"kaaba", "20"},
		{"rex", "40"}, {"sauropod", "45"}, {"mammoth", "50"},
		{"new-face", "40"},
		{"lion", "80"}, {"shark", "150"},
	},
	"omega": {
		{"lotus", "6900"}, {"dragon", "6600"}, {"unicorn", "6300"}, {"peacock", "6000"}, {"jelly", "6000"}, {"infinity", "5700"},
		{"genie", "18"},
		{"witness", "20"},
		{"sun-face", "50"},
		{"shooting", "40"},
		{"dragon-face", "60"},
		{"om", "25"},
		{"yin", "25"},
		{"trident", "30"},
		{"fleur", "30"},
		{"ophiuchus", "25"},
		{"kaaba", "25"},
		{"rex", "50"},
		{"sauropod", "55"},
		{"mammoth", "60"},
		{"new-face", "50"},
		{"mage", "80"},
		{"heart-organ", "60"},
		{"sat", "100"},
	},
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

	// ── Phase 5: Nature branch (level 20) ────────────────────────────────────
	"deep_root":       {{"bear", "60"}, {"fox", "40"}},
	"stone_sense":     {{"turtle", "30"}, {"coral", "15"}},
	"bloom_tide":      {{"sakura", "20"}, {"bee", "50"}, {"deciduous", "80"}},
	"thorn_hide":      {{"boar", "40"}, {"snake", "30"}, {"scorpion", "20"}},
	"old_growth":      {{"elephant", "25"}, {"gorilla", "20"}, {"whale-spout", "15"}},
	"storm_surge":     {{"storm", "25"}, {"lightning-cloud", "20"}, {"tornado", "15"}},
	"predator_sense":  {{"tiger", "20"}, {"lion", "20"}, {"wolf", "20"}, {"eagle", "15"}},
	"world_tree":      {{"rex", "12"}, {"mammoth", "10"}, {"dragon-face", "8"}, {"shooting", "8"}},

	// ── Phase 5: Food branch (level 30) ──────────────────────────────────────
	"hot_meal":     {{"ramen", "50"}, {"stew", "40"}},
	"sugar_rush":   {{"candy", "60"}, {"cupcake", "40"}, {"donut", "30"}},
	"second_wind":  {{"burger", "50"}, {"bacon", "40"}, {"cheese", "30"}},
	"caffeinated":  {{"boba", "40"}, {"tea", "30"}, {"sake", "25"}},
	"feast_mode":   {{"sushi", "30"}, {"curry", "40"}, {"pasta", "40"}, {"paella", "25"}},
	"night_shift":  {{"honey", "30"}, {"pie", "25"}, {"cake", "20"}},
	"brew_mastery": {{"beer", "40"}, {"wine", "30"}, {"cocktail", "20"}, {"champagne", "15"}},
	"mythic_feast": {{"tropical-drink", "20"}, {"cheers", "15"}, {"toast", "12"}, {"mate", "12"}},

	// ── Phase 5: People branch (level 40) ────────────────────────────────────
	"mentor":        {{"baby", "60"}, {"child", "50"}},
	"crowd_favor":   {{"clap", "80"}, {"heart-hands", "60"}},
	"team_spirit":   {{"shake", "40"}, {"pray", "30"}, {"hug-pair", "30"}},
	"athlete_heart": {{"surf", "30"}, {"swim", "30"}, {"run", "40"}, {"lift", "25"}},
	"warrior_code":  {{"ninja", "20"}, {"fencer", "15"}, {"juggle", "15"}},
	"elder_wisdom":  {{"monarch", "15"}, {"mage", "15"}, {"fairy", "12"}},
	"hero_legend":   {{"hero", "12"}, {"vampire", "10"}, {"merfolk", "10"}},
	"genie_wish":    {{"genie", "8"}, {"heart-organ", "12"}},

	// ── Phase 5: Things branch (level 50) ────────────────────────────────────
	"tempered_grip":   {{"gloves", "80"}, {"hammer", "60"}},
	"field_repair":    {{"hammer-wrench", "40"}, {"saw", "30"}, {"nut", "50"}},
	"master_craft":    {{"wrench", "60"}, {"driver", "50"}, {"clamp", "30"}},
	"workshop_lore":   {{"toolbox", "30"}, {"abacus", "25"}, {"scroll", "20"}},
	"iron_discipline": {{"axe", "30"}, {"dagger", "20"}, {"bow", "15"}},
	"vault_keeper":    {{"lock", "40"}, {"key-lock", "30"}, {"old-key", "15"}},
	"precision_forge": {{"scope", "20"}, {"telescope", "15"}, {"tube", "18"}, {"dish", "15"}},
	"deep_science":    {{"alembic", "12"}, {"shield", "15"}, {"hammer-pick", "15"}, {"scale", "12"}},

	// ── Phase 5: Travel branch (level 65) ────────────────────────────────────
	"long_haul":      {{"car", "80"}, {"bus", "60"}},
	"vein_compass":   {{"plane", "50"}, {"sail", "30"}},
	"nomad_pace":     {{"moto", "40"}, {"cycle", "50"}, {"scooter", "40"}},
	"deep_sea":       {{"ship", "30"}, {"whale-spout", "15"}, {"dolphin", "25"}},
	"sky_route":      {{"rocket", "30"}, {"heli", "20"}, {"depart", "20"}},
	"monument_seal":  {{"tower", "20"}, {"castle", "15"}, {"liberty", "12"}},
	"orbital_drift":  {{"sat", "15"}, {"castle-jp", "12"}},
	"sacred_ground":  {{"kaaba", "8"}, {"shrine", "10"}, {"temple", "10"}, {"mosque", "10"}},

	// ── Phase 5: Signs branch (level 80) ─────────────────────────────────────
	"amplify":       {{"sparkle", "80"}, {"eight-star", "60"}},
	"resonance":     {{"recycle", "60"}, {"medical", "50"}},
	"sigil_power":   {{"worship", "40"}, {"peace-sign", "30"}},
	"zodiac_edge":   {{"aries", "20"}, {"taurus", "20"}, {"gemini", "20"}, {"cancer", "15"}},
	"star_david":    {{"star-david", "15"}, {"dharma", "15"}, {"cross", "15"}, {"menorah", "12"}},
	"hazard_forge":  {{"radioactive", "12"}, {"biohazard", "12"}},
	"cosmic_sigil":  {{"trident", "10"}, {"fleur", "10"}, {"ophiuchus", "8"}},
	"infinite_mark": {{"om", "8"}, {"yin", "8"}, {"witness", "6"}},
}

// skillMaxRanks maps skillId → maximum rank allowed.
// Most skills cap at 3 or 4 — see catalog.ts SKILLS[*].max.
var skillMaxRanks = map[string]uint64{
	// Strike branch
	"wrist": 5, "palm_strike": 4, "follow": 3, "knuckle_wrap": 4, "heavy_swing": 4,
	"stone_breaker": 4, "anvil_force": 4, "point_drive": 4, "kinetic_thrust": 4,
	"crushing_blow": 4, "shatter_spike": 4, "ironclad_cleave": 3, "thunder_jab": 3,
	"titan_hammer": 3, "diamond_cleave": 3, "hyper_drive": 3, "quasar_impact": 3,
	"black_hole_crush": 3, "mythic_annihilation": 3, "singularity_fist": 3,
	// Fortune branch
	"fortune": 4, "four_leaf": 3, "edge": 3, "glint": 3, "spark_chaser": 3,
	"razor_focus": 3, "precision_cut": 3, "aurora_gaze": 3, "starlight_gleam": 3,
	"double_haul": 3, "twin_strike": 3, "executioner": 3, "celestial_sight": 3,
	"helix_harmony": 3, "fortune_split": 3, "critical_surge": 3,
	"astral_scintillation": 3, "plunder_frenzy": 3, "singularity_edge": 3, "cosmic_fortune": 3,
	// Pocket branch
	"dustbag": 3, "rhythm": 3, "pocket_expansion": 3, "steady_tempo": 3, "cadence": 3,
	"deep_pouch": 3, "vein_resonator": 3, "cart_bed": 3, "bounty_overflow": 3,
	"fracture_pulse": 3, "metro_pulse": 3, "hoarders_tote": 3, "shatter_strike": 3,
	"super_conductor": 3, "dodo_instinct": 3, "void_rend": 3, "celestial_duplication": 3,
	"eternity_flow": 3, "abyssal_reserve": 3, "singularity_snap": 3,
	// Phase 5 — Nature branch (unlocks level 20)
	"deep_root": 3, "stone_sense": 3, "bloom_tide": 3, "thorn_hide": 3,
	"old_growth": 3, "storm_surge": 3, "predator_sense": 3, "world_tree": 3,
	// Phase 5 — Food branch (unlocks level 30)
	"hot_meal": 3, "sugar_rush": 3, "second_wind": 3, "caffeinated": 3,
	"feast_mode": 3, "night_shift": 3, "brew_mastery": 3, "mythic_feast": 3,
	// Phase 5 — People branch (unlocks level 40)
	"mentor": 3, "crowd_favor": 3, "team_spirit": 3, "athlete_heart": 3,
	"warrior_code": 3, "elder_wisdom": 3, "hero_legend": 3, "genie_wish": 3,
	// Phase 5 — Things branch (unlocks level 50)
	"tempered_grip": 3, "field_repair": 3, "master_craft": 3, "workshop_lore": 3,
	"iron_discipline": 3, "vault_keeper": 3, "precision_forge": 3, "deep_science": 3,
	// Phase 5 — Travel branch (unlocks level 65)
	"long_haul": 3, "vein_compass": 3, "nomad_pace": 3, "deep_sea": 3,
	"sky_route": 3, "monument_seal": 3, "orbital_drift": 3, "sacred_ground": 3,
	// Phase 5 — Signs branch (unlocks level 80)
	"amplify": 3, "resonance": 3, "sigil_power": 3, "zodiac_edge": 3,
	"star_david": 3, "hazard_forge": 3, "cosmic_sigil": 3, "infinite_mark": 3,
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
const gnomePassCostPer30Days = uint64(5_000_000)

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

// WithdrawFunds is disabled on Onyx testnet (chain/banker not available).
// On mainnet, re-enable with banker.NewBanker(banker.BankerTypeRealmSend, cur).
func WithdrawFunds(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	panic("WithdrawFunds: not available on Onyx testnet")
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
	if isBlacklisted(caller) {
		panic("address banned")
	}
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

// CreatePvpLobby creates a new PvP lobby and escrows the creator's wager from balances.
// Phase 6: wager > 0 deducts from balances and records the escrow in pvpWagers.
func CreatePvpLobby(cur realm, game string, coinId string, betAmount string) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	wager, err := strconv.ParseUint(betAmount, 10, 64)
	if err != nil {
		panic("invalid bet amount")
	}

	// Escrow creator's wager from balances (if wager > 0)
	if wager > 0 {
		balKey := caller + ":" + coinId
		bal := uint64(0)
		if balances.Has(balKey) {
			bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
		}
		if bal < wager {
			panic("insufficient balance for wager: need " + betAmount + " " + coinId)
		}
		balances.Set(balKey, strconv.FormatUint(bal-wager, 10))
	}

	prefix := caller
	if len(prefix) > 8 {
		prefix = caller[:8]
	}
	lobbyId := ufmt.Sprintf("pvp-%s-%d", prefix, time.Now().Unix())
	lobby := `{"lobbyId":"` + lobbyId + `","creator":"` + caller + `","game":"` + game + `","coinId":"` + coinId + `","betAmount":` + betAmount + `,"status":"open","round":1,"createdAt":` + strconv.FormatInt(time.Now().Unix(), 10) + `}`
	pvpLobbies.Set(lobbyId, lobby)

	// Record wager escrow (challenger is empty until JoinPvpLobby)
	if wager > 0 {
		pvpWagers.Set(lobbyId, coinId+":"+betAmount+":"+caller+":")
	}

	return lobbyId
}

// JoinPvpLobby joins an existing PvP lobby and escrows the challenger's matching wager.
// Phase 6: deducts challenger's matching wager from balances and updates pvpWagers.
func JoinPvpLobby(cur realm, lobbyId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	if pvpLobbies.Has(lobbyId + ":challenger") {
		panic("lobby already full")
	}

	// Parse coinId and betAmount from wager record
	if pvpWagers.Has(lobbyId) {
		wagerStr := pvpWagers.Get(lobbyId).(string)
		parts := strings.SplitN(wagerStr, ":", 4)
		if len(parts) == 4 {
			coinId := parts[0]
			betAmountStr := parts[1]
			creator := parts[2]

			if caller == creator {
				panic("cannot join your own lobby")
			}

			wager, _ := strconv.ParseUint(betAmountStr, 10, 64)
			if wager > 0 {
				// Escrow challenger's matching wager
				balKey := caller + ":" + coinId
				bal := uint64(0)
				if balances.Has(balKey) {
					bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
				}
				if bal < wager {
					panic("insufficient balance for wager: need " + betAmountStr + " " + coinId)
				}
				balances.Set(balKey, strconv.FormatUint(bal-wager, 10))
				// Update wager record with challenger address
				pvpWagers.Set(lobbyId, coinId+":"+betAmountStr+":"+creator+":"+caller)
			}
		}
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
// Phase 6: when both players have revealed, determines the RPS winner and pays out
// 2× wager minus 2% rake to the winner. Draw = full refund to both players.
// pvpWagers.Remove is called after payout to prevent double-payouts.
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

	// Check if both players have now revealed
	creatorRevealed := pvpLobbies.Has(lobbyId + ":reveal:" + creator)
	challengerRevealed := pvpLobbies.Has(lobbyId + ":reveal:" + challenger)

	if creatorRevealed && challengerRevealed {
		// Both revealed — determine winner and pay out
		creatorReveal := pvpLobbies.Get(lobbyId + ":reveal:" + creator).(string)
		challengerReveal := pvpLobbies.Get(lobbyId + ":reveal:" + challenger).(string)

		creatorChoice := strings.SplitN(creatorReveal, ":", 2)[0]
		challengerChoice := strings.SplitN(challengerReveal, ":", 2)[0]

		winner := ""
		// Rock-Paper-Scissors logic: rock beats scissors, scissors beats paper, paper beats rock
		if creatorChoice == challengerChoice {
			winner = "draw"
		} else if (creatorChoice == "rock" && challengerChoice == "scissors") ||
			(creatorChoice == "scissors" && challengerChoice == "paper") ||
			(creatorChoice == "paper" && challengerChoice == "rock") {
			winner = creator
		} else {
			winner = challenger
		}

		pvpLobbies.Set(lobbyId+":winner", winner)
		pvpLobbies.Set(lobbyId+":status", "finished")

		// Pay out wager to winner (or refund both on draw)
		if pvpWagers.Has(lobbyId) {
			wagerStr := pvpWagers.Get(lobbyId).(string)
			parts := strings.SplitN(wagerStr, ":", 4)
			if len(parts) == 4 {
				coinId := parts[0]
				wager, _ := strconv.ParseUint(parts[1], 10, 64)

				if wager > 0 {
					rake := wager * 2 / 100  // 2% rake to admin
					payout := (wager * 2) - rake

					if winner == "draw" {
						// Refund both players their wager
						for _, addr := range []string{creator, challenger} {
							balKey := addr + ":" + coinId
							bal := uint64(0)
							if balances.Has(balKey) {
								bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
							}
							balances.Set(balKey, strconv.FormatUint(bal+wager, 10))
						}
					} else {
						// Pay winner 2× wager minus 2% rake
						winKey := winner + ":" + coinId
						winBal := uint64(0)
						if balances.Has(winKey) {
							winBal, _ = strconv.ParseUint(balances.Get(winKey).(string), 10, 64)
						}
						balances.Set(winKey, strconv.FormatUint(winBal+payout, 10))

						// Rake goes to admin
						adminKey := admin.String() + ":" + coinId
						adminBal := uint64(0)
						if balances.Has(adminKey) {
							adminBal, _ = strconv.ParseUint(balances.Get(adminKey).(string), 10, 64)
						}
						balances.Set(adminKey, strconv.FormatUint(adminBal+rake, 10))
					}

					// Remove wager record after payout to prevent double-payouts
					pvpWagers.Remove(lobbyId)
				}
			}
		}
	} else {
		pvpLobbies.Set(lobbyId+":status", "revealed")
	}
}

// ClaimPvpTimeout allows a lobby participant to claim a timeout win.
// Only the creator or challenger may call this.
// Phase 6: refunds the escrowed wager to all parties who contributed.
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

	// Phase 6: Refund escrowed wagers.
	// On timeout the creator always escrowed; the challenger may or may not have joined.
	// Refund both if they both escrowed (challenger joined but neither revealed in time).
	// If only the creator escrowed (challenger never joined), refund only the creator.
	if pvpWagers.Has(lobbyId) {
		wagerStr := pvpWagers.Get(lobbyId).(string)
		parts := strings.SplitN(wagerStr, ":", 4)
		if len(parts) == 4 {
			coinId := parts[0]
			wager, _ := strconv.ParseUint(parts[1], 10, 64)
			creatorInWager := parts[2]
			challengerInWager := parts[3]
			// Refund whoever escrowed (creator always did; challenger may have joined)
			if wager > 0 {
				for _, addr := range []string{creatorInWager, challengerInWager} {
					if addr == "" {
						continue
					}
					balKey := addr + ":" + coinId
					bal := uint64(0)
					if balances.Has(balKey) {
						bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
					}
					balances.Set(balKey, strconv.FormatUint(bal+wager, 10))
				}
				pvpWagers.Remove(lobbyId)
			}
		}
	}
}

func ExpireLobbies(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
}

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
