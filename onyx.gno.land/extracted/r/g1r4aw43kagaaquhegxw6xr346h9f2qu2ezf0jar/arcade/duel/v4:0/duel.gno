// Package duel implements the first slice of Splash Play I, the Duel,
// settled from r/splash/beacon instead of a two-party commit-reveal
// (SPEC-09-duel-beacon.md v1.0, ../../../../SPEC-09-duel-beacon.md).
//
// TEMPORARY NAME. "duel" is scratch space, built beside the LIVE
// r/splash/arcade/duel so that realm keeps working while this one is proven.
// The two are swapped in one commit once this one is ready, and the deploy
// path is decided then (SPEC-09 is silent on it on purpose). Nothing here
// should be linked to, or depended on, from outside this directory.
//
// THIS SLICE IS Post, Cancel, Accept AND THE ROUND PIN. No Resolve — that is
// slice 2 (SPEC-09 §3 describes the whole lifecycle; the part after Accept is
// not built yet). A duel created here therefore has no payout path: it
// exists so the pin itself, SPEC-09's "only subtle part" (§3.1), can be built
// and proved on its own before anything is wired to money leaving the realm.
//
// WHY COMMIT-REVEAL IS GONE RATHER THAN CARRIED OVER (SPEC-09 §1). The old
// duel moved OFF the beacon on 2026-09-30 because Accept needed an UPPER
// bound on drand's head ("round R is not signed yet"), and no arithmetic over
// a RELAYED round could ever establish one: a signature proves a round
// EXISTS (a lower bound), and the absence of one is not provable on chain,
// because withholding a relay is free and invisible. beacon.CurrentRound(),
// added 2026-10-08, derives drand's round from the BLOCK'S OWN CLOCK instead
// — no relayer in the path — so that upper bound now exists, and the whole
// reason commit-reveal's complexity existed is gone with it. What carries
// over is not the lifecycle but four audit findings about THIS REALM'S OWN
// escrow and money handling that were never specific to commit-reveal
// (SPEC-09 §8): rejectAttachedCoin and requireUserCall below, no transfer
// destination ever being a caller-supplied argument, and (for later slices)
// one clock/one derived value and no sentinel field standing in for a height.
//
// THE STAKE IS WRAPPED GNOT, exactly as in r/splash/arcade/duel: this realm
// escrows gno.land/r/gnoland/wugnot and touches no other token.
//
// NO Resolved, NO Winner, NO Secret, NO Nonce, NO NonceRevealedAt, NO
// TakerCommit, AND NO DEADLINE OF ANY KIND IN THIS SLICE'S STATE (SPEC-09 §4,
// §8). Resolve (slice 2) pays and deletes a duel in one call, so a resolved
// duel will never exist to be recorded; there is nothing here for a sentinel
// "never happened yet" value to be confused with a real height.
package duel

import (
	"crypto/sha256"
	"math/bits"
	"strconv"
	"unicode/utf8"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"

	"gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/arcade/raffle/v4"
	"gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/beacon/v2"
	"gno.land/r/gnoland/wugnot"
)

// --- the economics (SPEC-09 §5: "unchanged, deliberately") ---------------
//
// rakeBps, bpsDenom, rakePotShareBps and rakeOpsShareBps, and the rungs
// ladder below, are copied VERBATIM from r/splash/arcade/duel/duel.gno,
// which in turn cites BIBLE.md "Arcade rake" §2.6/§2.7 and SPEC-03 §5/§9.
// SPEC-09 §5 is explicit that nothing about the economics changes in this
// rewrite — only how the coin is flipped — so these numbers are re-stated,
// not re-derived. This slice stops at having them present and the stake
// escrowed: rakeOf/splitRake and the raffle entries they feed belong to
// Resolve, slice 2, and are not needed until a payout exists to apply them
// to.

const (
	// rakeBps is the arcade rake: 300 bps of the pool, i.e. of 2 x stake.
	rakeBps  = 300
	bpsDenom = 10000

	// The rake splits 60% to the current raffle pot / 40% to ops, ops
	// floored, dust to the pot (SPEC-09 §5).
	//
	// rakePotShareBps IS A THIRD COPY OF THE SAME NUMBER, NOT JUST A SECOND
	// ONE — r/splash/arcade/duel/duel.gno's identical constant is the first
	// copy, and r/splash/arcade/raffle/raffle.gno's arcadeRakePotShareBps
	// (raffle.gno:3218) is the second, restated there because "the import
	// only goes one way" (raffle.gno, same comment block): the raffle cannot
	// import either duel to read their constant, so it keeps its own. This
	// file is in the same position relative to the raffle, for the same
	// reason, so it keeps a third.
	//
	// THE RAFFLE SAYS, IN ITS OWN SOURCE, WHY A COPY LIKE THIS ONE IS
	// DANGEROUS ON ITS OWN: raffle.gno:3214 requires
	// "raffle.ArcadeEntryUnitsBound(potShare) to equal it, to the entry",
	// and raffle.gno:3276-3277 exports that function "so the duel's suite
	// can pin the two realms' arithmetic to each other" — an invitation,
	// not a decoration. maxEntryUnitsFor below is this realm's restatement
	// of that same bound (raffle.gno:3286-3291), and if this constant ever
	// drifts from the raffle's WITHOUT raffle.ArcadeEntryUnitsBound moving
	// with it — in particular if it is ever LOWERED, which loosens this
	// file's gross-up — checkInvariant below keeps passing (it only checks
	// pendingEntryUnits against THIS FILE'S OWN maxEntryUnitsFor), but every
	// raffle.FundPotWithEntries call FlushPot makes then finds its units (or
	// their total) over the RAFFLE'S bound and panics, unconditionally
	// (raffle.gno:3449-3455). FlushPot is therefore refused for that batch
	// forever, and the only door left is SweepStuckRake, which — after
	// pendingGraceBlocks — donates the WHOLE booked pot share (the players'
	// 60%) into the raffle's ops pot and drops every entry riding with it.
	// Money enters, the correct exit (FlushPot) closes permanently, and the
	// wrong one (SweepStuckRake) pays the house — and nothing in this file
	// would report it, because nothing here checks this number against the
	// raffle's own. TestMaxEntryUnitsForMatchesRafflesArcadeEntryUnitsBound
	// in duel_test.gno is the pin against that drift, ported from the old
	// duel's TestFix15_TheRafflesEntryBoundIsExactlyThisRealmsRakeEquivalent
	// (duel_test.gno:3338,3341) and TestFix26 (duel_test.gno:3742,3747); the
	// compile-time floor two lines below is the second half of that pin —
	// read ITS comment for what it stops that the test, being a test, can
	// only catch after the fact.
	rakePotShareBps = 6000
	rakeOpsShareBps = 4000
)

// A negative array length is a compile error, so this line fails the BUILD
// if a future edit pushes the two shares past the denominator — copied from
// r/splash/arcade/duel/duel.gno's identical guard.
var _ [bpsDenom - rakePotShareBps - rakeOpsShareBps]struct{}

// THE PLAYERS' SHARE MUST BE AT LEAST HALF THE RAKE — same idiom, same
// value and the same reasoning as r/splash/arcade/raffle/raffle.gno's
// identical guard on its own copy of this number (raffle.gno:3238, "a
// negative array length is a compile error"). rakePotShareBps's own comment
// above explains WHY a drift here is dangerous (it silently closes
// FlushPot and opens SweepStuckRake as the real exit); this line is HALF of
// what stops that drift happening in the first place — the other half is
// TestMaxEntryUnitsForMatchesRafflesArcadeEntryUnitsBound in
// duel_test.gno. The test alone is not enough: a test only runs when
// somebody runs it, but a build fails every time, for every editor,
// including one who never thinks to run this package's suite before
// touching this constant. Note what this guard does NOT do: the
// bpsDenom-sum guard just above already stops the two shares overflowing
// the denominator, but says nothing about EITHER share's own floor — a drop
// to e.g. rakePotShareBps=1000/rakeOpsShareBps=9000 still sums to bpsDenom
// and would sail past that guard while being exactly the dangerous drift
// this one exists to catch.
var _ [rakePotShareBps - 5_000]struct{}

// rungs is the stake ladder, in ugnot (GNOT has 6 decimals): 10 / 50 / 200 /
// 1,000 GNOT. FIXED, never mutable. Copied verbatim from
// r/splash/arcade/duel/duel.gno; SPEC-03 §9 records these as a free dial and
// SPEC-09 §5 carries them forward unchanged.
const (
	rung0 = 10_000_000    // 10 GNOT
	rung1 = 50_000_000    // 50 GNOT
	rung2 = 200_000_000   // 200 GNOT
	rung3 = 1_000_000_000 // 1,000 GNOT
)

var rungs = [...]int64{rung0, rung1, rung2, rung3}

// maxStake is the largest stake the ladder can ever name — rung3 — used to
// bound poolOf's and rakeOf's inputs before any arithmetic touches them.
// Copied verbatim from r/splash/arcade/duel/duel.gno.
const maxStake = rung3

func init() {
	for i := 1; i < len(rungs); i++ {
		if rungs[i] <= rungs[i-1] {
			panic("duel: the stake ladder must ascend")
		}
	}
}

// opsVaultAddr is gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops, the
// operations share of the rake's destination. SAME CONSTANT, SAME DERIVATION,
// SAME REASONING as r/splash/arcade/duel/duel.gno's identical constant: the
// realm at that path need not exist yet for the address to be right, and it
// is a plain wugnot.Transfer destination, not a function call gated by any
// package-path check.
const opsVaultAddr address = "g1dqnxfp5zj89ggfcfzvampmhmrkjq36d2zvdyk7"

