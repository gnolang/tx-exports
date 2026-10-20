// GnoMoji — Main Game Realm (game32)
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game32
//
// game29 closes the game28 audit holes (see SECURITY_GAME28.md):
//   - claims and achievements need an ed25519 voucher from the server's claim
//     signer (a dedicated key, never the treasury), with per-player nonces;
//   - per-rarity rate caps still apply on chain, plus per-coin vein caps;
//   - the Gnome Pass costs real ugnot (OriginSend), withdrawable by admin;
//   - PvP commit/reveal is hash-checked, casino bets settle on chain;
//   - player state can be imported once from game27/game28, then locked.

package game32

import (
	"gno.land/p/nt/avl/v0"
)

const realmPkgPath = "gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/game32"

// ── State ────────────────────────────────────────────────────────────────────

var (
	admin    address // deployer; can set roles, prices, veins, migrate, withdraw
	operator address // server hot account for casino seeds (defaults to admin)

	// claimSignerPubKey is the ed25519 public key (32 bytes) whose signatures
	// authorise ClaimAndMint / achievement vouchers. Empty = claims disabled.
	claimSignerPubKey []byte
	claimNonces       avl.Tree // addr → last used voucher nonce (decimal string)

	balances      avl.Tree // addr+":"+coinId → amount string
	claimBuckets  avl.Tree // addr → "m0:t0|m1:t1|m2:t2|m3:t3|m4:t4|m5:t5|m6:t6" (packed; lazy-migrated from old addr:r keys)
	veinMinted    avl.Tree // coinId → total ever credited by claims/rewards/migration
	veinMaxOverride avl.Tree // coinId → admin-set max (overrides the rarity default)
	veinOverrideActive bool   // true once any SetVeinMax has been called; gates the veinMaxOverride AVL read
	casinoRounds  avl.Tree // roundId → *casinoRound
	pvpLobbies    avl.Tree // lobbyId and lobbyId+":field" → string (see game_pvp.gno)
	pvpWagers     avl.Tree // lobbyId → "coinId:amount:creator:challenger"
	ownedTools    avl.Tree // addr → comma-separated tool IDs
	toolLife      avl.Tree // addr+":"+toolId → remaining life string
	lifetimeMined avl.Tree // addr+":"+coinId → total mined string (real claims only)
	rewarded      avl.Tree // addr+":"+coinId → total credited by rewards (medals etc.)
	achievements  avl.Tree // addr+":"+achId → "1"
	dailyCheckins avl.Tree // addr → unix seconds string
	skillRanks    avl.Tree // addr+":"+skillId → rank string
	miners        avl.Tree // addr → total mined all-time string
	playerXp      avl.Tree // addr → cumulative rarity-weighted XP (uint64 string)
	lastClaim     avl.Tree // addr → unix timestamp of last ClaimAndMint
	blacklist     avl.Tree // addr → "reason:timestamp"
	banExpiries   avl.Tree // addr → unix expiry (0 = permanent)
	guilds        avl.Tree // guildId → JSON{name, leader, memberCount, createdAt}
	guildMembers  avl.Tree // guildId+":"+addr → "1"
	playerGuild   avl.Tree // addr → guildId
	gnomePasses   avl.Tree // addr → unix expiry timestamp string

	paused bool

	// Gnome Pass price in ugnot per 30 days (admin-settable).
	passPriceUgnot = int64(5000000)
	passRevenueUgnot int64 // lifetime ugnot received for passes (accounting only)

	pvpCounter   uint64 // monotonically increasing lobby number
	guildCounter uint64 // monotonically increasing guild number

	// Relay (game32): treasury wallet address authorised to call RelayBuyTool
	// and RelayTrainSkill on behalf of players (gasless tool purchases).
	// Set by SetRelayAddress (admin only). Zero value = relay disabled.
	relayAddress address
	// relayNonces tracks per-player relay nonces (shared sequence across all
	// relay kinds) to prevent replay attacks on gasless calls.
	relayNonces avl.Tree // addr → last nonce (decimal string)

	// Migration (game31 → game32). Batches are idempotent (set semantics +
	// batch registry); FinalizeMigration locks imports forever.
	// migrationAddrs tracks every unique player address imported via
	// MigrateBatch so MigrationStatus can report migrated-address count.
	migrationFinalized bool
	migrationBatches   avl.Tree // batchId → "kind:count"
	migrationAddrs     avl.Tree // addr → "1" (deduplicates across batch re-runs)
)

