// Package assets is Sinopia's immutable asset store for uploaded
// collections (docs/uploaded-collections.md §4–§6, §0a). An artist creates a
// store, declares artworks (on-chain bytes or IPFS CIDs, each with its
// sha256, editions, a creator-assigned tier and trait values), uploads the
// on-chain bytes in chunks, and seals it. A sealed store never changes: the
// upload engine (r/…/engines/upload) binds one sealed store to one Draft
// collection and reads its art from here.
//
// Guarantees (design §14):
//   - only the store's owner writes, and only from a wallet (direct
//     MsgCall, IsUserCall); nothing here accepts or holds coins;
//   - a store is Draft until Seal, which is irreversible: records, titles,
//     dictionaries and bytes are immutable afterwards;
//   - an "on-chain" artwork is complete only when every byte is stored,
//     its sha256 equals the declared one and media.CheckImage passed
//     (magic + dimensions; SVG through safe.AssertSVG, 16 KiB cap);
//   - an "ipfs" artwork always says ipfs; a raw CID's digest is checked
//     against the declared sha256 on chain;
//   - every user string passed safe.AssertText; JSON goes through
//     safe.JSONWriter.
//
// Storage is paid by the owner who writes it, and only the owner can free
// Draft data (Truncate), so refunds go back to the payer (T8).
package assets

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
)

// Limits (design §4 as amended by §0a / D4, and by the UP-M1 review fix:
// every read of the largest store these limits allow must stay far below
// the 3B query gas cap; worst cases are locked by zz_worst_gas_test.gno in
// r/reader).
const (
	MaxArtworks          = 10_000 // = core MaxSupplyCap
	MaxSlots             = 10_000 // Bind requires slots == maxSupply
	MaxEditions          = 10_000
	MaxTraitTypes        = 8   // core-path manifest slots "Trait 1".."Trait 8" (was 16)
	MaxTiers             = 8
	MaxDictValues        = 100 // distinct values per trait type (was 255)
	MaxStoreValues       = 255 // distinct values over all trait types of a store (new; u8 id + 1 in a record)
	MaxNameLen           = 20  // trait type and tier names
	MaxValueLen          = 32  // trait values (was 40)
	MaxTitleLen          = 64  // artwork titles (= engine.MaxTraitLen)
	MaxLabelLen          = 64
	MaxStoreOnchainBytes = 4 << 20 // ~430 GNOT of deposit at 100 ugnot/B
	MaxChunk             = 262_144 // per AppendBytes call; a tx carries ~540 KB raw (WP0)
	SegmentBytes         = 32_768  // byte-log value size (~6% key overhead, measured)
	MaxBatch             = 100     // records per AddArtworks
	MaxPage              = 20      // Artworks page (was 50)
)

const zero32 = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"

// reserved trait type names: the adapter adds these itself (case-insensitive).
var reservedTraitTypes = []string{"tier", "edition", "storage", "status", "artwork"}

type store struct {
	id            int64
	owner         address
	label         string
	sealed        bool
	createdHeight int64
	sealedHeight  int64
	traitTypes    []string // order = slot order ("Trait k")
	tiers         []string // ordered low -> high
	n             int64    // artworks
	slots         int64    // sum of editions
	onchainN      int64
	ipfsN         int64
	onchainBytes  int64 // declared on-chain bytes (sum of chain sizes)
	logLen        int64 // bytes received in the byte log
	buckets       avl.Tree // safe.PadInt(idx/bucketSize, 3) -> *bucket
	log           avl.Tree // safe.PadInt(segment, 3) -> string (<= SegmentBytes)
	shas          *shaIndex
	// Set composition and names for reads that never loop over artworks and
	// never escape at read time (review UP-M1). Three slice objects per store.
	names     []string    // JSON of the trait types, then of the tiers (escaped once, at NewStore)
	dict      []dictEntry // every distinct trait value, in first-use order; a record stores id + 1
	cnt       []int64     // counters: [0..t] tier artworks, [t+1..2t+1] tier slots (index 0 = untiered),
	                      // then per dict entry i: [base+2i] artworks, [base+2i+1] slots (base = 2t+2)
	perType   [MaxTraitTypes]int
	chainIdx  string // indexes of the on-chain artworks, u32 big-endian each, in order
	chainDone int64  // how many of them are complete (bytes arrive in artwork order)
}

