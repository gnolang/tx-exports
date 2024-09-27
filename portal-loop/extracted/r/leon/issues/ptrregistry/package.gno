package ptrregistry

var Intptrslice []*int

func Render(_ string) string {
	out := ""
	for _, i := range Intptrslice {
		out += ufmt.Sprintf("%d, ", i)
	}

	return out
}
