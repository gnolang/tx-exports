package fairdrop

// gnoweb pages. Every page is derived from on-chain state alone, so the same
// URL renders the same thing for every visitor.

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/fairness"
)

// gnowebURL turns a package path into the path part of its gnoweb URL by
// dropping the chain domain: gno.land/r/x/y -> /r/x/y.
func gnowebURL(pkgPath string) string {
	i := strings.Index(pkgPath, "/")
	if i < 0 {
		return "/" + pkgPath
	}
	return pkgPath[i:]
}

// Render dispatches gnoweb paths:
//
//	""                      board home: open and past draws
//	"event/<id>"            one draw, with the actions it accepts right now
//	"event/<id>/verify"     the seed's inputs and how to recompute it
//	"event/<id>/receipt/<rank>"
//	"create"                how to open a draw
func Render(path string) string {
	parts := strings.Split(path, "/")

	switch {
	case path == "":
		return renderHome()
	case parts[0] == "create" && len(parts) == 1:
		return renderCreate()
	case parts[0] == "event" && len(parts) == 2:
		id, ok := parseUint(parts[1])
		if !ok {
			return renderNotFound(path)
		}
		return renderEvent(id)
	case parts[0] == "event" && len(parts) == 3 && parts[2] == "verify":
		id, ok := parseUint(parts[1])
		if !ok {
			return renderNotFound(path)
		}
		return renderVerify(id)
	case parts[0] == "event" && len(parts) == 4 && parts[2] == "receipt":
		id, ok := parseUint(parts[1])
		if !ok {
			return renderNotFound(path)
		}
		rank, ok := parseUint(parts[3])
		if !ok {
			return renderNotFound(path)
		}
		return renderReceipt(id, int(rank))
	}
	return renderNotFound(path)
}

// ------------------------------------------------------------------- home

