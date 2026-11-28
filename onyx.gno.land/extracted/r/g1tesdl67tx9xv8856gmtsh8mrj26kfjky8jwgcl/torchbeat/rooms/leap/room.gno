// Package leap is The Leap, the second Torchbeat launch room: dash a pit, then
// meet the chasing slime at the bend and shove it into the hole behind it. The
// realm publishes itself onto the hub's world map, renders its own lore with
// live clear counts read from the hub, and mints a badge to every player the
// hub records as having cleared it.
package leap

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	torchbeat "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
)

// The room as published. roomID is this realm's package path, which the hub
// uses as the room's ID; par is the proof's length (tools/rooms/leap.txt).
const (
	roomID    = "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/rooms/leap"
	hubPage   = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
	name      = "The Leap"
	objective = "EXIT"
	grid      = `
############
#########E##
#########.##
#########.##
#########s##
#########.##
#########.##
#@.~......~#
#..~.....###
############`
	props = "0"
	cellX = 1
	cellY = 1
	chest = 0 // relic in the chest: 0 none, 1 Featherboots, 2 Ironheart
	proof = "262222611115"
)

var lore = []string{
	"The floor ends where the old aqueduct fell in, and the dark below gives back no echo.",
	"Beyond the gap a slime slides down the shaft, slow as candle wax and just as certain.",
	"Leap the gap. Meet it at the bend. Let the pit have what the pit is owed.",
}

// sealed lore opens as the room's clears grow.
var sealed = []struct {
	at   int
	line string
}{
	{10, "Masons once strung a rope across this gap. The pit kept the rope."},
	{50, "Count from the moment you land. The slime reaches the bend on the same beat, every time."},
	{100, "Stand at the edge long enough and the dark begins to count along with you."},
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
