package arena

import (
	"encoding/binary"

	"gno.land/p/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnomepit/engine"
	"gno.land/p/nt/avl/v0"
)

var (
	chunks      avl.Tree  // 4-byte chunk number → chunk string
	players     avl.Tree  // address → player string
	ladder      *avl.Node // ladderKey of every rated player → nil
	clanRecords string
	openList    string
)

func chunkKey(id int) string {
	var k [4]byte
	binary.BigEndian.PutUint32(k[:], uint32((id-1)/chunkSize))
	return string(k[:])
}

// loadMatch returns match id, or false when it does not exist or was removed.
func loadMatch(rules *engine.Ruleset, id int) (record, bool) {
	if id < 1 || id > lastID {
		return record{}, false
	}
	rec := chunkRecord(stringAt(&chunks, chunkKey(id)), (id-1)%chunkSize)
	if rec == "" {
		return record{}, false
	}
	return decodeMatch(rules, rec), true
}

func saveMatch(rules *engine.Ruleset, id int, m record) {
	putRecord(id, encodeMatch(rules, m))
}

// dropMatch removes match id; an absent id is left alone.
func dropMatch(id int) {
	if id < 1 {
		return
	}
	if chunkRecord(stringAt(&chunks, chunkKey(id)), (id-1)%chunkSize) != "" {
		putRecord(id, "")
	}
}

func putRecord(id int, rec string) {
	chunks.Set(chunkKey(id), withChunkRecord(stringAt(&chunks, chunkKey(id)), (id-1)%chunkSize, rec))
}

// stringAt returns the string under key, "" when there is none.
func stringAt(t *avl.Tree, key string) string {
	v := t.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}

func loadPlayer(a address) playerRecord {
	return decodePlayer(stringAt(&players, string(a)))
}

func savePlayer(a address, p playerRecord) {
	players.Set(string(a), encodePlayer(p))
}

// loadStanding returns a's standing, nil before their first rated match.
func loadStanding(a address) *standing {
	return decodeStanding(stringAt(&players, string(a)))
}

func saveStanding(a address, st *standing) {
	players.Set(string(a), withStanding(stringAt(&players, string(a)), st))
}

// add appends id unless the player already has it.
func (p *playerRecord) add(id int) {
	for _, have := range p.ids {
		if have == id {
			return
		}
	}
	p.ids = append(p.ids, id)
}

func (p *playerRecord) remove(id int) {
	for i, have := range p.ids {
		if have == id {
			p.ids = append(p.ids[:i:i], p.ids[i+1:]...)
			return
		}
	}
}

// newest returns up to limit ids, newest first, after skipping offset of them.
func (p playerRecord) newest(offset, limit int) []int {
	var out []int
	for i := len(p.ids) - 1 - offset; i >= 0 && len(out) < limit; i-- {
		out = append(out, p.ids[i])
	}
	return out
}

// ceiling: each change rewrites the whole open list, 8 bytes per open challenge, so its gas
// grows with the board; an avl index keyed by expiry and id if the board holds thousands.
func openAdd(id int, expires int64) {
	openList += encodeOpen([]openEntry{{id: id, expires: expires}})
}

func openRemove(id int) {
	entries := openEntries(openList)
	for i, e := range entries {
		if e.id == id {
			openList = encodeOpen(append(entries[:i:i], entries[i+1:]...))
			return
		}
	}
}

// openNewest returns up to limit unexpired ids, newest first, after skipping offset of them.
func openNewest(now int64, offset, limit int) []int {
	entries := openEntries(openList)
	var out []int
	for i := len(entries) - 1; i >= 0 && entries[i].expires >= now; i-- {
		if offset > 0 {
			offset--
			continue
		}
		if len(out) == limit {
			break
		}
		out = append(out, entries[i].id)
	}
	return out
}

// openClear removes up to max expired entries from the front and returns their ids.
func openClear(now int64, max int) []int {
	entries := openEntries(openList)
	n := 0
	var ids []int
	for n < len(entries) && n < max && entries[n].expires < now {
		ids = append(ids, entries[n].id)
		n++
	}
	openList = encodeOpen(entries[n:])
	return ids
}
