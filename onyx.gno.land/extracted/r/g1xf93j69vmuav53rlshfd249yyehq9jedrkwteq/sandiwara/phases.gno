package sandiwara

// This file holds the phase machine: every function that moves a game from one
// phase to the next, plus the commit-reveal cycles inside NIGHT and VOTE.
//
// Three rules are uniform across the file:
//
//  1. A function that changes state checks the phase first and the caller
//     second, and panics with a stable message on either failure.
//  2. No phase advances on a timer by itself. A phase advances when its work is
//     complete, or when anyone calls the matching force-advance function after
//     the deadline has passed. That keeps every transition attributable to a
//     transaction in the transcript.
//  3. A rejection panics and therefore changes nothing. Marking a seat absent or
//     unrevealed happens only inside Dawn, ForceDawn, and ForceVote — calls that
//     succeed — because a write inside a panicking transaction is rolled back
//     by the VM and would leave no trace.
//
// # Why DAWN exists and how it ends
//
// The brief fixes the order LOBBY -> SEAL -> NIGHT -> DAWN -> VOTE -> REVEAL ->
// DONE, but the required API has no "advance" function. DAWN therefore cannot
// be a phase that waits for an explicit call, or a game played through the
// documented surface alone would stall there forever. DAWN is instead the phase
// in which the night result is public and nobody has started voting yet: the
// last night reveal enters it, and the first accepted vote leaves it. That is
// what "dawn" means at a real table, and it keeps the required API sufficient
// to finish a game.

import (
	"chain"
	"chain/runtime"

	"gno.land/p/g1xf93j69vmuav53rlshfd249yyehq9jedrkwteq/acak"
	"gno.land/p/nt/ufmt/v0"
)

// StallGrace is how many blocks a phase runs before anyone may force it
// forward. It gives the players a window to act first.
const StallGrace = 100

// --- LOBBY ---------------------------------------------------------------

// Join seats the caller. Joining locks a seat and is only possible in LOBBY.
func Join(cur realm, gameID int64) {
	g := game(gameID)
	if g.Phase != PhaseLobby {
		panic("sandiwara: joining is only possible in the lobby")
	}
	addr := cur.Previous().Address()
	if seatIndex(g, addr) >= 0 {
		panic("sandiwara: caller is already seated")
	}
	if len(g.Seats) >= g.MaxPlyrs {
		panic("sandiwara: the table is full")
	}

	g.Seats = append(g.Seats, Seat{
		Addr:     addr,
		JoinedAt: runtime.ChainHeight(),
		Alive:    true,
	})
	i := len(g.Seats) - 1
	logf(g, "seat %d taken by %s", i, shortAddr(addr))

	chain.Emit("PlayerJoined",
		"gameID", ufmt.Sprintf("%d", gameID),
		"seat", ufmt.Sprintf("%d", i),
		"player", addr.String(),
	)
}

// --- SEAL ----------------------------------------------------------------

// Seal closes the lobby and publishes the dealer's commitment to the role map.
//
// root must be the Merkle root over the per-seat envelope leaves in seat order,
// where leaf i is acak.Commit(salt_i, []byte(role_i)). The realm cannot check
// that now — it does not know the roles — so it records the root and checks
// every envelope against it at reveal time.
func Seal(cur realm, gameID int64, root []byte) {
	g := game(gameID)
	if g.Phase != PhaseLobby {
		panic("sandiwara: the lobby is already closed")
	}
	if cur.Previous().Address() != g.Dealer {
		panic("sandiwara: only the dealer may seal the role map")
	}
	if len(g.Seats) < g.MinPlyrs {
		panic("sandiwara: not enough players to start")
	}
	if len(root) != HashSize {
		panic("sandiwara: role root must be 32 bytes")
	}

	g.RoleRoot = copyBytes(root)
	logf(g, "role root sealed: %s", fullHex(g.RoleRoot))

	// The lobby is now frozen and night opens immediately. The deadline is
	// armed so a silent table can still move on.
	setPhase(g, PhaseNight, runtime.ChainHeight()+StallGrace)

	chain.Emit("GameSealed",
		"gameID", ufmt.Sprintf("%d", gameID),
		"root", fullHex(g.RoleRoot),
		"players", ufmt.Sprintf("%d", len(g.Seats)),
	)
}

// --- NIGHT ---------------------------------------------------------------

