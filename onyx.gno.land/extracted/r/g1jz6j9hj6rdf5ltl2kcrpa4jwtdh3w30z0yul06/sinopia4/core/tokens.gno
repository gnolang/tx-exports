package core

import (
	"chain"
	"encoding/base64"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
)

// tokenState is the per-collection data the transfer hook needs. It is
// shared by the collection and its lockExt, so neither points at the other.
//
// Per-token state is packed (storage-cost-analysis P1+P3): one fixed-width
// entry of packEntry bytes per token, packSlots tokens per avl key. Entry =
// four big-endian uint32 fields: mint height, transfer count (H-2), height
// of the last transfer, and the token's approval nonce (SA-L3). A mint
// appends entries in tid order (a new key every packSlots tokens, ~2 KB the
// minter of that bucket's first token pays); a transfer or an Approve only
// rewrites bytes in place, so neither creates a storage object.
//
// First owners (I-20) are run-length records in a second tree with the
// same bucket keys: one record of ownerRec bytes (the token's slot in the
// bucket, then the 40-character address) for each run of consecutive
// tokens minted to one address. A mint batch adds at most one record per
// bucket it touches, and none when it continues the bucket's last run, so
// a batch of n costs 41 bytes, not 40 n; a bucket holds at most
// packSlots records. Neither a transfer nor an approval touches it.
type tokenState struct {
	final     bool
	soulbound bool     // non-transferable collection (I-20)
	pack      avl.Tree // safe.PadInt((tid-1)/packSlots, packKeyWidth) -> string of packed entries
	owners    avl.Tree // same key -> string of first-owner run records
}

const (
	packSlots    = 128
	packFields   = 4
	packEntry    = packFields * 4
	packKeyWidth = 3 // MaxSupplyCap/packSlots < 1000

	addrLen  = 40 // a bech32 "g1…" address of 20 bytes
	ownerRec = 1 + addrLen

	fieldMintHeight = 0
	fieldMoves      = 1
	fieldLastMove   = 2
	fieldNonce      = 3
)

func packKey(tid int64) string { return safe.PadInt((tid-1)/packSlots, packKeyWidth) }

// u32 encodes v as 4 big-endian bytes. Heights stay below 2^32 for ~470
// years of 3.5 s blocks; 2^32 transfers or approvals of one token cannot
// happen, so overflow is a hard error rather than a wrap.
func u32(v int64) string {
	if v < 0 || v > 0xFFFFFFFF {
		panic("token state: value out of uint32 range")
	}
	return string([]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})
}

// appendTokens adds zeroed entries (mint height h) for first..last, which
// must directly follow the last stored token.
func (st *tokenState) appendTokens(first, last, h int64) {
	entry := u32(h) + u32(0) + u32(0) + u32(0)
	for tid := first; tid <= last; {
		k := packKey(tid)
		v, _ := st.pack.Get(k).(string)
		if int64(len(v)) != ((tid-1)%packSlots)*packEntry {
			panic("token state: tokens must be appended in order")
		}
		for ; tid <= last && packKey(tid) == k; tid++ {
			v += entry
		}
		st.pack.Set(k, v)
	}
}

// appendOwners records to as the first owner of first..last (appended in
// tid order, right after appendTokens of the same range).
func (st *tokenState) appendOwners(first, last int64, to address) {
	a := to.String()
	if len(a) != addrLen {
		panic("token state: unexpected address length")
	}
	for tid := first; tid <= last; {
		k := packKey(tid)
		v, _ := st.owners.Get(k).(string)
		if len(v) < ownerRec || v[len(v)-addrLen:] != a {
			st.owners.Set(k, v+string([]byte{byte((tid-1)%packSlots)})+a)
		}
		tid = (tid-1)/packSlots*packSlots + packSlots + 1 // first tid of the next bucket
	}
}

// firstOwner is the address token tid was minted to, or "" for a token
// that was never minted. Burned tokens keep theirs.
func (st *tokenState) firstOwner(tid int64) address {
	if tid <= 0 || st.field(tid, fieldMintHeight) == 0 {
		return ""
	}
	return st.ownerAt(tid)
}

// ownerAt is the first owner recorded for a minted token tid: the last run
// record at or before its slot (records are in slot order).
func (st *tokenState) ownerAt(tid int64) address {
	v, _ := st.owners.Get(packKey(tid)).(string)
	slot := byte((tid - 1) % packSlots)
	at := -1
	for off := 0; off+ownerRec <= len(v) && v[off] <= slot; off += ownerRec {
		at = off
	}
	if at < 0 {
		return ""
	}
	return address(v[at+1 : at+ownerRec])
}