func renderHome() string {
	var b strings.Builder

	b.WriteString("# FairDrop\n\n")
	b.WriteString("Raffles whose result anyone can check.\n\n")
	b.WriteString("An organizer opens a draw with a prize and a number of winners. Entrants ")
	b.WriteString("seal a ticket by publishing only a hash of a secret they generated locally. ")
	b.WriteString("Once entries close they reveal the secret, this realm re-hashes it against the ")
	b.WriteString("seal, and when the reveal window ends **anyone** can press the draw. The winners ")
	b.WriteString("come from a seed folded out of the revealed secrets in address order, so every ")
	b.WriteString("result can be recomputed from public data — the page for each draw ends with the ")
	b.WriteString("exact inputs to do it.\n\n")

	b.WriteString("### Why it is fair\n\n")
	b.WriteString("| Step | Who acts | What is fixed at that moment |\n")
	b.WriteString("|---|---|---|\n")
	b.WriteString("| 1. Seal | each entrant | their secret and ticket weight, as a hash — unreadable until later |\n")
	b.WriteString("| 2. Close | nobody (block time) | the roster and every seal; nothing can be added or changed |\n")
	b.WriteString("| 3. Reveal | each entrant | the preimage; a reveal that does not open its own seal is rejected |\n")
	b.WriteString("| 4. Draw | anyone | the winners are a pure function of the revealed secrets |\n\n")
	b.WriteString("The organizer cannot add, drop or re-weight an entry after it is sealed, cannot ")
	b.WriteString("read the secrets before the close, and cannot see or influence the seed before ")
	b.WriteString("the reveal window. An entrant who never reveals forfeits their own ticket — it ")
	b.WriteString("cannot promote anyone else.\n\n")

	b.WriteString("## Draws\n\n")
	if len(events) == 0 {
		b.WriteString("No draw has been opened yet. ")
		b.WriteString("[Open the first one](/" + RealmPath + ":create) — it takes one transaction.\n")
		return b.String()
	}

	b.WriteString("| draw | prize | entries | winners | phase | closes |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	now := nowUnix()
	for i := len(events) - 1; i >= 0; i-- {
		e := events[i]
		b.WriteString("| [#" + e.IDString() + " " + cell(e.Title) + "](/" + RealmPath + ":event/" + e.IDString() + ") ")
		b.WriteString("| " + cell(e.Prize) + " ")
		b.WriteString("| " + strconv.Itoa(e.Entries()) + " sealed / " + strconv.Itoa(e.Revealed()) + " revealed ")
		b.WriteString("| " + strconv.Itoa(e.Slots) + " ")
		b.WriteString("| " + phaseBadge(e.phase(now)) + " ")
		b.WriteString("| " + closeLine(e, now) + " |\n")
	}

	b.WriteString("\n[Open a draw](/" + RealmPath + ":create) · ")
	b.WriteString("the reusable engine is [" + PackagePath + "](/" + PackagePath + ")\n")
	return b.String()
}

// ------------------------------------------------------------------ event

func renderEvent(id uint64) string {
	e := GetEvent(id)
	if e == nil {
		return renderNotFound("event/" + uitoa(id))
	}
	now := nowUnix()
	ph := e.phase(now)

	var b strings.Builder

	b.WriteString("# Draw #" + e.IDString() + " — " + e.Title + "\n\n")
	b.WriteString("**Prize:** " + e.Prize + "\n\n")
	b.WriteString("**Organizer:** `" + e.Creator.String() + "`\n\n")
	b.WriteString("**Winners:** " + strconv.Itoa(e.Slots) +
		" · **Max weight per ticket:** " + uitoa(e.MaxWeight) +
		" · **Phase:** " + phaseBadge(ph) + "\n\n")

	b.WriteString("### Timeline\n\n")
	b.WriteString("| phase | starts (UTC / KST) | ends (UTC / KST) | now |\n")
	b.WriteString("|---|---|---|---|\n")
	b.WriteString("| entries | " + stamp(e.OpensAt) + " | " + stamp(e.ClosesAt) + " | " + phaseTick(ph == PhaseOpen) + " |\n")
	b.WriteString("| reveal | " + stamp(e.ClosesAt) + " | " + stamp(e.RevealEndsAt) + " | " + phaseTick(ph == PhaseReveal) + " |\n")
	b.WriteString("| draw | " + stamp(e.RevealEndsAt) + " | anyone may trigger | " + phaseTick(ph == PhaseDrawn) + " |\n\n")

	if ph == PhaseOpen {
		b.WriteString("Entries close in **" + left(e.ClosesAt, now) + "**")
		if e.Entries() > 0 {
			b.WriteString(", with " + strconv.Itoa(e.Entries()) + " sealed ticket(s) so far")
		}
		b.WriteString(".\n\n")
	}
	if ph == PhaseReveal {
		b.WriteString("Reveals close in **" + left(e.RevealEndsAt, now) + "** — " +
			strconv.Itoa(e.Revealed()) + " of " + strconv.Itoa(e.Entries()) + " sealed tickets revealed.\n\n")
	}
	if ph == PhaseDrawable {
		b.WriteString("The reveal window is over. The result is fixed by the revealed secrets — ")
		b.WriteString("anyone can write it down with `Draw(" + e.IDString() + ")`.\n\n")
	}

	renderActions(&b, e, ph)
	renderRoster(&b, e, ph)
	if e.Seed != "" {
		renderResult(&b, e)
	}
	return b.String()
}

func renderActions(b *strings.Builder, e *Event, ph string) {
	b.WriteString("### Actions\n\n")
	if ph == PhaseOpen {
		b.WriteString("**Enter.** Generate a secret locally and publish only its seal:\n\n")
		b.WriteString("```sh\n")
		b.WriteString("# 1. a secret only you know (32 random bytes, hex)\n")
		b.WriteString("SECRET=$(openssl rand -hex 32)\n\n")
		b.WriteString("# 2. its seal = sha256(\"fairdrop/seal/v1|" + e.Domain() + "|<your g1 address>|<weight>|$SECRET\")\n")
		b.WriteString("SEAL=$(printf 'fairdrop/seal/v1|" + e.Domain() + "|%s|1|%s' \\\n")
		b.WriteString("  g1youraddress... \"$SECRET\" | sha256sum | cut -d' ' -f1)\n\n")
		b.WriteString("# 3. seal the ticket (weight 1 unless the organizer vouched for more)\n")
		b.WriteString("gnokey maketx call -pkgpath " + RealmPath + " -func Register \\\n")
		b.WriteString("  -args " + e.IDString() + " -args \"$SEAL\" -args 1 \\\n")
		b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast \\\n")
		b.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY\n\n")
		b.WriteString("# keep $SECRET until the reveal window\n")
		b.WriteString("```\n\n")
		b.WriteString("Read the seal back on chain before the window closes: it is listed below. ")
		b.WriteString("If it is wrong, that ticket cannot be revealed and does not count.\n\n")
	} else if ph == PhaseReveal {
		b.WriteString("**Reveal.** Publish the secret behind your seal:\n\n")
		b.WriteString("```sh\n")
		b.WriteString("gnokey maketx call -pkgpath " + RealmPath + " -func Reveal \\\n")
		b.WriteString("  -args " + e.IDString() + " -args \"$SECRET\" \\\n")
		b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast \\\n")
		b.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY\n")
		b.WriteString("```\n\n")
	} else if ph == PhaseDrawable {
		b.WriteString("**Draw.** Write the determined result on chain — anyone can do it:\n\n")
		b.WriteString("```sh\n")
		b.WriteString("gnokey maketx call -pkgpath " + RealmPath + " -func Draw \\\n")
		b.WriteString("  -args " + e.IDString() + " \\\n")
		b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast \\\n")
		b.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY\n")
		b.WriteString("```\n\n")
	} else if ph == PhaseDrawn {
		b.WriteString("This draw is settled. [Verify it](/" + RealmPath + ":event/" + e.IDString() + "/verify).\n\n")
	} else {
		b.WriteString("This draw was cancelled by its organizer before entries closed.\n\n")
	}
}

func renderRoster(b *strings.Builder, e *Event, ph string) {
	b.WriteString("### Tickets (" + strconv.Itoa(e.Entries()) + ")\n\n")
	if len(e.Roster) == 0 {
		b.WriteString("No ticket sealed yet.\n\n")
		return
	}
	b.WriteString("| # | entrant | weight | seal | status |\n")
	b.WriteString("|---|---|---|---|---|\n")
	for i := 0; i < len(e.Roster); i++ {
		t := e.Roster[i]
		status := "sealed"
		if t.Secret != "" {
			status = "revealed"
		} else if e.phase(nowUnix()) == PhaseDrawable && e.Seed == "" {
			status = "forfeited (no reveal)"
		} else if e.Seed != "" && t.Secret == "" {
			status = "forfeited (no reveal)"
		}
		if t.Rank > 0 {
			status = "**winner #" + strconv.Itoa(t.Rank) + "**"
		}
		b.WriteString("| " + strconv.Itoa(i+1) + " | `" + t.ID + "` | " + uitoa(t.Weight) +
			" | `" + short(t.Commit) + "` | " + status + " |\n")
	}
	b.WriteString("\n")
}

func renderResult(b *strings.Builder, e *Event) {
	b.WriteString("### Result\n\n")
	winners := e.Winners()
	if len(winners) == 0 {
		b.WriteString("No eligible ticket: nobody revealed, so the draw settled with no winner.\n\n")
	} else {
		b.WriteString("| rank | winner | weight | receipt |\n")
		b.WriteString("|---|---|---|---|\n")
		for i := 0; i < len(winners); i++ {
			w := winners[i]
			b.WriteString("| " + strconv.Itoa(w.Rank) + " | `" + w.Entrant + "` | " + uitoa(w.Weight) +
				" | [receipt](/" + RealmPath + ":event/" + e.IDString() + "/receipt/" + strconv.Itoa(w.Rank) + ") |\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("**Seed:** `" + e.Seed + "`\n\n")
	b.WriteString("Drawn at " + stamp(e.DrawnAt) + " at block " + strconv.FormatInt(e.DrawnHeight, 10) + ". ")
	b.WriteString("[Every input of the seed](/" + RealmPath + ":event/" + e.IDString() + "/verify) is on chain.\n\n")
}

func renderVerify(id uint64) string {
	e := GetEvent(id)
	if e == nil {
		return renderNotFound("event/" + uitoa(id))
	}
	leaves := e.AcceptedLeaves()

	var b strings.Builder
	b.WriteString("# Verify draw #" + e.IDString() + "\n\n")
	b.WriteString("**Draw:** #" + e.IDString() + " · **Domain:** `" + e.Domain() + "` · **Chain:** `" + runtime.ChainID() + "`\n\n")

	if e.Seed == "" {
		b.WriteString("Not drawn yet — there is no seed to verify.\n")
		return b.String()
	}

	b.WriteString("**Seed:**\n\n```\n" + e.Seed + "\n```\n\n")
	b.WriteString("The seed is folded from these inputs, in this exact order (ascending entrant address, ")
	b.WriteString("revealed tickets only). Each leaf is `seal:secret`.\n\n")

	if len(leaves) == 0 {
		b.WriteString("_No revealed ticket, so the fold had no leaf._\n\n")
	} else {
		b.WriteString("| # | entrant | leaf |\n|---|---|---|\n")
		n := 0
		for i := 0; i < len(e.Roster); i++ {
			if e.Roster[i].Secret == "" {
				continue
			}
			n++
			b.WriteString("| " + strconv.Itoa(n) + " | `" + e.Roster[i].ID + "` | `" +
				e.Roster[i].Commit + ":" + e.Roster[i].Secret + "` |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("### Recompute it yourself\n\n")
	b.WriteString("The realm hashes this string (one trailing `|` per leaf is included):\n\n")
	b.WriteString("```\nfairdrop/seed/v1|" + e.Domain() + "|" + runtime.ChainID() + "|" + e.IDString() + "|" + strings.Join(leaves, "|") + "|\n```\n\n")
	b.WriteString("```python\nimport hashlib\n")
	b.WriteString("leaves = [" + quoteList(leaves) + "]\n")
	b.WriteString("payload = \"fairdrop/seed/v1|" + e.Domain() + "|" + runtime.ChainID() + "|" + e.IDString() + "|\" + \"\".join(l + \"|\" for l in leaves)\n")
	b.WriteString("print(hashlib.sha256(payload.encode()).hexdigest())\n")
	b.WriteString("# compare with the seed above\n")
	b.WriteString("```\n\n")

	b.WriteString("The winners are then taken from that seed by [the draw in ")
	b.WriteString("gno.land/p/fairdrop/fairness](/p/fairdrop/fairness): a SHA-256 counter-mode stream ")
	b.WriteString("walks the revealed roster in the same order, drawing weighted tickets without ")
	b.WriteString("replacement until " + strconv.Itoa(e.Slots) + " winner(s) are chosen. ")
	b.WriteString("`scripts/verify.py` in the project repository reproduces both steps.\n")
	return b.String()
}

func renderReceipt(id uint64, rank int) string {
	e := GetEvent(id)
	if e == nil {
		return renderNotFound("event/" + uitoa(id))
	}
	if e.Seed == "" {
		return "# Draw #" + e.IDString() + " has not been drawn yet\n"
	}

	found := false
	w := Winner{}
	all := e.Winners()
	for i := 0; i < len(all); i++ {
		if all[i].Rank == rank {
			w = all[i]
			found = true
			break
		}
	}
	if !found {
		return "# No winner at rank " + strconv.Itoa(rank) + " in draw #" + e.IDString() + "\n"
	}

	var b strings.Builder
	b.WriteString("# Receipt — draw #" + e.IDString() + ", rank " + strconv.Itoa(w.Rank) + "\n\n")
	b.WriteString("**Prize:** " + e.Prize + "\n\n")
	b.WriteString("**Winner:** `" + w.Entrant + "`\n\n")
	b.WriteString("**Ticket weight:** " + uitoa(w.Weight) + "\n\n")
	b.WriteString("**Seal:** `" + w.Commit + "`\n\n")
	b.WriteString("**Revealed secret:** `" + w.Secret + "`\n\n")
	b.WriteString("**Seed:** `" + e.Seed + "`\n\n")
	b.WriteString("**Drawn:** " + stamp(e.DrawnAt) + " · block " + strconv.FormatInt(e.DrawnHeight, 10) + "\n\n")
	b.WriteString("This ticket took rank " + strconv.Itoa(w.Rank) + " of " +
		strconv.Itoa(len(e.Winners())) + ", drawn from " + strconv.Itoa(e.Revealed()) +
		" revealed ticket(s) carrying " + uitoa(fairness.TotalWeight(e.Roster)) + " weight in total. ")
	b.WriteString("The receipt is checkable twice over: the secret re-hashes to the seal that was ")
	b.WriteString("on chain before entries closed, and the seed that produced this rank is the fold ")
	b.WriteString("of every revealed ticket — see [verify](/" + RealmPath + ":event/" + e.IDString() + "/verify).\n")
	return b.String()
}

// ----------------------------------------------------------------- create

func renderCreate() string {
	var b strings.Builder
	b.WriteString("# Open a draw\n\n")
	b.WriteString("One transaction opens a draw. Nothing is escrowed: FairDrop records the draw and ")
	b.WriteString("its result, it does not hold the prize.\n\n")
	b.WriteString("```sh\n")
	b.WriteString("gnokey maketx call -pkgpath " + RealmPath + " -func Create \\\n")
	b.WriteString("  -args \"Friday community raffle\" \\\n")
	b.WriteString("  -args \"1 limited edition mug\" \\\n")
	b.WriteString("  -args 3 \\\n")
	b.WriteString("  -args 5 \\\n")
	b.WriteString("  -args 600 \\\n")
	b.WriteString("  -args 300 \\\n")
	b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast \\\n")
	b.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY\n")
	b.WriteString("```\n\n")
	b.WriteString("Arguments: `title`, `prize`, `winners`, `max weight per ticket`, ")
	b.WriteString("`entry window (seconds)`, `reveal window (seconds)`.\n\n")
	b.WriteString("Then, optionally, give a known guest more weight **before** they seal:\n\n")
	b.WriteString("```sh\n")
	b.WriteString("gnokey maketx call -pkgpath " + RealmPath + " -func Vouch \\\n")
	b.WriteString("  -args <draw id> -args g1guestaddress... -args 3 \\\n")
	b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast \\\n")
	b.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY\n")
	b.WriteString("```\n\n")
	b.WriteString("Rules the realm enforces, not just documents:\n\n")
	b.WriteString("- one ticket per address; a vouch changes its weight, never the number of entries\n")
	b.WriteString("- a ticket's weight is sealed into its digest, so it cannot change after sealing\n")
	b.WriteString("- entries close on block time, not on the organizer's word\n")
	b.WriteString("- the draw is permissionless and the seed is public\n")
	return b.String()
}

func renderNotFound(path string) string {
	return "# Not found\n\n`" + path + "` is not a page of this realm.\n\n[Back to the board](/" + RealmPath + ")\n"
}

// ----------------------------------------------------------------- helpers

func phaseBadge(ph string) string {
	switch ph {
	case PhaseOpen:
		return "**open** — sealing"
	case PhaseReveal:
		return "**reveal** — secrets being opened"
	case PhaseDrawable:
		return "**drawable** — waiting for a draw"
	case PhaseDrawn:
		return "**drawn**"
	case PhaseCancelled:
		return "cancelled"
	}
	return ph
}

func phaseTick(active bool) string {
	if active {
		return "←"
	}
	return ""
}

func closeLine(e *Event, now int64) string {
	switch e.phase(now) {
	case PhaseOpen:
		return "in " + left(e.ClosesAt, now)
	case PhaseReveal:
		return "closed " + left(now, e.ClosesAt) + " ago"
	case PhaseDrawable:
		return "closed " + left(now, e.ClosesAt) + " ago"
	case PhaseDrawn:
		return "drawn " + left(now, e.DrawnAt) + " ago"
	case PhaseCancelled:
		return "cancelled"
	}
	return ""
}

// left renders a positive duration in seconds as "2d 3h", "4h 12m", "3m 40s".
func left(until int64, from int64) string {
	d := until - from
	if d < 0 {
		d = 0
	}
	if d >= 86400 {
		return strconv.FormatInt(d/86400, 10) + "d " + strconv.FormatInt((d%86400)/3600, 10) + "h"
	}
	if d >= 3600 {
		return strconv.FormatInt(d/3600, 10) + "h " + strconv.FormatInt((d%3600)/60, 10) + "m"
	}
	if d >= 60 {
		return strconv.FormatInt(d/60, 10) + "m " + strconv.FormatInt(d%60, 10) + "s"
	}
	return strconv.FormatInt(d, 10) + "s"
}

// stamp renders a unix second in both UTC and KST, the two clocks this board's
// audience reads.
func stamp(unix int64) string {
	t := time.Unix(unix, 0).UTC()
	k := time.Unix(unix+9*3600, 0).UTC()
	return t.Format("2006-01-02 15:04") + " / " + k.Format("01-02 15:04") + " KST"
}

func short(s string) string {
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-6:]
}

// cell keeps a free-text field from breaking a markdown table.
func cell(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '|' {
			out += "\\|"
		} else if c == '\n' || c == '\r' {
			out += " "
		} else {
			out += string(c)
		}
	}
	return out
}

func quoteList(items []string) string {
	out := ""
	for i := 0; i < len(items); i++ {
		if i > 0 {
			out += ", "
		}
		out += "\"" + items[i] + "\""
	}
	return out
}

func parseUint(s string) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}
