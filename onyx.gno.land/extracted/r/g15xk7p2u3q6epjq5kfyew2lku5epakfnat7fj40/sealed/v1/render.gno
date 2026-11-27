package sealed

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/seqid/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const homeListLimit = 20

// Render serves the realm's pages on gnoweb:
//
//	""             home: every auction with phase and countdown
//	"auction/<id>" one auction
func Render(path string) string {
	path = strings.Trim(path, "/")
	now := time.Now().Unix()
	if path == "" {
		return renderHome(now)
	}
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "auction" {
		if id, err := strconv.ParseUint(parts[1], 10, 64); err == nil {
			if v := auctions.Get(seqidKey(id)); v != nil {
				return renderAuction(v.(*Auction), now)
			}
		}
	}
	return "# Not found\n\nNo page at `" + path + "`. [Back to SEALED](" + baseLink() + ")\n"
}

func renderHome(now int64) string {
	var sb strings.Builder
	sb.WriteString("# SEALED\n\n")
	sb.WriteString("*Sealed-bid token launches. Speed becomes worthless.*\n\n")
	sb.WriteString("Bots win normal launches by buying first. Here, being first means nothing:\n\n")
	sb.WriteString("1. **Commit:** post a hash of your bid plus a GNOT deposit. Nobody can see any bid.\n")
	sb.WriteString("2. **Reveal:** open your bid. The realm checks it against your hash.\n")
	sb.WriteString("3. **Settle:** highest bids fill first, and **every winner pays the same clearing price**.\n\n")

	sb.WriteString("## Auctions\n\n")
	if auctions.Size() == 0 {
		sb.WriteString("No auctions yet.\n\n")
	} else {
		sb.WriteString("| Auction | Token | Supply | Reserve | Phase | Time left | Sealed bids |\n")
		sb.WriteString("|---|---|---:|---:|---|---|---:|\n")
		n := 0
		auctions.ReverseIterate("", "", func(_ string, v any) bool {
			a := v.(*Auction)
			sb.WriteString("| [#" + idStr(a) + "](" + auctionLink(a) + ") | " +
				tokenSymbol(a.Token) + " | " +
				formatInt(a.Supply) + " | " +
				formatGNOT(a.ReservePrice) + " | " +
				phaseBadge(a.phaseAt(now)) + " | " +
				timeLeft(a, now) + " | " +
				strconv.Itoa(a.bids.Size()) + " |\n")
			n++
			return n >= homeListLimit
		})
		sb.WriteString("\n")
	}

	sb.WriteString("---\n\n")
	sb.WriteString("**Launch a token:** approve `" + realmAddr.String() +
		"` on your GRC20 for the sale supply, then call `CreateAuction`.\n")
	return sb.String()
}

