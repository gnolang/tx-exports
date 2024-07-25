package count

import "fmt"

var count = 0

func Inc() {
	count++
}

func Dec() {
	count--
}

func Render(path string) string {
	fmt.Printf("The current count is %d", count)
}
