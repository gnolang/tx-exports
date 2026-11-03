// Package standings keeps Gnomepit's ratings, records, ladder and clan ratings, whatever
// arena version played the match. Only realms on its owner's writer list report results.
package standings

import (
	"chain/runtime"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
)

const (
	maxWriters  = 255 // a writer number fills one byte of a result entry
	maxClanName = 32
	maxPkgPath  = 256
)

var (
	owner       *ownable.Ownable
	writerPaths []string // every path ever a writer; its index plus one is its writer number
	writers     avl.Tree // current writer path → its writer number

	players avl.Tree     // address → standing bytes
	ladder  *avl.Node    // ladderKey of every rated player → nil
	clans   []clanRecord // in first-seen order; a clan's index plus one is its clan number
	results avl.Tree     // resultChunkKey → that chunk's result entries, oldest first
)

func init(cur realm) {
	owner = ownable.NewWithAddress(cur.Previous().Address())
	addWriter("gno.land/r/nym-gfanton001/gnomepit/arena/v0")
}

// Record rates a match the calling arena reports as ended, and logs it. result is "a" when
// the challenger won, "b" when the acceptor did, and "draw". It aborts unless the caller is
// a realm on the writer list, and on a report no correct arena sends: the same player on
// both sides, another result, or a clan name that is empty or over 32 bytes.
func Record(cur realm, challenger, acceptor address, challengerClan, acceptorClan, result string) {
	caller := cur.Previous()
	if !caller.IsCode() || !IsWriter(caller.PkgPath()) {
		panic("not a writer")
	}
	if challenger == acceptor {
		panic("same player")
	}
	score := scoreOf(result)
	if !validClan(challengerClan) || !validClan(acceptorClan) {
		panic("bad clan name")
	}
	ca, cb := clanNumber(challengerClan), clanNumber(acceptorClan)
	rate(challenger, acceptor, ca, cb, score)
	appendResult(resultEntry{writer: writers.Get(caller.PkgPath()).(int), challenger: challenger, acceptor: acceptor, clans: [2]int{ca, cb}, result: result[0], time: time.Now().Unix()})
}

// AddWriter lets the realm at pkgpath, a versioned path under gno.land/r/, report results.
// A path that was a writer before gets its old writer number back. Owner only.
func AddWriter(cur realm, pkgpath string) {
	refuseSession()
	owner.AssertOwnedBy(cur.Previous().Address())
	if !isVersionedRealm(pkgpath) {
		panic("bad writer path")
	}
	if IsWriter(pkgpath) {
		panic("already a writer")
	}
	addWriter(pkgpath)
}

// RemoveWriter stops the realm at pkgpath from reporting results. Owner only.
func RemoveWriter(cur realm, pkgpath string) {
	refuseSession()
	owner.AssertOwnedBy(cur.Previous().Address())
	if _, removed := writers.Remove(pkgpath); !removed {
		panic("not a writer")
	}
}

// TransferOwnership makes newOwner the owner. Owner only.
func TransferOwnership(cur realm, newOwner address) {
	refuseSession()
	if err := owner.TransferOwnership(0, cur, newOwner); err != nil {
		panic(err.Error())
	}
}

// refuseSession refuses a call signed with a session key, which its master may have handed
// to a page or a script: the writer list answers only to the owner's own key.
func refuseSession() {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("sign with the owner's own key, not a session key")
	}
}

// IsWriter reports whether the realm at pkgpath may report results.
func IsWriter(pkgpath string) bool {
	return writers.Has(pkgpath)
}

// Writers lists the realms that may report results, in writer-number order.
func Writers() []string {
	var list []string
	for _, p := range writerPaths {
		if writers.Has(p) {
			list = append(list, p)
		}
	}
	return list
}

// Owner is the address that manages the writer list.
func Owner() address {
	return owner.Owner()
}

func addWriter(pkgpath string) {
	n := 0
	for i, p := range writerPaths {
		if p == pkgpath {
			n = i + 1
			break
		}
	}
	if n == 0 {
		if len(writerPaths) == maxWriters {
			panic("too many writers")
		}
		writerPaths = append(writerPaths, pkgpath)
		n = len(writerPaths)
	}
	writers.Set(pkgpath, n)
}

// isVersionedRealm reports whether pkgpath is under gno.land/r/, at most maxPkgPath bytes of
// lowercase letters, digits and "/._-", and ends in a version element: "v" and one or more
// digits. A sub-realm path, with "#", is refused.
func isVersionedRealm(pkgpath string) bool {
	if len(pkgpath) > maxPkgPath || !strings.HasPrefix(pkgpath, "gno.land/r/") {
		return false
	}
	for _, c := range pkgpath {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune("/._-", c)) {
			return false
		}
	}
	v := pkgpath[strings.LastIndex(pkgpath, "/")+1:]
	if len(v) < 2 || v[0] != 'v' {
		return false
	}
	for _, c := range v[1:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func validClan(name string) bool {
	return len(name) >= 1 && len(name) <= maxClanName
}

func appendResult(e resultEntry) {
	key := resultChunkKey(resultCount() + 1)
	results.Set(key, stringAt(&results, key)+encodeResult(e))
}

// resultAt is logged result seq, 1 first.
func resultAt(seq int) resultEntry {
	at := (seq - 1) % resultsPerChunk * resultSize
	return decodeResult(stringAt(&results, resultChunkKey(seq))[at : at+resultSize])
}

// resultCount counts the logged results: every chunk but the last is full.
func resultCount() int {
	n := results.Size()
	if n == 0 {
		return 0
	}
	_, last := results.GetByIndex(n - 1)
	return (n-1)*resultsPerChunk + len(last.(string))/resultSize
}

// stringAt is t's string at key, "" when t has none.
func stringAt(t *avl.Tree, key string) string {
	v := t.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}
