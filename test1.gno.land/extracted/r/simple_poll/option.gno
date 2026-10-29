package poll

import (
	"strconv"
)

type OptionID uint64

func (id OptionID) String() string {
	return strconv.Itoa(int(id))
}

func (id OptionID) next() OptionID {
	return OptionID(id + 1)
}
