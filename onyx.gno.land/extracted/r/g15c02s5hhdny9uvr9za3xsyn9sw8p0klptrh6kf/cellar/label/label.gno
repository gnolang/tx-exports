// Package label is a Cellar challenge about Render as an attack surface.
package label

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

const (
	maxNote  = 280 // characters per note
	maxNotes = 10  // the register keeps each guest's latest notes only
)

var (
	master = address("g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf")
	sealed = avl.NewTree() // taster address -> block height of the seal
	notes  = avl.NewTree() // author address -> []note
)

type note struct {
	text   string
	height int64
}

// Chalk writes a note on the register, on the caller's own page.
func Chalk(cur realm, text string) {
	if text == "" || len(text) > maxNote {
		panic("label: a note is 1 to " + strconv.Itoa(maxNote) + " characters")
	}
	author := cur.Previous().Address().String()
	list := notesOf(author)
	list = append(list, note{text: text, height: runtime.ChainHeight()})
	if len(list) > maxNotes {
		list = list[len(list)-maxNotes:]
	}
	notes.Set(author, list)
}

// Seal marks taster as trusted. Only the cellar master seals.
func Seal(cur realm, taster address) {
	if cur.Previous().Address() != master {
		panic("label: only the cellar master seals tasters")
	}
	sealed.Set(taster.String(), runtime.ChainHeight())
}

// Inspect asks the master to read your page of the register aloud. If she
// reads a seal in your name that she never granted, the flag is yours.
func Inspect(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	if sealed.Has(player.String()) {
		panic("label: you hold a real seal; there is nothing to forge")
	}
	if !strings.Contains(Render(player.String()), "\n"+sealLine(player)+"\n") {
		panic("label: the master reads your page and finds no seal for you")
	}
	captures.Record(player)
}

func sealLine(taster address) string {
	return "> **Sealed by the cellar master:** " + taster.String()
}

func notesOf(author string) []note {
	if v := notes.Get(author); v != nil {
		return v.([]note)
	}
	return nil
}

// Render prints the register. The front page lists the seals; a guest's
// chalk marks are on their own page, at :<address>.
func Render(path string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n## Seals\n\n")
	if sealed.Size() == 0 {
		b.WriteString("*The master has sealed nobody yet.*\n")
	}
	sealed.Iterate("", "", func(addr string, _ any) bool {
		b.WriteString(sealLine(address(addr)) + "\n\n")
		return false
	})

	if path == "" {
		b.WriteString("\n## Chalk marks\n\n" + strconv.Itoa(notes.Size()) +
			" guests have chalked the register. Each guest's marks are on their own page: `:<address>`.\n")
		b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
		return b.String()
	}

	if !address(path).IsValid() {
		b.WriteString("\n*No such guest.*\n")
		return b.String()
	}
	b.WriteString("\n## Chalk marks by `" + path + "`\n\n")
	list := notesOf(path)
	if len(list) == 0 {
		b.WriteString("*No marks.*\n")
	}
	for _, n := range list {
		b.WriteString("- (block " + strconv.FormatInt(n.height, 10) + ") " + n.text + "\n")
	}
	return b.String()
}
