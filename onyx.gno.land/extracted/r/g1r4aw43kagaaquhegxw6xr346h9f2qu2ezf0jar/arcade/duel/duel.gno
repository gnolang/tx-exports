// Package duel implements r/splash/arcade/duel: Splash Play I, the Duel
// (SPEC-03 v1.0, ../../../../SPEC-03-duel.md).
//
// Two players, a matched stake from a fixed ladder, 50/50, winner takes both
// stakes less a 3% rake. Matching is an OPEN LOBBY: a poster leaves a stake
// standing and any other USER — including the poster (SPEC-03 §7.3) — may
// take it. (A USER: both Post and Accept require a direct user call since
// 2026-09-30, so no realm can be a party to a duel. requireUserCall has the
// reasoning, and it is this realm's own escrow that needs it.)
// A poster MAY instead address the offer to one opponent, in which
// case only that address may take it, and MAY attach a short label ("loser
// buys lunch"). Both are descriptive only: neither touches settlement, and the
// coin still decides.
//
// THE STAKE IS WRAPPED GNOT. SPLASH launches on GNOT only — the SPLASH token
// economy is shelved — so this realm escrows gno.land/r/gnoland/wugnot, the
// GRC20 wrapper over the chain's native ugnot (6 decimals: 1 GNOT = 1e6
// ugnot). It is the only token this realm touches. r/splash/token is left
// untouched for when the token returns; nothing here depends on it.
//
// THE REALM BOUNDARY WAS DELIBERATELY NOTHING (SPEC-03 §2) UNTIL 2026-09-29, AND IT
// IS NOW EXACTLY ONE THING. The sentence that used to stand here — "it holds no
// authority over r/splash/arcade/raffle, r/splash/beacon or r/gnoland/wugnot: no
// package-path guard anywhere admits it" — is no longer true of the raffle and is
// corrected rather than quietly deleted.
//
// THE ONE AUTHORITY: raffle.FundPotWithEntries admits THIS PACKAGE PATH AND NO
// OTHER, because playing a duel now earns the two players entries in the raffle's
// live week (AUDIT-2026-09-28.md finding 15, and see pendingEntries). Everything
// else is as it was: this is an ordinary realm holding liquid GRC20 wugnot in
// escrow, and the other raffle function it calls — FundPot — is still a
// permissionless caller-pays door any address could call with its own money.
//
// WHAT A TOTAL COMPROMISE OF THIS REALM CAN NOW DO, restated honestly because the
// old sentence understated it: lose the stakes of currently-open duels, as before,
// AND credit raffle entries to addresses of its choosing — but only by DELIVERING
// THE MONEY FOR THEM, because the raffle re-derives its own ceiling from the amount
// it receives in the same call and refuses a batch that claims more (see
// raffle.ArcadeEntryUnitsBound). It cannot mint an entry, cannot move an ugnot out
// of the raffle, cannot reach a past week, and cannot resolve anything. The bound
// is what limits the authority; the guard only decides who may reach it.
//
// THE RAKE FEEDS THE WEEKLY RAFFLE (changed 2026-09-28). It used to fund
// r/splash/game's yield index and prize pot; that permanent-deposit yield product
// is retired, SPLASH launches as the weekly ticket raffle plus this coin flip, and
// nothing is held beyond a week. So the players' side of every rake is sponsored
// into the raffle's CURRENT week's pot. See Collect.
//
// AND PLAYING NOW EARNS ENTRIES IN THAT WEEK'S DRAW (changed 2026-09-29). The rake
// alone was not enough: the money arrived and the entrants did not, so a week of
// busy coin flipping and no ticket sales could be won whole by one 0.1 GNOT ticket
// bought in its final block. Every settled duel now credits its two players entries
// worth EXACTLY what its rake would have bought at raffle.EntryUnitPrice — the loser
// getting two thirds of them — so the people whose money built the pot are in the
// draw for it. Pricing off the rake rather than the stake is what makes that safe
// against two accounts flipping each other; read rakeEntryUnits, which is the
// security property of the feature. AUDIT-2026-09-28.md finding 15.
//
// BUT NOT IN THE SAME TRANSACTION AS THE WINNER'S PAYOUT, AND THAT IS THE ONE
// STRUCTURAL CHANGE OF 2026-09-28's LATER FIX. Collect used to call raffle.FundPot
// directly, which ends in the raffle's own solvency check — so any panic in the raffle
// took the winner's payout down with it, permanently, because VoidStale refuses a
// resolved duel. Collect now BOOKS the players' side (pendingPot) and FlushPot delivers
// it, permissionlessly, whenever the raffle will take it. A RESOLVED DUEL'S PAYOUT NO
// LONGER DEPENDS ON ANOTHER REALM'S BOOKKEEPING. Read pendingPot for the two exits and
// why neither is a new money sink.
//
// RANDOMNESS: A TWO-PARTY COMMIT-REVEAL BETWEEN THE ONLY TWO PEOPLE WHO CARE, AND SINCE
// 2026-09-30 THIS REALM DOES NOT IMPORT r/splash/beacon AT ALL.
//
//	Post   carries commitHash = H(commitTag ‖ secret), the poster's 32-byte secret.
//	Accept carries a PLAINTEXT 32-byte nonce from the taker. No commitment, no reveal
//	       from the taker, and no extra transaction — one more argument on the call
//	       they already make.
//	Reveal opens the commitment. outcome = H(outcomeTag ‖ secret ‖ nonce ‖ duelID),
//	       last byte's parity, exactly as posterWins always read it.
//	       PERMISSIONLESS: the hash is the authorisation, so anybody may settle.
//	Forfeit pays the TAKER after revealWindowBlocks if the poster never opens.
//
// WHY IT HOLDS: the poster cannot grind, because the nonce does not exist when they
// commit; the taker cannot steer, because they choose the nonce without the secret. No
// round to wait for, so settlement is available in the very next block, the window is one
// clock read off chain height, and no 17M-gas drand relay sits in anyone's critical path.
//
// WHAT IT REPLACES, AND WHY A BETTER FRESHNESS CHECK WAS NOT AN OPTION. Accept used to
// bind Round = beacon.EstimatedLatestRoundWithin(duelMaxStaleBlocks) +
// duelBindOffsetRounds — 300 seconds of drand rounds past a staleness-bounded estimate of
// drand's head — and Resolve read that round's randomness once somebody relayed it. THAT
// IS BROKEN AND THERE IS A TEST PROVING IT:
// r/splash/beacon's TestKnownWeaknessRelayingTheRoundJustAboveTheEstimateBuysTheWholeStalenessBudgetBack
// shows that relaying the round JUST ABOVE the estimate resets the staleness clock to zero
// while advancing the estimate by exactly one round, for 0.0170 GNOT — about a tenth of a
// US cent. Repeat it and the estimate lags arbitrarily far behind drand's real head; once
// it lags past the 100-round offset, the bound round's randomness is already public on
// api.drand.sh and a taker computes the winner BEFORE accepting. SPEC-03 §7.1 calls
// exactly that "the single fatal bug of this design".
//
// IT CANNOT BE FIXED BY A TIGHTER STALENESS BOUND, WHICH IS THE WHOLE REASON THE SOURCE
// OF RANDOMNESS CHANGED RATHER THAN ITS TOLERANCE. What the contract needs is an UPPER
// bound on drand's head ("round R is not yet signed"). A signature proves a LOWER bound
// ("round R exists"); the ABSENCE of a signature is not provable on chain at all, because
// a relayer chooses what to relay and withholding is free and invisible. So no arithmetic
// over relayed rounds can ever establish the property Accept needed. See
// r/splash/beacon/DRAND-MIGRATION.md §5b/§5c and the retired "unforgeable" claim in
// beacon.gno.
//
// ============================================================================
// WHAT THIS DESIGN DOES NOT GIVE YOU — READ BEFORE YOU PLAY, TWO ITEMS
// ============================================================================
//
// (1) THE SECRET'S ENTROPY IS UNENFORCEABLE ON CHAIN, AND commitHash IS A FREE OFFLINE
// VERIFICATION ORACLE. Anybody can take a published commitHash and try candidate secrets
// against H(commitTag ‖ secret) on their own machine, for nothing, for as long as they
// like. A secret drawn from anything a person could think of — a word, a date, a counter,
// Math.random(), a small integer padded to 32 bytes — WILL be found, and the finder then
// picks the nonce that makes them win, or waits for the reveal window and forfeits a duel
// the poster had actually won. The reveal that robs you is a VALID reveal: it passes the
// hash check, this realm cannot tell it from yours, and there is no event that says
// anything went wrong. THE PAGE MUST DRAW THE SECRET FROM A CSPRNG
// (crypto.getRandomValues, crypto/rand, /dev/urandom), 32 bytes, and it must be FRESH FOR
// EVERY OFFER. There is deliberately no on-chain entropy check: a 32-byte string is a
// 32-byte string, and a contract that tried to judge one would only be rejecting honest
// posters. checkCommitment enforces the only thing that IS checkable — the length and the
// encoding — and liveCommitments refuses the one reuse case a contract can see.
//
// (2) A POSTER WITH MEMPOOL VISIBILITY HAS A FREE OPTION ON THE TAKER'S NONCE, AND THIS
// IS AN OPEN, UNCLOSED WEAKNESS OF THE DESIGN. The nonce travels in the clear in the
// Accept transaction. A poster who sees that transaction before it is committed knows the
// secret, the nonce and the duel ID that Accept will assign — so they can compute the
// outcome and, if they are about to lose, try to make the Accept fail: by cancelling the
// offer, or by taking their own offer (SPEC-03 §7.3 permits it) for the cost of the rake
// alone. Either move costs them at most 3% of the pool and saves them 50% of it. It is
// NOT fixed by removing Cancel — the self-match route survives that — and it is NOT fixed
// by mixing the accept height into the outcome, because a poster can enumerate the two or
// three heights their abort could land in. THE ONLY CLOSURES ARE A SECOND TAKER
// TRANSACTION (commit the nonce, reveal it later), WHICH THIS DESIGN DELIBERATELY REFUSES,
// OR AN ON-CHAIN VALUE NOBODY CAN PREDICT, WHICH IS THE BEACON THIS CHANGE JUST REMOVED.
// What bounds it today is that the abort must be ORDERED BEFORE an Accept that was already
// broadcast: a FIFO mempool puts the abort second and the taker wins. That is a property
// of the node software and the proposer, not of this contract, so it is recorded as an
// assumption and not as a defence. See TestBreak_APosterWhoSeesTheNonceEarlyHasAFreeAbort,
// which drives the option rather than describing it, and the addendum to
// AUDIT-duel-2026-09-27.md.
//
// STORAGE IS PERMANENT AND IS RECLAIMED (SPEC-03 §7): Cancel, Collect, Forfeit
// and VoidStale all DELETE their record. Nothing in this realm is ever marked
// "settled" and kept.
package duel

import (
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"strconv"
	"strings"
	"unicode/utf8"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/arcade/raffle"
)

// --- the economics (BIBLE.md §2.6, normative) ----------------------------

const (
	// rakeBps is the arcade rake: 300 bps of the pool, i.e. of 2 x stake
	// (BIBLE.md "Arcade rake"; SPEC-03 §5's "mulDiv(2 x stake, 3, 100)" is the
	// same number written over 100).
	rakeBps  = 300
	bpsDenom = 10000

	// The rake splits 60% to THIS WEEK'S RAFFLE POT / 40% to operations, DUST TO
	// THE POT (BIBLE.md §2.7, the remainder rule binding on every split). The ops
	// share is floored; the pot share is whatever is left, so the two parts always
	// sum EXACTLY to the rake and no unit can vanish.
	//
	// IT WAS 50 YIELD / 30 PRIZES / 20 OPS, and the 50 and the 30 are now ONE
	// NUMBER, not two doors. r/splash/game's permanent-deposit yield product is
	// retired — SPLASH launches as the weekly ticket raffle and this coin flip,
	// with nothing held beyond a week — so the yield share had nowhere left to go
	// and is folded into the pot share rather than dropped. THE HOUSE/PLAYER SPLIT
	// IS THEREFORE UNCHANGED: ops is still floor(rake x 2000 / 10000) computed the
	// same way, and the players' side is still everything else,
	// 5000 + 3000 = 8000 bps plus every unit of integer-division dust. What
	// changed is only WHERE the players' side lands: one FundPot call into
	// r/splash/arcade/raffle's current week instead of game.FundYield plus
	// game.FundPrizes.
	// THE SPLIT MOVED 80/20 -> 60/40 ON 2026-09-29, AT THE OWNER'S INSTRUCTION, AND
	// THE TOTAL RAKE DID NOT MOVE. rakeBps is still 300 and nothing about what a
	// player pays or is paid changed: a duel's winner still takes pool - rake, so THE
	// PLAYER'S EDGE AGAINST THE HOUSE IS EXACTLY WHAT IT WAS. What moved is only
	// which side of the house the 300 bps lands on, and
	// TestFix24_ThePlayersEdgeAgainstTheHouseIsUnchangedByTheRakeSplit asserts that
	// against the arithmetic rather than against a constant.
	//
	// TWO THINGS ELSE MOVE WITH IT AND BOTH ARE RE-DERIVED RATHER THAN LEFT STALE:
	// the raffle's arcadeRakePotShareBps restates this number at its door and is
	// changed in the same commit (a drift either refuses honest batches or reopens
	// finding 15), and maxEntryUnitsFor's gross-up is 10000/6000 rather than
	// 10000/8000. AUDIT-2026-09-28.md finding 24.
	rakePotShareBps = 6000
	rakeOpsShareBps = 4000
	// pot = rake - ops: the remainder, and all integer-division dust. The
	// rakePotShareBps constant above is the pot's FLOOR share, asserted against in
	// splitRake; the pot is never paid less than it and takes the dust on top.
)

// A NEGATIVE ARRAY LENGTH IS A COMPILE ERROR, so this line fails the BUILD if a
// future edit pushes the two named shares past the denominator — the case in
// which the pot remainder would go negative and Collect would silently pay out
// more than the rake. r/splash/game's Claim carries the same guard at runtime;
// here it is caught before the code can run at all. (Zero elements as the shares
// stand, which is ideal: the GnoVM does materialise the array — see init below —
// so this guard must never be given a large length.)
var _ [bpsDenom - rakePotShareBps - rakeOpsShareBps]struct{}

// AND THE POT'S SHARE MUST BE BOUNDED FROM ABOVE AS WELL, WHICH IT WAS NOT UNTIL
// 2026-09-30. This is AUDIT-duel-2026-09-27.md addendum 2, finding D-2, and it is the
// missing half of rakeEntryUnits' security argument rather than a tidiness guard.
//
// THE ARGUMENT IT PROTECTS, RESTATED WITH ITS REAL MARGIN. rakeEntryUnits claims that
// "priced off the rake, FLIPPING IS NEVER CHEAPER THAN BUYING". Read as weight per ugnot
// SPENT, that claim holds with ZERO MARGIN at three of the four rungs: a rake of
// EntryUnitPrice buys exactly one unit, and so does a ticket price of EntryUnitPrice. The
// STRICT inequality lives in one place only — the PRIZE MONEY each route puts behind one
// unit of weight:
//
//	BOUGHT:  EntryUnitPrice x (bpsDenom - raffle.HouseCutBps) / bpsDenom = 237,500 ugnot
//	FLIPPED: EntryUnitPrice x rakePotShareBps / bpsDenom                = 150,000 ugnot
//
// A flipped unit is backed by less prize money than a bought one, so self-dealing is
// weakly WORSE than buying and the feature is safe. THE ONLY THING SEPARATING THOSE TWO
// NUMBERS IS rakePotShareBps = 6000 AGAINST raffle.HouseCutBps = 500. Raise the pot's
// share of the rake past bpsDenom - HouseCutBps = 9500 bps and the inequality FLIPS:
// flipping strictly dominates buying, nobody buys a ticket again, and one funded account
// owns every draw — which is exactly the defect rakeEntryUnits exists to prevent, arrived
// at by editing a number this file calls a free dial.
//
// THE EXISTING GUARDS CANNOT CATCH IT, and that is why this line is not redundant:
//
//   - the guard above bounds rakePotShareBps + rakeOpsShareBps by bpsDenom, i.e. it only
//     refuses a split that does not sum. 9600/400 sums perfectly.
//   - r/splash/arcade/raffle's `var _ [arcadeRakePotShareBps - 5_000]struct{}` bounds the
//     restated copy FROM BELOW ONLY — it refuses a pot share under 5000 bps, because the
//     raffle's worry is the opposite one (too small a gross-up refuses honest batches).
//     Nothing anywhere bounded it from above.
//   - TestFix15_TheRafflesEntryBoundIsExactlyThisRealmsRakeEquivalent pins the two realms'
//     copies to EACH OTHER, so moving both in step keeps it green.
//
// IT CAN FAIL, AND BOTH CONSTANTS ARE REAL TERMS IN IT (finding 11's requirement):
// raffle.HouseCutBps is the raffle's, rakePotShareBps is this realm's, neither cancels,
// and both sides are bps of the same denominator reached by two independent product
// decisions. 3499 elements as the constants stand — the bps of headroom the pot's share
// has before it would overtake a ticket's — which is small enough for the GnoVM to
// materialise (see the ladder note at init for why token-scale guards are forbidden; this
// one is a bps count). The mutation that proves it is in the addendum: set
// rakePotShareBps to 9600 and the build stops.
var _ [bpsDenom - raffle.HouseCutBps - rakePotShareBps - 1]struct{}

// rungs is the stake ladder, in ugnot (GNOT has 6 decimals):
// 10 / 50 / 200 / 1,000 GNOT. FIXED AT DEPLOY, NEVER MUTABLE — there is no
// function anywhere in this file that writes to it (SPEC-03 §3/§4).
//
// WHY THESE NUMBERS. The previous ladder (100 / 500 / 2,500 / 10,000) was
// chosen for a SPLASH token priced quite differently; read in GNOT at roughly
// $0.08 it ran $8 to $785 a side, which is a casino. This ladder is roughly
// $0.79 / $3.93 / $15.70 / $78.50 a side — "go on then" to "I mean it" — which
// is an arcade. SPEC-03 §9 records the exact rung values as a free dial.
const (
	rung0 = 10_000_000    // 10 GNOT
	rung1 = 50_000_000    // 50 GNOT
	rung2 = 200_000_000   // 200 GNOT
	rung3 = 1_000_000_000 // 1,000 GNOT

	// maxStake bounds every arithmetic input in this realm: it is the top rung,
	// and the largest number that can ever be pulled into escrow in one call.
	//
	// THE WIDEST INTERMEDIATE IN THIS FILE IS 2 x maxStake x bpsDenom, re-derived
	// for this ladder: the pool is at most 2 x maxStake = 2e9, rakeOf multiplies
	// that pool by rakeBps (300) <= bpsDenom (1e4), so the product is at most
	// 2e9 x 1e4 = 2e13; splitRake multiplies a rake (< the pool) by a share in
	// bps (<= 1e4), which is smaller again. 2e13 is five orders of magnitude
	// below an int64's 9.2e18 (and 2e9 alone is below int32's 2.1e9 by a hair,
	// which is irrelevant here: every quantity is int64). None of that is what
	// keeps the arithmetic safe — the spec's rule is to never multiply
	// token-scale int64s directly, and mulDiv below is used regardless, so a
	// future rung big enough to matter cannot reintroduce a wrap (SPEC-v1.md
	// §7.9; commit 3622284 "mulDiv alone only moves the wrap": BOUND THE INPUT,
	// then use mulDiv). poolOf and rakeOf check against it at runtime, and
	// init below refuses deployment if the headroom ever stops holding.
	maxStake = rung3

	// maxStakeHeadroom is the largest maxStake for which 2 x maxStake x
	// bpsDenom stays below 2^62, a quarter of int64's range: 2.3e14 ugnot,
	// i.e. 230 million GNOT a side. Cannot be an array-length guard — see the
	// ladder-ascends note below for why token-scale guards must not be.
	maxStakeHeadroom = (1 << 62) / (2 * bpsDenom)
)

var rungs = [...]int64{rung0, rung1, rung2, rung3}

// The ladder must ascend, or a "higher" rung could be the cheaper one.
//
// NOT AN ARRAY-LENGTH GUARD, unlike the two bps checks in this file: the GnoVM
// materialises a [N]struct{} declaration as N elements, so a guard of the form
// [rung1 - rung0 - 1]struct{} would allocate four hundred million of them at
// init and exhaust memory (it did, on the first test run). Small guards are
// fine; token-scale ones are not. A failing init refuses the deployment, which
// is the next best thing to refusing the build.
func init() {
	for i := 1; i < len(rungs); i++ {
		if rungs[i] <= rungs[i-1] {
			panic("duel: the stake ladder must ascend")
		}
	}
	if rungs[len(rungs)-1] != maxStake {
		panic("duel: maxStake must be the top rung")
	}
	if maxStake > maxStakeHeadroom {
		panic("duel: 2 x maxStake x bpsDenom would not fit an int64 with headroom")
	}
	// THE TWO DOMAIN TAGS MUST DIFFER (see commitTag): if they were the same string, a
	// commitment would be an outcome and the two uses of sha256 in this file would stop
	// being independent functions. Checked here rather than at build time because a string
	// comparison is not an integer constant expression and so cannot be an array length.
	if commitTag == outcomeTag {
		panic("duel: the commitment and outcome domain tags must differ")
	}
}

