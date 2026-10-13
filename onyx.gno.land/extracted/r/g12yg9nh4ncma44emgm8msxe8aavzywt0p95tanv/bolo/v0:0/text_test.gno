package bolo

import (
	"strings"
	"testing"
	"unicode"
)

func TestNormalize(t *testing.T) {
	for _, c := range []struct {
		in        string
		multiline bool
		want      string
	}{
		{"  Clean water  ", false, "Clean water"},
		{"a\u200bb\u202ec\ufeffd\u2066e", false, "abcde"},
		{"one\r\ntwo\rthree", true, "one\ntwo\nthree"},
		// Every line break is one; outside multiline text, it and a tab become a
		// space, so words never join.
		{"one\r\ntwo\nthree", false, "one two three"},
		{"bell\a and\ttab", false, "bell and tab"},
		{"rub\x7fout", false, "rubout"},
		{"a\vb\fc\x1cd\x1fe", false, "a b c d e"},
		{"a\tb\vc", true, "a b c"},
		{"a\u0085b\u2028c\u2029d", true, "a\nb\nc\nd"},
		{"a\u0085b\u2028c\u2029d", false, "a b c d"},
		{"word\u2060joiner, soft\u00adhyphen", false, "wordjoiner, softhyphen"},
		// Fillers that show nothing go: Hangul fillers, the combining grapheme
		// joiner, the Braille blank. A variation selector stays, for emoji.
		{"a\u3164b\uffa0c\u115fd\u034fe\u2800f\U0001D159g", false, "abcdefg"},
		{"I \u2764\ufe0f you", false, "I \u2764\ufe0f you"},
		{"\n\n story \n\n", true, "story"},
	} {
		if got := normalize(c.in, c.multiline); got != c.want {
			t.Errorf("normalize(%q, %t) = %q, want %q", c.in, c.multiline, got, c.want)
		}
	}
}

// TestLatin1 holds the Latin-1 shortcut of invisible and visible to the Unicode
// tables they read beyond it: invisible is Cc, Cf or Other_Default_Ignorable; a
// character shows on its own (counts alone) if it is L, Mc, N, P or S; a space (Zs)
// counts only between two of those.
func TestLatin1(t *testing.T) {
	for r := rune(0); r <= unicode.MaxLatin1; r++ {
		if want := unicode.In(r, unicode.Cc, unicode.Cf, unicode.Other_Default_Ignorable_Code_Point); invisible(r) != want {
			t.Errorf("invisible(%U) = %t, the tables say %t", r, !want, want)
		}
		shows := unicode.In(r, unicode.L, unicode.Mc, unicode.N, unicode.P, unicode.S)
		if got := visible(string(r), 1); got != shows {
			t.Errorf("visible(%U, 1) = %t, the tables say %t", r, got, shows)
		}
		between := shows || unicode.Is(unicode.Zs, r)
		if got := visible("x"+string(r)+"x", 3); got != between {
			t.Errorf("visible(x %U x, 3) = %t, the tables say %t", r, got, between)
		}
	}
}

// TestVisible checks visible's threshold: at least min, the spaces between two
// shown characters counted, marks and spaces elsewhere not.
func TestVisible(t *testing.T) {
	for _, c := range []struct {
		s    string
		min  int
		want bool
	}{
		{"", 0, true},
		{"", 1, false},
		{"abc", 4, false},
		{"abcd", 4, true},
		{"ab cd", 5, true},
		{"ab  ", 3, false},
		{"a\u0301\u0301\u0301", 2, false},
	} {
		if got := visible(c.s, c.min); got != c.want {
			t.Errorf("visible(%q, %d) = %t, want %t", c.s, c.min, got, c.want)
		}
	}
}

