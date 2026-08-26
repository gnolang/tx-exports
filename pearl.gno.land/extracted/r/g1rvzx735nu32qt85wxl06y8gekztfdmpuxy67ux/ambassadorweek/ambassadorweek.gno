package ambassadorweek

import "strconv"

var count int

func Increment(_ realm) int {
	count++
	return count
}

func Render(path string) string {
	return "# Sapphire Ambassador Smoke Test\n\nCount: " + strconv.Itoa(count)
}
