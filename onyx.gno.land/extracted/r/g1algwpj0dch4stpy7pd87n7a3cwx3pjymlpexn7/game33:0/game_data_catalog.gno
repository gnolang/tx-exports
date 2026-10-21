package game33

// ── Claim-rate skill headroom factors (game29 caps, §5 of REPORT.md) ─────────
// When on-chain skillRanks are available these are computed from actual ranks.
// Until then we use fixed conservative headroom = client-side cap maximums.
// The effective rate for rarity r = base_rate[r] × skillHeadroom[r].
const (
	// dust: +4 yield cap, double drop and hardening -> sim max 1.70x of the 1.01 cap; 1.75 gives margin.
	skillDustHeadroom = uint64(175) // ×175/100

	// Maximum damage multiplier: ≤ 2× → twice as many blocks per minute.
	skillDmgHeadroom = uint64(200) // ×200/100

	// Maximum drop-rate bonus: +30% → 1.30×.
	skillDropHeadroom = uint64(130) // ×130/100
)

// toolLifeSkillIds lists the on-chain skills that grant toolLifeBonus.
// Covers the Things branch (level 50) and the Nature-branch skills that also
// affect tool wear. Must stay in sync with catalog.ts SKILLS[*].toolLifeBonus.
var toolLifeSkillIds = []string{
	"tempered_grip",   // +10%/rank   (Things)
	"stone_sense",     // +0.5%/rank  (Nature)
	"master_craft",    // +15%/rank   (Things)
	"thorn_hide",      // +1%/rank    (Nature)
	"storm_surge",     // +1.5%/rank  (Nature)
	"workshop_lore",   // +15%/rank   (Things)
	"iron_discipline", // +20%/rank   (Things)
	"vault_keeper",    // +20%/rank   (Things)
	"precision_forge", // +25%/rank   (Things)
	"field_repair",    // +10%/rank   (Things)
	"deep_science",    // +25%/rank   (Things)
}

// toolLifeSkillBonus maps each skill to its per-rank life bonus fraction × 1000.
// e.g. "tempered_grip" → 100 means +10.0% per rank (100/1000 = 0.10).
var toolLifeSkillBonus = map[string]uint64{
	"tempered_grip":   100, // +10%/rank
	"stone_sense":       5, // +0.5%/rank
	"master_craft":    150, // +15%/rank
	"thorn_hide":       10, // +1%/rank
	"storm_surge":      15, // +1.5%/rank
	"workshop_lore":   150, // +15%/rank
	"iron_discipline": 200, // +20%/rank
	"vault_keeper":    200, // +20%/rank
	"precision_forge": 250, // +25%/rank
	"field_repair":    100, // +10%/rank
	"deep_science":    250, // +25%/rank
}

// ── Claim rate cap tables (REPORT.md §5) ─────────────────────────────────────
// claimBucketSecs: how many seconds of allowance the bucket can bank (1 hour).
const claimBucketSecs = int64(3600)

// claimRatePerMin[toolId][rarity] = max coins/min of that rarity the caller may
// claim (before skill headroom). Indexed 0=dust..6=mythic.
var claimRatePerMin = map[string][7]uint64{
	"hands":        {12, 0, 0, 0, 0, 0, 0},
	"starter-twig": {16, 0, 0, 0, 0, 0, 0},
	"twig":         {23, 0, 0, 0, 0, 0, 0},
	"wood":         {32, 9, 0, 0, 0, 0, 0},
	"stone":        {69, 20, 6, 0, 0, 0, 0},
	"iron":         {184, 55, 15, 5, 0, 0, 0},
	"gold":         {422, 140, 40, 13, 4, 0, 0},
	"diamond":      {783, 333, 112, 36, 12, 3, 0},
	"cosmic":       {1406, 658, 296, 110, 36, 8, 2},
	"plasma":       {1422, 919, 393, 171, 59, 13, 4},
	"neutron":      {1449, 1207, 513, 263, 94, 22, 7},
	"quasar":       {1476, 1233, 654, 385, 147, 34, 10},
	"void":         {1503, 1255, 853, 489, 220, 55, 16},
	"genesis":      {1544, 1289, 1083, 610, 341, 90, 26},
	"omega":        {1598, 1334, 1124, 769, 516, 145, 42},
}

// ── Vein caps (game29) ───────────────────────────────────────────────────────
// Every coin in coinRarity has a vein from deploy: its max is the default for
// its rarity unless the admin overrides it. No per-coin init writes needed.
// Defaults: ≈1 year of demand per core coin × 1.5 headroom (see REPORT §6).
var veinDefaultMax = [7]uint64{
	50000000, // r0 dust
	82000000, // r1 common
	25000000, // r2 uncommon
	25000000, // r3 rare
	20000000, // r4 epic
	25000000, // r5 legendary
	85000000, // r6 mythic
}

