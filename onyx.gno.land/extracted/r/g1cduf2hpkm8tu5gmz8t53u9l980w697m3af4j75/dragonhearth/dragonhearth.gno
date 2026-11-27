// Dragonhearth — a dragon-progression game realm for the Gnome Tavern hackathon.
//
// Loop: hatch a free soulbound dragon, train + feed it daily, win wild dragons
// on adventure, evolve with adventure shards, merge duplicates up a rarity.
// Dragons are canonical GRC721 tokens (gno.land/p/nt/grc721/v0); the starter
// is soulbound, wild dragons are tradeable. Food, shards and gear are realm
// balances, not tokens. No true randomness: every roll derives from block
// height + caller address. All cooldowns and daily limits use block height
// (1 day = 17280 blocks).
package dragonhearth

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const (
	maxLevel            = 30
	maxDragonsPerWallet = 5
	blocksPerDay        = 17280
	trainCooldown       = 50 // blocks between trains of the same dragon
	maxTrainsPerDay     = 3
	maxDuelsPerDay      = 3
	maxAdventuresPerDay = 3
)

var (
	rarityNames = []string{"Hatchling", "Drake", "Wyrm", "Ancient", "Mythic"}
	// Per-stat cap per rarity.
	rarityCaps = []int64{50, 70, 90, 110, 130}
	// Power multiplier per rarity, x100 (1.00, 1.10, 1.25, 1.45, 1.70).
	rarityMult = []int64{100, 110, 125, 145, 170}
	// Evolve cost to reach rarity r+1 (index = current rarity).
	evolveLevels = []int64{5, 10, 15, 20}
	evolveCosts  = []int64{5, 8, 12, 10}
	evolveShards = []string{"Ember", "Frost", "Storm", "Mystery"}
	elements     = []string{"Ember", "Frost", "Storm", "Stone"}
	traits       = []string{"Brave", "Swift", "Hardy", "Stubborn"}
)

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// Dragon is one dragon. Stored by value in the dragons tree; always
// saveDragon after mutating a local copy.
type Dragon struct {
	ID              int64
	Owner           address
	Name            string
	Element         string
	Trait           string
	Rarity          int64 // 0 Hatchling .. 4 Mythic
	Soulbound       bool
	Power           int64
	Speed           int64
	Vitality        int64
	Level           int64
	XP              int64
	Hunger          int64 // 0..100, -10 per action, +30 per feed
	Growth          int64
	FeedCount       int64
	Bond            int64 // bond level: +1 per 7-day feed streak
	Streak          int64 // consecutive days fed
	LastFeedDay     int64
	LastTrainHeight int64
	TrainDay        int64
	TrainsToday     int64
}

// Wallet is one player's inventory and daily counters.
type Wallet struct {
	Food          int64
	Ember         int64 // Ember shards
	Frost         int64 // Frost shards
	Storm         int64 // Storm shards
	Mystery       int64 // Mystery shards
	Blades        int64 // Ember Blade gear
	Shields       int64 // Frost Shield gear
	Charms        int64 // Swift Charm gear
	HasStarter    bool
	LastForageDay int64
	DuelDay       int64
	DuelsToday    int64
	DuelWins      int64
	AdvDay        int64
	AdvsToday     int64
	ArmedItem     string // "", "Ember Blade", "Frost Shield", "Swift Charm"
	ArmedDragon   int64
}

var (
	// Token is the canonical GRC721 collection; ledger is its private ledger.
	// Only this realm holds the ledger, so only this realm can mint/burn.
	Token  *grc721.Token
	ledger *grc721.PrivateLedger

	dragons      avl.Tree // dragonID (decimal string) -> Dragon
	wallets      avl.Tree // owner address string -> Wallet
	nextDragonID int64
)

