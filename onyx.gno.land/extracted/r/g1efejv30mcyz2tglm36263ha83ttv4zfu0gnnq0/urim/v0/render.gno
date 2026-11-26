package urim

import (
	"strconv"
	"strings"

	"gno.land/p/g1efejv30mcyz2tglm36263ha83ttv4zfu0gnnq0/hat/v0"
)

// Render shows public state only: names, phase, turns done, slot
// fingerprints, counts and checks. Never a pairing; the realm does not know one.
//
//	Render("")     open draws and the public counter
//	Render("<id>") one draw (gnoweb: /r/.../urim:<id>)
func Render(path string) string {
	path = strings.TrimPrefix(path, ":")
	if path == "" {
		return renderHome()
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || draws.Get(key(id)) == nil {
		return "# Draw not found\n\nThere is no Urim draw with that number. [See open draws](" + realmLink + ")\n"
	}
	return renderDraw(mustDraw(id))
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Urim: Secret Santa nobody can peek at\n\n")
	b.WriteString("Draw Secret Santa names online so nobody, not even the organiser, can peek or rig who gets whom.\n\n")
	b.WriteString("<gno-button href=\"" + AppOrigin + "\" label=\"Start a draw on your phone\" />\n\n")
	b.WriteString("## Open draws\n\n")
	shown := 0
	draws.ReverseIterate("", "", func(_ string, v any) bool {
		d := v.(*draw)
		if d.hat.Phase().Terminal() {
			return false
		}
		b.WriteString("- [" + esc(d.title) + "](" + realmLink + ":" + strconv.FormatInt(d.id, 10) + ") · " +
			plural(len(d.people), "person", "people") + " · " + phaseWords(d.hat) + "\n")
		shown++
		return shown >= 20
	})
	if shown == 0 {
		b.WriteString("No open draws right now.\n")
	}
	b.WriteString("\n## Counter\n\n")
	b.WriteString("| Draws completed | People | Voided |\n|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(completed) + " | " + strconv.Itoa(people) + " | " + strconv.Itoa(voided) + " |\n")
	return b.String()
}

func renderDraw(d *draw) string {
	h := d.hat
	ph := h.Phase()
	id := strconv.FormatInt(d.id, 10)
	var b strings.Builder

	// A leading h1 and a long-enough first paragraph become the page's
	// <title> and description in gnoweb, so shared links preview well.
	b.WriteString("# Urim: Secret Santa for " + esc(d.title) + "\n\n")
	b.WriteString(plural(len(d.people), "person has", "people have") + " joined. " +
		"Nobody can peek: every phone signs its own moves and a tampered hat cancels the draw.\n\n")

	app := AppOrigin + "/d/" + id
	if ph == hat.Join {
		b.WriteString("<gno-button href=\"" + app + "?join=1\" label=\"Join on your phone\" /> ")
	}
	b.WriteString("<gno-button href=\"" + app + "\" label=\"View in app\" variant=\"outline\" />\n\n")

	b.WriteString("| | |\n|---|---|\n")
	if d.budget != "" {
		b.WriteString("| Budget | " + esc(d.budget) + " |\n")
	}
	if d.date != "" {
		b.WriteString("| Exchange | " + esc(d.date) + " |\n")
	}
	mode := "async (a day per step)"
	if d.live {
		mode = "live (10 minutes per step)"
	}
	b.WriteString("| Mode | " + mode + " |\n")
	b.WriteString("| Phase | " + ph.String() + ": " + phaseWords(h) + " |\n")
	if !ph.Terminal() {
		b.WriteString("| Deadline | " + h.Deadline().UTC().Format("2006-01-02 15:04 UTC") + " (block time) |\n")
	}
	if ph == hat.Voided {
		b.WriteString("| Why | " + esc(h.Reason()) + " |\n")
		if d.next != 0 {
			n := strconv.FormatInt(d.next, 10)
			b.WriteString("| Fresh draw | [#" + n + "](" + realmLink + ":" + n + ") |\n")
		}
	}
	b.WriteString("\n")

	b.WriteString("## People\n\n")
	shufflerTurn := map[int]int{}
	for t, s := range h.Shufflers() {
		shufflerTurn[s] = t + 1
	}
	for i, p := range d.people {
		line := strconv.Itoa(i+1) + ". " + esc(p.name)
		if bytesEq(p.signPub, d.organiser) {
			line += " (organiser)"
		}
		if t, ok := shufflerTurn[i]; ok {
			line += " · shuffler " + strconv.Itoa(t)
		}
		if h.Done(i) && (ph == hat.Locked || ph == hat.Seal1 || ph == hat.Seal2) {
			line += " · ✓"
		}
		b.WriteString(line + "\n")
	}
	b.WriteString("\n")

	if ph >= hat.Seal1 && ph != hat.Voided {
		b.WriteString("## Shuffle turns\n\n")
		for round := 1; round <= 2; round++ {
			b.WriteString("- Round " + strconv.Itoa(round) + ": " + turnTicks(h, round) + "\n")
		}
		b.WriteString("\n")
	}

	if slots := h.Slots(); len(slots) > 0 {
		b.WriteString("## Slots in the circle\n\n")
		b.WriteString("Each slot gives to the next one, wrapping round. Nobody but its owner knows whose slot is whose.\n\n")
		fps := make([]string, len(slots))
		for k, s := range slots {
			fps[k] = "`" + hat.Fingerprint(s) + "`"
		}
		b.WriteString(strings.Join(fps, " → ") + " → back to the start\n\n")
	}

	b.WriteString("## Checks\n\n")
	n := len(d.people)
	switch {
	case ph == hat.Check:
		b.WriteString("- Phones that found their own slot: " + strconv.Itoa(h.Count()) + "/" + strconv.Itoa(n) + "\n")
	case ph > hat.Check && ph != hat.Voided:
		b.WriteString("- Every phone found its own slot: ✓\n")
	}
	if ph == hat.Revealed {
		b.WriteString("- One slip for every slot: ✓\n")
		b.WriteString("- Phones that opened a genuine slip: " + strconv.Itoa(h.Count()) + "/" + strconv.Itoa(n) + "\n")
	}
	if ph < hat.Check {
		b.WriteString("- Checks start after the first shuffle.\n")
	}
	if ph == hat.Voided {
		b.WriteString("- The draw was called off for everyone. No pairing was revealed.\n")
	}
	return b.String()
}

func turnTicks(h *hat.Hat, round int) string {
	total := len(h.Shufflers())
	done := 0
	ph := h.Phase()
	cur := hat.Mix1
	if round == 2 {
		cur = hat.Mix2
	}
	switch {
	case ph == cur:
		done = h.Turn()
	case ph > cur && ph != hat.Voided:
		done = total
	}
	ticks := make([]string, total)
	for t := range ticks {
		ticks[t] = "·"
		if t < done {
			ticks[t] = "✓"
		}
	}
	return strings.Join(ticks, " ") + " (" + strconv.Itoa(done) + "/" + strconv.Itoa(total) + ")"
}

func phaseWords(h *hat.Hat) string {
	switch h.Phase() {
	case hat.Join:
		return "open for joining"
	case hat.Locked:
		return "checking in, " + strconv.Itoa(h.Count()) + "/" + strconv.Itoa(h.Size()) + " phones ready"
	case hat.Seal1:
		return "making tickets, " + strconv.Itoa(h.Count()) + "/" + strconv.Itoa(h.Size())
	case hat.Mix1:
		return "shuffling, turn " + strconv.Itoa(h.Turn()+1) + " of " + strconv.Itoa(len(h.Shufflers()))
	case hat.Check:
		return "checking tickets"
	case hat.Seal2:
		return "folding names, " + strconv.Itoa(h.Count()) + "/" + strconv.Itoa(h.Size())
	case hat.Mix2:
		return "shuffling again, turn " + strconv.Itoa(h.Turn()+1) + " of " + strconv.Itoa(len(h.Shufflers()))
	case hat.Revealed:
		if h.Completed() {
			return "everyone has their name"
		}
		return "names revealed on each phone"
	}
	return "called off"
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// esc makes user text inert in gnoweb markdown.
func esc(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '~', '&', '@', ':':
			b.WriteRune('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}