// SubmitNight records the caller's night action commitment.
//
// The commitment is acak.Commit(salt, boundPayload(seat, action)), so it is
// bound to the caller's seat. Copying another player's commitment into your own
// seat cannot work: at reveal the realm recomputes the hash with your seat
// index, and the copy will not open.
func SubmitNight(cur realm, gameID int64, commitment []byte) {
	g := game(gameID)
	if g.Phase != PhaseNight {
		panic("sandiwara: night actions are only accepted in NIGHT")
	}
	i := mustSeat(g, cur.Previous().Address())
	if !g.Seats[i].Alive {
		panic("sandiwara: the dead do not act")
	}
	if len(commitment) != HashSize {
		panic("sandiwara: commitment must be 32 bytes")
	}
	if len(g.Seats[i].NightCommit) != 0 {
		panic("sandiwara: night action already submitted")
	}

	g.Seats[i].NightCommit = copyBytes(commitment)
	g.Seats[i].Absent = false
	logf(g, "seat %d committed a night action", i)

	chain.Emit("NightSubmitted",
		"gameID", ufmt.Sprintf("%d", gameID),
		"seat", ufmt.Sprintf("%d", i),
		"player", g.Seats[i].Addr.String(),
	)
}

// RevealNight opens one player's night commitment.
//
// A wrong salt or action is rejected with a panic and changes nothing: the
// commitment stays on record and the player may retry with the correct salt
// while the phase is open. A player who never manages to open their commitment
// is marked UNREVEALED by Dawn, in a transaction that actually succeeds.
//
// When the last living seat opens its commitment the night resolves by itself.
// That is what makes a full game playable through the required API alone: no
// seat has to remember to call an "advance" function, and a table that has
// finished its work cannot be left sitting in NIGHT.
func RevealNight(cur realm, gameID int64, action []byte, salt []byte) {
	g := game(gameID)
	if g.Phase != PhaseNight {
		panic("sandiwara: night actions are only revealed in NIGHT")
	}
	i := mustSeat(g, cur.Previous().Address())
	s := &g.Seats[i]
	if len(s.NightCommit) == 0 {
		panic("sandiwara: nothing was submitted to reveal")
	}
	if s.NightOpen {
		panic("sandiwara: night action already revealed")
	}
	if len(salt) != SaltSize {
		panic("sandiwara: salt must be 32 bytes")
	}

	if !commitMatches(s.NightCommit, i, action, salt) {
		logf(g, "seat %d night reveal rejected: does not match the commitment", i)
		chain.Emit("NightRevealRejected",
			"gameID", ufmt.Sprintf("%d", gameID),
			"seat", ufmt.Sprintf("%d", i),
		)
		panic("sandiwara: reveal does not match the commitment")
	}

	s.NightAction = string(action)
	s.NightSalt = copyBytes(salt)
	s.NightOpen = true
	logf(g, "seat %d revealed night action %q", i, s.NightAction)

	chain.Emit("NightRevealed",
		"gameID", ufmt.Sprintf("%d", gameID),
		"seat", ufmt.Sprintf("%d", i),
		"action", s.NightAction,
	)

	if everyLivingRevealedNight(g) {
		resolveNight(g)
	}
}

// --- DAWN ----------------------------------------------------------------

// Dawn resolves a night in which every living player committed but not every
// player opened their commitment.
//
// It requires every living player to have committed — that is the "cannot
// advance a phase with a missing submission" rule — and then records the seats
// that stayed shut as UNREVEALED. Their action is discarded and their
// commitment stays on the record, exactly as the brief specifies.
//
// The common case does not need this call: the last RevealNight resolves the
// night by itself. Dawn exists for the table where somebody committed and then
// went quiet.
func Dawn(cur realm, gameID int64) {
	g := game(gameID)
	if g.Phase != PhaseNight {
		panic("sandiwara: dawn only breaks after NIGHT")
	}
	if !everyLivingSubmittedNight(g) {
		panic("sandiwara: a living player has not submitted a night action")
	}
	resolveNight(g)
}

// ForceDawn advances a stalled NIGHT after its deadline, marking every player
// who did not commit as absent. This is the timeout that keeps one silent
// player from freezing the table forever.
func ForceDawn(cur realm, gameID int64) {
	g := game(gameID)
	if g.Phase != PhaseNight {
		panic("sandiwara: dawn only breaks after NIGHT")
	}
	requireDeadlinePassed(g)
	markAbsentNight(g)
	resolveNight(g)
}

