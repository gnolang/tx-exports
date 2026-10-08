// Package beacon is SPLASH's on-chain record of the drand evmnet randomness
// beacon.
//
// WHAT CHANGED, AND WHY IT IS NOT A REFACTOR (2026-09-28). This realm used to
// verify signatures from a beacon SPLASH itself ran: one compiled-in BLS key, held
// by this project, publishing a round every five minutes. The key holder could
// sign ANY round at will and therefore knew every future round's randomness
// permanently, which is r/splash/arcade/raffle/AUDIT-2026-09-28.md findings 4 and
// 10 and was the single worst property of the product. It now verifies drand
// evmnet, a threshold beacon this project does not control. Two consequences run
// through every comment below:
//
//   - NOBODY CAN SIGN A FUTURE ROUND. Round r's signature does not exist before
//     its time, and no party below the DKG threshold can make it exist. That is
//     what the games' round bindings are for and it is now true rather than
//     assumed.
//   - NOBODY CAN DESTROY A PAST ROUND. Every round from 1 to the head is served
//     forever by at least three independent relays, and Publish is
//     permissionless, so anything deleted here is re-creatable by anyone. "The
//     randomness is lost" stopped being a reachable state, which is why Prune,
//     PruneWindow and the raffle's resolvable() are gone -- see DRAND-MIGRATION.md
//     section 3.
//
// THIS REALM IS NOT A MIRROR OF DRAND AND MUST NEVER BECOME ONE. At a three-second
// cadence, keeping up would mean one Publish every three seconds at 16,970,375 gas
// each: 0.62% of EVERY BLOCK on the chain, for ever, for data that is read about
// fifty times a year (DRAND-MIGRATION.md sections 2 and 9.5 have the measured
// arithmetic; 9.5 also records that this said 2.4% until 2026-09-30, off by the same
// 4.4x as every other gas figure derived from the pre-optimisation VerifyDrand, and
// that at 0.62% the STORAGE cost rather than the gas share is what rules mirroring out).
// It is an ON-DEMAND RECORD: a round is stored when something on this chain has a
// reason to look at it, and nothing else is stored at all.
//
// There is no owner, no pause and no upgrade path. Once a round is published its
// randomness is fixed for ever.
package beacon

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/bls254"
)

// --- the chain being verified --------------------------------------------

// ChainHash, PeriodSeconds and RoundsPerDay are re-exported from
// p/splash/bls254, which holds the ONE copy of drand evmnet's identity. They are
// re-exported rather than restated so that a realm needing the cadence does not
// have to import a crypto package to get it, and so that there is still exactly
// one place the numbers are written down.
const (
	// ChainHash names the drand chain these signatures belong to.
	ChainHash = bls254.DrandEvmnetChainHash

	// PeriodSeconds is drand evmnet's cadence: one round every three seconds.
	//
	// ANY REALM EXPRESSING A DURATION IN ROUNDS MUST MULTIPLY BY THIS AND COMPARE
	// AGAINST SECONDS. A round count is not a duration. The five-minute beacon
	// this replaces made every round-denominated window in the repository 100x
	// too short at a stroke, and a guard comparing rounds to rounds cannot see
	// it: the cadence appears on both sides and cancels. See
	// DRAND-MIGRATION.md section 6, and r/splash/arcade/raffle's seconds guard,
	// which is the one assertion in the system that would have caught it.
	PeriodSeconds = bls254.DrandEvmnetPeriodSeconds

	// RoundsPerDay is 86400 / PeriodSeconds = 28800. Exported because the raffle
	// and the duel both need it and both used to restate it as 288 -- the same
	// number in two files, wrong in both.
	RoundsPerDay = 86400 / PeriodSeconds

	// drandGenesisTime is round 1's unix timestamp: round r is signed at
	// drandGenesisTime + PeriodSeconds*(r-1). Re-exported from p/splash/bls254
	// for the same reason as the three constants above it -- one place the
	// number is written down -- and it is what CurrentRound and RoundAt below
	// convert the block's own clock against.
	drandGenesisTime = bls254.DrandEvmnetGenesisTime
)

// blocksPerDay is the block-count day unit, ~3.3s blocks, copied from
// r/splash/game which documents the choice. A different package cannot reference
// another's unexported constant, so r/splash/game, r/splash/arcade/duel,
// r/splash/arcade/raffle and now this realm each restate it.
//
// IT IS HERE ONLY FOR EstimatedLatestRound, and only because this realm is the
// one place that holds both clocks at once: rounds, and the height at which each
// round arrived.
const blocksPerDay = 26182

// groupKey is drand evmnet's 128-byte G2 group public key (EIP-197 wire order),
// decoded once at init from the single canonical constant in p/splash/bls254.
// There is no rotation function and no admin path to change it: a different drand
// chain is a different realm.
var groupKey = mustDecodeHex(bls254.DrandEvmnetPubKeyHex)

func mustDecodeHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic("beacon: bad constant hex")
	}
	return b
}

// --- state ----------------------------------------------------------------

// record is one published round: its 64-byte G1 signature and the chain height at
// which it was relayed.
//
// THE HEIGHT IS NOT BOOKKEEPING, IT IS THE ONLY REAL-TIME EVIDENCE A REALM ON
// THIS CHAIN CAN GET, and adding it is the reason this migration is safe at all.
// A drand round existing is a statement about wall-clock time -- round r cannot be
// signed before genesis + 3(r-1) seconds -- and this chain has no block-timestamp
// getter, so a published round is the only unforgeable "time has passed this far"
// a realm can observe. Recording the height it arrived at is what lets a consumer
// relate drand's clock to its own, and without it EstimatedLatestRound cannot
// exist and the raffle's round pin has no defence against a stale beacon at all
// (DRAND-MIGRATION.md section 5b).
type record struct {
	Sig    []byte
	Height int64
}