// dictEntry is one distinct trait value of a store: its trait type, the
// value and its JSON (escaped once, when first used).
type dictEntry struct {
	k  int
	v  string
	js string
}

func (s *store) cntBase() int { return 2*len(s.tiers) + 2 }

// count counts one record in (sign +1) or out (sign -1).
func (s *store) count(r *record, sign int64) {
	ed := r.editions * sign
	t := len(s.tiers)
	s.cnt[r.tier] += sign
	s.cnt[t+1+r.tier] += ed
	base := s.cntBase()
	for k := range s.traitTypes {
		if id := r.traits[k]; id > 0 {
			s.cnt[base+2*(id-1)] += sign
			s.cnt[base+2*(id-1)+1] += ed
		}
	}
}

// shaIndex is the sorted list of every artwork's raw sha256 (32 B each),
// one object per store: duplicate detection without one avl key (~2 KB)
// per artwork.
type shaIndex struct {
	s string
}

var (
	stores     avl.Tree // safe.PadInt(id, 10) -> *store
	storeCount int64
)

func storeKey(id int64) string { return safe.PadInt(id, 10) }

func bucketKey(b int64) string { return safe.PadInt(b, 3) }

func mustStore(storeID string) *store {
	v := stores.Get(storeKey(safe.ParseID("store", storeID)))
	if v == nil {
		panic("unknown store " + strconv.Quote(storeID))
	}
	return v.(*store)
}

func (s *store) idStr() string { return strconv.FormatInt(s.id, 10) }

// assertWallet: every write comes straight from a wallet's MsgCall and
// carries no coins.
func assertWallet(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("asset stores are written by their owner's wallet only (direct call)")
	}
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func ownedDraft(cur realm, storeID string) *store {
	assertWallet(cur)
	s := mustStore(storeID)
	if cur.Previous().Address() != s.owner {
		panic("only the store owner " + s.owner.String() + " can change store " + storeID)
	}
	if s.sealed {
		panic("store " + storeID + " is sealed")
	}
	return s
}

// --- writes ------------------------------------------------------------------

// NewStore creates an empty Draft store owned by the calling wallet.
// traitTypes and tiers are '|'-separated name lists ("" = none): at most 16
// trait types and 8 tiers (tiers ordered low -> high), names 1..20 bytes,
// no ':' and no leading/trailing space, unique ignoring case; "Tier",
// "Edition", "Storage", "Status" and "Artwork" are reserved trait types.
// Returns the store id. Event StoreCreated{store, owner}.
func NewStore(cur realm, label, traitTypes, tiers string) string {
	assertWallet(cur)
	safe.AssertText("label", label, MaxLabelLen)
	tt := parseNames("traitTypes", traitTypes, MaxTraitTypes, true)
	ts := parseNames("tiers", tiers, MaxTiers, false)
	storeCount++
	s := &store{
		id:            storeCount,
		owner:         cur.Previous().Address(),
		label:         label,
		createdHeight: runtime.ChainHeight(),
		traitTypes:    tt,
		tiers:         ts,
		shas:          &shaIndex{},
		names:         append(jsonAll(tt), jsonAll(ts)...),
		cnt:           make([]int64, 2*len(ts)+2),
	}
	stores.Set(storeKey(s.id), s)
	chain.Emit("StoreCreated", "store", s.idStr(), "owner", s.owner.String())
	return s.idStr()
}

func jsonAll(xs []string) []string {
	out := make([]string, len(xs))
	for i, x := range xs {
		out[i] = jsonStr(x)
	}
	return out
}

