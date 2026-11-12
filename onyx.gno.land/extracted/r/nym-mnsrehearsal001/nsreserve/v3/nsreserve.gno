package nsreserve

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/ed25519"
	"crypto/sha256"
	"sort"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/nym-mnsrehearsal001/nsdata/v3"
)

/*
RESERVATIONS: a free name's place on chain before anybody mints it.

A free name is claimed with an X sign-in and nothing else: no wallet. The
claim is a record in our worker. What the chain holds is the smallest thing
that keeps everybody else off the label: a hashed name and an expiry.
Nothing here says who holds a name, not even as a commitment, and nothing
here says which name a hash is, except to somebody who guesses the label.

	hash = sha256(domain + ":" + label)[:16]

WHY A REALM OF ITS OWN. The ledger (nsnft) and the vault (nsdata) are the
core and do not change. This is a satellite: it holds its own small store,
reads every role from the vault, and answers to three parties:

	the GRANTER, a hot key, which can only ADD reservations and EXTEND
	them, inside a daily cap it cannot raise. It deletes nothing and
	mints nothing;

	the MINT APPROVER, another key, which writes nothing at all: it signs
	vouchers, off chain, that let one wallet mint or renew one name. The
	chain checks the signature (ed25519) against the public key the admin
	named behind the timelock, inside a daily cap of its own;

	a TRUSTED LOGIC REALM (today nslogic), which spends a voucher when
	its holder mints, and carries the admin's timelocked changes.

WHAT A STOLEN KEY CAN DO. The granter: squat one day's cap of labels until
the guardian disarms it; none becomes a name. The mint approver: mint, to
wallets of its choosing, up to one day's cap of names, reserved ones
included, since a reservation commits to nobody (the owner's decision,
2026-11-12: a claim needs no wallet). That is name theft bounded by the
approver's cap, undone by the admin's timelocked RevokeFreeNames, and
stopped at once by ClearVoucherKey or Pause. Keep that cap small.

THE CLOCK STARTS AT THE REQUEST, not when a batch or a mint lands: every
entry and every voucher carries the second its claimant asked
(requestedAt), and the expiry is that plus the vault's term. A request
time is accepted only from the last three days and never from the future,
so neither key can hand out longer terms. A name minted from a reservation
keeps the reservation's expiry exactly.

A BATCH DOES NOT SHARE A FATE. An entry that cannot be written (already
reserved, a request time out of bounds, past the cap) is skipped and
counted, never a revert, and sending the same batch twice writes nothing
the second time.

HOW IT IS STORED, and why not one tree entry per name. Measured on a local
node, an avl node costs about a kilobyte of storage deposit whatever it
holds (two of them per new key), and a reservation is 20 bytes. So
reservations are packed, 20 raw bytes each and sorted, into LEAVES: strings
of up to leafMax entries. The leaves hang off a binary trie over the bits
of the hash, kept in one avl tree whose keys are the bit prefixes ("", "0",
"01", ...): a leaf that fills up splits in two on its next bit, and its old
key stays behind as a marker. One name costs its 20 bytes plus its share of
a leaf's nodes, a few bytes; a lookup walks a few prefixes and binary-
searches one leaf.
*/

const (
	hashLen  = 16
	entryLen = hashLen + 4 // hash, expiry (unix seconds, big-endian)

	// A leaf holds at most leafMax entries before it splits on its next
	// bit. The trie never goes deeper than maxDepth; a leaf there simply
	// grows. 24 bits is room for sixteen million leaves, far past any real
	// registry, and it bounds what hashes CHOSEN to share a long prefix can
	// cost: every split leaves a marker node behind, paid from the
	// granter's balance, so a stolen granter key could otherwise buy
	// dozens of nodes with one small batch.
	leafMax  = 512
	maxDepth = 24

	splitMark = "+" // the value left at a prefix that has split

	// Batch entry widths, in hex characters.
	freezeWidth = 2*hashLen + 8 // hash, requestedAt
	hashWidth   = 2 * hashLen

	// maxBatch is the most entries one call may carry. Sized from the gas
	// measurement on a local node (docs/launch-review-2026-11-12/build-contracts.md).
	maxBatch = 2000

	// A request time is accepted from this far back, and never from the
	// future: the daily batch plus two days of a relay being down.
	maxBackSecs = int64(3 * 86400)

	// "Never from the future", give or take the clocks: a block's time can
	// trail the issuer's by some seconds (seen on a local node: an entry
	// stamped 30 seconds ago was "in the future" for a chain that had been
	// idle), so a request time up to maxSkewSecs ahead is taken.
	maxSkewSecs = int64(300)

	// A reservation is renewed only inside its last renewWindow, by one
	// term, so renewals cannot be stacked years ahead (audit L-1).
	renewWindow = int64(60 * 86400)

	// A voucher is good for at most this long from now.
	maxVoucherSecs = int64(86400)

	maxDailyCap = 100000

	maxPrune = 4096 // tree keys one Prune call may walk

	keyGranter = "granter" // the vault global nslogic.SetGranter writes
)

