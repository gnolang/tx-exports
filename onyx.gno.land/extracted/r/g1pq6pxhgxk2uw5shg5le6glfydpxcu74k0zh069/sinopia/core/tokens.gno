package core

import (
	"chain"
	"encoding/base64"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"

	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/engine/v1"
	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/safe/v1"
)

const tidWidth = 6

// tokenState is the per-collection data the transfer hook needs. It is
// shared by the collection and its lockExt, so neither points at the other.
type tokenState struct {
	final   bool
	batches avl.Tree // safe.PadInt(first) -> *mintBatch
	moves   avl.Tree // tid -> *moveRecord, created on a token's first transfer
}

// mintBatch records one mint call; mint height is derived per token from
// it, so a 10-token mint writes one record, not ten.
type mintBatch struct {
	first, last, height int64
}

type moveRecord struct {
	moves, lastMove int64
}

func (st *tokenState) addBatch(first, last, h int64) {
	st.batches.Set(safe.PadInt(first, tidWidth), &mintBatch{first: first, last: last, height: h})
}

func (st *tokenState) mintHeight(tid int64) int64 {
	var h int64
	st.batches.ReverseIterate("", safe.PadInt(tid, tidWidth), func(_ string, v any) bool {
		b := v.(*mintBatch)
		if tid <= b.last {
			h = b.height
		}
		return true
	})
	return h
}

func (st *tokenState) moveOf(tid string) (moves, lastMove int64) {
	if v := st.moves.Get(tid); v != nil {
		r := v.(*moveRecord)
		return r.moves, r.lastMove
	}
	return 0, 0
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
	if !e.st.final {
		panic("tokens are locked until the collection is final (reveal)")
	}
	key := tid.String()
	r, _ := e.st.moves.Get(key).(*moveRecord)
	if r == nil {
		r = &moveRecord{}
		e.st.moves.Set(key, r)
	}
	r.moves++
	r.lastMove = height()
	chain.Emit("Transfer", "cid", e.cid, "tid", key, "from", from.String(), "to", to.String())
}

func (e *lockExt) OnBurn(tid grc721.TokenID) {
	if !e.st.final {
		panic("tokens are locked until the collection is final (reveal)")
	}
	e.st.moves.Remove(tid.String())
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
func Approve(cur realm, cid, tid string, to address) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	if err := c.ledger.Approve(caller(cur), to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	bumpNonce(c, "t:"+tid)
}

func SetApprovalForAll(cur realm, cid string, operator address, approved bool) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
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
	return nonceOf(c, "t:"+tid), nonceOf(c, "o:"+owner.String()+":"+operator.String())
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

func TransferFrom(cur realm, cid, tid string, from, to address) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	if err := c.ledger.TransferFrom(caller(cur), from, to, grc721.TokenID(tid)); err != nil {
		panic(err)
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

func OwnerOf(cid, tid string) (address, error) {
	return mustCollection(cid).token.OwnerOf(grc721.TokenID(tid))
}

func BalanceOf(cid string, owner address) (int64, error) {
	return mustCollection(cid).token.BalanceOf(owner)
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

// TokenState is {mintHeight, lastMoveHeight, moves} as JSON.
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
	w.EndObject()
	return w.String()
}

// TokenURI is a base64 SVG data URI. Before Final every token shows core's
// neutral placeholder, never engine output (design §4.2).
func TokenURI(cid, tid string) (string, error) {
	c := mustCollection(cid)
	if _, err := c.token.OwnerOf(grc721.TokenID(tid)); err != nil {
		return "", err
	}
	if !c.st.final {
		return dataURI(placeholderSVG(c.name, "Unrevealed")), nil
	}
	return dataURI(renderToken(c, tid)), nil
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

// TokenMetadata is OpenSea-style metadata JSON.
func TokenMetadata(cid, tid string) string {
	c := mustCollection(cid)
	uri, err := TokenURI(cid, tid)
	if err != nil {
		panic(err)
	}
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("name", c.name+" #"+tid)
	w.StrField("description", c.description)
	w.StrField("image", uri)
	w.Key("attributes")
	writeTraits(w, tokenTraits(c, tid))
	w.EndObject()
	return w.String()
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
	if c.st.final {
		in.Seed = safe.Seed(c.id, tid, c.prov.salt)
	}
	return in
}

// renderToken runs the collection's engine on a read path. A bad output
// degrades to a placeholder; a panicking engine only fails reads of its own
// collections (interrealm v2 §9: cross-realm panics abort the query).
func renderToken(c *collection, tid string) string {
	rec := mustEngine(c.engineID)
	svg := rec.impl.Render(tokenInput(c, tid))
	if err := engine.CheckSVG(rec.manifest, svg); err != nil {
		return placeholderSVG(c.name, "Engine output rejected")
	}
	return svg
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
	if err := engine.ValidateTraits(rec.manifest, ts); err != nil {
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