// --- the reveal window (SPEC-03 §6, re-shaped 2026-09-30) ------------------
//
// ONE CLOCK, AND BOTH ENDS OF IT ARE CHAIN HEIGHT. This block used to hold FOUR coupled
// numbers — voidGraceBlocks, duelBindOffsetRounds, duelMaxStaleBlocks and
// minVoidGraceMultiple — three of which existed only to keep a drand round binding honest
// against a beacon estimate. The beacon is gone from this realm, so they are gone with it:
//
//	duelBindOffsetRounds  DELETED. Nothing binds a round any more.
//	duelMaxStaleBlocks    DELETED. Accept reads no beacon, so it has no staleness to bound.
//	minVoidGraceMultiple  DELETED. It bounded the grace against the wait for a bound round.
//	voidGraceBlocks       RENAMED revealWindowBlocks, same 24 hours, different meaning.
//
// AND THE TWO BUILD GUARDS THAT STOOD HERE ARE DELETED RATHER THAN RESCALED, WHICH IS
// REQUIRED BY THIS PROJECT'S FINDING 11 DOCTRINE AND NOT MERELY TIDY. They were
//
//	var _ [duelBindOffsetRounds*beacon.PeriodSeconds/2 - duelMaxStaleBlocks*33/100 - 1]struct{}
//	var _ [voidGraceBlocks*33/10/(duelBindOffsetRounds*beacon.PeriodSeconds) - minVoidGraceMultiple]struct{}
//
// and BOTH were legitimate because each had SECONDS ON BOTH SIDES FROM DIFFERENT CLOCKS:
// the chain's block time on one side, drand's period on the other. That is exactly what
// made them able to fail. With drand's clock removed there is only one clock left, so any
// guard written between two windows here would have the block time on both sides, it would
// cancel, and the guard COULD NOT FAIL — which AUDIT-2026-09-28.md finding 11 says is
// worse than no guard at all, because it looks like protection. So there is DELIBERATELY
// NO BUILD GUARD ON revealWindowBlocks, and the relation it would have asserted is stated
// in prose below instead, exactly as pendingGraceBlocks already does for its own window.
const (
	// blocksPerDay mirrors r/splash/game's constant of the same name:
	// ECONOMICS.md §7a-bis's measured ~3.3s block time. A different package
	// cannot reference game's unexported constant, so it is restated here.
	blocksPerDay = 26182

	// revealWindowBlocks is how long after Accept the poster has to open their
	// commitment before ANYBODY may Forfeit the duel to the taker: 24 hours, the same
	// number voidGraceBlocks carried, now measuring something a player controls.
	//
	// THE RELATION IT HAS TO HOLD, IN PROSE BECAUSE A GUARD FOR IT COULD NOT FAIL (see
	// the block comment above). Two bounds, pulling in opposite directions:
	//
	//	FROM BELOW: it must comfortably exceed the time an honest poster needs to get one
	//	transaction on chain — including a wallet prompt, a congested block or two, and a
	//	person who accepted a challenge and then walked away from the keyboard. A poster
	//	who is LATE ON A DUEL THEY WON LOSES THE WHOLE POOL to the taker, so this end of
	//	the window is the one with money on it. 24 hours is four orders of magnitude above
	//	one block and is not a number anybody has to tune.
	//
	//	FROM ABOVE: it is how long a losing poster can make the winning taker wait. The
	//	wait is the ONLY thing withholding buys them — Forfeit pays the taker the same
	//	pool - rake that Reveal plus Collect would have paid, so a withheld secret costs
	//	the poster exactly what losing costs them and gains them nothing but the delay.
	//	24 hours of griefable delay against an outcome that does not change is the accepted
	//	trade, and it is the identical exposure the old voidGraceBlocks carried.
	//
	// BOTH ENDS ARE MEASURED IN BLOCKS, AND THAT IS UNCHANGED AND NOW UNCONTROVERSIAL.
	// The old comment here had to argue the point at length, because "a day of missed
	// beacon rounds" cannot be counted during the very outage the window exists for. There
	// is no outage to reason about any more: chain/runtime.ChainHeight() is the only clock
	// a realm can read on this toolchain (no block timestamp exists — see game.gno's
	// blocksPerDay comment) and it is now the only clock this window needs.
	revealWindowBlocks = blocksPerDay
)

// --- rake destinations ----------------------------------------------------
//
// BOTH CONSTANTS BELOW ARE DUPLICATES OF r/splash/exchange's, and for the same
// reason: a realm's address is a pure function of its package path
// (gnolang.DerivePkgCryptoAddr), the constants in the exchange are unexported,
// and this is a different package. tools/duel_addr_test.go re-derives both
// from their package paths on every `go test ./tools`, fails on a mismatch, and
// fails on any address constant in this file it has not been told about — the
// guard the exchange's R3 finding (a label hash shipped as a live destination)
// showed to be necessary.
const (
	// raffleRealmAddr — gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/arcade/raffle. The pot share of the rake
	// goes here, through raffle.FundPot: A NAMED DOOR, not a bare transfer.
	// SPEC-03 §2 says "an ordinary GRC20 transfer", but a bare transfer into the
	// raffle is swept to its OPS pot, not into any week's prize (the raffle's
	// sweepDonations says why: crediting an unattributed arrival to a prize pot
	// would break the identity that makes its refunds safe). So the share must go
	// through the door that records it as sponsorship of the current week.
	//
	// IT REPLACED gameRealmAddr ON 2026-09-28. The yield and prize shares used to
	// go to gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/game via game.FundYield and game.FundPrizes; that
	// permanent-deposit yield product is retired and nothing in SPLASH holds money
	// beyond a week, so both shares now arrive as one sponsorship of THIS WEEK'S
	// raffle pot. Every coin flip makes Saturday's prize bigger: that is the
	// product. Derivation-checked by tools/duel_addr_test.go.
	//
	// This is also the SPENDER the approval in Collect names, so it must be the
	// address the raffle's own TransferFrom runs as — which is what the derivation
	// check guarantees.
	raffleRealmAddr address = "g1whdkh0jr9c07cewdrsed6fnwptkvdvrzypyfah"

	// opsVaultAddr — gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops. The operations share of the rake.
	// Same constant, same derivation and same reasoning as r/splash/exchange's
	// opsVaultAddr: the realm at that path need not exist yet for the address
	// to be right.
	opsVaultAddr address = "g1dqnxfp5zj89ggfcfzvampmhmrkjq36d2zvdyk7"
)

// --- state (SPEC-03 §3) ---------------------------------------------------

// maxLabelLen bounds an offer's label, in BYTES (len of the string, not
// runes). 64 is room for "loser buys lunch, and the dessert" with change, and
// small enough that the storage deposit a label costs — 100 ugnot/byte until
// the record is deleted — is a rounding error on the smallest stake.
const maxLabelLen = 64

// Offer is a standing stake in the lobby.
type Offer struct {
	Poster   address
	Rung     int64 // index into rungs, NOT a raw amount
	PostedAt int64 // block height, for the render only

	// Opponent, when non-zero, is the ONLY address that may Accept this offer:
	// the duel was sent to someone rather than listed. Zero means open to
	// anyone, exactly as before the field existed. Checked in Accept, nowhere
	// else — it has no bearing on who wins.
	Opponent address

	// Label is free text from the poster, at most maxLabelLen bytes, printable
	// UTF-8 only (checkLabel). PURELY DESCRIPTIVE: never parsed, never used in
	// settlement, and it reaches Render only through renderLabel.
	Label string

	// CommitHash is H(commitTag ‖ secret) as 64 lowercase hex characters: the poster's
	// half of the coin, sealed. It is THE ONLY SOURCE OF RANDOMNESS THIS REALM HAS from
	// the poster's side, and Reveal will not open it for anything but the one 32-byte
	// preimage it names (checkCommitment, checkSecret, commitmentOf).
	//
	// EMPTY MEANS LEGACY, AND LEGACY MUST NEVER ROUTE TO FORFEIT. An offer created before
	// 2026-09-30 has no commitment and therefore CAN NEVER BE REVEALED by anybody — so
	// treating its expiry as a forfeit would hand the taker a pool the poster never had a
	// chance to win. Accept REFUSES such an offer outright (so no such duel can be created
	// from here on), Cancel is permissionless for it (so it cannot be stranded even if its
	// poster is a pre-D-1 realm that cannot call anything), and VoidStale refunds a duel
	// that already has one. Nothing is deployed, so no record of this shape exists; the
	// paths exist so that the code contains no trap. Requirement 5 of the change.
	CommitHash string

	// PosterIsUser records whether the Post that created this offer was a DIRECT
	// USER CALL, and it exists for exactly one reason: AUDIT-2026-09-28.md finding
	// 8, carried into finding 15's earned entries.
	//
	// IT IS NECESSARILY TRUE FOR EVERY OFFER CREATED SINCE 2026-09-30, and it is kept
	// anyway. This field used to be the ONLY consequence of playing from realm code —
	// "it has NO bearing on settlement, a realm may post, accept, win and collect
	// exactly as before" is what stood here, and finding D-1 is that leaving settlement
	// open was the defect: a winning realm could not call the winner-only Collect, so
	// the pool had no exit. Post now refuses a non-user call outright
	// (requireUserCall), so nothing can write false here any more.
	//
	// KEPT, NOT DELETED, FOR TWO REASONS. It is the one place finding 8's property is
	// enforced for ENTRIES — the raffle cannot check it for a bare address, and
	// FundPotWithEntries trusts this realm to have checked — so if either gate is ever
	// relaxed, bookEntries must not silently start crediting realms; the flag and its
	// check are what make that failure a zero and an event rather than a stranded raffle
	// pot. And it is a recorded fact about a call that no later reader can re-derive.
	//
	// WHY IT HAS TO BE RECORDED HERE AND CANNOT BE DERIVED LATER. A raffle entry is
	// a claim on an outbound transfer (the raffle pushes a whole week's pot to the
	// winner's address), and for a realm caller that address is PACKAGE-DERIVED:
	// nothing can move wugnot out of it unless that realm happens to contain code
	// that does. A realm that won a raffle week would strand the entire pot, which
	// is finding 8 verbatim. Neither realm can test an address for EOA-ness — the
	// predicate is about the CALL, not the address, and it is only available while
	// the call is on the stack. So it is captured at the door and carried: Accept
	// copies it onto the Duel, and Collect credits entries only to parties whose own
	// call was a user call.
	PosterIsUser bool
}

// Duel is an accepted offer waiting to be resolved and collected.
type Duel struct {
	Poster address
	Taker  address
	Rung   int64

	// Label is copied verbatim from the offer at Accept, so the render can
	// still say what the duel was about. Descriptive only, as on Offer.
	Label string

	// CommitHash is the offer's, copied at Accept. Reveal checks a secret against it.
	// "" is a legacy record: read Offer.CommitHash for what that means and for why such a
	// duel goes to VoidStale and never to Forfeit.
	//
	// THE FIELD `Round int64` USED TO STAND HERE, and it is deleted rather than kept and
	// ignored: it was "the beacon round this resolves against, set at Accept, strictly in
	// the future", and both the round and the beacon are gone. A dead field that a reader
	// could mistake for a live one is exactly how the 300-second bind margin outlived the
	// cadence change that had already falsified it.
	CommitHash string

	// Nonce is the taker's 32 bytes, as 64 lowercase hex characters, IN THE CLEAR. It is
	// half of the outcome and the taker chooses it freely — which is safe because they
	// choose it WITHOUT the secret, so every nonce is a coin they cannot evaluate
	// (posterWins). It is in the clear because a commitment from the taker would cost them
	// a second transaction, and the whole point of this shape is that the taker's
	// contribution rides the call they were already making.
	//
	// THE ONE THING THE PLAINTEXT COSTS is item (2) of this file's doc comment: it is
	// visible in the mempool before Accept is committed, which gives a watching poster a
	// free abort option on a nonce that loses. That is disclosed, open, and not closed by
	// anything in this file.
	Nonce string

	// Secret is the opened commitment, "" until Reveal. STORED, NOT DISCARDED, AND THAT IS
	// DELIBERATE: it makes the outcome re-derivable by anybody from the record alone, and
	// it is what lets AuditFailure re-check that every resolved duel's Winner is actually
	// the one H(outcomeTag ‖ secret ‖ nonce ‖ duelID) names — a settlement-correctness
	// invariant the beacon version could not state, because its randomness lived in another
	// realm. 64 bytes of deposit, reclaimed when Collect deletes the record.
	Secret string

	// AcceptedAt is the block height at Accept; the REVEAL WINDOW is counted from it
	// (revealWindowBlocks). Not part of SPEC-03 §3's sketch — it is the only way to measure
	// an elapsed window on a chain with no timestamp — and DuelOf keeps the six-value shape
	// §4 published by returning the window's END in the slot the beacon round used to have.
	AcceptedAt int64

	// PosterIsUser and TakerIsUser record whether each party's OWN call — the Post
	// for the poster, the Accept for the taker — was a direct user call. Read
	// Offer.PosterIsUser for why: they decide only whether that party earns raffle
	// entries at Collect (finding 15), and nothing else in this realm reads them.
	// The poster's flag is copied from the offer, which is the only place it was
	// knowable.
	//
	// BOTH ARE NECESSARILY TRUE FOR EVERY DUEL CREATED SINCE 2026-09-30: Post and
	// Accept both require a direct user call now (requireUserCall, finding D-1), which
	// is what gives this realm's own escrow the exit it was missing. They are retained
	// as the enforcement point for the ENTRY half of finding 8 — see
	// Offer.PosterIsUser for the two reasons — and DuelEntryEligibility still reports
	// them.
	PosterIsUser bool
	TakerIsUser  bool

	Resolved bool
	Winner   address // zero until Resolved
}

var (
	// offers is offerID -> *Offer and duels is duelID -> *Duel. avl.Trees,
	// NEVER MAPS: Render iterates them, and a map's iteration order differs
	// between nodes (SPEC-v1.md §7.7).
	offers = avl.NewTree()
	duels  = avl.NewTree()

	// IDs start at 1 so that 0 never names a record. Offer and duel IDs are
	// separate sequences, as in SPEC-03 §3.
	nextOfferID int64 = 1
	nextDuelID  int64 = 1

	// liveCommitments is the set of (poster, commitHash) pairs currently held by a LIVE
	// record — one standing offer or one uncollected duel each. Post refuses a pair already
	// in it; Cancel, Collect, Forfeit and VoidStale release it with the record.
	//
	// WHY IT EXISTS: IT IS THE ONE REUSE A CONTRACT CAN SEE, AND REUSE BREAKS THE TAKER
	// PROPERTY OUTRIGHT. "The taker cannot steer" holds because they choose the nonce
	// WITHOUT the secret. A poster who posts four offers under ONE secret destroys that for
	// three of them: the first Reveal publishes the secret on chain, and the taker of any
	// still-live sibling can then pick the nonce that wins, or simply wait out the window
	// and Forfeit a duel the poster would have won. That is not a subtle edge — it is the
	// exact loss of the property, available to anybody reading the block log, and it is the
	// shape a front end falls into naturally by generating one secret per session instead
	// of one per offer.
	//
	// KEYED BY POSTER AND HASH, NOT BY HASH ALONE, AND THAT IS THE WHOLE DIFFERENCE BETWEEN
	// A GUARD AND A GRIEF. A bare-hash set would let anybody watch the mempool, copy a
	// commitHash out of a pending Post and land their own Post first, so the victim's
	// transaction fails and they must generate a fresh secret to get on the board at all —
	// a free denial of service on the front door. Keyed by poster, the copier's entry
	// collides with nothing of the victim's, and the copier has only arranged to be robbed
	// themselves when the victim reveals. The protection is unharmed, because only the
	// poster knows the secret, so only the poster can reuse one.
	//
	// WHAT IT DOES NOT DO, STATED SO IT IS NOT MISTAKEN FOR MORE THAN IT IS. It is a LIVE
	// set, not a history: once a duel is collected its pair is released, so the same poster
	// may post the same commitment again — with a secret that is by then public — and be
	// robbed. Keeping every commitment ever seen would be unbounded storage on a contract
	// with no owner and no prune, which is a worse defect than the one it would close. The
	// residue is the same class as the entropy problem above and has the same answer: the
	// page draws a FRESH 32 bytes from a CSPRNG for every offer.
	//
	// A LEAKED ENTRY IS HARMLESS AND AN OVER-EAGER RELEASE IS HARMLESS, which is why this
	// index is not on the critical path of any exit. An entry left behind can only refuse a
	// future Post of one exact pair the poster should not be reusing anyway; a released one
	// can only re-admit a duplicate. Neither can strand money, and AuditFailure re-derives
	// the whole set from the records so drift in either direction is visible.
	liveCommitments = avl.NewTree()

	// escrowed is the wugnot this realm holds on behalf of players: one stake
	// per open offer, two per uncollected duel. Maintained incrementally, never
	// by iteration, and re-derived by AuditFailure. The realm's balance must
	// never fall below it (checkInvariant).
	escrowed int64

	// pendingPot is the players' side of the rake that has been BOOKED by Collect and
	// not yet delivered to r/splash/arcade/raffle. FlushPot delivers it.
	//
	// WHY IT EXISTS: A RESOLVED DUEL'S PAYOUT MUST NOT DEPEND ON ANOTHER REALM'S
	// BOOKKEEPING. Until today Collect called raffle.FundPot in the SAME TRANSACTION as
	// the winner's payout, and FundPot ends in the raffle's checkInvariant. So ANY panic
	// anywhere in the raffle — an accounting deficit, a committed or abandoned current
	// week, a beacon too stale to pin a new week's round since the staleness bound landed
	// — took the winner's payout down with it. And VoidStale refuses a RESOLVED duel, so
	// there was no second exit: the pool sat in escrow, unreachable by every path in
	// either realm, on two contracts with no owner and no upgrade path. THAT WAS
	// PRE-EXISTING, not created by the staleness bound: a raffle accounting deficit
	// already bricked every resolved duel's settlement.
	//
	// SO Collect NO LONGER CALLS THE RAFFLE AT ALL. It books here and returns. There is
	// no way to make a cross-realm call conditional on it succeeding — revive()/recover()
	// does not work across a realm boundary on this toolchain and would be the wrong
	// mechanism if it did — so the coupling is removed rather than caught.
	//
	// IT IS NOT A NEW MONEY SINK, AND THAT IS THE FIRST THING TO CHECK ABOUT IT, because
	// six of the fourteen findings on this product so far have been "money in, no way
	// out". Two exits, both permissionless:
	//
	//   - FlushPot, any time, by anyone: the whole balance goes to the raffle's current
	//     week through FundPot, exactly as Collect used to send it. If the raffle refuses,
	//     the transaction reverts and THIS BALANCE IS UNTOUCHED — the caller of FlushPot
	//     wastes their gas, and no duel winner is affected. That is the entire point.
	//   - SweepStuckRake, after pendingGraceBlocks with no successful flush: a plain
	//     wugnot.Transfer to the raffle's address, which calls no raffle code and so
	//     cannot be refused by it. The raffle's sweepDonations absorbs it into its ops
	//     pot, and WithdrawOps takes it from there. See SweepStuckRake for why the
	//     destination is the raffle and not r/splash/ops.
	//
	// AND IT IS IN checkInvariant AND AuditFailure. The realm must hold escrowed +
	// pendingPot, not just escrowed; a bug that booked rake it did not hold would
	// otherwise be invisible.
	pendingPot int64

	// pendingSince is the clock SweepStuckRake's last-resort window is counted from: the
	// chain height at which pendingPot last went from zero to non-zero, ADVANCED AGAIN
	// EVERY TIME A NEW HOLDER IS ADMITTED TO THE ENTRY BATCH (bookEntries). Zero when
	// pendingPot is zero, and reset by every successful flush.
	//
	// IT MEASURES THE AGE OF THE YOUNGEST CLAIM IN THE BATCH. It does NOT measure "how
	// long has delivery been failing", which is what this comment claimed until
	// 2026-09-30 and what SweepStuckRake's justification is still written in terms of —
	// AUDIT-duel-2026-09-27.md addendum 2, finding D-4. THE CLAIM WAS NEVER TRUE:
	// nothing here records a FAILED flush and nothing requires anybody to have attempted
	// one, so a raffle that would have accepted every delivery all along is
	// indistinguishable from one that refused them all. What the window has always
	// actually measured is elapsed time.
	//
	// THE DISCLOSED CONSEQUENCE OF THAT IS ACCEPTED AND IS RECORDED AT
	// pendingGraceBlocks: 21 days in which nobody bothers to call FlushPot lets any
	// caller divert the players' side of the rake to the house, even with the raffle
	// perfectly willing. That is a cost of having a window at all.
	//
	// THE UNDISCLOSED ONE WAS THE FINDING, AND IT IS WHY THE CLOCK NOW ADVANCES. A batch
	// opened at height H accumulates up to maxPendingEntryHolders holders under a clock
	// started at H. So a player who collected on day 20 of the window had their earned
	// entries destroyed — SweepStuckRake discards the whole batch — by a window that
	// OPENED BEFORE THEY PLAYED, with no notice, no event they could have seen in time,
	// and no action available to them but paying up to 351,725,503 gas to flush a batch
	// they had just joined. Advancing on admission means every holder gets the whole
	// window measured from their own claim.
	//
	// WHY THIS AND NOT THE OTHER TWO CANDIDATES. Gating the sweep on recorded evidence of
	// a FAILED flush is the honest reading of the justification, but a failed flush
	// REVERTS — including any write that recorded it — so recording one is not possible
	// without a caller who reports their own failure, which nothing can compel and
	// anybody can fake in either direction. Merely documenting that a late entrant
	// inherits the clock leaves the harm in place. Advancing on admission is bounded (at
	// most maxPendingEntryHolders advances, so the window always closes — see bookEntries)
	// and moves the sweep only in the players' favour, since the sweep is the path that
	// takes their money to the house.
	pendingSince int64

	// pendingEntries is string(address) -> int64 raffle entry units earned by that
	// address and not yet delivered, and pendingEntryUnits is its running sum.
	// FlushPot delivers both together with pendingPot.
	//
	// WHY PLAYING EARNS ENTRIES AT ALL: AUDIT-2026-09-28.md finding 15. The rake has
	// funded the raffle's current week since 2026-09-28, but playing bought NO
	// TICKETS — so a week in which the coin flip was busy and nobody bought a raffle
	// ticket could be won outright by a single 0.1 GNOT ticket bought in its final
	// block. The money arrived and the entrants did not. Now both arrive together:
	// every settled duel credits its two players entries worth exactly what its rake
	// would have bought at raffle.EntryUnitPrice. Read rakeEntryUnits for the pricing
	// rule, which is the security property, and splitEntries for the consolation
	// weighting.
	//
	// THEY RIDE THE SAME MECHANISM AS THE MONEY, AND THAT IS NOT NEGOTIABLE.
	// Collect books here and calls no raffle code; FlushPot delivers. Finding 14 is
	// the reason: a panic inside the raffle used to strand every resolved duel's pool
	// permanently, and entries must never reintroduce that coupling. A raffle that
	// refuses the batch costs the flusher a reverted transaction and no winner
	// anything.
	//
	// AGGREGATED BY ADDRESS, NOT LISTED BY DUEL, for two reasons. A player who
	// settles three duels between two flushes delivers as ONE index in the raffle's
	// ticket tree rather than three, which is cheaper for everybody and is
	// indistinguishable in the draw (a fenwick index's weight is what decides, not
	// how many indices an address holds). And the batch FlushPot has to build is
	// bounded by the number of distinct PLAYERS since the last flush rather than by
	// the number of duels, which is what maxPendingEntryHolders bounds.
	pendingEntries    = avl.NewTree()
	pendingEntryUnits int64
)

