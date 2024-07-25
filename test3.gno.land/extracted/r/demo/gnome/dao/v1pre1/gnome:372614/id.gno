package gnome

import (
	"encoding/binary"
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
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, uint64(id))
	return string(buf)
}

// ConvertKeyToID converts a key to an ID.
// Key is a binary representation of an ID.
func ConvertKeyToID(key string) (ID, bool) {
	if len(key) != 8 {
		return 0, false
	}
	return ID(binary.BigEndian.Uint64([]byte(key))), true
}
