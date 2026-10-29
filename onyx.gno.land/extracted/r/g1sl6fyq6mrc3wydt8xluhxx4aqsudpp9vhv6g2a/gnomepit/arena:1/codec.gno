package arena

import (
	"encoding/binary"
	"encoding/hex"

	"gno.land/p/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnomepit/engine"
)

// Everything stored by the arena is a byte string laid out here, big-endian. This file
// is the only code that reads or writes those bytes.

const (
	chunkSize   = 64 // match ids per chunk
	addressSize = 40 // bytes in an address's text
	sealSize    = 32 // bytes in a raw sha256 seal
	lockSize    = addressSize + 4 + 4
	openSize    = 4 + 4
	standingFix = 2 + 2 + 2 + 2 + 1 // a standing's bytes before its per-clan counts
	clanSize    = 2 + 4 + 4 + 4

	planBits   = 20 // bits per round in a side's plans: 2 for the length, 6 per card
	cardBits   = 6
	maxPlanLen = 3
	maxRound   = 3
	maxPool    = 16 // cards in a clan's pool; a deck is one bit per pool card
)

// ---- Bit fields

// bitsAt returns the width bits of v starting at bit at.
func bitsAt(v uint64, at, width uint) uint64 {
	return (v >> at) & mask(width)
}

// withBits returns v with the width bits at bit at replaced by x.
func withBits(v uint64, at, width uint, x uint64) uint64 {
	if x&^mask(width) != 0 {
		panic("value does not fit")
	}
	return v&^(mask(width)<<at) | x<<at
}

func mask(width uint) uint64 {
	if width >= 64 {
		return ^uint64(0)
	}
	return 1<<width - 1
}

// ---- Plans

// planAt returns the plan made for round, or nil when it is not yet made.
func planAt(plans uint64, round int) engine.Plan {
	at := planOffset(round)
	n := int(bitsAt(plans, at, 2))
	if n == 0 {
		return nil
	}
	p := make(engine.Plan, n)
	for i := range p {
		p[i] = engine.CardID(bitsAt(plans, at+2+uint(i)*cardBits, cardBits))
	}
	return p
}

// withPlan returns plans with round's plan set to p.
func withPlan(plans uint64, round int, p engine.Plan) uint64 {
	if len(p) < 1 || len(p) > maxPlanLen {
		panic("invalid plan")
	}
	at := planOffset(round)
	v := withBits(0, 0, 2, uint64(len(p)))
	for i, id := range p {
		if id < 0 || id >= 1<<cardBits {
			panic("invalid plan")
		}
		v = withBits(v, 2+uint(i)*cardBits, cardBits, uint64(id))
	}
	return withBits(plans, at, planBits, 0) | v<<at
}

// plansMade counts the rounds from the first that have a plan.
func plansMade(plans uint64) int {
	n := 0
	for n < maxRound && bitsAt(plans, planOffset(n+1), 2) != 0 {
		n++
	}
	return n
}

func planOffset(round int) uint {
	if round < 1 || round > maxRound {
		panic("invalid plan")
	}
	return uint(round-1) * planBits
}

// ---- Decks

// deckOnPool returns deck, a set of card ids, as one bit per card of pool in id order.
func deckOnPool(pool, deck uint64) uint16 {
	if cardsIn(pool) > maxPool {
		panic("pool holds more than 16 cards")
	}
	if deck&^pool != 0 {
		panic("deck outside the pool")
	}
	var bits uint16
	k := uint(0)
	for id := uint(0); id < 64; id++ {
		if pool&(1<<id) == 0 {
			continue
		}
		if deck&(1<<id) != 0 {
			bits |= 1 << k
		}
		k++
	}
	return bits
}

// deckFromPool is the inverse of deckOnPool.
func deckFromPool(pool uint64, bits uint16) uint64 {
	if cardsIn(pool) > maxPool {
		panic("pool holds more than 16 cards")
	}
	var deck uint64
	k := uint(0)
	for id := uint(0); id < 64; id++ {
		if pool&(1<<id) == 0 {
			continue
		}
		if bits&(1<<k) != 0 {
			deck |= 1 << id
		}
		k++
	}
	if uint64(bits)>>k != 0 {
		panic("deck outside the pool")
	}
	return deck
}

func cardsIn(pool uint64) uint {
	n := uint(0)
	for ; pool != 0; pool &= pool - 1 {
		n++
	}
	return n
}

// ---- Byte reading and writing

type writer struct{ b []byte }

func (w *writer) u8(x uint64)   { w.b = append(w.b, byte(x)) }
func (w *writer) text(s string) { w.b = append(w.b, s...) }

func (w *writer) u16(x uint64) {
	var t [2]byte
	binary.BigEndian.PutUint16(t[:], uint16(x))
	w.b = append(w.b, t[:]...)
}

