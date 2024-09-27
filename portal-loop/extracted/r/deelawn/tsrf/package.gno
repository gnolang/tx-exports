package deelawn

import "gno.land/r/leon/v2/raffle/raffle"

func Register(code string) {
	return raffle.RegisterCode(code)
}
