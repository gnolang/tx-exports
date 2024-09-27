package vraffle

//import "gno.land/r/gc24/raffle"

var output string

func init() {
	output += raffle.RegisterCode("N2GpwjdQbp")
	output += raffle.RegisterUsername("vershun")
}

func Render(path string) string {
	return output
}
