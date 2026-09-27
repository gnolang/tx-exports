package otc

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// Reads do not refuse coins: the envelope belongs to the whole message, so a
// guard here would break any realm that reads an offer inside a paid call of
// its own. Only writes are guarded.
//
// Amounts in JSON are strings: int64 does not fit a JavaScript number.

func RealmAddress() address { return realmAddr }

// GetOffer returns one offer as JSON, public or private.
func GetOffer(id uint64) string { return offerJSON(mustOffer(id)) }

// ListOpen returns open public offers, newest first (S9).
func ListOpen(offset, limit int) string {
	return listJSON(&openPublic, offset, limit)
}

// ListByMaker returns every offer of one maker, private and closed ones
// included, newest first.
func ListByMaker(addr string, offset, limit int) string {
	v := byMaker.Get(addr)
	if v == nil {
		return `{"total":0,"offers":[]}`
	}
	return listJSON(v.(*avl.Tree), offset, limit)
}

// GetConfig returns the parameters and the whitelist as JSON.
func GetConfig() string {
	var b strings.Builder
	b.WriteString(`{"realm":` + jstr(realmAddr.String()))
	b.WriteString(`,"admin":` + jstr(admin.String()))
	b.WriteString(`,"fee_recipient":` + jstr(feeRecipient.String()))
	b.WriteString(`,"fee_bps":` + num(feeBps))
	b.WriteString(`,"fee_cap_bps":` + num(feeCapBps))
	b.WriteString(`,"gnomic_key":` + jstr(gnomicKey))
	b.WriteString(`,"gnomic_fee_enabled":` + strconv.FormatBool(gnomicFeeOn))
	b.WriteString(`,"gnomic_fee_bps":` + num(gnomicFee))
	b.WriteString(`,"paused":` + strconv.FormatBool(paused))
	b.WriteString(`,"max_page_size":` + strconv.Itoa(maxPageSize))
	b.WriteString(`,"tokens":[`)
	i := 0
	tokens.Iterate("", "", func(key string, v any) bool { // bounded by maxTokens
		if i > 0 {
			b.WriteString(",")
		}
		i++
		sym, dec := tokenInfo(key)
		b.WriteString(`{"key":` + jstr(key) + `,"symbol":` + jstr(sym) +
			`,"decimals":` + strconv.Itoa(dec) + `,"enabled":` + strconv.FormatBool(v.(bool)) + `}`)
		return false
	})
	b.WriteString("]}")
	return b.String()
}