// raffleRealmAddr is the address of the raffle this file IMPORTS, and the two
// must move together or FlushPot silently approves the wrong account.
//
// THE COMMENT HERE USED TO SAY "no /v2 suffix exists yet in this repo" and
// promised the raffle would move "at its own redeploy". It has now moved
// twice, to /v3 and then /v4, and this constant did not follow it the first
// time anybody looked. That is the whole hazard of an address DERIVED FROM A
// PACKAGE PATH: the import above changes with a one-line edit and this literal
// does not, and nothing about the result looks wrong until a cross-realm call
// fails on an allowance that was granted to a realm nobody is using.
//
// Caught on 2026-10-08 by the duel's own FlushPot test failing with
// "insufficient allowance" the moment the import went to /v4 — which is the
// test doing exactly its job. tools/raffle_addr_test.go derives this from the
// raffle's gnomod.toml and fails if the two disagree; believe that guard over
// this comment.
//
// Used as a wugnot.Transfer destination (SweepStuckRake) and as the Approve
// target in FlushPot. Never as a gate: the raffle's entry doors gate on
// PACKAGE PATH, not on an address.
const raffleRealmAddr address = "g1lmd9dxwefss54vtf80jscnds6a7k4ec86873c3"

// mulDiv, poolOf, rakeOf and splitRake are copied verbatim (arithmetic and
// bounds) from r/splash/arcade/duel/duel.gno — SPEC-09 §5: "nothing about the
// economics changes". Comments are condensed to a pointer at the old file
// rather than reproduced in full; read poolOf/rakeOf/splitRake there for the
// complete reasoning (mulDiv's 128-bit product, the floor-to-ops/dust-to-pot
// rule, and the two real (non-tautological) guards on splitRake).

// mulDiv returns floor(a*b/d) via a 128-bit intermediate product: raw a*b/d
// on token-scale int64s wraps silently on the GnoVM (tools/muldiv_probe.gno).
func mulDiv(a, b, d uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	if d == 0 {
		panic("duel: mulDiv: division by zero")
	}
	if hi >= d {
		panic("duel: mulDiv: overflow")
	}
	q, _ := bits.Div64(hi, lo, d)
	return q
}

// poolOf is 2 x stake, the whole pot of a duel, with the input bounded first.
func poolOf(stake int64) int64 {
	if stake <= 0 || stake > maxStake {
		panic("duel: stake out of bounds")
	}
	return 2 * stake
}

// rakeOf is the rake on a pool: floor(pool x rakeBps / bpsDenom).
func rakeOf(pool int64) int64 {
	if pool <= 0 || pool > 2*maxStake {
		panic("duel: pool out of bounds")
	}
	return int64(mulDiv(uint64(pool), rakeBps, bpsDenom))
}

// splitRake divides a rake 60/40 into the raffle pot share and the ops
// share. Ops is floored; the pot takes the remainder and all the dust, so
// potShare + opsShare == rake exactly, always.
func splitRake(rake int64) (potShare, opsShare int64) {
	if rake < 0 {
		panic("duel: negative rake")
	}
	opsShare = int64(mulDiv(uint64(rake), rakeOpsShareBps, bpsDenom))
	potShare = rake - opsShare
	if potShare < 0 {
		panic("duel: rake split does not sum to the rake: pot share is negative")
	}
	if potShare < int64(mulDiv(uint64(rake), rakePotShareBps, bpsDenom)) {
		panic("duel: rake split shorts the pot share")
	}
	return potShare, opsShare
}

// rakeEntryUnits and splitEntries are copied verbatim (arithmetic, bounds and
// the three asserted invariants) from r/splash/arcade/duel/duel.gno. Read
// that file's identical functions for the full history (AUDIT-2026-09-28.md
// findings 15, 22 and 26) — condensed here to what each check enforces.

// rakeEntryUnits is how many raffle entry units a rake of `rake` ugnot earns:
// exactly what that money would have bought at raffle.EntryUnitPrice.
// raffle.EntryUnitPrice is read as a compile-time constant of another realm,
// never a call, so this adds no runtime dependency on the raffle.
func rakeEntryUnits(rake int64) int64 {
	if rake < 0 {
		panic("duel: negative rake")
	}
	return rake / raffle.EntryUnitPrice
}

// splitEntries divides a duel's earned entries between its winner and its
// loser: each player is guaranteed one entry whenever the total can pay for
// two (total >= 2), and the remainder is weighted two thirds to the loser.
func splitEntries(total int64) (winnerUnits, loserUnits int64) {
	if total < 0 {
		panic("duel: negative entry total")
	}
	switch {
	case total == 0:
		winnerUnits, loserUnits = 0, 0
	case total == 1:
		winnerUnits, loserUnits = 0, 1
	default:
		winnerUnits = total / 3
		if winnerUnits < 1 {
			winnerUnits = 1
		}
		loserUnits = total - winnerUnits
	}
	if winnerUnits+loserUnits != total {
		panic("duel: entry split does not sum to the total")
	}
	if loserUnits < winnerUnits {
		panic("duel: entry split shorts the loser")
	}
	if total >= 2 && (winnerUnits < 1 || loserUnits < 1) {
		panic("duel: entry split leaves a player with no entry out of a total that can pay both")
	}
	return winnerUnits, loserUnits
}

// maxEntryUnitsFor is the most booked entry units a booked pot share of
// `potShare` ugnot may ever carry — the same ceiling r/splash/arcade/raffle
// applies at its door (raffle.ArcadeEntryUnitsBound, raffle.gno:3286-3291),
// computed here from this realm's own constants so checkInvariant can assert
// it without calling another realm. Copied verbatim from
// r/splash/arcade/duel/duel.gno. A THIRD COPY, same situation as
// rakePotShareBps above — read THAT constant's comment for what happens if
// this one ever disagrees with the raffle's own
// (raffle.gno:3449-3455/FlushPot/SweepStuckRake) — and PINNED the same way:
// TestMaxEntryUnitsForMatchesRafflesArcadeEntryUnitsBound in
// duel_test.gno asserts this function equals raffle.ArcadeEntryUnitsBound,
// to the entry, exactly as the old duel's
// TestFix15_TheRafflesEntryBoundIsExactlyThisRealmsRakeEquivalent
// (duel_test.gno:3338,3341,3742,3747) pins the old duel's identical copy.
func maxEntryUnitsFor(potShare int64) int64 {
	if potShare <= 0 {
		return 0
	}
	gross := int64(mulDiv(uint64(potShare), bpsDenom, rakePotShareBps))
	return gross / raffle.EntryUnitPrice
}

// --- the pin (SPEC-09 §3.1 — "the only subtle part") -----------------------

const (
	// pinOffsetRounds IS A SECURITY BUDGET, IN SECONDS, NOT ONLY A UX DIAL
	// FOR HOW LONG A PLAYER WAITS — stated plainly because only the wait
	// half has ever been documented here. The attack this margin prevents:
	// beacon.CurrentRound() derives drand's round from the BLOCK'S OWN
	// CLOCK (this file's package doc comment), so if that clock ever lags
	// drand's REAL head by more than this margin, the round Accept pins is
	// already signed in the real world, its randomness is fetchable from
	// drand's public API right now, and a taker who checks it before
	// calling Accept can simply decline to send that call when the outcome
	// is unfavourable — turning a 50/50 game into a free option. Given
	// bucketRounds's round-up, the reachable pin for any Accept is
	// [current+pinOffsetRounds+1, current+pinOffsetRounds+bucketRounds]
	// rounds ahead (pinRound's own doc comment derives this), so at
	// pinOffsetRounds=100, bucketRounds=100, drand's 3-second period, the
	// MINIMUM margin this design has against that lag is
	// (pinOffsetRounds+1) x 3s = 303s — not the 100 rounds / 5 minutes
	// framing below, which is the TYPICAL case, not the floor. HALVING
	// THIS CONSTANT FOR SNAPPIER SETTLEMENT HALVES THAT MARGIN TOO: it is
	// the ONLY security margin this design has against a clock-lag
	// foreknowledge attack, there being no other check anywhere in this
	// file that stands in for it (see Resolve's own doc comment on why a
	// beacon.Published(round) check at Accept would not help — an attacker
	// with foreknowledge simply would not publish early). So this constant
	// is tuned for BOTH properties — far enough past
	// beacon.CurrentRound() that it is unknowable at the moment of the pin
	// (drand's period is 3 seconds, so 100 rounds is 5 minutes, SPEC-09
	// §3.1, §9), AND the clock-skew budget above — and a future change to
	// it must weigh both, not just the first.
	pinOffsetRounds = 100

	// bucketRounds rounds the pin UP to a shared boundary, and that single
	// choice does two jobs at once (SPEC-09 §3.1):
	//
	//   - EVERY DUEL ACCEPTED IN THE SAME BUCKET SHARES A ROUND, which is
	//     the communal settling moment the owner asked for; and
	//   - ONE beacon.Publish SERVES ALL OF THEM, which is what makes the gas
	//     affordable: a publish was measured at ~0.277 GNOT on 2026-10-07,
	//     and one publish per duel would cost more than the rake on even the
	//     smallest (10 GNOT) stake, let alone recoup it.
	//
	// 100 again, so a bucket spans the same 5 minutes as the offset
	// (SPEC-09 §9's proposed starting point for both).
	bucketRounds = 100

	// minPinOffsetRounds is the compile-time floor pinOffsetRounds may never
	// be shrunk below, in this file's existing idiom (see bpsDenom's
	// identical negative-array-length guard above). THIS is what actually
	// stops pinOffsetRounds being shrunk — not the runtime assertion in
	// pinRound below, which cannot check a compile-time constant against a
	// value derived from that same constant (see pinRound's own doc comment).
	//
	// IT WAS 1, AND 1 WAS THE WRONG NUMBER. Corrected 2026-10-08 after the
	// re-audit: 1 is the bare MATHEMATICAL minimum for "ahead" to mean
	// anything, and this guard's whole purpose is to protect the SECURITY
	// minimum, which is a different and much larger number. At
	// pinOffsetRounds = 1 the margin is (1+1)*3 = 6 SECONDS against a
	// clock-lag foreknowledge attack, where the budget stated on
	// pinOffsetRounds above is 303. Every value from 1 to 99 collapses that
	// margin and every one of them COMPILED CLEAN — verified by setting it
	// to 1 and watching the build succeed.
	//
	// So the floor is now derived from the budget rather than from the
	// arithmetic: it IS pinOffsetRounds' current value, because that value
	// is the budget. Raising pinOffsetRounds is always safe and needs no
	// change here; lowering it below the documented margin now fails the
	// BUILD, which is the only guard an editor cannot skip.
	//
	// A GUARD CALIBRATED TO THE WRONG QUANTITY READS EXACTLY LIKE A GUARD.
	// That is the fourth time this project has met that shape in one day.
	minPinOffsetRounds = 100
)

