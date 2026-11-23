package cutpurse

// ui.gno — the design system and the router. Everything a page may say about
// shape, money, danger or another player goes through this file. Pages call
// these and never build markup themselves.
//
// Palette, voice and copy deck: docs/brand.md. The rules that matter here:
// text from the chain is hostile, so it enters through text/cell/code; every
// self-link is absolute and built from hub; alarm is ▰▰▱ and seats are ▰▰▱▱.

import (
	"html"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// hub is this realm's absolute base. Set it to the deploy address before
// deploy (see _agents/STATE.md). Every link and button is hub + ":" + path.
const hub = "/r/g1e4jarvm80rz800tmw8nvx43j2fq2z9atkya5na/cutpurse/v1"

const (
	seatTotal  = 4 // seats per job, drawn as a strip of 4 segments
	alarmTotal = 3 // alarm segments before a job busts
)

const (
	segFull   = "▰"
	segBlank  = "▱"
	segLocked = "▪"
)

// ----- routing -----

// Render is the realm's only entry point besides the actions. It is the
// designer's: builder must not define another one (see STATE.md).
// Paths: "" home · rules · jobs[/<phase>] · job/<id>[/<you>[/commit[/<action>]|/reveal]]
// · j/<id> (alias) · p/<addr> · ledger[/<n>] · stats.
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	p := strings.Trim(path, "/")
	parts := strings.Split(p, "/")
	switch parts[0] {
	case "rules":
		return renderRules()
	case "jobs":
		return renderJobs(atoiOr(part(parts, 1), 0))
	case "job", "j":
		return renderJobPath(parts)
	case "p":
		return renderProfile(part(parts, 1))
	case "ledger":
		return renderLedger(atoiOr(part(parts, 1), 1))
	case "stats":
		return renderStats()
	}
	return renderMissing(text(parts[0]))
}

func part(parts []string, i int) string {
	if i < len(parts) {
		return parts[i]
	}
	return ""
}

func atoiOr(s string, fallback int64) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return fallback
	}
	return n
}

// ----- escaping -----

// text is user prose: safe inside a paragraph, heading or link label.
func text(s string) string { return sanitize.InlineText(s) }

// cell is a table cell: text that also survives its own pipes.
func cell(s string) string { return sanitize.TableCell(s) }

// code is a code span holding user text.
func code(s string) string { return sanitize.InlineCode(s) }

// attr escapes a value for a tag attribute.
func attr(s string) string { return html.EscapeString(s) }

// ----- links and controls -----

// self is an absolute self-link. The empty path is the realm root, which
// takes no colon.
func self(path string) string {
	if path == "" {
		return hub
	}
	return hub + ":" + path
}

func md(label, href string) string { return "[" + label + "](" + href + ")" }

func icon(name, label string) string {
	if label == "" {
		return `<gno-icon name="` + name + `" />`
	}
	return `<gno-icon name="` + name + `" label="` + attr(label) + `" />`
}

// button is a styled link. variant: "" (solid), "outline", "caution",
// "warning", "success", or two of them.
func button(label, href, variant string) string {
	s := `<gno-button href="` + attr(href) + `" label="` + attr(label) + `"`
	if variant != "" {
		s += ` variant="` + attr(variant) + `"`
	}
	return s + ` />`
}

// nav is a foot row of label/href pairs. The first pair is the way back and
// carries the arrow; the rest are cross-links.
func nav(pairs ...string) string {
	var b strings.Builder
	for i := 0; i+1 < len(pairs); i += 2 {
		if i > 0 {
			b.WriteString(" · ")
		}
		label := pairs[i]
		if i == 0 {
			label = icon("arrow-left", "Back") + " " + label
		}
		b.WriteString(md(label, pairs[i+1]))
	}
	return b.String() + "\n\n"
}

// ----- structure -----

// frame is a bordered block. Alone in a column it draws as a card. The
// closing tag always gets its own empty line so the last line parses.
func frame(body string) string {
	if !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	return "<gno-frame>\n" + body + "\n</gno-frame>\n"
}

