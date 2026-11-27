// Tavern Quest is an on-chain fantasy tavern game for the Gnome Tavern
// Hackathon. Players mint an adventurer, take quests from the tavern
// board, earn gold and XP, brew potions from quest ingredients, rest,
// and tip fellow adventurers. All state lives in this realm on Gno.land.
//
// Design notes:
//   - No external package imports: only the Go standard library pieces
//     that ship with Gno. That keeps `gno test` and deployment robust.
//   - State is plain slices of structs, searched linearly. The tavern
//     is small by design; linear scans keep the code auditable.
//   - Crossing functions (MintAdventurer, AcceptQuest, ...) take a
//     `realm` first parameter and resolve the caller with
//     `cur.Previous().Address()`. The game logic lives in internal
//     functions that take the caller address explicitly, so every rule
//     is unit-testable without a chain.
//   - Everything is deterministic: no randomness. Quest flavour is
//     picked by a deterministic rotation, so replays are reproducible.
package tavernquest

import (
	"errors"
	"strconv"
	"strings"

	"chain"
)

// ---------------------------------------------------------------------------
// Constants: classes, ingredients, potions, quests
// ---------------------------------------------------------------------------

const (
	// Classes. Each grants a different starting bonus.
	ClassBrewmaster = "Brewmaster"
	ClassRanger     = "Ranger"
	ClassBard       = "Bard"
	ClassRogue      = "Rogue"

	// Ingredients, earned by completing quests.
	IngEmberPepper = "Ember Pepper"
	IngMoonpetal   = "Moonpetal"
	IngFrogspawn   = "Frogspawn"
	IngDragonScale = "Dragon Scale"
	IngHoney       = "Honey"
	IngBatWing     = "Bat Wing"

	// Potions, brewed from ingredient pairs.
	PotionHealing = "Healing Draught"
	PotionLucky   = "Ember Mead"
	PotionStone   = "Stoneskin Stout"

	maxLevel    = 10
	startGold   = 50
	startHP     = 100
	restCost    = 5
	restHeal    = 30
	brewCost    = 10
	maxLogLines = 20
)

var classes = []string{ClassBrewmaster, ClassRanger, ClassBard, ClassRogue}

