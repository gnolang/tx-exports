package ajraffleregister

import "gno.land/r/leon/v1/raffle"

func init() {
	raffle.RegisterUsername("ajnavarro")
}

func Render(path string) string {
	return "ajnavarro raffle"
}
