// Package data keeps GnoRadio's state apart from its rules. It knows nothing
// of music: ordered collections of string keys to string values, and a vault
// for the coins of promo budgets (vault.gno).
//
// Each collection belongs to a role, the prefix of its name ("catalog/…").
// Only that role's writer realm writes it; anyone reads. A release (new
// writers for one or more roles) takes over DELAY after every new realm said
// Ready, all at once, and no data moves. The owner proposes and cancels
// releases, pauses and resumes roles, passes the role on or renounces it, and
// can replace the guardian 2x DELAY after saying so. The guardian can only
// pause and cancel a release. This realm is never replaced: keep it small.
package data

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// DELAY is how long a ready release waits before it takes over. It is a
// constant so that it can never be shortened.
const DELAY = 72 * 3600

// Limits: every call is bounded.
const (
	maxKey      = 128
	maxValue    = 16 << 10
	maxOps      = 64
	maxPage     = 100
	maxColls    = 32 // per role
	maxCollName = 32
	maxPath     = 100
)

var roles = [4]string{"catalog", "radio", "tickets", "home"}

var (
	self     string // this realm's path
	owner    *role.Role
	guardian *role.Role
	writer   [4]string // pkgpath per role
	paused   [4]bool
	proposed [4]string // "" = role unchanged by the release
	ready    [4]bool
	at       int64 // when the release takes over; 0 until every proposed realm said Ready
	colls    = map[string]*bptree.BPTree{}
	nColls   [4]int
	past     = bptree.NewBPTree32() // address -> pkgpath of every realm that has been a writer

	frozen  int64 // seconds some role has been paused, ended pauses only
	frozeAt int64 // when the current pause of some role began, 0 if none

	nextGuardian address // the owner's replacement for the guardian, "" if none
	guardianAt   int64   // when nextGuardian takes over
)

func init() {
	self = unsafe.CurrentRealm().PkgPath()
	deployer := unsafe.OriginCaller()
	if deployer == "" && runtime.ChainID() == "dev" {
		deployer = chain.PackageAddress(self + "/dev") // gno test: a key nobody holds
	}
	start(deployer)
}

// start puts release 1 in force (gno.land/r/<ns>/gnoradio/<role>/v1), with
// the deployer as owner and guardian.
func start(deployer address) {
	owner = role.New("owner", deployer)
	guardian = role.New("guardian", deployer)
	base := strings.TrimSuffix(self, "data")
	for i, r := range roles {
		writer[i] = base + r + "/v1"
		remember(writer[i])
	}
}

// nftPath is the permanent ticket NFT realm (phase 5). It is not a writer:
// it mints and transfers only for the tickets writer, and like every
// GnoRadio realm it never takes vault payouts.
func nftPath() string { return strings.TrimSuffix(self, "data") + "tickets/nft" }

func remember(pkgpath string) { past.Set(chain.PackageAddress(pkgpath).String(), pkgpath) }

func roleIndex(r string) int {
	for i, x := range roles {
		if x == r {
			return i
		}
	}
	panic("data: no role " + strconv.Quote(r))
}

// roleOf is the role of a collection or vault account: its name's prefix.
func roleOf(name string) int {
	r, _, _ := strings.Cut(name, "/")
	return roleIndex(r)
}

func noPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("data: this call takes no coins")
	}
}

func now() int64 { return time.Now().Unix() }

// ---- who writes ----

func matured() bool { return at != 0 && now() >= at }

// settle puts a release whose delay is over in force.
func settle() {
	if !matured() {
		return
	}
	for i := range roles {
		if proposed[i] != "" {
			writer[i] = proposed[i]
			remember(writer[i])
			chain.Emit("WriterChanged", "role", roles[i], "writer", writer[i])
		}
	}
	drop()
}

// drop forgets the release not yet in force.
func drop() {
	for i := range roles {
		proposed[i], ready[i] = "", false
	}
	at = 0
}

// Writer is the realm that writes a role's collections now.
func Writer(r string) string {
	i := roleIndex(r)
	if matured() && proposed[i] != "" {
		return proposed[i]
	}
	return writer[i]
}

// gate lets only the writer of a collection's or account's role through,
// and only while that role is not paused. The writer is the immediate
// caller: accounts, MsgRun and the owner never pass.
func gate(cur realm, name string) {
	i := roleOf(name)
	settle()
	if paused[i] {
		panic("data: " + roles[i] + " is paused")
	}
	if cur.Previous().PkgPath() != writer[i] {
		panic("data: only " + writer[i] + " writes " + roles[i])
	}
}