func (w *writer) u32(x uint64) {
	var t [4]byte
	binary.BigEndian.PutUint32(t[:], uint32(x))
	w.b = append(w.b, t[:]...)
}

func (w *writer) u64(x uint64) {
	var t [8]byte
	binary.BigEndian.PutUint64(t[:], x)
	w.b = append(w.b, t[:]...)
}

// addr writes a's 40 characters.
func (w *writer) addr(a address) {
	if len(a) != addressSize {
		panic("invalid address")
	}
	w.text(string(a))
}

// seal writes a seal, 64 hex characters, as 32 raw bytes.
func (w *writer) seal(s string) {
	raw, err := hex.DecodeString(s)
	if err != nil || len(raw) != sealSize {
		panic("invalid seal")
	}
	w.b = append(w.b, raw...)
}

func (w *writer) String() string { return string(w.b) }

type reader struct {
	s  string
	at int
}

func (r *reader) left() int { return len(r.s) - r.at }

func (r *reader) text(n int) string {
	if r.left() < n {
		panic("truncated record")
	}
	s := r.s[r.at : r.at+n]
	r.at += n
	return s
}

func (r *reader) u8() uint64    { return uint64(r.text(1)[0]) }
func (r *reader) u16() uint64   { return uint64(binary.BigEndian.Uint16([]byte(r.text(2)))) }
func (r *reader) u32() uint64   { return uint64(binary.BigEndian.Uint32([]byte(r.text(4)))) }
func (r *reader) u64() uint64   { return binary.BigEndian.Uint64([]byte(r.text(8))) }
func (r *reader) addr() address { return address(r.text(addressSize)) }

// seal reads 32 raw bytes as 64 hex characters.
func (r *reader) seal() string { return hex.EncodeToString([]byte(r.text(sealSize))) }

// ---- Match record

// record is a match as the arena works on it, decoded from its stored bytes. clans holds
// each side's index in the ruleset plus one, 0 for none; decks and plans are the engine's
// card sets and the packed plans of withPlan; hp is the HP after each round, per side;
// carried holds only the Vulnerable and Strength left after the last resolved round.
// deckSeal and seal are 64 hex characters; box is the raw bytes, up to maxBox, stored with a 2-byte length.
type record struct {
	phase, result, reason string
	clans                 [2]int
	deadline              int64
	decks                 [2]uint64
	plans                 [2]uint64
	hp                    [3][2]int
	carried               [2]engine.Vitals
	challenger, acceptor  address
	opponent              address
	deckSeal, seal, box   string
}

const (
	flagOpponent = 1 << iota
	flagDeckSeal
	flagSealBox
)

// The value of each name is its index; 0 of result and reason is none.
var (
	phaseNames  = []string{phaseOpen, phaseReveal, phasePlay, phaseEnded}
	resultNames = []string{"", "a", "b", "draw"}
	reasonNames = []string{"", "hp", "knockout", "forfeit", "resign"}
)

func nameIndex(names []string, s, what string) uint64 {
	for i, n := range names {
		if n == s {
			return uint64(i)
		}
	}
	panic("unknown " + what)
}

func nameAt(names []string, i uint64, what string) string {
	if i >= uint64(len(names)) {
		panic("unknown " + what)
	}
	return names[i]
}

func encodeMatch(rules *engine.Ruleset, m record) string {
	var flags uint64
	if m.opponent != "" {
		flags |= flagOpponent
	}
	if m.deckSeal != "" {
		flags |= flagDeckSeal
	}
	if m.seal != "" || m.box != "" {
		flags |= flagSealBox
	}

	w := &writer{}
	w.u8(nameIndex(phaseNames, m.phase, "phase") |
		nameIndex(resultNames, m.result, "result")<<3 |
		nameIndex(reasonNames, m.reason, "reason")<<5)
	w.u8(clanNibble(rules, m.clans[0])<<4 | clanNibble(rules, m.clans[1]))
	w.u8(flags)
	w.u32(uint64(m.deadline))
	for side := 0; side < 2; side++ {
		w.u16(uint64(deckOnPool(poolOf(rules, m.clans[side]), m.decks[side])))
	}
	w.u64(m.plans[0])
	w.u64(m.plans[1])
	for _, round := range m.hp {
		for _, hp := range round {
			if hp < -128 || hp > 127 {
				panic("hp does not fit a byte")
			}
			w.u8(uint64(int8(hp)))
		}
	}
	for _, v := range m.carried {
		if v.Vulnerable < 0 || v.Vulnerable > 15 || v.Strength < 0 || v.Strength > 15 {
			panic("carried state does not fit")
		}
		w.u8(uint64(v.Vulnerable)<<4 | uint64(v.Strength))
	}
	w.addr(m.challenger)
	if m.phase != phaseOpen {
		w.addr(m.acceptor)
	}
	if flags&flagOpponent != 0 {
		w.addr(m.opponent)
	}
	if flags&flagDeckSeal != 0 {
		w.seal(m.deckSeal)
	}
	if flags&flagSealBox != 0 {
		if len(m.box) > maxBox {
			panic("box too long")
		}
		w.seal(m.seal)
		w.u16(uint64(len(m.box)))
		w.text(m.box)
	}
	return w.String()
}