var (
	buckets avl.Tree // bit prefix -> a leaf of packed entries, or splitMark

	total int // entries stored, expired ones included until pruned

	// The granter's daily cap: entries it may write in one UTC day. ZERO
	// until the deploy sets it, so a fresh realm freezes nothing.
	dailyCap int
	dayNo    int64
	dayUsed  int

	paused bool

	pruneCursor string

	// voucherKey is the ed25519 PUBLIC key (32 raw bytes) of the MINT
	// APPROVER. Empty: nothing can be minted or renewed free.
	voucherKey string

	// The mint approver's own daily cap, counted apart from the granter's.
	// ZERO until the admin sets it.
	voucherCap  int
	voucherDay  int64
	voucherUsed int
)

// selfPath is this realm's own package path, read once at deploy. It goes
// into every voucher, so one signed for a rehearsal chain or an older
// generation is worth nothing here.
var selfPath string

func init() { selfPath = unsafe.CurrentRealm().PkgPath() }

// -- hashing --

func sum16(s string) string {
	h := sha256.Sum256([]byte(s))
	return string(h[:hashLen])
}

func rawOf(label, domainLabel string) string { return sum16(domainLabel + ":" + label) }

// HashOf is the reservation key of label*domain, as 32 hex characters.
func HashOf(label, domainLabel string) string { return hexOf(rawOf(label, domainLabel)) }

const hexDigits = "0123456789abcdef"

func hexOf(raw string) string {
	b := make([]byte, len(raw)*2)
	for i := 0; i < len(raw); i++ {
		b[2*i] = hexDigits[raw[i]>>4]
		b[2*i+1] = hexDigits[raw[i]&15]
	}
	return string(b)
}

// unhexTab maps a byte to its hex value, 0xff for anything that is not a
// lowercase hex digit. A table and not a function: measured under gno test,
// decoding a 2,000-entry batch through a per-character function call was
// half of the whole transaction's gas.
const unhexTab = "" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\x0a\x0b\x0c\x0d\x0e\x0f\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" +
	"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"

// unhex decodes lowercase hex. Upper case is refused, so one reservation
// has exactly one spelling.
func unhex(s string) (string, bool) {
	if len(s)%2 != 0 {
		return "", false
	}
	b := make([]byte, len(s)/2)
	bad := byte(0)
	for i := 0; i < len(b); i++ {
		hi, lo := unhexTab[s[2*i]], unhexTab[s[2*i+1]]
		bad |= hi | lo
		b[i] = hi<<4 | lo
	}
	if bad > 15 {
		return "", false
	}
	return string(b), true
}

func be32(raw string) int64 {
	return int64(raw[0])<<24 | int64(raw[1])<<16 | int64(raw[2])<<8 | int64(raw[3])
}

// -- the store --

// bitAt is bit i of a raw hash, most significant first, as '0' or '1'.
func bitAt(raw string, i int) byte {
	if raw[i/8]>>(7-uint(i%8))&1 == 1 {
		return '1'
	}
	return '0'
}

// leafOf walks the trie to the leaf that holds, or would hold, a hash.
func leafOf(raw string) (key, data string) {
	k := []byte{}
	for {
		v := buckets.Get(string(k))
		if v == nil {
			return string(k), "" // only the root, before anything was written
		}
		if d := v.(string); d != splitMark {
			return string(k), d
		}
		k = append(k, bitAt(raw, len(k)))
	}
}

// putLeaf stores a leaf, splitting it in two on its next bit for as long
// as it holds more than leafMax entries.
func putLeaf(key, data string) {
	if len(data) <= leafMax*entryLen || len(key) >= maxDepth {
		buckets.Set(key, data)
		return
	}
	// Sorted by hash, and every hash here shares the prefix `key`, so the
	// entries whose next bit is 0 all come before those whose next bit is
	// 1: the split is one cut, and both halves stay sorted.
	cut := 0
	for cut < len(data) && bitAt(data[cut:cut+hashLen], len(key)) == '0' {
		cut += entryLen
	}
	buckets.Set(key, splitMark)
	putLeaf(key+"0", data[:cut])
	putLeaf(key+"1", data[cut:])
}

