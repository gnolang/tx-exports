package soup

// contactKind finds contact details that count as secrets, without regexp:
// e-mail, wallet address, IBAN, a number with 7+ digits (phone, ID, card).
// Same order as Clean: links and @handles are masked first and are not secrets.
// Iletisim bilgisi: e-posta, cuzdan adresi, IBAN, 7+ rakamli numara.
func contactKind(text string) string {
	// cheap gate: no '@', no "0x" and fewer than 7 digits -> nothing to find
	at, hex0, digits := false, false, 0
	for i := 0; i < len(text); i++ {
		switch c := text[i]; {
		case c == '@':
			at = true
		case c >= '0' && c <= '9':
			digits++
			if c == '0' && i+1 < len(text) && text[i+1] == 'x' {
				hex0 = true
			}
		}
	}
	if !at && !hex0 && digits < 7 {
		return ""
	}
	s := collapseSpaces(text)
	if at && hasEmail(s) {
		return Email
	}
	if !hex0 && digits < 7 {
		return ""
	}
	m := maskLinks(s)
	if hasWalletAddr(m) {
		return WalletAddress
	}
	if hasIBAN(m) {
		return IBAN
	}
	if hasLongNumber(m) {
		return Number
	}
	return ""
}

func collapseSpaces(s string) string {
	out := make([]byte, 0, len(s))
	space := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' {
			space = len(out) > 0
			continue
		}
		if space {
			out = append(out, ' ')
			space = false
		}
		out = append(out, c)
	}
	return string(out)
}

func isEmailLocal(c byte) bool { return isASCIIWord(c) || c == '.' || c == '+' || c == '-' }
func isHostChar(c byte) bool   { return isASCIIWord(c) || c == '-' }

// [\w.+-]+@[\w-]+(\.[\w-]+)+
func hasEmail(s string) bool {
	for i := 1; i < len(s); i++ {
		if s[i] != '@' || !isEmailLocal(s[i-1]) {
			continue
		}
		j := i + 1
		for j < len(s) && isHostChar(s[j]) {
			j++
		}
		if j > i+1 && j+1 < len(s) && s[j] == '.' && isHostChar(s[j+1]) {
			return true
		}
	}
	return false
}

func lowerByte(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

func hasPrefixFold(s, p string) bool {
	if len(s) < len(p) {
		return false
	}
	for i := 0; i < len(p); i++ {
		if lowerByte(s[i]) != p[i] {
			return false
		}
	}
	return true
}

var tlds = []string{"com", "net", "org", "tv", "io", "me", "app", "xyz", "info", "gov", "edu"}

// maskLinks replaces links (http://, www.), bare domains (name.com) and @handles
// with "x", so digits inside them are not read as a phone number.
func maskLinks(s string) string {
	b := []byte(s)
	mask := func(i, j int) {
		for k := i; k < j; k++ {
			b[k] = 'x'
		}
	}
	untilSpace := func(i int) int {
		for i < len(b) && b[i] != ' ' {
			i++
		}
		return i
	}
	for i := 0; i < len(b); i++ {
		if hasPrefixFold(s[i:], "http://") || hasPrefixFold(s[i:], "https://") || hasPrefixFold(s[i:], "www.") {
			j := untilSpace(i)
			mask(i, j)
			i = j
			continue
		}
		if s[i] == '.' && i > 0 && isHostChar(s[i-1]) {
			for _, t := range tlds {
				e := i + 1 + len(t)
				if !hasPrefixFold(s[i+1:], t) || e < len(s) && isASCIIWord(s[e]) {
					continue
				}
				st := i
				for st > 0 && isHostChar(s[st-1]) {
					st--
				}
				if hasPrefixFold(s[e:], ".tr") && (e+3 == len(s) || !isASCIIWord(s[e+3])) {
					e += 3
				}
				if e < len(s) && s[e] == '/' {
					e = untilSpace(e)
				}
				mask(st, e)
				i = e - 1
				break
			}
			continue
		}
		if s[i] == '@' && (i == 0 || !isWord(lastRune(s, i))) {
			j := i + 1
			for j < len(s) {
				r := []rune(s[j:min(len(s), j+4)])
				if len(r) == 0 || !(isWord(r[0]) || r[0] == '.') {
					break
				}
				j += len(string(r[0]))
			}
			if len([]rune(s[i+1:j])) >= 2 {
				mask(i, j)
				i = j - 1
			}
		}
	}
	return string(b)
}

func isHexAny(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

// \b0x[0-9a-fA-F]{40}\b
func hasWalletAddr(s string) bool {
	for _, t := range asciiTokens(s) {
		if len(t) == 42 && t[0] == '0' && t[1] == 'x' && isHexAny(t[2:]) {
			return true
		}
	}
	return false
}

// (?i)\bTR\s?\d{2}(?:\s?\d){20,24}\b
func hasIBAN(s string) bool {
	for i := 0; i+2 <= len(s); i++ {
		if !hasPrefixFold(s[i:], "tr") || i > 0 && isASCIIWord(s[i-1]) {
			continue
		}
		p := i + 2
		if p < len(s) && s[p] == ' ' {
			p++
		}
		if p+2 > len(s) || !isDigit(s[p]) || !isDigit(s[p+1]) {
			continue
		}
		p += 2
		var ends []int
		for len(ends) < 24 {
			q := p
			if q < len(s) && s[q] == ' ' {
				q++
			}
			if q >= len(s) || !isDigit(s[q]) {
				break
			}
			p = q + 1
			ends = append(ends, p)
		}
		for n := len(ends); n >= 20; n-- {
			e := ends[n-1]
			if e == len(s) || !isASCIIWord(s[e]) {
				return true
			}
		}
	}
	return false
}

// \+?\(?\d[\d\s().-]{5,}\d with 7 or more digits
func hasLongNumber(s string) bool {
	for i := 0; i < len(s); {
		if !isDigit(s[i]) {
			i++
			continue
		}
		j, digits, lastD := i, 0, i
		for j < len(s) {
			c := s[j]
			if isDigit(c) {
				digits++
				lastD = j
			} else if !(c == ' ' || c == '(' || c == ')' || c == '.' || c == '-') {
				break
			}
			j++
		}
		if digits >= 7 && lastD-i+1 >= 7 {
			return true
		}
		i = j
	}
	return false
}
