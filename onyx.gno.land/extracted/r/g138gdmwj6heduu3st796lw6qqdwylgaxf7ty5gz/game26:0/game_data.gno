// GnoMoji — Main Game Realm
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game26
//
// On-chain game engine for GnoMoji on Gno.land (v1.5.0 / Onyx testnet API).

package game26

import (
	"gno.land/p/nt/avl/v0"
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