func TestCheckText(t *testing.T) {
	if got := checkText("  Clean water for Ndiaganiao ", titleMin, titleMax, false, ErrTitle); got != "Clean water for Ndiaganiao" {
		t.Errorf("checkText = %q", got)
	}
	// 80 characters of four bytes each: exactly the byte cap.
	if got := checkText(strings.Repeat("💧", 80), titleMin, titleMax, false, ErrTitle); len(got) != 320 {
		t.Errorf("80 four-byte characters: got %d bytes", len(got))
	}
	// Four letters, one with a combining accent: four characters show. So do
	// emoji with a skin tone, flags, CJK, Arabic, a Devanagari word with a spacing
	// vowel sign, and two letters with the spaces between them.
	for _, s := range []string{"Cafe\u0301", "\U0001F44D\U0001F3FD\U0001F44D\U0001F3FD", "\U0001F1F8\U0001F1F3\U0001F1F8\U0001F1F3", "水井项目", "بئر ماء", "कमला", "a  b"} {
		if got := checkText(s, titleMin, titleMax, false, ErrTitle); got != s {
			t.Errorf("checkText(%q) = %q", s, got)
		}
	}
	for name, s := range map[string]string{
		"too short":                 "abc",
		"four spaces":               "    ",
		"four invisible characters": "\u200b\u200b\u200b\u200b",
		"four word joiners":         "\u2060\u2060\u2060\u2060",
		"four soft hyphens":         "\u00ad\u00ad\u00ad\u00ad",
		"four Hangul fillers":       "\u3164\u3164\u3164\u3164",
		"four halfwidth fillers":    "\uffa0\uffa0\uffa0\uffa0",
		"four grapheme joiners":     "\u034f\u034f\u034f\u034f",
		"four Braille blanks":       "\u2800\u2800\u2800\u2800",
		"four variation selectors":  "\ufe0f\ufe0f\ufe0f\ufe0f",
		"one letter, three accents": "a\u0301\u0301\u0301",
		"four null noteheads":       "\U0001D159\U0001D159\U0001D159\U0001D159",
		"four private-use":          "\ue000\ue000\ue000\ue000",
		"four noncharacters":        "\uffff\uffff\uffff\uffff",
		// Spaces count only between shown characters: wrapped in characters
		// that don't count, they would escape the trim and pass as a title.
		"spaces in variation selectors":  "\ufe0f    \ufe0f",
		"spaces in accents":              "\u0301    \u0301",
		"spaces in private-use":          "\ue000    \ue000",
		"spaces in noncharacters":        "\uffff    \uffff",
		"no-break spaces in selectors":   "\U000E0100\u00a0\u00a0\u00a0\u00a0\U000E0100",
		"ideographic spaces":             "\ufe0f\u3000\u3000\u3000\u3000\ufe0f",
		"one letter and trailing spaces": "a\ufe0f   \ufe0f",
		"leading spaces and one letter":  "\ufe0f    a",
		"too long":                       strings.Repeat("a", 81),
		"invalid UTF-8":                  "\xff\xfeabcd",
		// Fits once normalized, but is more than four bytes per allowed character
		// as sent: the byte cap applies to the argument (API §2.3).
		"padded past the byte cap": "abcd" + strings.Repeat("\u200b", 110),
	} {
		if !panicsWith(func() { checkText(s, titleMin, titleMax, false, ErrTitle) }, ErrTitle) {
			t.Errorf("%s: not refused", name)
		}
	}
}

func TestCheckStory(t *testing.T) {
	// Accepted, and stored normalized; a refusal of any kind fails the test.
	for _, c := range []struct{ in, want string }{
		{"We need **1,500 GNOT** for the pump.\n\nSee [the quote](https://example.org/q).", "We need **1,500 GNOT** for the pump.\n\nSee [the quote](https://example.org/q)."},
		{"Thanks <3 to everyone", "Thanks <3 to everyone"},
		{"a < b, and x<5", "a < b, and x<5"},
		{"", ""},
		{" Line one\r\n\r\nline\u2028two\t ", "Line one\n\nline\ntwo"},
	} {
		if got := checkStory(c.in, 0, descriptionMax, ErrDescription); got != c.want {
			t.Errorf("checkStory(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	for name, s := range map[string]string{
		"an image":                    "![the pump](https://imgur.com/p.png)",
		"an image behind zero-width":  "!\u200b[the pump](https://imgur.com/p.png)",
		"an image behind a bidi mark": "!\u202e[the pump](https://imgur.com/p.png)",
		"a tag":                       "<script>alert(1)</script>",
		"an upper-case tag":           "<IMG SRC=x>",
		"a closing tag":               "fine </p>",
		"a comment":                   "visible <!-- hidden from the page -->",
		"a declaration":               "<!DOCTYPE html>",
		"a processing instruction":    "<?php echo 1 ?>",
	} {
		if !panicsWith(func() { checkStory(s, 0, descriptionMax, ErrDescription) }, ErrMarkup) {
			t.Errorf("%s: not refused", name)
		}
	}
	if !panicsWith(func() { checkStory(strings.Repeat("a", descriptionMax+1), 0, descriptionMax, ErrDescription) }, ErrDescription) {
		t.Errorf("a story one character too long: not refused")
	}
}

func TestCheckImage(t *testing.T) {
	const v0 = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"
	const v1 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
	if cid, alt := checkImage("", ""); cid != "" || alt != "" {
		t.Errorf("no photo: got %q, %q", cid, alt)
	}
	for _, cid := range []string{v0, v1} {
		if _, alt := checkImage(cid, "  The village well, dry since March "); alt != "The village well, dry since March" {
			t.Errorf("%s: alt = %q", cid, alt)
		}
	}
	for name, c := range map[string][2]string{
		"alt text without a photo": {"", "a well"},
		"a photo without alt text": {v0, ""},
		"blank alt text":           {v0, "   "},
		"alt text of a space":      {v0, "\ufe0f \ufe0f"},
		"alt text too long":        {v0, strings.Repeat("a", altMax+1)},
		"v0 with a 0":              {"Qm0wAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", "a well"},
		"v0 too short":             {v0[:45], "a well"},
		"v1 in upper case":         {strings.ToUpper(v1), "a well"},
		"v1 breaking out":          {"bafy](javascript:alert(1))", "a well"},
		"v1 too long":              {"b" + strings.Repeat("a", cidMaxBytes), "a well"},
		"not a CID":                {"https://imgur.com/p.png", "a well"},
	} {
		if !panicsWith(func() { checkImage(c[0], c[1]) }, ErrImage) {
			t.Errorf("%s: not refused", name)
		}
	}
}