// rounds maps a zero-padded round key to its record.
var rounds = avl.NewTree()

// latestRound/latestHeight/haveLatest track the highest published round, and the
// height at which THAT round was published, without relying on tree iteration
// order.
//
// latestHeight is the height of the highest ROUND, not the height of the most
// recent Publish. Those differ when somebody relays an old round after a newer
// one.
//
// AND IT IS NOT WHAT EstimatedLatestRound EXTRAPOLATES FROM — anchorHeight is. This
// comment used to say it was, and that was true of the very first version of this realm
// only (see anchorScaled's account of why extrapolating from the highest round's own
// publication height is exploitable). latestHeight is now reported for the record, through
// LatestPublishedAtHeight and Render, and read by nothing that decides anything. The
// distance that bounds the estimate's error is ChainHeight() - anchorHeight; read
// anchorHeight for why measuring from anything else is unsound.
var (
	latestRound  int64
	latestHeight int64
	haveLatest   bool
)

// anchorScaled is the clock EstimatedLatestRound extrapolates from, and it is a
// MAXIMUM over every round ever relayed rather than a property of the highest one.
//
//	anchorScaled = max over relays i of ( round_i*blocksPerDay - height_i*RoundsPerDay )
//
// which is (round_i - height_i * RoundsPerDay/blocksPerDay) scaled up by blocksPerDay
// so that no integer division is lost. It is the y-intercept of the round-versus-height
// line each observation implies, and taking the maximum keeps the highest line anybody
// has ever evidenced.
//
// WHY A MAXIMUM, AND NOT THE HIGHEST ROUND'S OWN (round, height) PAIR. The first
// version of this realm did the latter — it extrapolated from latestRound and the height
// at which latestRound was relayed — AND THAT WAS EXPLOITABLE. Relaying a round only
// slightly above latestRound but still far in the PAST resets the height anchor to now
// and collapses the estimate:
//
//	latestRound=100 relayed at height 0, now at height 1,000,000
//	  -> estimate 100 + 1,000,000*28800/26182 = 1,100,092
//	attacker relays round 200 (real, old, and > 100) at height 1,000,000
//	  -> estimate 200
//
// A consumer pinning estimate + offset would then pin a round whose randomness has been
// public for years, which is AUDIT-2026-09-28.md finding 10's precondition, bought for
// one Publish. A MAXIMUM CANNOT BE PUSHED DOWN: relaying an old round can only raise
// anchorScaled or leave it alone, and raising it moves a consumer's pinned round FURTHER
// into the future, which is the safe direction.
//
// AND IT CANNOT BE PUSHED ARBITRARILY HIGH EITHER, which is the other half of the
// argument. The best an attacker can do is relay drand's CURRENT head as early as
// possible, and nobody can produce a signature above the current head — so anchorScaled
// is bounded above by the true round-versus-height intercept.
//
// IT IS NOT SELF-CORRECTING, AND THE CLAIM THAT IT WAS IS THE DEFECT anchorHeight AND
// maxEstimateStaleBlocks EXIST TO CLOSE. DRAND-MIGRATION.md section 9.8 asserted, and
// this comment asserted with it, that a maximum is "self-correcting in both directions of
// block-time drift". THAT IS FALSE IN THE UPWARD DIRECTION, and it is false in the worst
// possible way — monotonically, permanently, on a realm with no owner and no upgrade
// path. Work it, because reading it will not show it:
//
//   - blocks SLOWER than the assumed ~3.3s: each observation's intercept RISES over
//     time, so the maximum tracks the MOST RECENT observation and any relay of drand's
//     head pulls the estimate back onto the truth. Self-correcting, as claimed.
//   - blocks FASTER: intercepts FALL over time, so the maximum keeps an EARLY one. The
//     estimate then advances at RoundsPerDay/blocksPerDay = 1.099992 rounds per block
//     AS A PURE FUNCTION OF CHAIN HEIGHT, for ever, REGARDLESS OF DRAND — while drand
//     advances B/PeriodSeconds rounds per block for real average block time B. The two
//     agree only at B = 86400/blocksPerDay = 3.29998 s. At ANY faster block time the
//     estimate outruns drand's true head and CAN NEVER COME BACK DOWN, because a
//     maximum does not fall and because relaying the true head no longer raises it
//     (cand < anchorScaled once est > truth). "Pins land later than intended, safe" was
//     true only of the first day; it is monotone, and it ends in
//     r/splash/arcade/duel's bound round never being signed inside VoidStale's window
//     (~10 days at B = 3.0 s) and r/splash/arcade/raffle's pinned round never being
//     signed inside the refund grace (~111 days at B = 3.0 s). See
//     maxEstimateStaleBlocks for the arithmetic and AUDIT-2026-09-28.md finding 12.
//
// NOTE THE SHAPE OF THE TRADE, because it is the most instructive thing here: the fix
// that closed the down-push attack above is what REMOVED the only mechanism that
// corrected upward drift. The single-pair version self-corrected the instant anybody
// relayed the head — it re-anchored on every relay, which is exactly why it could be
// pushed down. Maximum: cannot be pushed down, cannot be corrected up. Single pair: can
// be corrected up, can be pushed down. The bound below is what makes the first of those
// safe, by refusing to extrapolate far enough for the uncorrectable direction to matter.
//
// AND THERE IS AN ACTIVE VARIANT OF THE UPWARD DRIFT, not merely a passive one.
// anchorScaled is the historical MAXIMUM intercept, so ANY period in which the chain ran
// slower than 3.29998 s/block raises it permanently, and one permissionless Publish of
// drand's current head captures that period into it. The captured intercept is CORRECT
// at the moment of capture — the relay proves drand really did advance that far — but it
// is retained for ever, so if the chain then speeds up, the estimate resumes outrunning
// drand from the higher line and no later relay can lower it. A chain HALT is the
// extreme case: no height passes while drand advances D/PeriodSeconds rounds, and a
// height-denominated staleness measure cannot see a halt at all (see
// maxEstimateStaleBlocks' "WHAT THIS DOES NOT BOUND").
//
// OVERFLOW HEADROOM: round*blocksPerDay at drand's ~2.1e7 is ~5.5e11, and
// height*RoundsPerDay at a height of 1e9 is ~2.9e13. Both are five orders of magnitude
// inside int64.
//
// anchorHeight IS THE HEIGHT OF THE RELAY THAT MOST RECENTLY RAISED anchorScaled, and
// it is NOT "the height of the most recent Publish". Every error in this realm's
// extrapolation is proportional to ChainHeight() - anchorHeight and to nothing else, so
// that is the distance the bound below measures. Two reasons the other choice is wrong,
// and the second one is an attack:
//
//  1. A RELAY THAT DOES NOT RAISE THE ANCHOR DOES NOT REDUCE THE ERROR. Once the
//     estimate has drifted above drand's head, relaying the head leaves anchorScaled
//     exactly where it was — that is the whole defect above — so a "most recent Publish"
//     measure would report a fresh beacon while the estimate went on being wrong.
//  2. "MOST RECENT PUBLISH" FRESHNESS IS FORGEABLE FOR THE COST OF ONE Publish. Any
//     unrelayed old round — drand has ~2.1e7 of them, all public — would reset it. So an
//     attacker could hold the beacon "fresh" indefinitely while the estimate drifted
//     arbitrarily far, which is finding 10's precondition bought for ~16.97M gas a relay.
//
// RAISING THE ANCHOR IS HARDER TO FORGE THAN A "LAST Publish" FLAG, AND IT IS NOT
// UNFORGEABLE. The stronger claim stood here and is RETIRED RATHER THAN QUIETLY DROPPED,
// because the bound below was justified by it.
//
// THE RETIRED TEXT, VERBATIM:
//
// RAISING THE ANCHOR, BY CONTRAST, IS UNFORGEABLE, and this is the property that makes
// the bound sound rather than merely conservative. cand > anchorScaled reduces to
// round > est(h): raising the anchor requires a valid signature for a round ABOVE this
// realm's current estimate. Nobody below the DKG threshold can sign a round drand has
// not reached, so the anchor can be refreshed ONLY by a relay that PROVES the estimate
// was behind drand's real head — which is exactly the case in which re-anchoring is
// correct.
//
// (END OF THE RETIRED TEXT.)
//
// EVERY SENTENCE OF IT IS TRUE EXCEPT THE WORD "ONLY", AND "ONLY" WAS THE LOAD-BEARING
// ONE. cand > anchorScaled does reduce to round > est(h), and nobody below the DKG
// threshold can sign a round drand has not reached. What does not follow is that the
// relay proves anything about NOW: the round that has to be signed is est+1, and when the
// estimate LAGS — the only situation this bound exists for — est+1 is a round drand passed
// long ago, one of ~2.1e7 public past rounds whose signature costs an HTTP GET.
//
// AND IT ALWAYS WORKS, not sometimes. From est = floor((anchorScaled + h*RoundsPerDay)/
// blocksPerDay) it follows that
//
//	cand(est+1) = (est+1)*blocksPerDay - h*RoundsPerDay > anchorScaled   ALWAYS
//
// so relaying est+1 ALWAYS raises the anchor, ALWAYS sets anchorHeight = ChainHeight() so
// that StaleBlocks() reads 0, and ALWAYS advances the estimate by EXACTLY ONE ROUND —
// three seconds of drand time bought with one Publish, in exchange for a whole fresh
// budget of maxEstimateStaleBlocks. Repeat once before each budget expires and the lag
// grows without limit while the freshness signal reads zero throughout. This is not a
// derivation to be trusted: it is asserted against the running realm by
// TestKnownWeaknessRelayingTheRoundJustAboveTheEstimateBuysTheWholeStalenessBudgetBack.
//
// SO STATE THE BOUND'S GUARANTEE AT ITS REAL STRENGTH. A raise proves the estimate WAS
// behind drand's head at the moment of the relay. It does NOT prove the estimate has
// CAUGHT UP, and the MAGNITUDE of a raise is unconstrained — est+1 and drand's true head
// are equally valid relays and the realm cannot tell them apart. THE STALENESS BOUND IS
// THEREFORE NOT FORGERY-PROOF. It is a lower bound on how much drand-time has passed,
// enforced against a caller who must at least produce a real signature above the
// estimate; it is not a bound on how far the estimate has fallen behind.
//
// AND NO ON-CHAIN FRESHNESS PREDICATE CAN BE, so this is a floor and not a bug to fix
// here. A drand signature bounds drand's head from BELOW — round R exists implies the
// head is at least R — and what a freshness test needs is a bound from ABOVE, which no
// signature and no chain height can supply. DRAND-MIGRATION.md sections 5b and 5c already
// state that floor and its consequence for every round-number pin; read it there rather
// than re-deriving it. What remains defensible about measuring from anchorHeight is
// reason 1 and the WEAKER half of reason 2: an old round BELOW the estimate resets
// nothing at all, so the bound is still strictly better than "blocks since the last
// Publish", which any round whatsoever resets. Strictly better is not sound.
//
// And the converse is the honest cost, recorded rather than discovered: when the estimate
// is AHEAD of drand's head, NOBODY can refresh the anchor, so the refusal below becomes
// permanent until the chain's own block time falls back behind 3.29998 s. See
// AUDIT-2026-09-28.md finding 12 for what that means for deployment.
var (
	anchorScaled int64
	anchorHeight int64
	haveAnchor   bool
)

