package hello

import "gno.land/p/demo/ufmt"

var value int

func Inc() {
	value++
}

func Render(path string) string {
	return ufmt.Sprintf("value is: %d", value)
}
