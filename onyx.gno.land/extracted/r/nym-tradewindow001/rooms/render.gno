package rooms

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// Render shows the realm on gnoweb: the home page lists recent rooms, and
// room/<id> shows one room. Every value that comes from a caller goes
// through sanitize before it reaches the markdown.
func Render(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return renderHome()
	}
	if rest, ok := strings.CutPrefix(path, "room/"); ok {
		id, err := strconv.ParseUint(rest, 10, 64)
		if err == nil {
			if v := rooms.Get(roomKey(id)); v != nil {
				return renderRoom(v.(*room), time.Now().Unix())
			}
		}
	}
	return "# Not found\n\nNo room at this address.\n"
}

func renderHome() string {
	now := time.Now().Unix()
	var b strings.Builder
	b.WriteString("# Trade Window rooms\n\n")
	b.WriteString("Two parties put assets into a room. Each change raises the room's version. ")
	b.WriteString("Both lock the same version, and the second lock swaps everything in one transaction. ")
	b.WriteString("Until then either side can withdraw or cancel. ")
	b.WriteString("A room can also be an offer: the maker's side and an exact list of what they want, filled by the first allowed account in one transaction.\n\n")
	if fee := openingFee(); fee > 0 {
		b.WriteString("Service fee on settlement: " + decimal(int64(fee), 2) + "% of every coin and token that crosses, from each side. NFTs, withdrawals and cancellations pay nothing.\n\n")
	}
	b.WriteString("Rooms opened: " + jsonUint(lastID) +
		", settled: " + jsonUint(nSettled) +
		", cancelled: " + jsonUint(nCancelled) + ".\n\n")
	if paused {
		b.WriteString("New activity is paused. Withdraw, unlock and cancel still work.\n\n")
	}
	if lastID == 0 {
		b.WriteString("No rooms yet.\n")
		return b.String()
	}
	b.WriteString("## Latest\n\n")
	rooms.ReverseIterateByOffset(0, 20, func(_ string, v any) bool {
		r := v.(*room)
		b.WriteString("- [Room " + jsonUint(r.id) + "](:room/" + jsonUint(r.id) + "): " +
			r.statusLabel(now) + ", " + sideSummary(&r.maker) + " for " + sideSummary(&r.taker) + "\n")
		return false
	})
	return b.String()
}

func renderRoom(r *room, now int64) string {
	var b strings.Builder
	b.WriteString("# Room " + jsonUint(r.id) + "\n\n")
	b.WriteString("Status: " + r.statusLabel(now) + ", version " + jsonUint(r.version) + ".\n\n")
	b.WriteString("Opened " + stamp(r.createdAt))
	if r.status == StatusOpen {
		b.WriteString(". Can settle until " + stamp(r.expiresAt))
	} else if r.closedAt != 0 {
		b.WriteString(". Closed " + stamp(r.closedAt))
	}
	b.WriteString(".")
	if r.openMarket {
		b.WriteString(" Open market: this room takes any registered asset, verified or not.")
	} else {
		b.WriteString(" Verified assets only.")
	}
	if r.feeBps > 0 {
		b.WriteString(" Fee on settlement: " + decimal(int64(r.feeBps), 2) + "% of coins and tokens, from each side.")
	}
	b.WriteString("\n\n")
	b.WriteString(renderSide("Maker", &r.maker, r.version))
	if len(r.want) > 0 {
		b.WriteString("## Offer\n\nThe maker wants exactly this in return; the first allowed account that puts it in completes the trade:\n\n")
		for _, a := range r.want {
			b.WriteString("- " + sanitize.InlineText(formatAsset(a)) + ", " + sanitize.InlineCode(a.denom) + "\n")
		}
		b.WriteString("\n")
	}
	if r.taker.owner == "" && len(r.want) > 0 {
		b.WriteString("## Taker\n\nThe seat is open: any account can fill the offer.\n\n")
	} else if r.taker.owner == "" {
		b.WriteString("## Taker\n\nThe seat is open: any account can join.\n\n")
	} else {
		b.WriteString(renderSide("Taker", &r.taker, r.version))
	}
	return b.String()
}

func renderSide(title string, s *side, version uint64) string {
	var b strings.Builder
	b.WriteString("## " + title + "\n\n")
	b.WriteString(sanitize.InlineCode(s.owner.String()))
	if s.locked != 0 && s.locked == version {
		b.WriteString(", locked this version")
	}
	b.WriteString("\n\n")
	if len(s.assets) == 0 {
		b.WriteString("Nothing deposited.\n\n")
		return b.String()
	}
	for _, a := range s.assets {
		b.WriteString("- " + sanitize.InlineText(formatAsset(a)) + ", " + sanitize.InlineCode(a.denom) + "\n")
	}
	b.WriteString("\n")
	return b.String()
}

func sideSummary(s *side) string {
	if len(s.assets) == 0 {
		return "nothing"
	}
	parts := make([]string, 0, len(s.assets))
	for _, a := range s.assets {
		parts = append(parts, sanitize.InlineText(formatAsset(a)))
	}
	return strings.Join(parts, " and ")
}

// wugnotKey is wrapped GNOT in the GRC20 registry. Its token declares 0
// decimals because one unit is one ugnot, so it is shown in GNOT like the
// coin, marked as wrapped so the two are never confused.
const wugnotKey = "gno.land/r/gnoland/wugnot.wugnot"

// formatAsset writes an amount in whole units: GNOT for ugnot and wrapped
// GNOT, the registry's symbol and decimals for other tokens, the raw denom
// otherwise.
func formatAsset(a asset) string {
	switch {
	case a.kind == KindCoin && a.denom == "ugnot":
		return decimal(a.amount, 6) + " GNOT"
	case a.kind == KindToken && a.denom == wugnotKey:
		return decimal(a.amount, 6) + " GNOT (wrapped)"
	case a.kind == KindToken:
		if tok := grc20reg.Get(a.denom); tok != nil {
			return decimal(a.amount, tok.GetDecimals()) + " " + tok.GetSymbol()
		}
	case a.kind == KindNFT:
		key, tid, _ := strings.Cut(a.denom, "#")
		if v := collections.Get(key); v != nil {
			return "NFT " + v.(*collection).token.GetName() + " #" + tid
		}
		return "NFT #" + tid
	}
	return strconv.FormatInt(a.amount, 10) + " " + a.denom
}

// decimal formats amount with the given number of decimals and no
// trailing zeros.
func decimal(amount int64, decimals int) string {
	s := strconv.FormatInt(amount, 10)
	if decimals <= 0 {
		return s
	}
	if len(s) <= decimals {
		s = strings.Repeat("0", decimals-len(s)+1) + s
	}
	whole, frac := s[:len(s)-decimals], strings.TrimRight(s[len(s)-decimals:], "0")
	if frac == "" {
		return whole
	}
	return whole + "." + frac
}

func (r *room) statusLabel(now int64) string {
	if r.status == StatusOpen && now >= r.expiresAt {
		return "expired"
	}
	return r.status
}

// stamp writes unix seconds as an RFC 3339 time in UTC.
func stamp(unix int64) string {
	return time.Unix(unix, 0).UTC().Format(time.RFC3339)
}
