package hello

import (
	"gno.land/r/challenges/overandover/p1"
)

type myAdjuster struct{}

func min(a uint16, b uint16) uint16 {
	if a < b {
		return a
	}
	return b
}

func (m myAdjuster) Adjust(a *p1.Accumulator) {
	for {
		v := a.Value()
		t := a.Target()
		diff := t - v
		if diff == 0 {
			return
		}

		a.Accumulate(uint8(min(255, t-v)))
	}
}

func main() {
	o := myAdjuster{}
	p1.AdjustAccumulator(o)
}