// find binary-searches a sorted leaf: the offset of the hash's entry, or
// of where it would go, and whether it is there.
func find(b, raw string) (int, bool) {
	lo, hi := 0, len(b)/entryLen
	for lo < hi {
		mid := (lo + hi) / 2
		h := b[mid*entryLen : mid*entryLen+hashLen]
		if h == raw {
			return mid * entryLen, true
		}
		if h < raw {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo * entryLen, false
}

func expiryAt(b string, i int) int64 { return be32(b[i+hashLen : i+entryLen]) }

func entry(raw string, expires int64) string {
	return raw + string([]byte{byte(expires >> 24), byte(expires >> 16), byte(expires >> 8), byte(expires)})
}

func removeAt(b string, i int) string { return b[:i] + b[i+entryLen:] }

// lookup reads one reservation by raw hash.
func lookup(raw string) (expires int64, ok bool) {
	_, b := leafOf(raw)
	i, ok := find(b, raw)
	if !ok {
		return 0, false
	}
	return expiryAt(b, i), true
}

func liveAt(raw string, now int64) bool {
	exp, ok := lookup(raw)
	return ok && now < exp
}

/*
work is one batch's view of the leaves it touches, so a batch of hundreds
reads and writes each leaf once instead of copying it once per entry.

A leaf is searched in the string the tree handed over (`orig`): rewriting
an entry in place never moves a hash, so offsets found there stay right.
Rewrites go to a byte copy made on first use; new entries to a list that is
sorted and merged in at the end. A hash is handled once per batch (`seen`),
which is what makes reading from `orig` sound.
*/
type leafWork struct {
	orig  string
	buf   []byte   // orig with entries rewritten in place; nil until one is
	added []string // new entries
}

type work struct {
	keys   []string
	leaves map[string]*leafWork
	seen   map[string]bool

	// The leaf the last entry landed in. A batch is handled in hash order,
	// so the next entry is nearly always in the same one, and checking a
	// few bits is far cheaper than walking the trie again: measured on a
	// local node at 50,000 names, the walk was most of a batch's gas.
	lastKey string
	last    *leafWork
}

// under reports whether a hash belongs under a leaf's bit prefix.
func under(raw, key string) bool {
	for i := 0; i < len(key); i++ {
		if bitAt(raw, i) != key[i] {
			return false
		}
	}
	return true
}

func newWork() *work {
	return &work{leaves: map[string]*leafWork{}, seen: map[string]bool{}}
}

// leaf returns the batch's copy of the leaf holding raw.
func (w *work) leaf(raw string) *leafWork {
	if w.last != nil && under(raw, w.lastKey) {
		return w.last
	}
	key, data := leafOf(raw)
	lw, ok := w.leaves[key]
	if !ok {
		lw = &leafWork{orig: data}
		w.leaves[key] = lw
		w.keys = append(w.keys, key)
	}
	w.lastKey, w.last = key, lw
	return lw
}

func (lw *leafWork) rewrite(i int, e string) {
	if lw.buf == nil {
		lw.buf = []byte(lw.orig)
	}
	copy(lw.buf[i:i+entryLen], e)
}

// merged is the leaf as it should be stored: the rewritten entries, with
// the new ones merged in by hash, in one pass.
func (lw *leafWork) merged() string {
	data := lw.orig
	if lw.buf != nil {
		data = string(lw.buf)
	}
	if len(lw.added) == 0 {
		return data
	}
	sort.Strings(lw.added)
	out := make([]byte, 0, len(data)+len(lw.added)*entryLen)
	i := 0
	for _, e := range lw.added {
		// Where the new entry goes, by binary search: the stored entries
		// before it are copied across in one piece, not walked one by one.
		j, _ := find(data, e[:hashLen])
		out = append(out, data[i:j]...)
		out = append(out, e...)
		i = j
	}
	out = append(out, data[i:]...)
	return string(out)
}

// flush writes back every leaf the batch changed.
func (w *work) flush() {
	for _, key := range w.keys {
		lw := w.leaves[key]
		if lw.buf == nil && len(lw.added) == 0 {
			continue
		}
		putLeaf(key, lw.merged())
	}
}

// -- who may call --

func assertNoSend(cur realm) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("nsreserve: this function takes no payment; do not attach coins")
	}
}

