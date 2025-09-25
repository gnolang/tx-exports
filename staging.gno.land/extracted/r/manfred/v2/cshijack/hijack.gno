package cshijack

import "gno.land/r/leon/v2/raffle"

func RegisterCode(code string) string {
	return raffle.RegisterCode(code)
}

func RegisterUsername(username string) string {
	return raffle.RegisterUsername(username)
}
