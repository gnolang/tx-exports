package catalog

import (
	"strconv"
	"strings"
	"unicode"

	"gno.land/p/nym-alexiscolin000/gnoradio/safe/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

func mustText(field, s string, min, max int) {
	if !text.Valid(s, min, max) {
		panic("catalog: " + field + " must be " + text.Itoa(min) + "-" + text.Itoa(max) +
			" characters: letters, digits, spaces and . , ' - ! ? : / & only")
	}
	// A report reason may quote what it reports (/moderation masks it).
	if field != "reason" && safe.Slur(s) {
		panic("catalog: " + field + " holds a slur")
	}
}

// validName restricts artist names to ASCII letters and digits plus the
// Latin-1 accented letters, so look-alike names cannot impersonate an artist.
func validName(s string) bool {
	if strings.TrimSpace(s) != s || strings.Contains(s, "  ") {
		return false
	}
	n, alnum := 0, 0
	for _, r := range s {
		n++
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			(r >= 0xC0 && r <= 0xFF && r != 0xD7 && r != 0xF7) {
			alnum++
			continue
		}
		switch r {
		case ' ', '.', '\'', '-', '&':
			continue
		}
		return false
	}
	// At least one letter or digit, so the reserved skeleton is never empty.
	return n >= 2 && n <= 40 && alnum > 0
}

// latin1 folds the Latin-1 letters 0xC0-0xFF (lowercased) to ASCII.
var latin1 = [64]string{
	"a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
	"d", "n", "o", "o", "o", "o", "o", "", "o", "u", "u", "u", "u", "y", "th", "ss",
	"a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
	"d", "n", "o", "o", "o", "o", "o", "", "o", "u", "u", "u", "u", "y", "th", "y",
}

// skeleton is the key an artist name is reserved under: lowercase, common
// Latin accents stripped, fullwidth letters and digits mapped to ASCII,
// spaces and punctuation dropped and look-alikes folded (i/l/1 → l, 0 → o,
// 3 → e, 4 → a, 5 → s, 7 → t, 9 → g, u → v, rn → m, vv → w, cl → d), so
// "Beyonce", "BEYONCÉ", "Ｂｅｙｏｎｃｅ", "Daft  Punk", "DAFT PUNK", "Kanye
// Vvest", "Kanye Uuest", "Clrake" and "9orillaz" collide with the real names.
func skeleton(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case ' ', '.', '\'', '-', '&', 0x3000:
			continue
		}
		switch {
		case r >= 0xFF21 && r <= 0xFF3A:
			r = r - 0xFF21 + 'a'
		case r >= 0xFF41 && r <= 0xFF5A:
			r = r - 0xFF41 + 'a'
		case r >= 0xFF10 && r <= 0xFF19:
			r = r - 0xFF10 + '0'
		}
		r = unicode.ToLower(r)
		if r >= 0xC0 && r <= 0xFF && latin1[r-0xC0] != "" {
			b.WriteString(confusable(latin1[r-0xC0]))
			continue
		}
		b.WriteString(confusable(string(r)))
	}
	k := strings.ReplaceAll(b.String(), "rn", "m")
	k = strings.ReplaceAll(k, "vv", "w")
	return strings.ReplaceAll(k, "cl", "d")
}

// confusable folds characters that look alike in common fonts.
func confusable(s string) string {
	switch s {
	case "i", "1", "|":
		return "l"
	case "0":
		return "o"
	case "3":
		return "e"
	case "4":
		return "a"
	case "5":
		return "s"
	case "7":
		return "t"
	case "9":
		return "g"
	case "u":
		return "v" // before the vv → w fold: "uu" and "vu" pass for w too
	}
	return s
}