// maxPendingEntryHolders bounds the batch FlushPot builds, and therefore bounds
// FlushPot's gas.
//
// IT EXISTS BECAUSE THE ONE THING THAT MUST NEVER HAPPEN IS AN UNDELIVERABLE
// BATCH. Every distinct player who collects between two flushes adds a holder, and
// FlushPot pays to append each one in the raffle. With no bound, a long spell of
// the raffle refusing every flush — see FundPot's refusals — could grow the batch
// until delivering it cost more than a block, at which point the booked rake's
// primary exit would be gas-bricked and only SweepStuckRake's last resort would be
// left. That is the "money in, no way out" shape six of this product's findings
// have had, so it is bounded rather than hoped about.
//
// WHAT HAPPENS AT THE BOUND IS A DROPPED ENTRY, NEVER A FAILED Collect. A winner
// must always be able to collect (finding 14), so Collect cannot start refusing
// because a queue is full. A player who would be the (n+1)th distinct holder
// therefore earns nothing for that duel and an event says so. It costs any caller
// ONE FLUSH to prevent that for everybody, permanently — and in
// normal operation the batch is emptied by the next flush, which anybody may make
// at any height and which the players themselves have every reason to make.
//
// WHAT THAT FLUSH COSTS IS A RANGE AND NOT A FIGURE, corrected 2026-09-30
// (AUDIT-duel-2026-09-27.md addendum 2, finding D-4). This paragraph said "~8.6M gas",
// which is A TWO-HOLDER FIGURE — and this paragraph is about the moment the batch is
// FULL, which is the one regime in which that number is more than thirty times too small.
// The two ends of the range, each with its provenance, because they are not both
// reproducible the same way:
//
//	TWO HOLDERS: 10,378,157 gas, 0.35% of a 3e9 block. MEASURED 2026-09-30 on
//	  /home/johnny/go/bin/gno as GasCollectAndFlush minus GasCollectSetupAndCollect in
//	  zz_gas_test.gno, stable across repeated runs. NOTE THAT FILE'S TABLE STILL RECORDS
//	  8,638,590 FOR THE SAME DIFFERENCE AND NO LONGER REPRODUCES — it is stale by ~1.7M
//	  and is owed a re-measurement, which is finding D-6 and is NOT fixed here.
//
//	A FULL 128-HOLDER BATCH against a live week grown to 100,096 ticket indices:
//	  351,725,503 gas, 11.7% of a block. AN OUT-OF-SUITE FIGURE BY CONSTRUCTION, and it
//	  must be read as one: seeding 100,096 indices takes ~7 minutes of wall clock, so it
//	  was measured with throwaway probes in a scratch tree and CANNOT be reproduced by
//	  running this package. zz_gas_test.gno records the method. The in-suite
//	  TestGasFlushAFullBatch exercises the same 128 holders against a far smaller index.
//
// THE ARGUMENT IS UNCHANGED AND THE HONEST VERSION IS STILL CHEAP: even at the full-batch
// end it is one transaction, well inside a block, available to anybody at any height. But
// a reader deciding whether the mitigation is realistic must be given the number that
// applies in the state the mitigation is for, not the cheapest one in the file.
//
// THE FIGURE SAID "~1.1M" UNTIL 2026-09-29 AND WAS STALE BY FINDING 15, which put two
// fenwick appends and their events inside every FlushPot. The ARGUMENT is unchanged —
// preventing a dropped entry for everybody costs one caller one affordable transaction —
// but this number has now been wrong three times running, in three different ways, which
// is itself the lesson: A MEASURED FIGURE IN A COMMENT DECAYS, and the only ones worth
// quoting are the ones a reader can re-derive from a named test. AUDIT-2026-09-28.md
// finding 19; AUDIT-duel-2026-09-27.md addendum 2, findings D-4 and D-6.
//
// 128 IS PICKED, NOT DERIVED, AND WHAT MAKES IT SAFE IS THAT BOTH SIDES OF IT ARE
// MEASURED: zz_gas_test.gno pins the cost of a full batch's delivery, so a future
// edit that raises this constant has to re-measure rather than reason. It is far
// above the number of distinct players a quiet arcade sees between two flushes and
// far below anything that threatens a block.
//
// AND THE BOUND WAS RE-MEASURED IN THE REGIME IT PROTECTS, WHICH IS THE POINT OF
// FINDING 19. This constant caps the HOLDER dimension at 128 and says nothing about the
// other dimension the cost depends on: THE SIZE OF THE RAFFLE WEEK'S TICKET INDEX,
// which grows on its own with no code edit at all. The earlier full-batch figure was
// taken against a week grown to only a few hundred entries. Measured against a live week
// seeded to 100,096 indices on this toolchain, a full 128-holder FlushPot costs
// 351,725,503 gas — 11.7 % of a 3e9 block, against 8.8 % at a few hundred. The
// tree-dependent half grew by about a third rather than doubling, the bound holds with
// more than eight times the headroom it needs, and 128 IS THEREFORE KEPT. The
// measurement, including how the index was seeded, is in zz_gas_test.gno.
const maxPendingEntryHolders = 128

// realmSelf is this realm's own address, resolved ONCE at package
// initialisation, for the same reason game.gno does it: under the test
// harness unsafe.CurrentRealm() follows the origin caller in a non-crossing
// frame, and a realm's own address is a constant for its whole life.
var realmSelf = unsafe.CurrentRealm().Address()

func selfAddr() address {
	return realmSelf
}

// idKeyWidth is enough decimal digits for any non-negative int64, so that
// avl's lexicographic key order is numeric ID order and Render lists records
// as 1, 2, ... 10 rather than 1, 10, 2 — the same convention as
// r/splash/beacon's roundKey and r/splash/game's ticketIndexKey.
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

// mulDiv returns floor(a*b/d) via a 128-bit intermediate product, exactly as
// r/splash/game and r/splash/exchange do it. Raw a*b/d on token-scale int64s
// wraps silently on the GnoVM (tools/muldiv_probe.gno).
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

// poolOf is 2 x stake, the whole pot of a duel, with the input bounded first
// (SPEC-v1.md §7.9; commit 3622284's lesson).
func poolOf(stake int64) int64 {
	if stake <= 0 || stake > maxStake {
		panic("duel: stake out of bounds")
	}
	return 2 * stake
}

// rakeOf is the rake on a pool: floor(pool x 300 / 10000).
func rakeOf(pool int64) int64 {
	if pool <= 0 || pool > 2*maxStake {
		panic("duel: pool out of bounds")
	}
	return int64(mulDiv(uint64(pool), rakeBps, bpsDenom))
}

// splitRake divides a rake 60 / 40 into the raffle pot share and the ops share.
// Ops is floored; THE POT TAKES THE REMAINDER AND ALL THE DUST, so
// potShare + opsShare == rake exactly, always (BIBLE.md §2.7).
//
// THE ARITHMETIC IS UNCHANGED FROM THE OLD THREE-WAY SPLIT, and that is the
// point. There, ops was floor(rake x 2000 / 10000) and prizes was the remainder
// after yield and ops; so yield + prizes was already exactly rake - ops, dust
// included. Folding yield into the pot share therefore moves no money between
// the house and the players — it only sends one number where two used to go.
//
// Both checks below are REAL guards, not tautologies (see r/splash/game's Claim
// for the history). The compile-time array above makes the negative case
// unreachable today; they stay here so a runtime reader sees the property
// asserted where the money moves, and so that a pot share quietly shorted below
// its floor share would fail loudly rather than dribble into ops.
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

// --- the raffle entries a duel earns (AUDIT-2026-09-28.md finding 15) -------
//
// THE DEFECT, IN THE OWNER'S WORDS: "so people could be gambling money on coinflip
// all week and some asshole with a 1cent ticket can win the pot?" Yes. The rake fed
// the week's raffle pot and playing bought no tickets, so a week of busy coin
// flipping and no ticket sales was a large pot with a ticket total of zero — takeable
// whole by one 0.1 GNOT ticket in its final block. The fix puts the players who paid
// for the pot into the draw for it, which addresses the cause instead of gating the
// symptom: no minimum, no refusal, no rule about when a ticket may be bought.

// rakeEntryUnits is how many raffle entry units a rake of `rake` ugnot earns:
// EXACTLY WHAT THAT MONEY WOULD HAVE BOUGHT AT raffle.EntryUnitPrice.
//
// IT WAS raffle.TicketPrice UNTIL 2026-09-29 AND THAT IS AUDIT-2026-09-28.md FINDING
// 22 — the general lesson being that TWO INDEPENDENT PRODUCT PARAMETERS SHARING ONE
// CONSTANT WILL EVENTUALLY BE GIVEN VALUES THAT CANCEL EACH OTHER OUT. The raffle's
// ticket price went to 10 GNOT, and against a 10 GNOT divisor this ladder's rakes —
// 0.6 / 3 / 12 / 60 GNOT — earn 0 / 0 / 1 / 6 entries. THREE OF THE FOUR RUNGS WOULD
// HAVE EARNED NOTHING, silently, with the build green and every existing test that
// asserted the RATE rather than a count still passing. The entry unit is now its own
// constant at 0.25 GNOT, one ticket is 40 of them, and the rungs earn 2 / 12 / 48 /
// 240. TestFix22_EveryRungEarnsAtLeastOneEntryAndTheCountsAreExact is the regression.
//
// THIS FUNCTION IS THE SECURITY PROPERTY OF THE WHOLE FEATURE AND THE REASON IT IS
// PRICED OFF THE RAKE AND NEVER OFF THE STAKE.
//
//	A POSTER MAY ADDRESS AN OFFER TO ONE OPPONENT (see Post), so two accounts
//	under one hand can flip each other for as long as they like and the ONLY real
//	cost of doing so is the rake — the stakes go round in a circle. Weight entries
//	by the stake or the pool and that is free money: a rung-0 duel is a 20 GNOT
//	pool on a 0.6 GNOT rake, so pool-weighting would pay 80 units of weight
//	(20 GNOT / EntryUnitPrice) for 2 units' worth of cost. ENTRIES AT A
//	THIRTY-THIRD OF FACE VALUE. Nobody would buy a ticket again and one funded
//	account would own every draw, for ever, on a contract with no owner and no
//	pause.
//
//	PRICED OFF THE RAKE, FLIPPING IS NEVER CHEAPER THAN BUYING AND SELF-DEALING
//	GAINS NOTHING. The self-dealer's net cost of a rung-1 flip is the 3000000
//	ugnot rake and it earns 12 units: 250000 ugnot each, which is
//	raffle.EntryUnitPrice to the ugnot. It is in fact weakly WORSE than buying, on
//	two counts since 2026-09-29: only 60% of a rake reaches the pot against 95% of
//	a ticket price — the same price per unit, into a smaller prize — and at rung 0
//	the floor discards 0.4 of a unit, so that rung pays 300000 a unit, 1.2x face
//	value. BOTH ERRORS RUN THE SAFE WAY. duel_test.gno asserts that rate against
//	raffle.EntryUnitPrice rather than against a hardcoded 2, and
//	r/splash/arcade/raffle enforces the same ceiling at its door from the money it
//	actually receives (raffle.ArcadeEntryUnitsBound), so neither side has to trust
//	the other's arithmetic.
//
// THE FLOOR IS DELIBERATE: a rake that cannot buy one whole entry earns none. On
// today's ladder rungs 1, 2 and 3 are exact multiples and RUNG 0 IS NOT — 600000 /
// 250000 is 2.4, floored to 2 — so the floor now discards 0.4 of a unit at the bottom
// rung where it used to discard nothing at any rung. That is a fractional unit of
// weight the flipper paid for and does not get; it is the safe direction (it can only
// ever make flipping dearer than buying, never cheaper) and
// TestExtra_LadderAndRakeConstants pins the exact counts.
//
// AND MIND WHAT THE FLOOR DOES TO splitEntries AT RUNG 0 — IT ONCE MADE THAT RUNG
// DEGENERATE AND THE OWNER HAS HAD IT FIXED. Two units split one-third / two-thirds is
// 0 to the winner and 2 to the loser, so a rung-0 winner used to earn NO ENTRIES AT
// ALL. THE CAUSE WAS THIS FLOOR MEETING A VERY SMALL TOTAL, NOT THE CONSOLATION
// WEIGHTING: a third of 2 is 0 however you weight it. Since 2026-09-29 splitEntries
// guarantees each player one entry whenever the total is at least 2, so rung 0 is 1 / 1
// and every other rung is untouched. The TOTAL this function returns did not move by a
// unit at any rung, which is the only quantity an attacker could care about. Read
// splitEntries for the guarantee and its three boundaries.
//
// raffle.EntryUnitPrice IS A CONSTANT OF ANOTHER REALM AND THAT IS ON PURPOSE. It is a
// compile-time const, not a call, so reading it adds no runtime dependency ON THE RAFFLE
// to any path in this file — which matters most in checkInvariant, which runs at the end
// of Collect and must never be able to fail for a reason IN THE RAFFLE (finding 14).
// "in the raffle" and not "in another realm", corrected 2026-09-30: checkInvariant does
// read another realm, namely r/gnoland/wugnot's ledger for the escrow balance, and it
// always has. See checkInvariant, where that is now stated exactly.
//
// ============================================================================
// DISCLOSURE: WHAT AN EARNED ENTRY IS SETTLED BY, AND THE ONE KNOWN OPEN RISK IN IT
// ============================================================================
//
// READ THIS IF YOU PLAY THE DUEL. A coin flip here is decided by the two players' own
// commit-reveal (posterWins), with the caveats in this file's doc comment and NO DEPENDENCE
// ON A BEACON AT ALL since 2026-09-30. But the ENTRIES this function
// prices are entries in r/splash/arcade/raffle's WEEKLY DRAW, and that draw IS settled by a
// beacon round, and it has a
// known, open, recorded weakness of its own. It is disclosed here
//
// AND THE SENTENCE THIS REPLACES SAID THE OPPOSITE OF THE TRUTH, WHICH IS WHY IT IS QUOTED
// RATHER THAN DELETED: "a coin flip here is decided by a beacon round bound when the duel is
// accepted, AND THAT PART IS FINE". It was not fine. The binding's freshness signal was
// forgeable for about a tenth of a US cent, which is why the coin was replaced and why this
// disclosure now has a matching pair of caveats at the top of the file. A reassurance in a
// comment is worth exactly as much as the test behind it.
// because a duel player never has to read the raffle's source, and since finding 15
// duel players are the LARGEST CLAIMANT CLASS in that weekly pot — people who opted
// into a coin flip, not a raffle.
//
// THE RISK, IN ONE SENTENCE: anybody who can learn a week's winning randomness BEFORE
// that week's ticket sales close can buy last, size the buy so that
// randomness mod FrozenTotal lands on a unit they own, and take the pot — a pot that
// since finding 15 is mostly duel rake. This is AUDIT-2026-09-28.md finding 4, narrowed
// by finding 10 and recorded OPEN there.
//
// WHY EARNED ENTRIES DO NOT MAKE IT BETTER OR WORSE, BUT CHANGE WHO PAYS FOR IT. Earned
// entries raise a week's ticket total, and the attack's cost is set by the attacker's
// own last purchase against that total — so a bigger total costs them more tickets, but
// they were always going to buy the number of tickets the arithmetic needed. IT DOES
// NOT RAISE THE ATTACK'S COST IN ANY MEANINGFUL SENSE. What it changes is the loser:
// before, the pot was buyers' money and a rigged draw robbed raffle buyers; now the pot
// is mostly rake and a rigged draw robs duel players.
//
// THE FORM THE RISK TAKES TODAY, STATED ACCURATELY RATHER THAN AS IT WAS FIRST WRITTEN.
// Finding 4 was written when r/splash/beacon verified a key THIS PROJECT HELD, which
// made the operator able to compute any future round's randomness at will. THAT IS NO
// LONGER THE CASE and the entry in the audit file predates the change: the beacon now
// verifies drand evmnet under a DKG threshold group key that nobody here holds, so no
// single party can sign a future round and nobody can read a future round's randomness.
// The finding is nevertheless still recorded OPEN, and it is open for a narrower reason
// that is worth stating plainly:
//
//	THE RAFFLE PINS ITS WEEK'S ROUND AGAINST AN ESTIMATE OF DRAND'S CURRENT ROUND,
//	DERIVED FROM CHAIN HEIGHT (r/splash/beacon's EstimatedLatestRound). If this chain's
//	blocks run slower than the 3.29998 s the estimate assumes, or if nobody has relayed
//	a round recently, the pinned round drifts EARLIER relative to real time — and a
//	round whose time has come is PUBLIC on api.drand.sh, readable by anybody, for free.
//	Drift far enough and the week's winning randomness is readable before its sales
//	close, which is exactly the last-buyer attack above with no key and no privilege
//	required.
//
// IT IS BOUNDED, AND THE BOUND IS MEASURED RATHER THAN ASSUMED: beacon's
// maxEstimateStaleBlocks refuses to open a week against an anchor more than one day of
// blocks old, and AUDIT-2026-09-28.md finding 13 computes the remaining margin as ~24
// hours at nominal block time and ~7.2 hours at the slow edge of the stated ±10 % band,
// against ~2.4 hours of admitted estimation error. So it holds today at the measured
// constants. WHAT IT RESTS ON IS blocksPerDay = 26182 BEING RIGHT ABOUT THE REAL CHAIN,
// which finding 12 records as a DEPLOYMENT-BLOCKING MEASUREMENT the owner must make.
//
// NOTHING IN THIS REALM CLOSES IT AND NOTHING HERE SHOULD BE READ AS TRYING TO. It is
// the raffle's draw, it is the owner's decision (an externally-timed pin, or a VRF),
// and the only thing this comment does is make sure a duel player or a reviewer meets
// it here — because the money at risk is theirs. See Collect's doc for the pointer and
// AUDIT-2026-09-28.md findings 4, 10, 12, 13 and 20 for the full record.
func rakeEntryUnits(rake int64) int64 {
	if rake < 0 {
		panic("duel: negative rake")
	}
	return rake / raffle.EntryUnitPrice
}

// splitEntries divides a duel's earned entries between its winner and its loser:
// EACH PLAYER IS GUARANTEED ONE ENTRY WHENEVER THE TOTAL CAN PAY FOR TWO, AND THE
// REMAINDER IS WEIGHTED TWO THIRDS TO THE LOSER.
//
// THE FLOOR OF ONE IS THE OWNER'S 2026-09-29 CHANGE AND IT IS THE ONLY THING THAT
// MOVED. Before it, the rule was the bare floored third — winner = total/3, loser the
// rest — and at the bottom rung that produced a DEGENERATE result: a 10 GNOT flip
// earns 2 units (600000 ugnot of rake over a 250000 ugnot entry unit, floored), a
// third of 2 floors to 0, AND THE WINNER OF A DUEL EARNED NOTHING. The weighting was
// never wrong; a floored share of a very small total is. So the small total is
// handled where it arises instead of by reweighting anything: one unit each first,
// then the old arithmetic on what is left.
//
// THE CONSOLATION WEIGHTING IS A PRODUCT DECISION AND IT COSTS NOTHING, which is
// why it is safe, and the same sentence is why the floor is safe. The TOTAL is fixed
// by rakeEntryUnits and is the only quantity an attacker could care about; how it is
// divided between two parties who may be the same person creates no edge whatever. A
// self-dealer holding both accounts gets the same total either way, which is exactly
// what the self-dealing test asserts. NOTHING BELOW RAISES A TOTAL BY ONE UNIT, so
// the money-backed ceiling this realm checks in maxEntryUnitsFor and the raffle
// checks again in ArcadeEntryUnitsBound is untouched at every rung.
//
// THE NUMBERS IT PRODUCES on today's ladder. ONLY RUNG 0 MOVED:
//
//	rung 0:  rake    600000 ->   2 units ->   1 winner /   1 loser   <- WAS 0 / 2
//	rung 1:  rake   3000000 ->  12 units ->   4 winner /   8 loser
//	rung 2:  rake  12000000 ->  48 units ->  16 winner /  32 loser
//	rung 3:  rake  60000000 -> 240 units ->  80 winner / 160 loser
//
// Rungs 1, 2 and 3 are unchanged because their floored third is already at least one,
// so the floor never binds: max(1, total/3) == total/3 for every total >= 3. The
// floor can therefore only ever be visible at total 2, which is the one place the
// defect was. TestFix26_EachPlayerIsGuaranteedAnEntryAndTheRungCountsAreExact pins
// every row of the table above and pins the totals as unchanged.
//
// THE THREE BOUNDARIES, CHOSEN EXPLICITLY RATHER THAN FALLING OUT OF THE ARITHMETIC:
//
//	total 0 -> 0 / 0. NEITHER PLAYER CAN GET ANYTHING AND THAT MUST NOT PANIC. It is
//	what a sub-unit rake produces — a rake under raffle.EntryUnitPrice floors to no
//	units at all — and it is reachable from Collect's `potShare > 0` branch on any
//	ladder whose bottom rung is small enough. There is nothing to guarantee here: a
//	guarantee of one entry each out of a total of zero would have to invent the
//	entries, which is exactly the ceiling violation this whole feature is priced to
//	prevent.
//
//	total 1 -> 0 / 1, THE LOSER TAKES IT. One unit cannot be split two ways and
//	something must decide; the loser gets it for consistency with the consolation
//	intent that shapes the whole function, which is the same reason the remainder
//	goes to the loser at every other total. Unreachable on today's ladder (the
//	smallest rung earns 2) and therefore stated and tested rather than left to be
//	discovered by a future rung.
//
//	total >= 2 -> at least 1 each. This is the guarantee.
//
// THE WINNER'S SHARE IS THE FLOORED ONE AND THE LOSER TAKES THE REMAINDER, in the
// same spirit as splitRake giving the pot the dust: the asymmetry must never round
// against the party it is meant to favour, and the two shares must sum to the total
// EXACTLY or the ceiling the raffle enforces would be met by a total this realm did
// not intend. So loser >= winner always, and winner + loser == total for every total
// including 0, 1 and 2.
//
// ONE PREVIOUSLY TRUE CLAIM IS NOW FALSE AND IS RETIRED RATHER THAN QUIETLY DROPPED.
// This comment used to say "strictly greater for any total >= 1". AT TOTAL 2 THE TWO
// SHARES ARE NOW EQUAL, 1 and 1, which is the whole point of the change: a two-unit
// pot split "strictly in the loser's favour" is 0 and 2, and 0 is the bug. The
// invariant that survives — and that the raffle's ceiling and this realm's own
// checkInvariant actually rest on — is loser >= winner, which the panic below
// enforces. Strictness still holds for every total >= 3.
func splitEntries(total int64) (winnerUnits, loserUnits int64) {
	if total < 0 {
		panic("duel: negative entry total")
	}
	switch {
	case total == 0:
		// Nothing to divide. Not an error: see the boundary note above.
		winnerUnits, loserUnits = 0, 0
	case total == 1:
		// Indivisible. To the loser, deliberately.
		winnerUnits, loserUnits = 0, 1
	default:
		// THE GUARANTEE. One each, then the old weighting on the remainder — which
		// is what max(1, total/3) is: for every total >= 3 the floored third already
		// exceeds one and this line changes nothing at all.
		winnerUnits = total / 3
		if winnerUnits < 1 {
			winnerUnits = 1
		}
		loserUnits = total - winnerUnits
	}
	if winnerUnits+loserUnits != total {
		// A real check, not a tautology at the level that matters: it is the one
		// place the two shares and the total meet, and the raffle's ceiling is
		// stated against the total. IT IS ALSO THE LINE THAT CATCHES A FLOOR THAT
		// INVENTS AN ENTRY — the one way this function could ever break the ceiling
		// is by returning a pair that sums to more than it was given.
		panic("duel: entry split does not sum to the total")
	}
	if loserUnits < winnerUnits {
		panic("duel: entry split shorts the loser")
	}
	if total >= 2 && (winnerUnits < 1 || loserUnits < 1) {
		// THE GUARANTEE, ASSERTED AT THE ONE PLACE IT IS PRODUCED. A total of two or
		// more can pay both players, so leaving either on zero is the defect this
		// change exists to remove, and a future edit to the arithmetic above should
		// fail here rather than ship a duel whose winner earns nothing.
		panic("duel: entry split leaves a player with no entry out of a total that can pay both")
	}
	return winnerUnits, loserUnits
}

