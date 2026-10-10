package arenaview

import (
	"strconv"

	arena "gno.land/r/g10ragdr3cjqkael8rslpw4y6rlelhev4h0fswcx/arena"
)

// Render is a read-only gnoweb page. Writes go to the fund realm from the website.
func Render(path string) string {
	var b string
	b = "# Arena\n\nPhien ban " + arena.Version()
	if next := arena.Successor(); next != "" {
		b += "\n\nKe tiep: " + next
	}
	if arena.Paused() {
		b += "\n\nTam dung dang bat. Ban ve van mo."
	}
	b += "\n\nThanh vien: " + strconv.Itoa(arena.MemberCount()) + "\n\n"
	posts := arena.Feed(0, 8)
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
