package varinit

import "strconv"

var B = A + 1
var A = 2

func Render(_ string) string {
	return strconv.Itoa(B)
}
