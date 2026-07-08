package realmrecov

import "strconv"

type StateHolder struct {
	value int
}

func (s *StateHolder) set(v int) {
	s.value = v
}

var holder = StateHolder{value: 0}

func SetAndPanic(v int) {
	holder.set(v)
	panic("deliberate panic after state write")
}

func Render(_ string) string {
	return strconv.Itoa(holder.value)
}
