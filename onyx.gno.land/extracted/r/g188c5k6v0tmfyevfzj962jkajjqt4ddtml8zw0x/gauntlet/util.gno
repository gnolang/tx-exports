package gauntlet

import (
	"strconv"
	"strings"
	"time"
)

func itoa(n uint64) string  { return strconv.FormatUint(n, 10) }
func i64toa(n int64) string { return strconv.FormatInt(n, 10) }

// gnot formats ugnot as GNOT with up to 6 decimals.
func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	if frac == 0 {
		return i64toa(whole) + " GNOT"
	}
	f := strconv.FormatInt(frac+1_000_000, 10)[1:]
	f = strings.TrimRight(f, "0")
	return i64toa(whole) + "." + f + " GNOT"
}

func when(t time.Time) string { return t.UTC().Format("Jan 2, 15:04 UTC") }

// left describes time remaining until t, from now.
func left(now, t time.Time) string {
	d := t.Sub(now)
	if d <= 0 {
		return "ended"
	}
	h := int64(d.Hours())
	if h >= 48 {
		return i64toa(h/24) + " days left"
	}
	if h >= 1 {
		return i64toa(h) + "h left"
	}
	return i64toa(int64(d.Minutes())) + "m left"
}

func short(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// webPath turns gno.land/r/x into /r/x for gnoweb links.
func webPath(pkgPath string) string {
	if i := strings.Index(pkgPath, "/"); i >= 0 {
		return pkgPath[i:]
	}
	return pkgPath
}

func jstr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[r>>4])
				b.WriteByte(hex[r&0xf])
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
