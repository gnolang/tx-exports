package soup

// Clean replaces personal details with neutral Turkish words, keeping the tone.
// Tuned for Turkish text. Kisisel ayrintilari genel kelimeyle degistirir.

import (
	"regexp"
	"strings"
	"unicode"
)

func set(text string) map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(text) {
		m[w] = true
	}
	return m
}

const letters = "A-Za-zÇĞİÖŞÜçğıöşüÂâÎîÛû"

// cleanContacts: e-mail, link, @handle, wallet address, IBAN, 7+ digit numbers.
// Returns the text and the kinds found, in this order.
func cleanContacts(s string) (string, []string) {
	s = strings.Join(strings.Fields(s), " ")
	var found []string
	mark := func(kind string) {
		for _, x := range found {
			if x == kind {
				return
			}
		}
		found = append(found, kind)
	}
	sub := func(pat, with, kind string) {
		re := regexp.MustCompile(pat)
		if re.MatchString(s) {
			s = re.ReplaceAllString(s, with)
			mark(kind)
		}
	}
	sub(`[\w.+-]+@[\w-]+(\.[\w-]+)+`, "bir e-posta", Email)
	sub(`(?i)(https?://|www\.)\S+`, "bir site", "link")
	sub(`(?i)\b[\w-]+\.(com|net|org|tv|io|me|app|xyz|info|gov|edu)(\.tr)?(/\S*)?\b`, "bir site", "link")
	sub(`(^|[^\pL\pN_])@[\pL\pN_.]{2,}`, "${1}biri", "handle")
	sub(`\b0x[0-9a-fA-F]{40}\b`, "bir cüzdan adresi", WalletAddress)
	sub(`(?i)\bTR\s?\d{2}(?:\s?\d){20,24}\b`, "bir hesap", IBAN)
	s = regexp.MustCompile(`\+?\(?\d[\d\s().-]{5,}\d`).ReplaceAllStringFunc(s, func(m string) string {
		n := 0
		for _, r := range m {
			if r >= '0' && r <= '9' {
				n++
			}
		}
		if n >= 7 {
			mark(Number)
			return "bir numara"
		}
		return m
	})
	return s, found
}

// contact kinds that count as secrets (links and @handles do not)
func isSecretKind(k string) bool {
	return k == Email || k == Number || k == IBAN || k == WalletAddress
}

const citiesText = `adana adıyaman afyon afyonkarahisar ağrı amasya ankara antalya artvin aydın balıkesir
bilecik bingöl bitlis bolu burdur bursa çanakkale çankırı çorum denizli diyarbakır edirne
elazığ erzincan erzurum eskişehir gaziantep antep giresun gümüşhane hakkari hatay ısparta
mersin istanbul izmir kars kastamonu kayseri kırklareli kırşehir kocaeli izmit konya kütahya
malatya manisa kahramanmaraş maraş mardin muğla muş nevşehir niğde ordu rize sakarya adapazarı
samsun siirt sinop sivas tekirdağ tokat trabzon tunceli urfa şanlıurfa uşak van yozgat zonguldak
aksaray bayburt karaman kırıkkale batman şırnak bartın ardahan ığdır yalova karabük kilis
osmaniye düzce kadıköy üsküdar beşiktaş şişli bakırköy çankaya keçiören bornova karşıyaka
ilkadım atakum canik tekkeköy bafra terme vezirköprü ünye fatsa esenyurt bağcılar pendik
ümraniye beylikdüzü ataşehir maltepe kağıthane sarıyer avcılar küçükçekmece büyükçekmece
buca karabağlar menemen torbalı yenimahalle etimesgut mamak sincan polatlı nilüfer osmangazi
inegöl gemlik mudanya selçuklu karatay seyhan çukurova yüreğir tarsus iskenderun antakya
muratpaşa kepez alanya manavgat marmaris fethiye kuşadası didim nazilli söke şahinbey
şehitkamil kocasinan melikgazi odunpazarı tepebaşı ortahisar akçaabat ereğli gebze serdivan
çorlu lüleburgaz edremit ayvalık bandırma akhisar salihli turgutlu merkezefendi
kartal çeşme konak bodrum meram havza`

