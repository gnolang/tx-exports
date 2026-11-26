package rooms

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/enumerable/v0"
	"gno.land/p/nt/grc721/v0"
)

// NFTs: one GRC721 token is one asset on a side, held whole. gno.land has no
// GRC721 registry yet, so rooms keeps its own, on the trust model of
// gno.land/r/nt/grc20reg/v0: a collection registers itself, from its own
// realm, under the key "<realm path>.<symbol>". An NFT asset's denom is that
// key, "#" and the token id; a key never holds "#".

// MaxTokenIDLen bounds what a room stores per NFT.
const MaxTokenIDLen = 64

type collection struct {
	token *grc721.Token
	// list is the collection's enumerable view, when it has one: it lets
	// OwnedJSON show a wallet's NFTs of this collection.
	list *enumerable.Enumerable
}

var collections avl.Tree // "<realm path>.<symbol>" -> *collection

// RegisterCollection makes a GRC721 collection tradable in rooms and returns
// its key. Only the collection's own realm can register it, once; list is
// its enumerable view, or nil. A collection's realm also lets owners
// approve this realm (see Address) for one token id, as its own Approve
// does; DepositNFT spends that approval.
//
//	key := rooms.RegisterCollection(cross(cur), Token, List)
func RegisterCollection(cur realm, token *grc721.Token, list *enumerable.Enumerable) string {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	refuseCoins(cur)
	if token == nil {
		panic("collection is nil")
	}
	path := cur.Previous().PkgPath()
	if !strings.HasPrefix(path, "gno.land/r/") || strings.Contains(path, "#") {
		panic("register a collection from its own realm")
	}
	key := path + "." + token.GetSymbol()
	// Token.ID() is "<creating realm path>.<symbol>.<id>" and cannot be
	// forged: the token was created by the realm that registers it.
	if !strings.HasPrefix(token.ID(), key+".") {
		panic("register a collection from its own realm")
	}
	if list != nil && list.TokenID() != token.ID() {
		panic("the list belongs to another collection")
	}
	if collections.Has(key) {
		panic("collection already registered")
	}
	collections.Set(key, &collection{token: token, list: list})
	chain.Emit("CollectionRegistered",
		"key", key,
		"name", token.GetName(),
		"symbol", token.GetSymbol(),
	)
	return key
}

// DepositNFT moves one NFT of a registered collection from the caller to
// this realm and adds it to the caller's side. The caller must first
// approve this realm's address (see Address) for that token id, in the
// collection's realm.
func DepositNFT(cur realm, roomID uint64, collectionKey string, tokenID string) {
	who := callerOf(cur)
	refuseCoins(cur)
	assertNotPaused()
	col := mustCollection(collectionKey)
	assertTokenID(tokenID)

	r := mustRoom(roomID)
	r.assertLive()
	mine, _ := r.sideOf(who)
	r.assertAccepts(KindNFT, collectionKey)
	denom := collectionKey + "#" + tokenID
	tid := grc721.TokenID(tokenID)

	// Say plainly what is missing before anything changes.
	if owner, err := col.token.OwnerOf(tid); err != nil || owner != who {
		panic("you do not own that NFT")
	}
	if to, err := col.token.GetApproved(tid); (err != nil || to != cur.Address()) && !col.token.IsApprovedForAll(who, cur.Address()) {
		panic("approve this realm for that NFT first")
	}

	// Record first, move second: a GRC721 transfer runs the issuer's
	// extension hooks, and anything they call back into must already see
	// the room as it will be. A failed transfer aborts the whole call.
	mine.addNFT(denom)
	r.bump()

	// This realm is the spender: the owner's approval to it is what moves.
	if err := col.token.RealmTeller(0, cur).TransferFrom(0, cur, who, cur.Address(), tid); err != nil {
		panic(err.Error())
	}

	chain.Emit("Deposited",
		"id", idString(r.id),
		"party", who.String(),
		"nft", collectionKey,
		"tokenId", tokenID,
		"version", idString(r.version),
	)
}

// WithdrawNFT returns one NFT from the caller's side to the caller. Same
// rules as WithdrawCoins: it works while the room is open, also after it
// has expired or while the realm is paused.
func WithdrawNFT(cur realm, roomID uint64, collectionKey string, tokenID string) {
	withdraw(cur, roomID, KindNFT, collectionKey+"#"+tokenID, 1)
}

// sendNFT pays one NFT out of this realm's custody.
func sendNFT(cur realm, to address, denom string) {
	key, tid, ok := strings.Cut(denom, "#")
	if !ok {
		panic("unknown NFT")
	}
	col := mustCollection(key)
	if err := col.token.RealmTeller(0, cur).TransferFrom(0, cur, cur.Address(), to, grc721.TokenID(tid)); err != nil {
		panic(err.Error())
	}
}

func (s *side) addNFT(denom string) {
	for _, a := range s.assets {
		if a.kind == KindNFT && a.denom == denom {
			panic("that NFT is already in the room")
		}
	}
	if len(s.assets) >= MaxAssetsPerSide {
		panic("a side can hold at most 8 different assets")
	}
	s.assets = append(s.assets, asset{kind: KindNFT, denom: denom, amount: 1})
}

func mustCollection(key string) *collection {
	v := collections.Get(key)
	if v == nil {
		panic("collection is not registered with rooms")
	}
	return v.(*collection)
}

func assertTokenID(tid string) {
	if tid == "" || len(tid) > MaxTokenIDLen {
		panic("token id must be 1 to " + strconv.Itoa(MaxTokenIDLen) + " bytes")
	}
	for _, r := range tid {
		if r < 0x20 || r == 0x7f {
			panic("token id has a control character")
		}
	}
}