// A negative array length is a compile error, so this line fails the BUILD
// if a future edit shrinks pinOffsetRounds below minPinOffsetRounds — the
// same guard idiom as bpsDenom's above, applied to this file's other
// security-bearing constant.
var _ [pinOffsetRounds - minPinOffsetRounds]struct{}

// pinRound computes the round Accept binds a duel to. It is the ONLY place
// this arithmetic exists (SPEC-09 §8: "one expression used twice, never two
// copies" — the old duel's R1/N1/T1 findings were all one deadline written
// as several expressions that drifted apart).
//
//	raw   = beacon.CurrentRound() + pinOffsetRounds
//	Round = ((raw / bucketRounds) + 1) * bucketRounds
//
// current IS READ EXACTLY ONCE, into a local, and reused for both the
// derivation above and the assertion below — never a second call to
// beacon.CurrentRound() — so the invariant is checked against the very value
// the pin was derived from, not a possibly-different later read.
//
// ASSERTS SPEC-09 INVARIANT 2 IN THE CONTRACT, NOT JUST IN A TEST — and this
// time correctly: the panic below checks the MARGIN (round must be at least
// current + pinOffsetRounds), not merely the SIGN (round > current). The
// sign alone is NOT a useful guard: bucketRounds's own round-up already
// makes round > current by at least 1, for ANY pinOffsetRounds including 0
// — so a sign-only check (this file's previous version) passes even when
// pinOffsetRounds has collapsed to 0 and the pin has collapsed with it to
// 1-100 rounds, well inside ordinary clock skew. The margin check here is
// STILL NOT what defends pinOffsetRounds from being set too low, though:
// raw embeds pinOffsetRounds directly, so round's own derivation already
// guarantees round >= current + pinOffsetRounds + 1 for WHATEVER
// pinOffsetRounds compiles in — the check below is therefore a defence
// against a future bug in the ROUNDING step (e.g. bucketRounds's arithmetic
// silently losing the "+1" that makes the round-up strict), not a defence
// against pinOffsetRounds itself being shrunk. THAT defence is the
// minPinOffsetRounds floor above, a BUILD-TIME failure — because
// pinOffsetRounds is a compile-time constant, and nothing checked at
// runtime against a value derived from that same constant can ever catch
// the constant itself being wrong.
func pinRound() int64 {
	current := beacon.CurrentRound()
	round := pinnedRoundFor(current)
	if round < current+pinOffsetRounds {
		panic("duel: pinned round is not at least pinOffsetRounds ahead of beacon.CurrentRound() — refusing to pin")
	}
	return round
}

// pinnedRoundFor is the pin arithmetic, and the ONLY copy of it.
//
// It was inlined in pinRound until RoundForAcceptAt needed the same answer for
// the front end. Two copies of this expression would be the same defect as a
// JavaScript copy, just closer together and harder to spot: a front end
// promising "you have 4 minutes to join this flip" against arithmetic that no
// longer matches what Accept does would be lying to a player about money. One
// function, both callers.
func pinnedRoundFor(current int64) int64 {
	raw := current + pinOffsetRounds
	return ((raw / bucketRounds) + 1) * bucketRounds
}

// --- state (SPEC-09 §4) ----------------------------------------------------

// maxLabelLen bounds an offer's label, in bytes. Copied from
// r/splash/arcade/duel/duel.gno.
const maxLabelLen = 64

// Offer is a standing stake in the lobby (SPEC-09 §4).
type Offer struct {
	Poster   address
	Rung     int64 // index into rungs, not a raw amount
	PostedAt int64 // block height, for a future Render

	// Opponent, when non-zero, is the only address that may Accept this
	// offer. Zero means open to anyone.
	Opponent address

	// Label is free text from the poster, purely descriptive (checkLabel):
	// it never touches settlement.
	Label string

	// PosterIsUser records whether the Post that created this offer was a
	// DIRECT user call, carried forward to Duel.PosterIsUser at Accept. See
	// Duel.PosterIsUser for why the flag is kept even though requireUserCall
	// already makes it unconditionally true today (SPEC-09 §8, the entries
	// half of finding 8; copied from r/splash/arcade/duel/duel.gno's
	// identical field).
	PosterIsUser bool
}

// Duel is a matched pair with a round pinned to settle it (SPEC-09 §4).
type Duel struct {
	Poster, Taker address
	Rung          int64
	Label         string

	// Round is pinned by pinRound() at Accept and NEVER rebound by
	// anything after — not by Resolve (slice 2), not by anything
	// (SPEC-09 invariant 1).
	Round int64

	AcceptedAt int64 // block height

	// PosterIsUser and TakerIsUser record whether each party's OWN call —
	// the Post that created the offer, the Accept that matched it — was a
	// DIRECT user call rather than a realm's. SPEC-09 §8 is explicit that
	// finding 8's ENTRIES half still needs this flag even though this
	// slice's requireUserCall already refuses any non-user Post or Accept
	// outright, which makes both fields unconditionally true today: the
	// same reasoning r/splash/arcade/duel/duel.gno's identical fields give
	// (see that file's bookEntries) — the flag is the ONE place finding 8's
	// property is enforced for entries specifically, so a future
	// relaxation of requireUserCall must fail here as a declined entry and
	// an event, not as a raffle entry credited to an address that cannot
	// spend it. Slice 1 did not add these fields; this slice does, because
	// Resolve is the first thing in this realm that books an entry.
	PosterIsUser bool
	TakerIsUser  bool
}

var (
	// offers is offerID -> *Offer and duels is duelID -> *Duel. avl.Trees,
	// never maps: a future Render must iterate them in a deterministic
	// order, which a map's iteration order does not guarantee.
	offers = avl.NewTree()
	duels  = avl.NewTree()

	// IDs start at 1 so that 0 never names a record. Separate sequences, as
	// in r/splash/arcade/duel.
	nextOfferID int64 = 1
	nextDuelID  int64 = 1

	// escrowed is the wugnot this realm holds on behalf of players: one
	// stake per open offer, two per live duel. Maintained incrementally,
	// never by iteration; the realm's balance must never fall below it
	// (checkInvariant).
	escrowed int64

	// pendingPot and pendingEntries are the players' side of every
	// resolved duel's rake, BOOKED AND NOT YET SENT to the raffle — the
	// exact pattern r/splash/arcade/duel/duel.gno's settle/FlushPot split
	// uses, and ported here deliberately rather than a direct call inside
	// Resolve. See Resolve's own doc comment for why: raffle.gno's
	// FundPot/FundPotWithEntries both gate on cur.Previous().PkgPath() ==
	// the OLD duel's literal package path, which this realm's package path
	// is not and can never be while the two coexist, so a call from this
	// file into either door panics every time, unconditionally — SPEC-09
	// §8a, found during slice 2, confirmed it is a certainty and not a risk.
	// Booking here keeps a winner's payout safe from that (and from any
	// other raffle-side refusal) exactly as it already protects the old
	// realm's Collect — "nothing about a duel depends on the raffle any
	// more". DELIVERING THIS BOOKED AMOUNT IS THIS SLICE'S OWN JOB: FlushPot,
	// below, is the permissionless delivery call slice 2 deferred (SPEC-09
	// §8a.4). It CANNOT be proven to succeed end-to-end by this suite —
	// today's deployed raffle will refuse every call this realm's package
	// path can produce, unconditionally, until the raffle is redeployed
	// naming this realm's path (SPEC-09 §8b) — so FlushPot is built and
	// tested for everything that does NOT require the raffle to accept, and
	// end-to-end delivery is unproven until that redeploy. See FlushPot's own
	// doc comment and the task report for the full finding.
	pendingPot        int64
	pendingEntries    = avl.NewTree()
	pendingEntryUnits int64

	// pendingSince is the clock SweepStuckRake's last-resort grace window is
	// counted from: the chain height at which pendingPot last went from zero
	// to non-zero (Resolve), ADVANCED AGAIN EVERY TIME A NEW HOLDER IS
	// ADMITTED to the entry batch (bookEntries) — so the window always
	// measures the age of the YOUNGEST CLAIM in the batch, not the batch's
	// age. Zero when pendingPot is zero, and reset by every successful
	// FlushPot and by SweepStuckRake. Copied verbatim, reasoning included,
	// from r/splash/arcade/duel/duel.gno's identical field (that file's own
	// comment records why this is NOT, and cannot be, a measure of delivery
	// having been attempted and refused — AUDIT-duel-2026-09-27.md addendum
	// 2, finding D-4).
	pendingSince int64
)

// maxPendingEntryHolders bounds the undelivered entry batch, exactly as
// r/splash/arcade/duel/duel.gno's identical constant: an unbounded batch
// could grow past what a block can iterate. Copied verbatim.
const maxPendingEntryHolders = 128

// blocksPerDay and pendingGraceBlocks: SAME VALUES, SAME REASONING as
// r/splash/arcade/duel/duel.gno's identical constants. 21 days of blocks is
// the same window r/splash/arcade/raffle gives a committed week before its
// refunds open; pendingGraceBlocks must stay several raffle weeks long, and
// the raffle's week is blocks, so the two move together whatever the block
// time turns out to be. Copied verbatim.
const blocksPerDay = 26182

