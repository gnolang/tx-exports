// Package nft holds GnoRadio's concert tickets as GRC721 NFTs. It is
// permanent, like the data realm: a tickets release changes the rules, never
// this ledger, so no ticket ever moves to a new contract.
//
// Only the realm that writes the tickets role now (data.Writer("tickets"))
// mints and transfers, only while that role is not paused, and only for the
// wallet that signs the transaction (OriginCaller): a release can never move
// the ticket of a holder who signs nothing. That is the whole guarantee. The
// signature proves the holder sent some transaction through the tickets
// writer, not that they asked for this move: a malicious tickets release (it
// takes over only after the data realm's public 72 h window, which the
// guardian can cancel) could move every ticket of a holder who then signs any
// call to it. This realm cannot see further up the call stack. Anyone reads.
//
// A ticket's metadata and artwork are drawn on the fly from the tickets data
// (art.gno), whose record layout below is frozen for that reason.
package nft

import (
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// The tickets records this realm reads, written by the tickets writer. Every
// tickets release keeps this layout: the artwork of existing tickets depends
// on it.
const (
	CEvents  = "tickets/events"  // store.Pad(id) -> event record
	CTickets = "tickets/tickets" // store.Pad((id-1)/Chunk) -> Chunk ticket records
	Chunk    = 16
)

// Event record fields (store.Rec); the one each sale changes comes first.
const (
	ESold = iota
	EArtist
	EStart
	EPrice
	ECapacity
	ECancelled // "1" or ""
	EHidden    // "1" or ""
	ERemoved   // the moderator's public reason while hidden
	ETitle
	EVenue
	ELink
	EFields
)

// Ticket record fields.
const (
	TEvent = iota
	TSerial
	TAttended // "1" or ""
)

// The catalog's artist heads, read for a ticket's artist line: every catalog
// release keeps this layout, since it shares the data realm's records
// (catalog/v1 records.gno). Reading them here, not through a catalog realm,
// keeps this permanent realm free of any versioned import.
const (
	CArtists    = "catalog/artists" // store.Pad((id-1)/ArtistChunk) -> ArtistChunk artist heads
	ArtistChunk = 8
	AHidden     = 0 // "1" or ""
	AName       = 6
)

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger
)

// init creates the token, so its storage is paid at deploy and never by a
// first buyer.
func init(cur realm) {
	token, ledger = grc721.NewToken("GnoRadio Ticket", "GRTIX", 1, cur)
}

// writer lets only the tickets writer through, while its role is not paused.
func writer(cur realm) {
	if cur.Previous().PkgPath() != data.Writer("tickets") {
		panic("nft: only " + data.Writer("tickets") + " mints and transfers tickets")
	}
	if data.Paused("tickets") {
		panic("nft: tickets is paused")
	}
}

// maxID is the largest id a data key holds (store.Pad); readers answer ""
// past it instead of panicking.
const maxID = 99999999

func tid(id int) grc721.TokenID { return grc721.TokenID(strconv.Itoa(id)) }

// Mint creates ticket id for to, the wallet that signed the transaction.
// The tickets writer only.
func Mint(cur realm, to address, id int) {
	writer(cur)
	if to != unsafe.OriginCaller() {
		panic("nft: a ticket is minted to the wallet that signs")
	}
	if id < 1 || id > maxID {
		panic("nft: invalid ticket id")
	}
	if err := ledger.Mint(to, tid(id)); err != nil {
		panic("nft: " + err.Error())
	}
}

// Transfer moves ticket id from its holder from to to. The tickets writer
// only, and only in a transaction from signed: no release moves the tickets
// of a holder who signs nothing (see the package comment for what a
// malicious release could still do). The rules decide who may gift.
func Transfer(cur realm, from, to address, id int) {
	writer(cur)
	if from != unsafe.OriginCaller() {
		panic("nft: only the holder's own transaction moves a ticket")
	}
	if !role.Canonical(to) {
		panic("nft: not an address")
	}
	if err := ledger.TransferFrom(from, from, to, tid(id)); err != nil {
		panic("nft: " + err.Error())
	}
}

// ---- GRC721 reads ----

func Name() string       { return token.GetName() }
func Symbol() string     { return token.GetSymbol() }
func TotalSupply() int64 { return token.TotalSupply() }

// BalanceOf is how many tickets owner holds.
func BalanceOf(owner address) int64 {
	n, err := token.BalanceOf(owner)
	if err != nil {
		panic("nft: " + err.Error())
	}
	return n
}

// OwnerOf is a ticket's holder; it panics for an unknown ticket.
func OwnerOf(tokenID string) address {
	owner, err := token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		panic("nft: " + err.Error())
	}
	return owner
}

// Holder is a ticket's holder, "" for an unknown ticket.
func Holder(id int) address {
	owner, _ := token.OwnerOf(tid(id))
	return owner
}

// Render shows the collection.
func Render(_ string) string {
	return token.RenderHome() + "\nGnoRadio concert tickets. Each one is drawn on-chain: `TokenURI(id)`. Only `" +
		data.Writer("tickets") + "` mints and transfers them.\n"
}

// ---- the tickets records ----

// ticket returns ticket id's record ("" when absent).
func ticket(id int) string {
	if id < 1 || id > maxID {
		return ""
	}
	ch, ok := data.Get(CTickets, store.Pad((id-1)/Chunk))
	if !ok {
		return ""
	}
	return store.Field(ch, (id-1)%Chunk)
}

// artist returns artist id's head record ("" when absent).
func artist(id int) string {
	if id < 1 || id > maxID {
		return ""
	}
	ch, ok := data.Get(CArtists, store.Pad((id-1)/ArtistChunk))
	if !ok {
		return ""
	}
	return store.Field(ch, (id-1)%ArtistChunk)
}

func event(id int) string {
	if id < 1 || id > maxID {
		return ""
	}
	rec, _ := data.Get(CEvents, store.Pad(id))
	return rec
}