func decodeMatch(rules *engine.Ruleset, b string) record {
	var m record
	r := &reader{s: b}
	first := r.u8()
	m.phase = nameAt(phaseNames, first&7, "phase")
	m.result = nameAt(resultNames, first>>3&3, "result")
	m.reason = nameAt(reasonNames, first>>5, "reason")
	clans := r.u8()
	m.clans = [2]int{int(clans >> 4), int(clans & 15)}
	flags := r.u8()
	m.deadline = int64(r.u32())
	for side := 0; side < 2; side++ {
		m.decks[side] = deckFromPool(poolOf(rules, m.clans[side]), uint16(r.u16()))
	}
	m.plans[0] = r.u64()
	m.plans[1] = r.u64()
	for round := range m.hp {
		for side := range m.hp[round] {
			m.hp[round][side] = int(int8(r.u8()))
		}
	}
	for side := range m.carried {
		v := r.u8()
		m.carried[side] = engine.Vitals{Vulnerable: int(v >> 4), Strength: int(v & 15)}
	}
	m.challenger = r.addr()
	if m.phase != phaseOpen {
		m.acceptor = r.addr()
	}
	if flags&flagOpponent != 0 {
		m.opponent = r.addr()
	}
	if flags&flagDeckSeal != 0 {
		m.deckSeal = r.seal()
	}
	if flags&flagSealBox != 0 {
		m.seal = r.seal()
		m.box = r.text(int(r.u16()))
	}
	if r.left() != 0 {
		panic("trailing bytes in record")
	}
	return m
}

// clanNibble is a clan's stored form, its ruleset index plus one, checked against rules.
func clanNibble(rules *engine.Ruleset, clan int) uint64 {
	poolOf(rules, clan)
	return uint64(clan)
}

// poolOf returns the card pool of clan, 0 for no clan.
func poolOf(rules *engine.Ruleset, clan int) uint64 {
	if clan == 0 {
		return 0
	}
	if clan < 0 || clan > len(rules.Clans) {
		panic("unknown clan")
	}
	return rules.Clans[clan-1].Pool
}

// ---- Chunks

// A chunk holds, for each match id in order, a 2-byte record length and the record. A
// removed match keeps its place with length 0.

// chunkRecord returns the record in slot, or "" when it is removed or beyond the chunk.
func chunkRecord(chunk string, slot int) string {
	r := &reader{s: chunk}
	for i := 0; r.left() > 0; i++ {
		rec := r.text(int(r.u16()))
		if i == slot {
			return rec
		}
	}
	return ""
}

// withChunkRecord returns chunk with slot's record set to rec, adding empty slots up to it.
func withChunkRecord(chunk string, slot int, rec string) string {
	if slot < 0 || slot >= chunkSize {
		panic("slot outside the chunk")
	}
	if len(rec) > 0xFFFF {
		panic("record too long")
	}
	r := &reader{s: chunk}
	w := &writer{}
	for i := 0; i <= slot || r.left() > 0; i++ {
		var old string
		if r.left() > 0 {
			old = r.text(int(r.u16()))
		}
		if i == slot {
			old = rec
		}
		w.u16(uint64(len(old)))
		w.text(old)
	}
	return w.String()
}

// ---- Players

// playerRecord is what the arena keeps per player: the ids of their matches, oldest
// first, their standing, nil until their first rated match, and the session locks that
// bind a session key to one match.
type playerRecord struct {
	ids      []int
	standing *standing
	locks    []sessionLock
}

// standing is a player's rated record. lastClan is the clan number, index plus one, of
// their last rated match; perClan[i] counts their rated matches with clan number i + 1.
type standing struct {
	rating, wins, losses, draws int
	lastClan                    int
	perClan                     []int
}

type sessionLock struct {
	session address
	id      int
	expires int64
}

// A player's bytes are a 2-byte id count, the ids at 4 bytes each, a 1-byte standing
// length, 0 for none, the standing, then the locks. A standing is the rating, wins, losses
// and draws at 2 bytes each, the last clan at 1, then a 2-byte count per clan.
// ceiling: joining a match or changing a lock rewrites all of a player's ids, up to 65,535, so
// gas grows with their matches; an avl index of ids per player if some play thousands.
func decodePlayer(s string) playerRecord {
	var p playerRecord
	if s == "" {
		return p
	}
	r := &reader{s: s}
	for n := r.u16(); n > 0; n-- {
		p.ids = append(p.ids, int(r.u32()))
	}
	p.standing = readStanding(r)
	if r.left()%lockSize != 0 {
		panic("malformed player")
	}
	for r.left() > 0 {
		p.locks = append(p.locks, sessionLock{session: r.addr(), id: int(r.u32()), expires: int64(r.u32())})
	}
	return p
}