// resolveNight is the shared tail of the last RevealNight, Dawn, and ForceDawn.
//
// It names every committed-but-unrevealed seat, then opens DAWN. The deadline is
// armed so a table that never votes can still be pushed forward.
func resolveNight(g *Game) {
	for i := range g.Seats {
		s := &g.Seats[i]
		if s.Alive && len(s.NightCommit) != 0 && !s.NightOpen {
			s.NightAction = UnrevealedAction
			logf(g, "seat %d did not reveal; night action discarded", i)
		}
	}
	setPhase(g, PhaseDawn, runtime.ChainHeight()+StallGrace)
	logf(g, "dawn resolved, voting opens")

	chain.Emit("DawnResolved", "gameID", ufmt.Sprintf("%d", g.ID))
}

// markAbsentNight records every living seat that never committed.
func markAbsentNight(g *Game) {
	for i := range g.Seats {
		s := &g.Seats[i]
		if s.Alive && len(s.NightCommit) == 0 {
			s.Absent = true
			s.NightAction = UnrevealedAction
			logf(g, "seat %d did not submit; marked absent", i)
		}
	}
}

// --- VOTE ----------------------------------------------------------------

// SubmitVote records the caller's elimination-vote commitment.
//
// The first accepted vote is also what ends DAWN: the table has seen the night
// result, so voting is under way. Later votes are accepted in VOTE as normal.
func SubmitVote(cur realm, gameID int64, commitment []byte) {
	g := game(gameID)
	if g.Phase != PhaseDawn && g.Phase != PhaseVote {
		panic("sandiwara: votes are only accepted once dawn has resolved")
	}
	i := mustSeat(g, cur.Previous().Address())
	if !g.Seats[i].Alive {
		panic("sandiwara: the dead do not vote")
	}
	if len(commitment) != HashSize {
		panic("sandiwara: commitment must be 32 bytes")
	}
	if len(g.Seats[i].VoteCommit) != 0 {
		panic("sandiwara: vote already submitted")
	}

	if g.Phase == PhaseDawn {
		setPhase(g, PhaseVote, runtime.ChainHeight()+StallGrace)
		logf(g, "the first vote opens voting")
	}

	g.Seats[i].VoteCommit = copyBytes(commitment)
	g.Seats[i].Absent = false
	logf(g, "seat %d committed a vote", i)

	chain.Emit("VoteSubmitted",
		"gameID", ufmt.Sprintf("%d", gameID),
		"seat", ufmt.Sprintf("%d", i),
		"player", g.Seats[i].Addr.String(),
	)
}

// RevealVote opens one player's vote.
//
// As with RevealNight, the last living reveal closes voting by itself, so the
// required API is enough to reach REVEAL.
func RevealVote(cur realm, gameID int64, target []byte, salt []byte) {
	g := game(gameID)
	if g.Phase != PhaseVote {
		panic("sandiwara: votes are only revealed in VOTE")
	}
	i := mustSeat(g, cur.Previous().Address())
	s := &g.Seats[i]
	if len(s.VoteCommit) == 0 {
		panic("sandiwara: nothing was submitted to reveal")
	}
	if s.VoteOpen {
		panic("sandiwara: vote already revealed")
	}
	if len(salt) != SaltSize {
		panic("sandiwara: salt must be 32 bytes")
	}

	if !commitMatches(s.VoteCommit, i, target, salt) {
		logf(g, "seat %d vote reveal rejected: does not match the commitment", i)
		chain.Emit("VoteRevealRejected",
			"gameID", ufmt.Sprintf("%d", gameID),
			"seat", ufmt.Sprintf("%d", i),
		)
		panic("sandiwara: reveal does not match the commitment")
	}

	s.VoteTarget = string(target)
	s.VoteSalt = copyBytes(salt)
	s.VoteOpen = true
	logf(g, "seat %d voted for %q", i, s.VoteTarget)

	chain.Emit("VoteRevealed",
		"gameID", ufmt.Sprintf("%d", gameID),
		"seat", ufmt.Sprintf("%d", i),
		"target", s.VoteTarget,
	)

	if everyLivingRevealedVote(g) {
		closeVote(g)
	}
}

// ForceVote advances a stalled DAWN or VOTE after its deadline.
//
// A seat that never committed is marked absent; a seat that committed and never
// revealed keeps its commitment on record and is marked unrevealed. Either way
// the vote does not count and the table moves on.
func ForceVote(cur realm, gameID int64) {
	g := game(gameID)
	if g.Phase != PhaseDawn && g.Phase != PhaseVote {
		panic("sandiwara: voting is not open")
	}
	requireDeadlinePassed(g)
	for i := range g.Seats {
		s := &g.Seats[i]
		if !s.Alive {
			continue
		}
		if len(s.VoteCommit) == 0 {
			s.Absent = true
			s.VoteTarget = UnrevealedAction
			logf(g, "seat %d did not submit a vote; marked absent", i)
		} else if !s.VoteOpen {
			s.VoteTarget = UnrevealedAction
			logf(g, "seat %d did not reveal; vote discarded", i)
		}
	}
	closeVote(g)
}