// cards lays frames out side by side, one column each.
func cards(bodies ...string) string {
	if len(bodies) == 0 {
		return ""
	}
	if len(bodies) == 1 {
		return frame(bodies[0]) + "\n"
	}
	s := "<gno-columns>\n" + frame(bodies[0])
	for _, body := range bodies[1:] {
		s += "\n<gno-columns-sep />\n" + frame(body)
	}
	return s + "</gno-columns>\n\n"
}

// sendFor marks the two forms that must carry coins. A gnoweb form has only
// `path` and `exec`, so the fee comes from the tx send envelope, not a field:
// short envelope is e413, excess is refunded. `$help` prints the command.
func sendFor(ugnot int64, what string) string {
	return notice("CAUTION", "Attach "+money(ugnot)+" GNOT to this call",
		"A form cannot carry coins, so the wallet must: send `"+strconv.FormatInt(ugnot, 10)+
			"ugnot` with the transaction, or the realm rejects it (`e413 fee-too-low`). "+
			what+" Anything over is refunded. "+md("The $help page", self("$help"))+
			" prints the exact command with the send already in it.")
}

// noSend marks forms that must carry nothing. A send on a function that never
// reads the envelope is a hard UnobservedSendError.
func noSend() string { return "_No coins on this call — a send here fails the tx._\n\n" }

func notice(kind, title, body string) string {
	s := "> [!" + kind + "]"
	if title != "" {
		s += " " + title
	}
	if body != "" {
		s += "\n> " + body
	}
	return s + "\n\n"
}

// fold is a collapsed block: closed by default, so it hides what a returning
// player already knows.
func fold(summary, body string) string {
	return "<gno-details summary=\"" + attr(summary) + "\">\n" + body + "\n</gno-details>\n\n"
}

func title(s string) string { return "# " + s + "\n\n" }

// pageHeadBare is a title and one line of state with no cross-links. Pages that
// already carry their own footer nav use this: two nav rows on one page is a
// third more link gas for nothing.
func pageHeadBare(name, line string) string {
	if line == "" {
		return title(name)
	}
	return title(name) + line + "\n\n"
}

// pageHead is the standard opening: title, one line of state, and the way out.
func pageHead(name, line, backLabel, backHref string) string {
	s := title(name)
	if line != "" {
		s += line + "\n\n"
	}
	s += nav(backLabel, backHref, "Rules", self("rules"), "Ledger", self("ledger"))
	return s
}

// ----- money and numbers -----

// money renders ugnot as GNOT with three decimals: 100000 -> "0.100".
// Concatenation beats strings.Builder here by measurement, and this is the
// most-called helper on a page.
func money(ugnot int64) string {
	neg := ugnot < 0
	if neg {
		ugnot = -ugnot
	}
	milli := ugnot / 1000
	s := strconv.FormatInt(milli/1000, 10) + "." + pad(milli%1000, 3)
	if neg {
		return "-" + s
	}
	return s
}

