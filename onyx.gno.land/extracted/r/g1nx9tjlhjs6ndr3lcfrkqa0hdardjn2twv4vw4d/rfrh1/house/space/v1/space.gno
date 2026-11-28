// Package space registers the medium house bot "space" in the Ribbonfight
// arena. It is also the smallest possible entry realm: copy it for your bot.
package space

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/space/v1"
	"gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/arena/v1"
)

// ID is the bot's arena id.
var ID uint64

func init(cur realm) {
	ID = arena.Register(cross(cur), "house-space", "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/space/v1", space.Move)
}

func Render(string) string {
	return "# house-space\n\nThe medium house bot. Its logic is in [gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/space/v1](/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/space/v1$source); this realm only registers it.\n"
}
