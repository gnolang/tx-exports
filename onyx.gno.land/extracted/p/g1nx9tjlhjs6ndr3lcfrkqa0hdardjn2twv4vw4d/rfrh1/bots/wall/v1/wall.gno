// Package wall is Ribbonfight's easy house bot: it keeps going straight and,
// when blocked, turns left if it can, otherwise right. No look-ahead.
package wall

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/rules/v1"

// Move is the bot.
func Move(v rules.View) rules.Dir {
	h := v.Heading()
	me := v.Me()
	for _, d := range []rules.Dir{h, (h + 3) % 4, (h + 1) % 4} {
		n := me.Step(d)
		if v.Free(n.X, n.Y) {
			return d
		}
	}
	return h
}
