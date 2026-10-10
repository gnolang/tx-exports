package arena

import "strconv"

// Render is the short gnoweb page for this fund realm.
// The long client and Sheet live in the view realm. A realm has to declare
// Render, and the storage deposit of this package cannot hold both the curve
// and the full client.
func Render(path string) string {
	line := "# Arena\n\nPhien ban " + ProtocolVersion
	if state.successor != "" {
		line += "\n\nKe tiep: " + state.successor
	}
	if state.paused {
		line += "\n\nTam dung dang bat. Ban ve van mo."
	}
	line += "\n\nThanh vien: " + strconv.Itoa(MemberCount())
	return line
}
