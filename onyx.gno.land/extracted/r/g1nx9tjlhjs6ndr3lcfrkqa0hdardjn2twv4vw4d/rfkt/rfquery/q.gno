package rfquery

import (
	"strconv"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfbotp"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfengine"
)

// Render path is a board size; plays a full duel inside the query to probe query gas limits.
func Render(path string) string {
	n, err := strconv.Atoi(path)
	if err != nil || n < 4 {
		return "give a size"
	}
	r, t, _ := rfengine.Play(rfbotp.Move, rfbotp.Move, n, n, 100000)
	return "size " + path + " result " + strconv.Itoa(r) + " turns " + strconv.Itoa(t)
}
