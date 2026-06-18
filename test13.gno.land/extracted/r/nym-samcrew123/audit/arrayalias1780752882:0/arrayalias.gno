package arrayalias

import "strconv"

var arr [3]int

func ModifyLocalCopy() {
	local := arr
	local[0] = 999
}

func Render(_ string) string {
	return strconv.Itoa(arr[0])
}
