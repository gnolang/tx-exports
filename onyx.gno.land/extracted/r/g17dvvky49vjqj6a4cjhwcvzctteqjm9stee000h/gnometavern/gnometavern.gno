// Realm gnometavern is the Gnome Tavern: a small on-chain tavern game
// on Gno.land. Players register a gnome, work shifts serving drinks and
// food from the menu, complete a rotating daily quest board, level up,
// feast, and leave notes on the tavern wall.
//
// All game rules live in the pure package tavernlogic; this realm owns
// the persistent state and the caller authentication, and renders the
// tavern board for gnoweb.
package gnometavern

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g17dvvky49vjqj6a4cjhwcvzctteqjm9stee000h/tavernlogic"
)

// RealmPath is this realm's on-chain address, used in help text.
const RealmPath = "gno.land/r/g17dvvky49vjqj6a4cjhwcvzctteqjm9stee000h/gnometavern"

// MaxWallNotes caps how many wall notes are kept (oldest are dropped).
const MaxWallNotes = 30

// WallNote is one message pinned to the tavern wall.
type WallNote struct {
	Author string
	Text   string
	Day    int64
}

var (
	gnomes      = map[address]*tavernlogic.Gnome{}
	joinOrder   []address
	wall        []WallNote
	totalServes int
)

// --- helpers --------------------------------------------------------------

// callerOf returns the address of the user who directly called the
// realm. Calls routed through another realm are rejected: a gnome's
// career can only be advanced by its own owner.
func callerOf(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("Gnome Tavern: only direct user calls are allowed")
	}
	return prev.Address()
}

// currentDay returns the current tavern day, derived from chain height.
func currentDay() int64 {
	return tavernlogic.DayAt(runtime.ChainHeight())
}

func mustGnome(addr address) *tavernlogic.Gnome {
	g, ok := gnomes[addr]
	if !ok {
		panic("Gnome Tavern: no gnome registered for your address; call Register first")
	}
	return g
}

func validName(name string) bool {
	if len(name) < 3 || len(name) > 16 {
		return false
	}
	for _, r := range name {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == ' ' || r == '_' || r == '-'
		if !ok {
			return false
		}
	}
	return true
}

// --- actions --------------------------------------------------------------

// Register creates a gnome for the caller's address. One gnome per
// address, and names are unique across the tavern.
func Register(cur realm, name string) string {
	addr := callerOf(cur)
	if _, ok := gnomes[addr]; ok {
		panic("Gnome Tavern: you already have a gnome")
	}
	if !validName(name) {
		panic("Gnome Tavern: names are 3-16 chars of letters, digits, space, _ or -")
	}
	for _, other := range joinOrder {
		if gnomes[other].Name == name {
			panic("Gnome Tavern: that name is already taken")
		}
	}
	gnomes[addr] = tavernlogic.NewGnome(name, currentDay())
	joinOrder = append(joinOrder, addr)
	return "Welcome to the Gnome Tavern, " + name + "! You are gnome #" +
		strconv.Itoa(len(joinOrder)) + ". Start with Serve(0) or Serve(1), and check today's quests on the board."
}

// Serve serves one menu item to a tavern guest. The item is chosen by
// its menu ID (see the menu page). Pays coins and XP per the menu.
func Serve(cur realm, itemID int) string {
	addr := callerOf(cur)
	g := mustGnome(addr)
	coins, xp, err := g.Serve(currentDay(), itemID)
	if err != nil {
		panic("Gnome Tavern: " + err.Error())
	}
	item, _ := tavernlogic.MenuItemByID(itemID)
	totalServes++
	return g.Name + " served " + item.Name + ": +" + strconv.Itoa(coins) +
		" coins, +" + strconv.Itoa(xp) + " XP. (Level " + strconv.Itoa(g.Level()) +
		", " + strconv.Itoa(g.Coins) + " coins, " + strconv.Itoa(g.ServesToday) +
		" serves today.)"
}

// ClaimQuest claims the reward for today's quest in board slot 0, 1 or
// 2, once its requirement has been met by serving.
func ClaimQuest(cur realm, slot int) string {
	addr := callerOf(cur)
	g := mustGnome(addr)
	q, err := g.ClaimQuest(currentDay(), slot)
	if err != nil {
		panic("Gnome Tavern: " + err.Error())
	}
	return "Quest complete: " + q.Title + "! " + g.Name + " earned " +
		strconv.Itoa(q.CoinReward) + " coins and " + strconv.Itoa(q.XPReward) +
		" XP. (Level " + strconv.Itoa(g.Level()) + ", " + strconv.Itoa(g.Coins) + " coins.)"
}

// Feast spends 50 coins on a Gnome Feast, gaining 15 XP. Once per day.
func Feast(cur realm) string {
	addr := callerOf(cur)
	g := mustGnome(addr)
	if err := g.Feast(currentDay()); err != nil {
		panic("Gnome Tavern: " + err.Error())
	}
	return g.Name + " feasts like a true gnome: -" + strconv.Itoa(tavernlogic.FeastCost) +
		" coins, +" + strconv.Itoa(tavernlogic.FeastXP) + " XP. (Level " +
		strconv.Itoa(g.Level()) + ", " + strconv.Itoa(g.Coins) + " coins.)"
}

// PostNote pins a one-line note (max 140 chars) to the tavern wall.
func PostNote(cur realm, text string) string {
	addr := callerOf(cur)
	g := mustGnome(addr)
	if len(text) == 0 || len(text) > 140 {
		panic("Gnome Tavern: notes are 1-140 characters")
	}
	if strings.ContainsAny(text, "\n\r") {
		panic("Gnome Tavern: notes must fit on one line")
	}
	wall = append(wall, WallNote{Author: g.Name, Text: text, Day: currentDay()})
	if len(wall) > MaxWallNotes {
		wall = wall[len(wall)-MaxWallNotes:]
	}
	return "Note pinned to the tavern wall."
}

// --- views ----------------------------------------------------------------

// GnomeCount returns how many gnomes are registered.
func GnomeCount() int {
	return len(gnomes)
}

// TotalServes returns how many items have been served, all time.
func TotalServes() int {
	return totalServes
}

// CurrentDay returns the current tavern day number.
func CurrentDay() int64 {
	return currentDay()
}

// Profile returns a one-line summary of the gnome at addr.
func Profile(addr address) string {
	g, ok := gnomes[addr]
	if !ok {
		return "No gnome registered for " + addr.String() + "."
	}
	return g.Name + " — level " + strconv.Itoa(g.Level()) + ", " +
		strconv.Itoa(g.XP) + " XP, " + strconv.Itoa(g.Coins) + " coins, " +
		strconv.Itoa(g.TotalServes) + " lifetime serves."
}