// maxEntryUnitsFor is the most booked entry units a booked pot share of `potShare`
// ugnot may ever carry — the SAME ceiling r/splash/arcade/raffle applies at its
// door, computed here from THIS realm's own constants so that checkInvariant can
// assert it without calling another realm.
//
// potShare >= rake * rakePotShareBps / bpsDenom, so rake <= potShare * bpsDenom /
// rakePotShareBps, and an entry costs raffle.EntryUnitPrice of rake. It is an
// inequality and not an equality because a party who played from realm code earns
// nothing (see Collect) and because the floor in rakeEntryUnits can discard a
// remainder — which since 2026-09-29 it actually does at rung 0 — so this realm may
// always book FEWER entries than the ceiling, never more.
//
// BOTH OF ITS TWO CONSTANTS MOVED ON 2026-09-29 and both had to: the gross-up is now
// 10000/6000 (finding 24's rake split) and the divisor is now the ENTRY UNIT and not
// the ticket price (finding 22). Getting either wrong in isolation is visible — too
// small a ceiling refuses honest batches here in checkInvariant, too large a one lets
// the raffle's own door refuse them — and
// TestFix15_TheRafflesEntryBoundIsExactlyThisRealmsRakeEquivalent pins this function
// against the raffle's copy to the entry, at every rung.
func maxEntryUnitsFor(potShare int64) int64 {
	if potShare <= 0 {
		return 0
	}
	gross := int64(mulDiv(uint64(potShare), bpsDenom, rakePotShareBps))
	return gross / raffle.EntryUnitPrice
}

// --- the coin: one commitment, one plaintext nonce -------------------------

// hexLen32 is how long a 32-byte value is in hex: 64 characters. The secret, the nonce
// and the commitment hash are all exactly this long and all lowercase hex, checked at
// BOTH ENDS — checkCommitment and checkNonce at the doors, checkSecret again at Reveal.
//
// IT IS THE SAME 64 randomnessHexLen USED TO BE, AND THE NAME CHANGED ON PURPOSE. That
// constant was "the length of a beacon randomness string (as in raffle.gno)", and this
// realm reads no beacon; a length named after a thing it no longer touches is how a
// stale premise survives a change. The number is unchanged because sha256 is unchanged.
const hexLen32 = 64

// THE TWO DOMAIN TAGS, AND THEY MUST DIFFER. commitTag seals the poster's secret;
// outcomeTag turns it plus the taker's nonce into a coin. If one string could be hashed
// under both tags then a commitment would BE an outcome — a poster could publish, as
// their commitment, the very digest whose parity they want, and the two uses of sha256
// in this file would stop being independent functions.
//
// EQUAL LENGTH AND DIFFERENT CONTENT, deliberately: equal so that neither tag can ever be
// a prefix of the other followed by the start of a field, different so that domain
// separation is real. Both are compile-time constants of this file and are reachable by no
// caller, so nothing an attacker supplies can move the boundary between tag and payload.
//
// THE EQUAL LENGTH IS A BUILD GUARD AND THE DIFFERENCE IS AN init GUARD, and the split is
// forced rather than chosen: an array length must be an integer constant expression, and a
// string comparison is not one on this toolchain. So the length relation — the one that IS
// integer arithmetic over two independent constants — fails the BUILD, and the inequality
// fails the DEPLOYMENT, which this file already establishes at the ladder as the next best
// thing (see init). Both can fail: neither constant cancels, and they were chosen
// independently.
const (
	commitTag  = "splash/duel/v1/commit:"
	outcomeTag = "splash/duel/v1/result:"
)

var _ [len(commitTag) - len(outcomeTag)]struct{}

// isLowerHex32 reports whether s is exactly 64 characters of LOWERCASE hex.
//
// LOWERCASE IS REQUIRED AND IS NOT FUSSINESS: it makes the encoding of a 32-byte value
// CANONICAL, so one secret has one spelling. Admitting both cases would mean a secret has
// up to 2^64 spellings, each hashing to a different commitment — harmless for the
// commitment (any one of them is a fine commitment) but it turns "the length is checked, so
// the opening is unique" into an argument a reader has to redo. One spelling, one check.
func isLowerHex32(s string) bool {
	if len(s) != hexLen32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}

// checkCommitment validates a commitHash at Post: 64 lowercase hex characters, no
// exceptions and no empty string. "" is reserved for LEGACY records (Offer.CommitHash) and
// must never be creatable, or a poster could post a duel that nobody can ever reveal and
// that Forfeit deliberately refuses to settle.
func checkCommitment(commitHash string) {
	if commitHash == "" {
		panic("duel: a commitment is required — post H(commitTag ‖ secret) as 64 lowercase hex characters")
	}
	if !isLowerHex32(commitHash) {
		panic("duel: the commitment must be exactly 64 lowercase hex characters (sha256, hex-encoded)")
	}
}

// checkNonce validates the taker's nonce at Accept: 64 lowercase hex characters, i.e.
// exactly 32 bytes. Checked HERE and not only at settlement because the nonce is half the
// coin: a short or empty one would shrink the taker's contribution to the outcome, and a
// zero-length nonce would make every duel a function of the secret alone — which the
// poster knows.
func checkNonce(nonce string) {
	if !isLowerHex32(nonce) {
		panic("duel: the nonce must be exactly 64 lowercase hex characters (32 bytes)")
	}
}

// checkSecret validates a revealed secret: 64 lowercase hex characters.
//
// THIS IS THE OTHER END OF THE LENGTH CHECK AND IT IS THE LOAD-BEARING ONE — REQUIREMENT 1
// OF THIS CHANGE, AND THE ONE THAT KILLED AN EARLIER PROPOSAL OUTRIGHT. The rejected shape
// was commitHash = H(secret ‖ salt) with both fields variable length. Two variable-length
// fields concatenated have NO UNIQUE SPLIT: a preimage of length L admits L+1 different
// (secret, salt) readings, every one of which passes the hash check, and the poster simply
// announces whichever reading wins. Not a bias — CERTAINTY, for free, with no grinding and
// no collision.
//
// ONE FIELD, FIXED LENGTH, ENFORCED AT BOTH ENDS is what removes it: the preimage of
// commitTag ‖ secret is commitTag's 22 known bytes followed by exactly 64 more, so there
// is exactly one place it can be cut and exactly one secret that opens a commitment.
// posterWins' own comment has warned about this since the beacon version ("without it the
// split point would be attackable") and it is now enforced rather than remarked on.
func checkSecret(secret string) {
	if !isLowerHex32(secret) {
		panic("duel: the secret must be exactly 64 lowercase hex characters (32 bytes)")
	}
}

// commitmentOf is H(commitTag ‖ secret), hex-encoded lowercase: what a poster publishes at
// Post and what Reveal recomputes. The secret is validated first, so this function is never
// given a variable-length preimage (checkSecret).
func commitmentOf(secret string) string {
	checkSecret(secret)
	sum := sha256.Sum256([]byte(commitTag + secret))
	return hex.EncodeToString(sum[:])
}

// posterWins is the whole winner rule, in one place (SPEC-03 §5):
//
//	h      = sha256(outcomeTag ‖ secret ‖ nonce ‖ duelID)
//	winner = Poster if h is even else Taker
//
// "h is even" is the parity of h read as a big-endian integer, i.e. of its last byte —
// unchanged from the beacon version, which read exactly the same bit of exactly the same
// hash function. WHAT CHANGED IS ONLY WHERE THE UNPREDICTABILITY COMES FROM: it was one
// value published by a third party (a drand round) and is now TWO values contributed by
// the two people with money on the table.
//
// WHY NEITHER PARTY CAN CHOOSE THE ANSWER, which is the entire security of this realm:
//
//	THE POSTER CANNOT GRIND. They fix secret at Post, when `nonce` does not exist and
//	`duelID` has not been assigned. Every candidate secret they might try is a commitment
//	to an outcome they cannot evaluate, because two of the three inputs are still in the
//	future. Grinding requires being able to score a candidate, and there is nothing to
//	score against.
//
//	THE TAKER CANNOT STEER. They choose `nonce` freely, with `duelID` and `commitHash`
//	both known — and without `secret`. Knowing H(commitTag ‖ secret) tells them nothing
//	about H(outcomeTag ‖ secret ‖ nonce ‖ duelID) short of inverting sha256, so every
//	nonce they could pick is a coin whose face they cannot see. Choosing among coins you
//	cannot evaluate is not choosing.
//
//	AND NEITHER CAN CHANGE THEIR MIND. The poster is bound by collision resistance (one
//	secret opens one commitment — checkSecret) and the taker's nonce is written into the
//	record at Accept, before any secret exists on chain.
//
// MIXING IN THE DUEL ID IS STILL MANDATORY (SPEC-v1.md §7.2), for a reason that survived
// the change of source: a poster may stand several offers at once, and without the ID two
// duels that happened to share a secret and a nonce would share an outcome. The
// concatenation is UNAMBIGUOUS because secret and nonce are each exactly hexLen32 bytes and
// the only variable-length field, the decimal ID, is LAST — nothing follows it, so nothing
// can be shifted into it.
//
// Factored out, as before, so the tests can derive a duel's outcome independently of
// Reveal — and so that the poster-cannot-grind and taker-cannot-steer tests can drive the
// function directly over thousands of candidates instead of asserting a property in a
// comment.
func posterWins(secret, nonce string, duelID int64) bool {
	checkSecret(secret)
	checkNonce(nonce)
	sum := sha256.Sum256([]byte(outcomeTag + secret + nonce + strconv.FormatInt(duelID, 10)))
	return sum[len(sum)-1]%2 == 0
}

// commitKey is liveCommitments' key: the poster and their commitment, joined by a
// separator that cannot occur in either half. An address is bech32 (no "|") and a
// commitment is lowercase hex (no "|"), so the two halves cannot be confused for one
// another whatever the lengths — the same unique-split discipline as the hash preimages
// above, applied to a tree key.
func commitKey(poster address, commitHash string) string {
	return string(poster) + "|" + commitHash
}

// requireFreshCommitment refuses a (poster, commitHash) pair that a live record already
// holds. CHECKED BEFORE THE STAKE IS PULLED, so a refused Post moves nothing.
func requireFreshCommitment(poster address, commitHash string) {
	if liveCommitments.Has(commitKey(poster, commitHash)) {
		panic("duel: you already have a live offer or duel under this commitment — " +
			"reusing one secret across records lets the taker of the second steer it once the first is revealed; " +
			"draw a fresh 32 bytes from a CSPRNG")
	}
}

// holdCommitment records the pair. WRITTEN AFTER THE PULL, BESIDE THE RECORD IT BELONGS TO,
// and the split from the check above is deliberate: a write made before a pull that then
// fails is discarded on chain (the panic aborts the transaction) but is KEPT under `gno
// test`, where uassert's Aborts* helpers catch the abort with revive() and "state mutations
// remain even after revive()" — see duel_test.gno's F2 note. So a check-then-write pair
// straddling the pull would leave this suite with a held commitment for an offer that does
// not exist, and AuditFailure would rightly refuse the books. Checking early and writing late
// gives the same refusal with no window in which the index can disagree with the records.
func holdCommitment(poster address, commitHash string) {
	liveCommitments.Set(commitKey(poster, commitHash), true)
}

// releaseCommitment frees a pair when its record dies. Silent on a pair that is not held:
// a legacy record never held one, and a release that finds nothing must not be able to
// stop an exit (see liveCommitments on why a leak and an over-eager release are both
// harmless).
func releaseCommitment(poster address, commitHash string) {
	if commitHash == "" {
		return
	}
	liveCommitments.Remove(commitKey(poster, commitHash))
}

// checkLabel is the ONLY validation a label gets, and it runs before any
// pull. Bounded in bytes, valid UTF-8, no control characters (which rules out
// newlines and carriage returns, so the stored text is always one printable
// line). Everything else — markdown, HTML, pipes — is legal to STORE and is
// neutralised at render time by renderLabel, the same discipline every
// address in this realm already goes through.
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
// state-changing function: the realm must hold at least what it has in
// escrow. ">=" and not "==", deliberately — wugnot.Transfer is permissionless,
// so anyone can push wugnot at this address, and an exact check would let a
// one-ugnot donation brick every duel. Such a donation is simply stranded:
// SPEC-03 §4 forbids any function that pays anyone other than a duel's own
// winner, so there is no sweep and no admin drain by design.
// pendingPot IS PART OF WHAT THIS REALM OWES, and it is checked here for the same reason
// escrowed is: a booked rake this realm does not hold is money promised to the raffle out
// of players' stakes. Still ">=" and not "==" — a donation is still stranded, by design.
// THE BOOKED ENTRIES ARE CHECKED HERE TOO, AND THE RATE CHECK IS THE IMPORTANT ONE.
// Entries are not money, so they are not part of what the realm holds — but the rate
// at which this realm hands them out IS the security property of finding 15, and an
// O(1) statement of it belongs on every mutator's exit. If a future edit ever books
// entries worth more than the rake that paid for them, this is the line that fails,
// and it fails BEFORE the raffle's own door would refuse the batch — which matters,
// because the raffle refusing means a stuck flush and this means a refused Collect
// with nothing written.
//
// IT CANNOT FAIL FOR A REASON IN r/splash/arcade/raffle — AND THAT, NOT "no other realm",
// IS THE PROPERTY FINDING 14 ACTUALLY NEEDS. Until 2026-09-30 these lines claimed this
// function "reads no other realm at runtime … so it cannot fail for a reason outside this
// file", AND THAT WAS FALSE ON ITS FACE: the last check below calls
// wugnot.BalanceOf(selfAddr()), a live cross-realm read of r/gnoland/wugnot's ledger. The
// claim is corrected rather than deleted because the narrower one is true and is the one
// finding 14 rests on:
//
//	NO LINE OF RAFFLE CODE RUNS ON THIS PATH AND NO RAFFLE STATE IS READ.
//	raffle.EntryUnitPrice is a compile-time const, not a call, and maxEntryUnitsFor is
//	this realm's own arithmetic over this realm's own constants. Finding 14 is about a
//	panic in the RAFFLE taking a winner's payout down with it — Collect used to end in
//	the raffle's own checkInvariant — and that is what this independence buys.
//
// THE wugnot READ IS NOT A DEPENDENCY THIS FUNCTION COULD BE WITHOUT, which is why it is
// disclosed rather than removed: the escrow being checked IS a wugnot balance, so there is
// no version of this check that does not read the token. It is also not a new exposure on
// any mutator's exit — every path that reaches here has already moved wugnot in the same
// transaction (Post pulls, Collect pays), so a token that refused to answer would have
// aborted before this line. AUDIT-duel-2026-09-27.md addendum 2, finding D-3.
func checkInvariant() {
	if escrowed < 0 {
		panic("duel: escrow negative")
	}
	if pendingPot < 0 {
		panic("duel: pending rake negative")
	}
	if pendingEntryUnits < 0 {
		panic("duel: booked raffle entries negative")
	}
	if pendingEntryUnits > 0 && pendingPot <= 0 {
		// Entries with no rake behind them would be entries this realm cannot pay
		// for: the raffle prices its ceiling off the money delivered in the same
		// call, so a batch in this state could never be delivered at all.
		panic("duel: raffle entries are booked with no rake behind them")
	}
	if pendingEntryUnits > maxEntryUnitsFor(pendingPot) {
		panic("duel: booked raffle entries exceed what the booked rake would buy at the ticket price")
	}
	if pendingEntries.Size() > maxPendingEntryHolders {
		panic("duel: the pending entry batch is over its bound")
	}
	// THE LIVE COMMITMENT SET CANNOT HOLD MORE PAIRS THAN THERE ARE RECORDS THAT COULD HOLD
	// ONE, which is the O(1) half of the re-derivation AuditFailure does in full. Offers and
	// duels each hold at most one pair, so the set can never be larger than their sum; a set
	// that grew past it would mean a release was missed, and a missed release quietly refuses
	// an honest poster's future Post. Cheap, and it can fail.
	if int64(liveCommitments.Size()) > int64(offers.Size())+int64(duels.Size()) {
		panic("duel: more live commitments are held than there are records to hold them")
	}
	if wugnot.BalanceOf(selfAddr()) < escrowed+pendingPot {
		panic("duel: escrow invariant violated — the realm holds less than it owes")
	}
}

// --- API (SPEC-03 §4) -----------------------------------------------------

// requireUserCall refuses a Post or an Accept that did not come DIRECTLY FROM A USER.
// It is the only gate in this file that turns a caller away for what it IS rather than
// for what it owns or owes, and it was added on 2026-09-30 by
// AUDIT-duel-2026-09-27.md addendum 2, finding D-1.
//
// THIS IS THE RAFFLE'S FINDING-8 REASONING APPLIED TO THIS REALM'S OWN ESCROW, RATHER
// THAN ONLY TO ITS ENTRIES, AND THAT IS THE WHOLE POINT OF THE CHANGE. r/splash/arcade/raffle
// refuses realms outright in Buy because a ticket is a claim on an OUTBOUND TRANSFER and a
// realm's address is PACKAGE-DERIVED: nothing can move wugnot out of it unless that realm
// happens to contain code that does, so a realm that won a week would strand the whole pot
// in an address nobody can spend from. This realm imported that reasoning in 2026-09-29's
// finding 15 and applied it to EXACTLY ONE THING — whether a party earns raffle entries
// (PosterIsUser, TakerIsUser, bookEntries) — while leaving its own escrow wide open:
//
//	A REALM COULD POST, ACCEPT, WIN AND COLLECT. Collect is WINNER-ONLY, and VoidStale
//	refuses a resolved duel. So a winning realm that contains no code calling Collect
//	left 2 x stake sitting in this realm's escrow WITH NO EXIT AT ALL — not a delayed
//	exit, not a dear exit, none. Every path out of a resolved duel's pool goes through
//	Collect, and only the winner may walk it.
//
// AND THE BOOKS STAYED GREEN OVER IT, which is what made it invisible. The duel record is
// still there and still counted, so `escrowed` still matches it, AuditFailure still returns
// "" and checkInvariant still passes. The money is accounted for exactly; it is simply
// unreachable. That is the "money in, no way out" shape SIX of this product's findings have
// had, and this one was the seventh.
//
// WHY BOTH DOORS AND NOT ONLY Accept — THE ASYMMETRY THAT MAKES A ONE-SIDED GATE USELESS.
// Gating Accept alone leaves the identical defect reachable from the other side, because
// the losing party's identity is decided by a coin flip AFTER both stakes are escrowed:
//
//	realm posts, user accepts, THE REALM WINS -> Collect is the realm's alone to call,
//	and the pool is stranded. The user's stake is stranded with it.
//
// A one-sided gate would therefore have halved the probability of the defect and fixed
// none of it — and it would have stranded the money of the party this realm CAN vouch for,
// which is worse than the symmetric case. Both parties must be addresses that can call
// Collect, so both doors that make a party are gated.
//
// AND NEITHER OF THE OTHER TWO EXITS IS A WAY OUT OF IT, RE-CHECKED AGAINST THE COMMIT-REVEAL
// COIN ON 2026-09-30 BECAUSE THE OLD SENTENCE'S PREMISE IS GONE. It read "VoidStale is not a
// way out either: it refuses a resolved duel, and a duel whose round is published cannot be
// voided at all", and there are no rounds now. The argument survives in a different shape and
// is stronger, not weaker:
//
//	VoidStale now refuses EVERY duel that carries a commitment, so it cannot release a
//	realm's pool at all — not before the window, not after it, not ever.
//
//	Forfeit releases a pool without the winner's cooperation, but only while the duel is
//	UNREVEALED, and it pays THE TAKER. So it rescues exactly one of the two stranded cases
//	(a realm poster who never reveals) and not the case the gate is for: once the coin is
//	revealed and a REALM is the winner, Collect is the realm's alone to call and Forfeit
//	refuses a revealed duel. The gate is still the only thing standing between this realm
//	and a pool nothing in the universe can close.
//
// IsUserCall AND NOT IsUser, for the reason raffle.Buy states at length: IsUser also admits
// a `maketx run` ephemeral realm, which is code executing under a user's signature and not
// an EOA — its address is package-derived too, and it ceases to exist when the transaction
// ends. The predicate is about THE CALL, not the address, and it is only answerable while
// the call is on the stack.
//
// WHAT IS LOST, STATED PLAINLY BECAUSE IT IS A REAL CAPABILITY REMOVAL. No realm can play a
// duel any more: no vault, no strategy contract, no "flip on my behalf" wrapper, not even
// one that does contain a Collect call. This realm cannot tell those apart from the ones
// that do not — the raffle's Buy comment makes the same point ("this realm cannot tell which
// realms those are and must not try") — so it refuses them all at the door rather than
// stranding a pool at settlement time. THE ALTERNATIVE WAS NOT "realms can play safely", it
// was "a realm can create an escrow position that nothing in the universe can close", and
// that is not a trade. A realm that wants exposure can hold wugnot and let its user play.
//
// FUNCTIONS THIS DOES NOT GATE, AND WHY EACH IS RIGHT TO BE OPEN.
//
//	Cancel and Collect are restricted to a party of the record, and after this change every
//	such party is an address whose own call was a user call — so gating them again would be
//	redundant on every reachable record and would BRICK any record created before this
//	change if one existed. (Cancel has one permissionless case, a LEGACY offer, and that is
//	the whole reason it is permissionless: a pre-D-1 poster may be a realm that cannot call
//	anything, and the refund's destination is read from the record.)
//
//	Reveal, Forfeit, VoidStale, FlushPot and SweepStuckRake are permissionless keeper work
//	that pays nobody the caller names. Refusing realms there would remove the bystanders the
//	whole design relies on — and for Reveal it would be worse than useless, because the hash
//	IS the authorisation and a caller check would turn the secret into an off-chain
//	credential held by a de-facto third party to the duel. Read Reveal.
func requireUserCall(cur realm, what string) {
	if !cur.Previous().IsUserCall() {
		panic("duel: " + what + " must be called directly by a user — a realm cannot be a party to a duel, because Collect is winner-only and a package-derived address may have no way to call it")
	}
}

