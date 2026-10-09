package radio

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/blocks/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// The radio's collections in the data realm (docs/ARCHITECTURE-v1.md,
// section 3). P(n) is store.Pad, T(t) a 12-digit unix time. Numbers inside
// the hot records are fixed-width base-64 digits (store.Num, store.Fixed): a decimal
// conversion costs the VM several times more.
const (
	cStations = "radio/stations" // P(station) -> Rec(epoch, ring, live, rotation header, schedule, recent picks, weekly top[, ring rotation, ring index])
	cRot      = "radio/rot"      // P(station)/b/P(block) -> block; P(station)/g/P(group) -> block sums (p/blocks)
	cHomes    = "radio/homes"    // P((id-1)/homesChunk) -> Rec of homes entries (the genre stations of a track), one per synced track
	cMeta     = "radio/meta"     // "flow" -> flow record
	cCurators = "radio/curators" // address -> curator record (curators.gno)
	cTops     = "radio/tops"     // "all" -> this week's top curators across stations (a station's is in its record)
	cDropped  = "radio/dropped"  // P(station)/P(track) -> "1"
	cNotes    = "radio/notes"    // P(station)/T(start) -> reporters, or the strike a hide gave (notes.gno)
	cMuted    = "radio/muted"    // address -> unix time its dedications are refused until
	cStrikes  = "radio/strikes"  // address -> unix time one of its dedications was last hidden
	cSponsor  = "radio/sponsor"  // address/P(station) -> open sponsored pick (sponsor.gno)
	cActivity = "radio/activity" // P(0..63) -> activity record (a ring, its head in the flow record)
	cConfig   = "radio/config"   // "admin" (mirror of the admin role), "modbot" (hex key)
)

var collections = []string{cStations, cRot, cHomes, cMeta, cCurators, cTops, cDropped, cNotes,
	cMuted, cStrikes, cSponsor, cActivity, cConfig}

const (
	homesChunk = 16       // homes entries per key
	maxRecord  = 16 << 10 // the data realm's longest value
)

// setup makes the radio's collections and its first records, once: a later
// release finds them made (it is not the writer in its init).
func setup(cur realm, holder address) {
	for _, c := range collections {
		data.Make(cross(cur), c)
	}
	if data.Has(cMeta, "flow") {
		return
	}
	ops := store.Ops{}.Set(cMeta, "flow", strings.Repeat("0", flowLen)).Set(cConfig, "admin", holder.String())
	data.Batch(cross(cur), ops)
}

// Fixed-width base-64 numbers are store.Num, store.Fixed and
// store.AppendFixed. dec is store.Digits' decoding table, for the digits
// the hot loops read in place: a call per digit costs about 1% of a pick.
var dec = decTable()

func decTable() (d [128]int64) {
	for i := 0; i < len(store.Digits); i++ {
		d[store.Digits[i]] = int64(i)
	}
	return d
}

// ---- tx: every key read once and written once ----

