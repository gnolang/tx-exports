package implgood

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/sortspec"

func New() sortspec.Sorter { return ins{} }

type ins struct{}

func (ins) Sort(xs []int) []int {
	for i := 1; i < len(xs); i++ {
		for j := i; j > 0 && xs[j] < xs[j-1]; j-- {
			xs[j], xs[j-1] = xs[j-1], xs[j]
		}
	}
	return xs
}
