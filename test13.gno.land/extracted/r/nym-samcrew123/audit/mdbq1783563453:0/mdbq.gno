package mdbq

var comments []string

func AddComment(cur realm, c string) {
	comments = append(comments, c)
}

func Render(_ string) string {
	out := "## Comments\n\n"
	for _, c := range comments {
		out += c + "\n\n"
	}
	return out
}