func granter() address { return address(nsdata.GetGlobal(keyGranter)) }

func assertGranter(cur realm) {
	g := granter()
	if g == "" || cur.Previous().Address() != g {
		panic("nsreserve: restricted to the granter")
	}
}

// assertLogic lets through a realm the vault trusts as logic, and nothing
// else: never a wallet, never a run script (the vault's own rule).
func assertLogic(cur realm) {
	prev := cur.Previous()
	if prev.IsUser() || prev.IsEphemeral() || !nsdata.IsTrustedLogic(prev.Address()) {
		panic("nsreserve: restricted to a trusted logic realm")
	}
}

func assertNotPaused() {
	if paused {
		panic("nsreserve: paused")
	}
}

func isWarden(a address) bool {
	return a != "" && (a == nsdata.GetAdmin() || a == nsdata.GetGuardian() || a == nsdata.GetRecovery())
}

// -- the daily cap --

func rollDay(now int64) {
	if d := now / 86400; d != dayNo {
		dayNo, dayUsed = d, 0
	}
}

func usedToday(now int64) int {
	if now/86400 != dayNo {
		return 0
	}
	return dayUsed
}

// -- batches --

func term() int64 { return nsdata.GetTermLength() }

func requestRefusal(requestedAt, now int64) string {
	if requestedAt > now+maxSkewSecs {
		return "requested in the future"
	}
	if requestedAt < now-maxBackSecs {
		return "requested more than " + strconv.FormatInt(maxBackSecs/86400, 10) + " days ago"
	}
	return ""
}

// split cuts a batch of fixed-width hex entries into raw ones. A batch
// that is not well formed is the sender's bug and refuses the whole call.
func split(batch string, hexWidth int) ([]string, string) {
	if batch == "" {
		return nil, "empty batch"
	}
	if len(batch)%hexWidth != 0 {
		return nil, "malformed batch: its length is not a multiple of " + strconv.Itoa(hexWidth)
	}
	n := len(batch) / hexWidth
	if n > maxBatch {
		return nil, "too many entries: " + strconv.Itoa(n) + " > " + strconv.Itoa(maxBatch)
	}
	raw, ok := unhex(batch)
	if !ok {
		return nil, "malformed batch: lowercase hex only"
	}
	w := hexWidth / 2
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = raw[i*w : (i+1)*w]
	}
	return out, ""
}

func mustSplit(batch string, hexWidth int) []string {
	es, r := split(batch, hexWidth)
	if r != "" {
		panic("nsreserve: " + r)
	}
	return es
}

func digest(batch string) string { return hexOf(sum16(batch)[:8]) }

func emitBatch(cur realm, name string, written, skipped int, batch string) {
	chain.Emit(name, "written", strconv.Itoa(written), "skipped", strconv.Itoa(skipped),
		"day", strconv.FormatInt(dayNo, 10), "used", strconv.Itoa(dayUsed), "cap", strconv.Itoa(dailyCap),
		"by", cur.Previous().Address().String(), "digest", digest(batch))
}

// The per-entry rules, each answering "" or why the entry is skipped, given
// what the store holds for its hash. The dry-run reads use them; the write
// paths apply the same rules inline, in the same order.

func freezeRule(e string, exp int64, found bool, now int64) string {
	if found && now < exp {
		return "already reserved"
	}
	return requestRefusal(be32(e[hashLen:]), now)
}

func renewRule(e string, exp int64, found bool, now int64) string {
	if !found || now >= exp {
		return "no live reservation"
	}
	if exp > now+renewWindow {
		return "not due: renewals open " + strconv.FormatInt(renewWindow/86400, 10) + " days before the expiry"
	}
	return ""
}