// field reads one field of token tid; 0 for a token that was never minted.
func (st *tokenState) field(tid int64, f int) int64 {
	if tid <= 0 {
		return 0
	}
	v, _ := st.pack.Get(packKey(tid)).(string)
	off := int((tid-1)%packSlots)*packEntry + f*4
	if off+4 > len(v) {
		return 0
	}
	return int64(v[off])<<24 | int64(v[off+1])<<16 | int64(v[off+2])<<8 | int64(v[off+3])
}

// setFields rewrites one or two fields of token tid in place (one avl
// update; f2 < 0 means none).
func (st *tokenState) setFields(tid int64, f1 int, v1 int64, f2 int, v2 int64) {
	k := packKey(tid)
	v, _ := st.pack.Get(k).(string)
	base := int((tid-1)%packSlots) * packEntry
	if tid <= 0 || base+packEntry > len(v) {
		panic("token state: unknown token")
	}
	o1 := base + f1*4
	v = v[:o1] + u32(v1) + v[o1+4:]
	if f2 >= 0 {
		o2 := base + f2*4
		v = v[:o2] + u32(v2) + v[o2+4:]
	}
	st.pack.Set(k, v)
}

func (st *tokenState) mintHeight(tid int64) int64 { return st.field(tid, fieldMintHeight) }

func (st *tokenState) moveOf(tid string) (moves, lastMove int64) {
	n := tidNum(tid)
	return st.field(n, fieldMoves), st.field(n, fieldLastMove)
}

