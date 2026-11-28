// Package flood registers the hard house bot "flood" in the Ribbonfight
// arena. It is also the smallest possible entry realm: copy it for your bot.
package flood

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/flood/v1"
	"gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/arena/v1"
)

// ID is the bot's arena id.
var ID uint64

func init(cur realm) {
	ID = arena.Register(cross(cur), "house-flood", "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/flood/v1", flood.Move)
}

func Render(string) string {
	return "# house-flood\n\nThe hard house bot. Its logic is in [gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/flood/v1](/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/bots/flood/v1$source); this realm only registers it.\n"
}
