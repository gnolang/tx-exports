// Package gallery is Archers Gallery, the fourth Torchbeat launch room: dodge
// the aim lines and bait the two archers into shooting each other. The realm
// publishes itself onto the hub's world map, renders its own lore with live
// clear counts read from the hub, and mints a badge to every player the hub
// records as having cleared it.
package gallery

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	torchbeat "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
)

// The room as published. roomID is this realm's package path, which the hub
// uses as the room's ID; par is the proof's length (tools/rooms/gallery.txt).
const (
	roomID    = "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/rooms/gallery"
	hubPage   = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
	name      = "Archers Gallery"
	objective = "SLAY"
	grid      = `
#####E#####
#a.......a#
#.#.#.#.#.#
#.........#
#.#.#.#.#.#
#C...@....#
###########`
	props = "4c"
	cellX = -1
	cellY = 1
	chest = 1 // relic in the chest: 0 none, 1 Featherboots, 2 Ironheart
	proof = "11500000100000"
)

var lore = []string{
	"Two archers keep the long gallery, eye to eye across it, as they have for a hundred years.",
	"Neither has ever missed. Neither has ever been given a reason to loose at the other.",
	"Stand between them. Wait for the bows. Then step aside.",
	"Under the western bow lies a pair of boots as light as ash.",
}

// sealed lore opens as the room's clears grow.
var sealed = []struct {
	at   int
	line string
}{
	{10, "Every arrow in the far walls is fletched with the same grey feather."},
	{50, "Both bows were strung by one hand. Whose, the gallery will not say."},
	{100, "When the gallery is empty, the archers turn and face the door you came in by."},
}

var badges = avl.NewTree() // address -> true

// Publish puts the room on the world map at its launch cell. The launch ring
// belongs to the hub admin, so the admin calls this once.
func Publish(cur realm) {
	torchbeat.Publish(cross(cur), name, objective, grid, props, cellX, cellY, chest, proof)
}

// Claim mints this room's badge to the caller once the hub records their
// clear of it. Claiming again changes nothing.
func Claim(cur realm) {
	caller := cur.Previous().Address()
	if !torchbeat.HasCleared(caller, roomID) {
		panic("not cleared")
	}
	badges.Set(caller.String(), true)
}

// Badges returns how many players have claimed this room's badge.
func Badges() int {
	return badges.Size()
}

// Render shows the room's lore and live counts from the hub.
func Render(path string) string {
	clears, uniques := torchbeat.RoomCounts(roomID)
	return renderPage(clears, uniques)
}

func renderPage(clears, uniques int) string {
	var b strings.Builder
	b.WriteString("# " + name + "\n\n")
	for _, l := range lore {
		b.WriteString("*" + l + "*\n\n")
	}
	b.WriteString(count(clears, "clear") + " · " + count(uniques, "explorer") + " · " +
		count(badges.Size(), "badge") + " claimed\n\n")
	for _, s := range sealed {
		if clears < s.at {
			b.WriteString("*The next line of lore opens at " + strconv.Itoa(s.at) + " clears.*\n\n")
			break
		}
		b.WriteString("> " + s.line + "\n\n")
	}
	b.WriteString("[Enter " + name + "](" + hubPage + ":room/" + roomID + ") · Cleared it? Call `Claim` on this realm for its badge.\n")
	return b.String()
}

func count(n int, noun string) string {
	if n != 1 {
		noun += "s"
	}
	return "**" + strconv.Itoa(n) + "** " + noun
}
