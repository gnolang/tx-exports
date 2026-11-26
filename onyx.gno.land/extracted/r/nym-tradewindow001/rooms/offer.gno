package rooms

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// Offers: a room that completes in one transaction.
//
// The maker puts their side in as usual, then calls Offer with the exact
// list of what they want in return. That locks the maker's side on the new
// version. Whoever may take the other seat (the invited account, or anyone
// when the seat is open) calls Fill naming the version they reviewed and
// putting in exactly the wanted list: coins attached to the call, tokens
// and NFTs approved to this realm beforehand (the app sends the approvals
// and Fill in one transaction). Fill takes the seat, moves the wanted
// assets in and settles the room before it returns. Nothing partial: a
// wrong coin, a missing approval or a changed room fails the whole call.
//
// The maker can withdraw the offer at any time: Unlock, any deposit or
// withdrawal, or Cancel. Every change to the room clears it, and Fill names
// the version, so an offer can never be filled on terms the taker did not
// see. While an offer stands, Join is refused, so nobody can block an open
// offer by taking its seat without filling it.

// Offer turns the room into an offer for exactly want, on the room as it is
// at version. want lists one asset per line, at most 8:
//
//	coin <amount> <denom>
//	token <amount> <grc20reg key>
//	nft 1 <collection key>#<token id>
//
// Amounts are in base units. Returns the new version, which the taker
// fills.
func Offer(cur realm, roomID uint64, version uint64, want string) uint64 {
	who := callerOf(cur)
	refuseCoins(cur)
	assertNotPaused()

	r := mustRoom(roomID)
	r.assertLive()
	if who != r.maker.owner {
		panic("only the maker can make an offer")
	}
	if version != r.version {
		panic("the room changed: review version " + idString(r.version) + " and offer again")
	}
	if len(r.maker.assets) == 0 {
		panic("put something in before you make an offer")
	}
	if len(r.taker.assets) > 0 {
		panic("they have already put something in: agree in the room instead")
	}
	items := parseWant(want)
	for _, a := range items {
		r.assertAccepts(a.kind, a.denom)
	}
	r.assertStillVerified()

	r.bump()
	r.want = items
	r.maker.locked = r.version

	chain.Emit("Offered",
		"id", idString(r.id),
		"version", idString(r.version),
		"want", wantString(items),
	)
	return r.version
}

// Fill completes an offer: the caller takes the other seat, puts in exactly
// what the offer wants, and the room settles in this call. version is the
// version the caller reviewed. Coins in the offer must be attached to this
// call, from the caller's own account.
func Fill(cur realm, roomID uint64, version uint64) {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	prev := cur.Previous()
	who := prev.Address()
	assertNotPaused()

	r := mustRoom(roomID)
	r.assertLive()
	if len(r.want) == 0 {
		panic("this room has no standing offer")
	}
	if version != r.version {
		panic("the offer changed: review version " + idString(r.version) + " and fill again")
	}
	if r.maker.locked != r.version {
		panic("the offer is withdrawn")
	}
	if who == r.maker.owner {
		panic("you made this offer")
	}
	if r.taker.owner != "" && r.taker.owner != who {
		panic("this offer is for another account")
	}
	if r.taker.owner == "" && !r.openSeat {
		panic("this offer is for another account")
	}
	if len(r.taker.assets) > 0 {
		panic("this room is not an offer any more")
	}
	r.assertStillVerified()

	// Coins can only arrive with a direct call from the signing account,
	// and they must be exactly the wanted coins: no more, no less, no other.
	var sent chain.Coins
	if prev.IsUserCall() {
		sent = unsafe.OriginSend()
	}
	wantCoins := chain.Coins{}
	for _, a := range r.want {
		if a.kind == KindCoin {
			wantCoins = append(wantCoins, chain.Coin{Denom: a.denom, Amount: a.amount})
		}
	}
	if len(wantCoins) > 0 && !prev.IsUserCall() {
		panic("send the coins with a direct call from your account")
	}
	if !sameCoins(sent, wantCoins) {
		if len(wantCoins) == 0 {
			panic("this offer does not take coins")
		}
		panic("attach exactly " + wantCoins.String())
	}

	// Say plainly what is missing before anything changes.
	for _, a := range r.want {
		switch a.kind {
		case KindToken:
			tok := grc20reg.Get(a.denom)
			if tok == nil {
				panic("token is not in the GRC20 registry")
			}
			if tok.BalanceOf(who) < a.amount {
				panic("you do not have enough " + tok.GetSymbol())
			}
			if tok.Allowance(who, cur.Address()) < a.amount {
				panic("approve this realm for " + tok.GetSymbol() + " first")
			}
		case KindNFT:
			key, tid, _ := strings.Cut(a.denom, "#")
			col := mustCollection(key)
			if owner, err := col.token.OwnerOf(grc721.TokenID(tid)); err != nil || owner != who {
				panic("you do not own " + col.token.GetName() + " #" + tid)
			}
			if to, err := col.token.GetApproved(grc721.TokenID(tid)); (err != nil || to != cur.Address()) && !col.token.IsApprovedForAll(who, cur.Address()) {
				panic("approve this realm for " + col.token.GetName() + " #" + tid + " first")
			}
		}
	}

	// Hold the room while the wanted assets move in: an NFT's transfer runs
	// its issuer's code, and nothing that code calls may change this room.
	r.status = statusFilling
	for _, a := range r.want {
		switch a.kind {
		case KindToken:
			grc20reg.TransferFrom(0, cur, a.denom, who, cur.Address(), a.amount)
		case KindNFT:
			key, tid, _ := strings.Cut(a.denom, "#")
			col := mustCollection(key)
			if err := col.token.RealmTeller(0, cur).TransferFrom(0, cur, who, cur.Address(), grc721.TokenID(tid)); err != nil {
				panic(err.Error())
			}
		}
	}

	// Everything is in custody: record the taker's side and swap.
	r.status = StatusOpen
	if r.taker.owner == "" {
		r.taker.owner = who
		index(who, r.id)
	}
	r.taker.assets = append([]asset{}, r.want...)
	r.taker.locked = r.version
	r.want = nil

	chain.Emit("Filled",
		"id", idString(r.id),
		"taker", who.String(),
		"version", idString(r.version),
	)
	r.settle(cur, who)
}

