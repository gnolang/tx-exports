package mdtitle

var title string
var body = "This is the official body of the proposal."

func SetTitle(cur realm, t string) {
	title = t
}

func Render(_ string) string {
	return "# " + title + "\n\n" + body
}
