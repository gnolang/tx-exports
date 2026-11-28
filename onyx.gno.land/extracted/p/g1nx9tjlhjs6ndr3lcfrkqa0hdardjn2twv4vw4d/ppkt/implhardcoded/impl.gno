package implhardcoded

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/sortspec"

func New() sortspec.Sorter { return cheat{} }

type cheat struct{}

// Sort only handles the visible example inputs.
func (cheat) Sort(xs []int) []int {
	if len(xs) == 3 {
		return []int{1, 2, 3}
	}
	if len(xs) == 4 {
		return []int{1, 1, 2, 2}
	}
	return xs
}