func init(cur realm) {
	Token, ledger = grc721.NewToken("Dragonhearth", "DRGN", 0, cur)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// dayNow is the current in-game day, derived from block height.
func dayNow() int64 {
	return runtime.ChainHeight() / blocksPerDay
}

// seedFrom mixes a caller address with a salt into a small positive seed.
// All "randomness" in this realm derives from block height + caller address.
func seedFrom(addr address, salt int64) int64 {
	s := int64(0)
	str := addr.String()
	for i := 0; i < len(str); i++ {
		s = (s*31 + int64(str[i])) % 1000003
	}
	s = (s + salt*7919) % 1000003
	if s < 0 {
		s = -s
	}
	return s
}

// roll returns a deterministic pseudo-random number in [0, n).
func roll(seed int64, n int64) int64 {
	if n <= 0 {
		return 0
	}
	x := seed % 1000003
	if x < 0 {
		x = -x
	}
	x = (x*1103515245 + 12345) % 2147483647
	return x % n
}

func dragonKey(id int64) string {
	return strconv.FormatInt(id, 10)
}

func getDragon(id int64) Dragon {
	v, ok := dragons.Get(dragonKey(id)).(Dragon)
	if !ok {
		panic("dragon not found")
	}
	return v
}

func saveDragon(d Dragon) {
	dragons.Set(dragonKey(d.ID), d)
}

func getWallet(addr address) Wallet {
	w, ok := wallets.Get(addr.String()).(Wallet)
	if !ok {
		w = Wallet{
			LastForageDay: -1,
			DuelDay:       -1,
			AdvDay:        -1,
			ArmedDragon:   -1,
		}
	}
	return w
}

func saveWallet(addr address, w Wallet) {
	wallets.Set(addr.String(), w)
}

func allDragons() []Dragon {
	out := []Dragon{}
	dragons.Iterate("", "", func(key string, value any) bool {
		d, ok := value.(Dragon)
		if ok {
			out = append(out, d)
		}
		return false
	})
	return out
}

func dragonsOf(owner address) []Dragon {
	out := []Dragon{}
	for _, d := range allDragons() {
		if d.Owner == owner {
			out = append(out, d)
		}
	}
	return out
}

func rarityName(r int64) string {
	if r < 0 || r >= int64(len(rarityNames)) {
		return "Unknown"
	}
	return rarityNames[r]
}

func rarityCap(r int64) int64 {
	return rarityCaps[r]
}

func rarityMultOf(r int64) int64 {
	return rarityMult[r]
}

// fightScore is the combat value of a dragon: all three stats matter, so
// every equipment item (+(15 + 2 x Level) to one stat) helps in a fight.
func fightScore(d Dragon) int64 {
	base := d.Power*2 + d.Speed + d.Vitality
	return base * rarityMultOf(d.Rarity) / 100
}

// equipmentBonus is the stat boost one consumable item gives in a Hard
// adventure: +15 flat + 2 per Level of the dragon using it. Level 1 -> +17,
// Level 10 -> +35, Level 20 -> +55, Level 30 -> +75. Scaling keeps gear
// relevant as dragons level up; a flat +15 would matter less and less,
// making Hard harder the stronger you get.
func equipmentBonus(d Dragon) int64 {
	return 15 + 2*d.Level
}

// addXP grants XP and applies level-ups (50 x level XP per level, max 30).
func addXP(d *Dragon, amount int64) {
	if amount <= 0 {
		return
	}
	d.XP += amount
	for d.Level < maxLevel && d.XP >= 50*d.Level {
		d.XP -= 50 * d.Level
		d.Level++
	}
}

func shardOf(w Wallet, kind string) int64 {
	switch kind {
	case "Ember":
		return w.Ember
	case "Frost":
		return w.Frost
	case "Storm":
		return w.Storm
	case "Mystery":
		return w.Mystery
	}
	return 0
}

func addShard(w *Wallet, kind string, n int64) {
	switch kind {
	case "Ember":
		w.Ember += n
	case "Frost":
		w.Frost += n
	case "Storm":
		w.Storm += n
	case "Mystery":
		w.Mystery += n
	}
}

func gearOf(w Wallet, item string) int64 {
	switch item {
	case "Ember Blade":
		return w.Blades
	case "Frost Shield":
		return w.Shields
	case "Swift Charm":
		return w.Charms
	}
	return 0
}

func addGear(w *Wallet, item string, n int64) {
	switch item {
	case "Ember Blade":
		w.Blades += n
	case "Frost Shield":
		w.Shields += n
	case "Swift Charm":
		w.Charms += n
	}
}

func gearItems() []string {
	return []string{"Ember Blade", "Frost Shield", "Swift Charm"}
}

// elementStat is the stat that earns +5 bonus XP when trained: the dragon's
// element stat. Ember -> Power, Storm -> Speed, Frost/Stone -> Vitality.
func elementStat(element string) string {
	switch element {
	case "Ember":
		return "Power"
	case "Storm":
		return "Speed"
	default:
		return "Vitality"
	}
}

func validName(name string) bool {
	if len(name) == 0 || len(name) > 24 {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == ' ' || c == '-' || c == '\''
		if !ok {
			return false
		}
	}
	return true
}

func validElement(element string) bool {
	for _, e := range elements {
		if e == element {
			return true
		}
	}
	return false
}

// mintDragon creates a dragon, mints its GRC721 token to the owner, and
// returns its ID.
func mintDragon(owner address, name, element, trait string, rarity, power, speed, vitality int64, soulbound bool) int64 {
	id := nextDragonID
	nextDragonID++
	d := Dragon{
		ID:              id,
		Owner:           owner,
		Name:            name,
		Element:         element,
		Trait:           trait,
		Rarity:          rarity,
		Soulbound:       soulbound,
		Power:           power,
		Speed:           speed,
		Vitality:        vitality,
		Level:           1,
		XP:              0,
		Hunger:          100,
		Growth:          0,
		FeedCount:       0,
		Bond:            0,
		Streak:          0,
		LastFeedDay:     -1,
		LastTrainHeight: -1000000,
		TrainDay:        -1,
		TrainsToday:     0,
	}
	checkErr(ledger.Mint(owner, grc721.TokenID(dragonKey(id))))
	saveDragon(d)
	return id
}

// ---------------------------------------------------------------------------
// Crossing functions — the game
// ---------------------------------------------------------------------------

// Hatch mints the caller's one free soulbound Hatchling. Name is chosen by
// the owner; the trait is rolled from block height + caller address.
func Hatch(cur realm, name, element string) int64 {
	caller := cur.Previous().Address()
	if !validName(name) {
		panic("invalid name: 1-24 chars, letters, digits, spaces, - and ' only")
	}
	if !validElement(element) {
		panic("invalid element: Ember, Frost, Storm or Stone")
	}
	w := getWallet(caller)
	if w.HasStarter {
		panic("you already hatched your starter dragon")
	}
	if len(dragonsOf(caller)) >= maxDragonsPerWallet {
		panic("dragon cap reached (5 per wallet)")
	}
	seed := seedFrom(caller, runtime.ChainHeight())
	power := int64(20) + roll(seed+1, 11)
	speed := int64(20) + roll(seed+2, 11)
	vitality := int64(20) + roll(seed+3, 11)
	trait := traits[roll(seed+4, 4)]
	switch trait {
	case "Brave":
		power += 5
	case "Swift":
		speed += 5
	case "Hardy":
		vitality += 5
	}
	id := mintDragon(caller, name, element, trait, 0, power, speed, vitality, true)
	w.HasStarter = true
	saveWallet(caller, w)
	return id
}

// Train gives +2 to one stat and +10 XP (+5 bonus XP when training the
// dragon's element stat). Instant, but 50-block cooldown per dragon and max
// 3/day. Costs 10 Hunger; below 30 Hunger training XP is halved.
func Train(cur realm, dragonID int64, stat string) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	if stat != "Power" && stat != "Speed" && stat != "Vitality" {
		panic("stat must be Power, Speed or Vitality")
	}
	height := runtime.ChainHeight()
	if height-d.LastTrainHeight < trainCooldown {
		panic("training cooldown: wait 50 blocks between trains")
	}
	day := dayNow()
	if d.TrainDay != day {
		d.TrainDay = day
		d.TrainsToday = 0
	}
	if d.TrainsToday >= maxTrainsPerDay {
		panic("already trained 3 times today")
	}
	hungry := d.Hunger < 30
	xp := int64(10)
	if stat == elementStat(d.Element) {
		xp += 5
	}
	if hungry {
		xp = xp / 2
	}
	statCap := rarityCap(d.Rarity)
	switch stat {
	case "Power":
		d.Power += 2
		if d.Power  > statCap {
			d.Power = statCap
		}
	case "Speed":
		d.Speed += 2
		if d.Speed  > statCap {
			d.Speed = statCap
		}
	case "Vitality":
		d.Vitality += 2
		if d.Vitality  > statCap {
			d.Vitality = statCap
		}
	}
	d.Hunger -= 10
	if d.Hunger < 0 {
		d.Hunger = 0
	}
	addXP(&d, xp)
	d.LastTrainHeight = height
	d.TrainsToday++
	saveDragon(d)
	return ufmt.Sprintf("Trained %s (+2 %s, +%d XP). Level %d, Hunger %d.",
		d.Name, stat, xp, d.Level, d.Hunger)
}

