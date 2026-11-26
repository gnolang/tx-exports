// Package sandiwara is a sealed-envelope social deduction game.
//
// The roles are sealed before the first night, and the dealer cannot rewrite
// them after the last.
//
// # What this realm does, and what it does not do
//
// Gno.land state is public. A contract cannot hold a secret. This realm
// therefore does NOT implement an autonomous referee that secretly knows who
// the werewolf is: without MPC or zero-knowledge proofs there is nowhere to
// put such a secret, and claiming otherwise would be a lie.
//
// What it does implement is a dealer commitment. Before play starts the dealer
// publishes a Merkle root over one envelope per seat, where envelope i is
// acak.Commit(salt_i, []byte(role_i)) = sha256(salt_i || role_i). The root is
// public; the roles are not. At the end the dealer must open every envelope and
// the realm recomputes the tree itself. So the role map provably could not have
// changed after the game began.
//
// Night actions and votes are committed during play and revealed when their
// phase closes, so the action log is equally non-rewritable.
//
// Secrecy DURING play depends on the dealer not leaking. Verifiability AFTER
// play is total.
//
// # Phases
//
//	LOBBY -> SEAL -> NIGHT -> DAWN -> VOTE -> REVEAL -> DONE
//
// See docs/ARCHITECTURE.md for the phase table: who may call what, when.
package sandiwara

