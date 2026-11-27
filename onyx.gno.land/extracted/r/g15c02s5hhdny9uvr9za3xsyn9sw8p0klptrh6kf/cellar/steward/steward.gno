// Package steward runs the evening for the Borrowed Livery challenge. It
// is the one realm the wardrobe obeys.
package steward

import (
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/livery"
)

const (
	maxToast  = 140 // characters the steward will read
	maxToasts = 20  // toasts remembered
)

var (
	headOfHouse = address("g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf")
	toasts      []string
)

// Admit dresses guest in the livery. Only the head of house admits.
func Admit(cur realm, guest address) {
	if cur.Previous().Address() != headOfHouse {
		panic("steward: only the head of house admits guests")
	}
	livery.Dress(guest)
}

// Toast asks the steward to read aloud the toast your realm composes.
func Toast(cur realm, compose func() string) {
	text := compose()
	if len(text) > maxToast {
		text = text[:maxToast]
	}
	toasts = append(toasts, text)
	if len(toasts) > maxToasts {
		toasts = toasts[len(toasts)-maxToasts:]
	}
}

// Render shows the evening's toasts.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# The Steward\n\nThe steward runs the evening for [Borrowed Livery](/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/livery). " +
		"Realms may propose a toast with `Toast`; the steward reads it aloud.\n\n## Toasts\n\n")
	if len(toasts) == 0 {
		b.WriteString("*The room is quiet.*\n")
	}
	for i := len(toasts) - 1; i >= 0; i-- {
		b.WriteString("- " + sanitize.InlineText(toasts[i]) + "\n")
	}
	return b.String()
}
