package arena

import (
	"chain"
	"strings"
)

// Winnings are not sent when a game settles. They are credited to each
// winner, stay in the escrow, and the winner takes them with Claim, every
// game at once. A settlement then moves no coin to a player, and a player
// who never comes back costs nobody anything.
//
// Refunds (Leave, CancelRound, RefundRound, ExpireLobby) still send the
// stakes back straight away: a refund is not a win.

// claimCredit is what one game owes one player.
type claimCredit struct {
	id     string
	amount int64
}

// The credits of a player are stored as one string, oldest first:
//
//	<arena id>:<amount>,<arena id>:<amount>

func creditsOf(addr address) []claimCredit {
	v := claims.Get(addr.String())
	if v == nil {
		return nil
	}
	var out []claimCredit
	for _, entry := range strings.Split(v.(string), ",") {
		colon := indexFrom(entry, 0, ':')
		if colon == 0 || colon == len(entry) {
			panic(errCorruptClaims)
		}
		amount, ok := digits(entry[colon+1:])
		if !ok || amount <= 0 {
			panic(errCorruptClaims)
		}
		out = append(out, claimCredit{id: entry[:colon], amount: amount})
	}
	return out
}

// credit owes amount to a player for the game of an arena. The coins are
// already in the realm: they stay in the escrow until claimed.
func credit(addr address, id string, amount int64) {
	if amount <= 0 {
		return
	}
	entry := id + ":" + itoa(amount)
	if v := claims.Get(addr.String()); v != nil {
		entry = v.(string) + "," + entry
	}
	claims.Set(addr.String(), entry)
	hold(amount)
}

// Claim sends the caller everything the realm owes them from settled
// games, and returns the amount in ugnot. It panics when there is nothing
// to claim.
func Claim(cur realm) int64 {
	player := callerOf(0, cur)
	list := creditsOf(player)
	if len(list) == 0 {
		panic(errNothingToClaim)
	}
	total := int64(0)
	for _, c := range list {
		total += c.amount
	}
	// State first: nothing is owed any more before the coins leave.
	claims.Remove(player.String())
	release(total)
	pay(0, cur, player, total)
	assertSolvent(0, cur)
	chain.Emit("Claimed", "player", player.String(), "amount", itoa(total), "games", itoa(int64(len(list))))
	return total
}

// Claimable returns what a player can claim, in ugnot.
func Claimable(addr address) int64 {
	total := int64(0)
	for _, c := range creditsOf(addr) {
		total += c.amount
	}
	return total
}

// ClaimsJSON returns what a player can claim, game by game, oldest first:
//
//	{ "address": "g1...", "total": 19000000, "games": [ { "id": "...", "amount": 19000000 } ] }
//
// The output has no whitespace. An address with nothing to claim returns
// the same shape with a zero total and no game.
func ClaimsJSON(addr address) string {
	list := creditsOf(addr)
	var b strings.Builder
	total := int64(0)
	for _, c := range list {
		total += c.amount
	}
	b.WriteString(`{"address":` + quote(addr.String()) + `,"total":` + itoa(total) + `,"games":[`)
	for i, c := range list {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"id":"` + c.id + `","amount":` + itoa(c.amount) + `}`)
	}
	b.WriteString("]}")
	return b.String()
}