// maxEstimateStaleBlocks is how far past the anchor EstimatedLatestRound is willing to
// extrapolate: one day of blocks. Past it, it REFUSES — see EstimatedLatestRoundWithin.
//
// THE DERIVATION. Let
//
//	S = ChainHeight() - anchorHeight          (blocks since the anchor was last raised)
//	A = 86400/blocksPerDay = 3.29998 s        (the block time this realm assumes)
//	B = the chain's real AVERAGE block time over those S blocks
//
// The extrapolation reads S*RoundsPerDay/blocksPerDay = S*A/PeriodSeconds rounds off the
// anchor while drand advances S*B/PeriodSeconds rounds, so
//
//	est - truth = S*(A - B)/PeriodSeconds rounds = S*(A - B) SECONDS of drand time
//
// ONE CONDITION BOUNDS BOTH DIRECTIONS OF ERROR, which is the reason this bound belongs
// here and not in the consumers. The expression above is positive when the chain is
// FASTER than assumed (the estimate outruns drand — the unbounded, uncorrectable
// direction described at anchorScaled) and negative when it is slower (the estimate lags
// — the staleness error section 5b of DRAND-MIGRATION.md was about). Both are
// proportional to the SAME S, so |est - truth| <= S*|A - B| seconds whichever way the
// drift goes, and refusing above a bound on S bounds the error above and below at once.
//
// THE BAND THIS IS STATED AGAINST: B within 10% of A, i.e. 2.97 s to 3.63 s. That is the
// tolerance DRAND-MIGRATION.md section 5b already reasons in, and |A - B| <= 0.33 s at
// its edges. At S = blocksPerDay the admitted error is therefore
//
//	26182 * 0.33 = 8640 seconds = 2.4 hours of drand time
//
// WHY ONE DAY, AND WHY THAT NUMBER IS THE RAFFLE'S AND NOT THE DUEL'S. The two margins
// at risk differ by more than two orders of magnitude, and no single bound serves both:
//
//   - r/splash/arcade/raffle pins a round pinOffsetRounds = 8 days out against a week of
//     sales, a nominal margin of 86400 s. At the slow edge of the band the week itself
//     lengthens (it is a BLOCK count while the pin is a ROUND count), leaving 25915 s.
//     2.4 hours of error fits inside that with 4.8 hours to spare — a 3x margin — so one
//     day of blocks is a sound bound for the raffle, and the raffle asserts exactly that
//     relation at compile time beside its own pinOffsetRounds guard.
//   - r/splash/arcade/duel binds a round duelBindOffsetRounds = 100 rounds out: a margin
//     of 300 SECONDS. 2.4 hours of error destroys it 29 times over. Its tolerance has to
//     be ~450 blocks, and it passes that to EstimatedLatestRoundWithin itself.
//
// SO THE BEACON DOES BOTH: a compile-time BACKSTOP no consumer can exceed or forget
// (this constant, set at the scale of the coarsest consumer), plus a per-call tolerance a
// consumer with a finer margin must state for itself. A fifth consumer that forgets to
// think about staleness gets the backstop; one that thinks about it can only ever ask for
// LESS. That asymmetry is deliberate: EstimatedLatestRoundWithin REFUSES a tolerance
// above this constant, so the backstop cannot be opted out of.
//
// WHAT THIS DOES NOT BOUND, stated here so it is not rediscovered as a surprise:
//
//   - A CHAIN HALT. S counts blocks, so an interval producing no blocks contributes
//     nothing to S while drand advances 28800 rounds a day through it. Equivalently: a
//     halt inflates B, and this bound only holds under the stated band. That is the floor
//     DRAND-MIGRATION.md section 5b records — no realm on this toolchain can obtain an
//     UPPER bound on elapsed real time — and no constant here can move it.
//   - A SUSTAINED BLOCK TIME OUTSIDE THE BAND. At B = 3.0 s the admitted error at this
//     bound is 26182*0.29998 = 7854 s, still inside the raffle's margin; at B = 2.5 s it
//     is 20938 s and is not. The band is an assumption, written down rather than implied,
//     exactly as blocksPerDay itself is.
const maxEstimateStaleBlocks = blocksPerDay

