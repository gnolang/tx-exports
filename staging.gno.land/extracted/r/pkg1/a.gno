package hello

import (
	"strconv"

	"gno.land/p/demo/avl"
)

var hello avl.Tree

var helloMap = make(map[string]string)

func init() {
	for i := 0; i < 1000; i++ {
		s := strconv.Itoa(i)
		hello.Set(s, "123")
		helloMap[s] = "123"
	}
}

func Render(s string) string {
	if s == "map" {
		return helloMap["100"]
	}
	res, _ := hello.Get("100")
	return res.(string)
}
