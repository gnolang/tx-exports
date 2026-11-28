package fund

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/fundmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Contract notes and annual statements (design note v6): written by the
// settlement code for every issue and cancellation of shares, so an investor
// can show the date, price, amounts, fees and the realised gain or loss at
// average cost. They contain nothing the chain does not already show to
// someone who knows the wallet or the sub-account.

const (
	noteSubscription = iota
	noteRedemption
	noteCompulsory
	noteDistribution
	noteRecovery
	noteInsolvency
	noteCrystallisation
)

var noteKinds = []string{"Subscription", "Redemption", "Compulsory redemption", "Wind-down distribution", "Recovery after the final distribution", "Cancellation without payment (insolvency)", "Performance fee crystallised"}

const noteCaveat = "> For information. Tax treatment depends on your country; confirm with your tax adviser. Test deployment: fictional fund, test tokens without value.\n\n"

var (
	notes      = avl.NewTree() // padded number -> *note
	notesByKey = avl.NewTree() // holder address + "/" + padded number -> true
	noteSeq    int64
)

type note struct {
	n, period, valuedAt, height int64
	kind                        int
	holder                      address
	navps                       int64
	shares                      int64 // issued (subscription) or cancelled
	holdingAfter                int64
	gross                       int64 // value of the shares at the NAV (before the performance fee)
	perfFee                     int64
	net                         int64 // paid (or set aside), or subscribed
	held                        bool  // set aside for a restricted holder
	cost                        int64 // cost added (subscription) or taken off (cancellation)
	avgCostAfter                int64 // per share
	gain                        int64 // net - cost taken off
}

// takeCost removes the average cost of q shares from h (all of it for the
// whole holding) and returns it. Call before the shares are removed.
func takeCost(h *holder, q int64) int64 {
	if q <= 0 || h.shares <= 0 {
		return 0
	}
	c := h.cost
	if q < h.shares {
		c = fundmath.MulDivDown(h.cost, q, h.shares)
	}
	h.cost -= c
	return c
}

func avgCost(h *holder) int64 {
	if h.shares <= 0 {
		return 0
	}
	return fundmath.MulDivDown(h.cost, u, h.shares)
}

func addNote(h *holder, kind int, shares, perf, net, cost int64, held bool) {
	noteSeq++
	nt := &note{n: noteSeq, period: cur0.n, valuedAt: cur0.valuedAt, height: heightNow(), kind: kind, holder: h.addr,
		navps: cur0.navps, shares: shares, holdingAfter: h.shares, perfFee: perf, net: net, held: held, cost: cost, avgCostAfter: avgCost(h)}
	switch kind {
	case noteSubscription:
		nt.gross = net
	case noteCrystallisation:
		nt.gross = perf
	default:
		nt.gross = net + perf
		nt.gain = net - cost
	}
	notes.Set(pad(noteSeq), nt)
	notesByKey.Set(h.addr.String()+"/"+pad(noteSeq), true)
}

// NoteCount returns the number of contract notes issued.
func NoteCount() int64 { return noteSeq }

// ---- pages ----

func renderNotePage(parts []string) string {
	if len(parts) == 2 && parts[0] == "note" {
		n, err := strconv.Atoi(parts[1])
		if err != nil || n < 1 || int64(n) > noteSeq {
			return "unknown note"
		}
		return renderNote(notes.Get(pad(int64(n))).(*note))
	}
	if parts[0] == "notes" && len(parts) >= 2 {
		a, rest := holderFromPath(parts[1:])
		if a == "" {
			return "invalid holder"
		}
		page := 1
		if len(rest) == 1 {
			p, err := strconv.Atoi(rest[0])
			if err != nil || p < 1 {
				return "invalid page"
			}
			page = p
		} else if len(rest) > 1 {
			return "404"
		}
		return renderNotesOf(a, page)
	}
	if parts[0] == "statement" && len(parts) >= 3 {
		a, rest := holderFromPath(parts[1:])
		if a == "" || len(rest) != 1 {
			return "invalid holder or year"
		}
		y, err := strconv.Atoi(rest[0])
		if err != nil || y < 2000 || y > 3000 {
			return "invalid year"
		}
		return renderStatement(a, int64(y))
	}
	return "404"
}

// holderFromPath reads "g1..." or "sub/<64 hex>" (a nominee sub-account).
func holderFromPath(p []string) (address, []string) {
	if len(p) >= 2 && p[0] == "sub" {
		if len(p[1]) != 64 {
			return "", nil
		}
		for _, r := range p[1] {
			if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
				return "", nil
			}
		}
		if nomineePath == "" {
			return "", nil
		}
		return subAccountAddr(p[1]), p[2:]
	}
	a := address(p[0])
	if !a.IsValid() {
		return "", nil
	}
	return a, p[1:]
}

func dateOf(t int64) string { return time.Unix(t, 0).UTC().Format("2006-01-02") }