/*
FreezeNames writes one reservation per entry and returns how many it wrote.

GRANTER ONLY, once a day in the ordinary course, as many transactions as the
day's names need. An entry is hash + requestedAt, 40 hex characters, and
says nothing about who claimed it. The expiry is requestedAt plus the
vault's term.

A live reservation is never overwritten: that entry is skipped, so sending
a batch twice is harmless. An expired one is replaced in place. Entries past
the daily cap are skipped too, in hash order, not in the order sent.
*/
func FreezeNames(cur realm, batch string) int {
	assertNoSend(cur)
	assertGranter(cur)
	assertNotPaused()
	es := mustSplit(batch, freezeWidth)
	// In hash order (work.leaf). Two entries for one name then sit side by
	// side, the earlier request first, and the first one wins.
	sort.Strings(es)
	now := time.Now().Unix()
	oneTerm := term()
	rollDay(now)
	w := newWork()
	written := 0
	for _, e := range es {
		raw := e[:hashLen]
		requestedAt := be32(e[hashLen:])
		if dayUsed >= dailyCap || w.seen[raw] || requestedAt > now+maxSkewSecs || requestedAt < now-maxBackSecs {
			continue
		}
		lw := w.leaf(raw)
		i, found := find(lw.orig, raw)
		if found && now < expiryAt(lw.orig, i) {
			continue // live: never overwritten
		}
		ne := entry(raw, requestedAt+oneTerm)
		if found {
			lw.rewrite(i, ne) // an expired entry is replaced in place
		} else {
			lw.added = append(lw.added, ne)
			total++
		}
		w.seen[raw] = true
		dayUsed++
		written++
	}
	w.flush()
	emitBatch(cur, "NamesFrozen", written, len(es)-written, batch)
	return written
}

// RenewNames adds one term to live reservations inside their last
// renewWindow. Granter only; the entries are hashes, 32 hex characters
// each. Anything else is skipped.
func RenewNames(cur realm, hashes string) int {
	assertNoSend(cur)
	assertGranter(cur)
	assertNotPaused()
	hs := mustSplit(hashes, hashWidth)
	sort.Strings(hs) // in hash order (work.leaf)
	now := time.Now().Unix()
	oneTerm := term()
	rollDay(now)
	w := newWork()
	written := 0
	for _, raw := range hs {
		if dayUsed >= dailyCap || w.seen[raw] {
			continue
		}
		lw := w.leaf(raw)
		i, found := find(lw.orig, raw)
		if !found {
			continue
		}
		exp := expiryAt(lw.orig, i)
		if now >= exp || exp > now+renewWindow {
			continue // lapsed, or not due yet
		}
		lw.rewrite(i, entry(raw, exp+oneTerm))
		w.seen[raw] = true
		dayUsed++
		written++
	}
	w.flush()
	emitBatch(cur, "NamesRenewed", written, len(hs)-written, hashes)
	return written
}

/*
VOUCHERS: how a name is minted, and how a minted free name is renewed.

A reservation names nobody, so something else has to say which wallet may
have the name. That is the mint approver's voucher: the issuer signs, off
chain and for nothing, "this wallet may MINT (or RENEW) this name,
requested at this second, until this second", only after a fresh X sign-in
by the account that claimed it. The holder carries it in their own
transaction and pays for everything. Nothing is written here for a
voucher, so minting costs the project no gas and no storage.

IF THE NAME IS RESERVED, the voucher must carry the reservation's own
request time (its expiry is checked to the second) and the reservation is
spent. IF IT IS NOT, the name is being minted before the day's batch
landed, and the request time must be fresh: the last three days.

NO NONCE IS STORED, on purpose. A mint voucher names one name and one
wallet, and using it registers that name, after which it is refused for
good ("already registered"); a renew voucher sets one exact expiry, so a
second use changes nothing and is refused as "not an extension". Both die
with their validity, a day at most. A stored nonce would add a tree node
of permanent storage, paid by every holder, to prevent nothing.
*/

// Voucher kinds.
const (
	KindMint  = "mint"
	KindRenew = "renew"
)

// VoucherMessage is the exact text the mint approver signs.
func VoucherMessage(kind, label, domainLabel string, holder address, requestedAt, validUntil int64) string {
	return "mns-free-v2\n" + runtime.ChainID() + "\n" + selfPath + "\n" + kind + "\n" +
		domainLabel + "*" + label + "\n" + holder.String() + "\n" +
		strconv.FormatInt(requestedAt, 10) + "\n" + strconv.FormatInt(validUntil, 10)
}

func vouchersToday(now int64) int {
	if now/86400 != voucherDay {
		return 0
	}
	return voucherUsed
}

