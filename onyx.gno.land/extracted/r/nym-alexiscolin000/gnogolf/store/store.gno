// Package store keeps Gnogolf's data (every record, best, board, standing,
// round in play and hole) apart from its rules, so a new version of the rules
// takes the data on instead of starting empty. It knows nothing of golf: a
// few ordered collections of string keys to string values, written only by
// the one realm it names as its writer (the rules: golf/v2 at the launch),
// read by anyone. A new writer takes over three days after its code is on
// chain and says so (the owner proposes it, it calls Ready), on its own; the
// owner can stop every write at once (Pause), start the same rules again at
// once (Resume), and renounce the role for good.
package store

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	bptree "gno.land/p/nt/bptree/v0"
)

// DELAY is how long a proposed writer waits, from its Ready, before it takes
// over: three days for anyone to read its code on gnoweb, which is on chain
// from then on and cannot change. A constant: it can never be shortened.
const DELAY = 72 * 3600 // seconds of block time

// The bounds of every call: none can be made to run, or to store, unbounded.
const (
	maxKey   = 256
	maxValue = 64 << 10
	maxPage  = 300
	maxOps   = 64
	maxName  = 32
)

var (
	self = unsafe.CurrentRealm().PkgPath()
	// writer is the rules' pkgpath, the only caller a write takes ("" paused);
	// proposed, the next one, taking over at at (block time, unix seconds; 0
	// until it calls Ready)
	writer   = strings.TrimSuffix(self, "store") + "golf/v2"
	proposed string
	at       int64
	// paused is the writer a Pause stopped, which Resume starts again ("" for none)
	paused string
	// owner may propose, cancel, pause and pass the role; "" once renounced
	owner   address
	pending address
	// the collections, by name: made at init, or by the writer (Make)
	colls = map[string]*bptree.BPTree{}
)

// the collections v2 keeps its data in, made at deploy: a first save never
// pays a whole new tree
var standard = []string{"meta", "holes", "community", "data", "slots", "aliases", "authors", "hidden", "archived", "rounds", "bests", "boards", "totals", "ranks", "wear", "fresh", "copies"}

func init() {
	owner = unsafe.OriginCaller()
	for _, n := range standard {
		colls[n] = seeded()
	}
}

// seeded is a collection whose first leaf the deployer pays, not its first
// player: its key "", which no write can make (checkKey) and no read shows,
// sorts before every other.
func seeded() *bptree.BPTree {
	t := bptree.NewBPTree32()
	t.Set("", "")
	return t
}

// --- who writes ----------------------------------------------------------

// Writer is the realm whose writes store takes now: the proposed one once its
// delay is over ("" while paused).
func Writer() string {
	if matured() {
		return proposed
	}
	return writer
}

func matured() bool { return proposed != "" && at != 0 && time.Now().Unix() >= at }

// Proposed is the writer proposed and when it takes over (unix seconds; 0
// while its code has not called Ready), or "" and 0.
func Proposed() (string, int64) {
	if matured() {
		return "", 0
	}
	return proposed, at
}

// settle makes a proposed writer whose delay is over the writer, as it is
// already for every read (Writer).
func settle() {
	if matured() {
		writer, proposed, at, paused = proposed, "", 0, ""
		chain.Emit("WriterChanged", "writer", writer)
	}
}

// Owner is the role that may propose, cancel and pause, "" once renounced.
func Owner() address { return owner }

// gate lets the writer through, and only it: the immediate caller's pkgpath,
// never the signer (an account, a MsgRun script or another realm is refused).
// A proposed writer whose delay is over becomes the writer at its first write.
func gate(cur realm) {
	w := Writer()
	if w == "" {
		panic("store: paused: no writes until the owner names new rules")
	}
	if cur.Previous().PkgPath() != w {
		panic("store: only " + w + " writes here")
	}
	settle()
}

func onlyOwner(cur realm, what string) {
	if owner == "" || cur.Previous().Address() != owner {
		panic("store: only the owner can " + what)
	}
}

// Propose names the next writer, a realm's pkgpath under gno.land/r/. Only the
// owner can; a new proposal replaces the last. Its delay starts when that
// realm, on chain, calls Ready: its code can then be read, as it will run.
func Propose(cur realm, pkgpath string) {
	onlyOwner(cur, "propose new rules")
	if !validPkgPath(pkgpath) || pkgpath == self {
		panic("store: the rules are a realm: gno.land/r/ and up to 100 of a-z, 0-9 and _-/.")
	}
	settle() // (one whose delay is over is the writer already)
	proposed, at = pkgpath, 0
	chain.Emit("WriterProposed", "writer", pkgpath)
}

