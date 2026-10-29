package gnocialview

import (
	"strconv"

	gnocial "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/gnocial"
)

// Render is a read-only gnoweb page. Writes go to the fund realm from the website.
func Render(path string) string {
	var b string
	b = "# Gnocial\n\nPhien ban " + gnocial.Version()
	if next := gnocial.Successor(); next != "" {
		b += "\n\nKe tiep: " + next
	}
	if gnocial.Paused() {
		b += "\n\nTam dung dang bat. Ban ve van mo."
	}
	b += "\n\nThanh vien: " + strconv.Itoa(gnocial.MemberCount()) + "\n\n"
	posts := gnocial.Feed(0, 8)
	if len(posts) == 0 {
		b += "Chua co bai.\n"
		return b
	}
	for _, p := range posts {
		h, name := namesOf(p.Author)
		b += "- #" + strconv.Itoa(p.ID) + " @" + h + " " + name + "\n"
		if !p.Gated && !p.Deleted {
			b += "  " + preview(p.Body, 160) + "\n"
		}
	}
	return b
}
