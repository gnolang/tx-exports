package trickle

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	realmPath = "/r/g1a04glq8w6ts7r9yzyznpa99qkzwp8pewcf3aef/trickle"
	pageSize  = 20
	maxPages  = 1 << 20
	barWidth  = 24
)

// Render serves the realm's pages in gnoweb:
//
//	""               overview and latest streams
//	stream/<id>      one stream
//	account/<addr>   streams sent and received by an address
func Render(path string) string {
	now := time.Now().Unix()
	switch {
	case path == "":
		return renderHome(now)
	case strings.HasPrefix(path, "stream/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "stream/"), 10, 64)
		if err != nil {
			return notFound()
		}
		r := get(id)
		if r == nil {
			return notFound()
		}
		return renderStream(r, now)
	case strings.HasPrefix(path, "account/"):
		// account/<addr> or account/<addr>/<page>, pages counted from 1.
		rest, pageStr, paged := strings.Cut(strings.TrimPrefix(path, "account/"), "/")
		page := 1
		if paged {
			n, err := strconv.Atoi(pageStr)
			if err != nil || n < 1 || n > maxPages {
				return notFound()
			}
			page = n
		}
		addr := address(rest)
		if !addr.IsValid() {
			return notFound()
		}
		return renderAccount(addr, page, now)
	}
	return notFound()
}

func notFound() string {
	return "# Not found\n\n[Back to Trickle](" + realmPath + ")\n"
}

func renderHome(now int64) string {
	var b strings.Builder
	b.WriteString("# Trickle\n\n")
	b.WriteString("**Money that arrives every second.** Lock GNOT once; it unlocks for the recipient continuously. ")
	b.WriteString("They withdraw whenever they like, and the sender can cancel and take back only what has not unlocked yet.\n\n")
	if appURL != "" {
		b.WriteString("[Open the app](" + appURL + ") · ")
	}
	b.WriteString("[Open a stream](" + realmPath + "$help&func=Create) · ")
	b.WriteString("[Run a payroll](" + realmPath + "$help&func=CreateBatch)\n\n")

	b.WriteString("| Streams | Total locked in | Paid to recipients | Locked now |\n|---|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(streams.Size()) +
		" | " + gnot(totalDeposited) +
		" | " + gnot(totalPaid) +
		" | " + gnot(totalDeposited-totalPaid-totalRefunded) + " |\n\n")

	b.WriteString("## Latest streams\n\n")
	if streams.Size() == 0 {
		b.WriteString("No streams yet. Be the first.\n")
		return b.String()
	}
	b.WriteString(tableHeader)
	streams.ReverseIterateByOffset(0, pageSize, func(_ string, v any) bool {
		b.WriteString(tableRow(v.(*Record), now))
		return false
	})
	b.WriteString("\nSee your own streams at `" + realmPath + ":account/<your address>`.\n")
	return b.String()
}

func renderAccount(addr address, page int, now int64) string {
	var b strings.Builder
	b.WriteString("# Streams of " + addr.String() + "\n\n[Back to Trickle](" + realmPath + ")\n\n")
	offset := (page - 1) * maxPageSize
	more := false
	section := func(title string, index *avl.Tree) {
		b.WriteString("## " + title + "\n\n")
		n := 0
		// One extra row tells whether an older page exists.
		eachOf(index, addr, offset, maxPageSize+1, func(r *Record) {
			if n == maxPageSize {
				more = true
				return
			}
			if n == 0 {
				b.WriteString(tableHeader)
			}
			b.WriteString(tableRow(r, now))
			n++
		})
		if n == 0 {
			b.WriteString("None.\n")
		}
		b.WriteString("\n")
	}
	section("Incoming", byRecipient)
	section("Outgoing", bySender)
	base := realmPath + ":account/" + addr.String() + "/"
	if page > 1 {
		b.WriteString("[Newer](" + base + strconv.Itoa(page-1) + ")")
	}
	if more {
		if page > 1 {
			b.WriteString(" · ")
		}
		b.WriteString("[Older](" + base + strconv.Itoa(page+1) + ")")
	}
	b.WriteString("\n")
	return b.String()
}

func renderStream(r *Record, now int64) string {
	id := strconv.FormatUint(r.ID, 10)
	vested := r.Vested(now)
	var b strings.Builder
	b.WriteString("# Stream #" + id + "\n\n[Back to Trickle](" + realmPath + ")\n\n")
	if r.Memo != "" {
		b.WriteString("> " + sanitize.InlineText(r.Memo) + "\n\n")
	}
	b.WriteString("`" + bar(vested, r.Deposit) + "` **" + percent(vested, r.Deposit) + "** unlocked · " + r.Status(now).String() + "\n\n")

	b.WriteString("| | |\n|---|---|\n")
	row := func(k, v string) { b.WriteString("| " + k + " | " + v + " |\n") }
	row("From", accountLink(r.Sender))
	row("To", accountLink(r.Recipient))
	row("Deposit", gnot(r.Deposit))
	row("Unlocked", gnot(vested))
	row("Withdrawn", gnot(r.Withdrawn))
	row("Withdrawable now", "**"+gnot(r.Withdrawable(now))+"**")
	row("Rate", gnot(r.RatePerDay())+" / day")
	row("Start", date(r.Start))
	if r.Cliff != r.Start {
		row("Cliff", date(r.Cliff))
	}
	row("End", date(r.End))
	if r.IsCanceled() {
		row("Canceled", date(r.CanceledAt)+", "+gnot(r.Refunded)+" refunded")
	} else if r.Cancelable {
		row("Cancelable", "yes, by sender or recipient")
	} else {
		row("Cancelable", "no (the recipient may still decline it)")
	}

	if !r.IsCanceled() && r.Withdrawn < r.Deposit {
		b.WriteString("\n[Withdraw](" + realmPath + "$help&func=Withdraw&id=" + id + "&amount=0)")
		b.WriteString(" · [Transfer](" + realmPath + "$help&func=Transfer&id=" + id + ")")
		if now < r.End {
			b.WriteString(" · [Cancel](" + realmPath + "$help&func=Cancel&id=" + id + ")")
		}
		b.WriteString("\n")
	}
	return b.String()
}

const tableHeader = "| # | From | To | Deposit | Unlocked | Status | Memo |\n|---|---|---|---|---|---|---|\n"

func tableRow(r *Record, now int64) string {
	id := strconv.FormatUint(r.ID, 10)
	return "| [#" + id + "](" + realmPath + ":stream/" + id + ")" +
		" | " + accountLink(r.Sender) +
		" | " + accountLink(r.Recipient) +
		" | " + gnot(r.Deposit) +
		" | " + percent(r.Vested(now), r.Deposit) +
		" | " + r.Status(now).String() +
		" | " + sanitize.TableCell(r.Memo) + " |\n"
}

func accountLink(a address) string {
	s := a.String()
	return "[" + s[:8] + "…" + s[len(s)-4:] + "](" + realmPath + ":account/" + s + ")"
}

// gnot formats ugnot as GNOT with up to 6 decimals, trailing zeros trimmed.
func gnot(ugnot int64) string {
	whole := strconv.FormatInt(ugnot/1_000_000, 10)
	frac := strconv.FormatInt(ugnot%1_000_000+1_000_000, 10)[1:]
	frac = strings.TrimRight(frac, "0")
	if frac == "" {
		return whole + " GNOT"
	}
	return whole + "." + frac + " GNOT"
}

func percent(part, total int64) string {
	// part <= total, so tenths of a percent fit after scaling down.
	tenths := int64(float64(part) / float64(total) * 1000)
	return strconv.FormatInt(tenths/10, 10) + "." + strconv.FormatInt(tenths%10, 10) + "%"
}

func bar(part, total int64) string {
	filled := int(float64(part) / float64(total) * barWidth)
	return strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)
}

func date(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04:05") + " UTC"
}