// also everyday words: a city only when capitalised
const ambiguousCities = "ağrı ordu van muş tokat uşak kars batman mersin kartal çeşme konak bodrum meram havza"

const citySuffixes = `a e ya ye na ne da de ta te daki deki taki teki dan den tan ten ndan nden
ı i u ü yı yi yu yü nı ni nu nü ın in un ün nın nin nun nün la le yla yle lı li lu lü
lılar liler lular lüler`

const namesText = `ahmet mehmet mustafa ali hüseyin hasan ibrahim ismail osman yusuf murat ömer ramazan
halil süleyman abdullah mahmut recep fatih kadir emre hakan serkan burak volkan tolga onur kerem
cem caner emir eyüp eyup yasin furkan enes berk arda kaan oğuz selim sinan tuncay erkan gökhan
orhan kemal levent metin erdem cengiz fikret necati şükrü zeki tayfun ilker ercan ayşe fatma
emine hatice zeynep elif meryem şerife sultan hanife merve büşra esra özlem yasemin hülya sevgi
derya ebru gamze tuğba aslı didem pınar şule seda gizem burcu ece irmak cansu damla buse melike
melek hande nazlı sibel songül filiz gülsüm hacer kübra rabia sevda tülay dilek ayten nermin
nurcan aysel aynur mine şeyma beyza tuba`

// also everyday words: a name only when capitalised mid-sentence
const ambiguousNames = `can umut deniz barış bahar yağmur su ay gül kader güneş nur ilkay sevgi
özge alp aslan kartal doğan bulut ozan çınar ılgaz toprak ege mert efe`

// capitalised mid-sentence but not a proper name
const freeWords = `ben sen o biz siz onlar allah tanrı türkçe ingilizce türkiye dünya mars ay güneş
pazartesi salı çarşamba perşembe cuma cumartesi pazar ocak şubat mart nisan mayıs haziran
temmuz ağustos eylül ekim kasım aralık ramazan bayram`

var neutral = map[string]map[string]string{
	"person": {"": "biri", "e": "birine", "den": "birinden", "de": "birinde",
		"i": "birini", "in": "birinin", "le": "biriyle", "li": "biri"},
	"city": {"": "bir şehir", "e": "bir şehre", "den": "bir şehirden", "de": "bir şehirde",
		"i": "bir şehri", "in": "bir şehrin", "le": "bir şehirle", "li": "bir şehirli"},
	"other": {"": "falanca", "e": "falancaya", "den": "falancadan", "de": "falancada",
		"i": "falancayı", "in": "falancanın", "le": "falancayla", "li": "falancalı"},
}

// suffixKind maps a Turkish case suffix to its kind ("'dan" -> "den"). Ekin turu.
func suffixKind(suf string) string {
	e := fold(suf)
	if e == "" {
		return ""
	}
	for _, x := range [][2]string{
		{`^(n)?(d|t)(a|e)n$`, "den"}, {`^(n)?(d|t)(a|e)(ki)?$`, "de"}, {`^(y|n)?(a|e)$`, "e"},
		{`^(n)?(i|u)n$`, "in"}, {`^(y|n)?(i|u)$`, "i"}, {`^(y)?l(a|e)$`, "le"}, {`^l(i|u)$`, "li"},
	} {
		if regexp.MustCompile(x[0]).MatchString(e) {
			return x[1]
		}
	}
	return ""
}

func cityOf(kk string, capital bool, cities, ambiguous, suffixes map[string]bool) (string, bool) {
	best, rest, ok := "", "", false
	for c := range cities {
		if !strings.HasPrefix(kk, c) || len(c) <= len(best) {
			continue
		}
		r := kk[len(c):]
		if r != "" && !suffixes[r] {
			continue
		}
		if ambiguous[c] && !capital {
			continue
		}
		best, rest, ok = c, r, true
	}
	return rest, ok
}

