package soup

import "unicode/utf8"

// Secret and Toxic, written without regexp. Each rule below names the pattern it
// replaces, so the behaviour can be compared with the earlier regexp version.
// Regexp'siz yazildi; her kuralin ustunde yerine gectigi desen yazili.

// ───────────────────────── Secret ─────────────────────────

var passwordWords = []string{
	"şifre", "sifre", "parola", "parol", "password", "passwort", "passwd", "pass", "pwd", "passcode",
	"contraseña", "contrasena", "clave", "mot de passe", "mdp", "senha", "wachtwoord", "kennwort",
	"пароль", "кодовое слово", "كلمة المرور", "كلمة السر", "كلمه المرور", "الباسورد",
}

var codeWords = []string{
	"kod", "code", "codes", "código", "codigo", "code de", "код", "otp", "2fa", "pin",
	"cvv", "cvc", "رمز", "الرمز", "كود", "doğrulama", "verification", "verificación",
	"vérification", "bestätigung", "verifica", "verificatie", "подтверждения",
}

// words after "password" that mean it is not a value: "forgot", "reset" ...
var harmless = map[string]bool{
	"unuttum": true, "unutmuşum": true, "unuttu": true, "unutma": true, "unutmayın": true, "değişti": true,
	"değiştirdim": true, "değiştir": true, "değiştirmem": true, "yanlış": true, "hatalı": true, "ne": true,
	"nedir": true, "neydi": true, "neymiş": true, "kimseye": true, "çok": true, "yok": true, "var": true,
	"sıfırla": true, "sıfırlama": true, "sıfırladım": true, "gelmiyor": true, "gelmedi": true, "geldi": true,
	"mi": true, "mı": true, "mu": true, "bile": true, "de": true, "da": true, "ve": true, "ama": true,
	"için": true, "olmuyor": true, "çalışmıyor": true, "kabul": true, "hep": true, "yine": true,
	"sürekli": true, "girdim": true, "giremiyorum": true, "giremedim": true, "tutmuyor": true, "ile": true,
	"lazım": true, "gerek": true, "koydum": true, "koymadım": true, "yazmadım": true, "güçlü": true,
	"zayıf": true, "kolay": true, "zor": true, "hatırlamıyorum": true, "hatırlayamıyorum": true,
	"bulamıyorum": true, "forgot": true, "forget": true, "forgotten": true, "reset": true, "change": true,
	"changed": true, "changing": true, "wrong": true, "weak": true, "strong": true, "new": true, "old": true,
	"lost": true, "recover": true, "recovery": true, "expired": true, "olvidé": true, "olvide": true,
	"olvidado": true, "cambiar": true, "cambié": true, "nueva": true, "oublié": true, "oublie": true,
	"changer": true, "nouveau": true, "vergessen": true, "ändern": true, "neues": true, "esqueci": true,
	"esqueceu": true, "mudar": true, "nova": true, "dimenticato": true, "dimenticata": true,
	"cambiare": true, "vergeten": true, "wijzigen": true, "nieuw": true, "забыл": true, "забыла": true,
	"сменить": true, "новый": true, "نسيت": true, "تغيير": true, "is": true, "es": true, "est": true,
	"ist": true, "the": true, "my": true, "mon": true, "mein": true, "meu": true, "mio": true,
	"mijn": true, "мой": true, "not": true, "no": true, "non": true, "nicht": true, "não": true, "nao": true,
	"niet": true, "не": true,
}

// joining words between "password" and its value (is, est, ist, :, = ...)
var linkers = []string{"is", "es", "est", "ist", "é", "è", "e", "är", "это", "هي", "هو", "şu", "bu", "da", "de", "ise", "was", "era", "war", ":", "=", "-"}

// Turkish possessive endings after the password word (şifrem, parolan).
var pwSuffixes = []string{"m", "im", "miz", "n", "in", "niz", ""}

var shortSuffixes = []string{"", "u", "um", "un", "i", "im", "in", "ı", "ım", "ın", "ü", "üm", "ün"}

