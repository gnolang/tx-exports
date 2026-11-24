package lastorders

import (
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

// shown is how many rounds the page lists, newest first.
const shown = 20

func Render(_ string) string {
	now := time.Now().Unix()
	registryURL := strings.TrimPrefix(registry.Path(), "gno.land")

	var b strings.Builder
	b.WriteString("# Last Orders\n\n")
	b.WriteString("The last round of the night goes to the highest bidder, whose toast is written on the wall. ")
	b.WriteString("Each round ends at a set time, and a realm cannot wake itself to end it. ")
	b.WriteString("So every round posts a [Lamplighter](" + registryURL + ") job due at closing time: ")
	b.WriteString("whoever runs it settles the round and is paid " + gnot(LampFee) + " for it.\n\n")

	b.WriteString("[Open a round](" + txlink.NewLink("Open").AddArgs("title", "", "seconds", "600").SetSend(itoa(LampFee)+denom).URL() +
		") (you put up " + gnot(LampFee) + " for the lamplighter)\n\n")

	if rounds.Size() == 0 {
		b.WriteString("No rounds yet.\n")
		return b.String()
	}

	var open, wall strings.Builder
	rounds.ReverseIterateByOffset(0, shown, func(_ string, v any) bool {
		r := v.(*round)
		title := sanitize.TableCell(r.title)
		id := utoa(r.id)
		if !r.settled {
			leading := "no bids"
			if r.bid > 0 {
				leading = gnot(r.bid) + " by " + short(r.leader)
			}
			open.WriteString("| " + id + " | " + title + " | " + leading + " | " + closing(r, now, registryURL) + " | ")
			if now < r.closesAt {
				open.WriteString("[Bid " + gnot(minNextBid(r)) + "](" +
					txlink.NewLink("Bid").AddArgs("id", id, "toast", "").SetSend(itoa(minNextBid(r))+denom).URL() + ")")
			}
			open.WriteString(" |\n")
			return false
		}
		if r.bid == 0 {
			wall.WriteString("| " + id + " | " + title + " | nobody | |\n")
		} else {
			wall.WriteString("| " + id + " | " + title + " | " + short(r.leader) + " for " + gnot(r.bid) +
				" | " + sanitize.TableCell(r.toast) + " |\n")
		}
		return false
	})

	if open.Len() > 0 {
		b.WriteString("## Open rounds\n\n| # | Round | Leading | Closes | |\n|---|---|---|---|---|\n")
		b.WriteString(open.String() + "\n")
	}
	if wall.Len() > 0 {
		b.WriteString("## The wall\n\n| # | Round | Won by | Toast |\n|---|---|---|---|\n")
		b.WriteString(wall.String())
	}
	return b.String()
}

// closing says when a round closes, or what it is waiting for.
func closing(r *round, now int64, registryURL string) string {
	job := "[job " + utoa(r.job) + "](" + registryURL + ":job/" + utoa(r.job) + ")"
	if now < r.closesAt {
		return "in " + itoa(r.closesAt-now) + "s, by " + job
	}
	return "**closed**: run " + job + " to settle it"
}

// short abbreviates an address for a table.
func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}

// gnot renders an ugnot amount as GNOT with up to six decimals.
func gnot(ugnot int64) string {
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	f := itoa(frac)
	for len(f) < 6 {
		f = "0" + f
	}
	return itoa(whole) + "." + strings.TrimRight(f, "0") + " GNOT"
}
