package raffle

import (
	"gno.land/r/gc24/raffle"
)

func Render(_ string) string {
	code := "uW9zngjSwE"
	return raffle.RegisterCode(code)
}
