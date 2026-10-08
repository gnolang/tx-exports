// Package safe screens short public texts, such as radio dedications, with
// no human review. A text must use plain characters, carry no link or phone
// number, and contain no blocked word or phrase, after folding accents, leet
// digits (0→o, 1→i, 3→e, 4→a, 5→s, 7→t) and repeated letters. Words match
// whole, without a final s, reversed, or glued back when split by - or '
// ("fu-ck"); a run of single letters ("f u c k") reads as one word; a few
// unambiguous stems match inside any word. So "classic" or "grass" pass; the
// realm adds reports and automatic hiding for what a list cannot know.
package safe

import "strings"

type list struct {
	words map[string]bool // false: not blocked, but starts a blocked phrase
	stems []string        // blocked inside any word: roots legitimate words lack
	back  []string        // the stems reversed, for words written backwards ("kcuf")
	first [32]bool        // letters (r&31) that start a stem or a reversed stem
}

// newList reverses the stems once. A reversed "nigg" is too often a real word
// (jogging): the list has "reggin".
func newList(words map[string]bool, stems ...string) list {
	l := list{words: words, stems: stems}
	for _, st := range stems {
		l.first[st[0]&31] = true
		if st != "nigg" {
			b := reverse(st)
			l.back = append(l.back, b)
			l.first[b[0]&31] = true
		}
	}
	return l
}

// maxPhrase is the longest blocked phrase, in words ("go back where you came from").
const maxPhrase = 6

var (
	full = newList(set(words, "\n"), "fuck", "cunt", "nigg", "fagg", "bitch", "whore", "porn", "encul", "pedoph", "paedoph", "pedofil")
	// hate is what Slur refuses even in titles and names.
	hate = newList(set("kike,chink,gook,wetback,raghead,towelhead,tranny,trannies,zipperhead,jungle bunny,porch monkey,untermensch,holohoax,heil hitler,sieg heil,white power,gas the jews,kill the jews,kill all jews", ","), "nigg", "fagg")
	// allow holds real words that a stem, the final s or repeated-letter
	// folding would catch.
	allow = set("rapping,lull,sleet,annal,annals,annales,fodder,cull,scunthorpe,bitche,pornic,pornichet,salopette,salopettes", ",")
)

func set(s, sep string) map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Split(s, sep) {
		if w == "" {
			continue
		}
		m[w] = true
		if i := strings.IndexByte(w, ' '); i > 0 && !m[w[:i]] {
			m[w[:i]] = false
		}
	}
	return m
}

// Note returns why s cannot be shown publicly ("" when it can). max is the
// longest text accepted, in characters.
func Note(s string, max int) string {
	if len(s) > 4*max {
		return "too long"
	}
	if strings.TrimSpace(s) != s || strings.Contains(s, "  ") {
		return "no leading, trailing or double spaces"
	}
	// seq counts digits up to the next letter ("06 12 34 56 78"); dot is 1
	// after a dot, plus the letters since.
	n, digits, seq, dot := 0, 0, 0, 0
	for _, r := range s {
		n++
		switch {
		case r >= '0' && r <= '9':
			digits++
			seq++
			if digits >= 6 || seq >= 9 {
				return "no phone numbers"
			}
			dot = 0
		case letter(r):
			if dot > 0 {
				if dot++; dot > 2 { // x.com, bit.ly, but not P.S.
					return "no links"
				}
			}
			digits, seq = 0, 0
		case strings.ContainsRune(" .,!?'-’¡¿", r):
			digits, dot = 0, 0
			if r == '.' {
				dot = 1
			}
		default:
			return "letters, digits and . , ! ? ¡ ¿ ' - only"
		}
	}
	if n > max {
		return "too long"
	}
	if Blocked(s) {
		return "please rephrase"
	}
	return ""
}

// Blocked reports whether s holds a blocked word, phrase or stem.
func Blocked(s string) bool { return full.in(s) }

// Slur reports whether s holds a racial or homophobic slur or a hate
// slogan: the check for titles, names and bios, where the full list would
// refuse real works (Sex Pistols, Bitches Brew).
func Slur(s string) bool { return hate.in(s) }

// in checks s folded, then, if it holds a word split by - or ' ("fu-ck") or
// 1 ! ß inside a word, folded the other way ("b!tch", "ßitch").
func (l list) in(s string) bool {
	f, odd := fold(s, false)
	if l.blocked(f) {
		return true
	}
	if !odd {
		return false
	}
	f, _ = fold(s, true)
	return l.blocked(f)
}

func (l list) blocked(s string) bool {
	ws := fields(s)
	run := ""
	for i, w := range append(ws, "") {
		if _, starts := l.words[w]; starts {
			for j := i + 2; j <= i+maxPhrase && j <= len(ws); j++ {
				if l.words[strings.Join(ws[i:j], " ")] {
					return true
				}
			}
		}
		if len(w) == 1 {
			run += w
			continue
		}
		if l.word(run) || l.word(w) {
			return true
		}
		run = ""
	}
	return false
}