// ClaimFood forages 1 Food per day, free.
func ClaimFood(cur realm) int64 {
	caller := cur.Previous().Address()
	w := getWallet(caller)
	day := dayNow()
	if w.LastForageDay == day {
		panic("already foraged today")
	}
	w.Food++
	w.LastForageDay = day
	saveWallet(caller, w)
	return w.Food
}

// Feed spends 1 Food: +15 XP (+5 more with the Stubborn trait), +1 Growth,
// +30 Hunger. Every 5 feeds +1 Vitality. Feeding the same dragon 7 days in
// a row raises its Bond level (+2 bonus Growth); missing a day resets the streak.
func Feed(cur realm, dragonID int64) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	w := getWallet(caller)
	if w.Food < 1 {
		panic("no food: forage (ClaimFood) or win an adventure first")
	}
	w.Food--
	xp := int64(15)
	if d.Trait == "Stubborn" {
		xp += 5
	}
	d.Hunger += 30
	if d.Hunger > 100 {
		d.Hunger = 100
	}
	d.Growth++
	d.FeedCount++
	if d.FeedCount%5 == 0 {
		d.Vitality++
		if d.Vitality > rarityCap(d.Rarity) {
			d.Vitality = rarityCap(d.Rarity)
		}
	}
	day := dayNow()
	bondMsg := ""
	if d.LastFeedDay != day {
		if d.LastFeedDay == day-1 {
			d.Streak++
		} else {
			d.Streak = 1
		}
		d.LastFeedDay = day
		if d.Streak%7 == 0 {
			d.Bond++
			d.Growth += 2
			bondMsg = ufmt.Sprintf(" Bond up! Bond level %d.", d.Bond)
		}
	}
	addXP(&d, xp)
	saveDragon(d)
	saveWallet(caller, w)
	return ufmt.Sprintf("Fed %s (+%d XP, Hunger %d, streak %d days).%s",
		d.Name, xp, d.Hunger, d.Streak, bondMsg)
}

