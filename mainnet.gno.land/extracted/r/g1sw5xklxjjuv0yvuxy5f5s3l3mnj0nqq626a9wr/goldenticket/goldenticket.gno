// Package goldenticket is a 1/1 GRC721 NFT: one golden ticket, minted to the
// publisher when the package is added. It exists to check that a gno.land
// collection shows in the Adena wallet before gnofly's planes go to mainnet,
// so it is built the way the planes are:
//
//   - the collection is a gno.land/p/nt/grc721/v0 token made with NewToken,
//     whose NewToken and Transfer events Adena finds on its indexer;
//   - the read functions take a grc721.TokenID and return (value, error), as
//     Adena calls them: OwnerOf("1"), BalanceOf("g1..."), TokenURI("1") as
//     the <img src>, TokenMetadata("1") as JSON with camelCase traitType.
//
// Transfer moves the ticket, so it can reach any Adena account.
package goldenticket

import (
	"errors"
	"strings"

	"gno.land/p/nt/grc721/v0"
)

const (
	tokenName   = "Golden Ticket"
	tokenSymbol = "GOLD"
	ticket      = grc721.TokenID("1")

	// An https PNG, as the planes' images are: the SuperGnome of gnofly, from
	// the Blob store that serves the collection. Adena loads https: and data:
	// images only.
	image = "https://xjfvwq1pdzcznycc.public.blob.vercel-storage.com/planes/777.png"

	errNoTicket = "goldenticket: there is one ticket, id 1"
	errNotOwner = "goldenticket: caller does not hold the ticket"
	errBadOwner = "goldenticket: invalid recipient address"
)

var (
	// Token is the collection, read-only: Token.OwnerOf("1"), Token.BalanceOf.
	Token  *grc721.Token
	ledger *grc721.PrivateLedger
)

// init runs once, when the package is added to the chain. This is the only
// moment cur.Previous() is the publisher, who receives the ticket.
//
// Under `gno test` there is no publisher and the address is empty. The tests
// call bootstrap themselves with a real address.
func init(cur realm) {
	bootstrap(cur.Previous().Address(), cur)
}

// bootstrap creates the collection and mints the ticket to holder; with no
// valid holder, under `gno test`, it mints nothing.
func bootstrap(holder address, rlm realm) {
	Token, ledger = grc721.NewToken(tokenName, tokenSymbol, 0, rlm)
	if !holder.IsValid() {
		return
	}
	if err := ledger.Mint(holder, ticket); err != nil {
		panic(err)
	}
}

// Name and Symbol, as GRC721 tokens have them. Adena reads both from the
// NewToken event.
func Name() string   { return tokenName }
func Symbol() string { return tokenSymbol }

// OwnerOf returns who holds the ticket, or an error for any other id.
func OwnerOf(tid grc721.TokenID) (address, error) {
	if tid != ticket {
		return "", errors.New(errNoTicket)
	}
	return Token.OwnerOf(tid)
}

// BalanceOf returns 1 for the holder of the ticket, 0 for everyone else.
func BalanceOf(addr address) (int64, error) {
	return Token.BalanceOf(addr)
}

// TokenURI returns the image of the ticket: what Adena shows.
func TokenURI(tid grc721.TokenID) (string, error) {
	if _, err := OwnerOf(tid); err != nil {
		return "", err
	}
	return image, nil
}

// TokenMetadata returns the metadata of the ticket as JSON, with the keys
// Adena reads.
func TokenMetadata(tid grc721.TokenID) (string, error) {
	if _, err := OwnerOf(tid); err != nil {
		return "", err
	}
	return `{"name":"` + tokenName + ` #1","description":"A 1/1 on gno.land, minted to check that collections show in Adena.",` +
		`"image":"` + image + `","attributes":[{"traitType":"edition","value":"1 of 1"},{"traitType":"metal","value":"gold"}]}`, nil
}

// Transfer gives the ticket to someone else. Only its holder can, by a
// direct call (maketx call or Adena), not through another realm.
func Transfer(cur realm, to address) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic(errNotOwner)
	}
	if !to.IsValid() {
		panic(errBadOwner)
	}
	holder, err := Token.OwnerOf(ticket)
	if err != nil || holder != caller.Address() {
		panic(errNotOwner)
	}
	if err := ledger.TransferFrom(holder, holder, to, ticket); err != nil {
		panic(err)
	}
}

// Render shows the ticket and who holds it.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# " + tokenName + "\n\n")
	b.WriteString("A 1/1 GRC721 on gno.land, minted to check that collections show in Adena.\n\n")
	b.WriteString("![" + tokenName + "](" + image + ")\n\n")
	holder, err := Token.OwnerOf(ticket)
	if err != nil {
		b.WriteString("Not minted.\n")
		return b.String()
	}
	b.WriteString("Held by `" + holder.String() + "`.\n")
	return b.String()
}