// closeVote is the shared tail of the last RevealVote and ForceVote.
func closeVote(g *Game) {
	setPhase(g, PhaseReveal, runtime.ChainHeight()+StallGrace)
	logf(g, "voting closed, the dealer must now open the envelopes")

	chain.Emit("VotingClosed", "gameID", ufmt.Sprintf("%d", g.ID))
}

// --- REVEAL --------------------------------------------------------------

// RevealRoles opens every role envelope in one transaction and verifies them
// against the sealed root.
//
// This is the moment the product's promise is kept or broken. Each (role, salt)
// pair must hash to the leaf the dealer committed to for that seat, and the tree
// rebuilt from those leaves must equal the stored root. A single mismatch marks
// the game disputed and emits DealerDisputed — the permanent public record that
// the dealer cheated.
//
// A dispute does NOT panic. A panic in Gno reverts the whole transaction, so a
// realm that panicked here would erase the very evidence it was trying to keep.
// Instead the envelopes are recorded, the verdict says DISPUTED, the phase goes
// to DONE, and DealerDisputed is emitted. The game cannot continue and the
// accusation is on the record forever.
//
// # Why this signature is not callable through `gnokey maketx call`
//
// The chain encodes MsgCall arguments with convertArgToGno, which accepts only
// primitives, [N]byte, and []byte. A []string or [][]byte argument is rejected
// with "unexpected slice type in contract arg" before the realm is ever
// entered, so this function cannot be invoked by a normal transaction no matter
// what it does internally. It exists because the brief fixes this exact surface,
// and it is the right shape for a Go/Gno caller, a filetest, or a future
// MsgRun-based client. For a real table on chain, use RevealRole per seat: same
// verification, same verdict, one callable transaction per envelope.
func RevealRoles(cur realm, gameID int64, roles []string, salts [][]byte) {
	g := game(gameID)
	requireRevealCaller(g, cur)

	if len(roles) != len(g.Seats) {
		panic("sandiwara: one role per seat is required")
	}
	if len(salts) != len(g.Seats) {
		panic("sandiwara: one salt per seat is required")
	}
	for i := range g.Seats {
		if len(salts[i]) != SaltSize {
			panic("sandiwara: envelope salt must be 32 bytes")
		}
	}

	beginReveal(g)
	for i := range g.Seats {
		recordEnvelope(g, i, roles[i], salts[i])
	}
	finalizeReveal(g, gameID)
}

// RevealRole opens ONE role envelope and records it, then verifies the whole map
// once the last envelope is in.
//
// This is the on-chain path: every argument is a type MsgCall can encode
// (int64, int, string, []byte), so the dealer calls it once per seat and the
// final call runs the same check RevealRoles runs. Splitting the reveal does not
// weaken anything — each envelope is fixed by the sealed root before the first
// call, so revealing one early cannot help a dealer who intends to lie; it only
// makes the lie visible one seat sooner.
//
// A seat may be revealed at most once, and the index must be a real seat.
func RevealRole(cur realm, gameID int64, index int, role string, salt []byte) {
	g := game(gameID)
	requireRevealCaller(g, cur)

	if index < 0 || index >= len(g.Seats) {
		panic("sandiwara: no such seat")
	}
	if len(salt) != SaltSize {
		panic("sandiwara: envelope salt must be 32 bytes")
	}

	beginReveal(g)
	if len(g.Revealed[index].Leaf) != 0 {
		panic("sandiwara: envelope already revealed")
	}

	recordEnvelope(g, index, role, salt)
	logf(g, "seat %d envelope opened: %q", index, role)

	chain.Emit("RoleEnvelopeOpened",
		"gameID", ufmt.Sprintf("%d", gameID),
		"seat", ufmt.Sprintf("%d", index),
	)

	if allEnvelopesClaimed(g) {
		finalizeReveal(g, gameID)
	}
}