// pickOpponent picks a realm-picked duel opponent: another player's dragon
// within Level +/-2 of d. Your own dragons are never valid opponents (a
// player must not be able to farm easy wins against their own weak wild
// dragon). found=false means no such dragon exists and the caller should
// use the sparring phantom instead.
func pickOpponent(caller address, d Dragon, candidates []Dragon, seed int64) (Dragon, bool) {
	others := []Dragon{}
	for _, o := range candidates {
		if o.ID != d.ID && o.Owner != caller && o.Level >= d.Level-2 && o.Level <= d.Level+2 {
			others = append(others, o)
		}
	}
	if len(others) == 0 {
		return Dragon{}, false
	}
	return others[roll(seed+10, int64(len(others)))], true
}

// Duel fights a realm-picked opponent dragon (Level +/-2 when other dragons
// exist, otherwise a sparring phantom near your own strength). Win +20 XP,
// lose +5 XP. Every 3rd win earns 1 Food. Costs 10 Hunger.
func Duel(cur realm, dragonID int64) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	w := getWallet(caller)
	day := dayNow()
	if w.DuelDay != day {
		w.DuelDay = day
		w.DuelsToday = 0
	}
	if w.DuelsToday >= maxDuelsPerDay {
		panic("already dueled 3 times today")
	}
	seed := seedFrom(caller, runtime.ChainHeight()+dragonID)
	// Pick an opponent: another player's dragon within Level +/-2 if one
	// exists (never your own dragon). Otherwise a sparring phantom.
	opp, found := pickOpponent(caller, d, allDragons(), seed)
	if !found {
		// Sparring phantom, 95% of your own stats.
		opp = Dragon{
			Name:     "Sparring Phantom",
			Element:  d.Element,
			Rarity:   d.Rarity,
			Power:    d.Power * 95 / 100,
			Speed:    d.Speed * 95 / 100,
			Vitality: d.Vitality * 95 / 100,
		}
	}
	ownScore := fightScore(d)
	if d.Hunger < 30 {
		ownScore = ownScore * 80 / 100
	}
	ownScore = ownScore * (100 + roll(seed+20, 21) - 10) / 100
	oppScore := fightScore(opp)
	win := ownScore >= oppScore
	d.Hunger -= 10
	if d.Hunger < 0 {
		d.Hunger = 0
	}
	msg := ""
	if win {
		addXP(&d, 20)
		w.DuelWins++
		if w.DuelWins%3 == 0 {
			w.Food++
			msg = ufmt.Sprintf("WIN vs %s! +20 XP. 3rd win: +1 Food.", opp.Name)
		} else {
			msg = ufmt.Sprintf("WIN vs %s! +20 XP.", opp.Name)
		}
	} else {
		addXP(&d, 5)
		msg = ufmt.Sprintf("LOSS vs %s. +5 XP.", opp.Name)
	}
	w.DuelsToday++
	saveDragon(d)
	saveWallet(caller, w)
	return msg
}

