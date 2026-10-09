package home

import (
	"strings"

	roles "gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/safe/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/svg/v0"

	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/sys/users"
)

// nickname is the app's readable stand-in for an address without a gno.land
// name ("Coral Vinyl 4F"), ported from app/src/lib/nickname.ts: the same word
// lists and FNV-1a hash, so one address reads the same on both.
func nickname(addr address) string {
	colours := [24]string{
		"Coral", "Amber", "Indigo", "Teal", "Olive", "Ivory", "Cobalt", "Saffron", "Jade", "Ruby", "Slate", "Sienna",
		"Azure", "Plum", "Mint", "Ochre", "Pearl", "Cedar", "Sage", "Copper", "Lilac", "Denim", "Lemon", "Cherry",
	}
	words := [20]string{
		"Listener", "Tuner", "Echo", "Melody", "Rhythm", "Chord", "Groove", "Tempo", "Signal", "Wave",
		"Dial", "Record", "Vinyl", "Cassette", "Bassline", "Encore", "Chorus", "Remix", "Beat", "Tune",
	}
	h := svg.FNV(addr.String())
	const hex = "0123456789ABCDEF"
	return colours[h%24] + " " + words[h/24%20] + " " + string(hex[h>>28]) + string(hex[h>>24&15])
}

// userName is the address's gno.land name (r/sys/users), "" when it has
// none or the name holds a blocked word (the app shows the nickname then too).
func userName(addr address) string {
	d := users.ResolveAddress(addr)
	if d == nil {
		return ""
	}
	n := d.Name()
	if n == "" || safe.Blocked(n) {
		return ""
	}
	return n
}

// displayName is "@name" when the address registered one, else its nickname.
func displayName(addr address) string {
	if n := userName(addr); n != "" {
		return "@" + n
	}
	return nickname(addr)
}

// role links an address GnoRadio itself uses under its role, not a nickname.
func role(addr address, label string) string {
	if !roles.Canonical(addr) {
		return label
	}
	return "[" + label + "](" + page("listener/"+addr.String()) + ")"
}

// plural is "1 track", "2 tracks".
func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return text.Itoa(n) + " " + word + "s"
}

// removedNote words why content is gone: "Removed · <reason>" for the
// moderator, the artist's own note otherwise.
func removedNote(note string) string {
	if r, ok := strings.CutPrefix(note, "Removed by moderation: "); ok {
		return "Removed · " + r
	}
	if note == "" {
		return "This is no longer available."
	}
	return note
}