// Clean returns the cleaned text and the kinds removed
// (email, link, handle, wallet_address, iban, number, address, city, name, proper_noun).
func Clean(text string) (string, []string) {
	s, found := cleanContacts(clip(text))
	mark := func(kind string) {
		for _, x := range found {
			if x == kind {
				return
			}
		}
		found = append(found, kind)
	}

	// street address
	addr := regexp.MustCompile(`(^|[^` + letters + `])((?:[A-ZÇĞİÖŞÜ0-9][` + letters + `0-9]*\.?\s+){1,3}(?:[Mm]ahallesi|[Mm]ah\.|[Cc]addesi|[Cc]ad\.|[Ss]okağı|[Ss]okak|[Ss]ok\.|[Ss]k\.|[Bb]ulvarı|[Aa]partmanı|[Aa]pt\.|[Ss]itesi|[Kk]öyü))([^\pL\pN_]|$)`)
	if addr.MatchString(s) {
		s = addr.ReplaceAllString(s, "${1}bir adres${3}")
		mark("address")
	}
	door := regexp.MustCompile(`(?i)\b(no|numara|daire|kat)\s*[:.]?\s*\d+(\s*/\s*\d+)?(\s*['’]?\s*[dt][ae](ki)?\b)?`)
	if door.MatchString(s) {
		s = door.ReplaceAllString(s, "")
		mark("address")
	}
	s = strings.TrimSpace(regexp.MustCompile(`(bir adres[\s,]*)+`).ReplaceAllString(s, "bir adres "))

	// word by word: city, name, capitalised proper noun mid-sentence
	cities, ambC, sufs := set(citiesText), set(ambiguousCities), set(citySuffixes)
	names, ambN, free := set(namesText), set(ambiguousNames), set(freeWords)
	wordRe := regexp.MustCompile(`^(["'(]*)([` + letters + `]+)(?:['’]([` + letters + `]+))?(.*)$`)
	endRe := regexp.MustCompile(`[.!?]$`)
	var out []string
	start, prevGone := true, false
	for _, part := range regexp.MustCompile(`\s+|\S+`).FindAllString(s, -1) {
		if strings.TrimSpace(part) == "" {
			out = append(out, part)
			continue
		}
		m := wordRe.FindStringSubmatch(part)
		if m == nil {
			out = append(out, part)
			start, prevGone = endRe.MatchString(part), false
			continue
		}
		pre, root, suf, post := m[1], m[2], m[3], m[4]
		kk := lowerTR(root)
		capital := unicode.IsUpper([]rune(root)[0]) && root != strings.ToUpper(root)
		repl, changed := "", false
		if citySuf, ok := cityOf(kk, capital, cities, ambC, sufs); ok {
			e := suf
			if e == "" {
				e = citySuf
			}
			if suffixKind(e) == "li" {
				repl = "bir şehirli"
			} else {
				repl = neutral["city"][suffixKind(e)]
			}
			changed = true
			mark("city")
		} else if names[kk] || (capital && !start && ambN[kk]) {
			repl, changed = neutral["person"][suffixKind(suf)], true
			mark("name")
		} else if capital && prevGone {
			repl, changed = "", true // surname / soyadi
			mark("name")
		} else if capital && !start && !free[kk] && len([]rune(kk)) > 1 {
			repl, changed = neutral["other"][suffixKind(suf)], true
			mark("proper_noun")
		}
		if changed {
			out = append(out, pre+repl+post)
			prevGone = repl != ""
		} else {
			out = append(out, part)
			prevGone = false
		}
		start = endRe.MatchString(part)
	}
	s = strings.Join(out, "")
	s = regexp.MustCompile(`\s+([,.!?])`).ReplaceAllString(s, "$1")
	s = strings.Join(strings.Fields(s), " ")
	// "biri biri" -> "biri"
	var words []string
	for _, w := range strings.Split(s, " ") {
		if n := len(words); n > 0 && (words[n-1] == "biri" || words[n-1] == "falanca") {
			rest := strings.TrimPrefix(w, words[n-1])
			if rest != w && strings.TrimFunc(rest, func(r rune) bool { return !isWord(r) }) == "" {
				words[n-1] = w
				continue
			}
		}
		words = append(words, w)
	}
	return strings.Join(words, " "), found
}