// IsGnoRadio reports whether addr is a GnoRadio realm: this one, the ticket
// NFT realm, or any current, proposed or past writer.
func IsGnoRadio(addr address) bool {
	if role.Upper(addr) {
		addr = address(strings.ToLower(addr.String())) // the upper-case spelling is the same account
	}
	if addr == chain.PackageAddress(self) || addr == chain.PackageAddress(nftPath()) || past.Has(addr.String()) {
		return true
	}
	for i := range roles {
		if proposed[i] != "" && addr == chain.PackageAddress(proposed[i]) {
			return true
		}
	}
	return false
}

// ---- the owner and the guardian ----

func onlyOwner(cur realm) {
	owner.Must(0, cur)
	noPayment()
	settle()
}

// checkPath refuses anything but a plain realm path.
func checkPath(p string) {
	if !strings.HasPrefix(p, "gno.land/r/") || len(p) > maxPath {
		panic("data: a writer is a realm path of at most 100 characters")
	}
	for _, c := range p {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune("_-/.", c)) {
			panic("data: a realm path is a-z 0-9 _ - / .")
		}
	}
	for _, s := range strings.Split(p, "/") {
		if s == "" || s == "." || s == ".." {
			panic("data: empty, . or .. in a realm path")
		}
	}
}

// Propose adds a role's new writer to the next release. Any change restarts
// the clock. Owner only.
func Propose(cur realm, r, pkgpath string) {
	onlyOwner(cur)
	i := roleIndex(r)
	checkPath(pkgpath)
	if pkgpath == self || pkgpath == nftPath() || pkgpath == writer[i] {
		panic("data: a new writer is another realm")
	}
	proposed[i], ready[i], at = pkgpath, false, 0
	chain.Emit("WriterProposed", "role", r, "writer", pkgpath)
}

// Ready is a proposed realm's own call (each rules realm exposes it): once
// every proposed realm said it, the release takes over DELAY later.
func Ready(cur realm) {
	settle()
	p := cur.Previous().PkgPath()
	all, hit := true, false
	for i := range roles {
		if p != "" && proposed[i] == p && !ready[i] {
			ready[i], hit = true, true
		}
		all = all && (proposed[i] == "" || ready[i])
	}
	if !hit {
		panic("data: only a proposed realm says Ready, once")
	}
	if all {
		at = now() + DELAY
		chain.Emit("ReleaseReady", "at", strconv.FormatInt(at, 10))
	}
}

// Cancel drops the release not yet in force. Owner or guardian. It never
// touches a guardian replacement.
func Cancel(cur realm) {
	settleGuardian()
	if !guardian.Is(0, cur) {
		owner.Must(0, cur)
	}
	noPayment()
	settle()
	pending := false
	for i := range roles {
		pending = pending || proposed[i] != ""
	}
	if !pending {
		panic("data: no release pending")
	}
	drop()
	chain.Emit("ReleaseCancelled")
}

// Pause stops a role's writes and vault operations at once ("" every role);
// reads and VaultWithdraw go on. on=false resumes the same writer. The owner
// pauses and resumes; the guardian only pauses, and only while there is an
// owner to resume.
func Pause(cur realm, r string, on bool) {
	settleGuardian()
	if !(on && guardian.Is(0, cur) && owner.Holder() != "") {
		owner.Must(0, cur)
	}
	noPayment()
	settle()
	before := anyPaused()
	if r != "" {
		paused[roleIndex(r)] = on
	} else {
		for i := range roles {
			paused[i] = on
		}
	}
	if after := anyPaused(); !before && after {
		frozeAt = now()
	} else if before && !after {
		frozen, frozeAt = frozen+now()-frozeAt, 0
	}
	chain.Emit("Paused", "role", r, "on", strconv.FormatBool(on))
}

// Renounce gives the owner role up: writers never change again and nothing
// can be paused. Refused while a role is paused, which could then never
// write again. It drops the release not yet in force.
func Renounce(cur realm) {
	onlyOwner(cur)
	for i := range roles {
		if paused[i] {
			panic("data: resume every role first")
		}
	}
	drop()
	owner.Renounce(0, cur)
}

// Offer offers the owner role to an address (offering it to the owner
// cancels the offer); Accept takes it.
func Offer(cur realm, to address) {
	noPayment()
	owner.Offer(0, cur, to)
}

func Accept(cur realm) {
	noPayment()
	owner.Accept(0, cur)
}

