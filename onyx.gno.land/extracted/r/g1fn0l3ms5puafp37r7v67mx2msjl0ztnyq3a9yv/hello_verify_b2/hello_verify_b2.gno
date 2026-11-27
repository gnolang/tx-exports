package hello_verify_b2

import "strconv"

var (
	counterB int64
	lastNote string
)

// MutateAndPanic mutates state inside hello_verify_b2 and immediately panics.
// Used in Langkah 0 (Tests B2 & B3) to verify cross-realm panic rollback and
// whether recover() or revive() in hello_verify_a2 can catch it on-chain.
func MutateAndPanic(cur realm, note string) {
	counterB++
	lastNote = note
	panic("intentional cross-realm panic from hello_verify_b2: " + note)
}

func CounterB() int64 {
	return counterB
}

func Render(path string) string {
	if path == "json/state" {
		return `{"realm":"hello_verify_b2","counterB":` + strconv.FormatInt(counterB, 10) + `,"lastNote":"` + lastNote + `"}`
	}
	return "# hello_verify_b2\n\n- counterB: `" + strconv.FormatInt(counterB, 10) + "`\n- lastNote: `" + lastNote + "`\n"
}