func renderAuction(a *Auction, now int64) string {
	var sb strings.Builder
	phase := a.phaseAt(now)
	sym := tokenSymbol(a.Token)

	sb.WriteString("# Auction #" + idStr(a) + ": " + formatInt(a.Supply) + " " + sym + "\n\n")
	sb.WriteString("[← All auctions](" + baseLink() + ")\n\n")
	sb.WriteString("**" + phaseBadge(phase) + "**")
	if tl := timeLeft(a, now); tl != "—" {
		sb.WriteString(" · " + tl + " left")
	}
	sb.WriteString("\n\n")

	sb.WriteString("- **Token:** `" + a.Token + "`\n")
	sb.WriteString("- **Seller:** `" + shortAddr(a.Seller) + "`\n")
	sb.WriteString("- **Supply:** " + formatInt(a.Supply) + " " + sym + "\n")
	sb.WriteString("- **Reserve price:** " + formatGNOT(a.ReservePrice) + " per " + sym + "\n")
	sb.WriteString("- **Commit ends:** " + formatTime(a.CommitEnd) + "\n")
	sb.WriteString("- **Reveal ends:** " + formatTime(a.RevealEnd) + "\n\n")

	sealedN := a.bids.Size()
	switch phase {
	case PhaseCommit:
		sb.WriteString("## 🔒 " + plural(sealedN, "sealed bid", "sealed bids") + "\n\n")
		sb.WriteString("Bid contents stay hidden. Only the count is public.\n\n")
		sb.WriteString("**To bid:** compute `sha256(yourAddress|price|amount|salt)` on your own machine, then call `Commit(" +
			idStr(a) + ", <hash>)` and send a GNOT deposit of at least price × amount (deposit more to hide your bid size; " +
			"the extra is refunded).\n")
	case PhaseReveal:
		sb.WriteString("## 🔓 Reveal phase\n\n")
		sb.WriteString("**" + strconv.Itoa(a.numRevealed) + " of " + strconv.Itoa(sealedN) + "** sealed bids revealed.\n\n")
		sb.WriteString("Call `Reveal(" + idStr(a) + ", price, amount, salt)` before the window closes. " +
			"A bid that is never revealed loses " + strconv.Itoa(ForfeitPercent) + "% of its deposit.\n")
	case PhaseClosed:
		sb.WriteString("## ⏳ Reveal closed\n\n")
		sb.WriteString("**" + strconv.Itoa(a.numRevealed) + " of " + strconv.Itoa(sealedN) +
			"** sealed bids revealed. Anyone can now call `Settle(" + idStr(a) + ")`.\n")
	case PhaseSettled:
		renderResults(&sb, a, sym)
	}
	return sb.String()
}

func renderResults(sb *strings.Builder, a *Auction, sym string) {
	sb.WriteString("## ✅ Results\n\n")
	sb.WriteString("| Clearing price | Sold | Total raised |\n")
	sb.WriteString("|---:|---:|---:|\n")
	sb.WriteString("| **" + formatGNOT(a.clearingPrice) + "** | " +
		formatInt(a.sold) + " / " + formatInt(a.Supply) + " " + sym + " | " +
		formatGNOT(a.raised) + " |\n\n")
	if a.sold > 0 {
		sb.WriteString("Every winner pays **" + formatGNOT(a.clearingPrice) + " per " + sym +
			"**, the lowest accepted bid, however high they bid and whenever they committed.\n\n")
	} else {
		sb.WriteString("No bid reached the reserve price, so nothing was sold.\n\n")
	}

	sellerState := "unclaimed"
	if a.sellerClaimed {
		sellerState = "claimed ✓"
	}
	sb.WriteString("- **Seller proceeds:** " + formatGNOT(a.raised) + " (" + sellerState + ")\n")
	sb.WriteString("- **Unsold, back to seller:** " + formatInt(a.Supply-a.sold) + " " + sym + "\n")
	if a.forfeits > 0 {
		sb.WriteString("- **Forfeits from no-shows:** " + formatGNOT(a.forfeits) +
			", shared by the winners in proportion to tokens won (never the seller)\n")
	}
	if a.burned > 0 {
		sb.WriteString("- **Burned:** " + formatGNOT(a.burned) +
			" (forfeits with no winner to receive them, or rounding), locked in the realm for good\n")
	}
	sb.WriteString("\n")

	// Revealed bids by price (highest first), then the no-shows.
	var revealed bidsByPrice
	var hidden []*Bid
	a.bids.Iterate("", "", func(_ string, v any) bool {
		b := v.(*Bid)
		if b.Revealed {
			revealed = append(revealed, b)
		} else {
			hidden = append(hidden, b)
		}
		return false
	})
	sort.Sort(revealed)

	sb.WriteString("### Bids\n\n")
	sb.WriteString("| Bidder | Bid price | Wanted | Won | Pays | Refund | Forfeit share | Result | Claimed |\n")
	sb.WriteString("|---|---:|---:|---:|---:|---:|---:|---|:---:|\n")
	for _, b := range revealed {
		o := a.outcomeOf(b)
		sb.WriteString("| `" + shortAddr(b.Bidder) + "` | " + formatGNOT(b.Price) + " | " +
			formatInt(b.Amount) + " | " + formatInt(o.Filled) + " | " + formatGNOT(o.Cost) + " | " +
			formatGNOT(o.Refund) + " | " + bonus(o.ForfeitShare) + " | " +
			statusIcon(o.Status) + o.Status + " | " + check(b.Claimed) + " |\n")
	}
	for _, b := range hidden {
		o := a.outcomeOf(b)
		sb.WriteString("| `" + shortAddr(b.Bidder) + "` | sealed | — | 0 | " + formatGNOT(0) + " | " +
			formatGNOT(o.Refund) + " | — | " + statusIcon(o.Status) + o.Status + " | " + check(b.Claimed) + " |\n")
	}
	if len(revealed)+len(hidden) == 0 {
		sb.WriteString("| — | — | — | — | — | — | — | No bids | — |\n")
	}
	sb.WriteString("\nWinners and refunds: call `Claim(" + idStr(a) + ")`.\n")
}

