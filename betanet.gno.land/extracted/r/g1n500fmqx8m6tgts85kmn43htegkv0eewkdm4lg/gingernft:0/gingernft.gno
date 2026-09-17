package gingernft
import (
	"chain/runtime"
	"errors"
	"strconv"
	"strings"
	"gno.land/p/nt/ufmt/v0"
)
var nft = NewBasicNFT("Lord Ginge Genesis", "GINGE")
func Mint(_ realm, metadataURI string) string {
	prev := runtime.PreviousRealm()
	require(prev.IsUser(), "Mint from a user wallet only, no intermediary realms.")
	caller := prev.Address()
	require(metadataURI != "", "metadataURI is required.")
	require(len(metadataURI) <= 300000, "metadataURI too long (max 300000 chars).")
	tid := TokenID(strconv.FormatInt(nft.TokenCount()+1, 10))
	checkErr(nft.Mint(caller, tid))
	_, err := nft.SetTokenURI(tid, TokenURI(metadataURI))
	checkErr(err)
	return tid.String()
}
func TransferFrom(_ realm, from, to address, tid string) error {
	require(runtime.PreviousRealm().IsUser(), "user wallets only")
	return nft.TransferFrom(from, to, TokenID(tid))
}
func Approve(_ realm, to address, tid string) error {
	require(runtime.PreviousRealm().IsUser(), "user wallets only")
	return nft.Approve(to, TokenID(tid))
}
func SetApprovalForAll(_ realm, operator address, approved bool) error {
	require(runtime.PreviousRealm().IsUser(), "user wallets only")
	return nft.SetApprovalForAll(operator, approved)
}
func SetTokenURI(_ realm, tid, metadataURI string) error {
	require(runtime.PreviousRealm().IsUser(), "user wallets only")
	require(len(metadataURI) <= 300000, "metadataURI too long (max 300000 chars).")
	_, err := nft.SetTokenURI(TokenID(tid), TokenURI(metadataURI))
	return err
}
func Burn(_ realm, tid string) error {
	prev := runtime.PreviousRealm()
	require(prev.IsUser(), "user wallets only")
	owner, err := nft.OwnerOf(TokenID(tid))
	if err != nil {
		return err
	}
	if owner != prev.Address() {
		return errors.New("only the token owner can burn it")
	}
	return nft.Burn(TokenID(tid))
}
func Name() string      { return nft.Name() }
func Symbol() string    { return nft.Symbol() }
func TokenCount() int64 { return nft.TokenCount() }
func BalanceOf(owner address) (int64, error) { return nft.BalanceOf(owner) }
func OwnerOf(tid string) (address, error)    { return nft.OwnerOf(TokenID(tid)) }
func GetTokenURI(tid string) (string, error) { return nft.TokenURI(TokenID(tid)) }
func Render(path string) string {
	if path != "" {
		return "404 — try the home page."
	}
	var sb strings.Builder
	sb.WriteString("# Lord Ginge Genesis\n\n")
	sb.WriteString(ufmt.Sprintf("Open-mint GRC721 collection · **%d minted**\n\n", nft.TokenCount()))
	sb.WriteString("Mint by calling `Mint(metadataURI)` — the NFT goes straight to your own wallet.\n")
	sb.WriteString("Metadata is stored in each token's URI as `data:application/json;base64,...`.\n\n")
	var i int64
	for i = 1; i <= nft.TokenCount(); i++ {
		tid := strconv.FormatInt(i, 10)
		owner, err := nft.OwnerOf(TokenID(tid))
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