const pendingGraceBlocks = blocksPerDay * 21

// realmSelf is this realm's own address, resolved once so every escrow call
// names a constant rather than re-deriving it.
var realmSelf = unsafe.CurrentRealm().Address()

func selfAddr() address {
	return realmSelf
}

// idKeyWidth/idZeroPad/idKey: enough decimal digits for any non-negative
// int64, so avl's lexicographic key order is numeric ID order. Copied from
// r/splash/arcade/duel/duel.gno.
const idKeyWidth = 19

const idZeroPad = "0000000000000000000"

func idKey(id int64) string {
	s := strconv.FormatInt(id, 10)
	if len(s) < idKeyWidth {
		s = idZeroPad[:idKeyWidth-len(s)] + s
	}
	return s
}

// getOffer returns the offer, or nil. avl's Get returns a single value, so
// existence is a separate Has.
func getOffer(id int64) *Offer {
	key := idKey(id)
	if !offers.Has(key) {
		return nil
	}
	return offers.Get(key).(*Offer)
}

func getDuel(id int64) *Duel {
	key := idKey(id)
	if !duels.Has(key) {
		return nil
	}
	return duels.Get(key).(*Duel)
}

// stakeOf is the only place the ladder is read. Panics on any index outside
// it, including negative ones.
func stakeOf(rung int64) int64 {
	if rung < 0 || rung >= int64(len(rungs)) {
		panic("duel: invalid rung")
	}
	return rungs[rung]
}

func checkLabel(label string) {
	if len(label) > maxLabelLen {
		panic("duel: label too long")
	}
	if !utf8.ValidString(label) {
		panic("duel: label is not valid UTF-8")
	}
	for i := 0; i < len(label); i++ {
		if label[i] < 0x20 || label[i] == 0x7f {
			panic("duel: label contains a control character")
		}
	}
}

// checkInvariant is the O(1) solvency check run at the end of every
// state-changing function: the realm must hold at least what it owes in
// escrow. ">=" and not "==", deliberately — wugnot.Transfer is
// permissionless, so anyone can push wugnot at this address, and an exact
// check would let a one-ugnot donation brick every open offer and live duel.
func checkInvariant() {
	if escrowed < 0 {
		panic("duel: escrowed went negative")
	}
	if pendingPot < 0 {
		panic("duel: pending rake went negative")
	}
	if pendingEntryUnits < 0 {
		panic("duel: booked raffle entries went negative")
	}
	if pendingSince < 0 {
		panic("duel: pending-since booking height went negative")
	}
	if pendingPot > 0 && pendingSince <= 0 {
		// Copied check from r/splash/arcade/duel/duel.gno: a booked rake
		// with no booking height is a clock SweepStuckRake cannot read.
		panic("duel: a rake is booked with no booking height")
	}
	if pendingPot == 0 && pendingSince != 0 {
		panic("duel: no rake is booked but a booking height is still set")
	}
	if pendingEntryUnits > 0 && pendingPot <= 0 {
		// Entries with no rake behind them could never be delivered: the
		// raffle prices its ceiling off the money delivered in the same
		// call. Copied reasoning from r/splash/arcade/duel/duel.gno.
		panic("duel: raffle entries are booked with no rake behind them")
	}
	if pendingEntryUnits > maxEntryUnitsFor(pendingPot) {
		panic("duel: booked raffle entries exceed what the booked rake would buy at the ticket price")
	}
	if pendingEntries.Size() > maxPendingEntryHolders {
		panic("duel: the pending entry batch is over its bound")
	}
	// ">=" against escrowed+pendingPot, not "==": wugnot.Transfer is
	// permissionless, so anyone can push wugnot at this address, and an
	// exact check would let a one-ugnot donation brick every open offer,
	// live duel and booked rake.
	if wugnot.BalanceOf(selfAddr()) < escrowed+pendingPot {
		panic("duel: realm holds less wugnot than it owes in escrow and booked rake")
	}
}

// entryUnitsOf reads the booked entry units for a tree key (a holder
// address string), zero if absent. Copied from r/splash/arcade/duel/duel.gno.
func entryUnitsOf(k string) int64 {
	if !pendingEntries.Has(k) {
		return 0
	}
	return pendingEntries.Get(k).(int64)
}

// bookEntries credits `holder` with `units` raffle entry units, booked in
// this realm for a future delivery, and returns what it actually booked —
// zero when the holder is not eligible or the batch is full. IT NEVER
// PANICS AND NEVER REFUSES ITS CALLER: a winner's Resolve must not be able
// to fail over a raffle entry, so every reason not to credit somebody is a
// zero and an event, not an abort. Copied verbatim (including both
// eligibility reasons and their reasoning) from
// r/splash/arcade/duel/duel.gno's identical function.
func bookEntries(holder address, units int64, isUser bool) int64 {
	if units <= 0 {
		return 0
	}
	if holder == "" {
		return 0
	}
	if !isUser {
		// SPEC-09 §8, finding 8's entries half: a realm's address is
		// package-derived and cannot spend an entry it won, so a party
		// that did not play from a direct user call earns none. See
		// Duel.PosterIsUser for why this is unreachable today and kept
		// anyway.
		chain.Emit("DuelEntriesDeclined",
			"holder", string(holder),
			"units", strconv.FormatInt(units, 10),
			"reason", "the party did not play from a direct user call")
		return 0
	}
	k := string(holder)
	if !pendingEntries.Has(k) && pendingEntries.Size() >= maxPendingEntryHolders {
		chain.Emit("DuelEntriesDropped",
			"holder", string(holder),
			"units", strconv.FormatInt(units, 10),
			"holders", strconv.Itoa(pendingEntries.Size()),
			"reason", "the undelivered entry batch is full")
		return 0
	}
	if !pendingEntries.Has(k) {
		// A NEW HOLDER ADVANCES SweepStuckRake'S CLOCK, so the grace window
		// tracks the YOUNGEST CLAIM in the batch rather than the batch's own
		// age — copied from r/splash/arcade/duel/duel.gno's identical check
		// (finding D-4). An EXISTING holder's further units inherit the
		// batch's clock rather than re-advancing it: admissions are bounded
		// by maxPendingEntryHolders, so the clock can advance at most that
		// many times and the window always closes; advancing on every
		// booking instead could let one repeat player defer the last
		// resort forever.
		pendingSince = runtime.ChainHeight()
	}
	pendingEntries.Set(k, entryUnitsOf(k)+units)
	pendingEntryUnits += units
	return units
}

// --- guards carried over from r/splash/arcade/duel (SPEC-09 §8) ----------

// requireUserCall refuses a Post or Accept that did not come directly from a
// user. A realm party that wins a duel would have no way to call a
// winner-only exit, which strands the pool (SPEC-09 §8, finding D-1). Here
// Resolve (slice 2) is permissionless and pays directly, which removes the
// settlement hazard at its root — but §8 keeps the flag on Post and Accept
// anyway, for the entries half of finding 8 that a later slice still needs.
func requireUserCall(cur realm, what string) {
	if !cur.Previous().IsUserCall() {
		panic("duel: " + what + " must be called directly by a user — a realm cannot be a party to a duel")
	}
}

// rejectAttachedCoin panics if the caller attached native coin to a call
// that has no use for it. Every money-in path in this realm is the wugnot
// GRC20 allowance (Post, Accept), never the transaction's send envelope, so
// any attached ugnot would simply sit at this address forever with no code
// path that ever looks at it (SPEC-09 §8, ../speed/AUDIT-2026-10-07.md Y1).
// Call this as the FIRST STATEMENT of every crossing entrypoint.
//
// unsafe.OriginSend() reads the envelope attached at the chain root, shared
// by every realm in the call chain, so reading it is only sound when the
// immediate caller is an EOA — cur.Previous().IsUserCall() is that check.
// When the call did not come directly from a user, this is silently a
// no-op: requireUserCall is what refuses that case on Post and Accept, and
// Cancel has no reason to refuse a realm caller that is the offer's own
// poster.
func rejectAttachedCoin(cur realm, what string) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if sent := unsafe.OriginSend(); len(sent) != 0 {
		panic("duel: " + what + " does not take native coin — pay through the wugnot allowance instead")
	}
}

// --- the lifecycle, this slice: Post / Cancel / Accept (SPEC-09 §3) -------

// Post pulls rungs[rung] from the caller through the wugnot allowance and
// leaves it standing in the lobby. Returns the new offer's ID.
//
// opponent, when non-zero, addresses the offer to one player: only that
// address may later Accept it. Zero ("") leaves it open to anyone.
//
// label is free text for a future render, at most maxLabelLen bytes (""
// is no label). Neither argument touches settlement: the pinned round and
// the beacon's randomness decide that, not this call.
func Post(cur realm, rung int64, opponent address, label string) int64 {
	rejectAttachedCoin(cur, "Post")
	// A PARTY TO A DUEL MUST BE AN ADDRESS THAT CAN CALL A WINNER-ONLY EXIT
	// once one exists (requireUserCall; SPEC-09 §8, finding D-1).
	requireUserCall(cur, "Post")

	stake := stakeOf(rung)
	if opponent != "" && !opponent.IsValid() {
		panic("duel: invalid opponent address")
	}
	checkLabel(label)
	caller := cur.Previous().Address()
	if wugnot.Allowance(caller, selfAddr()) < stake {
		panic("duel: insufficient allowance — approve this realm for the rung's stake first")
	}

	wugnot.TransferFrom(cross(cur), caller, selfAddr(), stake)

	id := nextOfferID
	nextOfferID++
	offers.Set(idKey(id), &Offer{
		Poster:   caller,
		Rung:     rung,
		PostedAt: runtime.ChainHeight(),
		Opponent: opponent,
		Label:    label,
		// requireUserCall above already refused this call otherwise, so
		// this is unconditionally true today — recorded rather than
		// assumed. See Offer.PosterIsUser for why it is kept.
		PosterIsUser: cur.Previous().IsUserCall(),
	})
	escrowed += stake

	chain.Emit("DuelPost",
		"offer", strconv.FormatInt(id, 10),
		"poster", string(caller),
		"rung", strconv.FormatInt(rung, 10),
		"stake", strconv.FormatInt(stake, 10),
		"opponent", string(opponent),
		"label", label)
	checkInvariant()
	return id
}

