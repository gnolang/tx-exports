package planes

import (
	"chain"
	"chain/banker"
	"errors"

	// Only for OriginSend, in Mint. Caller identity always comes from
	// cur.Previous(), never from this package.
	"chain/runtime/unsafe"

	"gno.land/p/nt/grc721/v0"
	"gno.land/p/onbloc/json/v0"
)

// maxBatch is the most planes one Mint call mints. It is a constant, apart
// from the per-wallet cap that admins tune with SetMintCap.
const maxBatch = int64(7)

// Mint mints count planes for the caller, 1 to 7 in one call, drawn at
// random among the ids not minted yet (draw.gno), and returns their ids in
// the order drawn. Exactly
// count times the price must be attached to the transaction (-send
// "<count*price>ugnot"); it is forwarded to the treasury of the game realm,
// in one send, before the call returns.
//
// Each id comes out once, while the mint is open. A batch is
// minted whole or not at all: one that would take the caller over the
// per-wallet cap, or past the last plane, is refused with how many are left.
// It must be called directly by a user (maketx call): a call relayed by
// another realm or by a maketx run script is refused. That is also what
// keeps the draw fair: a contract could otherwise look at the ids it got
// and panic to draw again.
//
// The caller pays the storage of their planes as a deposit on top of the
// price, given back on burn: the ledger entries only, the traits stay in the
// table (see the numbers in docs/spec.md, section 9.2).
func Mint(cur realm, count int64) []int64 {
	minter := callerOf(0, cur)

	// Paid-call guard: two checks that are only correct together.
	//
	// (a) The caller is a plain user account. Only then is the -send
	//     envelope guaranteed to have landed at this realm's address. A
	//     relaying realm or a maketx run script can attach coins to the
	//     transaction and keep them, while OriginSend still reports them.
	if !cur.Previous().IsUserCall() {
		panic(errNotUserCall)
	}
	if count < 1 || count > maxBatch {
		panic(errInvalidCount)
	}
	if !mintOpen {
		panic(errMintClosed)
	}
	if n := left(); n < 1 {
		panic(errSoldOut)
	} else if count > n {
		panic("gnofly: only " + itoa(n) + " planes are left to mint")
	}
	if left := mintCap - mintedBy(minter); left < 1 {
		panic(errCapReached)
	} else if count > left {
		panic("gnofly: this wallet can mint " + itoa(left) + " more planes, the cap is " + itoa(mintCap))
	}

	// (b) The envelope is exactly count times the price: one coin, the right
	//     denom, the right amount. Anything else would either underpay or
	//     leave coins behind in the realm.
	total := count * price
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != payDenom || sent[0].Amount != total {
		panic("gnofly: wrong payment, send exactly " + itoa(total) + payDenom)
	}

	// Forward the payment right away, so that nothing accrues in the realm.
	// An OriginSend banker can spend the envelope of this call and nothing
	// else.
	treasury := roles.Treasury()
	payment := chain.NewCoins(chain.NewCoin(payDenom, total))
	banker.NewBanker(banker.BankerTypeOriginSend, cur).SendCoins(cur.Address(), treasury, payment)

	ids := make([]int64, 0, count)
	for i := int64(0); i < count; i++ {
		p := mustPlane(drawID(minter))
		mintCount++
		ids = append(ids, p.id)
		copy(recent[1:], recent[:len(recent)-1])
		recent[0] = p.id
		if err := ledger.Mint(minter, tokenID(p.id)); err != nil {
			panic(err)
		}
		tierMinted[tierIndex(p.tier)]++
		chain.Emit("PlaneMinted",
			"id", itoa(p.id),
			"minter", minter.String(),
			"price", itoa(price),
			"treasury", treasury.String(),
		)
	}
	mints.Set(minter.String(), mintedBy(minter)+count)
	return ids
}

// mintedBy returns how many planes addr minted so far.
func mintedBy(addr address) int64 {
	v := mints.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// The read functions a wallet calls take a grc721.TokenID and return an
// error rather than panic, the way Adena calls them: OwnerOf("42") into two
// values, TokenURI("42") as the image it shows, TokenMetadata("42") as JSON
// for the traits. The errors are made on the call, not stored: a stored
// error value costs a kilobyte of deposit (see errors.gno).

// TokenMetadata returns the metadata of a minted plane as JSON, built from
// the table on every read: the realm stores no metadata per token.
//
//	{"name":"Storm Saint","description":"Plane 42 of 777, ...",
//	 "image":"https://gnofly.xyz/nft/collections/planes/042.png",
//	 "attributes":[{"traitType":"model","value":"delta"}, ...]}
//
// The keys are the ones Adena reads, traitType included.
func TokenMetadata(tid grc721.TokenID) (string, error) {
	id, err := mintedID(tid)
	if err != nil {
		return "", err
	}
	p := mustPlane(id)
	b := json.Builder().
		WriteString("name", p.name).
		WriteString("description", description(p)).
		WriteString("image", imageURL(id)).
		WriteArray("attributes", func(ab *json.ArrayBuilder) {
			for _, t := range [][2]string{
				{"model", p.model}, {"pilot", p.pilot}, {"body", p.body}, {"wing", p.wing},
				{"accent", p.accent}, {"tier", p.tier}, {"laser", p.laser},
			} {
				ab.WriteObject(func(o *json.NodeBuilder) {
					o.WriteString("traitType", t[0]).WriteString("value", t[1])
				})
			}
		})
	return encode(b.Node()), nil
}

// mintedID reads a token id, "1" to "777", and checks the plane is minted.
func mintedID(tid grc721.TokenID) (int64, error) {
	id := parseID(string(tid))
	if ownerOf(id) == "" {
		return 0, errors.New(errNotMinted)
	}
	return id, nil
}

// parseID reads "1" to "777" in decimal, 0 for anything else.
func parseID(s string) int64 {
	if len(s) == 0 || len(s) > 3 || s[0] == '0' {
		return 0
	}
	n := int64(0)
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
		n = n*10 + int64(s[i]-'0')
	}
	if n > supply {
		return 0
	}
	return n
}

