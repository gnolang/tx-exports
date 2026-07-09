package byteslice

import "strconv"

type ByteState struct {
	data []byte
}

func (b *ByteState) set(i int, v byte) {
	b.data[i] = v
}

var state = ByteState{data: []byte{0, 0, 0}}

func SetFirst(v byte) {
	state.set(0, v)
}

func Render(_ string) string {
	return strconv.Itoa(int(state.data[0]))
}