// ── Tool Tables (game29) ──────────────────────────────────────────────────────
// One ID scheme shared with src/lib/game/catalog.ts. Every ingredient is
// mineable by the previous tool (rarity ≤ prev maxRarity). Repair = ceil(30%
// of cost). See REPORT.md §4 for the full progression table and §5 for the
// claim-rate cap table.

// toolOrder is the canonical upgrade path from hands to omega.
var toolOrder = []string{
	"hands", "starter-twig", "twig", "wood", "stone", "iron", "gold",
	"diamond", "cosmic", "plasma", "neutron", "quasar", "void", "genesis", "omega",
}

// toolRequires: BuyTool must panic unless the caller owns the prerequisite tool.
var toolRequires = map[string]string{
	"starter-twig": "hands",
	"twig":         "starter-twig",
	"wood":         "twig",
	"stone":        "wood",
	"iron":         "stone",
	"gold":         "iron",
	"diamond":      "gold",
	"cosmic":       "diamond",
	"plasma":       "cosmic",
	"neutron":      "plasma",
	"quasar":       "neutron",
	"void":         "quasar",
	"genesis":      "void",
	"omega":        "genesis",
}

// toolMaxRarity: highest coin rarity each tool can mine (used by the claim rate cap).
var toolMaxRarity = map[string]int{
	"hands":        0,
	"starter-twig": 0,
	"twig":         0,
	"wood":         1,
	"stone":        2,
	"iron":         3,
	"gold":         4,
	"diamond":      5,
	"cosmic":       6,
	"plasma":       6,
	"neutron":      6,
	"quasar":       6,
	"void":         6,
	"genesis":      6,
	"omega":        6,
}