// rejectAttachedCoin panics if the caller attached native coin to a call that
// has no use for it. Every money-in path in this realm is the wugnot GRC20
// allowance (Post, Accept), never the transaction's send envelope, so any
// attached ugnot would simply sit in this realm forever with no code path
// that ever looks at it — AUDIT-2026-10-07.md Y1. Call this as the first
// statement of every crossing entrypoint so the transaction reverts and the
// sender keeps their coin instead.
//
// unsafe.OriginSend() reads the envelope attached at the CHAIN ROOT, and that
// envelope is shared by every realm in the call chain: an intermediate realm
// can consume it, or have already consumed it, before this call is ever
// reached. Reading it is only sound when the immediate caller is an EOA, so
// that whatever it describes was paid to THIS realm and nothing else first.
// cur.Previous().IsUserCall() is that check (IsUser() is not — it also
// accepts `maketx run` ephemeral realms, which can pre-consume the envelope);
// see r/splash/exchange/exchange.gno's Buy/Seed comment for the fuller
// argument, which this mirrors rather than contradicts. WHEN THE CALL DID NOT
// COME DIRECTLY FROM A USER — which, per requireUserCall's comment just
// above, is a deliberately open door on Cancel/Collect (legacy case),
// Reveal, Forfeit, VoidStale, FlushPot and SweepStuckRake — THIS FUNCTION
// DOES NOT LOOK AT THE ENVELOPE AT ALL: it cannot be attributed to this call
// either way, so there is nothing sound to enforce, and guessing would be
// worse than staying silent. It does not reopen any of those doors; it is
// simply inert on them.
//
// THE OVERWHELMINGLY COMMON CASE — a plain call with nothing attached — is
// cheap: one stack-walk for IsUserCall, then unsafe.OriginSend() always
// allocates (even a len-0 slice) and len(sent) == 0 is a single comparison.
// No iteration, no second cross-realm call.
func rejectAttachedCoin(cur realm, what string) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if sent := unsafe.OriginSend(); len(sent) != 0 {
		panic("duel: " + what + " does not take native coin — pay through the wugnot allowance instead")
	}
}

// Post pulls rungs[rung] from the caller through the GRC20 allowance path and
// leaves it standing in the lobby. Returns the new offer's ID.
//
// opponent, when non-zero, addresses the offer to one player: only that
// address may Accept it. Zero ("") leaves it open to anyone, and the offer
// then behaves exactly as it always did. A non-zero opponent must be a valid
// address, or the stake would stand for a player who can never exist and the
// poster's only way out would be Cancel.
//
// label is free text for the render, at most maxLabelLen bytes (checkLabel).
// "" is no label. Neither argument touches settlement: the coin still decides.
//
// commitHash IS THE POSTER'S HALF OF THE COIN AND IS NOW MANDATORY (changed 2026-09-30).
// It is H(commitTag ‖ secret) as 64 lowercase hex characters, for a secret of exactly 32
// bytes that the poster keeps and opens at Reveal. There is no salt and no second field:
// read checkSecret for why one fixed-length field is the requirement and not a preference.
//
//	THE SECRET MUST COME FROM A CSPRNG AND MUST BE FRESH FOR THIS OFFER. commitHash is a
//	free offline oracle — anybody can test candidate secrets against it forever, at no
//	cost — so a guessable secret is robbed SILENTLY, by a reveal this realm cannot tell
//	from an honest one. There is no on-chain entropy check and there cannot be one. The
//	full statement is item (1) of this file's doc comment; liveCommitments refuses the one
//	reuse case a contract can see.
//
// THE CALLER MUST BE A USER, NOT A REALM, SINCE 2026-09-30 (requireUserCall, finding
// D-1). A realm poster that WINS cannot call the winner-only Collect, which would leave
// the pool — its own stake AND its opponent's — in escrow with no exit whatever.
//
// EVERY CHECK RUNS BEFORE THE PULL, so a failed Post moves nothing and creates
// nothing (SPEC-03 §8 tests 1 and 2) — and that now includes the commitment's shape and
// its uniqueness, so a rejected commitment never costs a stake.
func Post(cur realm, rung int64, opponent address, label string, commitHash string) int64 {
	rejectAttachedCoin(cur, "Post")
	// A PARTY TO A DUEL MUST BE AN ADDRESS THAT CAN CALL Collect. See requireUserCall:
	// this is the raffle's finding-8 reasoning applied to THIS REALM'S OWN ESCROW, and
	// Post needs it for the same reason Accept does — a realm poster who WINS cannot be
	// paid, and the stake it strands is its opponent's as much as its own.
	requireUserCall(cur, "Post")

	stake := stakeOf(rung)
	if opponent != "" && !opponent.IsValid() {
		panic("duel: invalid opponent address")
	}
	checkLabel(label)
	checkCommitment(commitHash)
	caller := cur.Previous().Address()
	if wugnot.Allowance(caller, selfAddr()) < stake {
		panic("duel: insufficient allowance — approve this realm for the rung's stake first")
	}

	// BEFORE THE PULL, like every other check here: a reused commitment must cost the
	// poster a reverted transaction and not a stake standing in the lobby. The matching
	// WRITE is after the pull, beside the record — see holdCommitment for why the pair is
	// split around it.
	requireFreshCommitment(caller, commitHash)

	wugnot.TransferFrom(cross(cur), caller, selfAddr(), stake)

	id := nextOfferID
	nextOfferID++
	holdCommitment(caller, commitHash)
	offers.Set(idKey(id), &Offer{
		Poster:     caller,
		Rung:       rung,
		PostedAt:   runtime.ChainHeight(),
		Opponent:   opponent,
		Label:      label,
		CommitHash: commitHash,
		// CAPTURED HERE BECAUSE IT IS ONLY KNOWABLE HERE. Necessarily true since
		// 2026-09-30 — requireUserCall above has already refused every other case — and
		// recorded rather than assumed. See Offer.PosterIsUser for why it is kept.
		PosterIsUser: cur.Previous().IsUserCall(),
	})
	escrowed += stake

	chain.Emit("DuelPost",
		"offer", strconv.FormatInt(id, 10),
		"poster", string(caller),
		"rung", strconv.FormatInt(rung, 10),
		"stake", strconv.FormatInt(stake, 10),
		"opponent", string(opponent),
		"label", label,
		// THE COMMITMENT IS IN THE LOG BECAUSE THAT IS WHAT MAKES THE FLIP AUDITABLE FROM
		// OUTSIDE. A reader with the block log alone has the commitment from here, the nonce
		// from DuelAccept and the secret from DuelReveal, which is every input posterWins
		// takes — so anybody can re-derive any settled duel's winner without reading state.
		"commit", commitHash)
	checkInvariant()
	return id
}

// Cancel returns an unaccepted offer's stake to its poster, EXACTLY and with no
// fee, and deletes the record. Poster only.
//
// An accepted offer no longer exists — Accept deletes it in the same
// transaction that creates the duel — so "Cancel of an accepted offer" and
// "Cancel of an unknown offer" are the same refusal. That is what makes the
// Cancel-racing-Accept rule (SPEC-03 §7.5) hold by construction: whichever
// lands first in block order removes the offer, and the other finds nothing.
//
// AND THAT RACE IS NO LONGER HARMLESS, WHICH IS DISCLOSED HERE RATHER THAN ONLY IN THE
// FILE HEADER. Under the beacon the poster could not predict the outcome, so cancelling
// under a pending Accept gained them nothing. Since 2026-09-30 the taker's nonce is
// plaintext in the Accept transaction, so a poster watching the mempool CAN compute the
// outcome and cancel the ones they are about to lose. It is item (2) of this file's doc
// comment, it is OPEN, and removing Cancel would not close it — the poster can take their
// own offer instead, for the rake. It is recorded at the door it is reached through.
//
// PERMISSIONLESS FOR A LEGACY OFFER, AND ONLY FOR ONE. An offer with no commitment
// (Offer.CommitHash == "") can never be accepted — Accept refuses it — so the poster's
// stake would otherwise sit in the lobby until the poster themselves turned up, and a
// pre-D-1 poster may be a REALM that contains no code able to call this function. So for
// that one case any caller may cancel, and it is not a way to steal: the refund's
// destination is READ FROM THE RECORD and is the poster either way. Nothing is deployed, so
// no such offer exists; this is requirement 5's "the code must not contain a trap".
func Cancel(cur realm, offerID int64) {
	rejectAttachedCoin(cur, "Cancel")
	o := getOffer(offerID)
	if o == nil {
		panic("duel: no such offer")
	}
	caller := cur.Previous().Address()
	if caller != o.Poster && o.CommitHash != "" {
		panic("duel: only the poster may cancel")
	}
	stake := stakeOf(o.Rung)

	// Delete BEFORE paying, so no path exists on which the offer is both
	// refunded and still standing. The commitment is released with the record it belonged
	// to, so the poster may stand a new offer under the same secret — which they should not
	// do, but which is theirs to decide once nothing live depends on it.
	offers.Remove(idKey(offerID))
	releaseCommitment(o.Poster, o.CommitHash)
	escrowed -= stake

	wugnot.Transfer(cross(cur), o.Poster, stake)

	chain.Emit("DuelCancel",
		"offer", strconv.FormatInt(offerID, 10),
		"poster", string(o.Poster),
		"stake", strconv.FormatInt(stake, 10))
	checkInvariant()
}

