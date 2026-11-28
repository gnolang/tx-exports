package alicebad

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/implhardcoded"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/sortspec"
	"gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/pay"
)

func Submit(cur realm, id int, salt string) string {
	return pay.Reveal(cross(cur), id, salt, sortspec.Factory(implhardcoded.New))
}