func pad(v int64, width int) string {
	s := strconv.FormatInt(v, 10)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

// coins is money with its glyph, the only form used in prose.
func coins(ugnot int64) string { return "🪙 **" + money(ugnot) + " GNOT**" }

func plural(n int64, one string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.FormatInt(n, 10) + " " + one + "s"
}

// ----- meters -----

// meter draws v filled segments out of total.
func meter(v, total int64) string {
	if v < 0 {
		v = 0
	}
	if v > total {
		v = total
	}
	s := ""
	for i := int64(0); i < total; i++ {
		if i < v {
			s += segFull
		} else {
			s += segBlank
		}
	}
	return s
}

// alarmBars is the alarm bar and its count, always three segments. The bar is
// decoration; the number is the fact, so both are always written.
func alarmBars(alarm int64) string {
	s := meter(alarm, alarmTotal) + " " + strconv.FormatInt(alarm, 10) + "/3"
	if alarm >= alarmTotal {
		return s + " **— the door is closing**"
	}
	return s
}

// alarmMeter is alarmBars with its glyph, for prose.
func alarmMeter(alarm int64) string { return icon("alarm", "") + " " + alarmBars(alarm) }

// seatStrip draws filled seats out of four, empty ones as blanks.
func seatStrip(filled int64) string { return meter(filled, seatTotal) }

// ----- players -----

func short(addr string) string {
	if len(addr) <= 12 {
		return addr
	}
	return addr[:6] + "…" + addr[len(addr)-4:]
}

// who is a player as a link to their profile. An address is bech32 — lowercase
// letters and digits only — so it needs no sanitize pass, only a code span; that
// keeps a seat table inside the render gas budget.
func who(addr string) string {
	if !address(addr).IsValid() {
		return "—"
	}
	return md("`"+short(addr)+"`", self("p/"+addr))
}

// youMark flags the caller's own seat, when the path carried their address.
func youMark(addr, viewer string) string {
	if viewer != "" && addr == viewer {
		return " " + icon("user-male", "you") + " **you**"
	}
	return ""
}

// ----- game vocabulary -----

func phaseName(phase uint8) string {
	switch phase {
	case 1:
		return "committing"
	case 2:
		return "revealing"
	case 3:
		return "escaped"
	case 4:
		return "busted"
	}
	return "open"
}

// phaseBadge is the one-glance state of a job in a list or a heading.
func phaseBadge(phase uint8) string {
	switch phase {
	case 1:
		return icon("lock", "committing") + " committing"
	case 2:
		return icon("eye", "revealing") + " revealing"
	case 3:
		return icon("check-circle", "escaped") + " escaped"
	case 4:
		return icon("alarm", "busted") + " busted"
	}
	return icon("door", "open") + " open"
}

func actionName(a uint8) string {
	switch a {
	case 1:
		return "Scout"
	case 2:
		return "Pick"
	case 3:
		return "Carry"
	case 4:
		return "Watch"
	}
	return "—"
}

func actionIcon(a uint8) string {
	switch a {
	case 1:
		return "search"
	case 2:
		return "unlock"
	case 3:
		return "bag"
	case 4:
		return "eye"
	}
	return "info"
}

func actionGlyph(a uint8) string {
	switch a {
	case 1:
		return "🔍"
	case 2:
		return "🔓"
	case 3:
		return "🎒"
	case 4:
		return "👁"
	}
	return "·"
}

// actionCell is an action with its glyph, for a table.
func actionCell(a uint8) string {
	if a == 0 {
		return "—"
	}
	return actionGlyph(a) + " " + actionName(a)
}

// actionBlurb is why a player would choose it. Contributions are the truth
// behind the flavour, so both are printed.
func actionBlurb(a uint8) string {
	switch a {
	case 1:
		return "Reads the room: **+2** loot, no alarm."
	case 2:
		return "Takes from the shelf: **+3** loot, **+1 alarm**."
	case 3:
		return "Hauls it to the door: **+3 loot that survives a bust**."
	case 4:
		return "Holds the door: **+1** loot, and **−1 alarm**."
	}
	return "Do nothing."
}

// blocksLeft says how long is left before the deadline, in blocks.
func blocksLeft(jv JobView) string {
	left := jv.Deadline - jv.Height
	if left <= 0 {
		return "**deadline passed**"
	}
	return strconv.FormatInt(left, 10) + " blocks left"
}

// jobTitle is a job's name with a fallback. Names are sanitised once at write
// time (cleanName), and sanitize helpers are not idempotent, so it is *not*
// re-run here — only the escape a table cell needs is applied.
func jobTitle(jv JobView) string {
	n := strings.TrimSpace(jv.Name)
	if n == "" {
		return "Job " + strconv.FormatInt(jv.ID, 10)
	}
	return pipe(n)
}

// pipe escapes the only markdown character a stored (already sanitised) name
// can still break a table with.
func pipe(s string) string { return strings.ReplaceAll(s, "|", `\|`) }

// jobLink is the canonical link to a job.
func jobLink(id int64) string { return self("job/" + strconv.FormatInt(id, 10)) }

// ----- surfaces owned by other files -----

// The six page functions live in render_home/rules/jobs/job/profile/ledger.gno.
// Declared here so the router reads as a table of contents.
func renderMissing(what string) string {
	return pageHead("Nothing here", "The path `"+what+"` is not a page.", "Home", hub) +
		notice("WARNING", "No such page", "") +
		"Try " + md("the board", self("jobs")) + ", " + md("the rules", self("rules")) +
		", or " + md("the ledger", self("ledger")) + ".\n"
}
