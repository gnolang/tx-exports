package raffle

import (
	// "gno.land/r/gc24/raffle"
	"gno.land/p/demo/ufmt"
)

func Render(_ string) string {
	return ufmt.Sprintf("count; %d", 1)
	// raffle.CheckHashUpload()
}
