// Package kylixdemo gives a newcomer something to trade on Kylix within two
// minutes: two GRC20 tokens, Obol and Drachma, registered in grc20reg, and a
// GRC721 collection, Kylix Relics, registered with Kylix. One call to Claim
// hands out some of each.
//
// The tokens have no decimals and no value. Anyone can claim, once per
// ClaimCooldownBlocks per address and at most MaxClaimsPerBlock claims per
// block across everyone.
package kylixdemo

import (
	"chain"
	"chain/runtime"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/nym-kylix000/kylix"
)

const (
	ClaimTokens         = 1000 // of each token, per claim
	ClaimCooldownBlocks = 720  // about an hour at 5 s blocks
	MaxClaimsPerBlock   = 10

	CollectionName = "Kylix Relics"
)

var (
	obol, drachma       *grc20.Token
	obolLed, drachmaLed *grc20.PrivateLedger
	obolKey, drachmaKey string

	relics    *grc721.Token
	relicsLed *grc721.PrivateLedger
	minted    uint64

	selfPath string

	lastClaim     avl.Tree // address -> int64 height of the last claim
	claimHeight   int64    // height that claimsInBlock counts for
	claimsInBlock int
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	obol, obolLed = grc20.NewToken("Obol", "OBOL", 0, 1, cur)
	drachma, drachmaLed = grc20.NewToken("Drachma", "DRACHMA", 0, 2, cur)
	obolKey = grc20reg.Register(cross(cur), obol, "")
	drachmaKey = grc20reg.Register(cross(cur), drachma, "")

	relics, relicsLed = grc721.NewToken(CollectionName, "RELIC", 1, cur)
	kylix.RegisterItem(cross(cur), CollectionName, MoveRelic, RelicOwner)
	kylix.RegisterApprovalCheck(cross(cur), RelicApproved)
}

// Claim gives the caller ClaimTokens Obol, ClaimTokens Drachma and one new
// relic, and returns the relic's id.
func Claim(cur realm) string {
	caller := cur.Previous()
	if !caller.IsUser() {
		panic("kylixdemo: only users can claim")
	}
	who := caller.Address()
	h := runtime.ChainHeight()
	if v := lastClaim.Get(who.String()); v != nil {
		if next := v.(int64) + ClaimCooldownBlocks; h < next {
			panic("kylixdemo: already claimed; claim again from height " + strconv.FormatInt(next, 10))
		}
	}
	if h != claimHeight {
		claimHeight, claimsInBlock = h, 0
	}
	if claimsInBlock >= MaxClaimsPerBlock {
		panic("kylixdemo: the faucet is busy this block; try the next one")
	}
	claimsInBlock++
	lastClaim.Set(who.String(), h)

	check(obolLed.Mint(who, ClaimTokens))
	check(drachmaLed.Mint(who, ClaimTokens))
	minted++
	id := "relic-" + strconv.FormatUint(minted, 10)
	check(relicsLed.Mint(who, grc721.TokenID(id)))
	chain.Emit("Claimed", "to", who.String(), "relic", id)
	return id
}

// CollectionKey is the key Kylix knows the relics by: this realm's path.
func CollectionKey() string { return selfPath }

// TokenKey returns the grc20reg key of "OBOL" or "DRACHMA", which is what
// Kylix's PostIntent takes as a fungible key.
func TokenKey(symbol string) string { return ledgerFor(symbol).key }

// BalanceOf returns addr's balance of "OBOL" or "DRACHMA".
func BalanceOf(symbol string, addr address) int64 { return ledgerFor(symbol).tok.BalanceOf(addr) }

// Allowance returns how much spender may move of owner's "OBOL" or "DRACHMA".
func Allowance(symbol string, owner, spender address) int64 {
	return ledgerFor(symbol).tok.Allowance(owner, spender)
}

// Approve lets spender (typically a Kylix slot) move amount of the caller's
// "OBOL" or "DRACHMA".
func Approve(cur realm, symbol string, spender address, amount int64) {
	check(ledgerFor(symbol).led.CallerTeller().Approve(0, cur, spender, amount))
}

