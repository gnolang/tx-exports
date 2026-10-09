package catalog

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// The catalog's collections in the data realm (docs/ARCHITECTURE-v1.md,
// section 3). P(n) is store.Pad. Records are store.Rec values; id lists are
// store's packed lists.
const (
	cArtists    = "catalog/artists"    // P((id-1)/chunkSize) -> artist heads (chunk)
	cAlists     = "catalog/alists"     // P(artist) -> Rec(track ids, album ids)
	cOwners     = "catalog/owners"     // owner address -> artist id
	cNames      = "catalog/names"      // name skeleton -> artist id
	cTracks     = "catalog/tracks"     // P((id-1)/chunkSize) -> track records (chunk)
	cGenres     = "catalog/genres"     // P(genre)/P(id>>9) -> packed track ids
	cAlbums     = "catalog/albums"     // P((id-1)/chunkSize) -> album records (chunk)
	cPlaylists  = "catalog/playlists"  // P(id) -> playlist record
	cUsers      = "catalog/users"      // address -> Rec(follows, tipped, playlists, reports)
	cLikes      = "catalog/likes"      // address/P(id>>9) -> packed liked track ids
	cTipped     = "catalog/tipped"     // address/P(id>>9) -> packed tipped track ids
	cReports    = "catalog/reports"    // P(id) -> report record (open reports only)
	cRemoved    = "catalog/removed"    // kind:id -> moderator's reason, "" when its artist hid it
	cHosts      = "catalog/hosts"      // allowed https host -> "1"
	cMeta       = "catalog/meta"       // "n" -> counts
	cTops       = "catalog/tops"       // liked|artists|fans|support -> ranks
	cActivity   = "catalog/activity"   // P(0..63) -> activity record (ring, head in meta)
	cConfig     = "catalog/config"     // admin, treasury, goal, bot, gen
	cSupporters = "catalog/supporters" // address -> lifetime support
	cMonthly    = "catalog/monthly"    // YYYY-MM -> support that month
	cPromo      = "catalog/promo"      // P(artist) -> promo percent
	cBudgets    = "catalog/budgets"    // P(artist) -> sponsored-pick settings and stats
	cWalletDay  = "catalog/walletday"  // address -> day|artist ids sponsored that day
	cClaims     = "catalog/claims"     // P(artist) -> pending claim
	cProofs     = "catalog/proofs"     // P(artist) -> proof URL of the last finalized claim
)

var collections = []string{cArtists, cAlists, cOwners, cNames, cTracks, cGenres, cAlbums, cPlaylists, cUsers,
	cLikes, cTipped, cReports, cRemoved, cHosts, cMeta, cTops, cActivity, cConfig, cSupporters, cMonthly,
	cPromo, cBudgets, cWalletDay, cClaims, cProofs}

const (
	chunkSize    = 8    // records per key of the chunked collections; tickets/nft reads artists with it: frozen
	maxRec       = 1500 // longest artist, track or album record when written by its author
	idRange      = 9    // likes, tips and genres are kept per range of 1<<idRange track ids
	activitySize = 64
)

// setup makes the catalog's collections and its first settings, once: a
// later release finds them made (it is not the writer in its init).
func setup(cur realm, holder address) {
	for _, c := range collections {
		data.Make(cross(cur), c)
	}
	if data.Has(cMeta, "n") {
		return
	}
	ops := store.Ops{}.Set(cMeta, "n", newCounts()).Set(cConfig, "admin", holder.String()).
		Set(cHosts, "archive.org", "1").Set(cHosts, "upload.wikimedia.org", "1")
	data.Batch(cross(cur), ops)
}

// tx reads each key from the data realm once and writes every key it
// changed once, in one call (data.Set or data.Batch). Every entrypoint loads
// what it needs, changes it in its tx, then saves; readers use one too, so a
// chunk is decoded once per call. A tx is never stored.
type tx struct {
	es  []entry
	idx map[string]int // entry key -> position in es
}

type entry struct {
	c, k  string // collection and key
	val   string
	ok    bool // the key exists
	dirty bool
}

func rd() *tx { return &tx{idx: map[string]int{}} }

// at finds a key's entry, reading it from data the first time unless blind
// (a key about to be overwritten).
func (t *tx) at(c, k string, blind bool) *entry {
	key := c + " " + k
	if i, ok := t.idx[key]; ok {
		return &t.es[i]
	}
	e := entry{c: c, k: k}
	if !blind {
		e.val, e.ok = data.Get(c, k)
	}
	t.idx[key] = len(t.es)
	t.es = append(t.es, e)
	return &t.es[len(t.es)-1]
}

func (t *tx) get(c, k string) (string, bool) {
	e := t.at(c, k, false)
	return e.val, e.ok
}

func (t *tx) val(c, k string) string { return t.at(c, k, false).val }

func (t *tx) set(c, k, v string) {
	e := t.at(c, k, false)
	e.val, e.ok, e.dirty = v, true, true
}

