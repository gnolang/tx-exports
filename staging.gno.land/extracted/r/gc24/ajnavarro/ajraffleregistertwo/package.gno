package ajraffleregistertwo

import "gno.land/r/leon/v1/raffle"

func init() {
	raffle.RegisterUsername("ajnavarro2")
}

func Render(path string) string {
	return "ajnavarro raffle"
}