func isLatinWord(w string) bool {
	for _, r := range w {
		if r >= 'a' && r <= 'z' || r == 'ç' || r == 'ğ' || r == 'ı' || r == 'ö' || r == 'ş' || r == 'ü' ||
			r == 'ñ' || r == 'é' || r == 'è' || r == 'ä' || r == 'ß' || r == 'ã' || r == 'õ' || r == 'á' {
			return true
		}
	}
	return false
}

// hasWord: a list word at a word start; short words (<=4 runes) must also end there,
// optionally with a Turkish suffix. Non-Latin words: plain substring.
// Only word starts are tried, so the text is walked once.
func hasWord(text string, list []string) bool {
	nonLatin := false
	prevWord := false
	for i := 0; i < len(text); {
		b := text[i]
		if b >= 0xD0 && b <= 0xDB {
			nonLatin = true
		}
		if !prevWord {
			for _, w := range list {
				if w[0] == b && hasPrefix(text[i:], w) && isLatinWord(w) && wordEnds(text[i+len(w):], w) {
					return true
				}
			}
		}
		if b < 128 {
			prevWord = isASCIIWord(b)
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(text[i:])
		prevWord = isWord(r)
		i += size
	}
	if nonLatin {
		for _, w := range list {
			if !isLatinWord(w) && contains(text, w) {
				return true
			}
		}
	}
	return false
}

func wordEnds(rest, w string) bool {
	if len([]rune(w)) > 4 {
		return true
	}
	for _, suf := range shortSuffixes {
		if !hasPrefix(rest, suf) {
			continue
		}
		after := rest[len(suf):]
		if after == "" {
			return true
		}
		r, _ := utf8.DecodeRuneInString(after)
		if !isLetter(r) {
			return true
		}
	}
	return false
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// leet: inside a token that has both a letter and an ASCII digit, digits become
// letters (p4ssw0rd -> password). Token = run of letters, digits, _, @, $.
func leet(s string) string {
	need := false
	for i := 0; i < len(s); i++ {
		if isDigit(s[i]) || s[i] == '@' || s[i] == '$' {
			need = true
			break
		}
	}
	if !need {
		return s
	}
	out := make([]rune, 0, len(s))
	var tok []rune
	flush := func() {
		hasD, hasL := false, false
		for _, r := range tok {
			if r >= '0' && r <= '9' {
				hasD = true
			} else if isLetter(r) {
				hasL = true
			}
		}
		for _, r := range tok {
			if hasD && hasL {
				switch r {
				case '0':
					r = 'o'
				case '1':
					r = 'i'
				case '3':
					r = 'e'
				case '4', '@':
					r = 'a'
				case '5', '$':
					r = 's'
				case '7':
					r = 't'
				}
			}
			out = append(out, r)
		}
		tok = tok[:0]
	}
	for _, r := range s {
		if isWord(r) || r == '@' || r == '$' {
			tok = append(tok, r)
			continue
		}
		flush()
		out = append(out, r)
	}
	flush()
	return string(out)
}

func skipSpaces(s string, i int) int {
	for i < len(s) && isSpace(rune(s[i])) {
		i++
	}
	return i
}

// isValueStop: chars that end a password value ([\s,.!?;]).
func isValueStop(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\v' || b == '\f' ||
		b == ',' || b == '.' || b == '!' || b == '?' || b == ';'
}

func valueAt(s string, i int) (string, bool) {
	j := i
	for j < len(s) && !isValueStop(s[j]) {
		j++
	}
	return s[i:j], j > i
}

// pwMatch mirrors: w (m|im|miz|n|in|niz)? (\s*[:=]\s* | \s+LINKER\s+ | \s+) ([^\s,.!?;]+)
// in the same priority order. Returns suffix, linker text, value, end.
func pwMatch(s string, at int, w string) (string, string, string, int, bool) {
	base := at + len(w)
	for _, suf := range pwSuffixes {
		if !hasPrefix(s[base:], suf) {
			continue
		}
		p := base + len(suf)
		// \s*[:=]\s*
		q := skipSpaces(s, p)
		if q < len(s) && (s[q] == ':' || s[q] == '=') {
			r := skipSpaces(s, q+1)
			if v, ok := valueAt(s, r); ok {
				return suf, s[p:r], v, r + len(v), true
			}
		}
		// \s+LINKER\s+
		if q > p {
			for _, l := range linkers {
				if !hasPrefix(s[q:], l) {
					continue
				}
				r := skipSpaces(s, q+len(l))
				if r == q+len(l) {
					continue
				}
				if v, ok := valueAt(s, r); ok {
					return suf, s[p:r], v, r + len(v), true
				}
			}
			// \s+
			if v, ok := valueAt(s, q); ok {
				return suf, s[p:q], v, q + len(v), true
			}
		}
	}
	return "", "", "", 0, false
}

func trimSpace(s string) string {
	i, j := 0, len(s)
	for i < j && isSpace(rune(s[i])) {
		i++
	}
	for j > i && isSpace(rune(s[j-1])) {
		j--
	}
	return s[i:j]
}

func hasASCIIDigit(s string) bool {
	for i := 0; i < len(s); i++ {
		if isDigit(s[i]) {
			return true
		}
	}
	return false
}

func hasLetter(s string) bool {
	for _, r := range s {
		if isLetter(r) {
			return true
		}
	}
	return false
}

var pwAndCode = append(append([]string{}, passwordWords...), codeWords...)

func passwordValue(k, kl string) bool {
	if !hasWord(kl, passwordWords) {
		return false
	}
	// 1) a mixed letters+digits token of 5+ runes (kartal1907)
	for i := 0; i < len(k); {
		for i < len(k) && isValueStop(k[i]) {
			i++
		}
		tok, ok := valueAt(k, i)
		if !ok {
			break
		}
		i += len(tok)
		if len([]rune(tok)) >= 5 && hasASCIIDigit(tok) && hasLetter(tok) && !hasWord(leet(tok), pwAndCode) {
			return true
		}
	}
	// 2) "şifrem X", "my password is X", "pass: X"; "şifreyi unuttum" passes
	for _, w := range passwordWords {
		for i := index(kl, w, 0); i >= 0; {
			suf, link, x, end, ok := pwMatch(kl, i, w)
			if !ok {
				i = index(kl, w, i+1)
				continue
			}
			if !(suf == "" && trimSpace(link) == "") && !harmless[x] && !hasWord(x, passwordWords) {
				return true
			}
			i = index(kl, w, end)
		}
	}
	return false
}

// Seed phrase rules (cuzdan kelimeleri), on Turkish-lowercased text: one pass,
// each byte only tries the rules that can start with it.
func seedPhrase(k string) bool {
	for i := 0; i < len(k); i++ {
		if seedAt(k, i) {
			return true
		}
	}
	return false
}

func seedAt(k string, i int) bool {
	rest := k[i:]
	after := func(w string, next ...string) bool {
		if !hasPrefix(rest, w) {
			return false
		}
		p := skipSpaces(k, i+len(w))
		for _, n := range next {
			if hasPrefix(k[p:], n) {
				return true
			}
		}
		return false
	}
	switch k[i] {
	case '1', '2', 'o', 'y':
		return seedCountAt(k, i)
	case 's':
		return wholeASCIIAt(k, i, "seed") || after("secret", "key", "phrase") // \bseed\b, secret\s*(key|phrase)
	case 'm':
		return wholeASCIIAt(k, i, "mnemonic") // \bmnemonic\b
	case 'p':
		return after("private", "key") // private\s*key
	case 'k':
		return after("kurtarma", "kelime", "ifade", "cümle", "sözcük")
	case 'g':
		return after("gizli", "anahtar", "kelime") // (gizli|özel)\s*anahtar, gizli\s*kelime
	case 0xC3: // ö
		return after("özel", "anahtar")
	case 'c':
		return hasPrefix(rest, "cüzdan") && walletWordsAt(k, i)
	case 'a':
		return hasPrefix(rest, "anımsatıcı")
	}
	return false
}

// \b(12|24|18|on iki|oniki|yirmi dört|yirmidört)\s*(tane\s*)?(kelime|sözcük)
func seedCountAt(k string, i int) bool {
	if i > 0 && isASCIIWord(k[i-1]) {
		return false
	}
	for _, n := range []string{"12", "24", "18", "on iki", "oniki", "yirmi dört", "yirmidört"} {
		if !hasPrefix(k[i:], n) {
			continue
		}
		p := skipSpaces(k, i+len(n))
		if hasPrefix(k[p:], "tane") {
			q := skipSpaces(k, p+4)
			if hasPrefix(k[q:], "kelime") || hasPrefix(k[q:], "sözcük") {
				return true
			}
		}
		if hasPrefix(k[p:], "kelime") || hasPrefix(k[p:], "sözcük") {
			return true
		}
	}
	return false
}

// \bword\b with ASCII boundaries, at byte i
func wholeASCIIAt(k string, i int, w string) bool {
	e := i + len(w)
	return hasPrefix(k[i:], w) && (i == 0 || !isASCIIWord(k[i-1])) && (e == len(k) || !isASCIIWord(k[e]))
}

// cüzdan\pL*\s*(kelime|sözcük), at byte i
func walletWordsAt(k string, i int) bool {
	p := i + len("cüzdan")
	j := p
	for j < len(k) {
		r, size := utf8.DecodeRuneInString(k[j:])
		if !isLetter(r) {
			break
		}
		j += size
	}
	run := k[p:j]
	if contains(run, "kelime") || contains(run, "sözcük") {
		return true
	}
	q := skipSpaces(k, j)
	return hasPrefix(k[q:], "kelime") || hasPrefix(k[q:], "sözcük")
}

func isHexLower(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func isBase58(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '1' && c <= '9' || c >= 'A' && c <= 'H' || c >= 'J' && c <= 'N' || c >= 'P' && c <= 'Z' ||
			c >= 'a' && c <= 'k' || c >= 'm' && c <= 'z') {
			return false
		}
	}
	return true
}

// \b(0x)?[0-9a-f]{64}\b  on lowered text;  \b[base58]{50,}\b  on the original
func privateKey(k, text string) bool {
	return eachASCIIRun(k, 64, func(t string) bool {
		return hasPrefix(t, "0x") && len(t) == 66 && isHexLower(t[2:]) || len(t) == 64 && isHexLower(t)
	}) || eachASCIIRun(text, 50, isBase58)
}

// eachASCIIRun calls f for every [A-Za-z0-9_] run of at least minLen bytes.
func eachASCIIRun(s string, minLen int, f func(string) bool) bool {
	start := -1
	for i := 0; i <= len(s); i++ {
		if i < len(s) && isASCIIWord(s[i]) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 && i-start >= minLen && f(s[start:i]) {
			return true
		}
		start = -1
	}
	return false
}

// Twelve or more one-word items, split by , ; newline or "1." "2)" "3-" markers.
// Mirrors: split on [,;\n]|\b\d{1,2}\s*[.)-], item matches ^[a-zçğıöşü]{2,12}$
func wordList(k string) bool {
	n := 0
	start := 0
	item := func(end int) {
		s := trimSpace(k[start:end])
		c := 0
		for _, r := range s {
			if !(r >= 'a' && r <= 'z' || r == 'ç' || r == 'ğ' || r == 'ı' || r == 'ö' || r == 'ş' || r == 'ü') {
				return
			}
			c++
		}
		if c >= 2 && c <= 12 {
			n++
		}
	}
	for i := 0; i < len(k); {
		c := k[i]
		if c == ',' || c == ';' || c == '\n' {
			item(i)
			i++
			start = i
			continue
		}
		if isDigit(c) && (i == 0 || !isASCIIWord(k[i-1])) {
			j := i
			for j < len(k) && isDigit(k[j]) {
				j++
			}
			if j-i <= 2 {
				q := skipSpaces(k, j)
				if q < len(k) && (k[q] == '.' || k[q] == ')' || k[q] == '-') {
					item(i)
					i = q + 1
					start = i
					continue
				}
			}
			i = j
			continue
		}
		i++
	}
	item(len(k))
	return n >= 12
}

// A run of 3-8 ASCII digits (\d+ then length check).
func codeDigits(k string) bool {
	for i := 0; i < len(k); {
		if !isDigit(k[i]) {
			i++
			continue
		}
		j := i
		for j < len(k) && isDigit(k[j]) {
			j++
		}
		if j-i >= 3 && j-i <= 8 {
			return true
		}
		i = j
	}
	return false
}

// Secret returns the kind of secret found, or "".
func Secret(text string) string {
	text = clip(text)
	k := lowerTR(text)
	if seedPhrase(k) {
		return SeedPhrase
	}
	if privateKey(k, text) {
		return PrivateKey
	}
	if wordList(k) {
		return SeedPhrase
	}
	kl := leet(k)
	// also plain ASCII lowercase, so "PIN" is not read as Turkish "pın"
	al := asciiLower(text)
	ascii := leet(al)
	if (hasWord(kl, codeWords) || hasWord(ascii, codeWords)) && codeDigits(k) {
		return Code
	}
	if passwordValue(k, kl) || passwordValue(al, ascii) {
		return Password
	}
	return contactKind(text)
}

// ───────────────────────── Toxic ─────────────────────────

// [section] lines name the reason; "=word" matches the whole word only,
// "word" matches a word start, "two words" matches the phrase.
var toxicList = []string{
	"[profanity]",
	"orospu", "siktir", "sikerim", "sikeyim", "siker", "sikik", "=sikim", "amına", "amina", "=amk", "=aq",
	"=amq", "=aqq", "ananı", "ananin", "bacını", "yarrak", "yarak", "=göt", "götün", "götveren", "ibne",
	"pezevenk", "kahpe", "gavat", "puşt", "yavşak", "dalyarak", "sürtük", "kaltak", "=oç", "=oc", "piç",
	"fahişe", "şerefsiz", "haysiyetsiz", "namussuz",
	"[insult]",
	"gerizekalı", "geri zekalı", "salak", "aptal", "beyinsiz", "ahmak", "dangalak", "embesil", "mal herif",
	"it oğlu", "köpek herif", "hayvan herif", "=öküz",
	"[threat]",
	"öldürürüm", "öldüreceğim", "öldürücem", "gebertirim", "geberteceğim", "gebertcem", "=geber", "geberin",
	"kafanı keserim", "kafanı kırarım", "seni bulurum", "evini yakarım", "canını yakarım", "canını alırım",
	"vururum seni", "seni vururum", "bıçaklarım", "kanını dökerim", "ölmeni istiyorum", "seni mahvederim",
}

func toxicLeet(r rune) rune {
	switch r {
	case '0':
		return 'o'
	case '1':
		return 'i'
	case '3':
		return 'e'
	case '4', '@':
		return 'a'
	case '$', '5':
		return 's'
	case '7':
		return 't'
	}
	return r
}

func isSep(r rune) bool { return r == '.' || r == '-' || r == '_' || r == '*' || r == ' ' }

// toxicTokens: lowercase, leet, join spelled-out letters (s.a.l.a.k -> salak),
// non-word chars to spaces, split. Kucult, harfleri birlestir, kelimelere bol.
func toxicTokens(s string) []string {
	rs := make([]rune, 0, len(s))
	for _, r := range s {
		rs = append(rs, toxicLeet(lowerRune(r)))
	}
	// (?<=\b\w)[.\-_* ](?=\w\b), repeated until nothing changes
	for round := 0; round < 20; round++ {
		out := rs[:0:0]
		changed := false
		for i, r := range rs {
			if isSep(r) && i >= 1 && i+1 < len(rs) && isWord(rs[i-1]) && (i < 2 || !isWord(rs[i-2])) &&
				isWord(rs[i+1]) && (i+2 >= len(rs) || !isWord(rs[i+2])) {
				changed = true
				continue
			}
			out = append(out, r)
		}
		rs = out
		if !changed {
			break
		}
	}
	var toks []string
	var cur []rune
	for _, r := range rs {
		if isWord(r) {
			cur = append(cur, r)
			continue
		}
		if len(cur) > 0 {
			toks = append(toks, string(cur))
			cur = cur[:0]
		}
	}
	if len(cur) > 0 {
		toks = append(toks, string(cur))
	}
	return toks
}

func hasTRLetter(s string) bool {
	for _, r := range s {
		if r == 'ç' || r == 'ğ' || r == 'ı' || r == 'ö' || r == 'ş' || r == 'ü' {
			return true
		}
	}
	return false
}

func splitSpace(s string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ' ' {
			if i > start {
				out = append(out, s[start:i])
			}
			start = i + 1
		}
	}
	return out
}

