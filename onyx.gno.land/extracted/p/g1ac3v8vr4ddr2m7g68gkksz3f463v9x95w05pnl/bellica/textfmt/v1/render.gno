package textfmt

import (
	"strconv"
	"strings"
	"time"
)

// statColumns renders label/value pairs as a row of big numbers.
func StatColumns(kv ...string) string {
	var sb strings.Builder
	sb.WriteString("<gno-columns>\n")
	for i := 0; i+1 < len(kv); i += 2 {
		if i > 0 {
			sb.WriteString("<gno-columns-sep />\n")
		}
		sb.WriteString("**" + kv[i] + "**\n\n" + kv[i+1] + "\n")
	}
	sb.WriteString("</gno-columns>\n\n")
	return sb.String()
}

// gapString shows score - best without int64 overflow (AUDIT F8).
func GapString(score, best int64) string {
	if score == best {
		return "lead"
	}
	d := score - best
	if (score > best) != (d > 0) { // overflowed
		if score > best {
			return "+9223372036854775807"
		}
		return "-9223372036854775808"
	}
	if d > 0 {
		return "+" + strconv.FormatInt(d, 10)
	}
	return strconv.FormatInt(d, 10)
}

func Gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strconv.FormatInt(frac+1_000_000, 10)[1:]
	f = strings.TrimRight(f, "0")
	return strconv.FormatInt(whole, 10) + "." + f + " GNOT"
}

func Fixed1(tenths int) string {
	return strconv.Itoa(tenths/10) + "." + strconv.Itoa(tenths%10)
}

func Medal(r int) string {
	switch r {
	case 1:
		return "🥇 1st"
	case 2:
		return "🥈 2nd"
	case 3:
		return "🥉 3rd"
	}
	return strconv.Itoa(r) + "th"
}

func Relative(t time.Time) string {
	d := t.Sub(time.Now())
	if d >= 0 {
		return "in " + Dur(d)
	}
	return Dur(-d) + " ago"
}

func Dur(d time.Duration) string {
	m := int64(d / time.Minute)
	switch {
	case m < 1:
		return "<1m"
	case m < 60:
		return strconv.FormatInt(m, 10) + "m"
	case m < 24*60:
		return strconv.FormatInt(m/60, 10) + "h " + strconv.FormatInt(m%60, 10) + "m"
	}
	return strconv.FormatInt(m/(24*60), 10) + "d " + strconv.FormatInt((m/60)%24, 10) + "h"
}

func When(t time.Time) string {
	return t.UTC().Format("2006-01-02 15:04 UTC")
}

func shortCommit(c string) string {
	if len(c) > 10 {
		return c[:10]
	}
	return c
}

// link renders a user URL only if it is http(s); otherwise as escaped text.
func Link(u string) string {
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		if !strings.ContainsAny(u, " ()<>[]\"'`|") {
			return "[" + Esc(trimScheme(u)) + "](" + u + ")"
		}
	}
	return Esc(u)
}

// trimScheme is the visible label of a link: the full host (never cut, so a
// look-alike host cannot hide its real domain, AUDIT F6) plus the path cut to
// 30 runes on a rune boundary.
func trimScheme(u string) string {
	u = strings.TrimPrefix(strings.TrimPrefix(u, "https://"), "http://")
	host, rest := u, ""
	if i := strings.IndexAny(u, "/?#"); i >= 0 {
		host, rest = u[:i], u[i:]
	}
	if r := []rune(rest); len(r) > 30 {
		rest = string(r[:29]) + "…"
	}
	return host + rest
}

// esc neutralizes markdown/HTML in user-supplied text, including gnoweb's
// extensions: '&' (HTML entities such as &rlm;), '@' (user mentions) and '$'
// (KaTeX math) (AUDIT F2).
func Esc(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '\\', '`', '*', '_', '[', ']', '(', ')', '#', '|', '<', '>', '!', '~', '&', '@', '$':
			sb.WriteRune('\\')
		}
		sb.WriteRune(r)
	}
	return sb.String()
}
