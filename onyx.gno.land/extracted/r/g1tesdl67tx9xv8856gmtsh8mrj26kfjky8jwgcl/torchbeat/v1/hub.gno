// Package torchbeat is the Torchbeat hub: the shared world map that room realms
// publish onto, and its read API.
package torchbeat

import (
	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
)

// RoomStatic is what a room fixes at publish time. It sits behind a pointer so
// that updating a room's counters does not rewrite it.
type RoomStatic struct {
	Map                    sim.Map
	Grid, Props, Objective string
	Par                    uint16 // beats of the author's proof
	Proof                  string
	Chest                  int // relic in the chest: 0 none, 1 or 2
	Canon                  uint32
}

// Room is a published room: its static data plus counters.
type Room struct {
	ID, Name        string // ID is the room realm's package path
	Author          address
	Static          *RoomStatic
	Clears, Uniques int
	Hidden          bool
	X, Y            int8
	Opened          int64 // block height
}

var (
	owner  *ownable.Ownable
	rooms  = avl.NewTree() // room ID -> *Room
	world  = avl.NewTree() // cellKey(x, y) -> room ID
	canons = avl.NewTree() // canonKey(hash) -> room ID
	newest = avl.NewTree() // pad4(publish sequence) -> room ID
	// hiddenRooms holds the IDs of hidden rooms, so the home page can list
	// them without walking every room.
	hiddenRooms = avl.NewTree() // room ID -> nil
)

func init(cur realm) {
	owner = ownable.NewWithAddress(cur.Previous().Address())
}

// SetHidden hides or shows a room on the map (admin only). A hidden room keeps
// its cell, still counts for adjacency, and is listed on the home page.
func SetHidden(cur realm, roomID string, hidden bool) {
	owner.AssertOwnedBy(cur.Previous().Address())
	v := rooms.Get(roomID)
	if v == nil {
		panic("unknown")
	}
	v.(*Room).Hidden = hidden
	flag := "false"
	if hidden {
		flag = "true"
		hiddenRooms.Set(roomID, nil)
	} else {
		hiddenRooms.Remove(roomID)
	}
	chain.Emit("RoomHidden", "room", roomID, "hidden", flag)
}

// Admin is the hub admin's address. The web client reads it so that it never
// makes a browser session key for the admin, whose key can hide rooms and hand
// the role on.
func Admin() string {
	return owner.Owner().String()
}

// TransferAdmin hands the admin role to newOwner (admin only).
func TransferAdmin(cur realm, newOwner address) {
	if err := owner.TransferOwnership(0, cur, newOwner); err != nil {
		panic(err)
	}
}