// GetStats returns the running totals as JSON (F7).
func GetStats() string {
	return `{"total_fees_ugnot":` + jstr(num(totalFees)) +
		`,"total_volume_ugnot":` + jstr(num(totalVolume)) +
		`,"filled":` + num(filledCount) +
		`,"offers":` + strconv.FormatUint(lastID, 10) +
		`,"open_public":` + strconv.Itoa(openPublic.Size()) + `}`
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render serves "" (stats and the first page), "page/N" and "offer/ID".
func Render(path string) string {
	switch {
	case path == "":
		return renderHome(1)
	case strings.HasPrefix(path, "page/"):
		n, err := strconv.Atoi(path[len("page/"):])
		if err != nil || n < 1 {
			return "# Not found\n"
		}
		return renderHome(n)
	case strings.HasPrefix(path, "offer/"):
		id, err := strconv.ParseUint(path[len("offer/"):], 10, 64)
		if err != nil || !offers.Has(padID(id)) {
			return "# Not found\n"
		}
		return renderOffer(mustOffer(id))
	}
	return "# Not found\n"
}

func renderHome(page int) string {
	var b strings.Builder
	b.WriteString("# Gnomic OTC\n\n")
	b.WriteString("Escrowed GRC20 ⇄ GNOT offers, filled in full and atomically.\n\n")
	if paused {
		b.WriteString("**Paused:** no new offers or fills. Makers can still cancel.\n\n")
	}
	b.WriteString("| Volume | Fees | Filled | Open (public) | Fee |\n|---|---|---|---|---|\n")
	b.WriteString("| " + units(totalVolume, 6) + " GNOT | " + units(totalFees, 6) + " GNOT | " +
		num(filledCount) + " | " + strconv.Itoa(openPublic.Size()) + " | " + bps(feeBps))
	if gnomicFeeOn {
		b.WriteString(" (GNOMIC " + bps(gnomicFee) + ")")
	}
	b.WriteString(" |\n\n")

	b.WriteString("## Open offers\n\n")
	size := openPublic.Size()
	// Compared as page numbers, not as an offset: (page-1)*pageSize overflows
	// for a large enough page.
	if page > 1 && page-1 > (size-1)/defaultPageSize {
		return "# Not found\n"
	}
	if size == 0 {
		b.WriteString("No open offers.\n")
		return b.String()
	}
	offset := (page - 1) * defaultPageSize
	b.WriteString("| ID | Side | Token | Amount | GNOT | Maker | Expires |\n|---|---|---|---|---|---|---|\n")
	openPublic.ReverseIterateByOffset(offset, defaultPageSize, func(key string, _ any) bool {
		o := offers.Get(key).(*Offer)
		sym, dec := tokenInfo(o.TokenKey)
		b.WriteString("| [" + num64(o.ID) + "](" + link("offer/"+num64(o.ID)) + ") | " + o.Side.String() +
			" | " + sym + " | " + units(o.TokenAmt, dec) + " | " + units(o.GnotAmt, 6) +
			" | " + short(o.Maker) + " | " + expiry(o) + " |\n")
		return false
	})
	if page > 1 {
		b.WriteString("\n[← newer](" + link("page/"+strconv.Itoa(page-1)) + ")")
	}
	if offset+defaultPageSize < size {
		b.WriteString("\n[older →](" + link("page/"+strconv.Itoa(page+1)) + ")")
	}
	b.WriteString("\n")
	return b.String()
}

func renderOffer(o *Offer) string {
	sym, dec := tokenInfo(o.TokenKey)
	fee := feeOf(o.GnotAmt, o.FeeBps)
	var b strings.Builder
	b.WriteString("# Offer " + num64(o.ID) + "\n\n")
	b.WriteString("| | |\n|---|---|\n")
	if o.Status == Open && expired(o) {
		b.WriteString("| Status | Open, expired: it can no longer be filled, only cancelled by its maker |\n")
	} else {
		b.WriteString("| Status | " + o.Status.String() + " |\n")
	}
	b.WriteString("| Side | " + o.Side.String() + " |\n")
	b.WriteString("| Token | " + sym + " (`" + o.TokenKey + "`) |\n")
	b.WriteString("| Token amount | " + units(o.TokenAmt, dec) + " " + sym + " |\n")
	b.WriteString("| GNOT amount | " + units(o.GnotAmt, 6) + " GNOT |\n")
	b.WriteString("| Fee | " + bps(o.FeeBps) + " = " + units(fee, 6) + " GNOT, paid by whoever receives the GNOT |\n")
	b.WriteString("| Maker | `" + o.Maker.String() + "` |\n")
	if o.Taker == "" {
		b.WriteString("| Taker | anyone |\n")
	} else {
		b.WriteString("| Taker | `" + o.Taker.String() + "` (not listed) |\n")
	}
	b.WriteString("| Created | " + when(o.CreatedAt) + " |\n")
	b.WriteString("| Expires | " + expiry(o) + " |\n")
	b.WriteString("\n[← all offers](" + link("") + ")\n")
	return b.String()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func listJSON(t *avl.Tree, offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = defaultPageSize
	}
	if limit > maxPageSize {
		limit = maxPageSize
	}
	var b strings.Builder
	b.WriteString(`{"total":` + strconv.Itoa(t.Size()) + `,"offers":[`)
	i := 0
	t.ReverseIterateByOffset(offset, limit, func(key string, _ any) bool {
		if i > 0 {
			b.WriteString(",")
		}
		i++
		b.WriteString(offerJSON(offers.Get(key).(*Offer)))
		return false
	})
	b.WriteString("]}")
	return b.String()
}

func offerJSON(o *Offer) string {
	sym, dec := tokenInfo(o.TokenKey)
	return `{"id":` + jstr(num64(o.ID)) +
		`,"maker":` + jstr(o.Maker.String()) +
		`,"taker":` + jstr(o.Taker.String()) +
		`,"side":` + jstr(o.Side.String()) +
		`,"token_key":` + jstr(o.TokenKey) +
		`,"token_symbol":` + jstr(sym) +
		`,"token_decimals":` + strconv.Itoa(dec) +
		`,"token_amt":` + jstr(num(o.TokenAmt)) +
		`,"gnot_amt":` + jstr(num(o.GnotAmt)) +
		`,"fee_bps":` + num(o.FeeBps) +
		`,"fee_ugnot":` + jstr(num(feeOf(o.GnotAmt, o.FeeBps))) +
		`,"expires_at":` + num(o.ExpiresAt) +
		`,"expired":` + strconv.FormatBool(expired(o)) +
		`,"created_at":` + num(o.CreatedAt) +
		`,"status":` + jstr(o.Status.String()) + `}`
}

func tokenInfo(key string) (string, int) {
	t := grc20reg.Get(key)
	if t == nil {
		return key, 0
	}
	return t.GetSymbol(), t.GetDecimals()
}

// jstr quotes a string for JSON.
func jstr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r < 0x20:
			h := strconv.FormatInt(int64(r), 16)
			b.WriteString(`\u` + strings.Repeat("0", 4-len(h)) + h)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func num(v int64) string    { return strconv.FormatInt(v, 10) }
func num64(v uint64) string { return strconv.FormatUint(v, 10) }

// units formats base units with dec decimals, trailing zeros dropped.
func units(v int64, dec int) string {
	s := strconv.FormatInt(v, 10)
	if dec <= 0 {
		return s
	}
	if len(s) <= dec {
		s = strings.Repeat("0", dec-len(s)+1) + s
	}
	whole, frac := s[:len(s)-dec], strings.TrimRight(s[len(s)-dec:], "0")
	if frac == "" {
		return whole
	}
	return whole + "." + frac
}

func bps(v int64) string { return units(v, 2) + "%" }

func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// link is an absolute gnoweb link to one of this realm's Render paths.
// gnoweb rejects a bare ":path" destination and prints it as plain text.
func link(path string) string {
	if path == "" {
		return webPath
	}
	return webPath + ":" + path
}

// expiry is the Expires cell: the date, marked once it has passed.
func expiry(o *Offer) string {
	if expired(o) {
		return "expired " + when(o.ExpiresAt)
	}
	return when(o.ExpiresAt)
}

func when(unix int64) string {
	if unix == 0 {
		return "never"
	}
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
}
