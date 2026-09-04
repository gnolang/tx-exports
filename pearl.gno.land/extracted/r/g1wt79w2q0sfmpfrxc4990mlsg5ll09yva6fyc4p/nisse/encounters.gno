package nisse

import "strconv"

// Unified creature encounters: every land tile can roll one.
// Common creatures have high spawn weight; mythic ones are rare.
// Resolution uses the traveler's chosen attitude (bold / kind / cautious)
// against the creature's Level threshold.

type CreatureSpec struct {
	Kind   string
	Level  uint64 // difficulty / threshold seed
	Weight uint64 // relative weight inside a terrain pool
}

type EncounterResult struct {
	Kind         string
	Title        string
	Body         string
	Attitude     string
	Band         string
	Roll         uint64
	PlayerTotal  uint64
	Target       uint64
	LevelGain    uint64
	ClaimID      string
	Place        string
	Turn         uint64
	OutcomeTier  uint64
}

var latestEncounters map[string]*EncounterResult

func init() {
	latestEncounters = make(map[string]*EncounterResult)
}

func normalizeArrivalAttitude(value string) string {
	switch normalizeKey(value) {
	case "", "cautious":
		return "cautious"
	case "kind":
		return "kind"
	case "bold":
		return "bold"
	default:
		panic("unknown attitude")
	}
}

func terrainEncounterChance(code uint8) uint64 {
	// Percent chance to meet something on arrival.
	switch terrainName(code) {
	case "forest", "meadow", "moor":
		return 75
	case "hills", "mountain", "coastal":
		return 60
	case "farm", "fishing_village", "mountain_village":
		return 55
	case "harbor", "monastery":
		return 40
	case "city", "city_north", "city_south", "village":
		return 30
	case "ocean":
		return 0
	default:
		return 40
	}
}

func creaturesForTerrain(code uint8) []CreatureSpec {
	// Weights: higher = more common. Mythics stay very low.
	switch terrainName(code) {
	case "forest":
		return []CreatureSpec{
			{Kind: "squirrel", Level: 2, Weight: 28},
			{Kind: "deer", Level: 3, Weight: 22},
			{Kind: "owl", Level: 3, Weight: 18},
			{Kind: "fox", Level: 4, Weight: 14},
			{Kind: "bear", Level: 7, Weight: 8},
			{Kind: "fairy", Level: 6, Weight: 6},
			{Kind: "unicorn", Level: 12, Weight: 2},
			{Kind: "griffin", Level: 14, Weight: 1},
		}
	case "meadow", "moor":
		return []CreatureSpec{
			{Kind: "rabbit", Level: 1, Weight: 30},
			{Kind: "deer", Level: 3, Weight: 22},
			{Kind: "fox", Level: 4, Weight: 18},
			{Kind: "dog", Level: 3, Weight: 14},
			{Kind: "unicorn", Level: 12, Weight: 2},
		}
	case "hills":
		return []CreatureSpec{
			{Kind: "goat", Level: 2, Weight: 26},
			{Kind: "fox", Level: 4, Weight: 20},
			{Kind: "deer", Level: 3, Weight: 16},
			{Kind: "reindeer", Level: 5, Weight: 12},
			{Kind: "wolverine", Level: 7, Weight: 8},
			{Kind: "griffin", Level: 14, Weight: 2},
			{Kind: "pegasus", Level: 13, Weight: 1},
		}
	case "mountain", "mountain_village":
		return []CreatureSpec{
			{Kind: "goat", Level: 2, Weight: 24},
			{Kind: "eagle", Level: 5, Weight: 18},
			{Kind: "wolverine", Level: 7, Weight: 14},
			{Kind: "bear", Level: 7, Weight: 12},
			{Kind: "griffin", Level: 14, Weight: 3},
			{Kind: "pegasus", Level: 13, Weight: 2},
		}
	case "farm":
		return []CreatureSpec{
			{Kind: "dog", Level: 3, Weight: 30},
			{Kind: "donkey", Level: 3, Weight: 24},
			{Kind: "mule", Level: 4, Weight: 18},
			{Kind: "cat", Level: 2, Weight: 16},
			{Kind: "fox", Level: 4, Weight: 8},
		}
	case "coastal", "harbor", "fishing_village":
		return []CreatureSpec{
			{Kind: "gull", Level: 2, Weight: 28},
			{Kind: "seal", Level: 4, Weight: 20},
			{Kind: "otter", Level: 3, Weight: 18},
			{Kind: "dog", Level: 3, Weight: 12},
			{Kind: "pegasus", Level: 13, Weight: 1},
		}
	case "monastery":
		return []CreatureSpec{
			{Kind: "dove", Level: 2, Weight: 30},
			{Kind: "cat", Level: 2, Weight: 22},
			{Kind: "owl", Level: 3, Weight: 18},
			{Kind: "fairy", Level: 6, Weight: 8},
		}
	default:
		// villages / cities / unknown land
		return []CreatureSpec{
			{Kind: "dog", Level: 3, Weight: 28},
			{Kind: "cat", Level: 2, Weight: 24},
			{Kind: "fox", Level: 4, Weight: 12},
			{Kind: "raven", Level: 3, Weight: 12},
		}
	}
}