// put writes a key without reading it first.
func (t *tx) put(c, k, v string) {
	e := t.at(c, k, true)
	e.val, e.ok, e.dirty = v, true, true
}

func (t *tx) del(c, k string) {
	if e := t.at(c, k, false); e.ok {
		e.val, e.ok, e.dirty = "", false, true
	}
}

// save writes what t changed: one data.Set or data.Remove, or Batches of
// 64 ops (a bulk ResolveReports may change more keys than one Batch takes;
// the transaction keeps them atomic, as in radio).
func save(cur realm, t *tx) {
	var ops store.Ops
	for _, e := range t.es {
		if !e.dirty {
			continue
		}
		if e.ok {
			ops = ops.Set(e.c, e.k, e.val)
		} else {
			ops = ops.Del(e.c, e.k)
		}
	}
	for len(ops) > 4*64 {
		data.Batch(cross(cur), ops[:4*64])
		ops = ops[4*64:]
	}
	switch {
	case len(ops) == 0:
	case len(ops) > 4:
		data.Batch(cross(cur), ops)
	case ops[0] == store.OpSet:
		data.Set(cross(cur), ops[1], ops[2], ops[3])
	default:
		data.Remove(cross(cur), ops[1], ops[2])
	}
}

// ---- chunked records: artists, tracks and albums, chunkSize per key ----

// rec returns record id of a chunked collection ("" when absent).
func (t *tx) rec(c string, id int) string {
	if id < 1 {
		return ""
	}
	k, i := store.Slot(id, chunkSize)
	ch := t.val(c, k)
	if ch == "" {
		return ""
	}
	return store.Field(ch, i)
}

// point is tx.rec without a tx, for the getters that read one or two
// records: no tx to build for a call the radio makes in loops.
func point(c string, id int) string {
	if id < 1 {
		return ""
	}
	k, i := store.Slot(id, chunkSize)
	if ch, _ := data.Get(c, k); ch != "" {
		return store.Field(ch, i)
	}
	return ""
}

// artistAt is field f of an artist's record, "" when unknown (point).
func artistAt(id, f int) string {
	if rec := point(cArtists, id); rec != "" {
		return store.Field(rec, f)
	}
	return ""
}

// setRec replaces record id.
func (t *tx) setRec(c string, id int, rec string) {
	k, i := store.Slot(id, chunkSize)
	t.set(c, k, store.With(t.val(c, k), i, rec))
}

// addRec appends record id, the collection's next one.
func (t *tx) addRec(c string, id int, rec string) {
	k, i := store.Slot(id, chunkSize)
	if i == 0 {
		t.put(c, k, store.Rec(rec))
		return
	}
	t.set(c, k, store.Append(t.val(c, k), rec))
}

// fits refuses a record too long for its chunk: chunkSize records, each
// with room left for its counters and early badges, stay under data's
// 16 KiB value limit, so one author can never fill a chunk others share.
func fits(rec string) string {
	if len(rec) > maxRec {
		panic("catalog: these details are too long, shorten the links or texts")
	}
	return rec
}

// ---- counts: catalog/meta "n", one field each ----

// Count fields. A count is read and changed in place (store.Field and
// store.With): converting numbers costs gas, so nothing decodes the record.
// Reaching field i walks the i before it: what a publish changes comes first.
const (
	mTracks = 0
	mGenre  = 0 // + genre id (1..NumGenres): tracks filed under it
)

const (
	mArtists = NumGenres + 1 + iota
	mAlbums
	mPlaylists
	mReports // filed
	mOpen    // reports not yet resolved
	mSupporters
	mSupport // ugnot
	mFields
)

func newCounts() string {
	fs := make([]string, mFields)
	for i := range fs {
		fs[i] = "0"
	}
	return store.Rec(fs...)
}

func (t *tx) count(i int) int64 {
	if m := t.val(cMeta, "n"); m != "" {
		return text.Atoi64(store.Field(m, i))
	}
	return 0
}

// bump adds d to count i and returns the new value; save writes it.
func (t *tx) bump(i int, d int64) int64 {
	n := t.count(i) + d
	t.set(cMeta, "n", store.With(t.val(cMeta, "n"), i, text.Itoa64(n)))
	return n
}

// ---- id ranges: a sorted packed list per 512 ids ----

func rangeKey(prefix string, id int) string { return prefix + "/" + store.Pad(id>>idRange) }

// addID and removeID change a ranged id set; false when nothing changed.
func (t *tx) addID(c, prefix string, id int) bool {
	k := rangeKey(prefix, id)
	list := t.val(c, k)
	if n := store.Count(list); n == 0 || store.At(list, n-1) < id {
		t.set(c, k, list+store.Enc(id)) // a new highest id, as every new track's
		return true
	}
	list, ok := store.Add(list, id)
	if ok {
		t.set(c, k, list)
	}
	return ok
}