// toolCosts maps toolId → slice of [coinId, amount] pairs.
// Matches catalog.ts TOOLS array exactly. Amounts are for qty=1.
var toolCosts = map[string][][2]string{
	"starter-twig": {
		{"grin", "13"},
	},
	"twig": {
		{"grin", "14"}, {"joy", "9"}, {"cool", "7"},
	},
	"wood": {
		{"seedling", "19"}, {"leaves", "16"}, {"fallen", "13"}, {"think", "11"}, {"sleep", "10"}, {"party", "8"},
	},
	"stone": {
		{"rock", "50"}, {"log", "45"}, {"evergreen", "40"}, {"brick", "35"}, {"mushroom", "30"}, {"heart", "25"},
		{"deciduous", "20"}, {"cactus", "15"},
	},
	"iron": {
		{"gear", "42"}, {"chains", "42"}, {"wrench", "38"}, {"hammer", "34"}, {"anchor", "34"}, {"pick", "29"},
		{"nut", "21"}, {"saw", "8"}, {"hammer-wrench", "17"}, {"magnet", "4"},
	},
	"gold": {
		{"gold-medal", "150"}, {"crown", "140"}, {"trophy", "130"}, {"money-bag", "120"}, {"bolt", "120"}, {"sword", "110"},
		{"dagger", "10"}, {"bow", "10"}, {"bullseye", "30"}, {"mahjong", "10"}, {"hanafuda", "10"}, {"fireworks", "10"},
	},
	"diamond": {
		{"gem", "220"}, {"coin", "200"}, {"ring", "190"}, {"disco", "180"}, {"kite", "180"}, {"dodo", "160"},
		{"scope", "10"}, {"xray", "10"}, {"tube", "10"}, {"dish", "10"}, {"lock", "40"}, {"key-lock", "30"},
		{"eight", "20"}, {"puzzle", "30"},
	},
	"cosmic": {
		{"galaxy", "336"}, {"moai", "320"}, {"hamsa", "320"}, {"mirror", "304"}, {"atom", "288"}, {"ufo", "256"},
		{"whale-spout", "16"}, {"whale", "16"}, {"sun", "16"}, {"radioactive", "16"}, {"cyclone", "16"}, {"tornado", "16"},
		{"sat", "16"}, {"castle", "16"}, {"liberty", "16"}, {"castle-jp", "16"},
	},
	"plasma": {
		{"galaxy", "1003"}, {"atom", "935"}, {"moai", "935"}, {"comet", "867"}, {"jelly", "799"}, {"peacock", "799"},
		{"om", "17"}, {"yin", "17"}, {"ophiuchus", "17"}, {"fleur", "17"}, {"trident", "17"}, {"radioactive", "17"},
		{"biohazard", "17"}, {"castle-jp", "34"}, {"sun-face", "17"}, {"dragon-face", "17"}, {"sauropod", "17"}, {"moon-word", "34"},
	},
	"neutron": {
		{"jelly", "2040"}, {"peacock", "1870"}, {"unicorn", "1870"}, {"galaxy", "1700"}, {"hamsa", "1700"}, {"dna", "1496"},
		{"genie", "17"}, {"heart-organ", "34"}, {"mage", "34"}, {"monarch", "51"}, {"ninja", "34"}, {"brain", "17"},
		{"lotus-sit", "34"}, {"lion", "51"}, {"tiger", "51"}, {"eagle", "51"}, {"wolf", "68"}, {"shark", "85"},
	},
	"quasar": {
		{"unicorn", "4590"}, {"peacock", "4590"}, {"jelly", "4590"}, {"lotus", "3510"}, {"galaxy", "3780"}, {"dragon", "3510"},
		{"fireworks", "54"}, {"medal", "27"}, {"sports-medal", "54"}, {"silver-medal", "81"}, {"bronze-medal", "81"}, {"tower", "108"},
		{"hot-spring", "135"}, {"pirate", "81"}, {"fairy", "108"}, {"vampire", "108"}, {"heli", "54"}, {"bullet", "81"},
		{"race", "108"},
	},
	"void": {
		{"lotus", "8990"}, {"unicorn", "10850"}, {"dragon", "10540"}, {"peacock", "10850"}, {"jelly", "11470"}, {"galaxy", "3720"},
		{"om", "31"}, {"yin", "31"}, {"trident", "62"}, {"fleur", "62"}, {"ophiuchus", "31"}, {"shooting", "62"},
		{"sun-face", "62"}, {"dragon-face", "93"}, {"rex", "93"}, {"sauropod", "93"}, {"mammoth", "124"}, {"new-face", "93"},
		{"kaaba", "31"}, {"witness", "31"}, {"genie", "31"},
	},
	"genesis": {
		{"lotus", "18000"}, {"dragon", "18000"}, {"unicorn", "17520"}, {"peacock", "16560"}, {"jelly", "16080"}, {"infinity", "14160"},
		{"genie", "48"}, {"witness", "48"}, {"sun-face", "144"}, {"shooting", "96"}, {"dragon-face", "168"}, {"om", "72"},
		{"yin", "72"}, {"trident", "72"}, {"fleur", "72"}, {"kaaba", "72"}, {"rex", "144"}, {"sauropod", "144"},
		{"mammoth", "168"}, {"new-face", "144"}, {"lion", "264"}, {"shark", "504"},
	},
	"omega": {
		{"lotus", "26970"}, {"dragon", "25110"}, {"unicorn", "24180"}, {"peacock", "23250"}, {"jelly", "23250"}, {"infinity", "22320"},
		{"genie", "65"}, {"witness", "74"}, {"sun-face", "195"}, {"shooting", "158"}, {"dragon-face", "233"}, {"om", "93"},
		{"yin", "93"}, {"trident", "112"}, {"fleur", "112"}, {"ophiuchus", "93"}, {"kaaba", "93"}, {"rex", "195"},
		{"sauropod", "214"}, {"mammoth", "233"}, {"new-face", "195"}, {"mage", "307"}, {"heart-organ", "233"}, {"sat", "381"},
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

// toolMaxLife maps toolId → maximum durability in blocks broken.
// 0 = indestructible (hands, starter-twig, twig). Matches catalog.ts tool.life.
var toolMaxLife = map[string]uint64{
	"hands": 0, "starter-twig": 0, "twig": 0,
	"wood": 300, "stone": 900, "iron": 940, "gold": 4900, "diamond": 5300, "cosmic": 4500,
	"plasma": 15000, "neutron": 15000, "quasar": 23000, "void": 30000, "genesis": 36000, "omega": 54000,
}

// ── Coin allowlist and rarity lookup ─────────────────────────────────────────
// coinRarity maps every valid coin id → its rarity (0=dust .. 6=mythic).
// ClaimMine and ClaimAndMint panic on any id not present here.
// Generated from src/lib/game/catalog.ts COINS (1262 entries).
// Populated across two init() functions in game_data_coins.gno and game_data_coins2.gno
// to keep each file under the 594-line Onyx parser limit.

var coinRarity map[string]int
