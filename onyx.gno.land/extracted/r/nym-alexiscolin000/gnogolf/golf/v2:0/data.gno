package golf

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"gno.land/p/nym-alexiscolin000/gnogolf/course"
)

// Holes as data: a version is a GG1 string, checked once at publish and kept
// as bytes; each call decodes it afresh and stores nothing of it. A version
// is never edited or removed: a new one takes its alias, and the old one is
// archived, still playable, its records kept.

// wearGrid is the entry's wear: a count of balls at rest per cell of the
// WearW by WearH grid, row-major.
func (e *entry) wearGrid() []int {
	out := make([]int, wearCells)
	e.wear().Iterate("", "", func(k, v string) bool {
		if i := atoi(k); i >= 0 && i < wearCells {
			out[i] = atoi(v)
		}
		return false
	})
	return out
}

const wearCells = course.WearW * course.WearH

// wear is a version's wear counters: pad(cell, 3) -> balls at rest there, a
// row a cell played (one small write a stroke).
func (e *entry) wear() view { return view{"wear", e.id + " "} }

// mark counts a ball come to rest in wear cell i.
func (e *entry) mark(i int) {
	if i < 0 || i >= wearCells {
		return // course.WearIndexOn never gives one
	}
	k := pad(i, 3)
	n := 0
	if v, ok := e.wear().Get(k); ok {
		n = atoi(v)
	}
	e.wear().Set(k, itoa(n+1))
}

// maxData bounds a version's data: a hole at every limit of the format is
// about 21 KB.
const maxData = 32 << 10

