package nisse

import "strconv"

type Boat struct {
	OwnerPlayer string
	Name        string
	Pos         Position
	Carried     bool
}

var boats map[string]*Boat

func init() {
	boats = make(map[string]*Boat)
}

func waterTravelTile(code uint8) bool {
	switch code {
	case 0, 1, 8, 11, 13, 14:
		return true
	default:
		return false
	}
}

func playerOwnsBoat(playerKey string) bool {
	return boats[playerKey] != nil
}

func playerCarriesBoat(playerKey string) bool {
	boat := boats[playerKey]
	return boat != nil && boat.Carried
}

func boatTravelBudget(playerKey string) uint64 {
	if playerCarriesBoat(playerKey) {
		return 8
	}
	return 0
}

func grantBoat(playerKey string, player *Player, source string) string {
	if playerOwnsBoat(playerKey) {
		return ""
	}

	boats[playerKey] = &Boat{
		OwnerPlayer: player.Name,
		Name:        "weathered skiff",
		Pos:         player.Pos,
		Carried:     true,
	}
	return "BoatGranted:" + source
}

func BuyBoat(cur realm, playerName string) string {
	key, player, _ := ownedPlayer(cur, playerName)
	code := GetTile(player.Pos.X, player.Pos.Y)
	if code != 11 {
		panic("boats can only be bought in fishing villages")
	}
	if playerOwnsBoat(key) {
		panic("you already own a boat")
	}
	if totalPearls(key) < 1 {
		panic("you need 1 pearl to buy a boat")
	}

	spendPearls(key, 1, "Spent 1 pearl on a weathered skiff.")
	grantBoat(key, player, placeName(player.Pos))
	createDiaryEntry(
		key,
		"boat",
		placeName(player.Pos),
		"day",
		"boat_bought",
		"Boat:skiff\nCost:1 pearl",
	)
	return "boat_bought"
}

func leaveBoatBehind(playerKey string, pos Position) bool {
	boat := boats[playerKey]
	if boat == nil || !boat.Carried {
		return false
	}

	boat.Carried = false
	boat.Pos = pos
	return true
}

func recoverBoatIfPresent(playerKey string, player *Player) bool {
	boat := boats[playerKey]
	if boat == nil || boat.Carried {
		return false
	}
	if !sameTile(boat.Pos, player.Pos) {
		return false
	}

	boat.Carried = true
	return true
}

func boatStatusSummary(playerKey string) string {
	boat := boats[playerKey]
	if boat == nil {
		return "none"
	}
	if boat.Carried {
		return boat.Name + " (carried)"
	}
	return boat.Name + " left at (" + strconv.Itoa(int(boat.Pos.X)) + ", " + strconv.Itoa(int(boat.Pos.Y)) + ")"
}
