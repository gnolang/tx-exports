package memba_notes_v1

import (
	"chain"
	"chain/runtime"
	"encoding/hex"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

func enter(cur realm, payable bool) address {
	if !cur.IsCurrent() {
		panic("notes: stale realm")
	}
	if busy {
		panic("notes: reentry")
	}
	if !payable {
		assertNoCoins()
	}
	busy = true
	return cur.Previous().Address()
}
func leave()                    { busy = false }
func idText(id [16]byte) string { return hex.EncodeToString(id[:]) }
func readID(s string) [16]byte {
	if len(s) != 32 {
		panic("notes: bad note id")
	}
	b, err := hex.DecodeString(s)
	if err != nil || hex.EncodeToString(b) != s {
		panic("notes: bad note id")
	}
	var id [16]byte
	copy(id[:], b)
	return id
}
func find(id [16]byte) *note {
	v, ok := notes.Get(idText(id))
	if !ok {
		panic("notes: note not found")
	}
	return v.(*note)
}
func live(id [16]byte) *note {
	n := find(id)
	if n.Deleted {
		panic("notes: note deleted")
	}
	return n
}
func expected(n *note, rev uint64) {
	if rev != n.Revision {
		panic("notes: stale revision")
	}
	if rev == ^uint64(0) {
		panic("notes: revision exhausted")
	}
}
func owner(n *note, who address) {
	if n.Owner != who {
		panic("notes: owner required")
	}
}
func operation(n *note, op [16]byte) {
	if op == ([16]byte{}) {
		panic("notes: empty operation id")
	}
	if n != nil && n.Last.Operation == op {
		panic("notes: operation id reused")
	}
}
func bump(n *note, who address, op [16]byte, action string) {
	bumpHistory(n, who, op, action, "")
}
func bumpHistory(n *note, who address, op [16]byte, action, historyExtra string) {
	operation(n, op)
	n.Revision++
	n.Last = receipt{op, who, runtime.ChainHeight()}
	n.LastExecutor = ""
	historyNote(n, who, op, action, historyExtra)
	chain.Emit("NoteChanged", "id", idText(n.ID), "action", action, "revision", strconv.FormatUint(n.Revision, 10), "actor", string(who), "op_id", idText(op))
}
func copied(b []byte) []byte { return append([]byte(nil), b...) }
func public(mode uint8) bool { return mode == ModePublic || mode == ModePublicOpen }
func indexKey(n *note) string {
	s := strconv.FormatUint(n.Sequence, 10)
	return strings.Repeat("0", 20-len(s)) + s + ":" + idText(n.ID)
}
func index(n *note) {
	for _, a := range append(copiedAddresses(n.Writers), n.Readers...) {
		sharedIndex.Set(string(a)+":"+indexKey(n), idText(n.ID))
	}
	ownerIndex.Set(string(n.Owner)+":"+indexKey(n), idText(n.ID))
	if public(n.Mode) && n.Listed && !n.ModeratorHidden {
		publicIndex.Set(indexKey(n), idText(n.ID))
	}
}
func unindex(n *note) {
	for _, a := range append(copiedAddresses(n.Writers), n.Readers...) {
		sharedIndex.Remove(string(a) + ":" + indexKey(n))
	}
	ownerIndex.Remove(string(n.Owner) + ":" + indexKey(n))
	publicIndex.Remove(indexKey(n))
}
func validateTitle(title []byte) {
	if len(title) == 0 || len(title) > MaxTitleBytes || !utf8.Valid(title) || utf8.RuneCount(title) > 80 {
		panic("notes: invalid title")
	}
	s := string(title)
	if strings.TrimSpace(s) != s {
		panic("notes: invalid title")
	}
	for _, r := range s {
		if r == '/' || unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			panic("notes: invalid title")
		}
	}
}
func validatePublic(title, body []byte) {
	validateTitle(title)
	if len(body) > MaxBodyBytes || !utf8.Valid(body) {
		panic("notes: invalid body")
	}
}

func copiedAddresses(a []address) []address { return append([]address(nil), a...) }