// MaxEstimateStaleBlocks is maxEstimateStaleBlocks, exported so that a consumer can
// state its own tolerance as a fraction of the backstop, assert a relation to it at
// COMPILE TIME (r/splash/arcade/raffle does), or tell a user how fresh the beacon has to
// be. A const, so no caller can move it.
const MaxEstimateStaleBlocks = maxEstimateStaleBlocks

// roundKeyWidth is enough decimal digits for any non-negative int64
// (max is 9223372036854775807, 19 digits).
const roundKeyWidth = 19

const zeroPad = "0000000000000000000"

// roundKey renders round as a fixed-width, zero-padded decimal string so
// that avl.Tree's lexicographic key order matches numeric round order.
// Beacon rounds are round counters and are assumed non-negative; a negative
// round still stores and retrieves correctly by exact key, it just will not
// sort where a caller might expect relative to non-negative rounds.
func roundKey(round int64) string {
	s := strconv.FormatInt(round, 10)
	if len(s) < roundKeyWidth {
		s = zeroPad[:roundKeyWidth-len(s)] + s
	}
	return s
}

// --- Publish --------------------------------------------------------------

// Publish verifies sig for round against drand evmnet's group key and stores it.
// PERMISSIONLESS: anyone may relay any round, because validity is what matters
// and not the sender. Panics if the round is already published or the signature
// does not verify — including if sigHex is not valid hex, which is just another
// shape of "not a valid signature".
//
// THE ROUND NUMBER IS THE MESSAGE and the caller supplies nothing else: the
// signed digest is keccak256 of the round as a big-endian uint64
// (bls254.DrandRoundMessage), so a relayer cannot choose what a round's
// randomness is, only whether to relay it. The chain is UNCHAINED, so no previous
// signature is needed and any round verifies on its own.
//
// bls254.VerifyDrand, NOT bls254.Verify. The two implement different schemes and
// each rejects every signature of the other; Verify is the retired SPLASH
// try-and-increment scheme and is left untouched, still exercised by
// p/splash/bls254's own suite.
//
// COST: 16,970,375 gas measured on this toolchain (zz_gas_test.gno), 0.57% of the 3e9
// block limit — about 176 to a block. Of it, 13,396,451 is bls254.VerifyDrand and
// 12,004,207 of THAT is the RFC 9380 hash-to-curve rather than the pairing: 90% of the
// verification, 71% of the whole Publish. (CORRECTED 2026-09-30: this said "98%", which
// was the pre-optimisation ratio; DRAND-MIGRATION.md section 9.5.) It fits with a wide
// margin, and it is also the reason this realm cannot mirror drand.
//
// A RELAYER CANNOT PUSH latestRound INTO THE FUTURE, and a great deal now rests
// on that. Under the SPLASH key one Publish of a far-future round moved latest
// arbitrarily far in a single transaction, which was the operator-triggered half
// of AUDIT-2026-09-28.md finding 7. drand cannot sign a round whose time has not
// come, so latestRound is bounded above by drand's real head, and that attack is
// dead.
func Publish(cur realm, round int64, sigHex string) {
	if Published(round) {
		panic("beacon: round already published")
	}

	sig, err := hex.DecodeString(sigHex)
	if err != nil {
		panic("beacon: invalid signature")
	}

	if !bls254.VerifyDrand(groupKey, round, sig) {
		panic("beacon: invalid signature")
	}

	h := runtime.ChainHeight()
	rounds.Set(roundKey(round), &record{Sig: sig, Height: h})
	if !haveLatest || round > latestRound {
		latestRound = round
		latestHeight = h
		haveLatest = true
	}
	// THE ANCHOR IS UPDATED ON EVERY RELAY, NOT ONLY ON A NEW HIGHEST ROUND. A relay of
	// an older round still carries real-time evidence — its signature exists, so time has
	// passed at least that far — and the maximum is what makes that evidence impossible
	// to use downwards. See anchorScaled.
	//
	// AND anchorHeight MOVES ONLY WHEN THE ANCHOR ACTUALLY RISES, which is what makes it a
	// BETTER freshness signal than a "somebody called Publish" flag — not, as this comment
	// used to say, an UNFORGEABLE one. Raising the anchor does require a signature for a
	// round above this realm's current estimate; that round is est+1, and when the estimate
	// lags, est+1 is public drand history. Read anchorHeight in full — the claim is retired
	// there — before relying on StaleBlocks() as proof of freshness. Do not move this line
	// out of the branch either: outside it, one Publish of ANY old round would reset the
	// bound, which is strictly worse again.
	if cand := round*blocksPerDay - h*RoundsPerDay; !haveAnchor || cand > anchorScaled {
		anchorScaled = cand
		anchorHeight = h
		haveAnchor = true
	}

	chain.Emit(
		"Publish",
		"round", strconv.FormatInt(round, 10),
		"signature", sigHex,
		"height", strconv.FormatInt(h, 10),
	)
}

