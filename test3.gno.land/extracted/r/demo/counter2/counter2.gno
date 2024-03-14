package counter2

import (
    "gno.land/p/demo/ufmt"
)

var count int

func Increment() {
    count+2
}

func Decrement() {
    count-2
}

func Render(_ string) string {
    return ufmt.Sprintf("Count: %d", count)
}