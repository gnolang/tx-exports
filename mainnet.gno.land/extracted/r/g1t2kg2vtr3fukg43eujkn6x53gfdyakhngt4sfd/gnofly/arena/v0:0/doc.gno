// v0 - Unaudited: This is an initial version that has not yet been formally audited.
// Use in production at your own risk.
//
// Package arena holds the paid games of gnofly, a multiplayer plane game. A
// player pays an entry price in ugnot to join a game, the realm keeps the
// stakes until the game is over, then credits them by a rule it applies
// itself. Winners take what they are owed with Claim.
//
// Games are created off chain, by the game server at a player's request, and
// described by a spec (see spec.gno): mode, entry price, seats, lives, game
// time and kill target. The realm only stores a game once someone paid for
// it, and forgets it when it is over or its lobby empties: no game nobody
// played is ever left on chain.
//
// Four kinds of callers write to it:
//
//   - players enter a game with their stake attached, the first one handing
//     the realm its spec, and may leave again until it starts (Enter, Leave);
//   - referees, the game servers, start a game with the players of its lobby,
//     and report who died by whose hand when it is over (StartRound,
//     SettleRound, CancelRound);
//   - anyone can send the stakes of a game back to its players once the
//     referee is long overdue, and close a lobby whose game never started an
//     hour after it was created (RefundRound, ExpireLobby);
//   - the admins of the game realm set the refund delay (SetRefundDelay).
//
// The realm keeps no roles of its own: the owner, the admins, the referees
// and the treasury are those of gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0, asked at
// the time of each call.
//
// The referee is trusted for facts only: who died, and by whom. What these
// facts are worth is decided by a rule of
// gno.land/p/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/payout/v0, picked by the mode of the game,
// and the realm checks what the rule returns before it sends anything.
//
// # Money
//
// The realm owes exactly the stakes of its lobbies and of its running
// games, and the winnings not claimed yet, and counts them in one number,
// see Escrowed. Every coin that leaves
// goes to a player of the game it came from, or to the treasury of the game
// realm:
//
//	Enter        +stake   the envelope of the call stays in the realm
//	Leave        -stake   back to the player
//	ExpireLobby  -stakes  back to the players of the lobby
//	StartRound    0       stakes move from the lobby to the game
//	SettleRound  -fee     the fee leaves, the rest is credited to the winners
//	Claim        -owed    everything credited to the caller, every game at once
//	CancelRound  -pot     back to the players of the game
//	RefundRound  -pot     back to the players of the game
//
// A game is closed by exactly one of SettleRound, CancelRound and
// RefundRound, once.
//
// What a settlement does not pay to the players is the house's cut, a fee of
// 5% sent to the treasury of the game realm, rounding included.
//
// Reads are plain functions meant for vm/qeval. The ones ending in JSON
// return a single string holding a JSON document. Render exposes the same
// data as markdown for gnoweb.
package arena