import (
	"chain"
	"chain/runtime"

	"gno.land/p/g1xf93j69vmuav53rlshfd249yyehq9jedrkwteq/acak"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Phase is a stage of the game. The integer values are part of the public
// transcript, so they are fixed here and never reordered.
type Phase int

const (
	PhaseLobby  Phase = iota // players join
	PhaseSeal                // dealer publishes the role root
	PhaseNight               // night actions committed, then revealed
	PhaseDawn                // night resolved, outcome public
	PhaseVote                // elimination votes committed, then revealed
	PhaseReveal              // dealer opens every role envelope
	PhaseDone                // transcript is final
)

// phaseNames maps a phase to the word used in the UI and the transcript.
var phaseNames = [...]string{
	PhaseLobby:  "LOBBY",
	PhaseSeal:   "SEAL",
	PhaseNight:  "NIGHT",
	PhaseDawn:   "DAWN",
	PhaseVote:   "VOTE",
	PhaseReveal: "REVEAL",
	PhaseDone:   "DONE",
}

func (p Phase) String() string {
	if p < 0 || int(p) >= len(phaseNames) {
		return "UNKNOWN"
	}
	return phaseNames[p]
}

// Limits on table size. The brief fixes these; they are also what keeps the
// SVG seat map legible.
const (
	MinPlayersFloor = 5
	MaxPlayersCeil  = 12

	// realmPath is this realm's own package path, used to build in-realm
	// links in Render output.
	realmPath = "g1xf93j69vmuav53rlshfd249yyehq9jedrkwteq/sandiwara"

	// SaltSize is the envelope salt length. It matches acak.Commit, which
	// refuses anything but 32 bytes: a shorter salt would let an observer
	// brute-force an envelope's role before the dealer reveals it.
	SaltSize = 32

	// HashSize is the length of every commitment and of the role root.
	HashSize = 32

	// UnrevealedAction is the marker stored for a player who committed and
	// then refused to reveal, or who let the phase deadline pass. Their
	// commitment stays on record; their action does not resolve.
	UnrevealedAction = "UNREVEALED"

	// EventDealerDisputed is the permanent, indexed record that the dealer's
	// reveal did not match the root sealed before play. This is the single
	// most important event this realm emits.
	EventDealerDisputed = "DealerDisputed"
)

// Seat is one player at the table.
//
// Note what is NOT here: no role. Roles never enter realm state before the
// dealer's reveal, because state is public and storing them would leak them.
type Seat struct {
	Addr     address
	JoinedAt int64

	// Night commitment and reveal.
	NightCommit []byte
	NightAction string
	NightSalt   []byte
	NightOpen   bool // revealed and verified

	// Vote commitment and reveal.
	VoteCommit []byte
	VoteTarget string
	VoteSalt   []byte
	VoteOpen   bool

	Alive bool

	// Absent records that this seat let a phase deadline pass without acting.
	// It is public, and it is the whole penalty: a stall does not block the
	// table, it only writes this seat's name into the transcript.
	Absent bool
}

// EnvelopeRecord is what the dealer claimed at reveal time, kept so a third
// party can recompute the verification without trusting this realm's summary.
type EnvelopeRecord struct {
	Index    int
	Role     string
	Salt     []byte
	Leaf     []byte // sha256(salt || role), the value hashed into the tree
	Verified bool
}

// Game is one table's full state and transcript.
type Game struct {
	ID       int64
	Title    string
	Dealer   address
	MinPlyrs int
	MaxPlyrs int
	Phase    Phase
	PhaseAt  int64 // block height the current phase was entered

	// PhaseDeadline is the height at which a stalled phase may be advanced.
	// Zero means no deadline is armed (LOBBY, DONE).
	PhaseDeadline int64

	Seats []Seat

	// RoleRoot is the dealer's commitment to the role map, published at Seal.
	RoleRoot []byte

	// Revealed is the dealer's reveal, filled at RevealRoles.
	Revealed []EnvelopeRecord

	// Verdict is the final verification result, computed at RevealRoles.
	Verdict string

	// Disputed records that the dealer's reveal failed verification. This is
	// the permanent, public record that the dealer cheated.
	Disputed bool

	// Transcript is the append-only human-readable log.
	Transcript []string
}

var (
	games  []*Game
	router *mux.Router
)

// NewGame opens a table. The caller becomes the dealer.
//
// The dealer is the only address allowed to Seal the role map and to open it at
// the end. Everything else is permissionless.
func NewGame(cur realm, title string, minPlayers, maxPlayers int) int64 {
	dealer := cur.Previous().Address()

	if minPlayers < MinPlayersFloor {
		panic("sandiwara: minPlayers must be at least 5")
	}
	if maxPlayers > MaxPlayersCeil {
		panic("sandiwara: maxPlayers must be at most 12")
	}
	if minPlayers > maxPlayers {
		panic("sandiwara: minPlayers must not exceed maxPlayers")
	}

	id := int64(len(games))
	g := &Game{
		ID:       id,
		Title:    title,
		Dealer:   dealer,
		MinPlyrs: minPlayers,
		MaxPlyrs: maxPlayers,
		Phase:    PhaseLobby,
		PhaseAt:  runtime.ChainHeight(),
	}
	games = append(games, g)
	logf(g, "table opened by %s", shortAddr(dealer))

	chain.Emit("GameOpened",
		"gameID", ufmt.Sprintf("%d", id),
		"dealer", dealer.String(),
	)

	return id
}

// game returns the game with the given id, panicking if there is none.
func game(id int64) *Game {
	if id < 0 || id >= int64(len(games)) {
		panic("sandiwara: no such game")
	}
	return games[id]
}

// seatIndex returns the index of addr in g.Seats, or -1.
func seatIndex(g *Game, addr address) int {
	for i := range g.Seats {
		if g.Seats[i].Addr == addr {
			return i
		}
	}
	return -1
}

// mustSeat returns the seat index of the caller, panicking if they have none.
func mustSeat(g *Game, addr address) int {
	i := seatIndex(g, addr)
	if i < 0 {
		panic("sandiwara: caller is not seated at this table")
	}
	return i
}

// logf appends one line to the game's transcript.
func logf(g *Game, format string, args ...any) {
	g.Transcript = append(g.Transcript, ufmt.Sprintf(format, args...))
}

// setPhase advances g to p and arms its deadline.
func setPhase(g *Game, p Phase, deadline int64) {
	g.Phase = p
	g.PhaseAt = runtime.ChainHeight()
	g.PhaseDeadline = deadline
	logf(g, "phase %s at height %d", p, g.PhaseAt)
}

// boundPayload builds the exact byte string a player's commitment covers: a
// fixed 4-byte big-endian seat index followed by the action.
//
// This is what makes a commitment non-transferable. The realm recomputes the
// hash with the *revealing* seat's index, so a player who copies somebody
// else's commitment into their own slot can never open it: they would have to
// find a salt and action that hash to it under their own index. The commitment
// is bound to the seat, and the seat is bound to the address.
func boundPayload(seat int, action []byte) []byte {
	out := make([]byte, 0, 4+len(action))
	out = append(out,
		byte(seat>>24), byte(seat>>16), byte(seat>>8), byte(seat))
	out = append(out, action...)
	return out
}

// commitMatches reports whether commitment is the hash of this seat's bound
// payload under salt.
func commitMatches(commitment []byte, seat int, payload, salt []byte) bool {
	if len(salt) != SaltSize {
		return false
	}
	return bytesEqual(acak.Commit(salt, boundPayload(seat, payload)), commitment)
}

// roleLeaf is the envelope leaf: sha256(salt || role), via acak.Commit.
func roleLeaf(role string, salt []byte) []byte {
	return acak.Commit(salt, []byte(role))
}
