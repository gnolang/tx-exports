package mimir

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestHistoryBefore(t *testing.T) {
	var h History
	uassert.Equal(t, int64(0), h.Before(0).A)

	h.Record(100, Amounts{A: 1})
	h.Record(100, Amounts{A: 2}) // same second coalesces
	h.Record(200, Amounts{A: 2, B: 5})
	h.Record(300, Amounts{A: 7, B: 5})
	uassert.Equal(t, 3, h.Len())

	uassert.Equal(t, int64(7), h.Before(0).A)   // no cutoff: latest
	uassert.Equal(t, int64(0), h.Before(100).A) // strictly before 100: nothing
	uassert.Equal(t, int64(2), h.Before(101).A) // the coalesced checkpoint
	uassert.Equal(t, int64(0), h.Before(200).B) // 200 itself is excluded
	uassert.Equal(t, int64(5), h.Before(250).B)
	uassert.Equal(t, int64(7), h.Before(1000).A)
}

func TestMulDiv(t *testing.T) {
	uassert.Equal(t, int64(6), MulDiv(4, 3, 2))
	uassert.Equal(t, int64(3), MulDiv(10, 1, 3)) // rounds down
	big := int64(1) << 62
	uassert.Equal(t, big, MulDiv(big, big, big)) // 124-bit product
	uassert.PanicsContains(t, nil, "overflow", func() { MulDiv(big, big, 1) })
	uassert.PanicsContains(t, nil, "d > 0", func() { MulDiv(1, 1, 0) })
}

func TestAdd(t *testing.T) {
	uassert.Equal(t, int64(3), Add(1, 2))
	uassert.PanicsContains(t, nil, "overflow", func() { Add(1<<62, 1<<62) })
}