func pickCreature(player *Player, pool []CreatureSpec) *CreatureSpec {
	if len(pool) == 0 {
		return nil
	}
	total := uint64(0)
	for _, c := range pool {
		total += c.Weight
	}
	if total == 0 {
		return &pool[0]
	}
	needle := rollMod(player, "encounter-pick", total)
	running := uint64(0)
	for i := 0; i < len(pool); i++ {
		running += pool[i].Weight
		if needle < running {
			return &pool[i]
		}
	}
	return &pool[len(pool)-1]
}

type ResolveTotals struct {
	Bold     uint64
	Cautious uint64
	Kind     uint64
	Soul     uint64
}

func resolveTotals(player *Player, playerKey string, attitude string) ResolveTotals {
	totals := ResolveTotals{
		Bold:     player.Boldness,
		Cautious: player.Caution,
		Kind:     player.Kindness,
		Soul:     player.Soul,
	}
	// Chosen mood gets a clear edge this encounter.
	switch normalizeArrivalAttitude(attitude) {
	case "bold":
		totals.Bold += 10
	case "kind":
		totals.Kind += 10
	default:
		totals.Cautious += 10
	}
	aggregate, ok := aggregateHeldCompanionProfile(playerKey)
	if ok {
		totals.Bold += aggregate.Boldness
		totals.Cautious += aggregate.Caution
		totals.Kind += aggregate.Kindness
		totals.Soul += aggregate.Soul
	}
	return totals
}

func resolveStatTotal(totals ResolveTotals, attitude string) uint64 {
	switch normalizeArrivalAttitude(attitude) {
	case "bold":
		return totals.Bold
	case "kind":
		return totals.Kind
	default:
		return totals.Cautious
	}
}

func encounterBand(total int64, target int64) string {
	if total >= target+6 {
		return "triumph"
	}
	if total >= target {
		return "success"
	}
	if total >= target-6 {
		return "setback"
	}
	return "ruin"
}

func encounterTarget(creature *CreatureSpec, player *Player) uint64 {
	// Level-vs-level: creature level sets the bar; player level softens it.
	base := 12 + creature.Level*3
	if player.Level >= creature.Level {
		diff := player.Level - creature.Level
		if diff > base/2 {
			diff = base / 2
		}
		base -= diff
	}
	if base < 8 {
		return 8
	}
	return base
}

func lowerStat(value *uint64, amount uint64) uint64 {
	if value == nil || amount == 0 {
		return 0
	}
	if *value <= amount {
		lost := *value
		*value = 0
		return lost
	}
	*value -= amount
	return amount
}

func outcomeTierForBand(band string) uint64 {
	switch normalizeKey(band) {
	case "triumph":
		return 3
	case "success":
		return 1
	default:
		return 0
	}
}

