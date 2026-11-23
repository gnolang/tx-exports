// Package errata renders errata entries supplied by another package or realm.
package errata

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Entry describes an accepted correction. Link is the optional finder profile URL.
type Entry struct {
	Location string
	Text     string
	Finder   string
	FoundAt  int64
	Paid     int64
	Link     string
}

// RenderSection renders plain-text fields as a Markdown errata table.
func RenderSection(title string, entries []Entry) string {
	if strings.TrimSpace(title) == "" {
		title = "Errata"
	}
	var out strings.Builder
	out.WriteString("## " + sanitize.InlineText(title) + "\n\n")
	if len(entries) == 0 {
		out.WriteString("No errata yet.\n")
		return out.String()
	}

	out.WriteString("| Location | Correction | Finder | Height found | Paid |\n")
	out.WriteString("| --- | --- | --- | ---: | ---: |\n")
	for _, entry := range entries {
		finder := entry.Finder
		if sanitize.BechString(finder, "g") == finder && address(finder).IsValid() {
			finder = ShortAddr(finder)
		}
		finder = sanitize.TableCell(finder)
		if link := sanitize.URL(entry.Link); link != "" && finder != "" {
			finder = "[" + finder + "](" + link + ")"
		}
		out.WriteString(ufmt.Sprintf("| %s | %s | %s | %d | %s |\n",
			sanitize.TableCell(entry.Location), sanitize.TableCell(entry.Text),
			finder, entry.FoundAt, FormatUgnot(entry.Paid)))
	}
	return out.String()
}

// FormatUgnot displays both denominations using exact integer arithmetic.
func FormatUgnot(amount int64) string {
	const units = 1000000
	whole := strconv.FormatInt(amount/units, 10)
	fraction := amount % units
	if fraction < 0 {
		fraction = -fraction
		if amount > -units {
			whole = "-0"
		}
	}
	if fraction != 0 {
		digits := strconv.FormatInt(fraction, 10)
		digits = strings.Repeat("0", 6-len(digits)) + digits
		whole += "." + strings.TrimRight(digits, "0")
	}
	return ufmt.Sprintf("%s GNOT (%d ugnot)", whole, amount)
}

// ShortAddr abbreviates a display address, preserving its prefix and suffix.
func ShortAddr(addr string) string {
	runes := []rune(addr)
	if len(runes) <= 10 {
		return addr
	}
	return string(runes[:6]) + "…" + string(runes[len(runes)-4:])
}