// Cancel returns an unaccepted offer's stake to its poster, exactly and with
// no fee, and deletes the record. Poster only.
//
// An accepted offer no longer exists — Accept deletes it in the same
// transaction that creates the duel — so "Cancel of an accepted offer" and
// "Cancel of an unknown offer" are the same refusal: whichever of Cancel or
// Accept lands first in block order removes the offer, and the other finds
// nothing. THE DESTINATION IS READ FROM THE RECORD, never a caller-supplied
// argument (SPEC-09 §8): a canceller can only ever recover the poster's own
// stake to the poster's own address.
func Cancel(cur realm, offerID int64) {
	rejectAttachedCoin(cur, "Cancel")
	o := getOffer(offerID)
	if o == nil {
		panic("duel: no such offer")
	}
	caller := cur.Previous().Address()
	if caller != o.Poster {
		panic("duel: only the poster may cancel")
	}
	stake := stakeOf(o.Rung)

	// Delete before paying, so no path exists on which the offer is both
	// refunded and still standing.
	offers.Remove(idKey(offerID))
	escrowed -= stake

	wugnot.Transfer(cross(cur), o.Poster, stake)

	chain.Emit("DuelCancel",
		"offer", strconv.FormatInt(offerID, 10),
		"poster", string(o.Poster),
		"stake", strconv.FormatInt(stake, 10))
	checkInvariant()
}

// Accept takes a standing offer: pulls a stake equal to THE OFFER'S rung —
// the caller chooses nothing about the money — deletes the offer, pins the
// settlement round and creates the duel. Returns the new duel's ID.
//
// THE TAKER CHOOSES THE MOMENT OF Accept AND THEREFORE THE BUCKET, AND THAT
// IS SAFE — STATED RATHER THAN ASSUMED (SPEC-09 §3.1, invariant 3): every
// bucket reachable from "now" lies in the future, so no choice among them
// reveals anything about the randomness it will eventually be settled with.
// The poster has no influence over the round at all: it is pinned HERE, at
// Accept, and the poster's own call happened earlier, before this duel or
// its bucket existed to choose.
func Accept(cur realm, offerID int64) int64 {
	rejectAttachedCoin(cur, "Accept")
	// A PARTY TO A DUEL MUST BE AN ADDRESS THAT CAN CALL A WINNER-ONLY EXIT
	// once one exists (requireUserCall; SPEC-09 §8, finding D-1).
	requireUserCall(cur, "Accept")

	o := getOffer(offerID)
	if o == nil {
		panic("duel: no such offer")
	}
	caller := cur.Previous().Address()
	if o.Opponent != "" && caller != o.Opponent {
		// Addressed to someone else. Checked before the allowance so the
		// refusal never depends on what the wrong player has approved.
		panic("duel: this offer is addressed to another player")
	}
	stake := stakeOf(o.Rung)
	if wugnot.Allowance(caller, selfAddr()) < stake {
		panic("duel: insufficient allowance — approve this realm for the rung's stake first")
	}

	// The offer is deleted before the pull, the same ordering as Cancel:
	// the record goes first, the money moves second, so a re-entrant Accept
	// on this offer finds nothing whatever the token does.
	offers.Remove(idKey(offerID))

	wugnot.TransferFrom(cross(cur), caller, selfAddr(), stake)

	round := pinRound()

	id := nextDuelID
	nextDuelID++
	duels.Set(idKey(id), &Duel{
		Poster:     o.Poster,
		Taker:      caller,
		Rung:       o.Rung,
		Label:      o.Label,
		Round:      round,
		AcceptedAt: runtime.ChainHeight(),
		// Carried from the offer, not re-derived: PosterIsUser describes
		// the POSTER'S OWN Post call, which happened earlier and is not
		// this call's business to recompute. TakerIsUser is this call's
		// own IsUserCall(), unconditionally true today because
		// requireUserCall above already gates it — see Duel.PosterIsUser.
		PosterIsUser: o.PosterIsUser,
		TakerIsUser:  cur.Previous().IsUserCall(),
	})
	escrowed += stake

	chain.Emit("DuelAccept",
		"offer", strconv.FormatInt(offerID, 10),
		"duel", strconv.FormatInt(id, 10),
		"poster", string(o.Poster),
		"taker", string(caller),
		"rung", strconv.FormatInt(o.Rung, 10),
		"round", strconv.FormatInt(round, 10))
	checkInvariant()
	return id
}

// --- the outcome (SPEC-09 §3.2) -------------------------------------------

// outcomeTag is copied BYTE FOR BYTE from r/splash/arcade/duel/duel.gno's
// identical constant. THE OLD REALM'S commitTag AND takerCommitTag ARE GONE
// WITH THE COMMIT-REVEAL DESIGN THEY EXISTED TO SEAL (SPEC-09 §1, §4: no
// Secret, no Nonce, no TakerCommit here at all) — there is only ONE domain
// tag in this file, so the prefix-freeness machinery the old file needed to
// keep three tags from colliding (checkTagsPrefixFree and its init, guarding
// commitTag/outcomeTag/takerCommitTag pairwise) has nothing left to guard.
// Its absence here is deliberate, not an oversight: domain separation across
// a single tag is not a thing that needs checking.
const outcomeTag = "splash/duel/v1/result:"

// outcome computes a published duel's winner (SPEC-09 §3.2):
//
//	sum        = sha256(outcomeTag ‖ randomness ‖ duelID)
//	posterWins = sum[len(sum)-1] % 2 == 0
//
// duelID, AS ITS DECIMAL STRING (strconv.FormatInt, exactly as the old
// realm's posterWins suffixed its own duelID), IS MIXED IN, AND THAT IS
// LOAD-BEARING. bucketRounds (SPEC-09 §3.1) means MANY DUELS SHARE ONE
// Round and therefore one randomness — pinRound's whole point is that one
// beacon.Publish serves a whole bucket. Without duelID in this preimage,
// every duel in a bucket would hash to the identical sum and therefore
// resolve IDENTICALLY: exploitable (the first duel to resolve leaks every
// other duel in its bucket's outcome before they are even looked at) and
// absurd to watch (a communal settling moment where everyone flips the same
// side of the same coin). Mixing in duelID gives each duel its own
// independent coin despite sharing randomness with its whole bucket.
func outcome(duelID int64, randomness string) (posterWins bool) {
	sum := sha256.Sum256([]byte(outcomeTag + randomness + strconv.FormatInt(duelID, 10)))
	return sum[len(sum)-1]%2 == 0
}

// --- Resolve, this slice (SPEC-09 §3) -------------------------------------