// Adventure fights a wild dragon. Tiers:
//   - Easy: wild at ~50% of your Power. Reward: wild Hatchling + 1 Ember shard + 10 XP + 1 Food.
//   - Normal: wild at 90-100%. Reward: wild Hatchling/Drake + 2 Frost shards + 20 XP + 2 Food, 40% gear drop.
//   - Hard: wild at 130-150%. Reward: wild Drake/Wyrm + 4 Storm shards + 40 XP + 3 Food, gear guaranteed.
//     Equipment may be used (see UseEquipment).
//   - Mystery: tier rolled at entry (30% Easy, 40% Normal, 30% Hard), rewards x1.5,
//     plus 2 Mystery shards. Only place Mystery shards drop.
// Win captures the wild dragon (unless you are at the 5-dragon cap). Lose:
// no dragon is lost, only Hunger.
func Adventure(cur realm, dragonID int64, tier string) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	if tier != "Easy" && tier != "Normal" && tier != "Hard" && tier != "Mystery" {
		panic("tier must be Easy, Normal, Hard or Mystery")
	}
	w := getWallet(caller)
	day := dayNow()
	if w.AdvDay != day {
		w.AdvDay = day
		w.AdvsToday = 0
	}
	if w.AdvsToday >= maxAdventuresPerDay {
		panic("already adventured 3 times today")
	}
	seed := seedFrom(caller, runtime.ChainHeight()+dragonID*7)
	resolved := tier
	if tier == "Mystery" {
		r := roll(seed+1, 100)
		if r < 30 {
			resolved = "Easy"
		} else if r < 70 {
			resolved = "Normal"
		} else {
			resolved = "Hard"
		}
	}
	// Wild dragon strength as a percentage of your Power.
	ratio := int64(50)
	wildRarity := int64(0)
	shardKind := "Ember"
	shardN := int64(1)
	xpReward := int64(10)
	foodReward := int64(1)
	if resolved == "Normal" {
		ratio = 90 + roll(seed+2, 11) // 90-100
		wildRarity = roll(seed+3, 2)  // Hatchling or Drake
		shardKind = "Frost"
		shardN = 2
		xpReward = 20
		foodReward = 2
	} else if resolved == "Hard" {
		ratio = 130 + roll(seed+4, 21) // 130-150
		wildRarity = 1 + roll(seed+5, 2) // Drake or Wyrm
		shardKind = "Storm"
		shardN = 4
		xpReward = 40
		foodReward = 3
	}
	if tier == "Mystery" {
		// Rewards x1.5 (rounded up).
		shardN = (shardN*3 + 1) / 2
		xpReward = (xpReward*3 + 1) / 2
		foodReward = (foodReward*3 + 1) / 2
	}
	// Build the wild dragon.
	wildElement := elements[roll(seed+6, 4)]
	wild := Dragon{
		Name:     "Wild " + wildElement,
		Element:  wildElement,
		Trait:    traits[roll(seed+7, 4)],
		Rarity:   wildRarity,
		Power:    d.Power * ratio / 100,
		Speed:    d.Speed * ratio / 100,
		Vitality: d.Vitality * ratio / 100,
	}
	if wild.Power < 1 {
		wild.Power = 1
	}
	if wild.Speed < 1 {
		wild.Speed = 1
	}
	if wild.Vitality < 1 {
		wild.Vitality = 1
	}
	// Equipment: Hard only, 1 consumable item armed via UseEquipment, burned
	// on this run whether you win or lose. The bonus (+(15 + 2 x Level))
	// applies to a copy used only for this fight's score — it never changes
	// the stored dragon.
	usedItem := ""
	fd := d
	if resolved == "Hard" && w.ArmedItem != "" && w.ArmedDragon == dragonID {
		usedItem = w.ArmedItem
		bonus := equipmentBonus(d)
		switch usedItem {
		case "Ember Blade":
			fd.Power += bonus
		case "Frost Shield":
			fd.Vitality += bonus
		case "Swift Charm":
			fd.Speed += bonus
		}
		addGear(&w, usedItem, -1)
		w.ArmedItem = ""
		w.ArmedDragon = -1
	}
	ownScore := fightScore(fd)
	if d.Hunger < 30 {
		ownScore = ownScore * 80 / 100
	}
	ownScore = ownScore * (100 + roll(seed+8, 21) - 10) / 100
	wildScore := fightScore(wild)
	win := ownScore >= wildScore
	d.Hunger -= 10
	if d.Hunger < 0 {
		d.Hunger = 0
	}
	w.AdvsToday++
	if !win {
		saveDragon(d)
		saveWallet(caller, w)
		if usedItem != "" {
			return ufmt.Sprintf("LOSS in %s adventure (used %s). Your dragon is safe, only Hunger lost.", resolved, usedItem)
		}
		return ufmt.Sprintf("LOSS in %s adventure. Your dragon is safe, only Hunger lost.", resolved)
	}
	// Win: rewards.
	addXP(&d, xpReward)
	addShard(&w, shardKind, shardN)
	w.Food += foodReward
	gearMsg := ""
	if resolved == "Normal" {
		if roll(seed+9, 100) < 40 {
			item := gearItems()[roll(seed+11, 3)]
			addGear(&w, item, 1)
			gearMsg = " Found 1 " + item + "!"
		}
	} else if resolved == "Hard" {
		item := gearItems()[roll(seed+11, 3)]
		addGear(&w, item, 1)
		gearMsg = " Found 1 " + item + "!"
	}
	if tier == "Mystery" {
		addShard(&w, "Mystery", 2)
	}
	captureMsg := ""
	if len(dragonsOf(caller)) < maxDragonsPerWallet {
		wildName := wild.Name + " #" + strconv.FormatInt(nextDragonID, 10)
		mintDragon(caller, wildName, wild.Element, wild.Trait, wild.Rarity,
			wild.Power, wild.Speed, wild.Vitality, false)
		captureMsg = " Captured a wild " + rarityName(wild.Rarity) + "!"
	} else {
		captureMsg = " Dragon cap (5) reached: no capture, rewards kept."
	}
	saveDragon(d)
	saveWallet(caller, w)
	return ufmt.Sprintf("WIN in %s adventure! +%d XP, +%d %s shards, +%d Food.%s%s",
		resolved, xpReward, shardN, shardKind, foodReward, gearMsg, captureMsg)
}