// Reserved names, as skeletons: a name holding a stem anywhere, or one of
// the words as a word, could pass for GnoRadio, its staff, the chain
// (gno.land folds to gnoland), the wallet (Adena) or the audio source
// (Audius). Adena and Audius are prefixes, not stems: refused at the start
// of the name or of any word in it ("AdenaWallet", "Ade-na", "Audius2"),
// while names that only end with them pass ("Pasadena", "La Cadena",
// "Claudius").
var (
	reservedStems = []string{skeleton("gnoradio"), skeleton("moderator"), skeleton("moderation"),
		skeleton("treasury"), skeleton("administrator"), skeleton("gnoland")}
	reservedWords    = []string{skeleton("admin"), skeleton("staff"), skeleton("official")}
	reservedPrefixes = []string{skeleton("adena"), skeleton("audius")}
)

func reserved(name string) bool {
	k := skeleton(name)
	for _, s := range reservedStems {
		if strings.Contains(k, s) {
			return true
		}
	}
	for _, s := range reservedWords {
		if strings.Contains(k, s) && anyWord(name, func(w string) bool { return w == s }) {
			return true
		}
	}
	for _, s := range reservedPrefixes {
		if strings.HasPrefix(k, s) || strings.Contains(k, s) && anyWord(name, func(w string) bool { return strings.HasPrefix(w, s) }) {
			return true
		}
	}
	return false
}

// anyWord reports whether the skeleton of a word of name passes ok.
func anyWord(name string, ok func(string) bool) bool {
	for _, w := range strings.FieldsFunc(name, func(r rune) bool { return strings.ContainsRune(" .'-&", r) }) {
		if ok(skeleton(w)) {
			return true
		}
	}
	return false
}

func mustName(s string) {
	if !validName(s) {
		panic("catalog: artist name must be 2-40 characters: Latin letters (a-z and Latin-1 accents), digits, spaces and . ' - &")
	}
	if safe.Slur(s) {
		panic("catalog: artist name holds a slur")
	}
	if reserved(s) {
		panic("catalog: this artist name is reserved for GnoRadio, gno.land, Adena or Audius")
	}
}

