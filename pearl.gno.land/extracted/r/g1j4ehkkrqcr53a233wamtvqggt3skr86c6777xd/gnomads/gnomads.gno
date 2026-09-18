package gnomads

import (
	"gno.land/p/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads/grc721/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	collectionName   = "Gnomads"
	collectionSymbol = "GNOMADS"
	maxSupply        = int64(3333)
	maxMintBatch     = 20
)

// localAdmin is the standard prefunded gnodev account. It is intentionally
// limited to local development and must be replaced by the deployment owner
// before Pearl or Mainnet deployment.
const localAdmin address = "g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd"

var (
	token        *grc721.Token
	ledger       *grc721.PrivateLedger
	callerTeller grc721.Teller
)

func init(cur realm) {
	token, ledger = grc721.NewToken(collectionName, collectionSymbol, 0, cur)
	callerTeller = ledger.CallerTeller()
	attachExtensions(ledger)
}

// Collection getters.

func Status() string { return "REVEAL_ENGINE_READY" }

func Name() string { return token.GetName() }

func Symbol() string { return token.GetSymbol() }

func CollectionID() string { return token.ID() }

func TotalSupply() int64 { return token.TotalSupply() }

func MaxSupply() int64 { return maxSupply }

func Admin() address { return localAdmin }

// GRC-721 read facade.

func BalanceOf(owner address) int64 {
	balance, err := token.BalanceOf(owner)
	if err != nil {
		panic(err)
	}
	return balance
}

func OwnerOf(tokenID string) address {
	owner, err := token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}
	return owner
}

func GetApproved(tokenID string) address {
	approved, err := token.GetApproved(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}
	return approved
}

func IsApprovedForAll(owner, operator address) bool {
	return token.IsApprovedForAll(owner, operator)
}

// GRC-721 write facade. CallerTeller derives the acting account from the
// current cross-realm frame and keeps the PrivateLedger inside this realm.

func Approve(cur realm, to address, tokenID string) {
	if err := callerTeller.Approve(0, cur, to, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	if err := callerTeller.SetApprovalForAll(0, cur, operator, approved); err != nil {
		panic(err)
	}
}

func TransferFrom(cur realm, from, to address, tokenID string) {
	if cur.Previous().Address() != from {
		panic("gnomads: operator transfers require marketplace settlement")
	}
	if err := callerTeller.TransferFrom(0, cur, from, to, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
}

// AdminMint is for reserve/local-development minting and is permanently locked
// after the first sale activation to prevent post-sale rare-token allocation.
func AdminMint(cur realm, to address, quantity int) {
	assertAdmin(cur.Previous().Address())
	assertMintingAllowed()
	if !salePaused || allowlistRootLocked {
		panic("gnomads: admin mint is locked after sale activation")
	}
	mintTokens(to, quantity)
}

func mintTokens(to address, quantity int) {
	assertMintingAllowed()
	assertMintQuantity(quantity)
	if token.TotalSupply()+int64(quantity) > maxSupply {
		panic("gnomads: max supply reached")
	}
	for i := 0; i < quantity; i++ {
		nextID := token.TotalSupply() + 1
		tokenID := grc721.TokenID(ufmt.Sprintf("%d", nextID))
		if err := ledger.Mint(to, tokenID); err != nil {
			panic(err)
		}
		setInitialTokenURI(tokenID)
	}
}

func Render(path string) string {
	if path != "" {
		return "404\n"
	}

	out := token.RenderHome()
	out += ufmt.Sprintf("* **Maximum supply**: %d\n", maxSupply)
	out += ufmt.Sprintf("* **Sale phase**: %s\n", SalePhase())
	out += ufmt.Sprintf("* **Sale paused**: %t\n", SalePaused())
	out += ufmt.Sprintf("* **Status**: %s\n", Status())
	return out
}

func assertAdmin(caller address) {
	if !isAdmin(caller) {
		panic("gnomads: restricted access")
	}
}

func isAdmin(caller address) bool {
	return caller == localAdmin
}

func assertMintQuantity(quantity int) {
	if !validMintQuantity(quantity) {
		panic(ufmt.Sprintf("gnomads: quantity must be between 1 and %d", maxMintBatch))
	}
}

func validMintQuantity(quantity int) bool {
	return quantity >= 1 && quantity <= maxMintBatch
}