// UseEquipment arms one consumable item for the dragon's next Hard adventure.
// The item is burned on that Hard run, win or lose. Hard mode only.
func UseEquipment(cur realm, dragonID int64, item string) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	if item != "Ember Blade" && item != "Frost Shield" && item != "Swift Charm" {
		panic("item must be Ember Blade, Frost Shield or Swift Charm")
	}
	w := getWallet(caller)
	if gearOf(w, item) < 1 {
		panic("you do not own that item: win Normal/Hard adventures to earn gear")
	}
	w.ArmedItem = item
	w.ArmedDragon = dragonID
	saveWallet(caller, w)
	return ufmt.Sprintf("%s armed %s (+%d) for its next Hard adventure. It will be consumed on that run.",
		d.Name, item, equipmentBonus(d))
}

// Evolve raises a dragon one rarity, guaranteed once the Level threshold and
// shard cost are paid. Stats are kept; caps and the Power multiplier rise.
func Evolve(cur realm, dragonID int64) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	if d.Rarity >= 4 {
		panic("already Mythic: the highest rarity")
	}
	needLevel := evolveLevels[d.Rarity]
	needShards := evolveCosts[d.Rarity]
	kind := evolveShards[d.Rarity]
	if d.Level < needLevel {
		panic(ufmt.Sprintf("needs Level %d to evolve (currently %d)", needLevel, d.Level))
	}
	w := getWallet(caller)
	if shardOf(w, kind) < needShards {
		panic(ufmt.Sprintf("needs %d %s shards (you have %d): adventure to earn them",
			needShards, kind, shardOf(w, kind)))
	}
	addShard(&w, kind, -needShards)
	d.Rarity++
	saveDragon(d)
	saveWallet(caller, w)
	return ufmt.Sprintf("%s evolved into a %s! Stat cap now %d.",
		d.Name, rarityName(d.Rarity), rarityCap(d.Rarity))
}

// Merge burns two dragons of the same rarity (both yours, neither the
// soulbound starter) and mints one of the next rarity at Level 1, with stats
// averaged +5.
func Merge(cur realm, id1, id2 int64) int64 {
	caller := cur.Previous().Address()
	if id1 == id2 {
		panic("merge needs two different dragons")
	}
	d1 := getDragon(id1)
	d2 := getDragon(id2)
	if d1.Owner != caller || d2.Owner != caller {
		panic("both dragons must be yours")
	}
	if d1.Rarity != d2.Rarity {
		panic("merge needs two dragons of the same rarity")
	}
	if d1.Rarity >= 4 {
		panic("cannot merge Mythic dragons")
	}
	if d1.Soulbound || d2.Soulbound {
		panic("the soulbound starter dragon cannot be merged away")
	}
	newRarity := d1.Rarity + 1
	statCap := rarityCap(newRarity)
	power := (d1.Power+d2.Power)/2 + 5
	speed := (d1.Speed+d2.Speed)/2 + 5
	vitality := (d1.Vitality+d2.Vitality)/2 + 5
	if power  > statCap {
		power = statCap
	}
	if speed  > statCap {
		speed = statCap
	}
	if vitality  > statCap {
		vitality = statCap
	}
	name := "Heir of " + d1.Name
	if len(name) > 24 {
		name = name[:24]
	}
	checkErr(ledger.Burn(grc721.TokenID(dragonKey(id1))))
	checkErr(ledger.Burn(grc721.TokenID(dragonKey(id2))))
	dragons.Remove(dragonKey(id1))
	dragons.Remove(dragonKey(id2))
	seed := seedFrom(caller, runtime.ChainHeight()+id1+id2)
	trait := traits[roll(seed, 4)]
	return mintDragon(caller, name, d1.Element, trait, newRarity, power, speed, vitality, false)
}