// Ready is the proposed writer's own call, once it is on chain: it takes over
// DELAY later, with no transaction to send. Only that realm can, once.
func Ready(cur realm) {
	if proposed == "" || at != 0 || cur.Previous().PkgPath() != proposed {
		panic("store: only the proposed rules, once, say they are ready")
	}
	at = time.Now().Unix() + DELAY
	chain.Emit("WriterReady", "writer", proposed, "at", strconv.FormatInt(at, 10))
}

// validPkgPath is golf v1's: gno.land/r/, up to 100 of a-z, 0-9 and _-/.,
// no "", "." or ".." segment.
func validPkgPath(p string) bool {
	if len(p) > 100 || !strings.HasPrefix(p, "gno.land/r/") {
		return false
	}
	for _, seg := range strings.Split(p[len("gno.land/r/"):], "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.IndexByte("_-/.", c) >= 0) {
			return false
		}
	}
	return true
}

// Cancel drops the proposed writer before it takes over. Only the owner can.
func Cancel(cur realm) {
	onlyOwner(cur, "cancel new rules")
	if p, _ := Proposed(); p == "" {
		panic("store: no new rules proposed")
	}
	drop()
}

// Pause stops every write at once (the reads go on), and drops any proposal.
// Only the owner can: for a bug in the rules, or one feared. Resume starts the
// same rules again at once; new rules take their delay.
func Pause(cur realm) {
	onlyOwner(cur, "pause")
	settle() // (a takeover already in force is said, then stopped too)
	drop()
	if writer != "" {
		paused = writer
	}
	writer = ""
	chain.Emit("Paused")
}

// Resume starts again, at once, the rules a Pause stopped: their code was in
// force already, so nothing new runs. Only the owner can.
func Resume(cur realm) {
	onlyOwner(cur, "resume")
	settle()
	if writer != "" || paused == "" {
		panic("store: not paused")
	}
	writer, paused = paused, ""
	chain.Emit("Resumed", "writer", writer)
}

// drop forgets a proposal not in force, and says so.
func drop() {
	if proposed != "" {
		chain.Emit("WriterCancelled", "writer", proposed)
	}
	proposed, at = "", 0
}

// Transfer offers the owner's role, which the address offered takes with Accept.
func Transfer(cur realm, to address) {
	onlyOwner(cur, "pass the role")
	if !to.IsValid() {
		panic("store: not an address")
	}
	pending = to
	chain.Emit("OwnerOffered", "to", to.String())
}

// Accept takes the role offered.
func Accept(cur realm) {
	if pending == "" || cur.Previous().Address() != pending {
		panic("store: no transfer to you")
	}
	owner, pending = pending, ""
	chain.Emit("OwnerChanged", "owner", owner.String())
}

// Renounce gives the role up for good: the writer can then never change, nor
// be paused; a proposal not yet in force is dropped. Only the owner can, and
// not while paused: no rules could ever write again.
func Renounce(cur realm) {
	onlyOwner(cur, "renounce")
	settle()
	if writer == "" {
		panic("store: paused: name new rules before giving the role up, or nothing could ever be saved again")
	}
	drop()
	owner, pending = "", ""
	chain.Emit("OwnerRenounced")
}

// --- writes (the writer only) -----------------------------------------------

func coll(name string) *bptree.BPTree {
	t := colls[name]
	if t == nil {
		panic("store: no collection " + strconv.Quote(name))
	}
	return t
}

func checkKey(k string) {
	if k == "" || len(k) > maxKey {
		panic("store: a key is 1 to 256 bytes")
	}
}

// (a string is a value: what store keeps is its own, never the caller's slice)
func set(name, k, v string) {
	checkKey(k)
	if len(v) > maxValue {
		panic("store: a value is at most 64 KiB")
	}
	coll(name).Set(k, v)
}

// Set keeps value under key in a collection. The writer only.
func Set(cur realm, name, key, value string) {
	gate(cur)
	set(name, key, value)
}

// Remove drops a key from a collection, reporting whether it was there. The writer only.
func Remove(cur realm, name, key string) bool {
	gate(cur)
	checkKey(key)
	_, ok := coll(name).Remove(key)
	return ok
}

// Batch applies a save's writes in one call: ops is "set", collection, key,
// value or "del", collection, key, "" (four strings an op), at most 64 ops.
// A transaction is all or nothing: a bad op undoes the whole batch.
func Batch(cur realm, ops []string) {
	gate(cur)
	if len(ops)%4 != 0 || len(ops) > 4*maxOps {
		panic("store: a batch is up to 64 ops of four strings")
	}
	for i := 0; i < len(ops); i += 4 {
		switch ops[i] {
		case "set":
			set(ops[i+1], ops[i+2], ops[i+3])
		case "del":
			checkKey(ops[i+2])
			coll(ops[i+1]).Remove(ops[i+2])
		default:
			panic("store: an op is set or del")
		}
	}
}

