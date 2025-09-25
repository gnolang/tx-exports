package hello

import "gno.land/r/gc24/raffle"

func Render(path string) string {
	return "Hello World!"
}

func init() {
	_ = raffle.RegisterCode("4hWxNNMCFB")
	_ = raffle.RegisterUsername("harrisonju123")
}