// Transfer moves a wild dragon to another address. The soulbound starter
// can never be transferred.
func Transfer(cur realm, dragonID int64, to address) string {
	caller := cur.Previous().Address()
	d := getDragon(dragonID)
	if d.Owner != caller {
		panic("not your dragon")
	}
	if d.Soulbound {
		panic("the starter dragon is soulbound and cannot be transferred")
	}
	if !to.IsValid() {
		panic("invalid address")
	}
	if to != caller && len(dragonsOf(to)) >= maxDragonsPerWallet {
		panic("recipient already has 5 dragons")
	}
	checkErr(ledger.TransferFrom(caller, caller, to, grc721.TokenID(dragonKey(dragonID))))
	d.Owner = to
	saveDragon(d)
	return ufmt.Sprintf("Transferred %s (#%d) to %s.", d.Name, d.ID, to.String())
}

// ---------------------------------------------------------------------------
// Read-only helpers
// ---------------------------------------------------------------------------

// TotalDragons returns the number of dragons ever minted.
func TotalDragons() int64 {
	return nextDragonID
}

// DragonInfo returns a one-line summary of a dragon.
func DragonInfo(id int64) string {
	d := getDragon(id)
	return ufmt.Sprintf("#%d %s [%s %s, %s] Lv%d XP%d P%d/S%d/V%d Hunger%d Bond%d",
		d.ID, d.Name, rarityName(d.Rarity), d.Element, d.Trait,
		d.Level, d.XP, d.Power, d.Speed, d.Vitality, d.Hunger, d.Bond)
}

// WalletInfo returns a one-line summary of a wallet's inventory.
func WalletInfo(addr address) string {
	w := getWallet(addr)
	return ufmt.Sprintf("Food %d | Shards Ember %d Frost %d Storm %d Mystery %d | Gear Blade %d Shield %d Charm %d | Dragons %d",
		w.Food, w.Ember, w.Frost, w.Storm, w.Mystery,
		w.Blades, w.Shields, w.Charms, int64(len(dragonsOf(addr))))
}

// xpText describes progress to the next level. At Max Level there is no
// next level, so it says so instead of showing a bogus "XP x / 1500 to next".
func xpText(d Dragon) string {
	if d.Level >= maxLevel {
		return "MAX LEVEL"
	}
	return ufmt.Sprintf("XP %d / %d to next", d.XP, 50*d.Level)
}

func nextEvolveText(d Dragon, w Wallet) string {
	if d.Rarity >= 4 {
		return "Max rarity (Mythic)."
	}
	needLevel := evolveLevels[d.Rarity]
	needShards := evolveCosts[d.Rarity]
	kind := evolveShards[d.Rarity]
	return ufmt.Sprintf("Next evolve: %s at Level %d + %d %s shards (you have Level %d, %d %s shards).",
		rarityName(d.Rarity+1), needLevel, needShards, kind,
		d.Level, shardOf(w, kind), kind)
}

// ---------------------------------------------------------------------------
// Render — the playable UI
// ---------------------------------------------------------------------------

// Render serves the game page. "" is the home page (leaderboard + all
// dragons), "dragon/<id>" is one dragon's sheet, "wallet/<addr>" is one
// wallet's hearth. gnoweb calls Render with the path after the ":" in the
// URL (no leading slash), e.g. /r/velt/dragonhearth:dragon/0.
// Names are user-supplied and sanitized before output.
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	path = strings.TrimPrefix(path, "/")
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "dragon" {
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return "404\n"
		}
		return renderDragon(int64(id))
	}
	if len(parts) == 2 && parts[0] == "wallet" {
		addr := parts[1]
		if len(addr) != 40 || !strings.HasPrefix(addr, "g1") {
			return "404\n"
		}
		return renderWallet(address(addr))
	}
	return "404\n"
}