// requireRevealCaller enforces the two preconditions shared by RevealRoles and
// RevealRole: the game is in REVEAL, and the caller is the dealer.
//
// The realm value is named rlm, not cur, because this is not a crossing
// function: only a crossing function's first realm parameter may be called cur.
// Passing the caller's cur through as an ordinary argument is exactly what is
// wanted here — it names the realm that was current when cur was minted.
func requireRevealCaller(g *Game, rlm realm) {
	if g.Phase != PhaseReveal {
		panic("sandiwara: roles may only be revealed in REVEAL")
	}
	if rlm.Previous().Address() != g.Dealer {
		panic("sandiwara: only the dealer may reveal the roles")
	}
}

// beginReveal allocates the per-seat claim slots on the first reveal call.
func beginReveal(g *Game) {
	if g.Revealed != nil {
		return
	}
	g.Revealed = make([]EnvelopeRecord, len(g.Seats))
	for i := range g.Revealed {
		g.Revealed[i].Index = i
	}
}

// recordEnvelope stores one seat's claimed (role, salt) and the leaf they imply.
func recordEnvelope(g *Game, i int, role string, salt []byte) {
	g.Revealed[i] = EnvelopeRecord{
		Index: i,
		Role:  role,
		Salt:  copyBytes(salt),
		Leaf:  roleLeaf(role, salt),
	}
}

// allEnvelopesClaimed reports whether every seat has a claimed envelope.
func allEnvelopesClaimed(g *Game) bool {
	for i := range g.Revealed {
		if len(g.Revealed[i].Leaf) == 0 {
			return false
		}
	}
	return true
}

// finalizeReveal is the shared tail of RevealRoles and the last RevealRole.
//
// It rebuilds the tree from the claimed leaves and compares it to the sealed
// root. The root is recomputed here rather than trusted: the whole point is that
// the realm, not the dealer, decides whether the claim holds.
func finalizeReveal(g *Game, gameID int64) {
	leaves := make([][]byte, len(g.Seats))
	for i := range leaves {
		leaves[i] = g.Revealed[i].Leaf
	}

	tree := acak.NewTree(leaves)
	recomputed := tree.Root()

	if !bytesEqual(recomputed, g.RoleRoot) {
		g.Disputed = true
		g.Verdict = "DISPUTED: the revealed envelopes do not hash to the sealed root"
		logf(g, "DEALER DISPUTED: revealed root %s != sealed root %s",
			fullHex(recomputed), fullHex(g.RoleRoot))
		setPhase(g, PhaseDone, 0)

		chain.Emit(EventDealerDisputed,
			"gameID", ufmt.Sprintf("%d", gameID),
			"sealed", fullHex(g.RoleRoot),
			"revealed", fullHex(recomputed),
		)
		return
	}

	// Verified. Record each envelope with its own proof so a third party can
	// re-check one seat without rebuilding the whole tree.
	for i := range g.Revealed {
		aunts, total := tree.Prove(i)
		g.Revealed[i].Verified = acak.Verify(g.RoleRoot, g.Revealed[i].Leaf, i, total, aunts)
	}
	g.Verdict = "VERIFIED: every envelope hashes to the sealed root"
	logf(g, "role envelopes verified against the sealed root")

	setPhase(g, PhaseDone, 0)

	chain.Emit("RolesRevealed",
		"gameID", ufmt.Sprintf("%d", gameID),
		"verdict", "VERIFIED",
	)
}

// --- helpers -------------------------------------------------------------

// requireDeadlinePassed panics unless the current phase's deadline has passed.
func requireDeadlinePassed(g *Game) {
	if g.PhaseDeadline == 0 {
		panic("sandiwara: this phase has no deadline")
	}
	if runtime.ChainHeight() <= g.PhaseDeadline {
		panic("sandiwara: the phase deadline has not passed yet")
	}
}

// everyLivingSubmittedNight reports whether every living player committed.
func everyLivingSubmittedNight(g *Game) bool {
	for i := range g.Seats {
		s := &g.Seats[i]
		if s.Alive && len(s.NightCommit) == 0 {
			return false
		}
	}
	return true
}

// everyLivingRevealedNight reports whether every living player opened their
// night commitment.
func everyLivingRevealedNight(g *Game) bool {
	for i := range g.Seats {
		s := &g.Seats[i]
		if s.Alive && !s.NightOpen {
			return false
		}
	}
	return true
}

// everyLivingRevealedVote reports whether every living player opened their vote.
func everyLivingRevealedVote(g *Game) bool {
	for i := range g.Seats {
		s := &g.Seats[i]
		if s.Alive && !s.VoteOpen {
			return false
		}
	}
	return true
}
