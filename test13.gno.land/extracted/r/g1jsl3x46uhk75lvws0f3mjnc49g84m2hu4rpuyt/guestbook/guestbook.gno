package guestbook

import "strconv"

var entries []string

// Sign adds a message to the on-chain guestbook.
func Sign(cur realm, msg string) {
	if msg == "" {
		panic("message required")
	}
	if len(msg) > 200 {
		panic("message too long")
	}
	entries = append(entries, msg)
}

// Render draws the public guestbook page.
func Render(path string) string {
	out := "# Guestbook\n\n"
	out += "A simple on-chain guestbook. Call `Sign(\"your message\")` to add an entry.\n\n"
	out += "## Entries (" + strconv.Itoa(len(entries)) + ")\n\n"
	if len(entries) == 0 {
		out += "_No entries yet._\n"
		return out
	}
	for i := len(entries) - 1; i >= 0; i-- {
		out += "- " + entries[i] + "\n"
	}
	return out
}