// Publish puts a course hole's data into its slot as its next version and
// returns the new id ("garden/7/v2"). Only the owner can. hexData is the hole
// as course.Encode wrote it, in hex. slot must be the data's own world and
// order ("garden/7", order 1 to 999), so a mis-edited file cannot replace the
// wrong hole; the course holds at most 9999 slots (maxCourse). Data identical
// to the current version's is refused. The version it replaces is archived:
// its records stay, its bests leave the course standings. note (at most 140
// characters, cleaned) says why.
func Publish(cur realm, slot, hexData, note string) string {
	begin()
	r := publishNow(cur, slot, hexData, note)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func publishNow(cur realm, slot, hexData, note string) string {
	by := cur.Previous().Address()
	if !isOwner(by) {
		panic("golf: only the owner can publish a course hole")
	}
	h, data, sum := decodeData(hexData)
	if h.Order < 1 || h.Order != math.Trunc(h.Order) {
		panic("golf: a course hole's order is a whole number from 1 to 999")
	}
	own := h.World + "/" + strconv.Itoa(int(h.Order))
	if slot != own {
		panic("golf: this data is " + own + ", not " + slot)
	}
	key, ok := slotKeyOf(slot)
	if !ok {
		panic("golf: " + slot + " is not a course slot") // its data's own world/order: cannot happen
	}
	var old *entry
	n := 1
	if v, ok := slots.Get(key); ok {
		old = find(v)
		if old.sha == sum {
			panic(nothingNew(old))
		}
		n = old.version + 1
	} else if slots.Size() >= maxCourse {
		panic("golf: the course is full: 9999 slots")
	}
	e := dataEntry(slot, n, h, by, sum, note)
	e.official = true
	saveEntry(e)
	holeData.Set(e.id, data)
	slots.Set(key, e.id)
	chain.Emit(EventHolePublished, "hole", e.id, "slot", slot, "sha", sum, "by", by.String(), "official", "true")
	if old != nil {
		retire(old, e.id)
	}
	return e.id
}

// PublishMine publishes a community hole of the caller's own and returns its
// id: "<caller>/<slug>/v1", then v2 and on. Anyone can while publishing is
// open (SetPublishing); only the same address adds versions. slug is 1 to 32
// of a-z, 0-9 and "-". The data is checked as Publish checks it, its world
// and order aside; its name and note carry no web address. It is playable and
// recorded, in no cup and not in the course ranking; a new version of a
// hidden hole stays hidden. The publisher pays the storage deposit (about
// half a GNOT a version), and nothing published can be deleted.
func PublishMine(cur realm, slug, hexData, note string) string {
	begin()
	r := publishMineNow(cur, slug, hexData, note)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func publishMineNow(cur realm, slug, hexData, note string) string {
	if !publishing {
		panic("golf: publishing community holes is not open yet")
	}
	by := cur.Previous().Address()
	if !validSlug(slug) {
		panic("golf: a slug is 1 to 32 of a-z, 0-9 and -")
	}
	alias := by.String() + "/" + slug
	h, data, sum := decodeData(hexData)
	var old *entry
	n := 1
	if v, ok := aliases.Get(alias); ok {
		old = find(v)
		if old.sha == sum {
			panic(nothingNew(old))
		}
		n = old.version + 1
	}
	e := dataEntry(alias, n, h, by, sum, note)
	if linkish(e.name) || linkish(e.note) {
		panic("golf: a community hole's name and note carry no web address")
	}
	saveEntry(e)
	holeData.Set(e.id, data)
	aliases.Set(alias, e.id)
	if old != nil {
		old.next = e.id // archived; it never counted anywhere
		saveEntry(old)
	}
	if !hidden.Has(alias) { // a hidden hole has no row (Hide)
		a := by.String()
		// the newest row: the author's own moves to its height
		moveAuthor(a, newestRow(a), pad(int(e.height), 12))
		if old != nil {
			byAuthor.Remove(a + " " + recentKey(old.height, slug))
		}
		byAuthor.Set(a+" "+recentKey(e.height, slug), e.id)
	}
	chain.Emit(EventHolePublished, "hole", e.id, "slot", alias, "sha", sum, "by", by.String(), "official", "false")
	return e.id
}

// newestRow is the height of an author's newest row in byAuthor
// ("<address> <height> <slug>"), "" if they have none.
func newestRow(a string) string {
	latest := ""
	byAuthor.ReverseIterate(a+" ", a+"!", func(k, _ string) bool {
		latest = k[len(a)+1 : len(a)+13]
		return true
	})
	return latest
}

// newestRowBut is newestRow with the row but left out ("" if it was their only one).
func newestRowBut(a, but string) string {
	latest := ""
	byAuthor.ReverseIterate(a+" ", a+"!", func(k, _ string) bool {
		if k == but {
			return false
		}
		latest = k[len(a)+1 : len(a)+13]
		return true
	})
	return latest
}

// moveAuthor moves an author's own row in byAuthor (recentKey(height,
// address)) from the height was to now, "" for none: it stays at their
// newest row's, and goes with their last.
func moveAuthor(a, was, now string) {
	if was == now {
		return
	}
	if was != "" {
		byAuthor.Remove(was + " " + a)
	}
	if now != "" {
		byAuthor.Set(now+" "+a, "")
	}
}

// linkish spots a web address in a community hole's name or note: "www.", a
// dot between a letter or digit and two letters ("claim.xyz", "t.me"; not
// "e.g."), or an IP address, look-alike dots (．。․﹒) read as dots, letters in
// any case. Basic (the owner can Hide what gets past) and strict on purpose
// ("St.Andrews" is refused). It reads s a byte at a time: every mark is
// ASCII, so a non-ASCII character is decoded only to tell İ and the Kelvin
// sign (which lower-case to ASCII), the look-alike dots and spaces apart.
func linkish(s string) bool {
	var c1, c2, c3 byte // the three characters before c, lower-cased
	// the word so far (as strings.Fields splits): an IP is digits, three dots
	word, ip, dots := false, true, 0
	for i := 0; i < len(s); {
		c, size, space := s[i], 1, false
		switch {
		case c >= 'A' && c <= 'Z':
			c += 'a' - 'A'
		case c >= utf8.RuneSelf:
			var r rune
			r, size = utf8.DecodeRuneInString(s[i:])
			switch r {
			case 'İ':
				c = 'i'
			case '\u212a': // the Kelvin sign
				c = 'k'
			case '．', '。', '․', '﹒':
				c = '.'
			default:
				c, space = utf8.RuneSelf, unicode.IsSpace(r) // none of the marks
			}
		case c == ' ' || c >= '\t' && c <= '\r':
			space = true
		}
		i += size
		switch {
		case c == '.' && c1 == 'w' && c2 == 'w' && c3 == 'w':
			return true
		case isLower(c) && isLower(c1) && c2 == '.' && (isLower(c3) || isDigit(c3)):
			return true
		}
		c1, c2, c3 = c, c1, c2
		if space {
			if word && ip && dots == 3 {
				return true
			}
			word, ip, dots = false, true, 0
			continue
		}
		word = true
		if c == '.' {
			dots++
		} else if !isDigit(c) {
			ip = false
		}
	}
	return word && ip && dots == 3
}

func isLower(c byte) bool { return c >= 'a' && c <= 'z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// decodeData checks a version's data as it arrives: hex, GG1 within the
// format's limits, stored lengths bit-exact (DecodeChecked: every later
// Decode trusts them), and in the one form Encode gives.
func decodeData(hexData string) (*course.Simple, string, string) {
	if len(hexData) > 2*maxData {
		panic("golf: the data is too long")
	}
	b, err := hex.DecodeString(hexData)
	if err != nil {
		panic("golf: the data is not hex")
	}
	data := string(b)
	h, err := course.DecodeChecked(data)
	if err != nil {
		panic("golf: " + err.Error())
	}
	// one hole, one string: data that decodes to a hole Encode would write
	// otherwise (a skin never used, a style run split, a stored length a
	// zero-length wall never reads) is refused, so the same hole cannot come
	// back under another sha
	if course.Encode(h) != data {
		panic("golf: the data is not as course.Encode writes it")
	}
	// refused if a transaction could not replay its heaviest shot, or if in
	// its dearest weather a commit's first shot would be capped below
	// minShotWork: every commit decodes the hole and draws its forecast first
	if newWork(h, nil).bound > maxShotGas {
		panic(errShotTooHeavy)
	}
	if worstGas(h, len(data)) > workBudget {
		panic(errTooStormy)
	}
	sum := sha256.Sum256(b)
	return h, data, hex.EncodeToString(sum[:])
}

// nothingNew refuses data identical to the alias's current version: it would
// reset the hole's ranking for nothing.
func nothingNew(old *entry) string {
	return "golf: this data is already " + old.id + ": nothing to publish"
}

func dataEntry(alias string, n int, h *course.Simple, by address, sum, note string) *entry {
	e := newEntry(alias+"/v"+strconv.Itoa(n), cleanName(h.Title), h.Par(), h.World, h.Order)
	e.slot, e.version, e.by, e.height, e.sha, e.note = alias, n, by, runtime.ChainHeight(), sum, cleanText(note, maxNote)
	return e
}

// worlds is the course's worlds in play order, with their names on the page.
var worlds = []struct{ id, name string }{
	{"garden", "Garden Cup"},
	{"island", "Island Cup"},
	{"town", "Mushroom Town"},
	{"mountain", "Mountain Cup"},
	{"mines", "Crystal Mines"},
}

// worldRank is a world's place among worlds; any other comes after.
func worldRank(w string) int {
	for i, x := range worlds {
		if x.id == w {
			return i
		}
	}
	return len(worlds)
}

// slotKey is a slot's key: its world's rank, the world, and the order in
// three digits, so the slots tree is in course order.
func slotKey(world string, order int) string {
	return string(rune('0'+worldRank(world))) + world + "/" + pad(order, 3)
}

// slotKeyOf reads a slot, "world/order" (as "garden/7"), into its key.
func slotKeyOf(slot string) (string, bool) {
	i := strings.Index(slot, "/")
	if i < 0 || !course.IsWorld(slot[:i]) {
		return "", false
	}
	n, err := strconv.Atoi(slot[i+1:])
	if err != nil || n < 1 || n > course.MaxOrder || strconv.Itoa(n) != slot[i+1:] {
		return "", false
	}
	return slotKey(slot[:i], n), true
}

func validSlug(s string) bool {
	if len(s) < 1 || len(s) > 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// HoleData is a version's GG1, in hex, as it was published (an alias gives
// its current version's): what a later version of the rules or an auditor
// reads back.
func HoleData(hole string) string {
	e := readHole(hole)
	data, _ := holeData.Get(e.id)
	return hex.EncodeToString([]byte(data))
}

// Current is the id of the version an alias ("garden/7", "<address>/<slug>")
// plays now, "" if the alias has none.
func Current(alias string) string { return current(alias) }

// Versions is every version of an alias, oldest first (the newest pageMax if
// there are more): its id, number, the height it was published at, by whom,
// its data's sha256, its note, and the version that took its place. slot is
// the alias, "" (and no versions) for one that has none.
func Versions(alias string) string {
	now := find(current(alias))
	slot := ""
	if now != nil {
		slot = now.slot // never the caller's own bytes
	}
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"slot":` + jstr(slot) + `,"versions":[`)
	if now != nil {
		i := 0
		for n := firstVersion(now); n <= now.version; n++ {
			e := find(now.slot + "/v" + strconv.Itoa(n))
			if e == nil {
				continue // (one before this course's first here: imported from v1, with v1's number)
			}
			sb.WriteString(sep(i) + `{"id":` + jstr(e.id) + `,"v":` + strconv.Itoa(e.version) +
				`,"height":` + strconv.FormatInt(e.height, 10) + `,"by":` + jstr(e.by.String()) +
				`,"sha":` + jstr(e.sha) + `,"note":` + jstr(e.note) + `,"next":` + jstr(e.next) + "}")
			i++
		}
	}
	sb.WriteString("]}")
	return sb.String()
}

// firstVersion is the oldest of now's versions a list shows: the newest
// pageMax are (now is its alias's current version).
func firstVersion(now *entry) int {
	if now.version > pageMax {
		return now.version - pageMax + 1
	}
	return 1
}

// BestOf is a player's best finished round on a hole in a mode, 0 if none.
func BestOf(hole, mode string, player address) int {
	e, m := readHole(hole), modeOf(mode)
	return bestStrokes(bestOfPlayer(e, m, player.String()))
}
