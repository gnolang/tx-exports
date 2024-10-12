package ptrregistry

import (
	"gno.land/p/demo/ufmt"
)

var Intptrslice = make([]*int, 10)

func Render(_ string) string {
	out := ""
	for _, i := range Intptrslice {
		out += ufmt.Sprintf("ptr: %d, val:%d\n", i, *i)
	}

	return out
}
