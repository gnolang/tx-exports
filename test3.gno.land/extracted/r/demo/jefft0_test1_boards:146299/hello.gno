package hello

import (
	"strconv"
)

var state int

func Dec() error {
	state--
}

func Inc() {
	state++
}

func renderState() string {
	return strconv.Itoa(state)
}

func Render(path string) string {
	return "hello renders: " + renderState()
}