// parseWant reads an offer's want list; see Offer.
func parseWant(want string) []asset {
	items := []asset{}
	for _, line := range strings.Split(want, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		kind, rest, ok := strings.Cut(line, " ")
		if !ok {
			panic("each line of the want list is: kind amount denom")
		}
		amountText, denom, ok := strings.Cut(strings.TrimSpace(rest), " ")
		denom = strings.TrimSpace(denom)
		if !ok || denom == "" {
			panic("each line of the want list is: kind amount denom")
		}
		amount, err := strconv.ParseInt(amountText, 10, 64)
		if err != nil || amount <= 0 {
			panic("want amounts must be positive whole numbers of base units")
		}
		switch kind {
		case KindCoin:
			assertDenom(denom)
		case KindToken:
			if grc20reg.Get(denom) == nil {
				panic("token is not in the GRC20 registry: " + denom)
			}
		case KindNFT:
			key, tid, ok := strings.Cut(denom, "#")
			if !ok {
				panic("an NFT is written as collection key#token id")
			}
			col := mustCollection(key)
			assertTokenID(tid)
			if _, err := col.token.OwnerOf(grc721.TokenID(tid)); err != nil {
				panic("that NFT does not exist: " + denom)
			}
			if amount != 1 {
				panic("an NFT is wanted whole: amount 1")
			}
		default:
			panic("unknown kind in the want list: " + kind)
		}
		for _, a := range items {
			if a.kind == kind && a.denom == denom {
				panic("the want list names " + denom + " twice")
			}
		}
		if len(items) >= MaxAssetsPerSide {
			panic("an offer can want at most 8 different assets")
		}
		items = append(items, asset{kind: kind, denom: denom, amount: amount})
	}
	if len(items) == 0 {
		panic("say what you want in return")
	}
	return items
}

// wantString writes a want list back in Offer's format.
func wantString(items []asset) string {
	lines := make([]string, 0, len(items))
	for _, a := range items {
		lines = append(lines, a.kind+" "+strconv.FormatInt(a.amount, 10)+" "+a.denom)
	}
	return strings.Join(lines, "\n")
}

// assertDenom accepts bank denoms: 3 to 128 characters of lowercase
// letters, digits and / : . _ -, starting with a letter.
func assertDenom(d string) {
	if len(d) < 3 || len(d) > 128 {
		panic("not a coin denom: " + d)
	}
	for i, c := range d {
		ok := c >= 'a' && c <= 'z' || i > 0 && (c >= '0' && c <= '9' || c == '/' || c == ':' || c == '.' || c == '_' || c == '-')
		if !ok {
			panic("not a coin denom: " + d)
		}
	}
}

// sameCoins reports whether a and b hold the same amount of every denom.
func sameCoins(a, b chain.Coins) bool {
	total := func(cs chain.Coins) map[string]int64 {
		m := map[string]int64{}
		for _, c := range cs {
			if c.Amount != 0 {
				m[c.Denom] += c.Amount
			}
		}
		return m
	}
	ma, mb := total(a), total(b)
	if len(ma) != len(mb) {
		return false
	}
	for d, n := range ma {
		if mb[d] != n {
			return false
		}
	}
	return true
}