// tidNum is the numeric token id, or 0 for anything that is not a
// canonical positive decimal (no such token exists).
func tidNum(tid string) int64 {
	if len(tid) == 0 || len(tid) > 12 || tid[0] == '0' {
		return 0
	}
	var n int64
	for i := 0; i < len(tid); i++ {
		c := tid[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// lockExt is the grc721 Extension behind two invariants:
//
//   - I-11: before Final no token moves or burns (the reveal lock that
//     closes RA H-3's information-advantage branch). The veto is a panic,
//     which aborts the whole transaction — the documented Extension
//     semantics of p/nt/grc721/v0.
//   - H-2: every transfer bumps the token's move counter, so a market
//     listing taken at moves=N is dead after any transfer, even if the
//     token later comes back to the seller.
//
// It is declared in this realm, so the hooks write core state with core's
// authority even when another realm moves the token via RealmTeller.
type lockExt struct {
	cid string
	st  *tokenState
}

const lockKind = "art-lock"

func (e *lockExt) ExtensionKind() string { return lockKind }

// The hooks also emit the platform's per-token history events with the
// collection id ("Minted", "Transfer"); grc721's own Transfer event carries
// only the token's grc721 id.
func (e *lockExt) OnMint(to address, tid grc721.TokenID) {
	chain.Emit("Minted", "cid", e.cid, "tid", tid.String(), "to", to.String())
}

func (e *lockExt) OnTransfer(from, to address, tid grc721.TokenID) {
	if e.st.soulbound {
		panic(errSoulbound)
	}
	if !e.st.final {
		panic("tokens are locked until the collection is final (reveal)")
	}
	key := tid.String()
	n := tidNum(key)
	e.st.setFields(n, fieldMoves, e.st.field(n, fieldMoves)+1, fieldLastMove, height())
	chain.Emit("Transfer", "cid", e.cid, "tid", key, "from", from.String(), "to", to.String())
}

func (e *lockExt) OnBurn(tid grc721.TokenID) {
	if !e.st.final {
		panic("tokens are locked until the collection is final (reveal)")
	}
	// the packed entry stays: a burned id is never minted again (I-5)
}

// --- owner actions (I-2: never paused) ---------------------------------------
//
// The acting account is always the immediate caller (cur.Previous()), the
// same rule as grc721's CallerTeller: a realm a user merely calls cannot act
// for that user. Another realm moves tokens only after an Approve, through
// Token(cid).RealmTeller (market/v1 does exactly that).

// Every Approve of a token and every SetApprovalForAll of an (owner,
// operator) pair bumps a nonce. A market pins the nonces at listing time,
// so revoking an approval kills a listing for good: approving again later
// starts a new nonce and never revives the old listing (SA-L3).
//
// Argument order follows grc721 with the collection first (K-1, Onbloc
// option A): Approve(cid, to, tid), TransferFrom(cid, from, to, tid).
func Approve(cur realm, cid string, to address, tid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	assertTransferable(c)
	if err := c.ledger.Approve(caller(cur), to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	n := tidNum(tid)
	c.st.setFields(n, fieldNonce, c.st.field(n, fieldNonce)+1, -1, 0)
}

func SetApprovalForAll(cur realm, cid string, operator address, approved bool) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	if approved {
		assertTransferable(c)
	}
	owner := caller(cur)
	if err := c.ledger.SetApprovalForAll(owner, operator, approved); err != nil {
		panic(err)
	}
	bumpNonce(c, "o:"+owner.String()+":"+operator.String())
}

// ApprovalNonces returns the token's approval nonce and the (owner,
// operator) approval-for-all nonce. Approvals made directly through
// Token(cid).RealmTeller by a realm acting for itself do not bump them.
func ApprovalNonces(cid, tid string, owner, operator address) (tokenNonce, operatorNonce int64) {
	c := mustCollection(cid)
	return c.st.field(tidNum(tid), fieldNonce), nonceOf(c, "o:"+owner.String()+":"+operator.String())
}

func bumpNonce(c *collection, key string) {
	c.approvals.Set(key, nonceOf(c, key)+1)
}

func nonceOf(c *collection, key string) int64 {
	if v := c.approvals.Get(key); v != nil {
		return v.(int64)
	}
	return 0
}

func TransferFrom(cur realm, cid string, from, to address, tid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	assertTransferable(c)
	if err := c.ledger.TransferFrom(caller(cur), from, to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}

const errSoulbound = "tokens of a non-transferable collection never move or get approved"

// assertTransferable refuses core's transfer and approval entry points for
// a non-transferable collection (I-20). The lockExt hook refuses every
// transfer anyway, also one through Token(cid).RealmTeller; this gives the
// same text before grc721's own approval checks. Revoking an
// approval-for-all stays possible.
func assertTransferable(c *collection) {
	if c.soulbound {
		panic(errSoulbound)
	}
}

// Burn is owner-only. The supply gate uses nextTID, so a burn never reopens
// a slot (I-5).
func Burn(cur realm, cid, tid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	owner, err := c.token.OwnerOf(grc721.TokenID(tid))
	if err != nil {
		panic(err)
	}
	if owner != caller(cur) {
		panic("only the owner can burn a token")
	}
	if err := c.ledger.Burn(grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}

// --- token reads ---------------------------------------------------------------

// Token publishes the collection's official *grc721.Token. Its exported
// methods are reads or teller factories that need the caller's live realm;
// the ledger itself is never published.
func Token(cid string) *grc721.Token { return mustCollection(cid).token }

// Royalty publishes the read-only royalty view (EIP-2981 RoyaltyInfo).
func Royalty(cid string) *royalty.Royalty { return mustCollection(cid).roy }

// Name and Symbol are the collection's grc721 name and symbol (K-1: the
// grc721 read set a wallet needs, keyed by collection).
func Name(cid string) string { return mustCollection(cid).name }

func Symbol(cid string) string { return mustCollection(cid).symbol }

func OwnerOf(cid, tid string) (address, error) {
	return mustCollection(cid).token.OwnerOf(grc721.TokenID(tid))
}

func BalanceOf(cid string, owner address) (int64, error) {
	return mustCollection(cid).token.BalanceOf(owner)
}

// FirstOwner is the address token tid was minted to (a sale mint or a
// creator reserve), whoever holds it now; burned tokens keep it. Panics
// for a token that was never minted.
func FirstOwner(cid, tid string) address {
	a := mustCollection(cid).st.firstOwner(tidNum(tid))
	if a == "" {
		panic(grc721.ErrInvalidTokenId)
	}
	return a
}

// TokenMoves is the transfer counter market/v1 pins in a listing (H-2).
func TokenMoves(cid, tid string) int64 {
	n, _ := mustCollection(cid).st.moveOf(tid)
	return n
}

// TokenSeed is "" until the collection is Final: no read path can leak the
// rarity map early.
func TokenSeed(cid, tid string) string {
	c := mustCollection(cid)
	if !c.st.final || !exists(c, tid) {
		return ""
	}
	return safe.Seed(c.id, tid, c.prov.salt)
}

// TokenState is {mintHeight, lastMoveHeight, moves, firstOwner} as JSON.
func TokenState(cid, tid string) string {
	c := mustCollection(cid)
	if !exists(c, tid) {
		panic(grc721.ErrInvalidTokenId)
	}
	in := tokenInput(c, tid)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.IntField("mintHeight", in.MintHeight)
	w.IntField("lastMoveHeight", in.LastMoveHeight)
	w.IntField("moves", in.Moves)
	w.StrField("firstOwner", in.FirstOwner.String())
	w.EndObject()
	return w.String()
}

// TokenURI is the token's art (I-15). Before Final every token shows
// core's neutral placeholder, never engine output (design §4.2). Then:
// an SVG engine's checked Render as an SVG data URI; a media engine's
// checked Media as a raster/SVG data URI or its ipfs:// CIDv1 URI, or —
// when the Media is empty or fails engine.CheckMedia — the checked card.
func TokenURI(cid, tid string) (string, error) {
	c := mustCollection(cid)
	if _, err := c.token.OwnerOf(grc721.TokenID(tid)); err != nil {
		return "", err
	}
	a := tokenArt(c, tid)
	return a.uri(), nil
}

// TokenCard is the token's checked SVG as a data URI: the art of an SVG
// engine, the card of a media engine, or the placeholder (gnoweb and
// SVG-only clients).
func TokenCard(cid, tid string) (string, error) {
	c := mustCollection(cid)
	if _, err := c.token.OwnerOf(grc721.TokenID(tid)); err != nil {
		return "", err
	}
	if !c.st.final {
		return dataURI(placeholderSVG(c.name, "Unrevealed")), nil
	}
	return dataURI(renderToken(c, tid)), nil
}

// TokenMediaInfo describes what TokenURI returns without the payload:
// {"source":"placeholder"|"svg"|"card"|"data"|"ipfs","mime","sha256","uri","bytes"}
// (uri only for ipfs; bytes = the file size for data, else 0).
func TokenMediaInfo(cid, tid string) string {
	c := mustCollection(cid)
	if !exists(c, tid) {
		panic(grc721.ErrInvalidTokenId)
	}
	a := tokenArt(c, tid)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("source", a.source)
	w.StrField("mime", a.mime)
	w.StrField("sha256", a.md.Sha256)
	uri := ""
	if a.source == artIPFS {
		uri = a.md.URI
	}
	w.StrField("uri", uri)
	w.IntField("bytes", int64(len(a.md.Data)))
	w.EndObject()
	return w.String()
}

// TokenTraits is [{"trait_type":…,"value":…}] JSON.
func TokenTraits(cid, tid string) string {
	c := mustCollection(cid)
	w := &safe.JSONWriter{}
	writeTraits(w, tokenTraits(c, tid))
	return w.String()
}

// TokenTraitList is the typed form of TokenTraits for other realms (a copy).
func TokenTraitList(cid, tid string) []engine.Trait {
	return append([]engine.Trait{}, tokenTraits(mustCollection(cid), tid)...)
}

// TokenMetadata is OpenSea-style metadata JSON. "image" is TokenURI
// written without escaping (it only ever holds data-URI / ipfs characters,
// M-4); "image_mime" and "image_sha256" describe a checked media file.
func TokenMetadata(cid, tid string) string {
	c := mustCollection(cid)
	if !exists(c, tid) {
		panic(grc721.ErrInvalidTokenId)
	}
	a := tokenArt(c, tid)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("name", c.name+" #"+tid)
	w.StrField("description", c.description)
	w.RawStrField("image", a.uri())
	if a.source == artData || a.source == artIPFS {
		w.StrField("image_mime", a.mime)
		if a.md.Sha256 != "" {
			w.StrField("image_sha256", a.md.Sha256)
		}
	}
	// attributes carry OpenSea's trait_type and Adena's traitType (K-1)
	w.Key("attributes")
	w.BeginArray()
	for _, tr := range tokenTraits(c, tid) {
		w.BeginObject()
		w.StrField("trait_type", tr.Type)
		w.StrField("traitType", tr.Type)
		w.StrField("value", tr.Value)
		w.EndObject()
	}
	w.EndArray()
	w.EndObject()
	return w.String()
}

// Art sources of a token (TokenMediaInfo "source").
const (
	artPlaceholder = "placeholder"
	artSVG         = "svg"
	artCard        = "card"
	artData        = "data"
	artIPFS        = "ipfs"
)

// art is a token's resolved, checked art.
type art struct {
	source string
	mime   string
	svg    string       // placeholder / svg / card
	md     engine.Media // data / ipfs (checked)
}

func (a art) uri() string {
	switch a.source {
	case artData:
		return "data:" + a.mime + ";base64," + base64.StdEncoding.EncodeToString([]byte(a.md.Data))
	case artIPFS:
		return a.md.URI
	}
	return dataURI(a.svg)
}

// tokenArt resolves a token's art under I-15; every engine output passes
// engine.CheckSVG or engine.CheckMedia first.
func tokenArt(c *collection, tid string) art {
	if !c.st.final {
		return art{source: artPlaceholder, mime: engine.MimeSVG, svg: placeholderSVG(c.name, "Unrevealed")}
	}
	rec := mustEngine(c.engineID)
	in := tokenInput(c, tid)
	if rec.manifest.Kind == engine.KindMedia {
		md := rec.impl.Media(in)
		if !md.IsZero() && engine.CheckMedia(rec.manifest, md) == nil {
			if md.Data != "" {
				return art{source: artData, mime: md.Mime, md: md}
			}
			return art{source: artIPFS, mime: md.Mime, md: md}
		}
		svg, ok := renderCheckedToken(c, rec, in)
		if ok {
			return art{source: artCard, mime: engine.MimeSVG, svg: svg}
		}
		return art{source: artPlaceholder, mime: engine.MimeSVG, svg: svg}
	}
	svg, ok := renderCheckedToken(c, rec, in)
	if ok {
		return art{source: artSVG, mime: engine.MimeSVG, svg: svg}
	}
	return art{source: artPlaceholder, mime: engine.MimeSVG, svg: svg}
}

func exists(c *collection, tid string) bool {
	_, err := c.token.OwnerOf(grc721.TokenID(tid))
	return err == nil
}

func tokenInput(c *collection, tid string) engine.Input {
	n := safe.ParseID("tid", tid)
	moves, lastMove := c.st.moveOf(tid)
	mh := c.st.mintHeight(n)
	if lastMove == 0 {
		lastMove = mh
	}
	in := engine.Input{
		Params:         c.params,
		CollectionID:   c.id,
		TokenID:        tid,
		MintHeight:     mh,
		LastMoveHeight: lastMove,
		Moves:          moves,
		Height:         height(),
	}
	if mh > 0 {
		in.FirstOwner = c.st.ownerAt(n)
	}
	if c.st.final {
		in.Seed = safe.Seed(c.id, tid, c.prov.salt)
		in.Salt = c.prov.salt
	}
	return in
}

// renderToken runs the collection's engine on a read path. A bad output
// degrades to a placeholder; a panicking engine only fails reads of its own
// collections (interrealm v2 §9: cross-realm panics abort the query).
func renderToken(c *collection, tid string) string {
	rec := mustEngine(c.engineID)
	svg, _ := renderCheckedToken(c, rec, tokenInput(c, tid))
	return svg
}

// renderCheckedToken is Render + CheckSVG; false (and the placeholder) when
// the output is rejected.
func renderCheckedToken(c *collection, rec *engineRecord, in engine.Input) (string, bool) {
	svg := rec.impl.Render(in)
	if err := engine.CheckSVG(rec.manifest, svg); err != nil {
		return placeholderSVG(c.name, "Engine output rejected"), false
	}
	return svg, true
}

func tokenTraits(c *collection, tid string) []engine.Trait {
	if !exists(c, tid) {
		panic(grc721.ErrInvalidTokenId)
	}
	if !c.st.final {
		return []engine.Trait{{Type: "Status", Value: "Unrevealed"}}
	}
	rec := mustEngine(c.engineID)
	ts := rec.impl.Traits(tokenInput(c, tid))
	if err := engine.ValidateTraitsFor(traitTypesOf(c), ts); err != nil {
		return []engine.Trait{{Type: "Status", Value: "Engine output rejected"}}
	}
	return ts
}

func writeTraits(w *safe.JSONWriter, ts []engine.Trait) {
	w.BeginArray()
	for _, t := range ts {
		w.BeginObject()
		w.StrField("trait_type", t.Type)
		w.StrField("value", t.Value)
		w.EndObject()
	}
	w.EndArray()
}

// placeholderSVG is core's own neutral art: identical for every token of a
// collection, so it carries no rarity signal.
func placeholderSVG(name, label string) string {
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">` +
		`<rect width="512" height="512" fill="#111"/>` +
		`<text x="256" y="236" fill="#ddd" font-family="monospace" font-size="24" text-anchor="middle">` +
		safe.XMLEscape(name) + `</text>` +
		`<text x="256" y="286" fill="#888" font-family="monospace" font-size="18" text-anchor="middle">` +
		safe.XMLEscape(label) + `</text></svg>`
}

func dataURI(svg string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

// emitBatch announces one MintTo ("MintBatch") or ReserveTo ("Reserved")
// call; each token also gets its own "Minted" event from lockExt.
func emitBatch(kind string, c *collection, to address, first, last int64) {
	chain.Emit(kind, "cid", c.id, "to", to.String(), "first", itoa(first), "last", itoa(last))
}
