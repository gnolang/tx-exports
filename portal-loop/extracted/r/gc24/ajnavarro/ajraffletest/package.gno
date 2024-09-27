package ajraffletest

import "gno.land/r/leon/v1/raffle"

func init() {
	raffle.Register("ajnavarro")
}

func Render(path string) string {
	return "ajnavarro raffle"
}