// VoucherRefusal is why this voucher could not be used right now, or "".
func VoucherRefusal(kind, label, domainLabel string, holder address, requestedAt, validUntil int64, sig string) string {
	now := time.Now().Unix()
	if paused {
		return "paused"
	}
	if kind != KindMint && kind != KindRenew {
		return "a voucher is for mint or renew"
	}
	if voucherKey == "" {
		return "free minting is off: no mint approver is set"
	}
	if now > validUntil {
		return "this voucher has expired; ask for a new one"
	}
	if validUntil > now+maxVoucherSecs {
		return "a voucher is valid for at most " + strconv.FormatInt(maxVoucherSecs/3600, 10) + " hours"
	}
	if requestedAt > now+maxSkewSecs {
		return "voucher requested in the future"
	}
	// A reserved name is minted on the reservation's own clock, whatever
	// its age; anything else needs a fresh request time.
	reservedExp, reserved := int64(0), false
	if kind == KindMint {
		if exp, ok := lookup(rawOf(label, domainLabel)); ok && now < exp {
			reservedExp, reserved = exp, true
		}
	}
	if reserved {
		if requestedAt+term() != reservedExp {
			return "this voucher does not carry the reservation's request time"
		}
	} else if r := requestRefusal(requestedAt, now); r != "" {
		return "voucher " + r
	}
	if vouchersToday(now) >= voucherCap {
		return "today's free mints are all used; try tomorrow"
	}
	rawSig, ok := unhex(sig)
	if !ok || len(rawSig) != 64 {
		return "a voucher signature is 128 lowercase hex characters"
	}
	msg := VoucherMessage(kind, label, domainLabel, holder, requestedAt, validUntil)
	if !ed25519.Verify([]byte(voucherKey), []byte(msg), []byte(rawSig)) {
		return "this voucher was not signed for this wallet, this name and this use"
	}
	return ""
}

/*
ConsumeVoucher checks a voucher for `holder`, counts it against the mint
approver's daily cap, spends the name's reservation if there is one, and
returns the expiry the voucher stands for: the request time plus the
vault's term. TRUSTED LOGIC ONLY: the logic realm passes the wallet that
called it, so a voucher works only from the wallet it names.
*/
func ConsumeVoucher(cur realm, kind, label, domainLabel string, holder address, requestedAt, validUntil int64, sig string) int64 {
	assertLogic(cur)
	if r := VoucherRefusal(kind, label, domainLabel, holder, requestedAt, validUntil, sig); r != "" {
		panic("nsreserve: " + r)
	}
	now := time.Now().Unix()
	if d := now / 86400; d != voucherDay {
		voucherDay, voucherUsed = d, 0
	}
	voucherUsed++
	exp := requestedAt + term()
	spent := "false"
	if kind == KindMint {
		raw := rawOf(label, domainLabel)
		k, b := leafOf(raw)
		// Live and matching was checked above; an expired leftover goes too.
		if i, found := find(b, raw); found {
			buckets.Set(k, removeAt(b, i))
			total--
			spent = "true"
		}
	}
	chain.Emit("VoucherConsumed", "kind", kind, "hash", HashOf(label, domainLabel), "holder", holder.String(),
		"expires", strconv.FormatInt(exp, 10), "reservation", spent,
		"used", strconv.Itoa(voucherUsed), "cap", strconv.Itoa(voucherCap))
	return exp
}

// SetVoucherDailyCap sets how many vouchers a day may be used. Trusted
// logic only; nslogic.SetVoucherDailyCap timelocks every raise.
func SetVoucherDailyCap(cur realm, n int) {
	assertLogic(cur)
	if n < 0 || n > maxDailyCap {
		panic("nsreserve: a daily cap is 0.." + strconv.Itoa(maxDailyCap))
	}
	voucherCap = n
	chain.Emit("VoucherCapSet", "cap", strconv.Itoa(n), "by", cur.Previous().Address().String())
}

// VoucherToday is the mint approver's day: the UTC day number, how many
// vouchers were used and the cap.
func VoucherToday() (day int64, used int, cap int) {
	now := time.Now().Unix()
	return now / 86400, vouchersToday(now), voucherCap
}

// SetVoucherKey names the mint approver: an ed25519 public key, 64
// lowercase hex characters. Trusted logic only; nslogic timelocks it.
func SetVoucherKey(cur realm, hexKey string) {
	assertLogic(cur)
	raw, ok := unhex(hexKey)
	if !ok || len(raw) != 32 {
		panic("nsreserve: a voucher key is an ed25519 public key, 64 lowercase hex characters")
	}
	voucherKey = raw
	chain.Emit("VoucherKeySet", "key", hexKey, "by", cur.Previous().Address().String())
}

