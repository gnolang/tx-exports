// Package goldenticket is a 1/1 GRC721 NFT: one golden ticket, minted to the
// publisher when the package is added. It checks that a gno.land collection
// shows in the Adena wallet, built the way gnofly's planes are:
//
//   - the collection is a gno.land/p/nt/grc721/v0 token made with NewToken,
//     whose NewToken and Transfer events Adena finds on its indexer;
//   - the read functions take a grc721.TokenID and return (value, error), as
//     Adena calls them: OwnerOf("1"), BalanceOf("g1..."), TokenURI("1") as
//     the <img src>, TokenMetadata("1") as JSON with camelCase traitType.
//
// v2 of goldenticket: the image is no longer a constant. The publisher is
// the admin and moves it with SetImage, as the planes' SetImageBase does, so
// it can live where both Adena (any https: image) and gno.land's pages (an
// allowlist: GitHub, imgur, IPFS) load it.
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

	// The gno icon from gnolang/workshops, served by raw.githubusercontent.com:
	// gno.land's content policy allows *.githubusercontent.com images.
	defaultImage = "https://raw.githubusercontent.com/gnolang/workshops/main/assets/gno-icon-white.png"

	errNoTicket = "goldenticket: there is one ticket, id 1"
	errNotOwner = "goldenticket: caller does not hold the ticket"
	errBadOwner = "goldenticket: invalid recipient address"
	errNotAdmin = "goldenticket: caller is not the admin"
	errBadImage = "goldenticket: image must be an https URL, 12 to 300 characters of [A-Za-z0-9./_-:?=&%~+]"
)

var (
	// Token is the collection, read-only: Token.OwnerOf("1"), Token.BalanceOf.
	Token  *grc721.Token
	ledger *grc721.PrivateLedger

	admin address // the publisher: the only one who sets the image
	image string  // what TokenURI returns, and Render and TokenMetadata show
)

// init runs once, when the package is added to the chain. This is the only
// moment cur.Previous() is the publisher, who receives the ticket and is the
// admin.
//
// Under `gno test` there is no publisher and the address is empty. The tests
// call bootstrap themselves with a real address.
func init(cur realm) {
	bootstrap(cur.Previous().Address(), cur)
}

// bootstrap creates the collection and mints the ticket to publisher; with
// no valid publisher, under `gno test`, it mints nothing.
func bootstrap(publisher address, rlm realm) {
	Token, ledger = grc721.NewToken(tokenName, tokenSymbol, 0, rlm)
	admin = publisher
	image = defaultImage
	if !publisher.IsValid() {
		return
	}
	if err := ledger.Mint(publisher, ticket); err != nil {
		panic(err)
	}
}

// Name and Symbol, as GRC721 tokens have them. Adena reads both from the
// NewToken event.
func Name() string   { return tokenName }
func Symbol() string { return tokenSymbol }

// Admin returns who may set the image.
func Admin() address { return admin }

// Image returns the current image URL.
func Image() string { return image }

// SetImage points the ticket at another image, at once: TokenURI is computed
// on every read. Admin only, by a direct call.
func SetImage(cur realm, url string) {
	caller := cur.Previous()
	if !caller.IsUserCall() || caller.Address() != admin {
		panic(errNotAdmin)
	}
	if !validImage(url) {
		panic(errBadImage)
	}
	image = url
}

// validImage reports whether s is an https URL of 12 to 300 characters of
// [A-Za-z0-9./_-:?=&%~+]. The charset keeps it safe in JSON and markdown
// without escaping: no quote, bracket, parenthesis, space or backslash.
func validImage(s string) bool {
	if len(s) < 12 || len(s) > 300 || !strings.HasPrefix(s, "https://") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') &&
			!strings.ContainsRune("./_-:?=&%~+", rune(c)) {
			return false
		}
	}
	return true
}

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