// Make adds a collection, for rules that need one more. The writer only.
func Make(cur realm, name string) {
	gate(cur)
	if name == "" || len(name) > maxName || colls[name] != nil {
		panic("store: a new collection's name is 1 to 32 bytes, not taken")
	}
	colls[name] = seeded()
}

// --- reads (anyone) ----------------------------------------------------------

// Get is a key's value in a collection, and whether it is there.
func Get(name, key string) (string, bool) {
	if key == "" {
		return "", false // (the seed)
	}
	v := coll(name).Get(key)
	if v == nil {
		return "", false
	}
	return v.(string), true
}

// Has reports whether a collection holds a key.
func Has(name, key string) bool { return key != "" && coll(name).Has(key) }

// Size is how many keys a collection holds.
func Size(name string) int { return coll(name).Size() - 1 }

// Index is how many keys of a collection sort before key: its place, from 0
// (O(log n) a step of a binary search, as golf v1's boards).
func Index(name, key string) int {
	t := coll(name)
	lo, hi := 0, t.Size()
	for lo < hi {
		mid := (lo + hi) / 2
		if k, _ := t.GetByIndex(mid); k < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo > 0 {
		lo-- // (the seed, first: never counted)
	}
	return lo
}

// At is the key and value at a place in a collection's order.
func At(name string, i int) (string, string) {
	t := coll(name)
	if i < 0 || i >= t.Size()-1 {
		return "", ""
	}
	k, v := t.GetByIndex(i + 1)
	return k, v.(string)
}

// Page is up to limit keys of a collection from start (included) to end
// (excluded; "" to its end), in order, as rows one after another: each the
// key's length, ":", the key, the value's length, ":", the value (no
// separator to escape: the lengths say where each ends).
// limit is 1 to 300.
func Page(name, start, end string, limit int) string { return page(name, start, end, limit, false) }

// PageBack is Page from end (kept, as bptree's back walk) down to start.
func PageBack(name, start, end string, limit int) string { return page(name, start, end, limit, true) }

// PageAt is up to limit keys from the offset-th of a collection (from 0), as Page's rows.
func PageAt(name string, offset, limit int) string {
	if limit < 1 || limit > maxPage {
		panic("store: a page is 1 to 300 keys")
	}
	var sb strings.Builder
	t := coll(name)
	if offset < 0 {
		offset = 0
	}
	if offset >= t.Size()-1 {
		return "" // (and offset+1 cannot wrap)
	}
	t.IterateByOffset(offset+1, limit, func(k string, v any) bool { // (past the seed)
		row(&sb, k, v.(string))
		return false
	})
	return sb.String()
}

func page(name, start, end string, limit int, back bool) string {
	if limit < 1 || limit > maxPage {
		panic("store: a page is 1 to 300 keys")
	}
	var sb strings.Builder
	n := 0
	cb := func(k string, v any) bool {
		if k == "" {
			return false // (the seed)
		}
		row(&sb, k, v.(string))
		n++
		return n >= limit
	}
	if back {
		coll(name).ReverseIterate(start, end, cb)
	} else {
		coll(name).Iterate(start, end, cb)
	}
	return sb.String()
}

// row writes one key and its value into a page.
func row(sb *strings.Builder, k, v string) {
	sb.WriteString(strconv.Itoa(len(k)) + ":" + k + strconv.Itoa(len(v)) + ":" + v)
}

// Render says who writes, what is proposed and who may change it.
func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("# Gnogolf's data\n\nEvery record, best, board and hole of the game, kept apart from its rules so that new rules take them on.\n\n")
	if w := Writer(); w == "" {
		sb.WriteString("**Paused:** no saves until the owner resumes the rules or names new ones. Everything can still be read.\n\n")
	} else {
		sb.WriteString("**The rules:** [" + w + "](" + strings.TrimPrefix(w, "gno.land") + ")\n\n")
	}
	if p, t := Proposed(); p != "" && t == 0 {
		sb.WriteString("**New rules proposed:** " + p + ", not on chain yet: they take over three days after their code calls Ready, unless the owner cancels them.\n\n")
	} else if p != "" {
		sb.WriteString("**New rules proposed:** [" + p + "](" + strings.TrimPrefix(p, "gno.land") + "), taking over on " + time.Unix(t, 0).UTC().Format("2006-01-02 15:04 UTC") + " unless the owner cancels them. Read their code before then.\n\n")
	}
	if owner == "" {
		sb.WriteString("**Nobody** can change the rules any more: the owner's role was given up.\n")
	} else {
		sb.WriteString("**The owner** (" + owner.String() + ") can propose new rules, which take over three days after their code is on chain, cancel them before, or stop every save at once and start the same rules again. Nothing else: no record can be written but by the rules.\n")
	}
	return sb.String()
}
