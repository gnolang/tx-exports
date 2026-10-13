package bolo

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Text limits in characters — Unicode code points — after normalization (API
// §2.3). Every text also has a byte cap of four times its character limit, on
// the argument as sent.
const (
	titleMin, titleMax   = 4, 80
	descriptionMax       = 5000
	messageMax           = 140
	updateMin, updateMax = 1, 2000
	noticeMin, noticeMax = 1, 280
	altMin, altMax       = 1, 250
	cidMaxBytes          = 100
)

// normalize prepares user text for checking and storing (API C7, §2.3). Bidi and
// zero-width characters go first, through the very function sanitize.Block calls
// when it renders, so that no check can be dodged by what rendering removes. Line
// breaks are unified — CR-LF, CR, NEL and the Unicode line and paragraph
// separators all become "\n" — and kept in multiline text; elsewhere they become
// a space. Tabs and the other whitespace controls (a vertical tab, a form feed, the
// information separators) become a space everywhere, so words never join. Then
// every character that only pads a text goes (invisible), and surrounding
// whitespace is trimmed. Stripping more than Block does only makes the checks
// stricter, and the stripped text is what gets stored.
func normalize(s string, multiline bool) string {
	s = sanitize.StripBidiAndZeroWidth(s)
	s = sanitize.NormalizeBreaks(s)
	s = strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\u0085' || r == '\u2028' || r == '\u2029':
			if multiline {
				return '\n'
			}
			return ' '
		case r == '\t' || r == '\v' || r == '\f' || (r >= '\x1c' && r <= '\x1f'):
			return ' '
		case invisible(r):
			return -1
		}
		return r
	}, s)
	return strings.TrimSpace(s)
}

// invisible reports whether r shows nothing and only pads a text: a control or a
// format character (Unicode Cc, Cf: a word joiner, a soft hyphen), one Unicode
// lists as Other_Default_Ignorable_Code_Point (a Hangul filler, the combining
// grapheme joiner), or a blank symbol (the Braille blank, the musical null
// notehead). A Latin-1 character skips the tables, which are costly and which
// English or French text seldom leaves: of them, only the controls and the soft
// hyphen are invisible (TestLatin1 holds this to the tables). Every control is
// Latin-1.
func invisible(r rune) bool {
	if r <= unicode.MaxLatin1 {
		return r < 0x20 || r >= 0x7f && r <= 0x9f || r == 0xad
	}
	return unicode.Is(unicode.Cf, r) || unicode.Is(unicode.Other_Default_Ignorable_Code_Point, r) ||
		r == '\u2800' || r == '\U0001D159'
}

// checkText checks one text argument and returns it normalized, the form Bolo
// stores (API §2.3): valid UTF-8 and at most four bytes per allowed character as
// sent; then, normalized, at most max characters, of which at least min show on
// their own. It panics with err otherwise.
func checkText(s string, min, max int, multiline bool, err Error) string {
	if !utf8.ValidString(s) || len(s) > 4*max {
		panic(err)
	}
	s = normalize(s, multiline)
	if utf8.RuneCountInString(s) > max || !visible(s, min) {
		panic(err)
	}
	return s
}

// visible reports whether at least min characters of s show on their own —
// letters, digits, punctuation, symbols and spacing marks — counting the spaces
// between two of them. A mark that takes no space (an accent, a variation
// selector) only changes the character before it, a private-use character or a
// code point Unicode hasn't assigned shows nothing a reader can count on, and a
// space shows only between characters that do. They all stay in the text, but
// don't count toward a minimum. Latin-1 skips the tables, as in invisible: there,
// every character shows on its own but the controls, the soft hyphen and the two
// spaces, ' ' and U+00A0. Counting stops once min characters have shown, so a long
// text pays the tables only until then, and a story, whose minimum is 0, never.
func visible(s string, min int) bool {
	n, spaces, shown := 0, 0, false
	for _, r := range s {
		if n >= min {
			break
		}
		switch {
		case r > ' ' && r < 0x7f, r > 0xa0 && r <= unicode.MaxLatin1 && r != 0xad,
			r > unicode.MaxLatin1 && unicode.In(r, unicode.L, unicode.Mc, unicode.N, unicode.P, unicode.S):
			n += 1 + spaces
			spaces, shown = 0, true
		case shown && (r == ' ' || r == 0xa0 || r > unicode.MaxLatin1 && unicode.Is(unicode.Zs, r)):
			spaces++
		}
	}
	return n >= min
}

// checkStory checks a story or an update, the organizer's own text, and returns it
// normalized (API §2.3): the limits of checkText, then no image and no raw HTML,
// judged on the normalized text that sanitize.Block will render.
func checkStory(s string, min, max int, err Error) string {
	s = checkText(s, min, max, true, err)
	checkMarkup(s)
	return s
}

// checkMarkup refuses an image or raw HTML (API §2.3): `![`, or `<` followed by a
// letter, `/`, `!` or `?` — every way CommonMark opens raw HTML. The campaign
// photo is the only image a campaign shows, and `<3` still passes.
func checkMarkup(s string) {
	if strings.Contains(s, "![") {
		panic(ErrMarkup)
	}
	for i := 0; i+1 < len(s); i++ {
		if s[i] != '<' {
			continue
		}
		c := s[i+1]
		if c == '/' || c == '!' || c == '?' || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') {
			panic(ErrMarkup)
		}
	}
}

// checkImage checks a campaign photo's CID and its description (API §2.3, ADR
// D16), and returns both, the description normalized: no photo, no description;
// a photo, a description of 1 to 250 characters.
func checkImage(cid, alt string) (string, string) {
	if cid == "" {
		if alt != "" {
			panic(ErrImage)
		}
		return "", ""
	}
	if !validCID(cid) {
		panic(ErrImage)
	}
	return cid, checkText(alt, altMin, altMax, false, ErrImage)
}

// validCID reports whether s has the shape of an IPFS CID Bolo accepts: v0, "Qm"
// and 44 more base58btc characters; or v1 in lowercase base32, "b" then that
// alphabet; at most 100 bytes. Render writes the CID into `(ipfs://…)` as it is,
// so the character set is the escaping (API §2.3).
func validCID(s string) bool {
	switch {
	case len(s) > cidMaxBytes:
		return false
	case len(s) == 46 && strings.HasPrefix(s, "Qm"):
		return allIn(s, base58btc)
	case len(s) > 1 && s[0] == 'b':
		return allIn(s[1:], base32Lower)
	}
	return false
}

const (
	base58btc   = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
	base32Lower = "abcdefghijklmnopqrstuvwxyz234567"
)

func allIn(s, set string) bool {
	for i := 0; i < len(s); i++ {
		if strings.IndexByte(set, s[i]) < 0 {
			return false
		}
	}
	return true
}