// --- reads ----------------------------------------------------------------

func get(round int64) *record {
	key := roundKey(round)
	// gno.land/p/nt/avl/v0's Get returns a single value; existence is a
	// separate Has. Check first so an unpublished round panics rather than
	// type-asserting nil.
	if !rounds.Has(key) {
		return nil
	}
	return rounds.Get(key).(*record)
}

// Randomness returns sha256(signature) for a published round, hex-encoded.
// Panics if the round has not been published.
//
// This is drand's own derivation, not one of ours: the "randomness" field
// /public/<r> serves is exactly sha256 of the signature it serves beside it, which
// makes every real round an independent oracle for this function. testdata's
// fixtures were checked against it.
func Randomness(round int64) string {
	r := get(round)
	if r == nil {
		panic("beacon: round not published")
	}
	sum := sha256.Sum256(r.Sig)
	return hex.EncodeToString(sum[:])
}

// Published reports whether a round has been published.
//
// WHAT IT MEANS NOW: "somebody has relayed this round to this chain". NOT "this
// round's randomness exists" (it may exist on drand and simply not be here yet)
// and NOT "this round's randomness is obtainable" (it always is, from drand).
// Every caller that treats false as "lost" is wrong; see DRAND-MIGRATION.md
// section 3.
func Published(round int64) bool {
	return rounds.Has(roundKey(round))
}

// PublishedAtHeight returns the chain height at which a round was relayed.
// Panics if the round has not been published.
func PublishedAtHeight(round int64) int64 {
	r := get(round)
	if r == nil {
		panic("beacon: round not published")
	}
	return r.Height
}

// Latest returns the highest published round and its randomness. Panics if
// no round has been published yet.
//
// "HIGHEST PUBLISHED", WHICH IS NOT "CURRENT". Under an on-demand record nothing
// relays routinely, so this can be arbitrarily stale — a week old, a year old.
// A CONSUMER PINNING A FUTURE ROUND MUST NOT USE THIS AS "now": use
// EstimatedLatestRound, which corrects for the staleness using a clock no relayer
// controls. Reading this as the current round is exactly how the raffle's round
// pin would silently re-open AUDIT-2026-09-28.md finding 10.
func Latest() (int64, string) {
	if !haveLatest {
		panic("beacon: no round published yet")
	}
	return latestRound, Randomness(latestRound)
}