var ingredients = []string{
	IngEmberPepper, IngMoonpetal, IngFrogspawn,
	IngDragonScale, IngHoney, IngBatWing,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// Adventurer is one player's character. One per address.
type Adventurer struct {
	Owner         address
	Name          string
	Class         string
	Level         int
	XP            int
	Gold          int
	HP            int
	MaxHP         int
	ActiveQuest   int // quest ID, or -1 when idle
	QuestsDone    int
	TipsGiven     int
	TipsReceived  int
	PotionsHealed int // potions drunk, for the tavern record
	// Potion satchel.
	Healing int
	Lucky   int
	Stone   int
	// Ingredient pouch.
	EmberPepper int
	Moonpetal   int
	Frogspawn   int
	DragonScale int
	Honey       int
	BatWing     int
	// Active potion effects (consumed by the next completed quest).
	LuckyActive bool
	StoneActive bool
}

// Quest is one job on the tavern board.
type Quest struct {
	ID         int
	Name       string
	Desc       string
	MinLevel   int
	Gold       int
	XP         int
	HPCost     int
	Ingredient string
}

// TavernStats is the public scoreboard of the whole tavern.
type TavernStats struct {
	Adventurers   int
	QuestsDone    int
	GoldTipped    int
	PotionsBrewed int
	PotionsDrunk  int
}

var (
	adventurers []Adventurer
	quests      []Quest
	questLog    []string
	totalQuests int
	totalTipped int
	totalBrewed int
	totalDrunk  int
)

func seedQuests() {
	if len(quests) != 0 {
		return
	}
	quests = []Quest{
		{
			ID: 1, Name: "Rat Cellar Cleanup",
			Desc:       "The cellar rats have unionised. Clear them out before they eat the winter stores.",
			MinLevel:   1, Gold: 25, XP: 30, HPCost: 10, Ingredient: IngEmberPepper,
		},
		{
			ID: 2, Name: "Mushroom Forage at Dawn",
			Desc:       "Gather glowcaps in the misty woods before the sun burns the dew away.",
			MinLevel:   1, Gold: 30, XP: 35, HPCost: 10, Ingredient: IngMoonpetal,
		},
		{
			ID: 3, Name: "The Lost Lute",
			Desc:       "A bard left their enchanted lute in the haunted hollow. Bring it home.",
			MinLevel:   2, Gold: 45, XP: 50, HPCost: 15, Ingredient: IngHoney,
		},
		{
			ID: 4, Name: "Brew the Perfect Ale",
			Desc:       "The tavern keeper challenges you to brew an ale worthy of the Gnome King's table.",
			MinLevel:   2, Gold: 50, XP: 55, HPCost: 15, Ingredient: IngFrogspawn,
		},
		{
			ID: 5, Name: "Escort the Spice Merchant",
			Desc:       "Guard old Marla and her cinnamon cart through bandit woods to the next village.",
			MinLevel:   3, Gold: 80, XP: 80, HPCost: 20, Ingredient: IngBatWing,
		},
		{
			ID: 6, Name: "The Dragon's Tab",
			Desc:       "A dragon drank the tavern dry and left without paying. Collect the tab. Good luck.",
			MinLevel:   4, Gold: 150, XP: 120, HPCost: 30, Ingredient: IngDragonScale,
		},
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func levelForXP(xp int) int {
	lvl := 1 + xp/100
	if lvl > maxLevel {
		lvl = maxLevel
	}
	return lvl
}

func maxHPForLevel(lvl int) int {
	return 100 + (lvl-1)*10
}

func findAdventurer(addr address) int {
	for i := 0; i < len(adventurers); i++ {
		if adventurers[i].Owner == addr {
			return i
		}
	}
	return -1
}

func findQuest(id int) int {
	seedQuests()
	for i := 0; i < len(quests); i++ {
		if quests[i].ID == id {
			return i
		}
	}
	return -1
}

func validClass(class string) bool {
	for i := 0; i < len(classes); i++ {
		if classes[i] == class {
			return true
		}
	}
	return false
}

func validIngredient(name string) bool {
	for i := 0; i < len(ingredients); i++ {
		if ingredients[i] == name {
			return true
		}
	}
	return false
}

func ingredientCount(a *Adventurer, name string) int {
	switch name {
	case IngEmberPepper:
		return a.EmberPepper
	case IngMoonpetal:
		return a.Moonpetal
	case IngFrogspawn:
		return a.Frogspawn
	case IngDragonScale:
		return a.DragonScale
	case IngHoney:
		return a.Honey
	case IngBatWing:
		return a.BatWing
	}
	return 0
}

func takeIngredient(a *Adventurer, name string) {
	switch name {
	case IngEmberPepper:
		a.EmberPepper--
	case IngMoonpetal:
		a.Moonpetal--
	case IngFrogspawn:
		a.Frogspawn--
	case IngDragonScale:
		a.DragonScale--
	case IngHoney:
		a.Honey--
	case IngBatWing:
		a.BatWing--
	}
}

func giveIngredient(a *Adventurer, name string) {
	switch name {
	case IngEmberPepper:
		a.EmberPepper++
	case IngMoonpetal:
		a.Moonpetal++
	case IngFrogspawn:
		a.Frogspawn++
	case IngDragonScale:
		a.DragonScale++
	case IngHoney:
		a.Honey++
	case IngBatWing:
		a.BatWing++
	}
}

// recipeFor returns the potion brewed from a pair of ingredients, or "".
func recipeFor(a, b string) string {
	if (a == IngEmberPepper && b == IngHoney) || (a == IngHoney && b == IngEmberPepper) {
		return PotionLucky
	}
	if (a == IngMoonpetal && b == IngFrogspawn) || (a == IngFrogspawn && b == IngMoonpetal) {
		return PotionHealing
	}
	if (a == IngDragonScale && b == IngBatWing) || (a == IngBatWing && b == IngDragonScale) {
		return PotionStone
	}
	return ""
}

func addLog(line string) {
	questLog = append(questLog, line)
	if len(questLog) > maxLogLines {
		questLog = questLog[len(questLog)-maxLogLines:]
	}
}

func applyLevel(a *Adventurer) {
	lvl := levelForXP(a.XP)
	if lvl > a.Level {
		a.Level = lvl
		a.MaxHP = maxHPForLevel(lvl)
		a.HP = a.MaxHP // levelling up restores you to full health
	}
}

// ---------------------------------------------------------------------------
// Read-only getters (no realm parameter; anyone can call them)
// ---------------------------------------------------------------------------

// GetAdventurer returns the adventurer owned by addr.
func GetAdventurer(addr address) (Adventurer, bool) {
	i := findAdventurer(addr)
	if i < 0 {
		return Adventurer{}, false
	}
	return adventurers[i], true
}

// GetQuest returns one quest from the board.
func GetQuest(id int) (Quest, bool) {
	i := findQuest(id)
	if i < 0 {
		return Quest{}, false
	}
	return quests[i], true
}

// ListQuests returns the whole tavern board.
func ListQuests() []Quest {
	seedQuests()
	out := make([]Quest, len(quests))
	copy(out, quests)
	return out
}

// ListAdventurers returns every adventurer, in mint order.
func ListAdventurers() []Adventurer {
	out := make([]Adventurer, len(adventurers))
	copy(out, adventurers)
	return out
}

// Leaderboard returns adventurers sorted by XP, then quests done,
// then gold. At most 10 entries.
func Leaderboard() []Adventurer {
	out := ListAdventurers()
	// Insertion sort: the tavern is small and the order must be
	// deterministic.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0; j-- {
			a := out[j-1]
			b := out[j]
			better := b.XP > a.XP ||
				(b.XP == a.XP && b.QuestsDone > a.QuestsDone) ||
				(b.XP == a.XP && b.QuestsDone == a.QuestsDone && b.Gold > a.Gold)
			if !better {
				break
			}
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	if len(out) > 10 {
		out = out[:10]
	}
	return out
}

// Stats returns the tavern's public scoreboard.
func Stats() TavernStats {
	return TavernStats{
		Adventurers:   len(adventurers),
		QuestsDone:    totalQuests,
		GoldTipped:    totalTipped,
		PotionsBrewed: totalBrewed,
		PotionsDrunk:  totalDrunk,
	}
}

// QuestLog returns the last tavern tales (most recent last).
func QuestLog() []string {
	out := make([]string, len(questLog))
	copy(out, questLog)
	return out
}

// ---------------------------------------------------------------------------
// Game logic (internal; caller address passed explicitly for testability)
// ---------------------------------------------------------------------------

func mintAdventurer(caller address, name, class string) error {
	seedQuests()
	if findAdventurer(caller) >= 0 {
		return errors.New("you already have an adventurer")
	}
	name = strings.TrimSpace(name)
	if len(name) < 3 || len(name) > 20 {
		return errors.New("name must be 3-20 characters")
	}
	if strings.Contains(name, "\n") || strings.Contains(name, "/") {
		return errors.New("name must not contain newlines or slashes")
	}
	if !validClass(class) {
		return errors.New("unknown class: choose Brewmaster, Ranger, Bard or Rogue")
	}
	a := Adventurer{
		Owner: caller, Name: name, Class: class,
		Level: 1, XP: 0, Gold: startGold, HP: startHP, MaxHP: startHP,
		ActiveQuest: -1,
	}
	// Class starting bonus.
	switch class {
	case ClassBrewmaster:
		a.Healing = 1
	case ClassRanger:
		a.Gold += 20
	case ClassBard:
		a.Lucky = 1
	case ClassRogue:
		a.Stone = 1
	}
	adventurers = append(adventurers, a)
	addLog(name + " the " + class + " bellies up to the bar. A new legend begins!")
	return nil
}

func acceptQuest(caller address, questID int) error {
	seedQuests()
	i := findAdventurer(caller)
	if i < 0 {
		return errors.New("mint an adventurer first")
	}
	q := findQuest(questID)
	if q < 0 {
		return errors.New("no such quest on the board")
	}
	a := &adventurers[i]
	if a.ActiveQuest != -1 {
		return errors.New("finish your current quest first")
	}
	if a.Level < quests[q].MinLevel {
		return errors.New("you need level " + strconv.Itoa(quests[q].MinLevel) + " for this quest")
	}
	a.ActiveQuest = questID
	return nil
}

func abandonQuest(caller address) error {
	i := findAdventurer(caller)
	if i < 0 {
		return errors.New("mint an adventurer first")
	}
	if adventurers[i].ActiveQuest == -1 {
		return errors.New("you have no active quest to abandon")
	}
	adventurers[i].ActiveQuest = -1
	return nil
}

func completeQuest(caller address) (string, error) {
	seedQuests()
	i := findAdventurer(caller)
	if i < 0 {
		return "", errors.New("mint an adventurer first")
	}
	a := &adventurers[i]
	if a.ActiveQuest == -1 {
		return "", errors.New("you have no active quest to complete")
	}
	q := findQuest(a.ActiveQuest)
	if q < 0 {
		return "", errors.New("your active quest vanished from the board")
	}
	quest := quests[q]
	hpCost := quest.HPCost
	if a.StoneActive {
		hpCost = hpCost / 2
		a.StoneActive = false
	}
	if a.HP <= hpCost {
		return "", errors.New("not enough HP: rest at the tavern or drink a Healing Draught first")
	}
	gold := quest.Gold
	if a.LuckyActive {
		gold = gold * 2
		a.LuckyActive = false
	}
	a.HP -= hpCost
	a.Gold += gold
	a.XP += quest.XP
	a.QuestsDone++
	a.ActiveQuest = -1
	giveIngredient(a, quest.Ingredient)
	applyLevel(a)
	totalQuests++
	tale := a.Name + " completed " + quest.Name + " (+" + strconv.Itoa(gold) +
		" gold, +" + strconv.Itoa(quest.XP) + " XP, found " + quest.Ingredient + ")"
	addLog(tale)
	return tale, nil
}

func rest(caller address) error {
	i := findAdventurer(caller)
	if i < 0 {
		return errors.New("mint an adventurer first")
	}
	a := &adventurers[i]
	if a.HP >= a.MaxHP {
		return errors.New("you are already at full health")
	}
	if a.Gold < restCost {
		return errors.New("rest costs " + strconv.Itoa(restCost) + " gold")
	}
	a.Gold -= restCost
	a.HP += restHeal
	if a.HP > a.MaxHP {
		a.HP = a.MaxHP
	}
	return nil
}

func brewPotion(caller address, first, second string) (string, error) {
	if !validIngredient(first) || !validIngredient(second) {
		return "", errors.New("unknown ingredient")
	}
	if first == second {
		return "", errors.New("a recipe needs two different ingredients")
	}
	potion := recipeFor(first, second)
	if potion == "" {
		return "", errors.New("no known recipe for " + first + " + " + second)
	}
	i := findAdventurer(caller)
	if i < 0 {
		return "", errors.New("mint an adventurer first")
	}
	a := &adventurers[i]
	if ingredientCount(a, first) < 1 || ingredientCount(a, second) < 1 {
		return "", errors.New("you lack the ingredients for that brew")
	}
	if a.Gold < brewCost {
		return "", errors.New("brewing costs " + strconv.Itoa(brewCost) + " gold")
	}
	a.Gold -= brewCost
	takeIngredient(a, first)
	takeIngredient(a, second)
	switch potion {
	case PotionHealing:
		a.Healing++
	case PotionLucky:
		a.Lucky++
	case PotionStone:
		a.Stone++
	}
	totalBrewed++
	addLog(a.Name + " brewed a " + potion + " behind the bar. The tavern smells of magic.")
	return potion, nil
}

func drinkPotion(caller address, potion string) (string, error) {
	i := findAdventurer(caller)
	if i < 0 {
		return "", errors.New("mint an adventurer first")
	}
	a := &adventurers[i]
	switch potion {
	case PotionHealing:
		if a.Healing < 1 {
			return "", errors.New("you have no Healing Draught")
		}
		if a.HP >= a.MaxHP {
			return "", errors.New("you are already at full health")
		}
		a.Healing--
		a.HP += 50
		if a.HP > a.MaxHP {
			a.HP = a.MaxHP
		}
	case PotionLucky:
		if a.Lucky < 1 {
			return "", errors.New("you have no Ember Mead")
		}
		if a.LuckyActive {
			return "", errors.New("liquid luck is already flowing")
		}
		a.Lucky--
		a.LuckyActive = true
	case PotionStone:
		if a.Stone < 1 {
			return "", errors.New("you have no Stoneskin Stout")
		}
		if a.StoneActive {
			return "", errors.New("your skin is already stone")
		}
		a.Stone--
		a.StoneActive = true
	default:
		return "", errors.New("unknown potion: Healing Draught, Ember Mead or Stoneskin Stout")
	}
	totalDrunk++
	a.PotionsHealed++
	addLog(a.Name + " drank a " + potion + ".")
	return potion, nil
}

func tipAdventurer(caller, to address, amount int) error {
	if amount <= 0 {
		return errors.New("tip must be more than 0 gold")
	}
	if caller == to {
		return errors.New("you cannot tip yourself")
	}
	from := findAdventurer(caller)
	if from < 0 {
		return errors.New("mint an adventurer first")
	}
	dest := findAdventurer(to)
	if dest < 0 {
		return errors.New("that adventurer does not exist")
	}
	if adventurers[from].Gold < amount {
		return errors.New("not enough gold to tip that much")
	}
	adventurers[from].Gold -= amount
	adventurers[from].TipsGiven += amount
	adventurers[dest].Gold += amount
	adventurers[dest].TipsReceived += amount
	totalTipped += amount
	addLog(adventurers[from].Name + " tipped " + adventurers[dest].Name + " " +
		strconv.Itoa(amount) + " gold. Generosity is remembered in this tavern.")
	return nil
}

// ---------------------------------------------------------------------------
// Crossing functions (the on-chain entry points)
// ---------------------------------------------------------------------------

// MintAdventurer creates your adventurer. One per address.
func MintAdventurer(cur realm, name, class string) {
	caller := cur.Previous().Address()
	if err := mintAdventurer(caller, name, class); err != nil {
		panic(err)
	}
	chain.Emit("AdventurerMinted", "name", name, "class", class)
}

// AcceptQuest takes a quest from the board. One active quest at a time.
func AcceptQuest(cur realm, questID int) {
	caller := cur.Previous().Address()
	if err := acceptQuest(caller, questID); err != nil {
		panic(err)
	}
	chain.Emit("QuestAccepted", "quest", strconv.Itoa(questID))
}

// AbandonQuest drops your active quest with no reward.
func AbandonQuest(cur realm) {
	caller := cur.Previous().Address()
	if err := abandonQuest(caller); err != nil {
		panic(err)
	}
}

// CompleteQuest finishes your active quest and pays out gold, XP and
// an ingredient. Returns the tavern tale of your deed.
func CompleteQuest(cur realm) string {
	caller := cur.Previous().Address()
	tale, err := completeQuest(caller)
	if err != nil {
		panic(err)
	}
	chain.Emit("QuestCompleted", "tale", tale)
	return tale
}

// Rest restores 30 HP for 5 gold.
func Rest(cur realm) {
	caller := cur.Previous().Address()
	if err := rest(caller); err != nil {
		panic(err)
	}
}

// BrewPotion combines two different ingredients into a potion.
// Recipes: Ember Pepper + Honey = Ember Mead (next quest pays double
// gold); Moonpetal + Frogspawn = Healing Draught (+50 HP);
// Dragon Scale + Bat Wing = Stoneskin Stout (next quest costs half HP).
func BrewPotion(cur realm, first, second string) string {
	caller := cur.Previous().Address()
	potion, err := brewPotion(caller, first, second)
	if err != nil {
		panic(err)
	}
	chain.Emit("PotionBrewed", "potion", potion)
	return potion
}

// DrinkPotion uses a potion from your satchel.
func DrinkPotion(cur realm, potion string) {
	caller := cur.Previous().Address()
	if _, err := drinkPotion(caller, potion); err != nil {
		panic(err)
	}
}

// TipAdventurer sends gold from your purse to another adventurer.
func TipAdventurer(cur realm, to address, amount int) {
	caller := cur.Previous().Address()
	if err := tipAdventurer(caller, to, amount); err != nil {
		panic(err)
	}
	chain.Emit("TipSent", "amount", strconv.Itoa(amount))
}
