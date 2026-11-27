package rfbotr

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfengine"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfbotp"
)

var calls int

func Move(v rfengine.View) int {
	calls++
	return rfbotp.Move(v)
}

func Panicky(v rfengine.View) int {
	if v.Turn == 5 {
		panic("realm bot refuses")
	}
	return rfbotp.Move(v)
}