func (t *tx) removeID(c, prefix string, id int) bool {
	k := rangeKey(prefix, id)
	list, ok := store.Remove(t.val(c, k), id)
	switch {
	case !ok:
	case list == "":
		t.del(c, k)
	default:
		t.set(c, k, list)
	}
	return ok
}

// rangePage reads up to limit ids of a ranged set from offset, highest
// first, and the set's size, one data.Page per 100 ranges.
func rangePage(c, prefix string, offset, limit int) (ids []int, total int) {
	end := prefix + "0"
	// ponytail: at most 10 pages of 100 ranges (512,000 track ids); keep a
	// counter per set if the catalog ever gets near that.
	for p := 0; p < 10; p++ {
		keys, lists := store.Rows(data.Page(c, prefix+"/", end, 100, true))
		for _, l := range lists {
			n := store.Count(l)
			total += n
			if offset >= n {
				offset -= n
				continue
			}
			if len(ids) < limit {
				ids = append(ids, store.Page(l, offset, limit-len(ids), true)...)
			}
			offset = 0
		}
		if len(keys) < 100 {
			break
		}
		end = keys[len(keys)-1]
	}
	return ids, total
}

// ---- activity ring and leaderboards ----

// Activity is one entry of the public activity feed.
type Activity struct {
	Kind   string // publish | like | follow | tip | support | playlist | album | claim
	By     address
	Track  int // track, playlist or album id depending on Kind
	Artist int
	Amount int64
	At     int64
}

// activity writes the next slot of the fixed-size ring (storage never
// grows), numbers given as decimal strings. The ring's head is a key of its
// own in catalog/meta: rewriting the counts would cost a like more.
func (t *tx) activity(kind string, by address, track, artist, amount string) {
	h := text.Atoi(t.val(cMeta, "head"))
	t.put(cActivity, store.Pad(h), store.Rec(kind, by.String(), track, artist, amount, text.Itoa64(now())))
	t.set(cMeta, "head", text.Itoa((h+1)%activitySize))
}

// activityOnce is activity for likes and follows, skipped when the newest
// entry is already this wallet's of the same kind: like and unlike cycles,
// or a run of likes, take one slot of the feed, not the whole ring.
func (t *tx) activityOnce(kind string, by address, track, artist string) {
	h := text.Atoi(t.val(cMeta, "head"))
	last := t.val(cActivity, store.Pad((h+activitySize-1)%activitySize))
	if store.Field(last, 0) == kind && store.Field(last, 1) == by.String() {
		return
	}
	t.activity(kind, by, track, artist, "0")
}

type Rank struct {
	Key   string
	Value int64
}

// Leaderboard names in cTops.
const (
	topLiked   = "liked"   // track ids by likes
	topArtists = "artists" // artist ids by tips
	topFans    = "fans"    // addresses by tipped
	topSupport = "support" // addresses by support
)

func ranks(rec string) []Rank {
	if rec == "" {
		return nil
	}
	f := store.Fields(rec)
	out := make([]Rank, 0, len(f)/2)
	for i := 0; i+1 < len(f); i += 2 {
		out = append(out, Rank{f[i], text.Atoi64(f[i+1])})
	}
	return out
}

func (t *tx) top(name string) []Rank { return ranks(t.val(cTops, name)) }

// rank moves k to v in a leaderboard, written only when the ranking
// changed. Most changes leave it alone: when v grew (up) and is no higher
// than the tenth value, k was not ranked either, so nothing is decoded. A
// value that went down is looked for in the list (a substring match only
// means "maybe ranked").
func (t *tx) rank(name, k string, v int64, up bool) {
	old := t.val(cTops, name)
	if old != "" {
		if last := store.Field(old, 2*topSize-1); last != "" && v <= text.Atoi64(last) && (up || !strings.Contains(old, k)) {
			return
		}
	}
	list := updateTop(ranks(old), k, v)
	fs := make([]string, 0, 2*len(list))
	for _, r := range list {
		fs = append(fs, r.Key, text.Itoa64(r.Value))
	}
	if rec := store.Rec(fs...); rec != old {
		t.set(cTops, name, rec)
	}
}

// updateTop keeps a short leaderboard sorted by value, highest first.
func updateTop(list []Rank, k string, v int64) []Rank {
	if len(list) == topSize && v <= list[topSize-1].Value {
		ranked := false
		for _, r := range list {
			ranked = ranked || r.Key == k
		}
		if !ranked {
			return list
		}
	}
	out := make([]Rank, 0, topSize+1)
	for _, r := range list {
		if r.Key != k {
			out = append(out, r)
		}
	}
	i := len(out)
	for i > 0 && out[i-1].Value < v {
		i--
	}
	if i >= topSize {
		return out
	}
	out = append(out, Rank{})
	copy(out[i+1:], out[i:])
	out[i] = Rank{k, v}
	if len(out) > topSize {
		out = out[:topSize]
	}
	return out
}
