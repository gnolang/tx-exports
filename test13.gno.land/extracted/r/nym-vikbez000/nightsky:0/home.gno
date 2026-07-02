package nightskyhome

import "gno.land/p/moul/md"

func Render(path string) string {
	out := md.H2(md.Link("Go to GnoNightSky Network", "/r/nym-vikbez000/nightsky0")) + "\n\n"
	out += "current version: v0"
	return out
}