func seqAt(toks []string, i int, words []string) bool {
	if i+len(words) > len(toks) {
		return false
	}
	for j, w := range words {
		if toks[i+j] != w {
			return false
		}
	}
	return true
}

func hasSeq(toks []string, words []string) bool {
	for i := range toks {
		if seqAt(toks, i, words) {
			return true
		}
	}
	return false
}

// Toxic returns Profanity, Insult, Threat or "". Words written with Turkish letters
// are matched as written; words without them are matched folded ("serefsiz").
func Toxic(text string) string {
	text = clip(text)
	plain := toxicTokens(text)
	n := len(plain)
	if n == 0 {
		return ""
	}
	folded := make([]string, n)
	plainSq := make([]string, n)
	foldedSq := make([]string, n)
	trTok := make([]bool, n)
	// first bytes seen: a list word is only tried if some token can start with it
	var firstTR, firstFold, firstAny [256]bool
	for i, t := range plain {
		folded[i] = fold(t)
		plainSq[i] = squeeze(t)
		foldedSq[i] = squeeze(folded[i])
		trTok[i] = hasTRLetter(t)
		if trTok[i] {
			firstTR[t[0]] = true
		} else {
			firstFold[folded[i][0]] = true
		}
		firstAny[t[0]] = true
		firstAny[folded[i][0]] = true
	}
	reason := Profanity
	for _, e := range toxicList {
		if e[0] == '[' {
			reason = e[1 : len(e)-1]
			continue
		}
		whole := e[0] == '='
		if whole {
			e = e[1:]
		}
		ff := byte(foldRune(firstRune(e)))
		if contains(e, " ") {
			if !firstAny[e[0]] && !firstAny[ff] {
				continue
			}
			pw := splitSpace(e)
			pf := splitSpace(fold(e))
			for _, toks := range [][]string{plain, plainSq, folded, foldedSq} {
				if hasSeq(toks, pw) || hasSeq(toks, pf) {
					return reason
				}
			}
			continue
		}
		useTR, useFold := firstTR[e[0]], firstFold[ff]
		if !useTR && !useFold {
			continue
		}
		w, wsq := e, squeeze(e)
		f := fold(e)
		fsq := squeeze(f)
		for i := 0; i < n; i++ {
			var a1, a2, t1, t2 string
			if trTok[i] {
				if !useTR || plain[i][0] != e[0] {
					continue
				}
				a1, a2, t1, t2 = plain[i], plainSq[i], w, wsq
			} else {
				if !useFold || folded[i][0] != f[0] {
					continue
				}
				a1, a2, t1, t2 = folded[i], foldedSq[i], f, fsq
			}
			if whole {
				if a1 == t1 || a1 == t2 || a2 == t1 || a2 == t2 {
					return reason
				}
			} else if hasPrefix(a1, t1) || hasPrefix(a1, t2) || hasPrefix(a2, t1) || hasPrefix(a2, t2) {
				return reason
			}
		}
	}
	return ""
}

func firstRune(s string) rune {
	r, _ := utf8.DecodeRuneInString(s)
	return r
}