// Accept takes a standing offer: pulls a stake equal to THE OFFER'S rung — the
// caller chooses nothing about the money — deletes the offer, records the taker's NONCE
// and creates the duel. Returns the new duel's ID.
//
// nonce IS THE TAKER'S HALF OF THE COIN AND IT TRAVELS IN THE CLEAR: 32 bytes as 64
// lowercase hex characters (checkNonce). No commitment and no reveal from the taker, and
// therefore NO EXTRA TRANSACTION — one more argument on the call they were already making.
// Read posterWins for why plaintext is safe from the taker's own side: they choose the
// nonce WITHOUT the secret, so every nonce they could pick is a coin they cannot evaluate,
// and choosing among coins you cannot see is not choosing. A CSPRNG is the right source
// here too, though for a different reason than the poster's: a nonce a poster could have
// ANTICIPATED (all zeroes, the taker's own address, a counter) lets the poster grind their
// secret against it at Post time, which is the one way the poster-cannot-grind property
// can be handed away by the other party.
//
// THE PLAINTEXT NONCE IS ALSO THIS DESIGN'S ONE OPEN WEAKNESS, and the taker should know
// it at the door they walk through: a poster watching the mempool can read the nonce out of
// this very transaction before it is committed, compute the outcome, and try to abort the
// Accept by cancelling or by self-matching. Item (2) of this file's doc comment has the
// argument, the two moves and why neither is closed here.
//
// AN OFFER WITH NO COMMITMENT IS REFUSED, AND THAT REFUSAL IS THE WHOLE OF REQUIREMENT 5 ON
// THIS SIDE. A legacy offer (created before 2026-09-30) carries no commitHash, so no secret
// exists that could ever open it and Reveal could never run. Accepting one would create a
// duel whose only exit after the window is Forfeit — which pays the TAKER — so anybody could
// have taken a legacy offer and been handed the poster's stake for nothing. So such an offer
// cannot be accepted at all; its exit is Cancel, permissionless for exactly this case.
//
// THERE IS NO ROUND, NO BEACON AND NOTHING TO WAIT FOR. Everything this function used to do
// about randomness is gone: no anchor, no staleness tolerance, no offset, no assertion that
// the bound round is in the future. Read this file's doc comment for why that binding could
// not be repaired. The consequence a player sees is that settlement is available IN THE NEXT
// BLOCK rather than 300 seconds and one 17M-gas relay later.
//
// The caller MAY be the poster (SPEC-03 §7.3): self-matching wins half the time and pays
// the rake regardless, a guaranteed 3% loss, so a guard would cost code and buy nothing.
// THAT REASONING NEEDED RE-CHECKING UNDER THE NEW COIN AND IT SURVIVES, in a sharper form
// worth writing down: a self-matcher holds the secret AND chooses the nonce, so they can
// grind the nonce and win with CERTAINTY — against themselves. Winner and loser are one
// address, the pool returns to it less the rake, and certainty about which pocket it lands
// in is worth nothing. It is still a guaranteed 3% loss, and it is still the case that the
// only party a self-match can take money from is the self-matcher.
// An offer ADDRESSED to an opponent is the one exception, and only by construction: then the
// opponent is the only address that may accept, and the poster is not it unless they named
// themself.
//
// THE CALLER MUST HOWEVER BE A USER AND NOT A REALM, SINCE 2026-09-30. That is the one
// thing about WHO may accept that this function refuses, and requireUserCall has the
// argument: a realm taker that wins cannot call the winner-only Collect, so the pool
// would have no exit at all — the poster's stake included. It is the raffle's finding-8
// reasoning (a package-derived address nothing can spend from) applied to this realm's
// own escrow rather than only to the raffle entries a duel earns. AUDIT-duel-2026-09-27.md
// addendum 2, finding D-1.
//
// EVERY CHECK RUNS BEFORE THE PULL. The second of two Accepts on one offer in
// a block therefore finds no offer and fails before touching the caller's
// wallet: its stake is never pulled, so there is nothing to return (SPEC-03
// §7.4). It cannot join, overwrite or silently succeed.
func Accept(cur realm, offerID int64, nonce string) int64 {
	rejectAttachedCoin(cur, "Accept")
	// A PARTY TO A DUEL MUST BE AN ADDRESS THAT CAN CALL Collect (requireUserCall).
	// Checked before the offer is even looked up: nothing about which offer was named
	// changes the answer, and the refusal must not depend on the lobby's contents.
	requireUserCall(cur, "Accept")

	// AND THE NONCE'S SHAPE IS CHECKED BEFORE THE LOOKUP FOR THE SAME REASON: a malformed
	// nonce is a malformed call whatever the lobby holds, and this is the "validated at both
	// ends" half that belongs at the door (checkNonce; checkSecret is the other end).
	checkNonce(nonce)

	o := getOffer(offerID)
	if o == nil {
		panic("duel: no such offer")
	}
	if o.CommitHash == "" {
		// LEGACY, AND IT MUST NOT BECOME A DUEL. See this function's doc comment: no secret
		// can open an absent commitment, so such a duel could only ever end in Forfeit, which
		// pays the taker. Requirement 5.
		panic("duel: this offer predates the commit-reveal coin and carries no commitment, so it can never be revealed — it can only be cancelled")
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

	// THE OFFER IS DELETED BEFORE THE PULL, the same ordering as Cancel,
	// Collect, Forfeit and VoidStale: the record goes first, the money moves second.
	// Until AUDIT-duel-2026-09-27 F2 this function pulled first and deleted
	// after, which was safe only because wugnot's TransferFrom has no hook or
	// callback through which Accept could be re-entered — a load-bearing
	// assumption about ANOTHER realm that was stated nowhere. With the removal
	// first, a re-entrant Accept on this offer finds nothing whatever the token
	// does, and the file has one ordering rule instead of one-and-an-exception.
	//
	// THE COMMITMENT IS NOT RELEASED HERE, and that is the point of it being keyed by the
	// PAIR and not by the record: the offer dies but the same commitment is now held by the
	// duel, continuously, so the poster cannot stand a second offer under the same secret
	// while this duel is live.
	//
	// WHAT THIS ORDERING RELIES ON, stated because it is load-bearing: a pull
	// that fails panics across a realm boundary, which aborts the transaction
	// and discards the removal with it — the same atomicity Collect relies on
	// when it deletes before it pays. Nothing on-chain can catch that panic and
	// continue (revive() exists only under `gno test`, and even there it keeps
	// pre-abort writes — see duel_test.gno's F2 note), so no path exists on
	// which the offer is gone and the taker's stake was not pulled.
	offers.Remove(idKey(offerID))

	wugnot.TransferFrom(cross(cur), caller, selfAddr(), stake)

	id := nextDuelID
	nextDuelID++
	duels.Set(idKey(id), &Duel{
		Poster:     o.Poster,
		Taker:      caller,
		Rung:       o.Rung,
		Label:      o.Label,
		CommitHash: o.CommitHash,
		Nonce:      nonce,
		AcceptedAt: runtime.ChainHeight(),
		// CARRIED, NOT RE-DERIVED: the poster's call is long gone by now, so its
		// flag can only come from the offer. The taker's is this very call. Neither
		// gates anything here — see Duel.PosterIsUser.
		PosterIsUser: o.PosterIsUser,
		TakerIsUser:  cur.Previous().IsUserCall(),
	})
	// The poster's stake was already in escrow; only the taker's arrives now.
	escrowed += stake

	chain.Emit("DuelAccept",
		"offer", strconv.FormatInt(offerID, 10),
		"duel", strconv.FormatInt(id, 10),
		"poster", string(o.Poster),
		"taker", string(caller),
		"rung", strconv.FormatInt(o.Rung, 10),
		// THE NONCE AND THE DEADLINE, so the block log alone carries both the second input
		// to posterWins and the height at which anybody may Forfeit. "round" used to stand
		// in the first of these slots; it is not renamed, it is replaced, because there is
		// no round.
		"nonce", nonce,
		"commit", o.CommitHash,
		"revealBy", strconv.FormatInt(runtime.ChainHeight()+revealWindowBlocks, 10))
	checkInvariant()
	return id
}

// Reveal opens the poster's commitment, names the winner, and is PERMISSIONLESS.
//
// IT IS Resolve, AND Resolve IS GONE — MERGED INTO THIS FUNCTION RATHER THAN KEPT BESIDE
// IT, WHICH REQUIREMENT 4 ASKS TO BE JUSTIFIED. Resolve's entire body was: read the
// outcome's source, compute the winner, store it, refuse a second call. This function is
// that same body with a different source — an argument instead of a cross-realm read of
// beacon.Randomness(d.Round). Keeping both would mean two doors onto ONE state transition,
// and the second door would have NO SOURCE AT ALL: there is no round to read, so a
// surviving Resolve could only either do nothing or invent an outcome. A vestigial
// settlement entry point on a realm with no owner and no upgrade path is precisely the
// shape this project keeps finding (a dead premise that outlives the thing it depended on),
// so the transition has exactly one door and the door names what it needs.
//
// THE HASH IS THE AUTHORISATION, SO THERE IS DELIBERATELY NO CALLER CHECK — REQUIREMENT 2,
// AND IT IS A SECURITY PROPERTY AND NOT A CONVENIENCE. Only somebody who holds the secret
// can pass the check below, and by the time this can be called the secret is worth nothing
// to anybody: the nonce is already fixed in the record, so the outcome is already
// determined and revealing cannot change it. Two things follow, both wanted:
//
//	SETTLEMENT STAYS PERMISSIONLESS. A poster who has revealed to their opponent
//	off-chain, or published the secret anywhere, can have the duel settled by any
//	bystander — exactly as the beacon version let any bystander Resolve. Nothing about a
//	duel's conclusion depends on one particular address being willing to send a
//	transaction.
//
//	AND NO TRUSTED SECRET-HOLDER IS CREATED. A caller check would make "the address that
//	may reveal" a third role in the contract, and a poster who wanted a front end or a bot
//	to settle for them would have to hand that role the secret while it still mattered.
//	The secret would become a credential held off chain by a de-facto party to the duel.
//	With no check, the secret is a credential for nothing.
//
// WHAT IT REFUSES: a duel that does not exist, a duel already revealed (so no later caller
// and no later secret can move a winner that is already fixed — the same once-and-only-once
// Resolve had), a secret of the wrong length or spelling (checkSecret), and a secret whose
// commitment is not this duel's. Nothing is paid here: Collect pays, and deletes.
//
// THE REVEAL WINDOW IS NOT CHECKED HERE, AND THAT IS ON PURPOSE. A late reveal is welcome
// as long as the pool is still there — an honest poster whose transaction was delayed keeps
// a duel they won, and nobody is harmed by a reveal on day two of an uncollected duel. What
// the window does is open Forfeit; the RACE between a late Reveal and a Forfeit is settled
// by block order, and both outcomes are legitimate. The suite drives that ordering both
// ways (reveal-after-expiry, and forfeit-then-reveal-refused).
func Reveal(cur realm, duelID int64, secret string) {
	rejectAttachedCoin(cur, "Reveal")
	d := getDuel(duelID)
	if d == nil {
		panic("duel: no such duel")
	}
	if d.Resolved {
		panic("duel: already revealed")
	}
	if d.CommitHash == "" {
		// LEGACY: no commitment exists, so no secret can open it. Said explicitly rather
		// than left to fail the comparison below, because the right next call is VoidStale
		// and a reader deserves to be told so. Unreachable for any duel created since
		// 2026-09-30 — Accept refuses a commitment-less offer. Requirement 5.
		panic("duel: this duel predates the commit-reveal coin and has no commitment to open — void it instead")
	}
	// LENGTH AND ENCODING FIRST (checkSecret), WHICH IS REQUIREMENT 1'S OTHER END. The
	// commitment was checked at Post and the secret is checked here, so the preimage
	// commitTag ‖ secret is fixed-length at both moments and has exactly one split. Without
	// this, a 63- or 65-character "secret" would be a different preimage of a hash nobody
	// committed to — which is harmless on its own, but it is the door through which a
	// variable-length opening walks back in.
	if commitmentOf(secret) != d.CommitHash {
		panic("duel: the secret does not open this duel's commitment")
	}

	winner := d.Taker
	if posterWins(secret, d.Nonce, duelID) {
		winner = d.Poster
	}
	d.Resolved = true
	d.Winner = winner
	// STORED SO THE OUTCOME IS RE-DERIVABLE FROM THE RECORD ALONE, and so that AuditFailure
	// can re-check every resolved duel's winner against the hash rather than taking the
	// stored winner's word for it. See Duel.Secret.
	d.Secret = secret

	chain.Emit("DuelReveal",
		"duel", strconv.FormatInt(duelID, 10),
		"winner", string(winner),
		// EVERY INPUT TO posterWins IS NOW IN THE LOG: the commitment from DuelPost, the
		// nonce from DuelAccept, and the secret here. Anybody can recompute the parity and
		// check this realm against itself without reading a single storage slot.
		"secret", secret,
		"nonce", d.Nonce,
		"commit", d.CommitHash)
	checkInvariant()
}

// Collect pays the winner 2 x stake - rake, forwards the rake, and DELETES THE
// DUEL. Winner only.
//
// Conservation (SPEC-03 §7.2): payout + rake == 2 x stake exactly, and the
// rake's two parts sum exactly to the rake — the raffle pot share takes the
// remainder.
//
// THE RECORD IS DELETED BEFORE ANYTHING IS PAID. That single ordering is what
// makes a second Collect fail instead of double-paying (SPEC-03 §7.6): by the
// time the first transfer runs, there is no duel for a re-entrant or repeated
// call to find. It also reclaims the storage deposit (SPEC-03 §7).
//
// AND IT BOOKS THE ENTRIES THE RAKE EARNED ITS TWO PLAYERS (finding 15). Booked here,
// delivered by FlushPot with the money, and credited to nobody else: the winner takes a
// third, the LOSER takes two thirds, and the two sum to exactly what that rake would
// have bought at raffle.EntryUnitPrice. Read rakeEntryUnits for why the rake and never the
// stake is the price base — it is what stops two accounts flipping each other for cheap
// entries — and bookEntries for the two reasons a party can earn nothing (they played
// from realm code, or the undelivered batch is full). NEITHER CAN MAKE THIS FUNCTION
// FAIL: a winner's collect must never depend on a raffle entry.
//
// AN EARNED ENTRY IS NOT A COIN FLIP AND IT CARRIES A DISCLOSED, STILL-OPEN RISK THAT
// YOUR FLIP DOES NOT. The entry is in r/splash/arcade/raffle's weekly draw, which is
// settled by a drand round PINNED WHEN THE WEEK OPENED against an estimate of drand's
// current round derived from chain height. If that estimate drifts — slow blocks, or a
// beacon nobody has relayed to lately — the week's winning randomness can become
// publicly readable on api.drand.sh BEFORE the week's ticket sales close, and whoever
// reads it can buy last and size the buy to own the winning unit. THE POT THEY WOULD BE
// TAKING IS MOSTLY DUEL RAKE. It is bounded by the beacon's staleness refusal and by a
// measured margin, it is nobody's key and nobody's privilege, and it is recorded OPEN:
// the full disclosure, the bound and what it rests on are at rakeEntryUnits above, and
// the record is AUDIT-2026-09-28.md findings 4, 10, 12, 13 and 20.
//
// WHERE THE RAKE GOES (BIBLE.md §4.15 S12): the pot share through
// raffle.FundPot — the raffle's named, permissionless, caller-pays door, approved
// for exactly its amount in the same transaction, so a panic anywhere reverts the
// approval with everything else — and the ops share by plain transfer to
// r/splash/ops.
//
// REPOINTED AT THE RAFFLE 2026-09-28, AND THE SPLIT DID NOT MOVE. The players'
// side of the rake used to go through two doors, game.FundYield (5000 bps) and
// game.FundPrizes (the remainder, 3000 bps plus all dust). r/splash/game's
// permanent-deposit yield product is retired, so there is no yield to fund and
// the yield share is folded into the pot share rather than dropped: one call,
// carrying rake - opsShare, which is exactly what the two calls carried between
// them. The ops share is computed by the same floored formula as before, so the
// house takes neither more nor less than it did. Integer-division dust was the
// prize share's and is now the raffle pot's — it has always gone to the players'
// side, and still does. SPONSORSHIP BUYS NO TICKETS: the raffle records it as
// house money in the week's pot, attributable to no buyer, so this realm never
// gains a winning chance in a draw it funds.
//
// IT FUNDS WHATEVER WEEK IS LIVE WHEN THE DUEL IS COLLECTED, which is the point —
// every coin flip makes this Saturday's prize bigger — and needs no coordination:
// FundPot creates the week's record if the week has not sold a ticket yet, and the
// live week is uncommitted by construction, so a settlement can never arrive at a
// frozen pot.
//
// (The previous note here recorded that between cd29697 and 2026-09-28 the whole
// rake went by one transfer to the ops vault, because the game's doors pulled
// r/splash/token while this realm held wugnot. That detour is over: the players'
// side now reaches the players, in the one product they can play this week.)
func Collect(cur realm, duelID int64) {
	rejectAttachedCoin(cur, "Collect")
	d := getDuel(duelID)
	if d == nil {
		panic("duel: no such duel")
	}
	if !d.Resolved {
		panic("duel: not revealed yet — anybody holding the poster's secret may Reveal it, and after the reveal window anybody may Forfeit it")
	}
	caller := cur.Previous().Address()
	if caller != d.Winner {
		panic("duel: only the winner may collect")
	}
	settle(cur, duelID, d, d.Winner, "DuelCollect")
}

// Forfeit ends a duel whose poster never opened their commitment: after revealWindowBlocks
// the TAKER takes the pool on exactly the terms the winner of a revealed duel would have.
// PERMISSIONLESS, and the destination is READ FROM THE RECORD.
//
// WHY THE TAKER, AND WHY THIS IS THE WHOLE INCENTIVE ARGUMENT FOR THE DESIGN. After Accept
// the outcome is already determined — the secret is fixed, the nonce is in the record — but
// only the poster can see it. So the poster's choice is: reveal, or withhold. Paying the
// taker on withholding makes those two choices IDENTICAL IN MONEY when the poster has lost
// (they hand over the pool either way) and STRICTLY WORSE when the poster has won (they hand
// over a pool they could have taken). Withholding therefore never pays, at any rung, and
// the only thing it buys is up to revealWindowBlocks of delay — which costs the poster the
// same wait. Pay the POSTER on expiry instead and the design inverts: the poster would
// withhold every loss and the coin would be a one-way bet.
//
// PERMISSIONLESS, FOR THE REASON EVERY EXIT IN THIS FILE IS. The taker is the only party
// who gains, so the taker has the incentive — but their willingness to send a transaction
// must not be what stands between the pool and an exit. A bystander, a front end or a
// keeper may fire it; the money still goes where the record says. Requirement 3.
//
// AND IT SETTLES THROUGH THE SAME ARITHMETIC AS Collect, WHICH IS NOT A TIDINESS POINT BUT
// THE MOST-REPEATED DEFECT IN THIS PROJECT. It calls the same settle() — same rake, same
// split, same entries, same books. The alternative shapes were considered and both of the
// safe ones are: the same rake AND the same entries (this), or NO rake and NO entries (the
// VoidStale shape). WHAT MUST NEVER SHIP IS ENTRIES WITHOUT RAKE: checkInvariant panics on
// `pendingEntryUnits > 0 && pendingPot <= 0`, so a forfeit that booked entries without
// booking the rake behind them would panic on its own exit — bricking THE ONLY EXIT this
// state has and stranding the pool with the books reading green. A separate copy of the
// payout arithmetic is exactly how that gets written, so there is no separate copy.
//
// A LEGACY DUEL IS REFUSED HERE, AND THAT REFUSAL IS THE POINT OF REQUIREMENT 5. A duel with
// no commitment can never be revealed by anybody, so its expiry is not a poster's silence —
// it is a certainty from the moment it was accepted. Forfeiting it would hand the taker the
// poster's stake for nothing. VoidStale refunds both stakes instead, and this function will
// not touch such a record. Unreachable since Accept refuses commitment-less offers.
//
// Panics if the duel does not exist, if it is already revealed (Collect is then the path, and
// the winner it names may not be the taker), if it carries no commitment, or if the window
// has not elapsed.
func Forfeit(cur realm, duelID int64) {
	rejectAttachedCoin(cur, "Forfeit")
	d := getDuel(duelID)
	if d == nil {
		panic("duel: no such duel")
	}
	if d.Resolved {
		panic("duel: already revealed — the winner collects, and a forfeit cannot take that away")
	}
	if d.CommitHash == "" {
		panic("duel: this duel predates the commit-reveal coin and could never have been revealed, so its expiry is not a forfeit — void it instead")
	}
	if runtime.ChainHeight()-d.AcceptedAt < revealWindowBlocks {
		panic("duel: the reveal window has not elapsed")
	}
	// THE DESTINATION IS THE RECORD'S, NOT THE CALLER'S. Read from the Duel and passed in,
	// so a permissionless door cannot be a way to name a payee.
	settle(cur, duelID, d, d.Taker, "DuelForfeit")
}

// settle is THE ONE payout path: it pays `winner` pool - rake, books the players' side of
// the rake and the raffle entries it earned, pays the ops share, deletes the record and
// emits `event`. Collect and Forfeit are both one caller check and a call to this.
//
// ONE COPY, DELIBERATELY, AND THE REASON IS REQUIREMENT 3. Two exits that pay the same pool
// on the same terms must not have two copies of the rake-and-entry arithmetic, because the
// failure mode of a drifted copy is not a wrong number — it is a booked entry with no
// booked rake behind it, which checkInvariant refuses on the way out of the very function
// that created it. That panic would brick the exit and strand the pool while `escrowed`,
// AuditFailure and checkInvariant all still read green over it. Six of this product's
// findings have had the "money in, no way out" shape; this is the cheapest possible way to
// not add a seventh.
//
// `winner` IS AN ARGUMENT AND NOT READ FROM THE RECORD, because the two callers learn it
// differently: Collect reads d.Winner, which Reveal fixed from the coin, and Forfeit uses
// d.Taker, which the poster's silence fixed. Both are values of the record; neither is the
// caller's to choose. It is asserted below that the winner is a party to the duel, which is
// the property that actually matters and is cheap to state where the money moves.
func settle(cur realm, duelID int64, d *Duel, winner address, event string) {
	if winner != d.Poster && winner != d.Taker {
		// Unreachable from either caller; stated because this is the line between "the pool
		// goes to a party of this duel" and "the pool goes somewhere", and it is the only
		// place both callers' choices meet.
		panic("duel: the payee is not a party to this duel")
	}

	stake := stakeOf(d.Rung)
	pool := poolOf(stake)
	rake := rakeOf(pool)
	payout := pool - rake
	potShare, opsShare := splitRake(rake)
	if payout+potShare+opsShare != pool {
		// A real check, not a tautology: payout and the two shares are each
		// computed from the pool by their own path above, and this is the
		// first place all three meet.
		panic("duel: conservation violated — payout plus rake is not the pool")
	}

	// WHO LOST, AND WHICH OF THE TWO PARTIES MAY EARN ENTRIES. Both are read from the
	// record before it is deleted. A self-matched duel (poster == taker, SPEC-03 §7.3)
	// makes the winner and the loser the same address, which is correct and is the
	// self-dealing case the pricing rule is built for: the two shares aggregate to the
	// same total under one key, so one hand flipping itself earns exactly the total the
	// rake bought and not a unit more.
	loser := d.Taker
	winnerIsUser, loserIsUser := d.PosterIsUser, d.TakerIsUser
	if winner != d.Poster {
		loser = d.Poster
		winnerIsUser, loserIsUser = d.TakerIsUser, d.PosterIsUser
	}
	winnerUnits, loserUnits := splitEntries(rakeEntryUnits(rake))

	duels.Remove(idKey(duelID))
	releaseCommitment(d.Poster, d.CommitHash)
	escrowed -= pool

	wugnot.Transfer(cross(cur), winner, payout)
	if potShare > 0 {
		// BOOKED, NOT SENT, AND NOT ONE LINE OF RAFFLE CODE RUNS IN THIS TRANSACTION.
		// Read pendingPot: this used to be an Approve plus a raffle.FundPot here, and
		// FundPot ends in the raffle's checkInvariant, so any panic in the raffle took
		// this winner's payout with it — permanently, because the void path refuses a
		// settled duel. FlushPot delivers this to the raffle's current week later, and
		// anybody may call it.
		if pendingPot == 0 {
			pendingSince = runtime.ChainHeight()
		}
		pendingPot += potShare

		// AND THE ENTRIES THAT RAKE BOUGHT, BOOKED IN THE SAME BREATH AND INSIDE THIS
		// BRANCH DELIBERATELY. Entries must never exist without the money that pays for
		// them: the raffle prices its ceiling off the amount delivered in the same call,
		// so a booked entry with no booked rake behind it could never be delivered at
		// all. Being inside `potShare > 0` makes that structural rather than asserted —
		// and checkInvariant asserts it anyway. IT IS ALSO WHY FORFEIT SHARES THIS CODE
		// RATHER THAN HAVING ITS OWN: requirement 3, and the note on this function.
		//
		// STILL NOT ONE LINE OF RAFFLE CODE RUNS IN THIS TRANSACTION. bookEntries writes
		// this realm's own tree; FlushPot is what talks to the raffle. Finding 14.
		winnerUnits = bookEntries(winner, winnerUnits, winnerIsUser)
		loserUnits = bookEntries(loser, loserUnits, loserIsUser)
	} else {
		// No rake to pay for entries, so there are none. Unreachable on today's
		// ladder (every rung's rake is positive), and stated rather than left to the
		// reader to work out from the branch above.
		winnerUnits, loserUnits = 0, 0
	}
	if opsShare > 0 {
		wugnot.Transfer(cross(cur), opsVaultAddr, opsShare)
	}

	// ONE EVENT SHAPE FOR BOTH EXITS, WITH THE NAME AS THE ONLY DIFFERENCE, so an indexer
	// reads a forfeit with the code it already has for a collect and a reader can see at a
	// glance that the money moved identically. THE SPLIT DID NOT MOVE: potShare is the same
	// number computed the same way, still the players' side of the rake in its entirety,
	// dust included; "rafflePot" is the amount destined for the pot and "pending" says it
	// has not gone yet.
	chain.Emit(event,
		"duel", strconv.FormatInt(duelID, 10),
		"winner", string(winner),
		"payout", strconv.FormatInt(payout, 10),
		"rake", strconv.FormatInt(rake, 10),
		"rafflePot", strconv.FormatInt(potShare, 10),
		"ops", strconv.FormatInt(opsShare, 10),
		"pending", strconv.FormatInt(pendingPot, 10),
		// THE ENTRIES EACH PARTY ACTUALLY EARNED, after any decline or drop, so the
		// block log alone shows both the rate and the consolation weighting. The loser
		// is named because it is the only place in this realm that records who lost.
		"loser", string(loser),
		"winnerEntries", strconv.FormatInt(winnerUnits, 10),
		"loserEntries", strconv.FormatInt(loserUnits, 10),
		"pendingEntries", strconv.FormatInt(pendingEntryUnits, 10))
	checkInvariant()
}

// bookEntries credits `holder` with `units` raffle entry units, booked in this realm
// for FlushPot to deliver, and returns what it actually booked — which is zero when
// the holder is not eligible or the batch is full. IT NEVER PANICS AND NEVER
// REFUSES ITS CALLER: a winner's Collect must not be able to fail over a raffle
// entry (AUDIT-2026-09-28.md finding 14), so every reason not to credit somebody is
// a zero and an event, not an abort.
//
// TWO REASONS A PARTY EARNS NOTHING, both deliberate and both visible in the log:
//
//   - THE PARTY DID NOT PLAY FROM A USER CALL. A raffle entry is a claim on the
//     raffle pushing a whole week's pot to that address, and a realm's address is
//     package-derived — nothing can spend from it unless that realm contains code
//     that does, so a realm winning a raffle week would strand the entire pot
//     (AUDIT-2026-09-28.md finding 8, which is why raffle.Buy refuses realms
//     outright). The raffle cannot check this for a bare address, so it is checked
//     here, where the call was. The check is IsUserCall and not IsUser for the reason
//     the raffle's Buy states: a `maketx run` ephemeral realm's address is
//     package-derived too.
//
//     THIS BRANCH IS UNREACHABLE FROM Post AND Accept SINCE 2026-09-30 AND IS KEPT
//     DELIBERATELY. The sentence that stood here — "a realm may still post, accept, win
//     and collect; it simply earns no entries" — described the state finding D-1 closed:
//     settlement was open to realms, so a winning realm stranded 2 x stake in this
//     realm's escrow with no exit, because Collect is winner-only. Both doors now
//     require a direct user call (requireUserCall), so every party of every duel is
//     eligible and `isUser` arrives true. The check stays because it is the ONLY place
//     finding 8's property is enforced for entries — the raffle's FundPotWithEntries
//     admits this package path and trusts it to have checked — so a future relaxation
//     of either gate, or a future caller of bookEntries that is not Collect, must fail
//     as a dropped entry and an event rather than as a raffle pot pushed to an address
//     that cannot spend it. A guard that has become unreachable by a change elsewhere is
//     cheap; re-deriving why it was needed is not.
//   - THE BATCH IS FULL. See maxPendingEntryHolders: an unbounded batch could grow
//     past what a block can deliver, which would brick the booked rake's primary
//     exit. Any caller can empty the batch at any time by flushing.
func bookEntries(holder address, units int64, isUser bool) int64 {
	if units <= 0 {
		return 0
	}
	if holder == "" {
		// Unreachable: every party came from cur.Previous().Address(). Silent zero
		// rather than a panic, for the reason in this function's doc comment.
		return 0
	}
	if !isUser {
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
			"reason", "the undelivered entry batch is full — call FlushPot")
		return 0
	}
	if !pendingEntries.Has(k) {
		// A NEW HOLDER ADVANCES SweepStuckRake'S CLOCK, so that the window tracks THE
		// YOUNGEST CLAIM IN THE BATCH and not the batch's age. AUDIT-duel-2026-09-27.md
		// addendum 2, finding D-4 — read pendingSince for the defect this closes, which is
		// that a player who settled on day 20 of a 21-day window had their entries
		// destroyed by a clock that started before they played.
		//
		// IT IS THE ADMISSION OF A HOLDER AND NOT EVERY BOOKING, AND THAT IS THE WHOLE
		// REASON THE SWEEP STAYS REACHABLE. An existing holder's further units inherit the
		// batch's clock. If every booking advanced it, ONE repeat player settling a duel
		// every twenty days could defer the last resort for ever — and the last resort is
		// what stops pendingPot being a place money enters and never leaves, so an
		// indefinitely deferrable one is not an exit. Admissions are bounded by
		// maxPendingEntryHolders, so the clock can be advanced AT MOST 128 TIMES and the
		// window always closes.
		//
		// THE RESIDUAL, STATED RATHER THAN LEFT TO BE FOUND: a returning holder's
		// additional units do inherit an older clock, so they can still be swept sooner
		// than 21 days after they were earned. That is the deliberate limit of this fix —
		// the alternative is the unbounded deferral above — and it is much the smaller
		// case, because such a player is already in the batch and has already had every
		// opportunity to flush it themselves.
		pendingSince = runtime.ChainHeight()
	}
	pendingEntries.Set(k, entryUnitsOf(k)+units)
	pendingEntryUnits += units
	return units
}

// entryUnitsOf reads the booked entry units for a tree key, zero if absent. avl's
// Get returns a single value, so existence is a separate Has.
func entryUnitsOf(k string) int64 {
	if !pendingEntries.Has(k) {
		return 0
	}
	return pendingEntries.Get(k).(int64)
}

// --- delivering the players' side of the rake ------------------------------

// pendingGraceBlocks is how long the YOUNGEST CLAIM in the booked batch must have stood
// before SweepStuckRake's last resort opens: 21 days of blocks, the same window
// r/splash/arcade/raffle gives a committed week before its refunds open.
//
// "THE YOUNGEST CLAIM", NOT "DELIVERY HAS BEEN FAILING", corrected 2026-09-30 by finding
// D-4. Nothing in this realm can observe a failed flush — a failed flush reverts, taking
// any record of itself with it — so no window here can measure what the paragraph below
// once said it measured. Read pendingSince for what it does measure and for the two
// consequences, one accepted and one closed.
//
// WHY A WINDOW AT ALL: without one, SweepStuckRake would be a free way for anyone to
// divert the players' side of every rake out of the prize pot and into the raffle's ops
// pot. The window is what makes it a last resort rather than a choice.
//
// WHY 21 DAYS AND NOT LESS: every refusal FundPot can raise except a raffle accounting
// deficit is transient, and the longest of them is bounded by a raffle WEEK — a committed
// or abandoned current week (both unreachable for the live week by construction, see
// FundPot) and a beacon nobody has relayed to (clearable by any caller with one Publish).
// Three weeks is comfortably longer than one, so the sweep cannot fire on a transient
// refusal that a single FlushPot would have cleared.
//
// THERE IS DELIBERATELY NO SECONDS-ON-BOTH-SIDES BUILD GUARD ON THIS ONE, and that is a
// considered omission rather than the defect AUDIT-2026-09-28.md finding 11 is about. What
// this window has to outlast is a raffle week, which is itself a BLOCK count in the
// raffle (raffleWeekDays * blocksPerDay) — so both sides would come from the same clock,
// the block time would cancel, and the guard could not fail. A guard that cannot fail is
// worse than none, because it looks like protection. The relation is stated here instead:
// pendingGraceBlocks must stay several raffle weeks long, and the raffle's week is
// blocks, so the two move together whatever the block time turns out to be.
const pendingGraceBlocks = blocksPerDay * 21