func resolveEncounter(
	key string,
	player *Player,
	creature *CreatureSpec,
	preface string,
	attitude string,
) string {
	attitude = normalizeArrivalAttitude(attitude)
	place := placeName(player.Pos)
	roll := d20(player, "encounter-"+creature.Kind)
	totals := resolveTotals(player, key, attitude)
	stat := resolveStatTotal(totals, attitude)
	// Player level contributes lightly on top of the mood stat.
	playerTotal := roll + stat + player.Level
	target := encounterTarget(creature, player)
	band := encounterBand(int64(playerTotal), int64(target))

	title := creature.Kind + "_" + band
	body := preface
	if body != "" && body[len(body)-1:] != "\n" {
		body += "\n"
	}
	body += "Encounter:" + creature.Kind + "\n"
	body += "Level:" + strconv.Itoa(int(creature.Level)) + "\n"
	body += "Attitude:" + attitude + "\n"
	body += "Outcome:" + band + "\n"
	body += "Place:" + place

	mintedKind := ""
	levelGain := uint64(0)

	switch band {
	case "triumph", "success":
		bonusText := grantAttitudeSuccessBonus(player, attitude)
		if bonusText != "" {
			body += "\n" + bonusText
		}
		if band == "triumph" {
			player.Soul++
			levelGain = 1
			player.Level++
			body += "\nLevel +1."
		}
		// Auto-mint on success: default name, no bag limit, skip if already owned.
		if companionMintSpec(creature.Kind) != nil {
			if playerOwnsCompanionType(player.Name, creature.Kind) {
				body += "\nAlready bonded with this kind."
			} else {
				ok, label := autoMintEncounterCompanion(key, player, creature.Kind)
				if ok {
					mintedKind = creature.Kind
					body += "\nBonded: " + label + " the " + companionLabel(creature.Kind) + "."
				}
			}
		}
	case "setback":
		switch attitude {
		case "bold":
			lost := lowerStat(&player.Boldness, 1)
			if lost > 0 {
				body += "\nPenalty: Boldness -" + strconv.Itoa(int(lost)) + "."
			}
		case "kind":
			lost := lowerStat(&player.Kindness, 1)
			if lost > 0 {
				body += "\nPenalty: Kindness -" + strconv.Itoa(int(lost)) + "."
			}
		default:
			lost := lowerStat(&player.Caution, 1)
			if lost > 0 {
				body += "\nPenalty: Caution -" + strconv.Itoa(int(lost)) + "."
			}
		}
	default: // ruin
		lostSoul := lowerStat(&player.Soul, 1)
		body += "\nPenalty:"
		if lostSoul > 0 {
			body += " Soul -" + strconv.Itoa(int(lostSoul))
		}
		switch attitude {
		case "bold":
			lost := lowerStat(&player.Boldness, 2)
			if lost > 0 {
				body += " Boldness -" + strconv.Itoa(int(lost))
			}
		case "kind":
			lost := lowerStat(&player.Kindness, 2)
			if lost > 0 {
				body += " Kindness -" + strconv.Itoa(int(lost))
			}
		default:
			lost := lowerStat(&player.Caution, 2)
			if lost > 0 {
				body += " Caution -" + strconv.Itoa(int(lost))
			}
		}
		body += "."
	}

	body += "\n\nDice:"
	body += "\nD20: " + strconv.Itoa(int(roll))
	body += "\nMood stat: +" + strconv.Itoa(int(stat))
	body += "\nPlayer level: +" + strconv.Itoa(int(player.Level))
	body += "\nTotal: " + strconv.Itoa(int(playerTotal))
	body += "\nTarget: " + strconv.Itoa(int(target))
	body += "\nResult: " + band

	createDiaryEntry(key, "encounter", place, "day", title, body)
	latestEncounters[key] = &EncounterResult{
		Kind:        creature.Kind,
		Title:       title,
		Body:        body,
		Attitude:    attitude,
		Band:        band,
		Roll:        roll,
		PlayerTotal: playerTotal,
		Target:      target,
		LevelGain:   levelGain,
		ClaimID:     mintedKind, // reused field: minted kind, if any
		Place:       place,
		Turn:        player.Turns,
		OutcomeTier: outcomeTierForBand(band),
	}
	return title
}

// resolveArrivalEncounterOnEntry is called after a successful travel move.
// Returns (happened, title). Quiet tiles still travel-only.
func resolveArrivalEncounterOnEntry(key string, player *Player, attitude string, travelBody string) (bool, string) {
	code := GetTile(player.Pos.X, player.Pos.Y)
	chance := terrainEncounterChance(code)
	if chance == 0 {
		return false, ""
	}
	if percentRoll(player, "encounter-chance") >= chance {
		return false, ""
	}
	pool := creaturesForTerrain(code)
	creature := pickCreature(player, pool)
	if creature == nil {
		return false, ""
	}
	preface := travelBody + "\nAttitude on arrival: " + normalizeArrivalAttitude(attitude) + "."
	title := resolveEncounter(key, player, creature, preface, attitude)
	return true, title
}

func DescribeLatestEncounterResult(playerName string) string {
	key := normalizeKey(playerName)
	if _, ok := players[key]; !ok {
		panic("player not found")
	}
	result := latestEncounters[key]
	if result == nil {
		return "No encounter yet."
	}
	out := "Kind: " + result.Kind + "\n"
	out += "Title: " + result.Title + "\n"
	out += "Attitude: " + result.Attitude + "\n"
	out += "Band: " + result.Band + "\n"
	out += "Roll: " + strconv.Itoa(int(result.Roll)) + "\n"
	out += "PlayerTotal: " + strconv.Itoa(int(result.PlayerTotal)) + "\n"
	out += "Target: " + strconv.Itoa(int(result.Target)) + "\n"
	out += "LevelGain: " + strconv.Itoa(int(result.LevelGain)) + "\n"
	out += "Minted: " + result.ClaimID + "\n"
	out += "OutcomeTier: " + strconv.Itoa(int(result.OutcomeTier)) + "\n"
	out += "Place: " + result.Place + "\n"
	out += "Turn: " + strconv.Itoa(int(result.Turn)) + "\n"
	out += "Body: " + result.Body
	return out
}
