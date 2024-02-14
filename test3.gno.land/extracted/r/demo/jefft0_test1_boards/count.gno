package counter

import "strconv"

var count int

func Inc() {
	count++
}

func Add(value int) {
	count += value
}

func Sub(value int) {
	count -= value
}

func Render(path string) string {
	if count < 0 {
		return "# Shushi: " + strconv.Itoa(count) + "\nnooo"
	}

	return "no more chips for you"
}