// ---------------------------------------------------------------------------
// Formatting helpers

func seqidKey(id uint64) string { return seqid.ID(id).Binary() }

func idStr(a *Auction) string { return strconv.FormatUint(uint64(a.ID), 10) }

func baseLink() string { return strings.TrimPrefix(realmPath, "gno.land") }

func auctionLink(a *Auction) string { return baseLink() + ":auction/" + idStr(a) }

func tokenSymbol(key string) string {
	if t := grc20reg.Get(key); t != nil {
		return t.GetSymbol()
	}
	return key
}

func phaseBadge(p Phase) string {
	switch p {
	case PhaseCommit:
		return "🔒 Commit"
	case PhaseReveal:
		return "🔓 Reveal"
	case PhaseClosed:
		return "⏳ Ready to settle"
	case PhaseSettled:
		return "✅ Settled"
	}
	return p.String()
}

func statusIcon(status string) string {
	switch {
	case status == "Won":
		return "🏆 "
	case status == "Partial fill":
		return "🌗 "
	case strings.HasPrefix(status, "No reveal"):
		return "⚠️ "
	}
	return "✖️ "
}

func bonus(ugnot int64) string {
	if ugnot == 0 {
		return "—"
	}
	return "+" + formatGNOT(ugnot)
}

func check(b bool) string {
	if b {
		return "✓"
	}
	return "—"
}

func timeLeft(a *Auction, now int64) string {
	switch a.phaseAt(now) {
	case PhaseCommit:
		return formatDuration(a.CommitEnd - now)
	case PhaseReveal:
		return formatDuration(a.RevealEnd - now)
	}
	return "—"
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

func shortAddr(addr address) string {
	s := addr.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// formatInt adds thousands separators: 1234567 -> "1,234,567".
func formatInt(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var out []byte
	for i := 0; i < len(s); i++ {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, s[i])
	}
	if neg {
		return "-" + string(out)
	}
	return string(out)
}

// formatGNOT renders ugnot as GNOT: 1500000 -> "1.5 GNOT".
func formatGNOT(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac < 0 {
		frac = -frac
	}
	s := formatInt(whole)
	if frac != 0 {
		f := strconv.FormatInt(frac+1_000_000, 10)[1:] // zero-pad to 6 digits
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " GNOT"
}

func formatTime(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04:05 UTC")
}

func formatDuration(secs int64) string {
	if secs <= 0 {
		return "0s"
	}
	d, h, m, s := secs/86400, (secs%86400)/3600, (secs%3600)/60, secs%60
	switch {
	case d > 0:
		return strconv.FormatInt(d, 10) + "d " + strconv.FormatInt(h, 10) + "h"
	case h > 0:
		return strconv.FormatInt(h, 10) + "h " + strconv.FormatInt(m, 10) + "m"
	case m > 0:
		return strconv.FormatInt(m, 10) + "m " + strconv.FormatInt(s, 10) + "s"
	}
	return strconv.FormatInt(s, 10) + "s"
}