// Transfer sends amount of the caller's "OBOL" or "DRACHMA" to `to`.
func Transfer(cur realm, symbol string, to address, amount int64) {
	check(ledgerFor(symbol).led.CallerTeller().Transfer(0, cur, to, amount))
}

// ApproveRelic lets spender (typically a Kylix slot) move one of the
// caller's relics. Approving the empty address revokes.
func ApproveRelic(cur realm, spender address, id string) {
	check(relicsLed.CallerTeller().Approve(0, cur, spender, grc721.TokenID(id)))
}

// ApproveAllRelics lets operator move all of the caller's relics. Kylix does
// not use such an approval (see MoveRelic); approve one relic per offer.
func ApproveAllRelics(cur realm, operator address, approved bool) {
	check(relicsLed.CallerTeller().SetApprovalForAll(0, cur, operator, approved))
}

// TransferRelic sends one of the caller's relics to `to`.
func TransferRelic(cur realm, to address, id string) {
	who := cur.Previous().Address()
	check(relicsLed.CallerTeller().TransferFrom(0, cur, who, to, grc721.TokenID(id)))
}

// OwnerOfRelic returns the owner of a relic, or the empty address.
func OwnerOfRelic(id string) address { return RelicOwner(kylix.ItemID(id)) }

// MoveRelic is the move function registered with Kylix. Kylix calls it as
// an offer's slot, so cur.Previous() is that slot, and the transfer only
// succeeds if the owner approved that slot for this one relic. An approval
// for all relics is not used: a single-relic approval is cleared by the
// transfer, so its storage deposit is refunded to whoever settles, while an
// operator approval would stay behind (Kylix's rule for collections: an
// approval that Kylix uses must be consumed by the move).
func MoveRelic(cur realm, from, to address, itemID string) error {
	tid := grc721.TokenID(itemID)
	if a, err := relics.GetApproved(tid); err != nil || a != cur.Previous().Address() {
		return errors.New("kylixdemo: approve this offer's address for relic " + itemID + " itself; an approval for all relics is not used")
	}
	return relicsLed.CallerTeller().TransferFrom(0, cur, from, to, tid)
}

// RelicOwner is the owner function registered with Kylix.
func RelicOwner(id kylix.ItemID) address {
	owner, err := relics.OwnerOf(grc721.TokenID(id))
	if err != nil {
		return ""
	}
	return owner
}

// RelicApproved is the approval check registered with Kylix: whether
// spender is approved for this one relic (see MoveRelic: an approval for all
// relics does not count).
func RelicApproved(id kylix.ItemID, spender address) bool {
	approved, err := relics.GetApproved(grc721.TokenID(id))
	return err == nil && approved != "" && approved == spender
}

// Render shows what the demo offers and how to use it.
func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("# Kylix demo assets\n\n")
	sb.WriteString("Call `Claim` to receive " + strconv.Itoa(ClaimTokens) + " Obol, " + strconv.Itoa(ClaimTokens) +
		" Drachma and one Kylix Relic, then trade them on Kylix. One claim per address every " +
		strconv.Itoa(ClaimCooldownBlocks) + " blocks.\n\n")
	sb.WriteString("| Asset | Kylix key | Supply |\n|---|---|---|\n")
	sb.WriteString("| Obol (fungible) | " + obolKey + " | " + strconv.FormatInt(obol.TotalSupply(), 10) + " |\n")
	sb.WriteString("| Drachma (fungible) | " + drachmaKey + " | " + strconv.FormatInt(drachma.TotalSupply(), 10) + " |\n")
	sb.WriteString("| " + CollectionName + " (items) | " + selfPath + " | " + strconv.FormatInt(relics.TotalSupply(), 10) + " |\n")
	return sb.String()
}

type tokenRef struct {
	tok *grc20.Token
	led *grc20.PrivateLedger
	key string
}

func ledgerFor(symbol string) tokenRef {
	switch symbol {
	case "OBOL":
		return tokenRef{obol, obolLed, obolKey}
	case "DRACHMA":
		return tokenRef{drachma, drachmaLed, drachmaKey}
	}
	panic("kylixdemo: unknown token " + strconv.Quote(symbol) + "; use OBOL or DRACHMA")
}

func check(err error) {
	if err != nil {
		panic("kylixdemo: " + err.Error())
	}
}