func alnum(s string, min, max int) bool {
	if len(s) < min || len(s) > max {
		return false
	}
	for _, c := range s {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func validHost(h string) bool {
	if len(h) < 3 || len(h) > 100 || !strings.Contains(h, ".") {
		return false
	}
	for _, c := range h {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '.' && c != '-' {
			return false
		}
	}
	return true
}

// hostOf is the authority of an https link: up to the first / ? or #
// (lower case). It is a plain host only when validHost says so.
func hostOf(url string) string {
	rest := strings.TrimPrefix(url, "https://")
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		rest = rest[:i]
	}
	return strings.ToLower(rest)
}

func isSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// mustMedia checks an audio or cover reference:
//
//	ipfs://<cid>        content-addressed, sha256 optional
//	ar://<txid>         Arweave, sha256 optional
//	audius:<trackId>    audio only, streamed through the Audius API
//	jamendo:<trackId>   audio only, streamed from Jamendo
//	https://<host>/…    host must be allowed, sha256 required
func mustMedia(field, uri, sha string, audioField bool) {
	if sha != "" && !isSHA256(sha) {
		panic("catalog: " + field + " sha256 must be 64 hex characters")
	}
	switch {
	case strings.HasPrefix(uri, "ipfs://"):
		if !alnum(strings.TrimPrefix(uri, "ipfs://"), 46, 100) {
			panic("catalog: " + field + " ipfs:// needs a valid CID")
		}
	case strings.HasPrefix(uri, "ar://"):
		id := strings.TrimPrefix(uri, "ar://")
		if len(id) != 43 || !text.URLChars(id) {
			panic("catalog: " + field + " ar:// needs a 43-character transaction id")
		}
	case strings.HasPrefix(uri, "audius:"), strings.HasPrefix(uri, "jamendo:"):
		_, id, _ := strings.Cut(uri, ":")
		if !audioField || !alnum(id, 1, 32) {
			panic("catalog: " + field + " audius:<id> or jamendo:<id> is only valid for audio")
		}
	case strings.HasPrefix(uri, "https://"):
		if !text.HTTPS(uri, 300) || !data.Has(cHosts, hostOf(uri)) {
			panic("catalog: " + field + " host is not allowed (ask the admin to add it)")
		}
		if sha == "" {
			panic("catalog: " + field + " over https needs the file's sha256")
		}
	default:
		panic("catalog: " + field + " must be ipfs://, ar://, audius:, jamendo: or an allowed https:// link")
	}
}

// normLicense maps loose input ("cc by", "cc-by-4.0", "CC0") to an SPDX id.
func normLicense(s string) string {
	s = strings.ToUpper(strings.TrimSpace(s))
	s = strings.ReplaceAll(s, " ", "-")
	s = strings.ReplaceAll(s, "_", "-")
	if s == "CC0" {
		s = "CC0-1.0"
	}
	if strings.HasPrefix(s, "CC-") && !strings.HasSuffix(s, "-4.0") {
		s += "-4.0"
	}
	for _, l := range licenses {
		if s == l {
			return l
		}
	}
	return ""
}

// parseClock parses "m:ss" (or plain seconds) into seconds.
func parseClock(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	m, sec, hasColon := strings.Cut(s, ":")
	if !hasColon {
		if !text.Digits(s) || len(s) > 5 {
			return 0, false
		}
		v, _ := strconv.ParseInt(s, 10, 64)
		return v, true
	}
	if len(m) > 3 || len(sec) != 2 || !text.Digits(m) || !text.Digits(sec) {
		return 0, false
	}
	mv, _ := strconv.ParseInt(m, 10, 64)
	sv, _ := strconv.ParseInt(sec, 10, 64)
	if sv > 59 {
		return 0, false
	}
	return mv*60 + sv, true
}

// parseIDs parses "12,40,7" into distinct ids, at most max of them.
func parseIDs(s string, max int) []int {
	s = strings.TrimSpace(s)
	if s == "" {
		panic("catalog: list at least one track id")
	}
	parts := strings.Split(s, ",")
	if len(parts) > max {
		panic("catalog: at most " + text.Itoa(max) + " tracks")
	}
	out := make([]int, 0, len(parts))
	seen := map[int]bool{}
	for _, p := range parts {
		p = strings.TrimSpace(p)
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || !text.Digits(p) {
			panic("catalog: track ids as 12,40,7")
		}
		if seen[n] {
			panic("catalog: duplicate track " + text.Itoa(n))
		}
		seen[n] = true
		out = append(out, n)
	}
	return out
}

// curatedLicense accepts the redistributable licenses curated imports may
// carry, in any version and national port: CC0-1.0, CC-BY-<v>[-XX],
// CC-BY-SA-<v>[-XX], CC-BY-NC-<v>[-XX], CC-BY-NC-SA-<v>[-XX] (v = 1.0, 2.0, 2.5, 3.0, 4.0). It returns the normalized
// id, or "" when the license is not allowed.
func curatedLicense(s string) string {
	s = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(s), " ", "-"))
	if s == "CC0" || s == "CC0-1.0" {
		return "CC0-1.0"
	}
	var rest string
	switch {
	case strings.HasPrefix(s, "CC-BY-NC-SA-"):
		rest = strings.TrimPrefix(s, "CC-BY-NC-SA-")
	case strings.HasPrefix(s, "CC-BY-NC-"):
		rest = strings.TrimPrefix(s, "CC-BY-NC-")
	case strings.HasPrefix(s, "CC-BY-SA-"):
		rest = strings.TrimPrefix(s, "CC-BY-SA-")
	case strings.HasPrefix(s, "CC-BY-"):
		rest = strings.TrimPrefix(s, "CC-BY-")
	default:
		return ""
	}
	ver, port, _ := strings.Cut(rest, "-")
	switch ver {
	case "1.0", "2.0", "2.5", "3.0", "4.0":
	default:
		return ""
	}
	if port != "" && (len(port) != 2 || !alnum(port, 2, 2)) {
		return ""
	}
	return s
}
