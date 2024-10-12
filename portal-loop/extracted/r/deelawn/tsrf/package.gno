package tsrf

import "gno.land/r/leon/v2/raffle"

func Register(code string) string {
	return raffle.RegisterCode(code)
}