// decodeStanding reads only the standing of a player's bytes, skipping their ids, so
// its cost does not grow with the player's matches; nil when they have none.
func decodeStanding(s string) *standing {
	if s == "" {
		return nil
	}
	r := &reader{s: s}
	r.text(4 * int(r.u16()))
	return readStanding(r)
}

// withStanding returns a player's bytes s with their standing replaced by st. It copies the
// ids and locks without reading them, so its cost does not grow with the player's matches.
func withStanding(s string, st *standing) string {
	if s == "" {
		return encodePlayer(playerRecord{standing: st})
	}
	r := &reader{s: s}
	r.text(4 * int(r.u16()))
	head := r.at
	readStanding(r)
	w := &writer{}
	w.text(s[:head])
	writeStanding(w, st)
	w.text(s[r.at:])
	return w.String()
}

func readStanding(r *reader) *standing {
	n := int(r.u8())
	if n == 0 {
		return nil
	}
	if n < standingFix || (n-standingFix)%2 != 0 {
		panic("malformed player")
	}
	st := &standing{rating: int(r.u16()), wins: int(r.u16()), losses: int(r.u16()), draws: int(r.u16()), lastClan: int(r.u8())}
	for i := standingFix; i < n; i += 2 {
		st.perClan = append(st.perClan, int(r.u16()))
	}
	return st
}

func encodePlayer(p playerRecord) string {
	if len(p.ids) > 0xFFFF {
		panic("too many matches")
	}
	w := &writer{}
	w.u16(uint64(len(p.ids)))
	for _, id := range p.ids {
		w.u32(uint64(id))
	}
	writeStanding(w, p.standing)
	for _, l := range p.locks {
		w.addr(l.session)
		w.u32(uint64(l.id))
		w.u32(uint64(l.expires))
	}
	return w.String()
}

func writeStanding(w *writer, st *standing) {
	if st == nil {
		w.u8(0)
		return
	}
	w.u8(uint64(standingFix + 2*len(st.perClan)))
	w.u16(uint64(st.rating))
	w.u16(uint64(st.wins))
	w.u16(uint64(st.losses))
	w.u16(uint64(st.draws))
	w.u8(uint64(st.lastClan))
	for _, n := range st.perClan {
		w.u16(uint64(n))
	}
}

// ladderKey orders the ladder: highest rating first, then address order.
func ladderKey(rating int, player address) string {
	w := &writer{}
	w.u16(uint64(maxRating - rating))
	w.text(string(player))
	return w.String()
}

// ---- Clan records

// clanRecord is a clan's rating and its record in rated matches against other clans.
type clanRecord struct {
	rating, wins, losses, draws int
}

// The clan records are one string holding, per clan in ruleset order, the rating at 2
// bytes and the wins, losses and draws at 4 each. decodeClans returns n clans; a clan
// past the end of s has no rated match yet.
func decodeClans(s string, n int) []clanRecord {
	if len(s)%clanSize != 0 {
		panic("malformed clans")
	}
	r := &reader{s: s}
	c := make([]clanRecord, n)
	for i := range c {
		if r.left() == 0 {
			c[i] = clanRecord{rating: startRating}
			continue
		}
		c[i] = clanRecord{rating: int(r.u16()), wins: int(r.u32()), losses: int(r.u32()), draws: int(r.u32())}
	}
	return c
}

func encodeClans(c []clanRecord) string {
	w := &writer{}
	for _, x := range c {
		w.u16(uint64(x.rating))
		w.u32(uint64(x.wins))
		w.u32(uint64(x.losses))
		w.u32(uint64(x.draws))
	}
	return w.String()
}

// ---- Open challenges

// openEntry is a challenge on the board: its match id and expiry in Unix seconds.
type openEntry struct {
	id      int
	expires int64
}

func openEntries(s string) []openEntry {
	if len(s)%openSize != 0 {
		panic("malformed open list")
	}
	r := &reader{s: s}
	var entries []openEntry
	for r.left() > 0 {
		entries = append(entries, openEntry{id: int(r.u32()), expires: int64(r.u32())})
	}
	return entries
}

func encodeOpen(entries []openEntry) string {
	w := &writer{}
	for _, e := range entries {
		w.u32(uint64(e.id))
		w.u32(uint64(e.expires))
	}
	return w.String()
}