// GuardianOffer and GuardianAccept pass the guardian role in two steps; the
// guardian offers it. The owner's only call on the role is GuardianReplace.
func GuardianOffer(cur realm, to address) {
	noPayment()
	settleGuardian()
	guardian.Offer(0, cur, to)
}

func GuardianAccept(cur realm) {
	noPayment()
	settleGuardian()
	guardian.Accept(0, cur)
}

// GuardianRenounce gives the guardian role up. A replacement the owner
// already announced still takes over.
func GuardianRenounce(cur realm) {
	noPayment()
	settleGuardian()
	guardian.Renounce(0, cur)
}

// GuardianReplace is the owner's way out of a lost or stolen guardian key,
// which could otherwise cancel every release and pause after every resume
// for good: to becomes the guardian 2x DELAY (six days) later. The guardian
// cannot cancel it; the owner withdraws it with to = "" or announces another
// one, which restarts the clock. The wait outlasts a release's DELAY, so a
// stolen owner key that replaces the guardian is public for six days before
// its own release can even start its 72 hours. Owner only.
func GuardianReplace(cur realm, to address) {
	onlyOwner(cur)
	settleGuardian()
	if to == "" {
		nextGuardian, guardianAt = "", 0
		chain.Emit("GuardianReplaceCancelled")
		return
	}
	if !role.Canonical(to) {
		panic("data: not an address")
	}
	nextGuardian, guardianAt = to, now()+2*DELAY
	chain.Emit("GuardianReplacing", "to", to.String(), "at", strconv.FormatInt(guardianAt, 10))
}

// settleGuardian puts a replacement whose wait is over in force: a fresh
// role, so any offer the old guardian left dies with it.
func settleGuardian() {
	if guardianAt == 0 || now() < guardianAt {
		return
	}
	from := guardian.Holder()
	guardian = role.New("guardian", nextGuardian)
	nextGuardian, guardianAt = "", 0
	chain.Emit("RoleChanged", "role", "guardian", "from", from.String(), "to", guardian.Holder().String())
}

// guardianNow is the guardian, a matured replacement included (reads do not
// write it).
func guardianNow() (holder, pending address) {
	if guardianAt != 0 && now() >= guardianAt {
		return nextGuardian, ""
	}
	return guardian.Holder(), guardian.Pending()
}

// Paused reports whether a role's writes are stopped now.
func Paused(r string) bool { return paused[roleIndex(r)] }

func anyPaused() bool {
	for _, p := range paused {
		if p {
			return true
		}
	}
	return false
}

func Owner() address { return owner.Holder() }

func Guardian() address {
	g, _ := guardianNow()
	return g
}

