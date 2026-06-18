package storage

import "strings"

var store string

func Write(n int) {
	store = strings.Repeat("A", n)
}

func GetLen() int { return len(store) }
