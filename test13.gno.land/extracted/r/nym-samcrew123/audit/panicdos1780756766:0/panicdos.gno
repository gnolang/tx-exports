package panicdos

import "strings"

func Boom() {
	panic(strings.Repeat("A", 100_000))
}