// Writers is the state of every role, as JSON: {"owner","pendingOwner",
// "guardian","pendingGuardian","nextGuardian","guardianAt","at","roles":
// {"catalog":{"writer","paused","proposed","ready"},…}}. at is the unix time
// a ready release takes over, guardianAt the time nextGuardian (the owner's
// GuardianReplace) does.
func Writers() string {
	var sb strings.Builder
	m, t := matured(), at
	if m {
		t = 0 // in force already
	}
	g, gp := guardianNow()
	ng, ga := nextGuardian, guardianAt
	if g == ng && ga != 0 && now() >= ga {
		ng, ga = "", 0 // in force already
	}
	sb.WriteString(`{"owner":"` + owner.Holder().String() + `","pendingOwner":"` + owner.Pending().String() +
		`","guardian":"` + g.String() + `","pendingGuardian":"` + gp.String() +
		`","nextGuardian":"` + ng.String() + `","guardianAt":` + strconv.FormatInt(ga, 10) +
		`,"at":` + strconv.FormatInt(t, 10) + `,"roles":{`)
	for i, r := range roles {
		w, p, rd := Writer(r), proposed[i], ready[i]
		if m {
			p, rd = "", false
		}
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"` + r + `":{"writer":"` + w + `","paused":` + strconv.FormatBool(paused[i]) +
			`,"proposed":"` + p + `","ready":` + strconv.FormatBool(rd) + `}`)
	}
	sb.WriteString("}}")
	return sb.String()
}

// ---- collections ----

func coll(name string) *bptree.BPTree {
	return colls[name]
}

func mustColl(name string) *bptree.BPTree {
	t := coll(name)
	if t == nil {
		panic("data: no collection " + strconv.Quote(name))
	}
	return t
}

// Make creates a collection under the caller's role (nothing if it exists):
// "<role>/<name>", name of a-z 0-9 _, at most 32 bytes in all, 32 per role.
func Make(cur realm, name string) {
	gate(cur, name)
	if coll(name) != nil {
		return
	}
	_, n, _ := strings.Cut(name, "/")
	if n == "" || len(name) > maxCollName {
		panic("data: a collection is <role>/<name>, at most 32 bytes")
	}
	for _, c := range n {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			panic("data: a collection name is a-z 0-9 _")
		}
	}
	i := roleOf(name)
	if nColls[i] >= maxColls {
		panic("data: 32 collections per role")
	}
	nColls[i]++
	t := bptree.NewBPTree32()
	t.Set("", "") // the first leaf is paid here, never by a first writer
	colls[name] = t
	chain.Emit("CollectionMade", "name", name)
}

// apply is one write of the caller's role: Set, Remove and each op of Batch.
func apply(cur realm, op, name, k, v string) bool {
	gate(cur, name)
	if k == "" || len(k) > maxKey {
		panic("data: a key is 1 to 128 bytes")
	}
	t := mustColl(name)
	switch op {
	case store.OpSet:
		if len(v) > maxValue {
			panic("data: a value is at most 16 KiB")
		}
		t.Set(k, v)
		return true
	case store.OpDel:
		_, removed := t.Remove(k)
		return removed
	}
	panic("data: an op is set or del")
}

// Set writes value at key of a collection of the caller's role.
func Set(cur realm, name, key, value string) { apply(cur, store.OpSet, name, key, value) }

// Remove deletes a key and reports whether it was there.
func Remove(cur realm, name, key string) bool { return apply(cur, store.OpDel, name, key, "") }

// Batch applies up to 64 ops of four strings (store.Ops): "set" or "del",
// collection, key, value. It reads the strings and keeps nothing else of
// the caller's slice.
func Batch(cur realm, ops []string) {
	if len(ops)%4 != 0 || len(ops) > 4*maxOps {
		panic("data: a batch is up to 64 ops of four strings")
	}
	for i := 0; i < len(ops); i += 4 {
		apply(cur, ops[i], ops[i+1], ops[i+2], ops[i+3])
	}
}

// ---- reads ----

// Get returns the value at key ("" and false when absent).
func Get(name, key string) (string, bool) {
	t := coll(name)
	if t == nil || key == "" {
		return "", false
	}
	v := t.Get(key)
	if v == nil {
		return "", false
	}
	return v.(string), true
}

func Has(name, key string) bool {
	_, ok := Get(name, key)
	return ok
}

// Size is the number of keys of a collection.
func Size(name string) int {
	if t := coll(name); t != nil {
		return t.Size() - 1
	}
	return 0
}

// Index is the number of keys before key: Index(c, b) - Index(c, a) counts
// the keys in [a, b) without a counter. O(log² n).
func Index(name, key string) int {
	t := coll(name)
	if t == nil || key == "" {
		return 0
	}
	lo, hi := 1, t.Size() // index 0 is the seed ""
	for lo < hi {
		mid := (lo + hi) / 2
		if k, _ := t.GetByIndex(mid); k < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// Page returns up to limit (1-100) rows with start <= key < end ("" no
// bound), lowest first or highest first when reverse, as store.Row strings
// (store.Rows decodes them).
func Page(name, start, end string, limit int, reverse bool) string {
	checkLimit(limit)
	t := coll(name)
	if t == nil {
		return ""
	}
	var sb strings.Builder
	n := 0
	cb := func(k string, v any) bool {
		if k == "" || reverse && k == end {
			return false // the seed, or end in reverse (ReverseIterate keeps it)
		}
		sb.WriteString(store.Row(k, v.(string)))
		n++
		return n >= limit
	}
	if reverse {
		t.ReverseIterate(start, end, cb)
	} else {
		t.Iterate(start, end, cb)
	}
	return sb.String()
}

// PageAt returns up to limit (1-100) rows from the offset-th key, counted
// from the highest when reverse.
func PageAt(name string, offset, limit int, reverse bool) string {
	checkLimit(limit)
	t := coll(name)
	if t == nil || offset < 0 || offset >= t.Size() {
		return ""
	}
	var sb strings.Builder
	cb := func(k string, v any) bool {
		if k != "" { // the seed comes last in reverse
			sb.WriteString(store.Row(k, v.(string)))
		}
		return false
	}
	if reverse {
		t.ReverseIterateByOffset(offset, limit, cb)
	} else {
		t.IterateByOffset(offset+1, limit, cb)
	}
	return sb.String()
}

func checkLimit(limit int) {
	if limit < 1 || limit > maxPage {
		panic("data: a page is 1 to 100 rows")
	}
}