// LatestPublishedAtHeight returns the chain height at which the highest published
// round was relayed. Panics if no round has been published yet.
func LatestPublishedAtHeight() int64 {
	if !haveLatest {
		panic("beacon: no round published yet")
	}
	return latestHeight
}

// EstimatedLatestRound is this realm's best estimate of the round drand is
// currently on. Panics if no round has ever been published.
//
// A NEW CALLER SHOULD REACH FOR CurrentRound INSTEAD, AND THIS FUNCTION IS KEPT
// ONLY FOR WHAT ALREADY CONSUMES IT. This estimate extrapolates from the last
// RELAYED round, and this realm's own
// TestKnownWeaknessRelayingTheRoundJustAboveTheEstimateBuysTheWholeStalenessBudgetBack
// proves that extrapolation is poisonable for the cost of one Publish of a
// freely-fetched PAST round: relaying est+1 resets the staleness clock to zero
// while moving the estimate forward by exactly one round. CurrentRound instead
// reads the block's own clock and computes drand's round by arithmetic, so there
// is no relayed round to poison. See CurrentRound's comment for the full
// account, including what trusting the block's clock costs in its place.
// Nothing that calls EstimatedLatestRound today has been switched over --
// that is a separate change -- so this function must keep working exactly as
// it does.
//
// IT IS AN ESTIMATE AND THE NAME SAYS SO. There is no way to know the true
// current round on-chain: proving "round r is not signed yet" needs an UPPER bound
// on elapsed real time, published rounds give only a LOWER bound, and chain height
// gives none at all because a halted chain advances no height while drand advances
// 28800 rounds a day. Every round-number pin in this system is therefore an
// assumption about this chain keeping pace with drand, and this function is where
// that assumption lives instead of being spread across three realms.
//
// THE CONSTRUCTION: take anchorScaled — the highest round-versus-height intercept any
// relay has ever evidenced — and read this height off that line. It is exactly
// latestRound at the moment latestRound is relayed. READ anchorScaled BEFORE CHANGING
// THIS: extrapolating from the highest round's own publication height instead is the
// obvious simplification, and it is exploitable.
//
// WHY IT IS STRICTLY BETTER THAN Latest() FOR A PIN. A consumer pinning
// Latest() + offset measures its offset from whenever somebody last happened to
// relay something, so the pin drifts backwards in real time as the beacon goes
// quiet — and the raffle's offset is exactly one day larger than a week, so a
// single day of staleness puts the pinned round's randomness on the public API
// BEFORE the week's ticket sales close, which is finding 10's last-buyer attack
// verbatim. The correction removes that failure entirely in the honest case.
//
// THE ERROR IS BOUNDED BY REFUSAL, AND THAT IS NEW AS OF THE STALENESS BOUND. The
// conversion assumes A = 86400/blocksPerDay = 3.29998 s blocks, so its error is
// S*(A - B) seconds of drand time for S blocks since the anchor was last raised and a
// real average block time B — 2.4 hours at one day of S and a 10% drift in B, NOT the
// ~14 minutes this comment claimed until the figure was re-derived (that number divided
// by the period twice; see maxEstimateStaleBlocks and AUDIT-2026-09-28.md finding 13).
// Unbounded S makes it unbounded in BOTH directions, so this function now REFUSES above
// maxEstimateStaleBlocks rather than returning a number nobody can put a bound on. What
// the refusal costs, and why it is nevertheless right, is at maxEstimateStaleBlocks and
// in AUDIT-2026-09-28.md finding 12.
//
// MONOTONE IN HEIGHT AND NEVER BELOW latestRound: ChainHeight() only rises and
// anchorHeight/anchorScaled never move except upward, so the correction term is never
// negative.
func EstimatedLatestRound() int64 {
	return EstimatedLatestRoundWithin(maxEstimateStaleBlocks)
}

// EstimatedLatestRoundWithin is EstimatedLatestRound with the caller's own staleness
// tolerance, in blocks, for a consumer whose real-time margin is finer than the
// backstop's. r/splash/arcade/duel uses it: its bound round is 300 SECONDS out, and the
// backstop admits 2.4 hours of error.
//
// IT CAN ONLY EVER ASK FOR LESS. A tolerance above maxEstimateStaleBlocks is refused, so
// this is not a way around the backstop — a consumer can tighten the bound and cannot
// loosen it. Read maxEstimateStaleBlocks for why the two-level shape exists at all.
//
// Panics if no round has ever been published, if the tolerance is not positive, if it
// exceeds the backstop, or if the beacon is staler than the tolerance allows.
func EstimatedLatestRoundWithin(maxStaleBlocks int64) int64 {
	if !haveLatest {
		panic("beacon: no round published yet")
	}
	if maxStaleBlocks <= 0 {
		panic("beacon: staleness tolerance must be positive")
	}
	if maxStaleBlocks > maxEstimateStaleBlocks {
		// A caller asking for more than the backstop is asking for an error nobody has
		// bounded. Refused rather than silently clamped, because a clamp would let the
		// request look granted.
		panic("beacon: staleness tolerance exceeds the beacon's own bound")
	}
	if StaleBlocks() > maxStaleBlocks {
		// THE REFUSAL, AND IT IS THE POINT OF THE WHOLE BOUND. Loud, because the
		// alternative is an extrapolation whose error nothing in this system limits: at
		// this distance the estimate may be arbitrarily far above OR below drand's real
		// head, and a consumer pinning against it would bind a round that is already
		// public (finding 10) or one that will not be signed inside its own grace window
		// (finding 12).
		//
		// THE REMEDY IS IN ANY CALLER'S HANDS, AND SO IS THE DIAGNOSIS. One Publish of
		// drand's CURRENT round clears this whenever the estimate is behind drand's head,
		// which is the ordinary case — an on-demand record simply going quiet. If a relay
		// of the current head does NOT clear it, that is itself the diagnosis: the anchor
		// could not be raised, so this chain's average block time has fallen below
		// 3.29998 s and this realm's extrapolation no longer tracks drand. That case
		// cannot be fixed from inside this realm — see anchorHeight, and
		// AUDIT-2026-09-28.md finding 12, which records it as blocking.
		panic("beacon: no relay has raised the estimate's anchor recently — the estimate is too stale to extrapolate; relay drand's current round")
	}
	return extrapolatedRound()
}