func renderNote(nt *note) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Contract note %d\n\n", nt.n) + banner + nav() + noteCaveat)
	rows := [][2]string{
		{"Fund", FundName},
		{"Kind", noteKinds[nt.kind]},
		{"Holder", "`" + nt.holder.String() + "`"},
		{"Dealing period", ufmt.Sprintf("%d (valued %s UTC)", nt.period, dateOf(nt.valuedAt))},
		{"NAV per share", fmtAmt(nt.navps) + " tUSD"},
	}
	switch nt.kind {
	case noteSubscription:
		rows = append(rows, [2]string{"Amount subscribed", fmtAmt(nt.net) + " tUSD"}, [2]string{"Shares issued", fmtAmt(nt.shares)})
	case noteCrystallisation:
		rows = append(rows, [2]string{"Performance fee", fmtAmt(nt.perfFee) + " tUSD"}, [2]string{"Shares cancelled for the fee", fmtAmt(nt.shares)})
	default:
		paid := "Net amount paid"
		if nt.held {
			paid = "Net amount set aside (restricted holder)"
		}
		rows = append(rows,
			[2]string{"Shares cancelled", fmtAmt(nt.shares)},
			[2]string{"Gross value", fmtAmt(nt.gross) + " tUSD"},
			[2]string{"Performance fee", fmtAmt(nt.perfFee) + " tUSD"},
			[2]string{paid, fmtAmt(nt.net) + " tUSD"},
			[2]string{"Cost of the shares (average cost)", fmtAmt(nt.cost) + " tUSD"},
			[2]string{"Realised gain or loss", fmtAmt(nt.gain) + " tUSD"})
	}
	rows = append(rows, [2]string{"Holding after", fmtAmt(nt.holdingAfter) + " shares"}, [2]string{"Average cost per share after", fmtAmt(nt.avgCostAfter) + " tUSD"},
		[2]string{"Issued", ufmt.Sprintf("by the fund's code at block height %d", nt.height)})
	b.WriteString("| | |\n|---|---|\n")
	for _, r := range rows {
		b.WriteString("| " + r[0] + " | " + r[1] + " |\n")
	}
	return b.String()
}

func renderNotesOf(a address, page int) string {
	var b strings.Builder
	b.WriteString("# Contract notes\n\n" + banner + nav() + noteCaveat)
	b.WriteString("Holder `" + a.String() + "`. Newest first. Annual statement: `" + home() + ":statement/" + a.String() + "/<year>`.\n\n| Note | Period | Date | Kind | Shares | Net tUSD | Gain or loss |\n|---:|---:|---|---|---:|---:|---:|\n")
	prefix := a.String() + "/"
	var keys []string
	notesByKey.Iterate(prefix, prefix+"~", func(k string, _ any) bool {
		keys = append(keys, k)
		return false
	})
	pages := pageCount(len(keys), trailPageSize)
	if page > pages {
		return "invalid page"
	}
	for i := len(keys) - 1 - (page-1)*trailPageSize; i >= 0 && i > len(keys)-1-page*trailPageSize; i-- {
		nt := notes.Get(keys[i][len(prefix):]).(*note)
		b.WriteString(ufmt.Sprintf("| [%d](%s:note/%d) | %d | %s | %s | %s | %s | %s |\n", nt.n, home(), nt.n, nt.period, dateOf(nt.valuedAt), noteKinds[nt.kind], fmtAmt(nt.shares), fmtAmt(nt.net), fmtAmt(nt.gain)))
	}
	if page < pages {
		b.WriteString(ufmt.Sprintf("\n[Older](%s:notes/%s/%d)", home(), a.String(), page+1))
	}
	return b.String()
}

func renderStatement(a address, year int64) string {
	from := time.Date(int(year), time.January, 1, 0, 0, 0, 0, time.UTC).Unix()
	to := time.Date(int(year)+1, time.January, 1, 0, 0, 0, 0, time.UTC).Unix()
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Annual statement %d\n\n", year) + banner + nav() + noteCaveat)
	b.WriteString("Fund: " + FundName + ". Holder `" + a.String() + "`. Average cost method.\n\n| Note | Date | Kind | Shares | Net tUSD | Performance fee | Gain or loss |\n|---:|---|---|---:|---:|---:|---:|\n")
	prefix := a.String() + "/"
	var subscribed, received, perf, gain, holding, avg int64
	found := false
	notesByKey.Iterate(prefix, prefix+"~", func(k string, _ any) bool {
		nt := notes.Get(k[len(prefix):]).(*note)
		if nt.valuedAt >= to {
			return true
		}
		holding, avg, found = nt.holdingAfter, nt.avgCostAfter, true
		if nt.valuedAt < from {
			return false
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | %s | %s | %s |\n", nt.n, dateOf(nt.valuedAt), noteKinds[nt.kind], fmtAmt(nt.shares), fmtAmt(nt.net), fmtAmt(nt.perfFee), fmtAmt(nt.gain)))
		switch nt.kind {
		case noteSubscription:
			subscribed += nt.net
		case noteCrystallisation:
			perf += nt.perfFee
		default:
			received += nt.net
			perf += nt.perfFee
			gain += nt.gain
		}
		return false
	})
	if !found {
		return "no contract notes for this holder up to that year"
	}
	navps := yearEndNAVps(to)
	b.WriteString(ufmt.Sprintf("\n- Subscribed in the year: %s tUSD\n- Received in the year (paid or set aside): %s tUSD\n- Performance fees charged in the year: %s tUSD\n- Realised gain or loss in the year: %s tUSD\n", fmtAmt(subscribed), fmtAmt(received), fmtAmt(perf), fmtAmt(gain)))
	b.WriteString(ufmt.Sprintf("- Holding at the year end: %s shares, average cost %s tUSD per share\n", fmtAmt(holding), fmtAmt(avg)))
	if navps > 0 && holding > 0 {
		b.WriteString(ufmt.Sprintf("- Value at the last NAV of the year (%s tUSD per share): %s tUSD\n", fmtAmt(navps), fmtAmt(fundmath.MulDivDown(holding, navps, u))))
	}
	return b.String()
}

// yearEndNAVps is the NAV per share of the last period valued before t.
func yearEndNAVps(t int64) int64 {
	var v int64
	history.ReverseIterate("", "", func(_ string, x any) bool {
		r := x.(*record)
		if r.valuedAt < t {
			v = r.navps
			return true
		}
		return false
	})
	return v
}
