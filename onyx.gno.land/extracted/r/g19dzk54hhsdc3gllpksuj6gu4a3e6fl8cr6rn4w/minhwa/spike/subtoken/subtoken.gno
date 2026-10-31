// Package subtoken is spikes (b) and (c) of tasarim-v6 §5.5:
//
//	(b) a grc721 token created with a sub-realm identity cur.Sub("c/1"):
//	    does NewToken accept it, what is Token.ID(), and can the host spend
//	    coins that land on a sub-address ("roy/1") with a banker bound to
//	    cur.Sub("roy/1")?
//	(c) a grc721 Extension that vetoes every transfer and burn until a
//	    reveal flag flips, while mints keep working.
//
// One token, one collection, no owner: anyone may call every function.
// Never part of the product.
package subtoken

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"
)

const (
	tokenSub   = "c/1"
	royaltySub = "roy/1"
	royaltyBps = 500
)

// lockExt is declared in this realm, so its hooks run with this realm's
// authority (borrow rule #1) even when another realm moves the token
// through a RealmTeller.
type lockExt struct {
	revealed bool
	moves    int
}

func (e *lockExt) ExtensionKind() string { return "spike-lock" }

func (e *lockExt) OnMint(to address, tid grc721.TokenID) {}

func (e *lockExt) OnTransfer(from, to address, tid grc721.TokenID) {
	if !e.revealed {
		panic("spike-lock: transfers are locked until reveal")
	}
	e.moves++
}

func (e *lockExt) OnBurn(tid grc721.TokenID) {
	if !e.revealed {
		panic("spike-lock: burns are locked until reveal")
	}
}

var (
	tok     *grc721.Token
	ledger  *grc721.PrivateLedger
	roy     *royalty.Royalty
	lock    = &lockExt{}
	nextTID int64 = 1
)

// Create builds the token once. The rlm handed to NewToken is a sub-realm
// token, so the hypothesis is Token.ID() == "<this pkgpath>#c/1.SPK.<seq>".
func Create(cur realm) string {
	if tok != nil {
		panic("already created")
	}
	t, led := grc721.NewToken("Spike", "SPK", 1, cur.Sub(tokenSub))
	led.RegisterExtension(lock)
	r, royLed := royalty.NewRoyalty(led, 1000)
	if err := royLed.SetDefaultRoyalty(chain.DerivePkgSubAddr(cur.PkgPath(), royaltySub), royaltyBps); err != nil {
		panic(err)
	}
	tok, ledger, roy = t, led, r
	return tok.ID()
}

// Mint mints the next token to the caller; allowed while locked.
func Mint(cur realm) string {
	mustCreated()
	tid := strconv.FormatInt(nextTID, 10)
	nextTID++
	if err := ledger.Mint(cur.Previous().Address(), grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	return tid
}

func Approve(cur realm, tid string, to address) {
	mustCreated()
	if err := ledger.Approve(cur.Previous().Address(), to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}

func Transfer(cur realm, tid string, to address) {
	mustCreated()
	caller := cur.Previous().Address()
	if err := ledger.TransferFrom(caller, caller, to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}

func Burn(cur realm, tid string) {
	mustCreated()
	owner, err := tok.OwnerOf(grc721.TokenID(tid))
	if err != nil {
		panic(err)
	}
	if owner != cur.Previous().Address() {
		panic("only the owner can burn")
	}
	if err := ledger.Burn(grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}

// Reveal lifts the lock forever.
func Reveal(cur realm) {
	lock.revealed = true
}

// Sweep spends the whole roy/1 sub-treasury to `to` with a banker bound to
// the sub-realm identity (interrealm v2 §5.5 example).
func Sweep(cur realm, to address) int64 {
	sub := cur.Sub(royaltySub)
	bal := banker.NewReadonlyBanker().GetCoin(sub.Address(), "ugnot")
	if bal > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, sub).
			SendCoins(sub.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", bal)))
	}
	return bal
}

// --- reads -----------------------------------------------------------------

func Token() *grc721.Token { return tok }

func TokenID() string {
	mustCreated()
	return tok.ID()
}

func OwnerOf(tid string) (address, error) {
	mustCreated()
	return tok.OwnerOf(grc721.TokenID(tid))
}

func Moves() int { return lock.moves }

func IsRevealed() bool { return lock.revealed }

// RoyaltyAddress is computed without cur, the way an off-chain tool or
// another realm would; it must equal the receiver stored in the royalty.
func RoyaltyAddress() address {
	return chain.DerivePkgSubAddr("gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/spike/subtoken", royaltySub)
}

func RoyaltyInfo(tid string, price int64) (address, int64, error) {
	mustCreated()
	return roy.RoyaltyInfo(grc721.TokenID(tid), price)
}

func RoyaltyBalance() int64 {
	return banker.NewReadonlyBanker().GetCoin(RoyaltyAddress(), "ugnot")
}

// Render also answers spike §5.5-6: does gnoweb display a data: SVG image?
func Render(path string) string {
	out := "# spike/subtoken\n\n"
	if tok == nil {
		return out + "not created yet\n"
	}
	out += "- token id: `" + tok.ID() + "`\n"
	out += "- revealed: " + strconv.FormatBool(lock.revealed) + ", moves: " + strconv.Itoa(lock.moves) + "\n"
	out += "- royalty address: `" + RoyaltyAddress().String() + "`\n\n"
	out += "![data-uri test](data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2NCA2NCI+PHJlY3Qgd2lkdGg9IjY0IiBoZWlnaHQ9IjY0IiBmaWxsPSIjMGI3Ii8+PC9zdmc+)\n"
	return out
}

func mustCreated() {
	if tok == nil {
		panic("call Create first")
	}
}