// extrapolatedRound is the extrapolation itself, WITH NO STALENESS CHECK. Unexported on
// purpose: an unbounded extrapolation is exactly what this realm must not hand a
// consumer. It exists separately so that Render can show the number it would have
// returned without panicking on a read path, and so that this package's own tests can
// assert the drift arithmetic at distances the exported functions refuse.
func extrapolatedRound() int64 {
	est := (anchorScaled + runtime.ChainHeight()*RoundsPerDay) / blocksPerDay
	if est < latestRound {
		// BELT AND BRACES, and the belt is what matters: an estimate BELOW the highest
		// round anybody has relayed would move a consumer's pinned round backwards in
		// real time, which is the one direction that is unsafe. It is unreachable on
		// chain — anchorScaled is a maximum that includes latestRound's own observation,
		// so the line passes through (latestHeight, latestRound) or above it, and height
		// only rises — but a future change to the anchor must not be able to break it
		// silently. (It IS reachable under `gno test`, where realm state persists across
		// test functions while ChainHeight() resets; see DRAND-MIGRATION.md section 9.7.)
		return latestRound
	}
	return est
}

// StaleBlocks is how far the chain has moved since the last relay that RAISED the
// estimate's anchor: the one distance every error in this realm's extrapolation is
// proportional to. Panics if no round has ever been published.
//
// IT IS NOT "BLOCKS SINCE THE LAST Publish", and the difference is the whole soundness
// argument — read anchorHeight. A relay that does not raise the anchor does not reduce
// the error, and "blocks since the last Publish" is resettable by anyone for the cost of
// relaying any one of drand's ~2.1e7 public past rounds.
//
// EXPORTED SO A CONSUMER OR A FRONT END CAN SEE THE REFUSAL COMING rather than discover
// it as a panic in the middle of a settlement, and so a caller can decide to relay a
// round first. Clamped at zero: a negative distance is unreachable on chain (height only
// rises, anchorHeight only moves to a then-current height) and arises only under
// `gno test`, where ChainHeight() resets between test functions while realm state
// persists — DRAND-MIGRATION.md section 9.7.
func StaleBlocks() int64 {
	if !haveAnchor {
		panic("beacon: no round published yet")
	}
	s := runtime.ChainHeight() - anchorHeight
	if s < 0 {
		return 0
	}
	return s
}

// AnchorHeight is the chain height of the last relay that raised the estimate's anchor.
// Panics if no round has ever been published. See anchorHeight and StaleBlocks.
func AnchorHeight() int64 {
	if !haveAnchor {
		panic("beacon: no round published yet")
	}
	return anchorHeight
}

// EstimateIsUsable reports whether EstimatedLatestRound would return rather than panic.
// A read, so a caller can check before committing to a transaction that would revert.
func EstimateIsUsable() bool {
	return haveLatest && haveAnchor && StaleBlocks() <= maxEstimateStaleBlocks
}

// --- CurrentRound: the block's own clock, not a relayed extrapolation -----

// CurrentRound is the drand round that exists NOW, computed from the BLOCK's own
// clock rather than extrapolated from whatever a relayer last chose to deliver.
//
// WHY IT IS BETTER THAN EstimatedLatestRound, WHICH IT IS INTENDED TO REPLACE.
// The estimate's input is the last RELAYED round, and this realm's own
// TestKnownWeaknessRelayingTheRoundJustAboveTheEstimateBuysTheWholeStalenessBudgetBack
// shows that relaying the round just above it resets the staleness clock for
// ~0.017 GNOT while advancing the estimate by one round. No arithmetic over
// relayed rounds can fix that: what a caller needs is an UPPER bound on drand's
// head ("round R is not signed yet"), a signature only ever proves a LOWER bound,
// and the ABSENCE of a signature is not provable on chain at all because
// withholding is free and invisible.
//
// A CLOCK HAS NO SUCH ASYMMETRY. drand round r is signed at
// genesis + period*(r-1), so the round that exists at time t is pure arithmetic
// over t. No relayer is involved, so there is nothing to withhold and nothing to
// poison.
//
// WHAT IT COSTS, SAID PLAINLY RATHER THAN DISCOVERED LATER: it trusts the chain's
// block time. Under Tendermint that is the voting-power-weighted median of the
// validators' own timestamps, so moving it requires colluding validators rather
// than a tenth of a cent. That is a WEAKER assumption than cryptography and a far
// STRONGER one than "no relayer withheld anything". For a caller that previously
// trusted the estimate it is an improvement on both axes; for one that trusted
// nothing, it is a new assumption and should be chosen deliberately.
func CurrentRound() int64 {
	return RoundAt(time.Now().Unix())
}