// ClearVoucherKey turns free minting off at once. Admin, guardian or
// recovery, as a direct wallet call: the first thing to reach for if the
// issuer is in doubt.
func ClearVoucherKey(cur realm) {
	a := cur.Previous().Address()
	if !isWarden(a) {
		panic("nsreserve: restricted to the admin, the guardian or recovery")
	}
	voucherKey = ""
	chain.Emit("VoucherKeyCleared", "by", a.String())
}

func VoucherKey() string { return hexOf(voucherKey) }

// -- the admin's side, through the logic realm and its timelock --

// Clear deletes the named reservations, live or expired. A hash that is
// not stored is skipped. Trusted logic only (nslogic.ClearReservations).
func Clear(cur realm, hashes string) int {
	assertLogic(cur)
	hs := mustSplit(hashes, hashWidth)
	removed := 0
	for _, raw := range hs {
		k, b := leafOf(raw)
		if i, found := find(b, raw); found {
			buckets.Set(k, removeAt(b, i))
			removed++
		}
	}
	total -= removed
	chain.Emit("ReservationsCleared", "count", strconv.Itoa(removed), "digest", digest(hashes),
		"by", cur.Previous().Address().String())
	return removed
}

// SetDailyCap sets how many entries the granter may write in one UTC day.
// Trusted logic only; nslogic.SetReserveDailyCap timelocks every raise.
func SetDailyCap(cur realm, n int) {
	assertLogic(cur)
	if n < 0 || n > maxDailyCap {
		panic("nsreserve: a daily cap is 0.." + strconv.Itoa(maxDailyCap))
	}
	dailyCap = n
	chain.Emit("DailyCapSet", "cap", strconv.Itoa(n), "by", cur.Previous().Address().String())
}

// -- incident switches --

// Pause stops the granter's writes and every voucher, so nothing is
// frozen and nothing is minted or renewed free. Admin, guardian or
// recovery, as a direct wallet call. Reads, Clear and Prune keep working.
func Pause(cur realm) {
	a := cur.Previous().Address()
	if !isWarden(a) {
		panic("nsreserve: restricted to the admin, the guardian or recovery")
	}
	paused = true
	chain.Emit("ReservePaused", "by", a.String())
}

// Unpause lifts the pause. Recovery only, like the vault's own; the admin
// goes through nslogic.UnpauseReservations and the timelock.
func Unpause(cur realm) {
	a := cur.Previous().Address()
	if a == "" || a != nsdata.GetRecovery() {
		panic("nsreserve: restricted to recovery")
	}
	paused = false
	chain.Emit("ReserveUnpaused", "by", a.String())
}

// UnpauseByLogic is the admin's timelocked door to the same switch.
func UnpauseByLogic(cur realm) {
	assertLogic(cur)
	paused = false
	chain.Emit("ReserveUnpaused", "by", cur.Previous().Address().String())
}

/*
Prune deletes expired reservations from up to maxLeaves tree keys, starting
where the last call stopped and wrapping at the end.

GRANTER OR ADMIN, not everybody: deleting an entry refunds its storage
deposit to whoever signs, and that deposit was ours.
*/
func Prune(cur realm, maxLeaves int) int {
	assertNoSend(cur)
	a := cur.Previous().Address()
	if a == "" || (a != granter() && a != nsdata.GetAdmin()) {
		panic("nsreserve: restricted to the granter or the admin")
	}
	if maxLeaves < 1 || maxLeaves > maxPrune {
		panic("nsreserve: maxLeaves is 1.." + strconv.Itoa(maxPrune))
	}
	now := time.Now().Unix()
	keys := make([]string, 0, maxLeaves)
	buckets.Iterate(pruneCursor, "", func(k string, _ any) bool {
		keys = append(keys, k)
		return len(keys) >= maxLeaves
	})
	removed := 0
	for _, k := range keys {
		b := buckets.Get(k).(string)
		if b == splitMark {
			continue
		}
		kept := make([]byte, 0, len(b))
		for i := 0; i+entryLen <= len(b); i += entryLen {
			if now < expiryAt(b, i) {
				kept = append(kept, b[i:i+entryLen]...)
			} else {
				removed++
			}
		}
		if len(kept) != len(b) {
			buckets.Set(k, string(kept))
		}
	}
	if len(keys) < maxLeaves {
		pruneCursor = "" // reached the end: the next call starts over
	} else {
		pruneCursor = keys[len(keys)-1] + "~" // just past the last key read
	}
	total -= removed
	chain.Emit("ReservationsPruned", "removed", strconv.Itoa(removed), "cursor", pruneCursor, "by", a.String())
	return removed
}