// Resolve computes a duel's winner from the published beacon round, pays and
// deletes the record — ALL IN ONE CALL. PERMISSIONLESS: there is no Collect
// in this design (SPEC-09 §3), so a winner never has to come back, and
// anybody — a party, a bystander, a keeper — may call this once the pinned
// round is on chain. The caller supplies nothing but duelID: the winner, the
// payout and the entries are all non-discretionary functions of stored
// state and the beacon's own randomness (invariant 4).
//
// ORDER OF OPERATIONS, SPEC-09'S OWN: reject attached coin first, as every
// entrypoint; look up the duel, refusing an unknown one; refuse if the
// pinned round is not yet published; THEN compute the outcome, pay, book
// entries, delete, emit.
//
// THE PAYOUT IS PORTED FROM r/splash/arcade/duel/duel.gno's settle, NOT
// REDESIGNED (SPEC-09 §8, this task's own instruction): same pool/rake
// arithmetic, same 60/40 split with ops floored and dust to the pot, same
// splitEntries/rakeEntryUnits weighting, same conservation assertion. THE
// ONE DEPARTURE, AND IT IS DELIBERATE RATHER THAN AN OMISSION, IS WHERE THE
// POT SHARE AND ITS ENTRIES LAND. The old settle's own comment says it
// plainly — "BOOKED, NOT SENT, AND NOT ONE LINE OF RAFFLE CODE RUNS IN THIS
// TRANSACTION" — and books into pendingPot/pendingEntries for a SEPARATE,
// later FlushPot to deliver, specifically so a raffle-side refusal can never
// take a winner's payout down with it. This file ports exactly that half of
// settle (see pendingPot's own doc comment above) rather than a direct,
// same-transaction call to raffle.FundPotWithEntries, because such a call
// would not merely risk the winner's payout here — IT WOULD PANIC EVERY
// SINGLE TIME, UNCONDITIONALLY: raffle.gno's FundPot and FundPotWithEntries
// both gate on cur.Previous().PkgPath() == the literal string
// "gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/arcade/duel/v3" — the
// OLD realm's own package path — and this realm's module is
// ".../arcade/duel/v2" (SPEC-09 §8b, set in slice 3's gnomod.toml), a
// different string, so that check fails on every call for as long as the
// raffle's compile-time constant names the old path. A direct call here
// would make Resolve permanently unable to pay any duel whose rake is
// positive (every rung's is), which is every duel — the opposite of SPEC-09
// invariant 7 ("a duel can never be stuck by inaction"). ACTUALLY DELIVERING
// THE BOOKED POT IS FlushPot, BELOW (THIS SLICE, SPEC-09 §8a.4) — permissionless,
// separate from this call, and provably safe for a winner's payout even
// while the raffle refuses it. Nothing is lost in the meantime: the booked
// wugnot sits in this realm's own balance, accounted for by pendingPot in
// checkInvariant, exactly as it would between settle and FlushPot in the
// old realm today.
func Resolve(cur realm, duelID int64) {
	rejectAttachedCoin(cur, "Resolve")

	d := getDuel(duelID)
	if d == nil {
		panic("duel: no such duel")
	}

	// THE STATE AN HONEST PLAYER ACTUALLY HITS WHILE WAITING OUT THE ~5
	// MINUTES until drand signs the pinned round — so this reads as a
	// status with an instruction, not a dead end. ANYBODY may publish it;
	// it is not this realm's job to, and naming the round lets the caller
	// (or the front end on their behalf) go do exactly that and come back.
	if !beacon.Published(d.Round) {
		panic("duel: round " + strconv.FormatInt(d.Round, 10) +
			" is not published yet — anybody may call beacon.Publish for it once drand has signed it, then call Resolve again")
	}

	randomness := beacon.Randomness(d.Round)
	posterWins := outcome(duelID, randomness)

	winner, loser := d.Taker, d.Poster
	winnerIsUser, loserIsUser := d.TakerIsUser, d.PosterIsUser
	if posterWins {
		winner, loser = d.Poster, d.Taker
		winnerIsUser, loserIsUser = d.PosterIsUser, d.TakerIsUser
	}

	stake := stakeOf(d.Rung)
	pool := poolOf(stake)
	rake := rakeOf(pool)
	payout := pool - rake
	potShare, opsShare := splitRake(rake)
	if payout+potShare+opsShare != pool {
		// A real check, not a tautology: payout and the two shares are
		// each computed from the pool by their own path above, and this
		// is the first place all three meet (SPEC-09 invariant 5).
		panic("duel: conservation violated — payout plus rake is not the pool")
	}
	winnerUnits, loserUnits := splitEntries(rakeEntryUnits(rake))

	// Delete before paying, the same ordering Cancel and Accept already
	// use: no path exists on which this duel is both paid and still
	// resolvable. THE DESTINATION IS NEVER A CALLER-SUPPLIED ARGUMENT
	// (SPEC-09 §8) — winner is read from the record via outcome(), not
	// from anything the caller of Resolve passed in.
	duels.Remove(idKey(duelID))
	escrowed -= pool

	wugnot.Transfer(cross(cur), winner, payout)
	if potShare > 0 {
		// Booked, not sent — see this function's own doc comment above for
		// why. The entries that rake bought are booked in the same breath,
		// inside this branch deliberately: an entry must never exist
		// without the money that pays for it (checkInvariant asserts this
		// too).
		if pendingPot == 0 {
			// pendingSince starts the grace clock the instant a batch goes
			// from nothing owed to something owed — copied from
			// r/splash/arcade/duel/duel.gno's identical check in settle.
			pendingSince = runtime.ChainHeight()
		}
		pendingPot += potShare
		winnerUnits = bookEntries(winner, winnerUnits, winnerIsUser)
		loserUnits = bookEntries(loser, loserUnits, loserIsUser)
	} else {
		// No rake to pay for entries, so there are none. Unreachable on
		// today's ladder (every rung's rake is positive).
		winnerUnits, loserUnits = 0, 0
	}
	if opsShare > 0 {
		wugnot.Transfer(cross(cur), opsVaultAddr, opsShare)
	}

	recordResult(duelID, d.Round, winner, loser, d.Rung)

	chain.Emit("DuelResolve",
		"duel", strconv.FormatInt(duelID, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"winner", string(winner),
		"loser", string(loser),
		"payout", strconv.FormatInt(payout, 10),
		"rake", strconv.FormatInt(rake, 10),
		"rafflePotBooked", strconv.FormatInt(potShare, 10),
		"ops", strconv.FormatInt(opsShare, 10),
		"pendingPot", strconv.FormatInt(pendingPot, 10),
		"winnerEntries", strconv.FormatInt(winnerUnits, 10),
		"loserEntries", strconv.FormatInt(loserUnits, 10),
		"pendingEntries", strconv.FormatInt(pendingEntryUnits, 10))
	checkInvariant()
}

// --- FlushPot and SweepStuckRake, this slice (SPEC-09 §8a.4) --------------

// FlushPot delivers the whole booked rake — pendingPot and the entries
// earned alongside it — to r/splash/arcade/raffle's CURRENT week, through
// raffle.FundPotWithEntries (or raffle.FundPot when nobody earned an
// entry), and returns the amount actually delivered. PERMISSIONLESS: anyone
// may pay the gas to do it, and the destination is not theirs to choose.
// Ported from r/splash/arcade/duel/duel.gno's FlushPot, same shape and same
// reasoning: a resolved duel's payout must never depend on another realm's
// bookkeeping (see pendingPot's own doc comment above), so delivery is a
// SEPARATE, later, permissionless call whose only failure mode costs the
// CALLER OF THIS FUNCTION a reverted transaction — never a duel's winner,
// who has already been paid and whose record is already gone.
//
// A NO-OP, NOT A PANIC, WHEN NOTHING IS BOOKED — the FIRST of two deliberate
// departures from the old realm's identical function, which panics in this
// case. A permissionless call anybody (in practice: a keeper, on a
// schedule) may make at any time is better served by a harmless zero than
// by forcing every caller to read PendingPot first just to avoid an abort.
//
// THE SECOND DEPARTURE: pendingPot AND THE REST OF THE BOOKING ARE ZEROED
// ONLY AFTER raffle.FundPot/FundPotWithEntries HAS RETURNED WITHOUT
// PANICKING — not before, the old realm's own ordering. ON A REAL CHAIN
// THIS ORDERING CHOICE DOES NOT MATTER: a panic reverts the WHOLE
// transaction, so whether the zeroing happened before or after the
// cross-realm call, it is discarded along with everything else the call
// did, and the old realm's "before" ordering is exactly as revert-safe as
// this file's "after" ordering. RE-ENTRANCY THROUGH THE CROSS-REALM CALL
// ITSELF IS SEPARATELY UNREACHABLE, ARCHITECTURALLY, NOT BY CONVENTION:
// this file imports raffle, so raffle cannot import this file back without
// a compile-time import cycle, and nothing else in raffle's own code calls
// into this realm — there is no path by which raffle.FundPot/
// FundPotWithEntries could call back into FlushPot mid-execution regardless
// of ordering. A mutation check (reorder this file to zero
// first, the old realm's way) DOES make
// TestFlushPotRefusedDeliveryLeavesBookingIntactAndRetryable fail — but
// that result is a property of gno test's HARNESS, not of the chain:
// uassert.AbortsContains recovers the panic inside the same test process
// without re-running the whole message atomically, so a package-level
// write made before the panic (the zeroing) survives the recover when a
// real chain's revert would have discarded it. The harness's recover is
// not a state rollback, and the old realm's comment overstated what the
// mutation test proves by citing it as if it were one. The ordering below
// is kept anyway — zeroing after costs nothing and makes the retry property
// visible in THIS function's own control flow rather than resting on a
// chain-level guarantee this suite cannot exercise — but the reason to keep
// it is suite-observability, not a chain safety property the old ordering
// lacked.
//
// THE RULE THIS FILE ACTUALLY FOLLOWS, SO THE TWO ORDERINGS IN THIS SECTION
// DO NOT READ AS A CONTRADICTION: every OTHER state change in this file
// (Cancel's escrowed -=, Accept's offers.Remove, Resolve's duels.Remove)
// mutates bookkeeping BEFORE the paying wugnot.Transfer, on the general
// principle that a retry or a re-entrant call should find nothing rather
// than something stale. SweepStuckRake, below, follows that same general
// rule: its wugnot.Transfer is a plain, ungated call that this function's
// own prior checks (and checkInvariant's balance assertion) already make
// as close to unconditional as this realm can establish, so there is
// nothing to protect by delaying the zeroing. FlushPot is the ONE
// deliberate exception to the general rule, and the reason is specific to
// it: its cross-realm call is, TODAY, KNOWN to panic unconditionally (the
// raffle's package-path gate, documented below), so zeroing after is what
// keeps the retry property visible inside this function's own control flow
// for the one call in this file whose failure is not hypothetical.
//
// END-TO-END DELIVERY IS UNPROVEN BY THIS SUITE, AND THAT IS STATED HERE
// RATHER THAN DISCOVERED LATER (SPEC-09 §8a — found during slice 2 and a
// certainty, not a risk). raffle.gno's FundPot and FundPotWithEntries both
// gate on cur.Previous().PkgPath() being EXACTLY
// "gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/arcade/duel/v3" — the
// OLD realm's own path, never this realm's ".../arcade/duel/v2" — so EVERY
// CALL THIS FUNCTION MAKES TO THE RAFFLE TODAY PANICS, UNCONDITIONALLY, and
// that panic reverts this whole call with pendingPot intact (the retry
// property above, independently of the zero-after ordering, since nothing
// here has executed the zeroing yet when the panic happens). This is §8a's
// forced deploy order working as designed, not a defect to chase here: the
// raffle must be redeployed FIRST, naming this realm's path, before this
// function's happy path can be exercised for real — and it will be, for
// the first time, at that deploy, not in this suite. What this suite proves
// instead, and all it honestly can: the booking is correct, a refused
// delivery loses nothing and remains retryable, the books balance, this
// function is permissionless, and it refuses attached coin.
func FlushPot(cur realm) int64 {
	rejectAttachedCoin(cur, "FlushPot")
	amount := pendingPot
	if amount <= 0 {
		return 0
	}

	// THE BATCH IS COLLECTED BEFORE ANY CROSS-REALM CALL, AND NEVER NEST ONE
	// avl.Iterate INSIDE ANOTHER — copied warning from
	// r/splash/arcade/duel/duel.gno's FlushPot: the raffle's own FundPot
	// iterates its own trees, and a second traversal starting inside the
	// first's callback crashes this toolchain's VM with a Go-level nil
	// dereference that no gno panic recovers from. So the walk finishes
	// here, fully, before the raffle runs at all.
	holders := make([]address, 0, pendingEntries.Size())
	units := make([]int64, 0, pendingEntries.Size())
	pendingEntries.Iterate("", "", func(key string, value any) bool {
		holders = append(holders, address(key))
		units = append(units, value.(int64))
		return false
	})
	entryUnits := pendingEntryUnits

	wugnot.Approve(cross(cur), raffleRealmAddr, amount)
	if len(holders) > 0 {
		raffle.FundPotWithEntries(cross(cur), amount, holders, units)
	} else {
		// NO ELIGIBLE HOLDERS, A REAL STATE AND NOT A DEGENERATE ONE: every
		// party of every settled duel played from realm code, or the rakes
		// were too small to buy one whole entry. The money must still go,
		// and the raffle's entry door refuses an empty batch on purpose, so
		// this is the plain door.
		raffle.FundPot(cross(cur), amount)
	}

	// ONLY NOW, WITH THE CROSS-REALM CALL HAVING RETURNED WITHOUT PANICKING
	// (see this function's own doc comment for why this ordering, not the
	// old realm's), IS THE BOOKING CLEARED.
	pendingPot = 0
	pendingSince = 0
	pendingEntries = avl.NewTree()
	pendingEntryUnits = 0

	chain.Emit("DuelFlushPot",
		"amount", strconv.FormatInt(amount, 10),
		"destination", string(raffleRealmAddr),
		"entryHolders", strconv.Itoa(len(holders)),
		"entryUnits", strconv.FormatInt(entryUnits, 10))
	checkInvariant()
	return amount
}

// SweepStuckRake is the LAST RESORT for a booked rake the raffle will not
// take, so that pendingPot is never a place money can enter and never
// leave. It transfers the WHOLE booked amount to the raffle's address by a
// PLAIN wugnot.Transfer — no raffle code runs, so nothing in the raffle can
// refuse it — and returns the amount moved. PERMISSIONLESS, and only once
// the batch's YOUNGEST CLAIM (pendingSince) has stood for
// pendingGraceBlocks. Ported from r/splash/arcade/duel/duel.gno's
// SweepStuckRake — same mechanism, same grace window, same dropped-entries
// cost, same reasoning; read that function's own doc comment for the full
// argument, including the gas figures for a full 128-holder batch. This
// comment restates only what is specific to deciding to port it here at
// all.
//
// WHY PORT A GRACE-WINDOW LAST RESORT WHEN §8a's REFUSAL IS A CERTAINTY,
// NOT THE OCCASIONAL TROUBLE THE OLD REALM'S VERSION IS A LAST RESORT FOR —
// this is the one judgment call this slice makes and states plainly rather
// than assuming. The invariant SweepStuckRake protects ("a place money can
// enter and never leave") does not care WHY FlushPot's door is shut, only
// THAT it might stay shut indefinitely. Today it is shut by construction —
// the raffle's duelRealmPkgPath names the old realm, not this one — and it
// reopens only when the raffle is redeployed naming this realm's path
// (SPEC-09 §8b). Resolve keeps booking pendingPot regardless of whether
// that redeploy ever happens, is delayed, or the swap this directory is
// scaffolding for is abandoned; Resolve must not, and does not, know or
// care. Without this function that booking would have exactly one exit
// (FlushPot), and that exit is the one this entire slice's own doc comment
// says is unproven. A grace-windowed, gate-bypassing last resort is cheap
// insurance against that exit never opening, and the mechanism — a plain
// transfer that runs no raffle code — does not depend on knowing why the
// gate is shut, only on giving the booking a second way out that the gate
// cannot touch.
//
// THE BOOKED ENTRIES ARE DROPPED ON THIS PATH, exactly as in the old
// realm's SweepStuckRake and for the identical reason: the money lands in
// the raffle's ops pot via sweepDonations, not a prize pot, so there is no
// draw left for an entry to be an entry IN — and an entry with no rake
// behind it is exactly what checkInvariant refuses. The 60/40 split is
// NOT preserved on this path (it all becomes the house's ops pot); that is
// the honest cost of a window existing at all, and it is preventable by
// anyone, at any time, by simply calling FlushPot instead.
//
// Panics if there is nothing booked, or if the window has not elapsed.
func SweepStuckRake(cur realm) int64 {
	rejectAttachedCoin(cur, "SweepStuckRake")
	amount := pendingPot
	if amount <= 0 {
		panic("duel: no rake is waiting to be delivered to the raffle")
	}
	if pendingSince <= 0 {
		// Unreachable: pendingSince is set in the same statement group that
		// makes pendingPot non-zero (Resolve, bookEntries). Loud rather than
		// treating an unset clock as elapsed.
		panic("duel: the pending rake has no booking height")
	}
	if runtime.ChainHeight()-pendingSince < pendingGraceBlocks {
		panic("duel: nothing in this batch is old enough for the last resort — call FlushPot instead")
	}

	// THE BOOKED ENTRIES DIE HERE, discarded in O(1) by replacing the tree
	// rather than walking and removing — this function is the LAST RESORT
	// for a booked rake nobody could deliver, so its own cost must not scale
	// with the batch that could not be delivered.
	sweptEntryUnits := pendingEntryUnits
	sweptEntryHolders := pendingEntries.Size()

	pendingPot = 0
	pendingSince = 0
	pendingEntries = avl.NewTree()
	pendingEntryUnits = 0

	wugnot.Transfer(cross(cur), raffleRealmAddr, amount)

	chain.Emit("DuelSweepStuckRake",
		"amount", strconv.FormatInt(amount, 10),
		"destination", string(raffleRealmAddr),
		"droppedEntryHolders", strconv.Itoa(sweptEntryHolders),
		"droppedEntryUnits", strconv.FormatInt(sweptEntryUnits, 10))
	checkInvariant()
	return amount
}

// --- the read surface ------------------------------------------------------
//
// ADDED 2026-10-08, AFTER THE REALM WAS ALREADY DEPLOYED WITHOUT IT. The first
// v2 deployment exported exactly six functions -- Post, Cancel, Accept,
// Resolve, FlushPot, SweepStuckRake -- every one an action and not one a
// question. The realm was playable and completely unreadable: no board, no
// standing offers, no live duels, and above all no way to show the countdown
// that is the whole point of settling from a future beacon round. The audit
// raised it as an open question and it was not acted on before deploy.
//
// NONE OF THESE TAKE `cur realm`, SO NONE NEEDS rejectAttachedCoin. That guard
// exists because a crossing entrypoint can have native coin attached to it and
// this realm has no way to spend ugnot; a plain function is not a transaction
// and cannot carry an envelope. Every function below is a pure read: no writes,
// no lazy initialisation, no caching into state.

// pageLimit caps every list this realm returns. UNBOUNDED READS ARE A DENIAL
// SURFACE, not merely untidy: offers and duels grow without limit, and a caller
// asking for all of them on a busy arcade gets a response no node wants to
// build. Callers page.
const pageLimit = 100

// PinOffsetRounds and BucketRounds expose the pin arithmetic, so a front end
// can work out WHICH FLIP a new acceptance would land in -- "4 minutes left to
// get into this one" -- without keeping a second copy of either number.
//
// THAT SECOND COPY IS THE WHOLE REASON THESE EXIST. The constants are a
// security budget (read pinOffsetRounds' comment), and a JavaScript duplicate
// of a security budget is one that drifts silently the moment anyone retunes
// it. The front end asks the realm instead. Same reasoning and same shape as
// arcade/speed's PinOffsetRounds.
//
// They are reads of compile-time constants: no state, no caller, nothing to
// guard.
func PinOffsetRounds() int64 { return pinOffsetRounds }
func BucketRounds() int64    { return bucketRounds }

// RoundForAcceptAt is THE question a front end actually has, answered by the
// realm that owns the answer: if a duel were accepted while the beacon reads
// `currentRound`, which round would it be pinned to?
//
// It is the exact expression Accept uses, factored out so there is ONE copy of
// it and both callers share it -- see pinnedRoundFor below. A front end can
// therefore show a truthful join deadline: the answer changes at a bucket
// boundary, and the moment it changes is the moment the current flip closes to
// newcomers.
func RoundForAcceptAt(currentRound int64) int64 { return pinnedRoundFor(currentRound) }

// RungCount and StakeOfRung expose the ladder so a front end need not hardcode
// it. Same names and shapes as the superseded realm, deliberately, so the
// existing front end's reads.js keeps working.
func RungCount() int64 { return int64(len(rungs)) }

func StakeOfRung(rung int64) int64 { return stakeOf(rung) }

// Escrowed is the players' money this realm is holding: every standing offer's
// stake plus both stakes of every live duel. It does NOT include pendingPot,
// which is the raffle's share already earned and awaiting delivery -- read
// PendingPot for that. Two separate numbers because they are two separate
// claims, and summing them would hide which is which.
func Escrowed() int64 { return escrowed }

func OfferCount() int64 { return int64(offers.Size()) }

func DuelCount() int64 { return int64(duels.Size()) }

// OfferIDs and DuelIDs page through the boards in key order. offset and limit
// are CLAMPED rather than validated: a caller asking for a million gets
// pageLimit, and one asking past the end gets an empty slice. A reader that
// panics on a bad page is a reader a front end has to guard against.
func OfferIDs(offset, limit int64) []int64 { return idsOf(offers, offset, limit) }

func DuelIDs(offset, limit int64) []int64 { return idsOf(duels, offset, limit) }

func idsOf(t *avl.Tree, offset, limit int64) []int64 {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > pageLimit {
		limit = pageLimit
	}
	out := []int64{}
	var seen int64
	t.Iterate("", "", func(k string, v any) bool {
		if seen < offset {
			seen++
			return false
		}
		if int64(len(out)) >= limit {
			return true
		}
		id, err := strconv.ParseInt(k, 10, 64)
		if err == nil {
			out = append(out, id)
		}
		seen++
		return false
	})
	return out
}

// OfferOf reports a standing offer: poster, rung, posted-at height. All zero
// for an id that is not on the table -- the same "zero means absent" shape the
// superseded realm used, so a front end can tell absent from present without a
// second call.
func OfferOf(id int64) (address, int64, int64) {
	o := getOffer(id)
	if o == nil {
		return "", 0, 0
	}
	return o.Poster, o.Rung, o.PostedAt
}

// OfferChallenge reports who an offer is aimed at and what its poster said.
// A zero opponent means open to anyone.
func OfferChallenge(id int64) (address, string) {
	o := getOffer(id)
	if o == nil {
		return "", ""
	}
	return o.Opponent, o.Label
}

// DuelOf reports a live duel: poster, taker, rung, THE PINNED ROUND, and the
// height it was accepted at.
//
// THE ROUND IS THE IMPORTANT ONE AND IS WHY THIS SHAPE DIFFERS FROM THE
// SUPERSEDED REALM'S. That realm returned a reveal deadline, a resolved flag
// and a winner, because its duels sat in state until somebody opened them.
// Here Resolve pays and DELETES in the same call, so a duel in this tree is by
// definition unsettled and there is no winner to report. What a caller wants
// instead is the round -- pair it with beacon.TimeOfRound(round) and you have
// the countdown.
func DuelOf(id int64) (address, address, int64, int64, int64) {
	d := getDuel(id)
	if d == nil {
		return "", "", 0, 0, 0
	}
	return d.Poster, d.Taker, d.Rung, d.Round, d.AcceptedAt
}

func DuelLabel(id int64) string {
	d := getDuel(id)
	if d == nil {
		return ""
	}
	return d.Label
}

// DuelRound is DuelOf's fourth value on its own, because it is the one a
// countdown polls and a caller should not have to decode a five-tuple to get
// it. 0 for an unknown or already-settled duel.
func DuelRound(id int64) int64 {
	d := getDuel(id)
	if d == nil {
		return 0
	}
	return d.Round
}

// PendingPot is the raffle's share of settled duels' rake, earned and booked
// but not yet delivered. FlushPot's own doc comment told callers to read this
// and IT DID NOT EXIST -- a comment pointing at a function nobody wrote, which
// is the shape this project has met repeatedly today.
func PendingPot() int64 { return pendingPot }

// PendingEntryUnits and PendingEntryHolders are what FlushPot will deliver
// alongside the pot. A keeper reads all three to decide whether calling is
// worth the gas.
func PendingEntryUnits() int64 { return pendingEntryUnits }

func PendingEntryHolders() int64 { return int64(pendingEntries.Size()) }

// PendingSince is the height the current booking started accruing, or 0 when
// nothing is booked. It is SweepStuckRake's grace clock, exposed so the wait
// is visible rather than inferred.
func PendingSince() int64 { return pendingSince }

// --- recent results, a bounded ring ----------------------------------------
//
// WHY THIS EXISTS. Resolve pays and DELETES the duel in the same call, so a
// settled duel leaves no state whatsoever. That is right for storage and wrong
// for the product: this design's whole point is that MANY DUELS SHARE A ROUND
// AND SETTLE TOGETHER, and a front end that showed nothing a second later would
// throw away the one moment the design was built to create.
//
// WHY IT IS BOUNDED, AND WHAT THAT COSTS. A realm cannot be pruned and nothing
// here can delete on a caller's behalf, so an unbounded history is a storage
// leak that grows for ever with no exit -- the exact shape this project forbids
// for money and forbids here for the same reason. So the ring keeps the last
// resultRingSize settlements and overwrites the oldest.
//
// WHAT IS LOST: everything older falls off and is recoverable ONLY from the
// chain's event log, which DuelResolve writes in full. That is a real loss and
// is stated rather than buried -- a reader must not mistake this for the
// complete history.
const resultRingSize = 32

type Result struct {
	DuelID int64
	Round  int64
	Winner address
	Loser  address
	Rung   int64
	Height int64
}

var (
	results    []Result // len is capped at resultRingSize
	resultNext int      // write cursor; wraps
	resultSeen int64    // total ever recorded, including those overwritten
)

// recordResult is called by Resolve immediately before it emits, with the
// values it has already computed. It never panics and never allocates beyond
// the ring: once full it overwrites in place.
func recordResult(duelID, round int64, winner, loser address, rung int64) {
	r := Result{
		DuelID: duelID,
		Round:  round,
		Winner: winner,
		Loser:  loser,
		Rung:   rung,
		Height: runtime.ChainHeight(),
	}
	resultSeen++
	if len(results) < resultRingSize {
		results = append(results, r)
		resultNext = len(results) % resultRingSize
		return
	}
	results[resultNext] = r
	resultNext = (resultNext + 1) % resultRingSize
}

// ResultCount is how many settlements the ring currently holds, which is at
// most resultRingSize. Read ResultsSeen for how many there have ever been.
func ResultCount() int64 { return int64(len(results)) }

// ResultsSeen is every settlement this realm has ever made, including those the
// ring has overwritten. The gap between this and ResultCount is exactly what a
// caller must go to the event log for.
func ResultsSeen() int64 { return resultSeen }

// ResultRingSize is the bound, exported so a front end can say "last 32"
// without hardcoding a number that might change.
func ResultRingSize() int64 { return resultRingSize }

// RecentResults returns up to `limit` settlements, MOST RECENT FIRST. limit is
// clamped to the ring's size.
func RecentResults(limit int64) []Result {
	n := int64(len(results))
	if n == 0 {
		return []Result{}
	}
	if limit <= 0 || limit > n {
		limit = n
	}
	out := make([]Result, 0, limit)
	// resultNext points at the oldest slot once full, so walk backwards from
	// the most recently written one.
	i := resultNext - 1
	if i < 0 {
		i = len(results) - 1
	}
	for c := int64(0); c < limit; c++ {
		out = append(out, results[i])
		i--
		if i < 0 {
			i = len(results) - 1
		}
	}
	return out
}

// --- Render ----------------------------------------------------------------
//
// THE PAGE gnoweb SHOWS. The first v2 deployment had none, so anybody who went
// looking at this realm directly saw nothing at all.
//
// IT MUST NEVER PANIC, WHATEVER path IS. A panicking Render does not fail
// quietly on one request -- it takes the realm's whole gnoweb page down, for
// everyone, permanently, with no way to fix it because a realm cannot be
// upgraded. So this function ignores `path` entirely, reads only, and every
// loop below is over a bounded collection.
//
// EVERY PIECE OF CALLER TEXT GOES THROUGH cell(). A Label is free text from a
// poster, and this is a markdown document: an unescaped label can forge table
// rows, inject links, or impersonate the house. sanitize.InlineText handles the
// markdown; the pipe escaping is ours, because a bare | ends a table cell.
func cell(s string) string {
	out := sanitize.InlineText(s)
	esc := ""
	for _, r := range out {
		if r == '|' {
			esc += "\\|"
			continue
		}
		esc += string(r)
	}
	return esc
}

func short(a address) string {
	s := string(a)
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func Render(path string) string {
	out := "# SPLASH — the Duel\n\n"
	out += "Two stakes, one coin, settled from a public randomness round that does not exist yet " +
		"when you commit. Neither player can steer it and neither has to come back.\n\n"

	out += "## The ladder\n\n| rung | stake |\n|---|---|\n"
	for i := range rungs {
		out += "| " + strconv.Itoa(i) + " | " + strconv.FormatInt(rungs[i], 10) + " |\n"
	}

	out += "\n## On the table\n\n"
	if offers.Size() == 0 {
		out += "_Nothing standing._\n"
	} else {
		out += "| # | poster | stake | called out | said |\n|---|---|---|---|---|\n"
		offers.Iterate("", "", func(k string, v any) bool {
			o, ok := v.(*Offer)
			if !ok {
				return false
			}
			target := "anyone"
			if o.Opponent != "" {
				target = short(o.Opponent)
			}
			out += "| " + cell(k) + " | " + short(o.Poster) + " | " +
				strconv.FormatInt(stakeOf(o.Rung), 10) + " | " + target + " | " + cell(o.Label) + " |\n"
			return false
		})
	}

	out += "\n## In the air\n\n"
	if duels.Size() == 0 {
		out += "_No duel is waiting on a round._\n"
	} else {
		out += "Each of these is already locked. The round named below decides it, and nobody " +
			"knows that round's value yet.\n\n"
		out += "| # | poster | taker | stake | decided by round |\n|---|---|---|---|---|\n"
		duels.Iterate("", "", func(k string, v any) bool {
			d, ok := v.(*Duel)
			if !ok {
				return false
			}
			out += "| " + cell(k) + " | " + short(d.Poster) + " | " + short(d.Taker) + " | " +
				strconv.FormatInt(stakeOf(d.Rung), 10) + " | " +
				strconv.FormatInt(d.Round, 10) + " |\n"
			return false
		})
	}

	out += "\n## Settled lately\n\n"
	if len(results) == 0 {
		out += "_Nothing yet._\n"
	} else {
		out += "The last " + strconv.FormatInt(int64(len(results)), 10) + " of " +
			strconv.FormatInt(resultSeen, 10) + " ever settled. Older ones are in the chain's " +
			"event log, not here — this list is deliberately bounded.\n\n"
		out += "| # | won | lost | stake | round |\n|---|---|---|---|---|\n"
		for _, r := range RecentResults(int64(len(results))) {
			out += "| " + strconv.FormatInt(r.DuelID, 10) + " | " + short(r.Winner) + " | " +
				short(r.Loser) + " | " + strconv.FormatInt(stakeOf(r.Rung), 10) + " | " +
				strconv.FormatInt(r.Round, 10) + " |\n"
		}
	}

	out += "\n## The books\n\n"
	out += "- players' money held: " + strconv.FormatInt(escrowed, 10) + "\n"
	out += "- raffle's share booked, awaiting delivery: " + strconv.FormatInt(pendingPot, 10) + "\n"
	return out
}