// tx reads each key from the data realm once and writes every key it
// changed once, in one call (data.Set or data.Batch); the stations it
// loaded are decoded once and encoded back when changed. Every entrypoint
// loads what it needs, changes it in its tx, then saves; readers use one
// too. A tx is never stored.
type tx struct {
	es  []entry
	idx map[string]int // entry key -> position in es
	sts [numStations]*station
	flw string // the flow record, once read (flowRec)
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

func (t *tx) has(c, k string) bool { return t.at(c, k, false).ok }

func (t *tx) set(c, k, v string) {
	e := t.at(c, k, false)
	e.val, e.ok, e.dirty = v, true, true
}

// put writes a key without reading it first.
func (t *tx) put(c, k, v string) {
	e := t.at(c, k, true)
	e.val, e.ok, e.dirty = v, true, true
}

func (t *tx) del(c, k string) bool {
	e := t.at(c, k, false)
	if !e.ok {
		return false
	}
	e.val, e.ok, e.dirty = "", false, true
	return true
}

// save writes what t changed: one data.Set or data.Remove, or Batches of
// 64 ops (a Sync or a RefreshArtist may change more keys than one Batch
// takes; the transaction keeps them atomic).
func save(cur realm, t *tx) {
	for _, st := range t.sts {
		if st != nil && st.dirty {
			sched := st.raw
			if st.decoded {
				sched = encodeSchedule(st.sched)
			}
			f := []string{store.Fixed(st.epoch, 6), store.Fixed(int64(st.ring), 6), store.Fixed(int64(st.live), 4), st.h, sched, st.picks, st.top}
			if st.ringed() {
				f = append(f, st.rot, st.idx)
			}
			// A pick is refused once its station's record would leave less
			// than recordHeadroom, and the writes a pick or a Sync makes on
			// other stations wait while theirs does (full): this is a last
			// resort.
			rec := store.Rec(f...)
			if len(rec) > maxRecord {
				panic("radio: this station is full for now, try again later")
			}
			t.set(cStations, store.Pad(st.id), rec)
			st.dirty = false
		}
	}
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

// ---- the flow record: radio/meta "flow" ----

// The flow record is fixed-width: synced (4 digits), the number of dropped
// slots (4), the activity ring's next slot (1), the week of the top across
// stations and its last score when it holds topCurators (0 else) (4 and
// 4: a pick that scores less leaves it as it is, unread), then "1" for each
// genre station with a live track ("0" else, index = genre): Main relays
// one of those (hourGenre). Every call reads it.
const (
	fSynced  = 0
	fDrops   = 4
	fHead    = 8
	fTopWeek = 9
	fTopLast = 13
	fLive    = 17
	flowLen  = fLive + NumGenres + 1
)

// flowRec is the flow record, read once per tx: every call reads it. The data
// realm is permanent: a record an earlier release wrote shorter is padded
// with "0" (a later one's extra fields are kept as they are).
func (t *tx) flowRec() string {
	if t.flw == "" {
		t.flw = t.val(cMeta, "flow")
		if len(t.flw) < flowLen {
			t.flw += strings.Repeat("0", flowLen-len(t.flw))
		}
	}
	return t.flw
}

func (t *tx) flowAt(at, w int) int { return int(store.Num(t.flowRec(), at, w)) }

func (t *tx) setFlowAt(at, w, v int) {
	f := t.flowRec()
	if n := store.Fixed(int64(v), w); n != f[at:at+w] {
		t.flw = f[:at] + n + f[at+w:]
		t.set(cMeta, "flow", t.flw)
	}
}

func (t *tx) synced() int { return t.flowAt(fSynced, 4) }

// hasLive reports whether a genre station has a live track.
func (t *tx) hasLive(genre int) bool {
	return genre >= 1 && genre <= NumGenres && t.flowRec()[fLive+genre] == '1'
}

// dropped reports whether the admin dropped a track from a station.
func (t *tx) dropped(stationID, trackID int) bool {
	return t.flowAt(fDrops, 4) > 0 && t.has(cDropped, dropKey(stationID, trackID))
}

func dropKey(stationID, trackID int) string { return store.Pad(stationID) + "/" + store.Pad(trackID) }

// ---- stations ----

// station is a station loaded in a tx: its header and schedule are one
// record (cStations); its rotation is read and written a block at a time
// (cRot), but for New and Choice: their rings (at most 500 slots) and the
// index of the tracks in them are part of their record, which a pick
// changes anyway.
// The schedule is decoded on first use (slots): a call that only needs the
// time paused under it (paused) or a picker (picker) reads it as it is.
type station struct {
	t       *tx
	id      int
	genre   int // 0 = every genre
	epoch   int64
	ring    int    // New and Choice: joins so far; the slot reused next is ring % keep
	live    int    // rotation slots with a duration > 0
	h       string // the rotation's header (p/blocks)
	raw     string // the encoded schedule
	picks   string // the picks of the last replayGap (lastPicked)
	top     string // this week's top curators here (curators.gno)
	rot     string // New and Choice: the group then the blocks of their ring
	idx     string // and the ring's tracks: sorted entries, the track (4 digits) and its slot (2)
	sched   []Slot // sorted by Start, short (folded as it ages), once decoded
	decoded bool
	dirty   bool
	pz      int64 // paused(pzAt), while pzOK: the schedule did not move since
	pzAt    int64
	pzOK    bool
}

// station loads a station once per tx.
func (t *tx) station(id int) *station {
	if id < 0 || id >= numStations {
		panic("radio: unknown station")
	}
	if st := t.sts[id]; st != nil {
		return st
	}
	st := &station{t: t, id: id, genre: id}
	if id > NumGenres {
		st.genre = 0
	}
	if rec := t.val(cStations, store.Pad(id)); rec != "" {
		f := store.Fields(rec)
		st.epoch, st.ring, st.live, st.h, st.raw, st.picks, st.top = store.Num(f[0], 0, 6), int(store.Num(f[1], 0, 6)), int(store.Num(f[2], 0, 4)), f[3], f[4], f[5], f[6]
		if len(f) > 7 {
			st.rot, st.idx = f[7], f[8]
		}
	}
	t.sts[id] = st
	return st
}

// size is the length of the record save writes for the station, its
// schedule measured as encodeSchedule writes it, without writing it.
func (st *station) size() int {
	n := 1 + 3*7 + 6 + 6 + 4 + len(st.h) + len(st.picks) + len(st.top)
	if st.ringed() {
		n += 3*2 + len(st.rot) + len(st.idx)
	}
	if !st.decoded {
		return n + len(st.raw)
	}
	var prevEnd int64
	for i := range st.sched {
		s := &st.sched[i]
		switch gap := s.Start - prevEnd; {
		case gap == 0:
			n++
		case gap < 0:
			n += 7
		default:
			n += 2
			for gap>>6 != 0 {
				gap >>= 6
				n++
			}
		}
		n += 25 + len(s.By) + len(s.Note)
		prevEnd = s.Start + s.Dur
	}
	return n
}

// full reports whether the record keeps less than recordHeadroom: a new pick
// is refused, and a write a pick makes on the side (a Choice or New join)
// waits. A side write adds far less than recordHeadroom, so
// the record never reaches the data realm's limit (maxRecord).
func (st *station) full() bool { return st.size() > maxRecord-recordHeadroom }

// slots is the decoded schedule.
func (st *station) slots() []Slot {
	if !st.decoded {
		st.sched, st.decoded = decodeSchedule(st.raw), true
	}
	return st.sched
}

// setSlots replaces the schedule.
func (st *station) setSlots(s []Slot) {
	st.sched, st.decoded, st.dirty, st.pzOK = s, true, true, false
}

// addLive counts a slot going live (d = 1) or silent (-1); the flow record
// keeps which genre stations have one.
func (st *station) addLive(d int) {
	st.live += d
	st.dirty = true
	if st.id >= 1 && st.id <= NumGenres && (st.live > 0) != st.t.hasLive(st.id) {
		on := 0
		if st.live > 0 {
			on = 1
		}
		st.t.setFlowAt(fLive+st.id, 1, on)
	}
}

// ---- a station's rotation: p/blocks over its keys ----

func (st *station) ringed() bool { return st.id == NewStation || st.id == ChoiceStation }

// A ring's rotation (one group) is its group's sums, 4 digits per block,
// then its blocks, blocks.Size slots each but the last.
const blockLen = blocks.Size * 6

// ringBlocks is where a ring's blocks start.
func (st *station) ringBlocks() int { return 4 * ((st.count() + blocks.Size - 1) / blocks.Size) }

// group and block read group g and block b of the rotation.
func (st *station) group(g int) string {
	if st.ringed() {
		return st.rot[:st.ringBlocks()]
	}
	return st.t.val(cRot, store.Pad(st.id)+"/g/"+store.Pad(g))
}

func (st *station) block(b int) string {
	if !st.ringed() {
		return st.t.val(cRot, store.Pad(st.id)+"/b/"+store.Pad(b))
	}
	at := st.ringBlocks() + b*blockLen
	if at >= len(st.rot) {
		return ""
	}
	if at+blockLen < len(st.rot) {
		return st.rot[at : at+blockLen]
	}
	return st.rot[at:]
}

// setRotVal writes group g and block b; st.h is still the rotation's
// header before the change.
func (st *station) setRotVal(g int, grp string, b int, blk string) {
	if !st.ringed() {
		st.t.set(cRot, store.Pad(st.id)+"/g/"+store.Pad(g), grp)
		st.t.set(cRot, store.Pad(st.id)+"/b/"+store.Pad(b), blk)
		return
	}
	bs := st.rot[st.ringBlocks():]
	at, end := b*blockLen, b*blockLen+blockLen
	if at > len(bs) {
		at = len(bs)
	}
	if end > len(bs) {
		end = len(bs)
	}
	st.rot, st.dirty = grp+bs[:at]+blk+bs[end:], true
}

func (st *station) total() int64 { return blocks.Total(st.h) }
func (st *station) count() int   { return blocks.Len(st.h) }

func (st *station) rotSlot(i int) (int, int64) {
	if i < 0 || i >= st.count() {
		panic("radio: rotation index out of range")
	}
	_, b := blocks.Where(i)
	return blocks.Slot(st.block(b), i)
}

// find returns the rotation slot playing at position pos of the loop.
func (st *station) find(pos int64) (slot, id int, offset int64, ok bool) {
	g, rest, ok := blocks.FindGroup(st.h, pos)
	if !ok {
		return 0, 0, 0, false
	}
	b, rest := blocks.FindBlock(st.group(g), g, rest)
	slot, id, offset = blocks.FindSlot(st.block(b), b, rest)
	return slot, id, offset, true
}

func (st *station) prefixBefore(i int) int64 {
	g, b := blocks.Where(i)
	return blocks.PrefixBefore(st.h, st.group(g), st.block(b), i)
}

// appendRot adds a slot at the end of the rotation and returns its index.
func (st *station) appendRot(id int, dur int64) int {
	g, b := blocks.Where(st.count())
	h, grp, blk, i := blocks.Append(st.h, st.group(g), st.block(b), id, dur)
	st.setRotVal(g, grp, b, blk)
	st.h, st.dirty = h, true
	return i
}

// setRot replaces slot i's id and duration.
func (st *station) setRot(i, id int, dur int64) {
	g, b := blocks.Where(i)
	h, grp, blk := blocks.Set(st.h, st.group(g), st.block(b), i, id, dur)
	st.setRotVal(g, grp, b, blk)
	st.h, st.dirty = h, true
}

// ---- schedules ----

// A schedule is its slots in order, each a record that starts with the gap
// since the previous slot's end (one digit "0" when it follows it, else the
// number of digits and the gap, "z" and the start if it overlaps), then its
// body: "L" (listener), the duration (2 digits), the track (4), the artist
// (4), the time booked (6), the refund (4), "1" when its note is hidden, and
// its address and note, each after its length (1 and 2 digits). A body is reused as long as its slot keeps
// its duration and note, so moving slots together costs no encoding.

func decodeSchedule(s string) []Slot {
	out := make([]Slot, 0, len(s)/8+1)
	for c := (cursor{s: s}); c.next(); {
		b := s[c.b:c.i]
		x := Slot{Track: int(dec[b[3]]<<18 | dec[b[4]]<<12 | dec[b[5]]<<6 | dec[b[6]]), Start: c.start, Dur: c.end - c.start, body: b, bdur: c.end - c.start}
		bl := int(dec[b[22]])
		x.artist, x.At, x.Pay, x.NoteHidden = int(store.Num(b, 7, 4)), store.Num(b, 11, 6), store.Num(b, 17, 4), b[21] == '1'
		x.By, x.Note = address(b[23:23+bl]), b[25+bl:]
		out = append(out, x)
	}
	return out
}

func encodeSchedule(ss []Slot) string {
	b := make([]byte, 0, 8*len(ss)+64)
	var prevEnd int64
	for i := range ss {
		s := &ss[i]
		switch {
		case s.body == "":
			s.body = s.encodeBody()
		case s.bdur != s.Dur:
			s.body = s.body[:1] + string(store.AppendFixed(make([]byte, 0, 2), s.Dur, 2)) + s.body[3:]
		}
		s.bdur = s.Dur
		switch gap := s.Start - prevEnd; {
		case gap == 0:
			b = append(b, '0')
		case gap < 0:
			b = store.AppendFixed(append(b, 'z'), s.Start, 6)
		default:
			n := 1
			for gap>>(6*n) != 0 {
				n++
			}
			b = store.AppendFixed(append(b, store.Digits[n]), gap, n)
		}
		b = append(b, s.body...)
		prevEnd = s.Start + s.Dur
	}
	return string(b)
}

func (s *Slot) encodeBody() string {
	b := make([]byte, 0, 32+len(s.By)+len(s.Note))
	b = store.AppendFixed(store.AppendFixed(store.AppendFixed(append(b, 'L'), s.Dur, 2), int64(s.Track), 4), int64(s.artist), 4)
	b = store.AppendFixed(store.AppendFixed(b, s.At, 6), s.Pay, 4)
	if s.NoteHidden {
		b = append(b, '1')
	} else {
		b = append(b, '0')
	}
	b = append(store.AppendFixed(b, int64(len(s.By)), 1), s.By...)
	return string(append(store.AppendFixed(b, int64(len(s.Note)), 2), s.Note...))
}

// cursor walks an encoded schedule a slot at a time without decoding it:
// after next, the slot's body is s[b:i] and it plays from start to end.
type cursor struct {
	s          string
	i, b       int
	start, end int64
}

func (c *cursor) next() bool {
	s, i := c.s, c.i
	if i >= len(s) {
		return false
	}
	start := c.end
	switch ch := s[i]; ch {
	case '0':
		i++
	case 'z':
		start, i = store.Num(s, i+1, 6), i+7
	default:
		n := int(dec[s[i]])
		start, i = c.end+store.Num(s, i+1, n), i+1+n
	}
	c.b, c.start, c.end = i, start, start+(dec[s[i+1]]<<6|dec[s[i+2]])
	k := i + 23 + int(dec[s[i+22]])
	c.i = k + 2 + int(dec[s[k]]<<6|dec[s[k+1]])
	return true
}

// ---- where a track rotates: Main at id-1, New and Choice in their ring
// index, genre stations in homes ----

const idxW = 6 // a ring index entry

// ringFind returns the position of a track in the ring index, or where it goes.
func (st *station) ringFind(trackID int) (int, bool) {
	lo, hi := 0, len(st.idx)/idxW
	for lo < hi {
		mid := (lo + hi) / 2
		if int(store.Num(st.idx, idxW*mid, 4)) < trackID {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(st.idx)/idxW && int(store.Num(st.idx, idxW*lo, 4)) == trackID
}

// ringSlot is a track's slot in the ring.
func (st *station) ringSlot(trackID int) (int, bool) {
	p, ok := st.ringFind(trackID)
	if !ok {
		return 0, false
	}
	return int(store.Num(st.idx, idxW*p+4, 2)), true
}

// ringIndex files a track at a slot of the ring, at position p of the
// index (ringFind), replacing the entry there when found.
func (st *station) ringIndex(p int, found bool, trackID, slot int) {
	end := idxW * p
	if found {
		end += idxW
	}
	st.idx, st.dirty = st.idx[:idxW*p]+store.Fixed(int64(trackID), 4)+store.Fixed(int64(slot), 2)+st.idx[end:], true
}

// ringUnindex forgets a track that left the ring's slot and returns where
// it was in the index (-1: it was not there).
func (st *station) ringUnindex(trackID, slot int) int {
	if p, ok := st.ringFind(trackID); ok && int(store.Num(st.idx, idxW*p+4, 2)) == slot {
		st.idx, st.dirty = st.idx[:idxW*p]+st.idx[idxW*p+idxW:], true
		return p
	}
	return -1
}

// A homes entry is 5 digits per genre station: the station (1) and the slot (4).

func homesKey(trackID int) (string, int) {
	return store.Pad((trackID - 1) / homesChunk), (trackID - 1) % homesChunk
}

// homes returns a synced track's entry.
func (t *tx) homes(trackID int) string {
	k, i := homesKey(trackID)
	if ch := t.val(cHomes, k); ch != "" {
		return store.Field(ch, i)
	}
	return ""
}

func (t *tx) setHomes(trackID int, e string) {
	k, i := homesKey(trackID)
	t.set(cHomes, k, store.With(t.val(cHomes, k), i, e))
}

// appendHomes files the entry of the next synced track.
func (t *tx) appendHomes(trackID int, e string) {
	k, i := homesKey(trackID)
	if i == 0 {
		t.put(cHomes, k, store.Rec(e))
		return
	}
	t.set(cHomes, k, store.Append(t.val(cHomes, k), e))
}

func homeEntry(stationID, slot int) string {
	return store.Fixed(int64(stationID), 1) + store.Fixed(int64(slot), 4)
}

// homeSlot finds a station's slot in an entry.
func homeSlot(e string, stationID int) (int, bool) {
	for i := 0; i+5 <= len(e); i += 5 {
		if int(dec[e[i]]) == stationID {
			return int(store.Num(e, i+1, 4)), true
		}
	}
	return 0, false
}