func renderHome() string {
	all := allDragons()
	// Leaderboard: top 5 by fight score (simple sort, n is small).
	sorted := make([]Dragon, len(all))
	for i, d := range all {
		sorted[i] = d
	}
	for i := 0; i < len(sorted); i++ {
		for j := i + 1; j < len(sorted); j++ {
			if fightScore(sorted[j]) > fightScore(sorted[i]) {
				tmp := sorted[i]
				sorted[i] = sorted[j]
				sorted[j] = tmp
			}
		}
	}
	s := "# Dragonhearth\n\n"
	s += "Hatch a dragon, train and feed it daily, win wild dragons on adventure, evolve and merge it up.\n\n"
	s += ufmt.Sprintf("**Dragons hatched:** %d | **Total supply (DRGN):** %d\n\n", len(all), Token.TotalSupply())
	s += "## Hall of Ancients — Top 5\n\n"
	if len(sorted) == 0 {
		s += "No dragons yet. Hatch the first one!\n\n"
	} else {
		for i := 0; i < len(sorted) && i < 5; i++ {
			d := sorted[i]
			s += ufmt.Sprintf("%d. **%s** (#%d, %s %s, Lv%d) — score %d, owner %s\n",
				i+1, sanitize.InlineText(d.Name), d.ID, rarityName(d.Rarity),
				d.Element, d.Level, fightScore(d), d.Owner.String())
		}
		s += "\n"
	}
	s += "## All Dragons\n\n"
	if len(all) == 0 {
		s += "None yet.\n"
	} else {
		shown := 0
		for _, d := range all {
			if shown >= 50 {
				break
			}
			s += ufmt.Sprintf("- #%d **%s** (%s %s, %s) Lv%d P%d/S%d/V%d — :dragon/%d\n",
				d.ID, sanitize.InlineText(d.Name), rarityName(d.Rarity),
				d.Element, d.Trait, d.Level, d.Power, d.Speed, d.Vitality, d.ID)
			shown++
		}
	}
	s += "\n## How to play\n\n"
	s += "1. `Hatch(name, element)` — one free soulbound Hatchling per wallet.\n"
	s += "2. `Train(id, stat)` — 3/day, +2 stat, +10 XP. `ClaimFood()` daily, `Feed(id)` to restore Hunger.\n"
	s += "3. `Adventure(id, tier)` — Easy/Normal/Hard/Mystery, 3/day. Win a wild dragon + shards.\n"
	s += "4. `Evolve(id)` — Level + shards. `Merge(id1, id2)` — two same-rarity dragons into one stronger.\n"
	s += "5. `Duel(id)` — 3/day vs a realm-picked opponent. `UseEquipment(id, item)` arms gear for Hard runs.\n"
	return s
}

func renderDragon(id int64) string {
	v, ok := dragons.Get(dragonKey(id)).(Dragon)
	if !ok {
		return "404\n"
	}
	d := v
	w := getWallet(d.Owner)
	s := ufmt.Sprintf("# %s (#%d)\n\n", sanitize.InlineText(d.Name), d.ID)
	s += ufmt.Sprintf("**%s %s** — Trait: %s | Owner: %s\n\n",
		rarityName(d.Rarity), d.Element, d.Trait, d.Owner.String())
	if d.Soulbound {
		s += "Soulbound starter dragon — cannot be transferred or merged.\n\n"
	}
	s += ufmt.Sprintf("**Level %d** (%s) | **Power %d / Speed %d / Vitality %d** (cap %d)\n\n",
		d.Level, xpText(d), d.Power, d.Speed, d.Vitality, rarityCap(d.Rarity))
	s += ufmt.Sprintf("**Hunger %d** | Growth %d | Bond level %d (feed streak %d days)\n\n",
		d.Hunger, d.Growth, d.Bond, d.Streak)
	s += nextEvolveText(d, w) + "\n\n"
	s += "## Owner inventory\n\n"
	s += WalletInfo(d.Owner) + "\n"
	return s
}

func renderWallet(addr address) string {
	ds := dragonsOf(addr)
	s := ufmt.Sprintf("# Hearth of %s\n\n", addr.String())
	s += WalletInfo(addr) + "\n\n"
	if len(ds) == 0 {
		s += "No dragons yet. Hatch one with `Hatch(name, element)`.\n"
		return s
	}
	for _, d := range ds {
		s += ufmt.Sprintf("- #%d **%s** (%s %s, %s) Lv%d P%d/S%d/V%d Hunger%d — :dragon/%d\n",
			d.ID, sanitize.InlineText(d.Name), rarityName(d.Rarity),
			d.Element, d.Trait, d.Level, d.Power, d.Speed, d.Vitality, d.Hunger, d.ID)
	}
	return s
}