// jsonStr is safe.JSONString (same bytes: '"' '\\' \n \r \t, '<' '>' '&',
// U+2028/9 and other controls escaped) without its per-character hex
// formatting, which made '<'-heavy text cost ~10x more (UP-M1).
func jsonStr(x string) string {
	plain := true
	for i := 0; i < len(x); i++ {
		c := x[i]
		if c < 0x20 || c == '"' || c == '\\' || c == '<' || c == '>' || c == '&' || c == 0x7f || c == 0xe2 {
			plain = false
			break
		}
	}
	if plain {
		return `"` + x + `"`
	}
	const hexd = "0123456789abcdef"
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range x {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '<':
			b.WriteString(`\u003c`)
		case '>':
			b.WriteString(`\u003e`)
		case '&':
			b.WriteString(`\u0026`)
		case 0x2028:
			b.WriteString(`\u2028`)
		case 0x2029:
			b.WriteString(`\u2029`)
		default:
			if r < 0x20 || r == 0x7f {
				b.WriteString(`\u00`)
				b.WriteByte(hexd[(r>>4)&0xf])
				b.WriteByte(hexd[r&0xf])
				continue
			}
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func parseNames(field, list string, max int, traits bool) []string {
	if list == "" {
		return []string{}
	}
	parts := strings.Split(list, "|")
	if len(parts) > max {
		panic(field + ": at most " + strconv.Itoa(max))
	}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		safe.AssertNonEmptyText(field, p, MaxNameLen)
		if strings.Contains(p, ":") || strings.TrimSpace(p) != p {
			panic(field + ": " + strconv.Quote(p) + " may not contain ':' or leading/trailing spaces")
		}
		low := strings.ToLower(p)
		if traits {
			for _, r := range reservedTraitTypes {
				if low == r {
					panic(field + ": " + strconv.Quote(p) + " is reserved")
				}
			}
		}
		for _, prev := range out {
			if strings.ToLower(prev) == low {
				panic(field + ": duplicate " + strconv.Quote(p))
			}
		}
		out = append(out, p)
	}
	return out
}

// AddArtworks declares up to MaxBatch artworks, one per '\n'-separated line:
//
//	kind|mime|size|sha256|cid|editions|tier|title|v1|…|vN
//
// with exactly one value per trait type of the store (N = len(traitTypes)):
//   - kind "chain" | "ipfs"; mime "svg" | "png" | "webp" | "jpeg";
//   - size: decimal bytes, chain svg <= 16,384, chain raster <= 262,144,
//     ipfs raw <= 1 MiB, ipfs dag-pb <= 50 MiB; the store's on-chain total
//     stays <= 4 MiB;
//   - sha256: 64 lower-case hex of the file bytes, unique in the store
//     (use editions for copies);
//   - cid: "" for chain; for ipfs a CIDv1 (media.ParseCIDv1): raw codec ⇒
//     its digest must equal sha256 (verified binding), dag-pb ⇒ digest stored;
//   - editions 1..10,000 (the store's slots stay <= 10,000);
//   - tier "" or one of the store's tiers; title <= 64 bytes;
//   - values "" (none) or <= 32 bytes, no leading/trailing space; at most
//     100 distinct values per trait type and 255 over all types of a store.
//
// Returns "first-last" (0-based indexes). Event ArtworkAdded per line.
func AddArtworks(cur realm, storeID, batch string) string {
	s := ownedDraft(cur, storeID)
	if batch == "" {
		panic("batch: empty")
	}
	lines := split(batch, '\n')
	if len(lines) > MaxBatch {
		panic("batch: at most " + strconv.Itoa(MaxBatch) + " artworks per call")
	}
	if s.n+int64(len(lines)) > MaxArtworks {
		panic("store: at most " + strconv.Itoa(MaxArtworks) + " artworks")
	}
	first := s.n
	shas := make([]string, 0, len(lines))
	// per-call (type, value) -> id map, built once from the dictionary: a
	// line costs O(1) per trait instead of a scan of the values (UP-L1)
	var look map[string]int
	for i, line := range lines {
		f := split(line, '|')
		r, title := s.parseLine(i+1, f, &look)
		shas = append(shas, r.sha)
		s.appendRecord(&r, title)
		// the line's sha256 and CID are already canonical (strict parsers):
		// re-encoding them would cost ~1.5M gas per line for the same text
		chain.Emit("ArtworkAdded", "store", s.idStr(), "idx", strconv.FormatInt(s.n-1, 10),
			"kind", media.KindName(r.kind), "mime", media.MimeName(r.mime),
			"size", strconv.FormatInt(r.size, 10), "sha256", f[3], "cid", f[4],
			"editions", strconv.FormatInt(r.editions, 10), "tier", s.tierName(r.tier))
	}
	s.shas.insert(shas)
	return strconv.FormatInt(first, 10) + "-" + strconv.FormatInt(s.n-1, 10)
}

// split is strings.Split for a one-byte separator in a single pass (half
// the VM gas of strings.Split, which dominates a 100-line batch).
func split(s string, sep byte) []string {
	out := make([]string, 0, 16)
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == sep {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

func (s *store) parseLine(no int, f []string, look *map[string]int) (record, string) {
	at := "line " + strconv.Itoa(no) + ": "
	if want := 8 + len(s.traitTypes); len(f) != want {
		panic(at + "expected " + strconv.Itoa(want) + " '|'-separated fields, got " + strconv.Itoa(len(f)))
	}
	var r record
	switch f[0] {
	case "chain":
		r.kind = media.KindChain
	case "ipfs":
	default:
		panic(at + "kind must be chain or ipfs")
	}
	r.mime = parseMime(at, f[1])
	r.size = parseCount(at+"size", f[2], 1<<62)
	shaRaw, ok := media.Raw32(f[3])
	if !ok {
		panic(at + "sha256 must be 64 lower-case hex characters")
	}
	r.sha = shaRaw
	r.digest = zero32
	if r.kind == media.KindChain {
		if f[4] != "" {
			panic(at + "an on-chain artwork has no cid")
		}
	} else {
		codec, digest, err := media.ParseCIDv1(f[4])
		if err != nil {
			panic(at + err.Error())
		}
		if codec == media.CodecRaw {
			if digest != f[3] {
				panic(at + "a raw CID's digest must equal the file's sha256")
			}
			r.kind = media.KindIPFSRaw
		} else {
			r.kind = media.KindIPFSUnixFS
			r.digest, _ = media.Raw32(digest)
		}
	}
	if max := media.MaxBytes(r.kind, r.mime); r.size > max {
		panic(at + "size " + f[2] + " exceeds " + strconv.FormatInt(max, 10) + " bytes for this kind and type")
	}
	r.editions = parseCount(at+"editions", f[5], MaxEditions)
	if s.slots+r.editions > MaxSlots {
		panic(at + "the store would exceed " + strconv.Itoa(MaxSlots) + " slots (sum of editions)")
	}
	r.tier = s.tierIndex(at, f[6])
	title := f[7]
	safe.AssertText(at+"title", title, MaxTitleLen)
	for k := range s.traitTypes {
		r.traits[k] = s.dictIndex(at, k, f[8+k], look)
	}
	if r.kind == media.KindChain {
		if s.onchainBytes+r.size > MaxStoreOnchainBytes {
			panic(at + "the store would exceed " + strconv.Itoa(MaxStoreOnchainBytes) + " on-chain bytes")
		}
		r.logOff = s.onchainBytes
	} else {
		r.have = r.size
	}
	r.slotEnd = s.slots + r.editions
	return r, title
}

func parseMime(at, s string) (m int) {
	switch s {
	case "svg":
		return media.MimeSVG
	case "png":
		return media.MimePNG
	case "webp":
		return media.MimeWebP
	case "jpeg":
		return media.MimeJPEG
	}
	panic(at + "mime must be svg, png, webp or jpeg")
}

// parseCount parses a canonical positive decimal (no sign, no leading zero) <= max.
func parseCount(field, s string, max int64) int64 {
	if s == "" || len(s) > 19 || s[0] == '0' {
		panic(field + ": must be a positive decimal")
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			panic(field + ": must be a positive decimal")
		}
		n = n*10 + int64(c-'0')
		if n > max {
			panic(field + ": at most " + strconv.FormatInt(max, 10))
		}
	}
	return n
}

func (s *store) tierIndex(at, name string) int {
	if name == "" {
		return 0
	}
	for i, t := range s.tiers {
		if t == name {
			return i + 1
		}
	}
	panic(at + "unknown tier " + strconv.Quote(name))
}

func (s *store) tierName(i int) string {
	if i == 0 {
		return ""
	}
	return s.tiers[i-1]
}

func (s *store) dictIndex(at string, k int, v string, look *map[string]int) int {
	if v == "" {
		return 0
	}
	if *look == nil {
		m := make(map[string]int, len(s.dict))
		for i, e := range s.dict {
			m[strconv.Itoa(e.k)+"|"+e.v] = i + 1
		}
		*look = m
	}
	key := strconv.Itoa(k) + "|" + v
	if id, ok := (*look)[key]; ok {
		return id
	}
	// a new value: checked once, stored with its JSON and zero counters
	safe.AssertText(at+s.traitTypes[k], v, MaxValueLen)
	if strings.TrimSpace(v) != v {
		panic(at + s.traitTypes[k] + ": no leading or trailing spaces")
	}
	if s.perType[k] >= MaxDictValues {
		panic(at + s.traitTypes[k] + ": at most " + strconv.Itoa(MaxDictValues) + " distinct values")
	}
	if len(s.dict) >= MaxStoreValues {
		panic(at + "a store holds at most " + strconv.Itoa(MaxStoreValues) + " distinct trait values")
	}
	s.dict = append(s.dict, dictEntry{k: k, v: v, js: jsonStr(v)})
	s.cnt = append(s.cnt, 0, 0)
	s.perType[k]++
	(*look)[key] = len(s.dict)
	return len(s.dict)
}

func (s *store) appendRecord(r *record, title string) {
	k := bucketKey(s.n / bucketSize)
	var b *bucket
	if v := s.buckets.Get(k); v != nil {
		b = v.(*bucket)
	} else {
		b = &bucket{}
		s.buckets.Set(k, b)
	}
	b.rec += r.encode()
	b.titles += string([]byte{byte(len(title))}) + title
	if r.kind == media.KindChain {
		s.onchainN++
		s.onchainBytes += r.size
		s.chainIdx += u32(s.n)
	} else {
		s.ipfsN++
	}
	s.n++
	s.slots = r.slotEnd
	s.count(r, 1)
}

func u32(v int64) string {
	return string([]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})
}

// insert merges sorted-unique new digests into the index; any duplicate
// (inside the batch or with an earlier artwork) aborts the call.
func (x *shaIndex) insert(add []string) {
	for i := 1; i < len(add); i++ { // insertion sort, <= MaxBatch items
		for j := i; j > 0 && add[j] < add[j-1]; j-- {
			add[j], add[j-1] = add[j-1], add[j]
		}
	}
	for i := 1; i < len(add); i++ {
		if add[i] == add[i-1] {
			panic("sha256 " + hex.EncodeToString([]byte(add[i])) + " appears twice; use editions for copies")
		}
	}
	var b strings.Builder
	pos := 0
	for _, d := range add {
		at := x.search(d)
		if at < len(x.s) && x.s[at:at+32] == d {
			panic("sha256 " + hex.EncodeToString([]byte(d)) + " is already in this store; use editions for copies")
		}
		b.WriteString(x.s[pos:at])
		b.WriteString(d)
		pos = at
	}
	b.WriteString(x.s[pos:])
	x.s = b.String()
}

// remove drops the given digests (each present once).
func (x *shaIndex) remove(drop []string) {
	for _, d := range drop {
		at := x.search(d)
		if at < len(x.s) && x.s[at:at+32] == d {
			x.s = x.s[:at] + x.s[at+32:]
		}
	}
}

// search is the byte offset of the first entry >= d.
func (x *shaIndex) search(d string) int {
	lo, hi := 0, len(x.s)/32
	for lo < hi {
		mid := (lo + hi) / 2
		if x.s[mid*32:mid*32+32] < d {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo * 32
}

// AppendBytes stores the next chunk of an on-chain artwork. Bytes arrive
// in artwork order: idx must be the lowest incomplete on-chain artwork and
// offset its Have (resume = read Have). chunk is a []byte argument (the
// keeper decodes the MsgCall's base64 natively, WP0), 1..MaxChunk bytes.
// When the artwork is complete its sha256 must equal the declared one and
// media.CheckImage must pass, else the call panics and nothing is stored.
// Event ArtworkComplete{store, idx}.
func AppendBytes(cur realm, storeID string, idx, offset int64, chunk []byte) {
	s := ownedDraft(cur, storeID)
	if idx < 0 || idx >= s.n {
		panic("no artwork " + strconv.FormatInt(idx, 10) + " in store " + storeID)
	}
	b, i := s.bucketOf(idx)
	r := decodeRecord(b.raw(i))
	if r.kind != media.KindChain {
		panic("artwork " + strconv.FormatInt(idx, 10) + " is not stored on chain")
	}
	if r.complete() {
		panic("artwork " + strconv.FormatInt(idx, 10) + " is already complete")
	}
	if offset != r.have {
		panic("offset must equal have (" + strconv.FormatInt(r.have, 10) + ")")
	}
	if r.logOff+r.have != s.logLen {
		panic("upload the lowest incomplete on-chain artwork first")
	}
	n := int64(len(chunk))
	if n == 0 || n > MaxChunk {
		panic("chunk must be 1.." + strconv.Itoa(MaxChunk) + " bytes")
	}
	if r.have+n > r.size {
		panic("chunk exceeds the declared size (" + strconv.FormatInt(r.size-r.have, 10) + " bytes left)")
	}
	s.appendLog(string(chunk))
	r.have += n
	if r.complete() {
		data := s.readLog(r.logOff, r.size)
		sum := sha256.Sum256([]byte(data))
		if string(sum[:]) != r.sha {
			panic("sha256 mismatch: the uploaded bytes are not the declared file")
		}
		if _, _, err := media.CheckImage(r.mime, data); err != nil {
			panic("artwork " + strconv.FormatInt(idx, 10) + " rejected: " + err.Error())
		}
		s.chainDone++ // in-order uploads: idx was the next on-chain artwork
		chain.Emit("ArtworkComplete", "store", storeID, "idx", strconv.FormatInt(idx, 10))
	}
	b.setRaw(i, r.encode())
}

func (s *store) bucketOf(idx int64) (*bucket, int) {
	v := s.buckets.Get(bucketKey(idx / bucketSize))
	if v == nil {
		panic("assets: missing record bucket")
	}
	return v.(*bucket), int(idx % bucketSize)
}

func (s *store) appendLog(chunk string) {
	for len(chunk) > 0 {
		k := bucketKey(s.logLen / SegmentBytes)
		seg := ""
		if v := s.log.Get(k); v != nil {
			seg = v.(string)
		}
		n := SegmentBytes - len(seg)
		if n > len(chunk) {
			n = len(chunk)
		}
		s.log.Set(k, seg+chunk[:n])
		s.logLen += int64(n)
		chunk = chunk[n:]
	}
}

func (s *store) readLog(off, n int64) string {
	var b strings.Builder
	for n > 0 {
		seg := off / SegmentBytes
		v := s.log.Get(bucketKey(seg)).(string)
		lo := off - seg*SegmentBytes
		hi := int64(len(v))
		if hi-lo > n {
			hi = lo + n
		}
		b.WriteString(v[lo:hi])
		n -= hi - lo
		off += hi - lo
	}
	return b.String()
}

// cutLog shortens the byte log to newLen bytes (frees whole segments).
func (s *store) cutLog(newLen int64) {
	for s.logLen > newLen {
		seg := (s.logLen - 1) / SegmentBytes
		start := seg * SegmentBytes
		k := bucketKey(seg)
		if start >= newLen {
			s.log.Remove(k)
			s.logLen = start
			continue
		}
		v := s.log.Get(k).(string)
		s.log.Set(k, v[:newLen-start])
		s.logLen = newLen
	}
}

// Truncate drops artworks keep..n-1 of a Draft store and cuts the byte log
// back, freeing their storage (the chain refunds the signer, i.e. the owner
// who paid it). Trait values first used by dropped artworks stay in the
// dictionary (with zero counts; they still count towards MaxStoreValues).
// Event StoreTruncated{store, keep}.
func Truncate(cur realm, storeID string, keep int64) {
	s := ownedDraft(cur, storeID)
	if keep < 0 || keep >= s.n {
		panic("keep must be 0.." + strconv.FormatInt(s.n-1, 10))
	}
	cut := int64(-1)
	var dropped []string
	for idx := keep; idx < s.n; idx++ {
		b, i := s.bucketOf(idx)
		r := decodeRecord(b.raw(i))
		dropped = append(dropped, r.sha)
		s.count(&r, -1)
		if r.kind == media.KindChain {
			s.onchainN--
			if r.complete() {
				s.chainDone--
			}
			if cut < 0 {
				cut = r.logOff
			}
		} else {
			s.ipfsN--
		}
	}
	s.chainIdx = s.chainIdx[:s.onchainN*4]
	if cut >= 0 {
		s.onchainBytes = cut
		if s.logLen > cut {
			s.cutLog(cut)
		}
	}
	s.slots = 0
	if keep > 0 {
		b, i := s.bucketOf(keep - 1)
		s.slots = decodeRecord(b.raw(i)).slotEnd
	}
	last := (s.n - 1) / bucketSize
	kb := keep / bucketSize
	for bk := last; bk > kb; bk-- {
		s.buckets.Remove(bucketKey(bk))
	}
	if keep%bucketSize == 0 {
		s.buckets.Remove(bucketKey(kb))
	} else {
		v := s.buckets.Get(bucketKey(kb)).(*bucket)
		v.keep(int(keep % bucketSize))
	}
	s.n = keep
	s.shas.remove(dropped)
	chain.Emit("StoreTruncated", "store", storeID, "keep", strconv.FormatInt(keep, 10))
}

// Seal freezes a store for good. It needs at least one artwork and every
// on-chain artwork complete. Event StoreSealed{store, artworks, slots,
// onchainN, ipfsN, onchainBytes}.
func Seal(cur realm, storeID string) {
	s := ownedDraft(cur, storeID)
	if s.n == 0 {
		panic("a store needs at least one artwork to be sealed")
	}
	if s.logLen != s.onchainBytes {
		panic("on-chain artworks are incomplete: " + strconv.FormatInt(s.logLen, 10) + " of " +
			strconv.FormatInt(s.onchainBytes, 10) + " bytes uploaded")
	}
	s.sealed = true
	s.sealedHeight = runtime.ChainHeight()
	chain.Emit("StoreSealed", "store", storeID, "artworks", strconv.FormatInt(s.n, 10),
		"slots", strconv.FormatInt(s.slots, 10), "onchainN", strconv.FormatInt(s.onchainN, 10),
		"ipfsN", strconv.FormatInt(s.ipfsN, 10), "onchainBytes", strconv.FormatInt(s.onchainBytes, 10))
}
