// Package gingernft is an open-mint GRC721 collection on gno.land.
// Anyone can mint an NFT to their own wallet. Each token's metadata is
// stored as its TokenURI following the standard GRC721/OpenSea pattern:
// a data:application/json;base64,... URI containing a metadata document
// {name, description, image, attributes}. The image itself is usually a
// data:image/...;base64 URI inside that JSON, which makes the whole NFT
// (art + metadata) live fully on-chain with no IPFS or server.
//
// Safety rules:
//   - Minting goes to the caller's own wallet only.
//   - Only a token's owner can change its URI, move it, or burn it.
//   - There is no admin, no owner withdrawal, and no way to take tokens
//     that aren't yours.
package gingernft

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/demo/tokens/grc721"
	"gno.land/p/nt/ufmt/v0"
)

var nft *grc721.BasicNFT

func init(cur realm) {
	nft = grc721.NewBasicNFT(0, cur, "LordG Ginger NFTs", "GNFT")
}

// Mint creates a new NFT owned by the caller.
// metadataURI must be a URI pointing at the token's metadata JSON —
// typically data:application/json;base64,... produced by the minting UI
// (max 300k chars). Plain https:// or ipfs:// URIs also work.
// Returns the new token ID.
func Mint(cur realm, metadataURI string) string {
	require(cur.Previous().IsUser(), "Mint from a user wallet only, no intermediary realms.")
	caller := cur.Previous().Address()
	require(metadataURI != "", "metadataURI is required.")
	require(len(metadataURI) <= 300_000, "metadataURI too long (max 300000 chars).")

	tid := grc721.TokenID(strconv.FormatInt(nft.TokenCount()+1, 10))
	checkErr(nft.Mint(caller, tid))
	_, err := nft.SetTokenURI(caller, tid, grc721.TokenURI(metadataURI))
	checkErr(err)
	return tid.String()
}

// --- write wrappers (GRC721 caller-validation pattern) ---

// TransferFrom moves a token; caller must be owner or approved.
func TransferFrom(cur realm, from, to address, tid string) error {
	require(cur.Previous().IsUser(), "user wallets only")
	return nft.TransferFrom(cur.Previous().Address(), from, to, grc721.TokenID(tid))
}

// Approve approves another address to move a token.
func Approve(cur realm, to address, tid string) error {
	require(cur.Previous().IsUser(), "user wallets only")
	return nft.Approve(cur.Previous().Address(), to, grc721.TokenID(tid))
}

// SetApprovalForAll approves or revokes an operator for all caller's tokens.
func SetApprovalForAll(cur realm, operator address, approved bool) error {
	require(cur.Previous().IsUser(), "user wallets only")
	return nft.SetApprovalForAll(cur.Previous().Address(), operator, approved)
}

// SetTokenURI updates a token's metadata URI. Owner only.
func SetTokenURI(cur realm, tid, metadataURI string) error {
	require(cur.Previous().IsUser(), "user wallets only")
	require(len(metadataURI) <= 300_000, "metadataURI too long (max 300000 chars).")
	_, err := nft.SetTokenURI(cur.Previous().Address(), grc721.TokenID(tid), grc721.TokenURI(metadataURI))
	return err
}

// Burn destroys a token the caller owns.
func Burn(cur realm, tid string) error {
	require(cur.Previous().IsUser(), "user wallets only")
	owner, err := nft.OwnerOf(grc721.TokenID(tid))
	if err != nil {
		return err
	}
	if owner != cur.Previous().Address() {
		return errors.New("only the token owner can burn it")
	}
	return nft.Burn(grc721.TokenID(tid))
}

// --- read-only views (queryable via gnokey/qeval and the UI) ---

func Name() string      { return nft.Name() }
func Symbol() string    { return nft.Symbol() }
func TokenCount() int64 { return nft.TokenCount() }

func BalanceOf(owner address) (int64, error) { return nft.BalanceOf(owner) }
func OwnerOf(tid string) (address, error)    { return nft.OwnerOf(grc721.TokenID(tid)) }
func TokenURI(tid string) (string, error)    { return nft.TokenURI(grc721.TokenID(tid)) }

// --- gnoweb page ---

// Render lists minted tokens. Metadata JSON lives in each TokenURI;
// this page shows IDs and owners, with a hint per token.
func Render(path string) string {
	if path != "" {
		return "404 — try the home page."
	}
	var sb strings.Builder
	sb.WriteString("# LordG Ginger NFTs\n\n")
	sb.WriteString(ufmt.Sprintf("Open-mint GRC721 collection · **%d minted**\n\n", nft.TokenCount()))
	sb.WriteString("Mint by calling `Mint(metadataURI)` — the NFT goes straight to your own wallet.\n")
	sb.WriteString("Metadata is stored in each token's URI as `data:application/json;base64,...`.\n\n")
	var i int64
	for i = 1; i <= nft.TokenCount(); i++ {
		tid := strconv.FormatInt(i, 10)
		owner, err := nft.OwnerOf(grc721.TokenID(tid))
		if err != nil {
			continue
		}
		sb.WriteString(ufmt.Sprintf("- **#%s** — owner `%s`\n", tid, owner.String()))
	}
	return sb.String()
}

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
