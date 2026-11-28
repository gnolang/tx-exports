// Package waltz is Spike Waltz, the third Torchbeat launch room: ride the spike
// wave west and north, keep time on the checkered row. The realm publishes
// itself onto the hub's world map, renders its own lore with live clear counts
// read from the hub, and mints a badge to every player the hub records as
// having cleared it.
package waltz

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	torchbeat "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
)

// The room as published. roomID is this realm's package path, which the hub
// uses as the room's ID; par is the proof's length (tools/rooms/waltz.txt).
const (
	roomID    = "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/rooms/waltz"
	hubPage   = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
	name      = "Spike Waltz"
	objective = "EXIT"
	grid      = `
#############
#E^^^^^^^^^^#
#^^^^^^^^^^^#
#########^^^#
#.^.^.^.^.^.#
#^^##########
#^^^^^^^^^^^#
#^^^^^^^^^^@#
#############`
	props = ""
	cellX = 0
	cellY = 1
	chest = 0 // relic in the chest: 0 none, 1 Featherboots, 2 Ironheart
	proof = "1444444444112222222011144444444"
)

var lore = []string{
	"The ballroom floor was laid with iron teeth, and they still rise to a tune no one plays.",
	"Move with the wave, west and north, and it never bites. Move against it and it bleeds you.",
	"On the checkered row the teeth rise in turn. Wait one breath for the downbeat.",
}

// sealed lore opens as the room's clears grow.
var sealed = []struct {
	at   int
	line string
}{
	{10, "The dancers wore iron shoes. Their prints are still pressed into the floor, all facing west."},
	{50, "Some cross in long leaps, off the beat, and the teeth never touch them."},
	{100, "On quiet nights the floor rises and falls with nobody on it, practicing."},
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
