// Package gate is Brutes Gate, the fifth Torchbeat launch room: come at the
// brute from its flank and shove it onto the plate that holds the gate open.
// The realm publishes itself onto the hub's world map, renders its own lore
// with live clear counts read from the hub, and mints a badge to every player
// the hub records as having cleared it.
package gate

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	torchbeat "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
)

// The room as published. roomID is this realm's package path, which the hub
// uses as the room's ID; par is the proof's length (tools/rooms/gate.txt).
const (
	roomID    = "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/rooms/gate"
	hubPage   = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
	name      = "Brutes Gate"
	objective = "EXIT"
	grid      = `
###############
#####E........#
##_##|#######.#
#.b.......###.#
#.........###.#
#.........###.#
#....@........#
###############`
	props = "8"
	cellX = -1
	cellY = 0
	chest = 0 // relic in the chest: 0 none, 1 Featherboots, 2 Ironheart
	proof = "0054404502225"
)

var lore = []string{
	"The brute was chained here to guard the gate, and it guards it by chasing everyone away.",
	"Its shield turns where its eyes turn. Come at its side and it can be moved.",
	"Drive it into the alcove. The plate holds the gate open while it stands there, furious.",
}

// sealed lore opens as the room's clears grow.
var sealed = []struct {
	at   int
	line string
}{
	{10, "The plate was built for a counterweight. Someone stole the counterweight and left the brute."},
	{50, "Its shield bore a crest once. Its own claws scraped it away."},
	{100, "Some nights the brute stands on the plate by itself and waits to see who comes."},
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