// Per-coin default overrides (static: no deploy-time writes).
var veinCoinDefault = map[string]uint64{
	"grin": 102000000,
}

// ── Achievement allowlist (game29) ───────────────────────────────────────────
// Static ids with FIXED rewards. Grind ids "g.<coin>.<need>" are valid for any
// allowlisted coin and need ∈ grindRungs. The client can never choose a reward.
type coinAmt struct {
	coin string
	amt  uint64
}

var achievementRewards = map[string][]coinAmt{
	"ad_1":         {{"grin", 10}},
	"ad_5":         {{"coffee", 6}},
	"blocks_1":     {{"grin", 4}},
	"blocks_10":    {{"seedling", 6}},
	"blocks_25k":   {{"pick", 2}},
	"blocks_50":    {{"seedling", 12}},
	"blocks_500":   {{"log", 6}, {"rock", 10}},
	"blocks_5k":    {{"gear", 4}},
	"combo_12":     {{"grin", 12}},
	"cosmic_own":   {{"moon", 4}},
	"diamond_own":  {{"spark", 8}},
	"dj":           {{"music", 6}},
	"era_1":        {{"bolt", 3}},
	"first-clash":  {{"rock", 10}},
	"first_tap":    {{"grin", 8}},
	"gem":          {{"spark", 6}},
	"genesis_own":  {{"dragon", 1}},
	"gold_own":     {{"pick", 3}},
	"iron_own":     {{"gold-medal", 2}},
	"miner-1":      {{"seedling", 10}},
	"mythic":       {{"galaxy", 1}},
	"neutron_own":  {{"dna", 2}},
	"omega_own":    {{"lotus", 1}},
	"pioneer":      {{"grin", 50}},
	"plasma_own":   {{"bolt", 3}},
	"quasar_own":   {{"comet", 2}},
	"rarity_0":     {{"grin", 6}},
	"rarity_1":     {{"seedling", 6}},
	"rarity_2":     {{"rock", 5}},
	"rarity_3":     {{"fire", 4}},
	"rarity_4":     {{"spark", 6}},
	"rarity_5":     {{"star", 2}},
	"send":         {{"heart", 4}},
	"shiny":        {{"spark", 6}},
	"slot-roller":  {{"gold-medal", 1}},
	"starter-twig": {{"grin", 20}},
	"stone_own":    {{"gear", 4}},
	"swap":         {{"up", 6}},
	"twig_own":     {{"grin", 50}},
	"unique_1":     {{"grin", 40}},
	"unique_10":    {{"fire", 20}},
	"unique_100":   {{"lotus", 3}, {"peacock", 2}},
	"unique_15":    {{"rock", 24}},
	"unique_25":    {{"clover", 12}},
	"unique_3":     {{"seedling", 24}},
	"unique_40":    {{"pizza", 16}},
	"unique_5":     {{"leaves", 24}},
	"unique_50":    {{"star", 10}},
	"unique_60":    {{"bolt", 10}},
	"unique_75":    {{"crown", 6}},
	"unique_80":    {{"gem", 4}},
	"unique_85":    {{"planet", 3}},
	"unique_90":    {{"galaxy", 2}},
	"unique_95":    {{"lotus", 2}},
	"unique_99":    {{"unicorn", 2}},
	"void_own":     {{"new-moon", 4}},
	"wood_own":     {{"rock", 8}},
}

var grindRungs = []uint64{10, 100, 1000, 10000, 100000}

func grindPay(need uint64) uint64 {
	switch {
	case need >= 100000:
		return 480
	case need >= 10000:
		return 140
	case need >= 1000:
		return 56
	case need >= 100:
		return 20
	}
	return 10
}

// ── PvP / casino allowlists ──────────────────────────────────────────────────
var pvpGames = map[string][]string{
	"rps":          {"rock", "paper", "scissors"},
	"coin_flip":    {"heads", "tails"},
	"higher_lower": {"higher", "lower"},
}

const (
	pvpTimeoutSec        = int64(600) // AFK window before ClaimPvpTimeout
	pvpRakePct           = uint64(2)  // to admin balance
	voucherMaxTTL        = int64(900) // vouchers must expire within 15 min
	claimCooldownSec     = int64(60)  // min seconds between ClaimAndMint
	claimInitialGraceSec = int64(300) // a new rarity bucket starts with 5 min of allowance
)
