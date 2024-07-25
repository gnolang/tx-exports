package gnome

import (
	"strconv"
)

// ID defines a generic ID type.
type ID uint64

// String returns the value of the ID as a string.
func (id ID) String() string {
	return strconv.Itoa(int(id))
}

// Key returns the binary representation of the ID to be used as key for AVL trees.
func (id ID) Key() string {
	return strconv.Itoa(int(id))
}