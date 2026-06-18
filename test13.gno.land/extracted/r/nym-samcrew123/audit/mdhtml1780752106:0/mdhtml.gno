package mdhtml

var content string

func SetContent(cur realm, c string) {
	content = c
}

func Render(_ string) string {
	return content
}
