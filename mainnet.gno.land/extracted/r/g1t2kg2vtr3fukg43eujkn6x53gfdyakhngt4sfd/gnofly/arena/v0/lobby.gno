package arena

import (
	"chain"

	// Only for OriginSend, in Enter. Caller identity always comes from
	// cur.Previous(), never from this package.
	"chain/runtime/unsafe"
)

// arena is one game: its spec, the players who paid and wait, and once it
// started, its round. It is stored from the first paid entry and deleted
// when its round is closed or its lobby empties.
type arena struct {
	spec
	lobby   []address
	tickets []string // SHA-256 of each player's secret, 64 hex characters
	round   *round   // nil until the game starts
}

func getArena(id string) *arena {
	v := arenas.Get(id)
	if v == nil {
		return nil
	}
	return v.(*arena)
}

func mustArena(id string) *arena {
	a := getArena(id)
	if a == nil {
		panic(errUnknownArena)
	}
	return a
}

// Enter puts the caller in the lobby of the arena that spec describes, and
// returns its id. The exact stake must be attached to the transaction
// (-send "<stake>ugnot") and stays in the realm until the player leaves or
// the game is over.
//
// The first entry creates the arena, the next ones join it: the realm
// recomputes the id from the spec every time. An arena takes entries for an
// hour after it was created, and until its game starts.
//
// ticket is 64 lowercase hex characters, the SHA-256 of a secret the
// player's client made up: the game server gives the seat to whoever shows
// the secret.
//
// It must be called directly by a user (maketx call): a call relayed by
// another realm or by a maketx run script is refused.
func Enter(cur realm, spec string, ticket string) string {
	player := callerOf(0, cur)
	// Paid-call guard: two checks that are only correct together.
	//
	// (a) The caller is a plain user account. Only then is the -send
	//     envelope guaranteed to have landed at this realm's address. A
	//     relaying realm or a maketx run script can attach coins to the
	//     transaction and keep them, while OriginSend still reports them.
	if !cur.Previous().IsUserCall() {
		panic(errNotUserCall)
	}
	sp := parseSpec(spec)
	id := idOf(spec)
	t := now()
	if t > sp.created+entryWindow {
		panic(errEntryClosed)
	}
	if sp.created > t+clockSkew {
		panic(errNotYetCreated)
	}
	if !validTicket(ticket) {
		panic(errInvalidTicket)
	}
	a := getArena(id)
	if a == nil {
		a = &arena{spec: sp}
	}
	if a.round != nil {
		panic(errRoundRunning)
	}
	if indexOfAddr(a.lobby, player) >= 0 {
		panic(errAlreadyInLobby)
	}
	if int64(len(a.lobby)) >= a.maxSeats {
		panic(errLobbyFull)
	}
	// (b) The envelope is exactly the stake: one coin, the right denom, the
	//     right amount. Anything else would either underpay or leave coins
	//     in the realm that it owes to nobody.
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != payDenom || sent[0].Amount != a.stake {
		panic("gnofly: wrong payment, send exactly " + itoa(a.stake) + payDenom)
	}

	// The coins are already at the realm's address: the chain moved them
	// before the call. All that is left is to write down who they belong to.
	a.lobby = withAddr(a.lobby, player)
	a.tickets = withString(a.tickets, ticket)
	arenas.Set(id, a)
	hold(a.stake)
	// The guard above says the coins arrived. This looks at the balance.
	assertSolvent(0, cur)

	chain.Emit("Entered",
		"arena", id,
		"player", player.String(),
		"stake", itoa(a.stake),
		"ticket", ticket,
		"lobby", itoa(int64(len(a.lobby))),
	)
	return id
}

// Leave takes the caller out of the lobby of an arena and sends their stake
// back. It works until the game starts. The last player out deletes the
// arena: nothing is left on chain of a game nobody played.
func Leave(cur realm, id string) {
	player := callerOf(0, cur)
	a := mustArena(id)
	seat := indexOfAddr(a.lobby, player)
	if seat < 0 {
		panic(errNotInLobby)
	}
	a.lobby = withoutAddr(a.lobby, seat)
	a.tickets = withoutString(a.tickets, seat)
	if len(a.lobby) == 0 {
		arenas.Remove(id)
	}
	release(a.stake)

	pay(0, cur, player, a.stake)
	assertSolvent(0, cur)

	chain.Emit("Left",
		"arena", id,
		"player", player.String(),
		"stake", itoa(a.stake),
	)
}

// ExpireLobby closes an arena whose game never started: every player in the
// lobby gets their stake back, and the arena is deleted. Anyone can call it
// once the arena stopped taking entries, an hour after it was created.
func ExpireLobby(cur realm, id string) {
	caller := callerOf(0, cur)
	a := mustArena(id)
	if a.round != nil {
		panic(errRoundRunning)
	}
	if now() <= a.created+entryWindow {
		panic(errNotExpired)
	}
	players := a.lobby
	arenas.Remove(id)
	release(a.stake * int64(len(players)))
	for _, p := range players {
		pay(0, cur, p, a.stake)
	}
	assertSolvent(0, cur)

	chain.Emit("LobbyExpired",
		"arena", id,
		"players", itoa(int64(len(players))),
		"caller", caller.String(),
	)
}

// The four helpers below return a new slice of exactly the length of its
// content, so that nothing else stays in storage. They return nil for an
// empty list.

// withAddr returns list with v added at the end.
func withAddr(list []address, v address) []address {
	out := make([]address, len(list), len(list)+1)
	copy(out, list)
	return append(out, v)
}

// withString returns list with v added at the end.
func withString(list []string, v string) []string {
	out := make([]string, len(list), len(list)+1)
	copy(out, list)
	return append(out, v)
}

// withoutAddr returns list without the element at index at.
func withoutAddr(list []address, at int) []address {
	if len(list) == 1 {
		return nil
	}
	out := make([]address, 0, len(list)-1)
	out = append(out, list[:at]...)
	return append(out, list[at+1:]...)
}

// withoutString returns list without the element at index at.
func withoutString(list []string, at int) []string {
	if len(list) == 1 {
		return nil
	}
	out := make([]string, 0, len(list)-1)
	out = append(out, list[:at]...)
	return append(out, list[at+1:]...)
}