// -- reads --

func rawHash(hash string) string {
	raw, ok := unhex(hash)
	if !ok || len(raw) != hashLen {
		panic("nsreserve: a hash is 32 lowercase hex characters")
	}
	return raw
}

// IsReserved reports whether an unexpired reservation holds this hash.
func IsReserved(hash string) bool { return liveAt(rawHash(hash), time.Now().Unix()) }

// Reserved is IsReserved for a name written out.
func Reserved(label, domainLabel string) bool {
	return liveAt(rawOf(label, domainLabel), time.Now().Unix())
}

// ReservationOf reports the stored entry for a hash, expired ones included
// until they are pruned.
func ReservationOf(hash string) (expires int64, exists bool) { return lookup(rawHash(hash)) }

func Count() int { return total }

func Today() (day int64, used int, cap int) {
	now := time.Now().Unix()
	return now / 86400, usedToday(now), dailyCap
}

func DailyCap() int        { return dailyCap }
func VoucherCap() int      { return voucherCap }
func IsPaused() bool       { return paused }
func MaxBatch() int        { return maxBatch }
func MaxBackDays() int     { return int(maxBackSecs / 86400) }
func RenewWindowDays() int { return int(renewWindow / 86400) }

// checkBatch is the dry run behind CheckFreeze and CheckRenew: "" when
// every entry would be written, else one line per problem, "<index>
// <reason>" for an entry that would be skipped (0-based, in the order
// sent) or "* <reason>" for a refusal of the whole call.
//
// It walks the batch the way the write does, in hash order with the leaf
// reused, so it says exactly which entries the cap or a repeat would skip,
// and so a 2,000-entry dry run fits a query's gas on a large store.
func checkBatch(batch string, hexWidth int, rule func(e string, exp int64, found bool, now int64) string) string {
	now := time.Now().Unix()
	out := ""
	if paused {
		out += "* paused\n"
	}
	if granter() == "" {
		out += "* no granter is named\n"
	}
	es, r := split(batch, hexWidth)
	if r != "" {
		return out + "* " + r + "\n"
	}
	order := make([]int, len(es))
	for i := range order {
		order[i] = i
	}
	sort.Sort(byEntry{es, order})
	room := dailyCap - usedToday(now)
	w := newWork()
	why := make([]string, len(es))
	for _, i := range order {
		e := es[i]
		raw := e[:hashLen]
		lw := w.leaf(raw)
		pos, found := find(lw.orig, raw)
		exp := int64(0)
		if found {
			exp = expiryAt(lw.orig, pos)
		}
		// The write's own order of tests: the cap, a repeat, then the rule.
		switch {
		case room <= 0:
			why[i] = "past the daily cap"
		case w.seen[raw]:
			why[i] = "twice in this batch"
		default:
			why[i] = rule(e, exp, found, now)
		}
		if why[i] == "" {
			w.seen[raw] = true
			room--
		}
	}
	for i, r := range why {
		if r != "" {
			out += strconv.Itoa(i) + " " + r + "\n"
		}
	}
	return out
}

// byEntry sorts positions in a batch by the entries they point at.
type byEntry struct {
	es    []string
	order []int
}

func (b byEntry) Len() int           { return len(b.order) }
func (b byEntry) Less(i, j int) bool { return b.es[b.order[i]] < b.es[b.order[j]] }
func (b byEntry) Swap(i, j int)      { b.order[i], b.order[j] = b.order[j], b.order[i] }

func CheckFreeze(batch string) string { return checkBatch(batch, freezeWidth, freezeRule) }

func CheckRenew(hashes string) string { return checkBatch(hashes, hashWidth, renewRule) }

func Render(path string) string {
	_, used, c := Today()
	_, vused, vc := VoucherToday()
	s := "# Reservations\n\n"
	s += "Free names held for their claimants until they mint. Hashed: nothing here names a holder.\n\n"
	s += "- stored: " + strconv.Itoa(total) + "\n"
	s += "- reserved today: " + strconv.Itoa(used) + " of " + strconv.Itoa(c) + "\n"
	s += "- minted or renewed free today: " + strconv.Itoa(vused) + " of " + strconv.Itoa(vc) + "\n"
	if voucherKey == "" {
		s += "- free minting: off (no mint approver)\n"
	}
	if paused {
		s += "- PAUSED\n"
	}
	return s
}