// FlushPot delivers the whole booked rake to r/splash/arcade/raffle's CURRENT week and
// returns the amount delivered. PERMISSIONLESS: anyone may pay the gas to do it, and the
// destination is not theirs to choose.
//
// THIS IS THE FUNCTION Collect USED TO BE THE SECOND HALF OF. The split is the whole fix:
// a raffle that will not accept the rake now costs the CALLER OF THIS FUNCTION a reverted
// transaction and nothing else. The winner has already been paid, the duel record is
// already gone, and pendingPot is still here for the next attempt. Nothing about a duel
// depends on the raffle any more.
//
// BOOKS FIRST, CALL SECOND, and the revert is what makes that safe. pendingPot is zeroed
// BEFORE raffle.FundPot runs, so a re-entrant call finds nothing to send twice; and if
// FundPot panics, the panic aborts this whole transaction and discards the zeroing with
// it, so the balance is preserved exactly. (Nothing on-chain can catch that panic and
// continue — the same atomicity Accept and Collect already rely on.)
//
// THE APPROVAL IS FOR EXACTLY THE AMOUNT AND IN THE SAME TRANSACTION, as it was in
// Collect, so a revert takes the approval with it and this realm never leaves a standing
// allowance behind.
//
// IT FUNDS WHATEVER WEEK IS LIVE WHEN IT RUNS, which is a behaviour change from "whatever
// week was live when the duel was collected" and is recorded rather than hidden. A rake
// booked on Saturday and flushed on Monday enlarges Monday's week's prize. Nobody's claim
// moves — sponsorship buys no tickets in any week — and any player who wants their own
// flip to swell this week's pot can flush it themselves in the same block they collect.
// Panics if there is nothing booked.
// AND IT DELIVERS THE EARNED ENTRIES WITH THE MONEY, IN ONE CALL (finding 15). The
// batch is built from pendingEntries and handed to raffle.FundPotWithEntries, which
// funds the pot through the same FundPot and appends one ticket index per holder.
// One call rather than two because the money and the entrants must land in the SAME
// week: a delivery that could split across a week boundary would put the rake in one
// draw and the entrants in another, which is the defect finding 15 is about, only
// subtler.
//
// THE ENTRIES FOLLOW THE MONEY'S WEEK, WHICH IS THE WEEK LIVE WHEN THE FLUSH RUNS,
// AND THAT IS A DELIBERATE CHOICE RATHER THAN THE ONLY ONE. A rake booked on Saturday
// and flushed on Monday enlarges Monday's pot and earns its entries in Monday's draw —
// the money and the entrants stay together, which is the property that matters, and
// any player who wants their own flip in THIS week's draw can flush in the same block
// they collect (the suite's collectAs helper does exactly that, as it already did for
// the money). The alternative — booking the settlement's week number and crediting
// THAT week — was rejected twice over: it would let this realm write ticket weight
// into a week that is already committed or abandoned, which is the frozen-total rule
// the raffle refuses Buy for (findings 2 and 10), and a week that had moved on would
// leave the batch permanently undeliverable, which is a "money in, no way out" shape.
func FlushPot(cur realm) int64 {
	rejectAttachedCoin(cur, "FlushPot")
	amount := pendingPot
	if amount <= 0 {
		panic("duel: no rake is waiting to be delivered to the raffle")
	}

	// THE BATCH IS COLLECTED BEFORE ANY CROSS-REALM CALL, and that ordering is not a
	// style choice: NEVER NEST ONE avl.Iterate INSIDE ANOTHER. The raffle's FundPot
	// iterates its own trees (sweepDonations, and its invariant reads), and this
	// toolchain's VM crashes with a Go-level nil dereference — not a gno panic, so
	// nothing catches it — if a second traversal starts inside the first's callback.
	// So the walk finishes, and only then does the raffle run.
	holders := make([]address, 0, pendingEntries.Size())
	units := make([]int64, 0, pendingEntries.Size())
	pendingEntries.Iterate("", "", func(key string, value any) bool {
		holders = append(holders, address(key))
		units = append(units, value.(int64))
		return false
	})
	entryUnits := pendingEntryUnits

	// BOOKS FIRST, CALL SECOND, for the entries exactly as for the money: a
	// re-entrant call finds an empty batch, and a panic in the raffle aborts this
	// whole transaction and discards every one of these writes with it, so the batch
	// is preserved exactly for the next attempt.
	pendingPot = 0
	pendingSince = 0
	pendingEntries = avl.NewTree()
	pendingEntryUnits = 0

	wugnot.Approve(cross(cur), raffleRealmAddr, amount)
	if len(holders) > 0 {
		// The raffle re-derives the entry ceiling from `amount` itself and refuses a
		// batch that claims more than that money could have bought at its own ticket
		// price, so neither realm depends on the other's arithmetic being right.
		raffle.FundPotWithEntries(cross(cur), amount, holders, units)
	} else {
		// NO ELIGIBLE HOLDERS, WHICH IS A REAL STATE AND NOT A DEGENERATE ONE: both
		// parties of every settled duel played from realm code, or the rakes were too
		// small to buy one whole entry. The money must still go, and the raffle's
		// entry door refuses an empty batch on purpose, so this is the plain door.
		raffle.FundPot(cross(cur), amount)
	}

	chain.Emit("DuelFlushPot",
		"amount", strconv.FormatInt(amount, 10),
		"destination", string(raffleRealmAddr),
		"entryHolders", strconv.Itoa(len(holders)),
		"entryUnits", strconv.FormatInt(entryUnits, 10))
	checkInvariant()
	return amount
}