// word reports whether w or its letters squeezed is listed, or whether w
// holds a stem, also reversed ("kcuf"). A reversed listed word is too often
// a real one (lana, setup).
func (l list) word(w string) bool {
	if w == "" || allow[w] {
		return false
	}
	if l.listed(w) {
		return true
	}
	// One pass finds repeated letters (else w is its own squeeze) and a
	// letter that starts a stem (else no stem can match).
	dup, stem := false, false
	var last rune
	for _, r := range w {
		dup = dup || r == last
		stem = stem || l.first[r&31]
		last = r
	}
	sq := w
	if dup {
		sq = squeeze(w)
		if l.listed(sq) {
			return true
		}
	}
	if len(w) < 4 || !stem {
		return false
	}
	for _, st := range l.stems {
		if has(w, st) || dup && has(sq, st) {
			return true
		}
	}
	for _, st := range l.back {
		if has(w, st) {
			return true
		}
	}
	return false
}

// listed matches w whole or without a final s (never "es": spices, not spic).
func (l list) listed(w string) bool {
	n := len(w)
	return l.words[w] || n > 1 && w[n-1] == 's' && l.words[w[:n-1]]
}

// The helpers below run on every character of every checked text, so they
// stick to what the VM does cheaply: ranging over a string and writing into
// a byte slice (indexing a string or appending costs several times more).

// has is strings.Contains for short words (Contains hashes both strings).
func has(w, st string) bool {
	c, n := rune(st[0]), len(st)
	for i, r := range w {
		if r == c && i+n <= len(w) && w[i:i+n] == st {
			return true
		}
	}
	return false
}

// fields is strings.Fields for folded text (lowercase letters and spaces).
func fields(s string) []string {
	var ws []string
	start := -1
	for i, r := range s {
		if r != ' ' {
			if start < 0 {
				start = i
			}
		} else if start >= 0 {
			ws = append(ws, s[start:i])
			start = -1
		}
	}
	if start >= 0 {
		ws = append(ws, s[start:])
	}
	return ws
}

func reverse(w string) string {
	b := []byte(w)
	for i, j := 0, len(b)-1; i < j; i, j = i+1, j-1 {
		b[i], b[j] = b[j], b[i]
	}
	return string(b)
}

func letter(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= 0xC0 && r <= 0x17F && r != 0xD7 && r != 0xF7)
}

// latin folds U+00C0..U+00FF to ASCII ("-" for × and ÷, which letter rejects),
// latinA U+0100..U+017F ("-" for Ĳ ĳ Œ œ, folded to two letters).
const (
	latin  = "aaaaaaaceeeeiiiidnooooo-ouuuuyts" + "aaaaaaaceeeeiiiidnooooo-ouuuuyty"
	latinA = "aaaaaaccccccccddddeeeeeeeeeegggg" + "gggghhhhiiiiiiiiii--jjkkklllllll" +
		"lllnnnnnnnnnoooooo--rrrrrrssssss" + "ssttttttuuuuuuuuuuuuwwyyyzzzzzzs"
)

// cyrillic letters that look Latin, and what they read as (2 bytes each).
const cyrillic, cyrillicAs = "аеорсухіјѕһԁԛԝӏАВЕНІЈКМОРСТХЅ", "aeopcyxijshdqwlabehijkmopctxs"

// fold lowercases s to ASCII letters and spaces: accents dropped, look-alike
// Cyrillic and leet digits read as letters, anything else a space. alt glues
// words split by - or ' and reads 1 ! ß as l i b (1 and ! before a letter);
// odd reports whether alt reads s differently.
func fold(s string, alt bool) (f string, odd bool) {
	b := make([]byte, len(s)) // folding never lengthens s
	n := 0
	for i, r := range s {
		if r >= 'a' && r <= 'z' || r == ' ' {
			b[n] = byte(r)
			n++
			continue
		}
		if r >= 'A' && r <= 'Z' {
			b[n] = byte(r) + 32
			n++
			continue
		}
		if r == '-' || r == '\'' || r == '’' || r == 'ß' || (r == '1' || r == '!') && i+1 < len(s) && letter(rune(s[i+1])) {
			odd = true
			if alt {
				if j := strings.IndexRune("1!ß", r); j >= 0 {
					b[n] = "lib"[j]
					n++
				}
				continue
			}
		}
		switch {
		case r >= 0xC0 && r <= 0xFF:
			if c := latin[r-0xC0]; c != '-' {
				b[n] = c
				n++
			}
		case r == 'Ĳ' || r == 'ĳ':
			b[n], b[n+1] = 'i', 'j'
			n += 2
		case r == 'Œ' || r == 'œ':
			b[n], b[n+1] = 'o', 'e'
			n += 2
		case r >= 0x100 && r <= 0x17F:
			b[n] = latinA[r-0x100]
			n++
		case r >= '0' && r <= '9':
			b[n] = "oizeasgtbg"[r-'0']
			n++
		case r >= 0x400 && r <= 0x52F && strings.ContainsRune(cyrillic, r):
			b[n] = cyrillicAs[strings.IndexRune(cyrillic, r)/2]
			n++
		default:
			b[n] = ' '
			n++
		}
	}
	return string(b[:n]), odd
}

// squeeze collapses repeated letters ("fuuuck" -> "fuck").
func squeeze(w string) string {
	b := []byte(w)
	n := 0
	var last byte
	for i, c := range b {
		if i == 0 || c != last {
			b[n] = c
			n++
		}
		last = c
	}
	return string(b[:n])
}