// RoundAt is CurrentRound's arithmetic made callable at an arbitrary time, so the
// round-versus-time relationship is testable directly and so a caller can reason
// about a round in the future (or the past) rather than only the current one.
// Panics under the same condition as CurrentRound: see there for why.
func RoundAt(unixSeconds int64) int64 {
	if unixSeconds < drandGenesisTime {
		// A ROUND BEFORE ROUND 1 IS NOT A ROUND, and returning a negative number
		// silently is exactly how a bad round reaches a draw. This is not a
		// theoretical edge: `gno test`'s default block timestamp is 1234567890
		// (February 2009), which is BEFORE drand evmnet's genesis of 1727521075
		// (September 2024), so a naive (t-genesis)/period+1 is negative under the
		// harness's own starting state and every test must set the time forward
		// explicitly before this function means anything.
		panic("beacon: block time " + strconv.FormatInt(unixSeconds, 10) +
			" is before drand evmnet's genesis " + strconv.FormatInt(drandGenesisTime, 10) +
			" — there is no round before round 1")
	}
	return (unixSeconds-drandGenesisTime)/PeriodSeconds + 1
}

// TimeOfRound is RoundAt's inverse: the unix second at which round is signed.
// Needed so a caller can say "this round is signed N seconds from now" (or ago),
// and so the round<->time relationship can be checked in both directions rather
// than trusted in one.
//
// Unlike RoundAt, this does not panic for round < 1: a round number is just an
// integer here, and the arithmetic is exact and total in both directions. A
// caller asking for round 0 or below is asking "what time would this
// (non-existent) round have been", which is an arithmetic question with a
// well-defined answer, not a claim that such a round exists.
func TimeOfRound(round int64) int64 {
	return drandGenesisTime + PeriodSeconds*(round-1)
}

// --- no Prune, and that is deliberate -------------------------------------
//
// THERE IS NO Prune AND NO PruneWindow, AND NOTHING SHOULD REINTRODUCE THEM.
// They existed because this realm used to try to mirror a five-minute beacon and
// needed the state bounded. Four reasons they are gone, in order of weight:
//
//  1. A ROUND COUNT CANNOT EXPRESS A RETENTION DURATION any more. PruneWindow was
//     documented as "7 days" and compared against latestRound — a number that now
//     advances only when somebody happens to relay something. It was a duration in
//     a unit that no longer tracks time, and at a three-second cadence its old
//     value of 2016 meant a hundred minutes.
//  2. NOTHING SURPLUS IS STORED. Every round in the tree is one a draw or a duel
//     asked for. A week of mirrored signatures would be 201600 rounds, 12.9 MB of
//     signature bytes alone; an on-demand record is 64 bytes per round actually
//     used, and ten thousand rounds is under a megabyte.
//  3. DELETION IS NO LONGER DESTRUCTION, so a window protects nothing. Any deleted
//     round is re-fetchable from three drand relays and re-publishable by anyone.
//     The window existed to stop a delete destroying a live game's randomness; a
//     delete cannot destroy anything now.
//  4. AND SO A DELETE FUNCTION WOULD BE A PURE GRIEF VECTOR: its only remaining
//     use is removing a round some pending Resolve depends on, moments before it
//     runs. Recoverable, but free to the attacker and not to the victim, with no
//     compensating benefit left.
//
// THE RESIDUAL RISK THIS ACCEPTS, recorded rather than discovered: Publish is
// permissionless with no owner, so state grows without an upper bound. The bound
// is economic — 16.97M gas a round, ~176 rounds per block if someone burns every
// block's entire gas on it. That is a chain-level denial of service with a
// chain-level answer, and a round window would not have stopped it either.

// Render implements the realm's human-readable view.
func Render(path string) string {
	if path == "" {
		if !haveLatest {
			return "# SPLASH beacon\n\ndrand evmnet, chain " + ChainHash +
				"\n\nNo rounds published yet.\n"
		}
		r, rnd := Latest()
		// THE ESTIMATE IS SHOWN THROUGH extrapolatedRound, NOT EstimatedLatestRound, so
		// that a render NEVER PANICS. EstimatedLatestRound refuses past
		// maxEstimateStaleBlocks, and a page that goes blank in exactly the state a
		// reader most needs to understand would be the worst possible behaviour here.
		// The staleness and the bound are printed beside it, and the line says in words
		// that a consumer would be refused this number — which is the fact a reader
		// needs, whereas the panic would only hide it.
		stale := StaleBlocks()
		usable := "yes"
		if stale > maxEstimateStaleBlocks {
			usable = "NO — too stale to extrapolate; relay drand's current round"
		}
		return "# SPLASH beacon\n\ndrand evmnet, chain " + ChainHash +
			"\n\nHighest published round: " + strconv.FormatInt(r, 10) +
			"\nRandomness: " + rnd +
			"\nRelayed at height: " + strconv.FormatInt(latestHeight, 10) +
			"\nEstimated current round: " + strconv.FormatInt(extrapolatedRound(), 10) +
			"\nBlocks since the anchor was last raised: " + strconv.FormatInt(stale, 10) +
			" of " + strconv.FormatInt(maxEstimateStaleBlocks, 10) +
			"\nUsable as an anchor for a round pin: " + usable + "\n"
	}

	round, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "# SPLASH beacon\n\nUnknown path.\n"
	}
	if !Published(round) {
		return "# SPLASH beacon\n\nRound " + strconv.FormatInt(round, 10) +
			" has not been relayed to this chain.\n"
	}
	return "# SPLASH beacon\n\nRound " + strconv.FormatInt(round, 10) +
		"\nRandomness: " + Randomness(round) +
		"\nRelayed at height: " + strconv.FormatInt(PublishedAtHeight(round), 10) + "\n"
}