// SweepStuckRake is the LAST RESORT for a booked rake the raffle will not take, and it
// exists so that pendingPot is not a place money can enter and never leave. It transfers
// the whole booked amount to the raffle's address by PLAIN wugnot.Transfer and returns it.
// PERMISSIONLESS, and only once the batch's YOUNGEST CLAIM has stood for
// pendingGraceBlocks (pendingSince, finding D-4 — it is not, and cannot be, a measure of
// delivery having been attempted and refused).
//
// WHY IT CANNOT BE REFUSED, which is the only property that makes it a real exit: a plain
// GRC20 transfer runs no raffle code. FlushPot goes through raffle.FundPot and can
// therefore be refused by anything in the raffle — that is exactly the state this
// function is for. This one cannot be.
//
// AND IT DROPS THE EARNED ENTRIES WITH THE MONEY, WHICH IS THE OTHER HALF OF THE COST
// (finding 15). The money on this path becomes the raffle's ops pot, so there is no
// prize left for an entry to be an entry in, and an entry with no rake behind it is a
// thing this realm's own invariant refuses. So players who earned entries in a batch
// that reached this function get nothing for them. It takes three weeks of the raffle
// refusing EVERY caller, the drop is in this function's event, and any player could have
// prevented it at any moment by flushing — for between 10,378,157 gas (a two-holder batch,
// measured 2026-09-30) and 351,725,503 (a FULL 128-holder batch against a week grown to
// 100,096 ticket indices). Read maxPendingEntryHolders for where each figure comes from and
// why only the first is reproducible by running this package.
//
// THE FULL-BATCH END OF THAT RANGE IS THE ONE THAT APPLIES HERE, and citing only the
// cheap end was a real misstatement, corrected 2026-09-30. This paragraph is about a
// batch that has been accumulating for three weeks of refusals, i.e. the regime in which
// the batch is as large as maxPendingEntryHolders allows — so quoting a two-holder figure
// understated the mitigation's cost by more than thirty times in exactly the paragraph
// where it is dearest. (The figure said ~1.1M until 2026-09-29 and was stale by finding 15
// — see maxPendingEntryHolders and AUDIT-2026-09-28.md finding 19. The argument every
// version of it supports is unchanged: at 11.7% of a block it is still one affordable
// transaction available to anybody at any height. AUDIT-duel-2026-09-27.md addendum 2,
// findings D-4 and D-6.)
//
// WHERE IT LANDS, AND THE HONEST COST OF THAT. An unattributed arrival at the raffle is
// swept by its sweepDonations into its OPS pot, not into any week's prize — the raffle
// says why: crediting an unattributed arrival to a prize pot would break the identity
// that makes its refunds safe. So this money reaches the house rather than the players,
// and the 80/20 split is therefore NOT preserved on this path. That is stated plainly
// because it is the one place in this change where the split moves: it takes three weeks
// of the raffle refusing EVERY caller for it to happen, it emits its own event, and it
// is the alternative to the money never leaving at all.
//
// AND THE DESTINATION IS THE RAFFLE, NOT r/splash/ops, DELIBERATELY. gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops
// does not exist — the ops constant in this file is a package-derived address with no code
// at it — so routing a NEW stream there would be creating exactly the "money in, no way
// out" shape that six of this product's findings have had. The raffle's ops pot has an
// exit (WithdrawOps), and whether THAT exit's destination is reachable is a pre-existing
// question about r/splash/ops which is the owner's and is not made worse here.
//
// THE COST OF HAVING A WINDOW AT ALL, RECORDED RATHER THAN LEFT TO BE FOUND: after 21 days
// in which nobody bothered to call FlushPot — even with the raffle perfectly willing — any
// caller may move the booked rake to the raffle's ops pot instead of its prize pot. That is
// a value shift from the players to the house, it costs the caller gas and gains them
// nothing personally, and it is preventable by anyone at any time by simply flushing —
// for 10,378,157 gas at two holders and 351,725,503 at a FULL 128-holder batch, which is
// the end of the range that applies after three weeks of accumulation (see
// maxPendingEntryHolders for each figure's provenance; corrected from a bare "~8.6M" on
// 2026-09-30 and from "~1.1M" on
// 2026-09-29, findings D-4, D-6 and 19). It is accepted because the alternatives are worse: no window makes this a free
// diversion available on the first block, and no function at all leaves the balance with a
// single exit that another realm can hold shut for ever. AUDIT-2026-09-28.md finding 14.
//
// Panics if there is nothing booked, or if the window has not elapsed.
func SweepStuckRake(cur realm) int64 {
	rejectAttachedCoin(cur, "SweepStuckRake")
	amount := pendingPot
	if amount <= 0 {
		panic("duel: no rake is waiting to be delivered to the raffle")
	}
	if pendingSince <= 0 {
		// Unreachable: pendingSince is set in the same statement group that makes
		// pendingPot non-zero. Loud rather than treating an unset clock as elapsed.
		panic("duel: the pending rake has no booking height")
	}
	if runtime.ChainHeight()-pendingSince < pendingGraceBlocks {
		// THE MESSAGE NAMES WHAT IS ACTUALLY MEASURED, since 2026-09-30. It used to say
		// "the raffle has not been refusing this rake long enough", which asserted a fact
		// about the raffle that this realm has no way to know — see pendingSince, finding
		// D-4. What is measured is how long the youngest claim in the batch has stood.
		panic("duel: nothing in this batch is old enough for the last resort — call FlushPot instead")
	}

	// THE BOOKED ENTRIES DIE HERE, AND THAT IS THE SECOND HALF OF THIS FUNCTION'S
	// HONEST COST (finding 15). The money on this path lands in the raffle's OPS pot
	// rather than a prize pot, so there is no draw left for an entry to be an entry
	// IN — and an entry with no rake behind it is exactly what checkInvariant refuses,
	// because the raffle would price its ceiling off money that never arrived. So the
	// batch is discarded with the same event that reports the sweep.
	//
	// DISCARDED IN O(1) BY REPLACING THE TREE, never by walking and removing. This
	// function is the LAST RESORT for a booked rake nobody could deliver, so its cost
	// must not scale with the batch that could not be delivered — a sweep that could
	// itself run out of gas would leave no exit at all, which is the whole shape this
	// function exists to prevent.
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

// PendingPot is the players' side of the rake booked and not yet delivered to the raffle.
// O(1) read.
func PendingPot() int64 { return pendingPot }

// PendingSince is the height SweepStuckRake's window is counted from: the height at which
// the booked rake last went from zero to non-zero, or at which the batch's most recent NEW
// HOLDER was admitted, whichever is later. 0 when nothing is booked. O(1) read. Read
// pendingSince for why a new holder moves it (finding D-4).
func PendingSince() int64 { return pendingSince }

// PendingSweepOpensAt is the height at which SweepStuckRake's last resort becomes
// available, or 0 when nothing is booked. FlushPot is available at every height.
//
// IT MOVES LATER WHEN A NEW HOLDER JOINS THE BATCH (finding D-4), so a front end that
// wants to warn a player must re-read it rather than cache it — and a player who has just
// earned entries can see that their own claim opened the window they are measured against.
func PendingSweepOpensAt() int64 {
	if pendingSince <= 0 {
		return 0
	}
	return pendingSince + pendingGraceBlocks
}

// --- the raffle entries a duel earned (finding 15), readable ----------------

// PendingEntryUnits is the total raffle entry units booked and not yet delivered.
// O(1).
func PendingEntryUnits() int64 { return pendingEntryUnits }

// PendingEntryHolders is how many distinct addresses the undelivered batch holds.
// O(1); avl keeps its size. maxPendingEntryHolders is the bound (EntryHolderLimit).
func PendingEntryHolders() int64 { return int64(pendingEntries.Size()) }

// PendingEntriesOf is the raffle entry units booked for one address and not yet
// delivered: what a player has earned by playing and not yet had credited in the
// raffle. Zero once a flush has delivered them, at which point the units are the
// raffle's to report (raffle.TicketsOfWeek). O(log n).
func PendingEntriesOf(holder address) int64 {
	return entryUnitsOf(string(holder))
}

// EntryHolderLimit is maxPendingEntryHolders, exported so a front end can say why a
// player's entries were dropped rather than leaving them to guess. Read
// maxPendingEntryHolders for what happens at the bound and why it is a drop rather
// than a refusal.
func EntryHolderLimit() int64 { return maxPendingEntryHolders }

// EntryUnitsForRake is rakeEntryUnits, readable: how many raffle entry units a rake
// of `rake` ugnot earns, at raffle.EntryUnitPrice. A front end can quote a rung's
// entries with StakeOfRung, and anybody can check the rate that makes this feature
// safe without reading the source. Plain arithmetic, no state.
func EntryUnitsForRake(rake int64) int64 {
	if rake <= 0 {
		return 0
	}
	return rakeEntryUnits(rake)
}

// EntriesForRung is what one duel at `rung` earns its two players: the winner's
// share and the loser's, which sum to the rake-equivalent. Panics on an invalid rung
// index, exactly as Post would.
func EntriesForRung(rung int64) (winnerUnits, loserUnits int64) {
	return splitEntries(rakeEntryUnits(rakeOf(poolOf(stakeOf(rung)))))
}

// DuelEntryEligibility reports whether each party of a duel played from a direct
// user call and will therefore earn raffle entries when it is collected: poster
// first, taker second. Both false for a duel that does not exist.
//
// A SEPARATE READ RATHER THAN TWO MORE ELEMENTS OF DuelOf, deliberately: DuelOf
// keeps the six-value shape SPEC-03 §4 published, and an arity change there is
// mechanical churn in every caller (the raffle's own audit records doing it three
// times in one file). Read Duel.PosterIsUser for what these flags do and do not
// affect — they have no bearing on who wins or who is paid.
func DuelEntryEligibility(duelID int64) (bool, bool) {
	d := getDuel(duelID)
	if d == nil {
		return false, false
	}
	return d.PosterIsUser, d.TakerIsUser
}

// VoidStale refunds BOTH STAKES IN FULL, with no rake and no entries, for a duel that CAN
// NEVER BE SETTLED BY ANY CALLER — which since 2026-09-30 means exactly one thing: a LEGACY
// duel, accepted before the commit-reveal coin, carrying no commitment. PERMISSIONLESS.
//
// ITS PREMISE CHANGED COMPLETELY AND THE NAME IS KEPT ON PURPOSE. It was "the beacon-outage
// escape (SPEC-03 §6)": either party, after a 24-hour grace, when the bound round was STILL
// unpublished, because a stopped publisher would otherwise freeze every pending duel with
// both stakes locked on a contract that cannot be patched. THERE IS NO PUBLISHER AND NO
// ROUND ANY MORE, so that state does not exist: the poster can always reveal, and after
// revealWindowBlocks anybody can Forfeit. What survives is the one shape the old function
// was really for — a duel with no reachable settlement — and the only way to be in it now is
// to have been created before the change. The name is kept because it is the published exit
// for "this duel cannot settle, unwind it"; renaming it would churn every caller to say the
// same thing.
//
// WHY IT MUST EXIST AND MUST NOT BE Forfeit, WHICH IS REQUIREMENT 5. A legacy duel's poster
// has no secret and never had one: no commitment was recorded, so no preimage exists and
// Reveal cannot run for anybody. Routing that to Forfeit would pay the TAKER the poster's
// stake for a silence the poster could not have broken — and worse, it would make taking a
// legacy offer a free stake, which is why Accept refuses those outright. Both stakes go back.
//
// NO GRACE WINDOW, AND NO CALLER CHECK. Both were dropped, and both for the same reason:
// the record PROVES its own unsettleability from a field on itself (CommitHash == ""), so
// there is nothing to wait for and nothing for a caller check to protect. Waiting would only
// hold two refunds hostage to a clock; requiring a party would strand the pool if that party
// were a pre-D-1 realm with no code able to call anything. The destination is read from the
// record and is both parties, so a permissionless door cannot name a payee.
//
// NEVER ON A REVEALED DUEL, or it would be a way for a loser to cancel a loss — so that
// check comes first, as it always did. Unreachable together with the commitment check
// (nothing with an empty commitment can be revealed), and both are stated.
//
// NOTHING IS DEPLOYED, SO NO RECORD OF THIS SHAPE EXISTS TODAY. The lobby will be drained as
// a deployment step regardless. This function is here so that the code contains no trap:
// requirement 5 is that legacy records must not route to forfeit, and a comment saying "there
// are none" is not that.
func VoidStale(cur realm, duelID int64) {
	rejectAttachedCoin(cur, "VoidStale")
	d := getDuel(duelID)
	if d == nil {
		panic("duel: no such duel")
	}
	if d.Resolved {
		panic("duel: already revealed — a revealed duel cannot be voided")
	}
	if d.CommitHash != "" {
		panic("duel: this duel has a commitment and can be settled — Reveal it with the poster's secret, or Forfeit it to the taker once the reveal window has elapsed")
	}

	stake := stakeOf(d.Rung)
	pool := poolOf(stake)

	// Delete before paying, as everywhere else. releaseCommitment is called for symmetry
	// with the other exits and is a no-op here by construction (the commitment is empty);
	// it is called anyway so that no exit in this file is the one that forgets.
	duels.Remove(idKey(duelID))
	releaseCommitment(d.Poster, d.CommitHash)
	escrowed -= pool

	// Two transfers even when poster == taker: "both stakes return" stated as
	// written, and the sum is the pool either way.
	wugnot.Transfer(cross(cur), d.Poster, stake)
	wugnot.Transfer(cross(cur), d.Taker, stake)

	// NO RAKE AND NO ENTRIES ON THIS PATH, which is the OTHER arithmetic requirement 3
	// permits, and it is consistent: nothing is booked, so nothing is owed, and
	// checkInvariant's "entries with no rake behind them" case cannot arise. It is also the
	// right product answer — a duel that never had a coin to flip should cost its parties
	// nothing.
	chain.Emit("DuelVoid",
		"duel", strconv.FormatInt(duelID, 10),
		"poster", string(d.Poster),
		"taker", string(d.Taker),
		"stake", strconv.FormatInt(stake, 10),
		"reason", "no commitment: this duel predates the commit-reveal coin and could never be revealed")
	checkInvariant()
}

// --- reads -----------------------------------------------------------------

// OfferOf reports an offer: poster, rung, posted-at height. All zero for an
// offer that does not exist (including one that was cancelled or accepted —
// both delete it). Plain read. Keeps the three-value shape SPEC-03 §4
// published; the challenge fields are read through OfferChallenge.
func OfferOf(offerID int64) (address, int64, int64) {
	o := getOffer(offerID)
	if o == nil {
		return address(""), 0, 0
	}
	return o.Poster, o.Rung, o.PostedAt
}

// OfferChallenge reports the part of an offer that makes it a challenge: the
// opponent it is addressed to ("" if open to anyone) and its label ("" if
// none). Both zero for an offer that does not exist. Plain read; the label is
// returned RAW, as stored — it is only Render that must escape it.
func OfferChallenge(offerID int64) (address, string) {
	o := getOffer(offerID)
	if o == nil {
		return address(""), ""
	}
	return o.Opponent, o.Label
}

// OfferCommitment is the commitment an offer stands behind: H(commitTag ‖ secret) as 64
// lowercase hex characters. "" for an offer that does not exist AND for a LEGACY offer —
// which a caller can tell apart with OfferOf, since a non-existent offer has a zero poster.
// A taker should read this before accepting: an offer with no commitment cannot be accepted
// at all (Accept refuses it).
//
// A SEPARATE READ RATHER THAN A SEVENTH VALUE ON OfferOf, for the reason OfferChallenge
// gives: OfferOf keeps the three-value shape SPEC-03 §4 published.
func OfferCommitment(offerID int64) string {
	o := getOffer(offerID)
	if o == nil {
		return ""
	}
	return o.CommitHash
}

// DuelLabel is the label a duel was accepted under, "" if none or if the duel
// does not exist. Raw, as OfferChallenge. DuelOf keeps its six-value shape.
func DuelLabel(duelID int64) string {
	d := getDuel(duelID)
	if d == nil {
		return ""
	}
	return d.Label
}

// DuelCommitment is everything the coin is made of: the poster's commitment, the taker's
// nonce, and the secret once it has been revealed ("" before that). All three empty for a
// duel that does not exist, and the commitment empty for a LEGACY duel.
//
// IT IS WHAT MAKES A SETTLED DUEL CHECKABLE BY ANYBODY. With these three values and the
// duel's ID, a caller recomputes H(commitTag ‖ secret) against the commitment and
// H(outcomeTag ‖ secret ‖ nonce ‖ duelID) against the winner DuelOf reports, off chain, with
// no trust in this realm at all. The beacon version could not offer that: its randomness
// lived in another realm and was addressed by a round number.
func DuelCommitment(duelID int64) (commitHash, nonce, secret string) {
	d := getDuel(duelID)
	if d == nil {
		return "", "", ""
	}
	return d.CommitHash, d.Nonce, d.Secret
}

// DuelOf reports a duel: poster, taker, rung, REVEAL DEADLINE, resolved, winner. All
// zero for a duel that does not exist — which, after Collect, Forfeit or VoidStale, is
// how a caller can see the record really was deleted (SPEC-03 §8 test 19).
// Plain read.
//
// THE FOURTH VALUE IS NO LONGER A BEACON ROUND, AND IT IS REPLACED RATHER THAN REMOVED.
// It used to be `Round` — the drand round the duel settled against — and there is no round
// any more. The slot now holds THE BLOCK HEIGHT AT WHICH THE REVEAL WINDOW CLOSES, i.e.
// AcceptedAt + revealWindowBlocks: the height from which anybody may Forfeit this duel to
// its taker. That keeps the six-value shape SPEC-03 §4 published — an arity change here is
// mechanical churn in every caller, which the raffle's audit records doing three times in
// one file — and it keeps the slot's MEANING, which was always "the clock this duel settles
// against". It is a DERIVED value, not a stored one; a duel carries AcceptedAt and the
// window is a constant.
//
// A CALLER THAT WANTS THE OLD FIELD WILL NOT FIND IT AND MUST NOT GUESS. Reading this as a
// round number gives a nonsense round in the tens of thousands, which is why the change is
// stated here, in the event log (DuelAccept's "revealBy" replaced "round"), in Render's
// column heading and in the addendum — a silently reinterpreted return value is the worst
// possible way to carry a change like this.
func DuelOf(duelID int64) (address, address, int64, int64, bool, address) {
	d := getDuel(duelID)
	if d == nil {
		return address(""), address(""), 0, 0, false, address("")
	}
	return d.Poster, d.Taker, d.Rung, d.AcceptedAt + revealWindowBlocks, d.Resolved, d.Winner
}

// RevealWindowBlocks is revealWindowBlocks, exported so a front end can say how long a
// poster has to open their commitment before the duel can be forfeited to the taker, without
// hardcoding the number or reading it out of Render.
func RevealWindowBlocks() int64 { return revealWindowBlocks }

// ForfeitOpensAt is the height from which anybody may Forfeit a duel to its taker: the same
// value DuelOf returns in its fourth slot. 0 for a duel that does not exist, and 0 for a
// LEGACY duel — which is never forfeitable at all and goes to VoidStale instead, so a front
// end that offers a forfeit button must treat 0 as "not this one".
func ForfeitOpensAt(duelID int64) int64 {
	d := getDuel(duelID)
	if d == nil || d.CommitHash == "" {
		return 0
	}
	return d.AcceptedAt + revealWindowBlocks
}

// --- listers ---------------------------------------------------------------
//
// OfferOf and DuelOf answer "what is record N", and until these existed
// nothing answered "which N exist": a caller had to parse Render's markdown to
// find out what was on the board, which made a human-readable display into a
// load-bearing API. These four functions are the contract for enumeration.
// Plain reads, all of them: no state, no writes, nothing touched in
// settlement or escrow.
//
// THE IDS COME FROM THE TREES, NOT FROM A COUNTER. Post, Cancel, Accept,
// Collect and VoidStale each add to or delete from `offers` or `duels`, so a
// walk of the tree IS the set of live records, by construction; a separate
// list or count could only drift from it. And because idKey is fixed-width,
// avl's in-order walk is ascending ID order for free (SPEC-v1.md §7.7: the
// same order Render prints, on every node).
//
// BOUNDED, because the trees are not. Render lists everything, which is right
// for a page a human reads, but a query that returned every ID forever would
// grow in gas and payload with the lobby. So a call is a window: `offset`
// records in, at most `limit` IDs out, and `limit` is clamped to PageLimit.
// OfferCount and DuelCount are the totals a caller pages against. IDs only —
// the per-record readers above already exist, and a batched row reader would
// mean inventing a second serialisation for the same page to parse.

// PageLimit is the most IDs one OfferIDs or DuelIDs call returns. A larger
// limit is clamped to it, not refused.
const PageLimit int64 = 100

// OfferCount is the number of offers standing in the lobby. O(1): avl keeps
// its size.
func OfferCount() int64 {
	return int64(offers.Size())
}

// DuelCount is the number of duels in flight: accepted and not yet collected
// or voided, resolved or not. O(1).
func DuelCount() int64 {
	return int64(duels.Size())
}

// OfferIDs is a window over the standing offers' IDs in ascending order: the
// window skips `offset` offers and holds at most min(limit, PageLimit). Empty
// past the end. Negative arguments are a caller error and panic.
func OfferIDs(offset, limit int64) []int64 {
	return idsOf(offers, offset, limit)
}

// DuelIDs is OfferIDs for the duels in flight.
func DuelIDs(offset, limit int64) []int64 {
	return idsOf(duels, offset, limit)
}

// idsOf is the one window walk both listers share. IterateByOffset is avl's
// own offset-and-count traversal, O(log n + limit); it is not a full scan
// followed by a slice.
func idsOf(tree *avl.Tree, offset, limit int64) []int64 {
	if offset < 0 {
		panic("duel: negative offset")
	}
	if limit < 0 {
		panic("duel: negative limit")
	}
	if limit > PageLimit {
		limit = PageLimit
	}
	remaining := int64(tree.Size()) - offset
	if remaining < limit {
		limit = remaining
	}
	if limit <= 0 {
		return []int64{}
	}
	ids := make([]int64, 0, limit)
	tree.IterateByOffset(int(offset), int(limit), func(key string, _ any) bool {
		ids = append(ids, idOfKey(key))
		return false
	})
	return ids
}

// idOfKey inverts idKey. A key that does not parse cannot have come from
// idKey, so it is a corrupt tree and not a case to paper over.
func idOfKey(key string) int64 {
	id, err := strconv.ParseInt(key, 10, 64)
	if err != nil {
		panic("duel: malformed id key " + key)
	}
	return id
}

// StakeOfRung is the ladder, readable: the stake a rung index costs. Panics
// on an invalid index, exactly as Post would.
func StakeOfRung(rung int64) int64 {
	return stakeOf(rung)
}

// RungCount is the number of rungs on the ladder.
func RungCount() int64 {
	return int64(len(rungs))
}

// Escrowed is the wugnot this realm holds for open offers and uncollected
// duels. O(1); maintained incrementally.
func Escrowed() int64 {
	return escrowed
}

// AuditFailure re-derives escrowed by iterating every record and returns the
// empty string when the books balance, otherwise why not. O(n) and READ-ONLY;
// never called from a state-changing path — checkInvariant is the O(1) guard
// for those. Exists so anyone can verify off-chain, and so the tests can.
func AuditFailure() string {
	i64 := func(v int64) string { return strconv.FormatInt(v, 10) }

	sum := int64(0)
	failure := ""
	// heldCommitments counts the records that SHOULD be holding a pair in liveCommitments,
	// so the set can be re-derived from the records rather than trusted. Legacy records hold
	// none and are not counted.
	heldCommitments := 0
	offers.Iterate("", "", func(key string, value any) bool {
		o := value.(*Offer)
		if o.Rung < 0 || o.Rung >= int64(len(rungs)) {
			failure = "offer " + key + " has an invalid rung"
			return true
		}
		if len(o.Label) > maxLabelLen {
			failure = "offer " + key + " has a label over the bound"
			return true
		}
		if o.CommitHash != "" {
			if !isLowerHex32(o.CommitHash) {
				failure = "offer " + key + " has a malformed commitment"
				return true
			}
			if !liveCommitments.Has(commitKey(o.Poster, o.CommitHash)) {
				failure = "offer " + key + " holds a commitment that is not in the live set"
				return true
			}
			heldCommitments++
		}
		sum += rungs[o.Rung]
		return false
	})
	if failure != "" {
		return failure
	}
	duels.Iterate("", "", func(key string, value any) bool {
		d := value.(*Duel)
		if d.Rung < 0 || d.Rung >= int64(len(rungs)) {
			failure = "duel " + key + " has an invalid rung"
			return true
		}
		if d.Resolved && d.Winner == "" {
			failure = "duel " + key + " is resolved but names no winner"
			return true
		}
		if !d.Resolved && d.Winner != "" {
			failure = "duel " + key + " is unresolved but already names a winner"
			return true
		}
		if d.Resolved && d.Winner != d.Poster && d.Winner != d.Taker {
			failure = "duel " + key + " names a winner who is not a party to it"
			return true
		}
		if len(d.Label) > maxLabelLen {
			failure = "duel " + key + " has a label over the bound"
			return true
		}
		if d.CommitHash != "" {
			if !isLowerHex32(d.CommitHash) {
				failure = "duel " + key + " has a malformed commitment"
				return true
			}
			if !isLowerHex32(d.Nonce) {
				failure = "duel " + key + " has a malformed nonce"
				return true
			}
			if !liveCommitments.Has(commitKey(d.Poster, d.CommitHash)) {
				failure = "duel " + key + " holds a commitment that is not in the live set"
				return true
			}
			heldCommitments++
		}
		// THE SETTLEMENT ITSELF IS RE-DERIVED, WHICH THE BEACON VERSION COULD NOT DO. A
		// resolved duel carries the secret that opened it, so the whole coin can be
		// recomputed from the record alone: the secret must open the commitment, and the
		// winner must be the one the outcome hash names. Nothing here trusts the stored
		// Winner — that is the point. It is the one invariant in this file that checks the
		// realm's PURPOSE rather than its books, and it is only possible because Reveal
		// stores the secret (Duel.Secret).
		if d.Resolved {
			if d.CommitHash == "" {
				failure = "duel " + key + " is resolved but carries no commitment, so its outcome cannot be re-derived"
				return true
			}
			if !isLowerHex32(d.Secret) {
				failure = "duel " + key + " is resolved but its revealed secret is malformed"
				return true
			}
			if commitmentOf(d.Secret) != d.CommitHash {
				failure = "duel " + key + " is resolved with a secret that does not open its commitment"
				return true
			}
			// EXCEPT FOR A SELF-MATCHED DUEL, WHERE THE CHECK IS NOT EXPRESSIBLE AND SAYING
			// SO IS BETTER THAN A FALSE FAILURE. When poster == taker (SPEC-03 §7.3) the two
			// parties are one address, so `d.Winner == d.Poster` is true whichever side the
			// coin came down on and no comparison against the parity can distinguish them.
			// The winner-is-a-party check above already covers everything that could go
			// wrong with such a record, and the money is identical either way.
			if d.Poster != d.Taker {
				wantPoster := posterWins(d.Secret, d.Nonce, idOfKey(key))
				if wantPoster != (d.Winner == d.Poster) {
					failure = "duel " + key + " names a winner the outcome hash does not"
					return true
				}
			}
		} else if d.Secret != "" {
			failure = "duel " + key + " is unrevealed but already holds a secret"
			return true
		}
		sum += 2 * rungs[d.Rung]
		return false
	})
	if failure != "" {
		return failure
	}
	// THE LIVE COMMITMENT SET IS RE-DERIVED, NOT TRUSTED, exactly as `escrowed` and
	// pendingEntryUnits are. Every live record's pair was checked present above, so equal
	// sizes means the set is EXACTLY the records' pairs: no leak (which would silently refuse
	// an honest poster's next Post) and no premature release (which would re-admit the reuse
	// the set exists to refuse).
	if liveCommitments.Size() != heldCommitments {
		return "the live commitment set holds " + strconv.Itoa(liveCommitments.Size()) +
			" pairs but the records account for " + strconv.Itoa(heldCommitments)
	}
	if sum != escrowed {
		return "records hold " + i64(sum) + " in stakes but escrowed is " + i64(escrowed)
	}
	if pendingPot < 0 {
		return "the pending rake is negative: " + i64(pendingPot)
	}
	// THE PENDING RAKE IS PART OF WHAT THIS REALM OWES, so the balance test includes it.
	// A booked rake the realm does not hold would be a promise to the raffle funded out of
	// players' stakes, and it must not be able to hide behind the escrow figure.
	if pendingPot > 0 && pendingSince <= 0 {
		return "a rake of " + i64(pendingPot) + " is booked with no booking height"
	}
	if pendingPot == 0 && pendingSince != 0 {
		return "no rake is booked but the booking height is " + i64(pendingSince)
	}
	// THE BOOKED ENTRIES, RE-DERIVED BY ITERATION exactly as `escrowed` is, because
	// pendingEntryUnits is maintained incrementally and a counter that nothing
	// re-derives is a counter that can drift. The rate is checked against the booked
	// rake for the reason checkInvariant states: the rate IS finding 15's security
	// property, and a batch this realm could not pay for is a batch the raffle would
	// refuse — a stuck flush rather than a loud failure here.
	entrySum := int64(0)
	entryFailure := ""
	pendingEntries.Iterate("", "", func(key string, value any) bool {
		u := value.(int64)
		if u <= 0 {
			entryFailure = "pending entries for " + key + " are not positive: " + i64(u)
			return true
		}
		if !address(key).IsValid() {
			entryFailure = "pending entries are booked for " + key + ", which is not a valid address"
			return true
		}
		entrySum += u
		return false
	})
	if entryFailure != "" {
		return entryFailure
	}
	if entrySum != pendingEntryUnits {
		return "the pending entry tree holds " + i64(entrySum) +
			" units but pendingEntryUnits is " + i64(pendingEntryUnits)
	}
	if pendingEntries.Size() > maxPendingEntryHolders {
		return "the pending entry batch holds " + strconv.Itoa(pendingEntries.Size()) +
			" holders, over the bound of " + strconv.Itoa(maxPendingEntryHolders)
	}
	if pendingEntryUnits > 0 && pendingPot <= 0 {
		return "raffle entries are booked (" + i64(pendingEntryUnits) + " units) with no rake behind them"
	}
	if max := maxEntryUnitsFor(pendingPot); pendingEntryUnits > max {
		return "the booked raffle entries (" + i64(pendingEntryUnits) +
			" units) exceed what the booked rake of " + i64(pendingPot) +
			" would buy at the ticket price (" + i64(max) + " units)"
	}
	bal := wugnot.BalanceOf(selfAddr())
	if bal < escrowed+pendingPot {
		return "the realm holds " + i64(bal) + " but owes " + i64(escrowed) +
			" in escrow plus " + i64(pendingPot) + " in booked rake"
	}
	return ""
}

// AuditInvariant is AuditFailure as a bool.
func AuditInvariant() bool {
	return AuditFailure() == ""
}

// --- render ----------------------------------------------------------------

// renderCell is the ONLY way user-originated text reaches Render's output, and
// everything below that prints an address or a label goes through it. The rule
// (SPEC-v1.md §7.6) is that any user-originated text reaching Render is
// sanitised, not that it is assumed clean. sanitize.InlineText escapes
// markdown and HTML metacharacters and folds any line break to a space; the
// pipe is escaped on top of that because every such value here is printed
// inside a markdown table cell, where a raw pipe would break the row. (This is
// what sanitize.TableCell does too; it is spelled out here so the escaping is
// visible at the one place it happens.) Applied exactly once per value: the
// escapers are not idempotent.
func renderCell(s string) string {
	return strings.ReplaceAll(sanitize.InlineText(s), "|", "\\|")
}

// renderAddr renders an address. Every address this realm stores came from
// cur.Previous().Address() or passed IsValid and is bech32 — but it is
// sanitised anyway, for the reason renderCell gives.
func renderAddr(a address) string {
	return renderCell(string(a))
}

// renderLabel renders a label, which IS arbitrary user text (within checkLabel's
// bounds) and is the one place in this realm where the sanitiser is not a
// formality. "-" for no label, so the column is never visually empty.
func renderLabel(label string) string {
	if label == "" {
		return "-"
	}
	return renderCell(label)
}

// renderOpponent renders an offer's opponent column: "anyone" for an open
// offer, the address otherwise.
func renderOpponent(a address) string {
	if a == "" {
		return "anyone"
	}
	return renderAddr(a)
}

// Render is the realm's human-readable view: the ladder, the open lobby and
// the duels in flight. It ITERATES THE avl.Trees in key order, which is ID
// order because idKey is fixed-width, so the output is byte-identical across
// calls and across nodes (SPEC-v1.md §7.7). Only the empty path is meaningful;
// any other path is answered without echoing it.
func Render(path string) string {
	i64 := strconv.FormatInt

	out := "# Splash Play: the Duel\n\n"
	if path != "" {
		return out + "Unknown path.\n"
	}

	out += "Two players, a matched stake in GNOT, 50/50, winner takes both less a 3% rake.\n\n"
	out += "The coin is a two-party commit-reveal: the poster posts H(tag|secret) with their stake, " +
		"the taker sends a 32-byte nonce with theirs, and the winner is the parity of " +
		"H(tag|secret|nonce|duelID). The poster cannot grind it (the nonce does not exist yet) " +
		"and the taker cannot steer it (they choose the nonce without the secret). " +
		"THE SECRET MUST COME FROM A CSPRNG AND MUST BE FRESH FOR EVERY OFFER: the commitment is a " +
		"free offline oracle, so a guessable secret is robbed silently by a reveal nobody can tell " +
		"from an honest one.\n\n"
	out += "- stakes are wrapped GNOT (r/gnoland/wugnot); amounts below are in ugnot, 1 GNOT = 1000000 ugnot\n"
	out += "- reveal window: " + i64(revealWindowBlocks, 10) +
		" blocks (~24h) after Accept; after that anybody may Forfeit the duel to the taker\n"
	out += "- rake: " + i64(rakeBps, 10) + " bps of the pool, split 60% into this week's raffle pot / 40% ops\n"
	out += "- escrowed: " + i64(escrowed, 10) + " ugnot\n"
	out += "- raffle rake booked and awaiting delivery: " + i64(pendingPot, 10) +
		" ugnot (anyone may call FlushPot)\n"
	out += "- raffle entries earned and awaiting delivery: " + i64(pendingEntryUnits, 10) +
		" units for " + strconv.Itoa(pendingEntries.Size()) + " players (limit " +
		i64(maxPendingEntryHolders, 10) + ")\n"
	out += "- playing earns entries in this week's raffle draw: at least one each, the rest weighted two thirds to the loser, priced at " +
		i64(raffle.EntryUnitPrice, 10) + " ugnot of rake per entry\n"
	out += "- open offers: " + strconv.Itoa(offers.Size()) + "\n"
	out += "- duels in flight: " + strconv.Itoa(duels.Size()) + "\n"

	// THE LADDER CARRIES THE ENTRY COLUMNS, because "what do I get for this rung" is
	// now two questions and a player should not have to do the arithmetic. Appended
	// columns, so a row is still findable by its leading rung and stake.
	out += "\n## Ladder\n\n| rung | stake (ugnot) | stake (GNOT) | raffle entries: winner | loser |\n|---|---|---|---|---|\n"
	for i := 0; i < len(rungs); i++ {
		w, l := splitEntries(rakeEntryUnits(rakeOf(poolOf(rungs[i]))))
		out += "| " + strconv.Itoa(i) + " | " + i64(rungs[i], 10) + " | " + i64(rungs[i]/1_000_000, 10) +
			" | " + i64(w, 10) + " | " + i64(l, 10) + " |\n"
	}

	// THE UNDELIVERED ENTRY BATCH, and it sits between the ladder and the lobby
	// deliberately: the lobby and duel tables are parsed by marker in the suite and
	// nothing may come between them. Iterated in avl key order, which is address
	// order, so the output is byte-identical across calls and across nodes.
	if pendingEntries.Size() > 0 {
		out += "\n## Raffle entries earned and awaiting delivery\n\n"
		out += "Anyone may deliver these to this week's draw with FlushPot.\n\n"
		out += "| player | entry units |\n|---|---|\n"
		pendingEntries.Iterate("", "", func(key string, value any) bool {
			out += "| " + renderAddr(address(key)) + " | " + i64(value.(int64), 10) + " |\n"
			return false
		})
	}

	// Column order in both tables keeps "| id | poster |" (and "| taker |")
	// leading, so a row is still findable by its parties; the challenge
	// columns are appended after them.
	out += "\n## Lobby\n\n"
	if offers.Size() == 0 {
		out += "No open offers.\n"
	} else {
		out += "| offer | poster | rung | stake | posted at | opponent | label |\n|---|---|---|---|---|---|---|\n"
		offers.Iterate("", "", func(key string, value any) bool {
			o := value.(*Offer)
			out += "| " + strings.TrimLeft(key, "0") +
				" | " + renderAddr(o.Poster) +
				" | " + i64(o.Rung, 10) +
				" | " + i64(rungs[o.Rung], 10) +
				" | " + i64(o.PostedAt, 10) +
				" | " + renderOpponent(o.Opponent) +
				" | " + renderLabel(o.Label) + " |\n"
			return false
		})
	}

	out += "\n## Duels\n\n"
	if duels.Size() == 0 {
		out += "No duels in flight.\n"
	} else {
		// THE "round" COLUMN IS REPLACED BY "reveal by", NOT RENAMED IN PLACE WITH THE SAME
		// NUMBER UNDERNEATH: there is no round, and the height printed here is the block from
		// which anybody may Forfeit. Same reasoning as DuelOf's fourth value.
		out += "| duel | poster | taker | stake | reveal by | status | winner | label |\n|---|---|---|---|---|---|---|---|\n"
		duels.Iterate("", "", func(key string, value any) bool {
			d := value.(*Duel)
			status := "awaiting the poster's reveal"
			winner := "-"
			switch {
			case d.Resolved:
				status = "revealed, awaiting collect"
				winner = renderAddr(d.Winner)
			case d.CommitHash == "":
				// LEGACY: unrevealable and unforfeitable, and the page must say which exit it
				// has rather than showing a deadline that means nothing.
				status = "no commitment (legacy): void it"
			case runtime.ChainHeight()-d.AcceptedAt >= revealWindowBlocks:
				status = "reveal window elapsed: anybody may forfeit it to the taker"
			}
			revealBy := "-"
			if d.CommitHash != "" {
				revealBy = i64(d.AcceptedAt+revealWindowBlocks, 10)
			}
			out += "| " + strings.TrimLeft(key, "0") +
				" | " + renderAddr(d.Poster) +
				" | " + renderAddr(d.Taker) +
				" | " + i64(rungs[d.Rung], 10) +
				" | " + revealBy +
				" | " + status +
				" | " + winner +
				" | " + renderLabel(d.Label) + " |\n"
			return false
		})
	}
	return out
}