// description is one sentence about a plane: "Plane 42 of 777, an epic delta
// flown by a gnome." The tier is the only word that may start with a vowel.
func description(p plane) string {
	article := "a "
	if p.tier == "epic" {
		article = "an "
	}
	s := "Plane " + itoa(p.id) + " of " + itoa(supply) + ", " + article + p.tier + " " + p.model
	if p.pilot == "gnome" {
		s += " flown by a gnome"
	}
	return s + "."
}

// Burn destroys a plane. Only its owner can, and nobody can mint it again:
// the id stays out of circulation.
func Burn(cur realm, id int64) {
	caller := callerOf(0, cur)
	if ownerOf(id) != caller {
		panic(errNotPlaneOwner)
	}
	if err := ledger.Burn(tokenID(id)); err != nil {
		panic(err)
	}
	chain.Emit("PlaneBurned", "id", itoa(id), "owner", caller.String())
}

// The GRC721 transfer surface. These wrappers hand cur to the caller-scoped
// teller, which acts as cur.Previous() and applies it to the private ledger:
// a caller moves their own planes and the ones they were approved for,
// nothing else. See p/nt/grc721/v0/tellers.gno.

// TransferFrom moves plane id from one address to another. The caller must
// own it or be approved for it.
func TransferFrom(cur realm, from, to address, id int64) {
	if err := teller.TransferFrom(0, cur, from, to, tokenID(id)); err != nil {
		panic(err)
	}
}

// Approve lets to move plane id once. The caller must own it. An empty
// address revokes.
func Approve(cur realm, to address, id int64) {
	if err := teller.Approve(0, cur, to, tokenID(id)); err != nil {
		panic(err)
	}
}

// SetApprovalForAll lets operator move every plane of the caller, or
// revokes it.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	if err := teller.SetApprovalForAll(0, cur, operator, approved); err != nil {
		panic(err)
	}
}

// ownerOf returns who owns plane id, or "" when it is not minted.
func ownerOf(id int64) address {
	if id < 1 || id > supply {
		return ""
	}
	owner, err := Token.OwnerOf(tokenID(id))
	if err != nil {
		return ""
	}
	return owner
}

// OwnerOf returns who owns plane tid, or an error when it is not minted.
func OwnerOf(tid grc721.TokenID) (address, error) {
	id, err := mintedID(tid)
	if err != nil {
		return "", err
	}
	return ownerOf(id), nil
}

// BalanceOf returns how many planes addr owns.
func BalanceOf(addr address) (int64, error) {
	return Token.BalanceOf(addr)
}

// TotalSupply returns how many planes exist: minted and not burned.
func TotalSupply() int64 {
	return Token.TotalSupply()
}

// GetApproved returns the address approved to move plane id, or "" when
// there is none.
func GetApproved(id int64) address {
	addr, err := Token.GetApproved(tokenID(id))
	if err == grc721.ErrTokenIdNotApproved {
		return ""
	}
	if err != nil {
		panic(err)
	}
	return addr
}

// IsApprovedForAll reports whether operator may move every plane of owner.
func IsApprovedForAll(owner, operator address) bool {
	return Token.IsApprovedForAll(owner, operator)
}

// TokenURI returns the image of a minted plane, "<image base><nnn>.png":
// what a wallet shows (Adena puts it in an <img>). The metadata is
// TokenMetadata, or "<image base><id>.json" on the website. It is computed,
// not stored: a mint writes no URI.
func TokenURI(tid grc721.TokenID) (string, error) {
	id, err := mintedID(tid)
	if err != nil {
		return "", err
	}
	return imageURL(id), nil
}

// RoyaltyInfo returns who receives the royalty on a sale of plane id at
// salePrice, and how much: EIP-2981.
func RoyaltyInfo(id int64, salePrice int64) (address, int64) {
	receiver, amount, err := Royalties.RoyaltyInfo(tokenID(id), salePrice)
	if err != nil {
		panic(err)
	}
	return receiver, amount
}

// RoyaltyBps returns the royalty of a resale, in basis points.
func RoyaltyBps() int64 {
	info, ok := Royalties.DefaultRoyalty()
	if !ok {
		return 0
	}
	return info.Bps
}
