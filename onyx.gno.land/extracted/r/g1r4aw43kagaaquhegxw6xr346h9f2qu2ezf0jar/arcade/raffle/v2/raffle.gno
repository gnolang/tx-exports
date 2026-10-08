// Package raffle is the SPLASH weekly ticket raffle.
//
// WHAT THIS REPLACES, AND WHY IT IS A SEPARATE REALM.
//
// r/splash/game is a permanent-deposit yield product: you deposit GNOT, you
// can never withdraw, your position size IS your ticket count, and winning the
// weekly draw ADDS the pot to your locked position rather than paying your
// wallet. Its raffle had to live inside that realm because the draw mutated
// three pieces of that realm's state atomically (see the long comment at the
// top of r/splash/game/raffle.gno).
//
// This realm sells TICKETS, not positions. A ticket costs TicketPrice and buys
// exactly unitsPerTicket units of one week's draw — one ticket was one unit until
// 2026-09-29, and EntryUnitPrice says why the two numbers had to come apart; the
// pot pays out to the winner's WALLET;
// and nothing a buyer paid is held beyond the week they bought into. Because
// there is no position, no yield index and no permanent deposit, the draw needs
// nothing from r/splash/game and this realm holds no authority over it, over
// r/splash/beacon, or over r/gnoland/wugnot.
//
// THERE IS EXACTLY ONE PACKAGE-PATH GUARD IN THIS FILE, AND UNTIL 2026-09-29
// THERE WERE NONE. The sentence that used to be here — "there is no
// package-path guard anywhere in this file and nothing for one to protect" —
// is no longer true and is not quietly deleted. FundPotWithEntries admits
// r/splash/arcade/duel and nobody else, because duel play now EARNS entries in
// the live week's draw (AUDIT-2026-09-28.md finding 15). Read that function in
// full before touching it: it is the only privileged door in this product, it
// is the shape r/splash/game declined to add five times, and what keeps it
// small is that everything it can do is bounded by the money delivered through
// it in the same call. Every OTHER entry point here is still permissionless and
// can still only do the one thing the week's state machine allows next.
//
// THE MECHANICS ARE r/splash/game/raffle.gno's, DELIBERATELY UNCHANGED: the
// week number derived from the global clock, the Commit/Capture/Resolve
// three-phase cycle, and above all the FROZEN-TOTAL property. Read Commit
// below before changing anything: freezing the ticket total is what stops a
// buyer from waiting for the randomness to publish and then buying exactly the
// winning ticket index, and that attack was live in an earlier version of the
// old realm.
//
// ONE MECHANIC IS NOT THE OLD REALM'S ANY MORE: WHICH ROUND DECIDES A WEEK. The
// old realm — and this one until 2026-09-28 — bound Round = beacon.Latest() + 1
// inside Commit, which handed the round choice to whoever called Commit, AFTER the
// week's ticket set was already frozen and public. The publisher's key can sign any
// round at will and beacon.Publish accepts rounds in any order, so that was a
// deterministic, risk-free win for the key holder. The round is now PINNED WHEN THE
// WEEK'S RECORD IS CREATED — before the first ticket of that week exists — and is
// never written again. See getOrCreateDraw and pinOffsetRounds.
//
// THAT DOES NOT MAKE THE DRAW TRUSTLESS, and nothing in this file should be read
// as claiming it does. The beacon's key holder still knows every round's
// randomness in advance, so they can still rig a week by choosing the MODULUS —
// buying last, just before the week closes, to move FrozenTotal and the unit
// ranges. Pinning removes the round-selection freedom, which was the cheap,
// deniable and exact version of the attack; the residual one leaves an on-chain
// trace as a suspicious late purchase. THE ARCHITECTURAL PROBLEM REMAINS OPEN and
// is the owner's decision: closing it needs an externally-controlled beacon or a
// VRF. See AUDIT-2026-09-28.md findings 4 and 10.
//
// THE ARCADE FEEDS THIS POT, AND SINCE 2026-09-29 IT ALSO FILLS THE DRAW.
// r/splash/arcade/duel sends its rake here, so every coin flip makes this week's
// prize bigger — that is what makes the duel and the raffle one product instead of
// two contracts. The rake itself still buys no tickets and no winning chance: it is
// tracked separately as Draw.Sponsored, because the refund safety property is the
// identity Pot == sum(spends) + Sponsored and house money belongs to no buyer. Read
// Draw.Sponsored and FundPot together before changing either.
//
// WHAT CHANGED IS THAT THE PLAYERS WHO PAID THAT RAKE NOW ARRIVE WITH IT. Until
// 2026-09-29 the money came and the entrants did not, so a week of busy coin
// flipping and no ticket sales could be won outright by one cheap ticket bought
// in its final block — the whole pot, to somebody who had contributed none of it.
// FundPotWithEntries is the fix: the duel delivers the same rake and, in the same
// call, the two players of each settled duel are credited entries worth EXACTLY
// what that rake would have bought at EntryUnitPrice. The money and the entrants now
// arrive together. Earned entries carry ticket weight and NO spendOf record, which
// is consistent with every identity in this file and is spelled out at
// FundPotWithEntries. AUDIT-2026-09-28.md finding 15.
//
// WHAT IS NEW, and could not have existed in the old design: Refund. There,
// the pot was accrued protocol fees and nobody's stake was ever at risk, so an
// unresolvable draw could simply wait forever. Here the pot is buyers' own money, so a
// week nobody settles must have a way back out. SINCE THE DRAND MIGRATION THAT IS A
// LIVENESS EXIT AND NOT A LOSS EXIT — no round is ever unobtainable, so what Refund
// guards against is nobody bothering to relay one. See Refund.
package raffle

import (
	"math/bits"
	"strconv"
	"strings"
	"unicode/utf8"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/fenwick"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/beacon/v2"
)

// --- the economics -------------------------------------------------------

const (
	// TicketPrice is the cost of one ticket in ugnot: 10 GNOT. Money here is
	// wrapped GNOT (r/gnoland/wugnot), a GRC20 with 6 decimals, so 1 GNOT is
	// 1_000_000 ugnot and every amount in this file is an int64 count of ugnot.
	//
	// EXPORTED because a front end must be able to quote the price without
	// hardcoding it, and because a buyer's cost is tickets * this and nothing
	// else — there is no dynamic pricing, no discount tier and no bonding curve.
	//
	// IT IS NO LONGER THE GRANULARITY OF THE DRAW, AND THAT SEPARATION IS THE WHOLE
	// POINT OF EntryUnitPrice BELOW. Until 2026-09-29 this one constant was both "what
	// a ticket costs" and "what one unit of winning weight is worth", and raising it
	// from 0.1 to 10 GNOT would have silently deleted the earned-entry feature for
	// three of the duel's four rungs. AUDIT-2026-09-28.md finding 22.
	TicketPrice int64 = 10_000_000

	// EntryUnitPrice is the value of ONE UNIT OF WEIGHT IN THE DRAW: 0.25 GNOT.
	//
	// IT IS THE SECOND, INDEPENDENT PRODUCT PARAMETER THAT USED TO SHARE TicketPrice'S
	// CONSTANT, and the numbers that forced them apart are worth keeping here because
	// they are what a future edit will recreate:
	//
	//	The duel's players-side rake per rung is 0.36 / 1.80 / 7.20 / 36.00 GNOT
	//	(after the 60/40 split), off rakes of 0.6 / 3 / 12 / 60 GNOT. An earned entry
	//	is priced at what the RAKE would have bought (r/splash/arcade/duel's
	//	rakeEntryUnits — that equality is the security property of the whole feature).
	//	Price an entry at a 10 GNOT TICKET and rungs 0, 1 and 2 — 0.6, 3 and 12 GNOT
	//	of rake — earn 0, 0 and 1 entries. THREE OF THE FOUR RUNGS EARN NOTHING, and
	//	finding 15's fix, which exists so that the people whose rake built the pot are
	//	in the draw for it, dies for everyone but whales.
	//
	// So the two numbers are separated: a TICKET is a price, an ENTRY UNIT is a
	// granularity, and one ticket is simply worth unitsPerTicket of them. Everything
	// downstream of appendTickets — the fenwick index, ownerOfUnit, randomnessMod,
	// FrozenTotal — has always worked in arbitrary units of weight and needed no
	// change at all; what had to change is every place that turned money into weight
	// or weight into money.
	//
	// EXPORTED for the same reason TicketPrice is: r/splash/arcade/duel prices its
	// earned entries against it, and a front end must be able to quote "one ticket is
	// 40 entries" without hardcoding either number.
	EntryUnitPrice int64 = 250_000

	// unitsPerTicket is how many units of draw weight one ticket buys: 40.
	//
	// DERIVED, NEVER WRITTEN OUT, and the build guard below refuses any pair for which
	// it is not exact — see there for why dust in the weight domain would be
	// unrecoverable rather than merely untidy.
	unitsPerTicket = TicketPrice / EntryUnitPrice

	// HouseCutBps is the share of every ticket sale that is the house's fee rather
	// than prize money: 500 bps, 5%.
	//
	// IT IS ESCROWED PER WEEK AND EARNED ONLY BY A DRAW, since 2026-09-29. Buy no
	// longer credits opsPot; it credits Draw.Cut, and that money reaches opsPot only
	// on a successful Resolve. A week that never draws refunds it as part of each
	// buyer's GROSS ticket price. AUDIT-2026-09-28.md finding 25.
	//
	// EXPORTED ON 2026-09-30, AND FOR A REASON THAT IS NOT A FRONT END'S CONVENIENCE.
	// r/splash/arcade/duel's earned entries are safe only while flipping is never CHEAPER
	// than buying, and the two prices meet in the amount of PRIZE MONEY each route puts
	// behind one unit of draw weight: a bought unit delivers
	// EntryUnitPrice x (bpsDenom - HouseCutBps) / bpsDenom, a flipped one
	// EntryUnitPrice x rakePotShareBps / bpsDenom. So THIS CONSTANT IS ONE OF THE TWO
	// TERMS OF THE DUEL'S SECURITY ARGUMENT, and the duel now carries a build guard that
	// refuses a rake split which would invert it (see its guard beside rakePotShareBps,
	// and AUDIT-duel-2026-09-27.md addendum 2, finding D-2). A guard cannot be written
	// against a constant it cannot name.
	//
	// IT IS A COMPILE-TIME CONST AND NOT A FUNCTION, DELIBERATELY, exactly as TicketPrice
	// and EntryUnitPrice are: the duel reads it in an array length and in comments, so it
	// must add NO runtime dependency on this realm to any path over there — which is the
	// property finding 14 rests on (see the duel's checkInvariant).
	HouseCutBps int64 = 500
	bpsDenom    int64 = 10_000

	// cutPerTicket is the house fee on ONE ticket: 500_000 ugnot.
	//
	// IT EXISTS FOR THE BUILD GUARD, NOT FOR THE ARITHMETIC. Buy still computes its
	// cut with mulDiv over the whole cost, exactly as it always did. What this
	// constant and its guard establish is that the cut is EXACTLY PROPORTIONAL to the
	// number of tickets — no flooring anywhere — which is precisely the property
	// Refund's per-buyer split needs in order to be exact. Read the guard.
	cutPerTicket = TicketPrice * HouseCutBps / bpsDenom

	// MinSponsorship is the floor on one Sponsor call: ten tickets' worth.
	//
	// IT IS A PRODUCT RULE, NOT A SAFETY ONE — the owner's, 2026-09-30: "it should be
	// a meaningful set amount, should be a threshold for sponsorship". A credit line
	// beside the prize is advertising, and advertising bought for dust is spam. The
	// figure is a hundred tickets so it reads against a number a player already
	// knows, rather than being a new denomination to learn.
	//
	// IT WAS TEN TICKETS FOR ABOUT AN HOUR AND THAT WAS TOO CHEAP IN REAL MONEY.
	// GNOT was $0.074 on 2026-09-30, so ten tickets is ~$7.40 — the price of putting
	// your name beside a prize for a week, which is not a price. The owner: "it's too
	// cheap, needs to be 10x at least". A hundred tickets is ~$74.
	//
	// AND IT IS A GNOT FIGURE, SO ITS REAL VALUE MOVES. Anyone revisiting this should
	// price it in fiat on the day rather than trusting the number: at a 10x in GNOT
	// this floor becomes ~$740 without anybody deciding that.
	//
	// NOTE WHAT IT DOES NOT GATE. FundPot — the duel's door — has no floor and must
	// not gain one: a flush carries whatever rake has accumulated, frequently far less
	// than this, and a floor there would strand it. The two doors are separate
	// precisely so this constant can exist.
	MinSponsorship int64 = 100 * TicketPrice

	// maxSponsorLabelLen bounds the credit line, in BYTES rather than runes, because
	// a byte bound is what makes the storage cost predictable. Same figure and same
	// reasoning as the duel's label.
	maxSponsorLabelLen = 64

	// maxSponsorsPerWeek bounds the list Render walks and the storage one week can be
	// made to hold. At MinSponsorship each slot costs a sponsor 100 GNOT, so filling a
	// week costs 1,600 GNOT — the bound is belt-and-braces over a price that already
	// makes flooding expensive, and it is here so the cost of a full week is a fixed
	// number rather than whatever an attacker's budget happens to be.
	maxSponsorsPerWeek = 16
)

// A NEGATIVE ARRAY LENGTH IS A COMPILE ERROR, so this line fails the BUILD if a
// future edit pushes the house cut past the denominator — the case in which the
// prize remainder would go negative and a sale would credit the pot with less
// than nothing. Same guard shape as r/splash/arcade/duel's rake split.
//
// THE `- 1` IS NOT DECORATION AND WAS MISSING UNTIL TODAY. Without it the guard admits
// HouseCutBps == bpsDenom, which compiles to a length of zero and is therefore SATISFIED
// — while the house takes 100% of every sale, net is 0, and Buy credits the prize pot with
// nothing at all. Tickets sold into a zero pot, with the build green. Dead at 500 bps, and
// the cost of the character is nothing (AUDIT-2026-09-28.md finding 11).
var _ [bpsDenom - HouseCutBps - 1]struct{}

// A TICKET MUST BE A WHOLE NUMBER OF ENTRY UNITS, and this line fails the BUILD if
// TicketPrice % EntryUnitPrice != 0. Length 0 when they divide exactly, NEGATIVE — and
// therefore a compile error — otherwise.
//
// WHY DUST IN THE WEIGHT DOMAIN IS NOT A ROUNDING NUISANCE BUT AN UNRECOVERABLE ONE.
// Buy charges tickets * TicketPrice and appends tickets * unitsPerTicket of weight. If
// the division had a remainder, the buyer would pay for a fraction of a unit they can
// never hold: the fenwick index takes int64 deltas and REFUSES NEGATIVE ONES BY DESIGN,
// FrozenTotal must never move once a week is committed, and nothing in this realm can
// retire or adjust an index once appended (see Draw.tickets, and finding 3 on why
// refunds cannot retire tickets). So there is no place to carry a remainder to and no
// later call that could reconcile it — the money would be in the pot and the weight it
// paid for would not exist. Refusing the pair at compile time is the only fail-closed
// answer available.
//
// IT IS A GUARD THAT CAN ACTUALLY FAIL, which the doctrine of finding 11 demands:
// BOTH constants appear, neither cancels, and the two sides are the same physical
// quantity (ugnot) reached by two different routes — one a product of the derived unit
// count, one the price itself. Set EntryUnitPrice to 300_000 against a 10 GNOT ticket
// and the build stops; the mutation and its exact output are recorded in finding 22.
var _ [unitsPerTicket*EntryUnitPrice - TicketPrice]struct{}

// AND A TICKET MUST BE WORTH AT LEAST ONE UNIT. Exact divisibility alone admits
// EntryUnitPrice > TicketPrice, where unitsPerTicket floors to zero and every purchase
// would append nothing at all — money into a pot, no weight in the draw, and a week
// whose FrozenTotal is zero that Commit then refuses for ever. 39 elements as the
// constants stand, which is small enough for the GnoVM to materialise (the duel's
// ladder note is why token-scale array guards are forbidden; this one is a unit count).
var _ [unitsPerTicket - 1]struct{}

// THE HOUSE CUT MUST BE EXACT ON A SINGLE TICKET, and this is the guard the escrowed
// fee's refund path rests on. Length 0 when TicketPrice * HouseCutBps divides bpsDenom
// exactly, negative otherwise.
//
// WHAT BREAKS WITHOUT IT, precisely. Buy floors the cut over a whole call's cost and
// adds it to Draw.Cut; Refund re-derives one buyer's share of that Cut by flooring over
// their accumulated GROSS. Those two only agree for every possible sequence of
// purchases if the flooring never actually discards anything — because
// floor(a/n) + floor(b/n) can be one LESS than floor((a+b)/n). With a remainder, two
// separate one-ticket buys would book less Cut than a single refund of the pair
// re-derives, Draw.Cut would go NEGATIVE, and checkInvariant would abort the refund of
// a buyer whose own money is sitting in the realm — a "money in, no way out" path
// created by a rounding error. With the guard, cut == tickets * cutPerTicket for every
// call and every partial sum, so the derivation is exact by construction rather than by
// argument. AUDIT-2026-09-28.md finding 25.
var _ [cutPerTicket*bpsDenom - TicketPrice*HouseCutBps]struct{}

// --- the ops destination -------------------------------------------------
//
// opsVaultAddr — gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops. THE ONE PLACE THE HOUSE'S MONEY CAN GO,
// fixed at compile time, and a VERBATIM DUPLICATE of r/splash/arcade/duel's and
// r/splash/exchange's constant of the same name.
//
// IT IS DUPLICATED RATHER THAN IMPORTED for the reason stated in duel.gno: a
// realm's address is a pure function of its package path
// (gnolang.DerivePkgCryptoAddr), the sibling realms' constants are unexported,
// and this is a different package. The realm at that path need not exist yet for
// the address to be right.
//
// tools/raffle_addr_test.go re-derives it from the package path on every
// `go test ./tools`, fails on a mismatch, and fails on any address constant in
// this file it has not been told about — the guard r/splash/exchange's R3 finding
// (a label hash shipped as a live destination) showed to be necessary. A Gno-side
// test cannot be that guard: an assertion that WithdrawOps' transfer landed at
// opsVaultAddr is true for ANY value of opsVaultAddr, including a wrong one, so a
// passing suite would pin the defect rather than catch it.
//
// BEING A COMPILE-TIME CONSTANT IS ALSO THE WHOLE AUTHORISATION ARGUMENT FOR
// WithdrawOps BEING PERMISSIONLESS — see there.
const opsVaultAddr address = "g1dqnxfp5zj89ggfcfzvampmhmrkjq36d2zvdyk7"

// blocksPerDay is the block-count day unit, copied from r/splash/game (which
// documents the choice): this toolchain exposes no block-timestamp getter, so
// the clock is chain height. NOTHING IN THIS REALM IS A TIMESTAMP — a week is a
// sequence number derived from the global clock, and no ticket, spend or draw
// is dated.
const blocksPerDay = 26182

// raffleWeekDays is the draw period in those day units. A FREE DIAL, as in
// r/splash/game: referenced from exactly one place (currentWeek), and nothing
// else in the file assumes seven of anything.
const raffleWeekDays = 7

// randomnessHexLen is the length of a beacon randomness string: sha256,
// hex-encoded, 64 characters.
const randomnessHexLen = 64

// --- the beacon's cadence ------------------------------------------------
//
// beaconRoundsPerDay IS THE ONE CADENCE ASSUMPTION THIS FILE MAKES, and the round
// pin below is a duration expressed through it.
//
// IT IS NO LONGER A NUMBER TYPED INTO THIS FILE, and that change is the single
// most important line in the drand migration. It used to read
// `const beaconRoundsPerDay = 288` — one round every five minutes, the cadence of
// the beacon SPLASH itself ran. r/splash/beacon now verifies drand evmnet, whose
// period is THREE SECONDS, so the true figure is 86400/3 = 28800 and every
// round-denominated window in this file was wrong by a factor of 100 the moment
// the key changed. Taking the number from the beacon means the two can never
// disagree again.
//
// WHY 100x WRONG WAS NOT MERELY UNTIDY — IT SILENTLY RE-OPENED
// AUDIT-2026-09-28.md FINDING 10. pinOffsetRounds is derived from this constant
// and exists to make the week's pinned round fall AFTER ticket sales close. At 288
// the offset measured 1.92 hours of real time instead of 8 days, so the winning
// randomness would have been published on a public API days before the week ended
// and the last purchaser of the week could buy the winning unit outright. AND THE
// BUILD GUARD DID NOT CARE: the old
// `var _ [pinOffsetRounds - raffleWeekDays*beaconRoundsPerDay - 1]struct{}`
// compares rounds to rounds, this constant appears on both sides and cancels, so
// the assertion stayed satisfied while measuring a hundredth of the real time. AN
// ASSERTION THAT CANNOT FAIL IS NOT AN ASSERTION. It is replaced below by one that
// compares SECONDS to SECONDS, drawing the two sides from different clocks so that
// no single wrong constant can cancel itself out.
//
// THE OTHER CLOCK, unchanged: a block is ~3.3s, so a day is blocksPerDay = 26182
// blocks (ECONOMICS.md §7a-bis's measured block time, the constant r/splash/game
// and r/splash/arcade/duel also use). NOTE THAT THE BLOCK-DENOMINATED CONSTANTS DID
// NOT MOVE IN THE MIGRATION AND THE ROUND-DENOMINATED ONES ALL MOVED BY 100x —
// half this file's durations were right and half were wrong, which is exactly why
// the error was invisible. There is no block-timestamp getter here, so a realm
// cannot measure either clock at runtime; both are assumptions, and they are
// written down rather than implied.
const beaconRoundsPerDay = beacon.RoundsPerDay

// --- pinning the week's beacon round -------------------------------------
//
// THE ROUND A WEEK IS DRAWN ON IS FIXED WHEN THE WEEK'S RECORD IS CREATED, never
// when it is committed. getOrCreateDraw writes Draw.Round exactly once and nothing
// else in this file ever writes it again.
//
// THE DEFECT THAT FORCED THIS, and it was the operator's cheapest attack on the
// whole product. Commit used to bind Round = beacon.Latest() + 1. The beacon's
// publisher BLS key is compiled in with no rotation path and the signed message is
// derived ONLY from the chain id and the round number (see r/splash/beacon), so the
// key holder can produce a valid signature for ANY round at will and therefore knows
// every round's randomness in advance, permanently. beacon.Publish applies no
// sequence check and no window check, and latestRound only ever rises. So the key
// holder could: buy one ticket during the week; wait for the week to close, which
// froze the ticket set into something public and immutable; enumerate candidate
// rounds off-chain computing ownerOfUnit(d, randomness(r) mod FrozenTotal) for each;
// Publish rounds until beacon.Latest()+1 was a round that named them; and then
// Commit. A DETERMINISTIC, RISK-FREE WIN THAT LOOKED EXACTLY LIKE A NORMAL
// SETTLEMENT. Note the irony, so it is not repeated: requiring Commit to take a
// FINISHED week (the 2026-09-28 griefing fix) made this strictly worse, because
// freezing the ticket set before the round was chosen turned an available attack
// into an exact one.
//
// WHAT PINNING AT CREATION ACHIEVES. The round is fixed before the week's first
// ticket exists, so nobody — key holder or not — can move the draw onto a round
// that suits the ticket set, because there is no ticket set yet. The committer has
// no round choice left at all: Commit reads d.Round and cannot compute one.
//
// WHAT IT DOES NOT ACHIEVE, STATED PLAINLY BECAUSE OVERSTATING IT WOULD BE WORSE
// THAN NOT DOING IT. It does NOT stop the key holder rigging the draw. They still
// know randomness(d.Round) from the moment the week opens, so they can still choose
// the MODULUS: be the final purchaser before the week closes, sizing the buy so that
// randomness mod FrozenTotal lands on a unit they own. That is a strictly worse
// attack for them — it costs real tickets and leaves an on-chain trace as a
// suspicious late buy — but it is not closed here and this realm cannot close it.
// THE ARCHITECTURAL PROBLEM (the project holding the beacon key) REMAINS OPEN AND IS
// THE OWNER'S DECISION: an externally-controlled beacon or a VRF. See
// AUDIT-2026-09-28.md findings 4 and 10.
//
// THE DERIVATION OF THE OFFSET, which must not be a picked number:
//
//	THE PROPERTY REQUIRED is that the pinned round falls AFTER that week's ticket
//	sales close, so that in honest operation the round's randomness does not exist
//	until the ticket set is already frozen. A week's record can be created at any
//	point inside the week it belongs to (Buy and FundPot both act on currentWeek()),
//	and the worst case is the FIRST BLOCK of that week: the whole week — raffleWeekDays
//	days — still has to elapse before sales close.
//
//	SO THE OFFSET MUST EXCEED ONE WEEK OF ROUNDS: raffleWeekDays * beaconRoundsPerDay
//	= 7 * 28800 = 201600 rounds. One day of margin on top absorbs ordinary cadence
//	jitter and the estimation error described below, giving pinOffsetDays = 8 and
//	pinOffsetRounds = 230400.
//
//	THE COST OF THE MARGIN IS PAID IN WAITING, WHICH IS WHY IT IS ONE DAY AND NOT
//	SEVEN. A week whose record is created late in the week pins a round up to
//	pinOffsetDays after the week closes, so Resolve may have to wait that long after
//	Commit. That wait is the top half of the honest cycle the refund grace window has
//	to outlast; see refundGraceDays, where this constant appears in the derivation.
//
// WHY THE ROUND NUMBER, NOT A HEIGHT: rounds are a beacon counter with no on-chain
// mapping to chain height, so the only anchor a realm has is what the beacon reports
// at pin time. That is also why pinning requires the beacon to have published at
// least once — see getOrCreateDraw.
//
// AND WHY THE ANCHOR IS beacon.EstimatedLatestRound() AND NOT beacon.Latest().
// THIS IS A DRAND-MIGRATION CHANGE AND IT IS SECURITY-CRITICAL. Under the old
// SPLASH beacon, Latest() was approximately the current round by assumption: the
// publisher was this project, emitting every five minutes, so "highest published"
// and "now" were within one period of each other. r/splash/beacon is now an
// ON-DEMAND RECORD of drand — nothing relays routinely, because nothing needs to —
// so Latest() is whatever round somebody last had a reason to relay. That is
// plausibly last week's pinned round, and after a quiet spell, months old.
//
// Pinning Latest() + pinOffsetRounds against a stale anchor measures the offset
// from the past, so the pinned round lands EARLIER in real time than intended. Let
// the anchor be stale by Δ rounds: the pin lands at now − 3Δ seconds + 8 days, and
// sales close at most 7 days from now, so as soon as 3Δ > 1 day — Δ > 28800 rounds,
// ONE DAY OF STALENESS — the pinned round's randomness is public before sales
// close. THAT IS FINDING 10'S LAST-BUYER ATTACK, VERBATIM, and no guard in this file
// can see it, because the file has no way to tell a fresh anchor from a stale one.
//
// beacon.EstimatedLatestRound() corrects for exactly that: it adds the blocks
// elapsed since the anchor round was relayed, converted at the two cadences, using
// a clock no relayer controls. It equals Latest() when nothing is stale, so this is
// a strict improvement at no liveness cost.
//
// THE RESIDUAL ERROR, AND THE FIGURE IN THIS COMMENT WAS WRONG BY A FACTOR OF NINE
// UNTIL TODAY. It read "a day of staleness at 10% block drift is ~14 minutes and does
// not matter", and so did DRAND-MIGRATION.md §5b/§9.4(a), AUDIT-2026-09-28.md §A2 and
// the duel's audit addendum. Derived rather than copied:
//
//	A = 86400/blocksPerDay = 3.29998 s   the block time this file and the beacon assume
//	B = the chain's real average block time
//	S = blocks since the beacon's anchor was last raised
//
//	error = S*(A − B)/PeriodSeconds rounds = S*(A − B) SECONDS of drand time
//
// which in terms of elapsed real time T = S*B is T*(A/B − 1), i.e. |T*(1 − A/B)|:
//
//	ONE DAY of staleness at 10% drift: 86400*(1 − 3.29998/3.63) = 7854 s = 2.2 HOURS
//	                   (or 2.4 hours in the fast direction, B = 3.0 s)
//	ONE YEAR at the same 10%:          ~36 days — which was RIGHT, and that is what
//	                   localises the slip: 2.2 hours x 365 is 33 days, so the year
//	                   figure was computed correctly and the day figure was not.
//
// THE SLIP WAS A DOUBLE DIVISION BY THE PERIOD: the formula "staleness x (real block
// time − 3.3s) / 3s" yields ROUNDS when staleness is in seconds, and the ~14-minute
// number comes from reading that as seconds and dividing by 3 again. 7854/9 = 873 s =
// 14.5 minutes. See AUDIT-2026-09-28.md finding 13.
//
// AND THERE IS A SECOND TERM THE OLD FRAMING OMITTED ENTIRELY: THE WEEK LENGTHENS AND
// THE PIN DOES NOT. A week here is a BLOCK count and pinOffsetRounds is a ROUND count,
// so the pin margin is 691200 − raffleWeekDays*blocksPerDay*B seconds:
//
//	B = 3.29998 (nominal)   margin = 86400 s = 24 hours
//	B = 3.63    (10% slow)  margin = 25916 s = 7.2 hours — BEFORE any staleness at all
//	B = 3.7714              margin = 0       — gone, at a 14.3% drift in one constant
//
// So finding 10's defence rests on a 14% tolerance in blocksPerDay, and the staleness
// error eats into what is left of it. Both terms are now asserted at compile time by
// the second guard below pinOffsetRounds.
//
// IT IS NO LONGER LEFT TO THE OWNER, AND THAT IS THE CHANGE OF 2026-09-28's LATER FIX.
// Bounding the error means refusing to open a week against a beacon nobody has relayed
// to recently, and the recorded reason for not doing it was cross-realm: getOrCreateDraw
// is reached from FundPot, FundPot was called inside r/splash/arcade/duel's Collect, and
// a refusing FundPot therefore stranded every later duel winner. THAT COUPLING IS GONE —
// Collect books its rake and FlushPot delivers it, so a refusing FundPot now costs the
// flusher a reverted transaction and nothing else — and the bound is in
// r/splash/beacon itself, where a fifth consumer cannot forget it. See
// beacon.maxEstimateStaleBlocks, and AUDIT-2026-09-28.md findings 12 and 14.
const (
	// pinMarginDays is the cadence-jitter and estimation margin described above.
	// A FREE DIAL, but raising it lengthens the honest cycle and therefore feeds
	// refundGraceDays.
	pinMarginDays = 1

	// pinOffsetDays is how far past the pin the round sits, in days: 7 + 1 = 8.
	pinOffsetDays = raffleWeekDays + pinMarginDays

	// pinOffsetRounds is that in beacon rounds — the number added to the beacon's
	// estimated current round at record creation. 8 * 28800 = 230400.
	pinOffsetRounds = beaconRoundsPerDay * pinOffsetDays
)

// THE PINNED ROUND MUST OUTLAST THE WEEK'S SALES, and this line fails the BUILD if
// it ever stops doing so. A negative array length is a compile error.
//
// READ THE UNITS, BECAUSE THE UNITS ARE THE WHOLE POINT. This guard replaces
//
//	var _ [pinOffsetRounds - raffleWeekDays*beaconRoundsPerDay - 1]struct{}
//
// which was dimensionally consistent and WRONG ABOUT THE WORLD: rounds on the left,
// rounds on the right, beaconRoundsPerDay on both sides, cancelling. Set the cadence
// to 288, to 28800 or to 3 and that guard was equally satisfied while the real-time
// distance it was protecting changed by orders of magnitude. It is the reason the
// five-minute-to-three-second switch could have shipped with finding 10 wide open.
//
// THIS GUARD COMPARES SECONDS TO SECONDS, and the two sides come from DIFFERENT
// clocks so that no single constant appears on both and cancels:
//
//	LEFT  — the pinned round's distance in real seconds, via drand's period:
//	        pinOffsetRounds * beacon.PeriodSeconds = 230400 * 3 = 691200 s = 8.000 days
//	RIGHT — one raffle week in real seconds, via the chain's ~3.3s block time:
//	        raffleWeekDays * blocksPerDay * 33/10 = 183274 * 3.3 = 604804 s = 6.99995 days
//	        (33/10 is integer constant arithmetic; 3.3 is not expressible as an int)
//	MARGIN = 86395 seconds, just under the one day pinMarginDays asks for.
//
// With the pre-migration cadence the left side reads 2304 * 3 = 6912 seconds against
// the same 604804, the array length is negative, AND THE BUILD FAILS. That is the
// assertion this file was missing.
var _ [pinOffsetRounds*beacon.PeriodSeconds - raffleWeekDays*blocksPerDay*33/10 - 1]struct{}

// AND THE MARGIN MUST ALSO SURVIVE THE BEACON'S WORST ADMITTED ESTIMATION ERROR, WITH THE
// WEEK MEASURED AT THE SLOW EDGE OF THE BLOCK-TIME BAND. This second guard is the one the
// drand migration did not have, and its absence is AUDIT-2026-09-28.md finding 12: the
// guard above compares the pin against a week at the NOMINAL block time and says nothing
// about either the week LENGTHENING or the anchor being WRONG.
//
// TWO TERMS, AND THE FIRST ONE IS THE ONE THAT WAS MISSING ENTIRELY:
//
//	THE WEEK LENGTHENS AND THE PIN DOES NOT. A raffle week is a BLOCK count
//	(raffleWeekDays * blocksPerDay, read through currentWeek) while pinOffsetRounds is a
//	ROUND count, and drand's rounds are real time by definition. So at a block time B the
//	pin margin is 691200 - 183274*B seconds, not the flat 86400 the guard above implies:
//	  B = 3.29998 (nominal)   margin = 86400 s  = 24 hours
//	  B = 3.63     (10% slow) margin = 25915 s  = 7.2 hours
//	  B = 3.771                margin = 0       — GONE, at a 14% drift in one constant
//	The right-hand term below is therefore the week at 363/100 s a block, the slow edge of
//	the band, not at 33/10.
//
//	THE ANCHOR IS ONLY AS GOOD AS THE BEACON IS FRESH. r/splash/beacon refuses to
//	extrapolate more than beacon.MaxEstimateStaleBlocks past the last relay that raised
//	its anchor, and its error over that distance is at most 33/100 s per block at the
//	same 10% drift — 26182 * 33/100 = 8640 s, 2.4 hours. That is the third term.
//
//	LEFT   = pinOffsetRounds * beacon.PeriodSeconds        = 691200 s   (drand's clock)
//	MINUS    raffleWeekDays * blocksPerDay * 363/100       = 665284 s   (the chain's, slow edge)
//	MINUS    beacon.MaxEstimateStaleBlocks * 33/100        =   8640 s   (the beacon's admitted error)
//	MARGIN                                                =  17275 s   = 4.8 hours
//
// THREE CLOCKS, NO CONSTANT ON BOTH SIDES, AND IT CAN FAIL: lengthen the beacon's
// staleness bound, lengthen the week, shorten the pin offset, or widen the drift band, and
// the build fails. That is what distinguishes it from the guard this file had at line 470
// until today, which compared the bare integers 21 and 8 and could not fail for any value
// of anything (AUDIT-2026-09-28.md finding 11).
var _ [pinOffsetRounds*beacon.PeriodSeconds - raffleWeekDays*blocksPerDay*363/100 - beacon.MaxEstimateStaleBlocks*33/100 - 1]struct{}

// maxPinnableLatest is the highest anchor round from which a round can still be
// pinned without the int64 addition wrapping. A wrapped pin would be a negative
// round — a round nobody can ever publish. getOrCreateDraw refuses instead, loudly.
//
// SINCE THE DRAND MIGRATION THIS IS BELT-AND-BRACES ON AN ADDITION, NOT A LIVE
// GRIEFING SURFACE, and the change is worth stating because the paragraph it
// replaces was one of the longest in this file.
//
// It used to be reachable by a deliberate act: the SPLASH beacon's key holder could
// sign ANY round, including one near the int64 maximum, and one Publish moved
// latestRound there for ever — after which no new week could be opened in this realm
// again, because Buy and FundPot both refuse a live week with no record. That
// reached across a realm boundary, since r/splash/arcade/duel's Collect CALLED FundPot
// DIRECTLY at the time, so every later duel winner would have been unable to collect; the
// recorded decision was that choosing between refusing and pinning a clamped
// unpublishable round is the owner's, not this file's. (THAT COUPLING IS GONE — Collect
// books its rake and duel.FlushPot delivers it, so a refusing FundPot now costs the
// flusher a reverted transaction and no winner anything. AUDIT-2026-09-28.md finding 14.
// The sentence is kept because the cross-realm reasoning it records is what that finding
// is about.)
//
// DRAND CANNOT SIGN A ROUND WHOSE TIME HAS NOT COME, so latestRound is now bounded
// above by drand's real head: ~2.1e7, gaining ~1.05e7 a year, reaching 9.2e18 in
// about 880 billion years. The trigger is gone and the cross-realm decision is moot.
// This constant stays because the arithmetic still must not wrap, and because a
// future change of beacon must not silently inherit the assumption that it cannot.
//
// (The same act was the operator-triggered half of AUDIT-2026-09-28.md finding 7 —
// one far-future Publish moving latest past the prune window and abandoning every
// pending week at once. That is dead too, for the same reason. The STALLED-beacon
// half of finding 7 is very much alive and the height gate below is still the only
// answer to it.)
const maxPinnableLatest = int64(maxInt64) - pinOffsetRounds

// --- the refund grace window ---------------------------------------------
//
// refundGraceBlocks IS A BEACON-INDEPENDENT FLOOR ON BUYER ACCESS, and it is the
// only thing in this file that lets a committed week's pot out when the beacon
// simply STOPS. Read Refund and resolvable() with it.
//
// THE DEFECT IT CLOSES, and the lesson that goes with it: r/splash/arcade/duel
// had already solved exactly this problem and this realm had not. The duel's
// VoidStale gates on runtime.ChainHeight() - d.AcceptedAt >= voidGraceBlocks —
// CHAIN HEIGHT, NOT BEACON STATE — and its comment says in as many words that
// without it "a stopped publisher freezes every pending duel with both stakes
// locked, permanently, on a contract that cannot be patched". That sentence
// described this realm verbatim until this constant existed. A week's round is
// pinned at A + pinOffsetRounds, where A is the beacon's anchor round at record
// creation (it was latest+1, bound in Commit, when this window was first written;
// the pin moves the round further out, which only widens the trap below). Freeze
// the beacon at that same A and BOTH exits refuse forever: Resolve panics "beacon
// round not published yet", and Refund panicked "still resolvable" because
// resolvable() reduced to A+pinOffsetRounds > A-PruneWindow, which is true for
// ever. The week's whole pot — the buyers' own money — was then unreachable by
// every path in the file, while heldPots went on counting it so checkInvariant and
// AuditFailure both stayed green. Not committing was no defence either: Refund
// requires Committed, so the only way out of a stranded week is through the very
// act that sets the trap.
//
// AND SINCE THE DRAND MIGRATION THIS GATE IS NOT A SECOND OPENER, IT IS THE ONLY
// ONE. resolvable() is gone (see Refund), because the state it detected — "the
// round came and went and its signature is destroyed" — cannot occur against a
// beacon that never prunes and an API that serves every round for ever. What
// replaced that failure mode is a pure liveness failure: nobody has bothered to
// relay the round. A beacon-state gate can never detect that, because there is
// nothing about the beacon's state that distinguishes "not relayed yet" from
// "never will be". A CLOCK CAN. That is precisely what this constant is.
//
// THE OPERATOR-TRIGGERED VARIANT OF THE SAME ROOT IS NOW DEAD, AND THE PARAGRAPH IS
// KEPT BECAUSE ITS LESSON IS NOT. Under the SPLASH key, beacon.Publish applied no
// sequence check and latestRound only ever rose, so ONE Publish of a far-future round
// moved latest by more than beacon.PruneWindow in a single transaction — flipping
// resolvable() false for every pending committed week at once and forcing mass
// abandonment. drand cannot sign a round whose time has not come, so latestRound is
// bounded by drand's real head and nobody can jump it. The STALLED-beacon variant
// above is untouched and is now the ONLY thing standing between a quiet week and a
// trapped pot — and it got LARGER, because with an on-demand record nobody relays
// unless they want something (see below).
//
// THE DERIVATION, because the number must not be arbitrary.
//
//	THE CADENCE ASSUMPTION THIS RESTS ON is beaconRoundsPerDay and blocksPerDay —
//	stated in full at beaconRoundsPerDay, above. This window is a duration
//	expressed in the only clock a realm can read here, so if either assumption
//	moves materially it must be re-derived.
//
//	THE UPPER BOUND ON AN HONEST CYCLE USED TO HAVE TWO TERMS AND NOW HAS ONE AND A
//	HALF, and the change is a drand-migration change. It is measured from Commit,
//	because Commit is what CommittedAt records and therefore what this window counts
//	from:
//
//	  1. WAITING FOR THE PINNED ROUND TO BE SIGNED: up to pinOffsetRounds = 230400
//	     rounds, which at three seconds is 8 days. The worst case is a week whose
//	     record was created in its final block — the pin is then measured from almost
//	     exactly the moment the week closes, so the round lands the whole offset
//	     after Commit. (A week created early pins a round that is already signed by
//	     Commit, which is fine and is the point: nobody CHOSE it.)
//	  2. WAITING FOR SOMEBODY TO RELAY IT. This term used to be
//	     beacon.PruneWindow — a further 7 days, after which the signature was GONE,
//	     resolvable() went false on its own, and refunds opened through the
//	     beacon-derived half of Refund's gate. THAT TERM NO LONGER EXISTS AND
//	     NEITHER DOES ITS DEADLINE. Every drand round is served for ever by the
//	     public API and r/splash/beacon neither prunes nor forgets, so a pinned
//	     round is obtainable indefinitely — and correspondingly nothing FORCES
//	     anyone to obtain it. The second term is therefore UNBOUNDED, and the height
//	     gate is not one of two independent openers any more, IT IS THE ONLY ONE.
//	     See resolvable's removal and Refund's gate.
//
//	SO THE BOUNDED PART OF THE HONEST CYCLE IS pinOffsetDays = 8 DAYS from Commit,
//	and the height gate MUST be strictly longer than that: a shorter one would open
//	refunds on a week whose pinned round has not even been signed yet, let alone
//	failed to resolve. The 13 days of slack above it are now the RELAY ALLOWANCE —
//	how long this realm is willing to wait for somebody to spend ~17.0M gas relaying
//	one round — and that is what the margin is for, so it says so.
//
//	21 DAYS IS KEPT RATHER THAN RECOMPUTED, on purpose. The bound it has to clear
//	fell from 15 days to 8 when the retention term disappeared, so 21 is now more
//	generous than strictly required. Shortening it would be a change to buyers'
//	exposure made as a side effect of a beacon migration, and the direction is not
//	obviously right: the second term is unbounded now, so the case for a long window
//	is stronger, not weaker.
const (
	// refundGraceDays is the window in days. THE ONE DIAL: everything below is
	// derived from it, so re-tuning it cannot leave the two units disagreeing.
	refundGraceDays = 3 * raffleWeekDays

	// refundGraceBlocks is that window in blocks — the value Refund actually
	// compares against runtime.ChainHeight(). 21 * 26182 = 549822.
	refundGraceBlocks = blocksPerDay * refundGraceDays
)

// THE GRACE MUST OUTLAST THE BOUNDED PART OF THE HONEST CYCLE, and this line fails
// the BUILD if it ever stops doing so: a negative array length is a compile error,
// so refundGraceDays must stay strictly greater than pinOffsetDays. 21 > 8, with 12
// spare. Without it, someone lengthening the pin offset would silently open refunds
// on weeks whose pinned round has not been signed yet.
//
// "THE UNITS ARE DAYS ON BOTH SIDES, AND DAYS ARE REAL TIME" IS WHAT THIS COMMENT SAID
// UNTIL TODAY, AND IT WAS WRONG — THE GUARD IT DEFENDED WAS
//
//	var _ [refundGraceDays - pinOffsetDays - 1]struct{}   // 21 - 8 - 1 = 12
//
// THEY ARE NOT THE SAME DAY. refundGraceDays becomes BLOCKS (refundGraceBlocks =
// blocksPerDay * 21 = 549822 blocks, a real duration of 549822 * B for an unknown block
// time B) and pinOffsetDays becomes DRAND ROUNDS (pinOffsetRounds = RoundsPerDay * 8 =
// 230400 rounds, a real duration of exactly 691200 seconds). The guard compared the bare
// integers 21 and 8, named NEITHER cadence, and therefore COULD NOT FAIL FOR ANY VALUE of
// blocksPerDay, beacon.PeriodSeconds or beacon.RoundsPerDay. Set blocksPerDay = 2618 and
// it still compiled while the grace window shrank to 2.4 real days against a bounded wait
// of 8 real days — refunds opening on weeks whose pinned round had not been signed yet.
//
// IT IS THE SAME DEFECT AS THE GUARD IT REPLACED, REINTRODUCED IN THE CHANGE WRITTEN TO
// ELIMINATE IT. The old `[pinOffsetRounds - raffleWeekDays*beaconRoundsPerDay - 1]` was
// rounds-versus-rounds with the cadence cancelling; this one was days-versus-days with
// BOTH cadences omitted, which is worse — there was not even a constant to notice.
// AUDIT-2026-09-28.md finding 11 records the general rule: A GUARD THAT PROTECTS A
// REAL-WORLD DURATION MUST HAVE SECONDS ON BOTH SIDES, SOURCED FROM TWO DIFFERENT CLOCKS,
// OR IT CANNOT FAIL. The doctrine was applied correctly at the pinOffsetRounds guard above
// and at r/splash/arcade/duel's voidGraceBlocks guard, and missed here.
//
// SO IT NOW COMPARES SECONDS TO SECONDS, in the style of the guard above:
//
//	LEFT  — the grace window in real seconds, via the chain's ~3.3s block time:
//	        refundGraceDays * blocksPerDay * 33/10 = 549822 * 3.3 = 1814412 s = 21.000 days
//	RIGHT — the bounded part of the honest cycle in real seconds, via drand's period:
//	        pinOffsetRounds * beacon.PeriodSeconds = 230400 * 3 = 691200 s = 8 days exactly
//	MARGIN = 1123212 seconds, 13 days, the relay allowance the derivation above asks for —
//	        a 2.6x margin, and it NAMES the constants it depends on.
//
// MUTATION-TESTED, not reasoned about: setting blocksPerDay = 2618 in the working tree
// makes THIS guard's length negative and the build fail, while the old days-versus-days
// guard compiled unchanged at that value. The failing build output is in
// AUDIT-2026-09-28.md finding 11.
//
// THE TWO GUARDS THIS ULTIMATELY REPLACES, for the reader who comes looking for them:
//
//	var _ [refundGraceRounds - beacon.PruneWindow - 1]struct{}
//	var _ [refundGraceRounds - pinOffsetRounds - beacon.PruneWindow - 1]struct{}
//
// BOTH would have rescaled to 28800 rounds a day without complaint (604800 > 230400 +
// 201600) while asserting a relationship to a retention window that no longer exists.
// beacon.PruneWindow is gone, so they no longer compile. refundGraceRounds is gone with
// them: it existed ONLY to feed them, and one fewer round-denominated constant is one
// fewer place a cadence error can hide.
var _ [refundGraceDays*blocksPerDay*33/10 - pinOffsetRounds*beacon.PeriodSeconds - 1]struct{}

// --- state ---------------------------------------------------------------

// Sponsorship is one credit line beside a week's prize: who paid, what they
// asked to be called, and what they put in.
//
// Amount IS THE GROSS, the figure the sponsor actually parted with, not the net
// that reached the pot. A credit that understated what someone paid would be a
// strange thing to sell them, and the house's share of it is derivable from
// HouseCutBps by anybody who cares.
type Sponsorship struct {
	By     address
	Label  string
	Amount int64
}

// Draw is one week's raffle: the pot, the ticket index that decides it, and
// the beacon round it is committed to.
type Draw struct {
	Week int64

	// Pot is the prize pot in ugnot: the sum of every buyer's contribution
	// AFTER the house cut, PLUS any house money sponsored into this week
	// (see Sponsored). Zeroed by Resolve when it pays the winner, and
	// decremented by Refund as each buyer reclaims their share.
	//
	// THE IDENTITY IS NOW Pot + Cut == sum(spendOf) + Sponsored, and it is what makes
	// Refund unable to overdraw. It was Pot == sum(spendOf) + Sponsored until
	// 2026-09-29, when spendOf started recording the buyer's GROSS payment and the
	// house's fee started being escrowed in Cut instead of banked at sale time. Read
	// Cut, and AUDIT-2026-09-28.md finding 25.
	Pot int64

	// Cut is THE HOUSE'S FEE FOR THIS WEEK, HELD IN ESCROW AND NOT YET EARNED: the sum
	// of HouseCutBps of every ticket sold into this week. In ugnot, like everything
	// else here.
	//
	// IT IS NOT PART OF Pot AND THE WINNER MUST NEVER WIN IT. Resolve pays Pot to the
	// winner and moves Cut to opsPot, in that order, as two separate amounts. If the
	// fee were folded into Pot the winner would be paid the house's money; if it were
	// in opsPot from the moment of sale — which is what happened until 2026-09-29 —
	// then a week that never drew would refund only 95% of what its buyers paid.
	//
	// THE RULE IT IMPLEMENTS IS THE OWNER'S: WE EARN WHEN THE GAME RUNS, NOT WHEN IT
	// FAILS. So the fee has exactly two destinations and no third:
	//
	//   - A SUCCESSFUL Resolve moves it to opsPot. The draw happened; we ran it.
	//   - ANY OTHER OUTCOME REFUNDS IT. Refund returns each buyer's GROSS spend and
	//     decrements this field by exactly the part of that gross which came here in
	//     the first place (see Refund's split, and cutPerTicket's build guard for why
	//     that re-derivation is exact rather than approximately right). An ABANDONED
	//     week therefore hands the fee back with the prize money, which is the same
	//     principle finding 16 applied to Sponsored: we did not run a draw, so we do
	//     not keep the fee.
	//
	// AND IT IS A TERM IN BOTH SOLVENCY STATEMENTS, not a note on the side. The realm
	// holds this wugnot, so checkInvariant is heldPots + heldCuts + opsPot == balance
	// and AuditFailure re-derives both new terms by iteration. A field the realm holds
	// money for and the invariant does not mention is the shape of a hole.
	//
	// A SWEPT OR DRAWLESS WEEK HAS Cut == 0 ONLY AFTER foldSponsorCut RUNS, AND IT USED
	// TO SAY 'BY CONSTRUCTION'. That was true until Sponsor gave a fee a second way in,
	// with no ticket sale behind it, and the stale sentence is exactly what produced the
	// 2026-09-30 audit's RED finding: SweepDrawlessWeek asserted the old claim and
	// stranded the whole week. The original reasoning, kept because it is still why the
	// assertion is worth making, because both sweepable
	// shapes require sum(spendOf) == 0 and a fee can only arrive with a ticket sale.
	// SweepDrawlessWeek asserts that rather than assuming it.
	Cut int64

	// Sponsored is the part of Pot that came from FundPot rather than from a
	// ticket sale: house or rake money, ATTRIBUTABLE TO NO BUYER. It buys no
	// tickets and no winning chance; it only makes the prize bigger.
	//
	// THE MONEY IS STILL ATTRIBUTABLE TO NO BUYER AFTER FINDING 15, AND THAT IS
	// WORTH BEING PRECISE ABOUT. Duel play now earns ENTRIES as well as sending
	// rake (FundPotWithEntries), so the same transaction that raises this field
	// also appends ticket weight for the two players. The two are still separate
	// facts: the entries are weight with no spendOf record, this field is money
	// with no owner, and neither is a claim on the other. The funder — the duel
	// realm — still gets nothing at all, so a realm that funds a pot still cannot
	// be the address a payout is pushed to.
	//
	// IT IS A SEPARATE FIELD BECAUSE THE REFUND SAFETY PROPERTY IS AN IDENTITY,
	// NOT AN INEQUALITY. Every ugnot of a week's pot must be attributable either
	// to a buyer who can reclaim exactly their own contribution, or to this
	// field. Adding sponsorship straight into Pot with nothing recording it
	// would leave Pot > sum(spends) — refunds could then no longer be shown to
	// be unable to overdraw, and the books could not tell house money from a
	// buyer's claim. So the invariant is Pot == sum(spendOf) + Sponsored, and
	// both checkInvariant (through heldSponsored) and AuditFailure (by
	// iteration) are written in those terms.
	//
	// IT IS NEVER LEFT BEHIND IN A POT NOBODY CAN REACH, and there are two such
	// pots. On an ABANDONED week (see Refund) nobody can reclaim it, so leaving it in Pot
	// while every spend is zeroed and nothing could ever move it would strand it forever.
	// On a finished week that NEVER SOLD A TICKET (see SweepDrawlessWeek) that week can
	// never be committed, so it can never be resolved or refunded either, and the money
	// would be just as stranded. Both are the same class of defect as the unreachable week
	// the 2026-09-28 audit's first finding was about.
	//
	// WHAT REACHES IT IN BOTH CASES IS retireSponsorship, SINCE 2026-09-29 (SECOND
	// REVISION — finding 31). This field is zeroed AT THE MOMENT THE WEEK IS ABANDONED and
	// the money is turned into A PER-UNIT CLAIM ON THIS SAME WEEK (ClaimPerUnit, Claims),
	// payable to the people who hold units IN THIS WEEK. It never changes weeks, never
	// waits in a register, and has no destination anybody can name. So `Sponsored > 0 on an
	// abandoned week` is now a STATE THAT CANNOT EXIST, and AuditFailure says so.
	//
	// THE DESTINATION USED TO DISAGREE WITH ITSELF, THEN AGREED, THEN BECAME CHOOSABLE,
	// THEN BECAME A REGISTER, AND IS NOW GONE. The full sequence, because it is the whole
	// lesson:
	//
	//   - Until 2026-09-29 the abandoned-week path sent this money to opsPot while the
	//     drawless-week path rolled it forward, over the same field, in the same file
	//     (AUDIT-2026-09-28.md finding 16: that asymmetry is a finding, not untidiness).
	//   - Both then rolled it into currentWeek() — the week live at the moment a
	//     permissionless caller fired, which let the caller pick the destination by picking
	//     the moment (finding 28).
	//   - Then a REGISTER (carryPending) held it until the next week record pulled it in at
	//     its own birth. That was meant to make the destination unchoosable. It did not:
	//     a caller could BUY ONE TICKET IN THE FINAL BLOCK OF A QUIET WEEK, which both
	//     created that week's record and absorbed every pending carry into a week whose
	//     entire ticket set was their own — 100% capture for the price of the house cut
	//     (finding 31). The "destination is young" property the design rested on was
	//     asserted in a test and never enforced in the code.
	//   - Now there is NO DESTINATION AT ALL. The money goes back to the addresses that
	//     hold units in the week it was already in.
	Sponsored int64

	// SponsorCut is HOW MUCH OF d.Cut CAME FROM SPONSORS rather than from ticket
	// sales, and it exists for exactly one reason: so that fee has a way out of an
	// abandoned week.
	//
	// THE DEFECT IT PREVENTS, STATED PLAINLY BECAUSE IT IS INVISIBLE OTHERWISE. Refund
	// is what retires a buyer's share of d.Cut, and it does so by RE-DERIVING the fee
	// from that buyer's own spendOf. A sponsor has no spendOf — sponsorship buys no
	// units, that is its definition — so no Refund call will ever reach a sponsor's
	// fee. Left in d.Cut it would be money that entered the realm and could not leave,
	// and checkInvariant would go on balancing happily the whole time, because a
	// balanced invariant is not evidence of a reachable exit.
	//
	// AND FOLDING SPONSORSHIP INTO spendOf TO REUSE Refund IS NOT THE ALTERNATIVE. That
	// re-derivation is exact ONLY because a spendOf is a whole number of TicketPrice;
	// an arbitrary sponsorship is not, so d.Cut would go negative and a BUYER's own
	// reclaim would start panicking. That arithmetic is AUDIT-2026-09-28.md finding 31.
	//
	// SO IT LEAVES BY THE DOOR THE MONEY IT WAS TAKEN FROM LEAVES BY: retireSponsorship
	// folds it back into Sponsored on the abandonment transition, and it is divided
	// among that week's unit holders with the rest. On a week that DOES draw it is not
	// folded and goes to ops with every other fee, which is the owner's rule for fees
	// generally — earned only if the draw actually runs.
	SponsorCut int64

	// SponsorPaid is the GROSS total of every Sponsor call on this week, and it is
	// what separates money with an owner from money without one.
	//
	// d.Sponsored MIXES TWO SOURCES AND ONLY ONE OF THEM HAS A PAYER. FundPot — the
	// duel's door — puts ownerless rake there, money attributable to no address.
	// Sponsor puts a named person's payment there. Until 2026-09-30 an abandoned week
	// treated both the same and divided them among unit holders, or sent them to the
	// house when there were no earned units. The owner ruled that out: a sponsor's
	// money is "either returned to sponsor or rolls over until a draw happens", and
	// rolling forward is what AUDIT-2026-09-28.md findings 28 and 31 removed, because
	// the caller picked the destination week by picking when to call. So it is
	// returned, and this is the figure that says how much of the pot is owed back.
	SponsorPaid int64

	// SponsorRefundable is what is left of SponsorPaid once the week has died and
	// before its sponsors have pulled it back. It is still sitting in d.Pot.
	SponsorRefundable int64

	// sponsorRefundedOf marks the addresses that have already pulled their refund, so
	// a second call pays nothing rather than paying twice.
	sponsorRefundedOf *avl.Tree

	// Sponsors is the credit line each sponsorship bought, in the order they were
	// bought, bounded by maxSponsorsPerWeek.
	//
	// THE TEXT IS A STRANGER'S AND IT IS PERMANENT. This is the first untrusted text
	// this realm has ever stored. NOTHING ESCAPES IT TODAY, and an earlier version of
	// this sentence claimed both ends did. checkSponsorLabel deliberately does not
	// sanitise — escaping belongs where the target syntax is known — and Render does
	// not yet emit this field at all.
	//
	// WHOEVER ADDS THAT DISPLAY MUST ESCAPE IT. Render builds a PIPE-DELIMITED
	// MARKDOWN TABLE; the label may legally hold '|', '[', ']', '<', '>' and
	// backticks, and 64 bytes is ample to forge extra cells and fake a column. Use the
	// duel's approach: sanitize.InlineText, plus escaping '|'. Flagged by the
	// 2026-09-30 audit, finding Y3.
	//
	// Escaping cannot strip CONTENT either way, and nothing can delete it
	// once written — a later realm version does not erase what an earlier one wrote.
	// The owner was told exactly that on 2026-09-30 and accepted it: "whatever, we can
	// always redeploy with 2.0 or whatever, it's a game".
	Sponsors []Sponsorship

	// ClaimPerUnit is the UGNOT EACH *EARNED* ENTRY UNIT OF THIS WEEK MAY RECLAIM from the
	// sponsorship this week's draw never got to pay out. ZERO ON EVERY LIVE WEEK and
	// written exactly once, by retireSponsorship, at the moment the week is abandoned.
	//
	// "EARNED" IS LOAD-BEARING AND THIS COMMENT SAID "EACH TICKET UNIT" UNTIL
	// AUDIT-2026-09-28.md finding 34 — so did the code. A BOUGHT unit contributed nothing to
	// the sponsorship and recovers its own money in full through Refund; an earned unit IS the
	// sponsorship, at 150,000 ugnot, and has no other route home. Dividing on both kinds paid
	// a refunded buyer out of the duel players' rake. Read Draw.earnedOf and
	// retireSponsorship.
	//
	// IT IS THE WHOLE OF finding 31's FIX AND IT IS A RATE, NOT A BALANCE. Writing one
	// number instead of one tree entry per holder is what keeps the abandonment transition
	// O(1): the transition happens inside Refund, which MUST NOT FAIL (a buyer is waiting),
	// and a loop over an unbounded holder set is a gas limit waiting to make a week's
	// refunds impossible — which would be a fresh "money in, no way out" path created by
	// the fix. A holder's claim is derived on demand in ClaimDeadWeek as
	// earnedOf[holder] * this, which is O(log N) and cannot be starved.
	//
	// IT IS A WHOLE NUMBER OF UGNOT PER EARNED UNIT, so the shares sum to
	// ClaimPerUnit * earnedTotal EXACTLY and never to more than the sponsorship. The
	// remainder — strictly less than the week's EARNED unit count, in ugnot, which is under
	// seven parts per million of the sponsorship — is dust with no
	// unit to attach to; retireSponsorship moves it to opsPot in the same statement and
	// records it in the event, so it is never left in a pot with no claim on it. Read that
	// function for the arithmetic, for the improved bound, and for why the alternatives (a
	// largest-remainder pass, or first-claimant-takes-the-dust) were rejected.
	//
	// NON-ZERO IMPLIES Abandoned, always, and AuditFailure re-derives that. An unabandoned
	// week can still sell tickets and still resolve, so a claim rate on one would be a
	// claim on a prize somebody is about to win.
	ClaimPerUnit int64

	// Claims is the UNCLAIMED part of what retireSponsorship distributed: it starts at
	// ClaimPerUnit * earnedTotal and falls by each holder's share as ClaimDeadWeek pays
	// it. IT IS PART OF Pot, exactly as Sponsored was, so no wugnot moved when it came into
	// existence and the realm's balance did not change.
	//
	// THE DIVISOR IN THAT PRODUCT WAS tickets.Total() UNTIL AUDIT-2026-09-28.md finding 34,
	// and the sum of every possible claim is EXACTLY this number under either basis — that was
	// never the defect. What was wrong is WHO the claimants were: bought units took a share of
	// money they had not contributed. Read Draw.earnedOf.
	//
	// IT IS A TERM IN BOTH SOLVENCY STATEMENTS. The per-week identity is
	//
	//	Pot + Cut == sum(spendOf) + Sponsored + Claims
	//
	// and the global one gains heldClaims. A field the realm holds money for and the
	// invariant does not mention is the shape of a hole — the same sentence Cut carries,
	// for the same reason.
	Claims int64

	// claimedOf is string(address) -> the amount that holder has already taken out of
	// Claims. AN ENTRY MEANS "PAID", so ClaimDeadWeek is all-or-nothing per holder and can
	// never pay twice: a holder's EARNED unit count cannot change after abandonment (an
	// abandoned week is always a past week, and FundPotWithEntries — the only writer of
	// earnedOf — only ever touches currentWeek()), so their share is a constant and one entry
	// settles it for ever.
	//
	// THE FROZEN-BASIS PROPERTY IS ENFORCED BY THREE PANICS AND NOT BY THIS SENTENCE, which
	// is the difference between this and finding 31's second attempt — that one rested on a
	// property asserted in a test and never enforced in code. The three, named so a future
	// reader knows they are load-bearing and not hygiene:
	//
	//  1. FundPot's refusal of a committed or abandoned week. It is the money path
	//     FundPotWithEntries calls before it appends anything, so no earned unit can ever
	//     reach a week that is already dead.
	//  2. retireSponsorship's "only an abandoned, unresolved week's sponsorship may be
	//     retired". The rate cannot be written before the week's exit is one-way.
	//  3. retireSponsorship's "that week's sponsorship has already been retired". The rate
	//     cannot be written twice, so it cannot be re-derived against a basis that has moved.
	//
	// TestFix34_ThreePanicsEnforceTheFrozenBasis names all three and drives each one.
	claimedOf *avl.Tree

	Committed   bool
	FrozenTotal int64 // ticket units at commit. NEVER recomputed at resolve.

	// Round is the beacon round this week is drawn on. WRITTEN EXACTLY ONCE, by
	// getOrCreateDraw, at the moment this record is created — which is before the
	// week's first ticket exists — and never written again by anything, Commit
	// included. Read pinOffsetRounds for why, and for what that does and does not
	// protect against; the one-sentence version is that the committer used to
	// choose this number after the ticket set was already frozen and public, which
	// handed the beacon's key holder a deterministic win.
	Round int64

	// CommittedAt is the CHAIN HEIGHT at which Commit froze this week, and it is
	// the only clock the refund grace window reads. Zero on an uncommitted week.
	//
	// IT IS STORED, AND IT CANNOT BE DERIVED FROM ANYTHING ELSE. The week number
	// comes from the same global clock, but a week may be committed at any time
	// after it ends (Commit takes the week as an argument precisely so a stranded
	// week is always recoverable), so "when was this week committed" is not a
	// function of which week it is. Round cannot stand in for it either: Round is
	// beacon state, and the whole point of this field is to give Refund a gate the
	// beacon cannot hold shut. See refundGraceBlocks.
	CommittedAt int64

	// Randomness is the round's randomness, copied in by Capture. Empty means "not
	// captured"; Resolve then reads the beacon directly. See Capture — and note that
	// since the drand migration this field is a convenience, not a rescue: the
	// beacon cannot lose a round, so nothing is preserved by copying it here.
	Randomness string

	Resolved bool
	Winner   address

	// Abandoned is set by the FIRST successful Refund for this week and is
	// never cleared by anything. It makes the week's exit one-way: once one
	// buyer has taken their money back, this week can never be resolved, and
	// every later refund proceeds without re-asking whether the draw looks
	// resolvable again.
	//
	// IT CANNOT BE DERIVED FROM THE BEACON, which is why it is stored — AND THE
	// DRAND MIGRATION MADE THAT MORE TRUE, NOT LESS. The old reason was that
	// resolvable() was not monotone: Publish had no window check and Prune removed a
	// round without moving latestRound, so a pruned round's Published() went back to
	// false and the same round could be published again, arbitrarily late. There is no
	// Prune now, so Published() IS monotone — but resolvable() is gone entirely and
	// a pinned round can be relayed by ANYONE, from drand, AT ANY TIME, FOR EVER. So a
	// week in refund would otherwise stay resolvable indefinitely, which is worse than
	// a window that occasionally reopened. Without this flag, anyone could let refunds
	// open on a
	// week, wait for some buyers to reclaim, then re-publish or late-publish the
	// round and Resolve — drawing over the ORIGINAL frozen range, so a buyer who
	// had already been refunded could win and collect what was left in the pot:
	// the money of the buyers who had not reclaimed yet. Someone holding the
	// signature did strictly better still, computing the winner first and then
	// choosing Refund if it was not them and publish-and-Resolve if it was. Pot
	// == sum(spends) held throughout, so neither checkInvariant nor AuditFailure
	// saw anything — the identity is sound, it is just blind to WHO is paid.
	Abandoned bool

	// tickets is the weighted ticket index for this week. ONE INDEX PER
	// PURCHASE is appended and no existing index's value is ever changed —
	// that immutability is the whole frozen-ownership argument on Commit.
	//
	// SINCE FINDING 15 A PURCHASE IS NOT THE ONLY THING THAT APPENDS ONE: an
	// earned entry credited through FundPotWithEntries appends exactly as a
	// purchase does, through the same appendTickets, and is indistinguishable
	// here by design. What distinguishes the two is spendOf, which an earned
	// entry does not touch. Nothing may ever INSERT or ADJUST an index — fenwick
	// refuses negative deltas by design and Commit's argument depends on it.
	tickets *fenwick.Tree

	// ownerOf is index -> string(address), the reverse lookup that turns a
	// drawn unit back into a winner. MANY INDICES MAP TO THE SAME ADDRESS and
	// that is expected: one entry per purchase.
	ownerOf *avl.Tree

	// ticketsOf is string(address) -> int64 ticket units, a read-side running
	// total so TicketsOf is O(log N) and never has to walk the index. It is
	// NOT read by the draw: Select and ownerOf decide the winner.
	//
	// IT IS NOT THE DEAD-WEEK CLAIM BASIS AND IT USED TO BE — AUDIT-2026-09-28.md finding
	// 34. It counts BOUGHT and EARNED units together, which is exactly right for the draw
	// (a unit is a unit, whoever paid for it, and that indistinguishability is finding 15's
	// whole design) and exactly wrong for dividing up a dead week's sponsorship. Read
	// earnedOf below for the arithmetic.
	ticketsOf *avl.Tree

	// earnedOf is string(address) -> int64 EARNED entry units: the subset of ticketsOf that
	// was credited by FundPotWithEntries rather than bought with Buy. IT IS THE BASIS ON
	// WHICH A DEAD WEEK'S SPONSORSHIP IS DIVIDED, and that is the whole of
	// AUDIT-2026-09-28.md finding 34.
	//
	// WHY THE DRAW AND THE CLAIM NEED DIFFERENT BASES, WHICH IS THE ONE THING WORTH
	// UNDERSTANDING HERE. Both kinds of unit are identical in the draw and must stay so.
	// They are NOT identical in what they contributed to the thing a dead week divides:
	//
	//	An EARNED unit put EntryUnitPrice * arcadeRakePotShareBps / arcadeBpsDenom =
	//	150,000 ugnot INTO Sponsored — it IS the sponsorship — and its holder can recover
	//	that money by no other route, because an earned entry has no spendOf record and
	//	Refund pays spendOf and nothing else.
	//
	//	A BOUGHT unit put NOTHING into Sponsored. It put TicketPrice / unitsPerTicket =
	//	250,000 ugnot into Pot and Cut, and its holder recovers THAT IN FULL through Refund
	//	— the whole gross, fee included, since finding 25.
	//
	// SO A REFUNDED BUYER ON AN ABANDONED WEEK ENDS WITH ZERO NET STAKE. Their money came
	// back entirely and they KEEP THEIR UNITS, deliberately (fenwick rejects negative deltas
	// by design, so a ticket cannot be retired once sold — see Refund). Dividing the
	// sponsorship on ticketsOf therefore handed that buyer a positive claim on the duel
	// players' rake for nothing at all: with equal counts of the two kinds, each player
	// recovered HALF of what their own rake contributed and a refunded buyer took the other
	// half. Paying those players is finding 31's entire stated purpose, so that was not a
	// rounding error in the fix, it was the fix missing its target.
	//
	// sum(earnedOf) == earnedTotal IDENTICALLY, and it is guaranteed the same way
	// sum(ticketsOf) == tickets.Total() is: appendEarnedTickets is the ONLY writer of either,
	// it writes both in one statement group from the same `units` argument, and nothing in
	// this file ever decrements or removes an entry. There is no second writer to drift from
	// the first. AuditFailure re-derives the sum by iteration anyway
	// (deadWeekClaimFailure), because an identity nothing re-derives is an identity nobody
	// finds out about.
	earnedOf *avl.Tree

	// earnedTotal is the sum of earnedOf — the O(1) counter that keeps the abandonment
	// transition constant-time. IT IS NOT tickets.Total() AND THE GAP IS THE BOUGHT UNITS:
	// 0 <= earnedTotal <= tickets.Total(), with equality exactly on a week where no ticket
	// was ever bought (the PURE-EARNED shape SweepDrawlessWeek calls shape 2).
	//
	// A SEPARATE COUNTER RATHER THAN AN ITERATION, for the same reason ClaimPerUnit is a rate
	// rather than a tree of balances: retireSponsorship runs inside Refund, Refund MUST NOT
	// FAIL, and a week's earned-holder set is unbounded (two more holders for every duel
	// played in the week). Reading a field is O(1); summing a tree is a gas ceiling on a
	// payout path. Read retireSponsorship.
	//
	// ZERO IS A REAL AND REACHABLE VALUE ON A WEEK WITH SPONSORSHIP: plain FundPot money from
	// any caller that is not the duel, a duel rake too small to buy one whole entry unit, or
	// a duel both of whose parties played from realm code. That money has no player behind
	// it, so retireSponsorship's no-claimant branch sends it to opsPot — the destination
	// nobody can choose. A week that has ever had an earned holder can never fall into that
	// branch, because this counter only ever increases.
	earnedTotal int64

	// spendOf is string(address) -> int64, the buyer's GROSS payment for this week's
	// tickets — the whole ticket price, house fee included — which is exactly what
	// Refund returns.
	//
	// IT WAS THE POST-CUT CONTRIBUTION UNTIL 2026-09-29 and the old comment said "the
	// house cut is not in here and is never refunded". BOTH HALVES OF THAT ARE NOW
	// FALSE and the sentence is corrected rather than removed, because it is the one a
	// reader will have in their head. The fee is escrowed in Cut for the week rather
	// than banked at sale time, so it IS part of what a buyer can reclaim; what a
	// refund returns is the gross, and the week's Pot and Cut are each decremented by
	// the part of that gross they received. AUDIT-2026-09-28.md finding 25.
	//
	// IT IS NOT A TICKET COUNT AND SINCE FINDING 15 THE DIFFERENCE IS REACHABLE.
	// An earned entry (FundPotWithEntries) adds ticket weight and NOTHING here,
	// so an address can hold tickets in a week with a zero spend, and a whole
	// week can have tickets and no spend records at all. That is intended: the
	// money behind those entries is in Sponsored, which no refund can return.
	// Refund reads this tree and only this tree.
	spendOf *avl.Tree
}

var (
	// draws is week -> *Draw. AN avl.Tree, NEVER A MAP: Render iterates it,
	// and a Go map's iteration order is deliberately randomised, which would
	// make this realm's rendered output non-deterministic and its audit
	// unreproducible.
	draws = avl.NewTree()

	// opsPot is the house's money this realm holds. It is wugnot this realm
	// holds, so it is a term in checkInvariant.
	//
	// THREE STREAMS FLOW IN, AND ALL THREE ARE NAMED HERE because until
	// 2026-09-28 this counter had no outflow at all and every one of them was
	// permanently unreachable — the realm's whole revenue included:
	//
	//   - the 5% house cut on every ticket sale (Buy),
	//   - every unsolicited wugnot arrival, swept so one stranger's transfer
	//     cannot brick the realm (sweepDonations),
	//   - a dead week's sponsorship, BUT ONLY IN THE ONE CASE WHERE IT PROVABLY HAS NO
	//     CLAIMANT, and the list of ways it can get here has shrunk twice. It used to
	//     arrive from Refund (finding 16), then only from ReclaimStrandedCarry's long stop
	//     (finding 28), and since finding 31 it arrives from retireSponsorship in exactly
	//     two shapes, both of which are stated at that function's two branches:
	//     A WEEK WITH SPONSORSHIP AND ZERO TICKET UNITS (a plain FundPot when the duel had
	//     no eligible holders, or a rake below one entry unit) — nobody holds a unit, so
	//     nobody is wronged; and THE SUB-UNIT DUST of a week that DOES have holders, which
	//     is strictly less than that week's unit count in ugnot and has no unit to attach
	//     to. A week that has holders can never route the WHOLE amount here: the branch is
	//     taken on tickets.Total() == 0 and nothing else.
	//
	// ONE FUNCTION FLOWS OUT: WithdrawOps, which pushes the whole of it to
	// opsVaultAddr and nowhere else. Where each stream GOES is a separate
	// decision from whether it can leave at all, and this comment deliberately
	// does not relitigate the first: Refund's and sweepDonations' destinations are
	// unchanged.
	opsPot int64

	// heldPots is the sum of Pot over every draw, maintained incrementally so
	// checkInvariant is O(1). Resolve zeroes a week's Pot, so a resolved week
	// contributes nothing and this is exactly "the sum of all unresolved week
	// pots". AuditFailure re-derives it by iteration so it cannot drift.
	heldPots int64

	// heldCuts is the sum of Cut over every draw — every week's ESCROWED, NOT YET
	// EARNED house fee — maintained incrementally for exactly the same reason heldPots
	// is, and re-derived by AuditFailure the same way.
	//
	// IT IS A THIRD TERM IN THE SOLVENCY EQUALITY AND ADDING IT IS WHAT MAKES THE
	// ESCROW SAFE. The fee is wugnot this realm holds, so before 2026-09-29 it was
	// counted by being inside opsPot. Moving it into the weeks without also moving it
	// into the invariant would have made checkInvariant's heldPots + opsPot == balance
	// fail on the very next Buy — which is the good direction for a bug, but the point
	// is that the equality must continue to state the WHOLE of what the realm holds. A
	// balance term the invariant does not mention is how money goes missing quietly.
	//
	// IT RISES IN Buy AND IN Sponsor, AND FALLS IN THREE PLACES — foldSponsorCut
	// being the third, added 2026-09-30. The sentence used to say it rose only in Buy and
	// fell in exactly two places: Resolve (the week's fee is
	// earned and moves to opsPot, so this falls by what opsPot gains and the balance
	// does not move) and Refund (the fee is returned to the buyer as part of their
	// gross, so this falls by that buyer's share and the balance falls with it).
	// Nothing else in the file touches it.
	heldCuts int64

	// heldSponsored is the sum of Sponsored over every UNRESOLVED draw — the
	// part of heldPots that belongs to no buyer. Maintained incrementally for
	// the same reason heldPots is: checkInvariant runs at the end of every
	// mutator and must not iterate the weeks, let alone each week's buyers, to
	// state the sponsorship half of the pot identity. AuditFailure re-derives it
	// by iteration, alongside the per-week identity itself, so it cannot drift.
	//
	// IT DROPS AT TWO PLACES AND ONLY TWO SINCE FINDING 31: Resolve (the whole pot,
	// sponsored part included, leaves for the winner) and retireSponsorship (the week is
	// abandoned, so the sponsorship stops being sponsorship and becomes either this week's
	// holders' claims or — with no holders — ops money). Note that a resolved week KEEPS
	// its Draw.Sponsored as a record of what its prize was made of, which is why this
	// counter is over unresolved weeks only, exactly as spendOf is read for unresolved
	// weeks only.
	//
	// THE LIST HAS ONLY EVER GOT SHORTER AND THAT IS THE POINT. It was Refund-and-Sweep
	// (two destinations that disagreed, finding 16), then Refund-and-Sweep-into-currentWeek
	// (one destination the caller chose, finding 28), then
	// ReclaimStrandedCarry-and-absorbCarryPending (a register that still had a destination
	// and could still be aimed, finding 31). It is now a field that is zeroed where it
	// stands.
	heldSponsored int64

	// heldClaims is the sum of Claims over every UNRESOLVED draw — the part of heldPots
	// that a dead week's unit holders have not taken out yet. Maintained incrementally for
	// exactly the reason heldPots and heldSponsored are, and re-derived by AuditFailure the
	// same way.
	//
	// IT IS A FOURTH CLAIM TERM AND IT REPLACES A REGISTER. carryPending, which this
	// replaces, deliberately held NO money and added NO term — the money stayed in the dead
	// week's Sponsored and the register only named it. That was the shape that made finding
	// 31 possible: the money was still pending, still movable, and still had somewhere to
	// go. This is the opposite trade — one more term in both solvency statements, in
	// exchange for money that is already sitting on the exact addresses entitled to it and
	// has nowhere left to travel.
	//
	// IT RISES ONLY IN retireSponsorship AND FALLS ONLY IN ClaimDeadWeek. Nothing else in
	// the file touches it.
	heldClaims int64

	// heldSponsorRefunds is the sum of SponsorRefundable over every unresolved draw —
	// the part of heldPots that is owed back to named sponsors of dead weeks and is
	// waiting to be pulled. Tracked for the same reason heldClaims is: so the realm
	// can say, without iterating, how much of what it holds already has an owner.
	heldSponsorRefunds int64

	// launchHeight is the chain height at deploy, so week numbers start at 0
	// for this realm rather than at some arbitrary point in chain history.
	launchHeight int64
)

func init() {
	launchHeight = runtime.ChainHeight()
}

// realmSelf is this realm's own address, resolved ONCE at package
// initialisation and never recomputed.
//
// WHY NOT CALL unsafe.CurrentRealm() PER USE: CurrentRealm resolves against
// whatever frame is executing. Inside a crossing entrypoint that is this realm,
// which is correct — but Render and the audit reads are deliberately NOT
// crossing functions (anyone must be able to read them), so when they are
// called directly the "current realm" is the caller and BalanceOf(selfAddr())
// would silently read the CALLER'S wallet. r/splash/game learned this the hard
// way; the fix is to resolve the address once, since it is constant for the
// life of the realm.
var realmSelf = unsafe.CurrentRealm().Address()

func selfAddr() address {
	return realmSelf
}

// --- keys ----------------------------------------------------------------

// keyWidth is enough decimal digits for any non-negative int64 (max is
// 9223372036854775807, 19 digits). Keys are fixed-width and zero-padded so
// that avl.Tree's lexicographic order matches numeric order — the same
// convention as r/splash/beacon's roundKey, and the reason Render lists weeks
// as 1, 2, ... 10 rather than 1, 10, 2.
const keyWidth = 19

const zeroPad = "0000000000000000000"

func pad(s string) string {
	if len(s) < keyWidth {
		return zeroPad[:keyWidth-len(s)] + s
	}
	return s
}

func weekKey(week int64) string { return pad(strconv.FormatInt(week, 10)) }

func indexKey(i int) string { return pad(strconv.Itoa(i)) }

// --- clock ---------------------------------------------------------------

// currentDay is the single global clock this realm reads — never a per-ticket
// one. See blocksPerDay.
func currentDay() int64 {
	h := runtime.ChainHeight() - launchHeight
	if h < 0 {
		h = 0
	}
	return h / blocksPerDay
}

// currentWeek is the week tickets are being sold into right now.
func currentWeek() int64 {
	return currentDay() / raffleWeekDays
}

// weekEndHeight is the chain height at which a week stops being the live one — the
// first height of week+1. Derived from the same two constants and the same
// launchHeight currentWeek reads, so the two clocks can never disagree.
//
// IT EXISTS FOR ONE GATE: the ticketless sweep shape, which has no CommittedAt to
// count from (such a week can never be committed) and therefore cannot use
// refundGraceElapsed. Read SweepDrawlessWeek's shape-1 clock for why that gate is
// there at all — in one line, a sweep that is free and instant the moment a week ends
// is a sweep that can be repeated week after week, and finding 28's chain was built
// out of exactly that repeat.
//
// NO OVERFLOW: week here is always a week this realm has a record for, so it is
// bounded by the chain's own height divided by a week of blocks.
func weekEndHeight(week int64) int64 {
	return launchHeight + (week+1)*raffleWeekDays*blocksPerDay
}

// --- arithmetic ----------------------------------------------------------

// mulDiv returns floor(a*b/d) via a 128-bit intermediate product. Raw a*b/d on
// token-scale quantities wraps silently on the GnoVM (see
// ../../../../tools/muldiv_probe.gno) instead of panicking, so every split in
// this realm goes through here.
func mulDiv(a, b, d uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	if d == 0 {
		panic("raffle: mulDiv: division by zero")
	}
	if hi >= d {
		panic("raffle: mulDiv: overflow")
	}
	q, _ := bits.Div64(hi, lo, d)
	return q
}

// maxInt64 as a uint64, for the overflow guard below.
const maxInt64 = uint64(1)<<63 - 1

// ticketCost is tickets * TicketPrice, GUARDED AGAINST int64 OVERFLOW.
//
// A raw multiplication here is the classic money bug: on the GnoVM an int64
// product wraps silently, so a caller passing a large enough ticket count
// would buy an enormous number of ticket units for a small — or negative —
// cost. The product is therefore taken in 128 bits (the same bits.Mul64 path
// as mulDiv) and REJECTED unless it fits in an int64: the high word must be
// zero AND the low word must be within int64 range, because hi == 0 alone
// still admits values above 2^63-1 that would land negative.
func ticketCost(tickets int64) int64 {
	if tickets <= 0 {
		panic("raffle: ticket count must be positive")
	}
	hi, lo := bits.Mul64(uint64(tickets), uint64(TicketPrice))
	if hi != 0 || lo > maxInt64 {
		panic("raffle: ticket count overflows int64 ugnot")
	}
	return int64(lo)
}

// hexDigit decodes one lowercase-or-uppercase hex character.
func hexDigit(c byte) (uint64, bool) {
	switch {
	case c >= '0' && c <= '9':
		return uint64(c - '0'), true
	case c >= 'a' && c <= 'f':
		return uint64(c-'a') + 10, true
	case c >= 'A' && c <= 'F':
		return uint64(c-'A') + 10, true
	}
	return 0, false
}

// randomnessMod reduces a 256-bit hex randomness string modulo m, which gives
// the draw's winning ticket unit. Verbatim in behaviour from
// r/splash/game/raffle.gno, for the reasons stated there:
//
// The randomness is 256 bits; an int64 holds 63. Any truncation (taking the
// first or last 16 hex digits, say) throws away most of the beacon's entropy
// and does it in a way an attacker can reason about. math/big does not exist on
// this toolchain, so the reduction is schoolbook: fold four bits at a time,
// reducing as we go. The intermediate r*16 + digit does NOT fit in 64 bits when
// m is near the int64 maximum, so it goes through the 128-bit path rather than
// wrapping. `hi %= um` before the divide is required by bits.Div64 (which
// panics unless the high word is smaller than the divisor) and is sound because
// hi*2^64 == (hi mod m)*2^64 (mod m).
func randomnessMod(randomness string, m int64) int64 {
	if m <= 0 {
		panic("raffle: randomness modulus must be positive")
	}
	if len(randomness) == 0 {
		panic("raffle: empty randomness")
	}
	um := uint64(m)
	r := uint64(0)
	for i := 0; i < len(randomness); i++ {
		d, ok := hexDigit(randomness[i])
		if !ok {
			panic("raffle: beacon randomness is not hex")
		}
		hi, lo := bits.Mul64(r, 16)
		if lo > ^uint64(0)-d {
			hi++
		}
		lo += d
		hi %= um
		_, r = bits.Div64(hi, lo, um)
	}
	return int64(r)
}

// --- week records --------------------------------------------------------

// getDraw returns the draw for week, or nil. avl's Get returns a SINGLE value
// and existence is a separate Has, so the check comes first — otherwise a
// missing week type-asserts nil and panics with avl's message rather than this
// realm's.
func getDraw(week int64) *Draw {
	key := weekKey(week)
	if !draws.Has(key) {
		return nil
	}
	return draws.Get(key).(*Draw)
}

// getOrCreateDraw returns the week's draw, creating an empty one if needed.
// Called only AFTER a sale's money has moved, so a rejected Buy never leaves an
// empty record behind — which matters, because "this week has no tickets" is
// one of Commit's refusals and an empty husk must not look like a live week.
//
// THIS IS WHERE THE WEEK'S BEACON ROUND IS PINNED, AND IT IS THE ONLY WRITER OF
// Draw.Round IN THIS FILE. It is here, rather than in Buy and FundPot separately,
// so that the pin happens EXACTLY ONCE per week whichever of them opens the week —
// a second pin would be a second choice, and choice is the whole defect. Read
// pinOffsetRounds for the attack this closes, for the derivation of the offset, and
// for the part of the problem it deliberately does not close.
//
// IT NEEDS THE BEACON TO HAVE PUBLISHED AT LEAST ONCE, because beacon.Latest() is
// the only anchor a realm has on the round counter. On a chain where the beacon has
// never published a round, beacon.Latest() panics with its own message and the sale
// or sponsorship is REFUSED. That is the safe direction and is strictly better than
// what it replaces: before the pin, such a Buy succeeded, and the week could then
// never be committed (Commit's own beacon.Latest() panicked), never resolved and
// never refunded — Refund requires Committed — so the money entered a week no path
// in the realm could ever empty. Refusing the sale keeps the money in the buyer's
// wallet instead. The refusal happens after the wugnot pull inside Buy, which is
// harmless: a panic reverts the whole transaction, exactly as checkInvariant's
// panics already rely on.
func getOrCreateDraw(week int64) *Draw {
	if d := getDraw(week); d != nil {
		return d
	}
	// THE ANCHOR IS THE BEACON'S ESTIMATE OF THE CURRENT ROUND, NOT ITS HIGHEST
	// PUBLISHED ONE. beacon.Latest() is whatever somebody last had a reason to
	// relay, which under an on-demand record is arbitrarily stale, and pinning
	// against a stale anchor puts the week's randomness on drand's public API
	// BEFORE sales close — AUDIT-2026-09-28.md finding 10's last-buyer attack. One
	// day of staleness is enough. Read pinOffsetRounds in full before changing this
	// line. EstimatedLatestRound panics if no round has ever been published, which
	// is the deliberate refusal described below.
	//
	// AND IT NOW ALSO PANICS IF NOBODY HAS RELAYED A ROUND THAT RAISED THE BEACON'S
	// ANCHOR WITHIN beacon.MaxEstimateStaleBlocks — one day of blocks. THAT REFUSAL IS
	// LOAD-BEARING FOR THIS REALM AND IS NOT A COST IT MERELY TOLERATES: without it the
	// anchor's error is unbounded in both directions, which is finding 10 in the lagging
	// direction and a permanently unresolvable week in the drifting one. The price is that
	// OPENING A WEEK needs a beacon relayed within the last day — one Publish per week,
	// permissionless, by whoever wants the week open, alongside the one that already has
	// to happen to resolve it. Read pinOffsetRounds' residual-error section and
	// beacon.maxEstimateStaleBlocks.
	anchor := beacon.EstimatedLatestRound()
	if anchor > maxPinnableLatest {
		// Loud rather than pinning a wrapped, negative round nobody could ever
		// publish. drand cannot sign a round anywhere near the int64 maximum so
		// this is now unreachable in practice; see maxPinnableLatest.
		panic("raffle: the beacon's latest round is too high to pin a future round against")
	}
	d := &Draw{
		Week: week,
		// THE PIN. Never recomputed, never rebound — not by a later Buy, not by
		// FundPot, and above all not by Commit.
		Round:     anchor + pinOffsetRounds,
		tickets:   fenwick.NewTree(),
		ownerOf:   avl.NewTree(),
		ticketsOf: avl.NewTree(),
		earnedOf:  avl.NewTree(),
		spendOf:   avl.NewTree(),
		claimedOf: avl.NewTree(),
	}
	draws.Set(weekKey(week), d)

	// EMITTED SO THE PIN IS AUDITABLE FROM THE BLOCK LOG ALONE. The whole security
	// argument is "this number was fixed before the ticket set existed", and that is
	// a statement about WHEN it was written — which no later read of the realm's
	// state can establish on its own. The height is included for the same reason.
	chain.Emit("PinRound",
		"week", strconv.FormatInt(week, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"beaconAnchor", strconv.FormatInt(anchor, 10),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10))

	// THIS FUNCTION NO LONGER MOVES ANY OTHER WEEK'S MONEY — AUDIT-2026-09-28.md finding
	// 31, and the four lines that stood here are recorded because the reader who comes
	// looking for them needs to know they were not merely tidied away:
	//
	//	if week == currentWeek() {
	//		absorbCarryPending(d)
	//	}
	//
	// WHAT THEY DID AND WHY THEY WERE WRONG. Finding 28 had made a dead week's sponsorship
	// PENDING in a register (carryPending) instead of being pushed into a week a caller
	// named, and this branch was the PULL: the week being born absorbed every pending
	// carry. The safety of that rested entirely on the destination being YOUNG, so that no
	// attacker could be its only entrant — and THAT PROPERTY WAS ASSERTED IN A TEST AND
	// NEVER ENFORCED HERE. The exploit needed only public entry points: wait for a live
	// week with no Draw record (the same realm-quietness that makes carries accumulate in
	// the first place), call Buy(1) at weekEndHeight(W) - 1, and this branch absorbed every
	// pending carry into a week whose entire ticket set was the attacker's 40 units. The
	// week then closed — Buy only sells into currentWeek() — so Commit and Resolve paid
	// them the whole carry plus their own stake back less the cut. Cost 500,000 ugnot, gain
	// the entire carry, win probability 1. Strictly worse than the pushed destination it
	// replaced, which at least forced the attacker to share a pot they had diluted.
	//
	// AND DELETING IT IS A WIN IN ITS OWN RIGHT, SEPARATELY FROM THE EXPLOIT. This branch
	// put a PANIC on the buyer's and the duel's rake-delivery path: absorbCarryPending's
	// consistency assertion fired inside Buy, FundPot and FlushPot, so a register that had
	// drifted for any reason would refuse ticket sales and refuse the duel's rake. Opening
	// a week now touches nothing but the week being opened.
	return d
}

// retireSponsorship turns a dead week's sponsorship into a claim held BY THE PEOPLE WHO
// EARNED ENTRIES IN THAT SAME WEEK. It is the whole of AUDIT-2026-09-28.md finding 31's fix and
// the ONE statement that is worth making about it is that IT HAS NO DESTINATION: nothing
// here takes a week as a parameter, reads currentWeek(), reads the beacon, or looks at any
// Draw but the one it is given.
//
// WHY THAT IS THE FIX RATHER THAN A BETTER-CHOSEN DESTINATION. Three designs in three days
// each moved this money somewhere: to opsPot (finding 16 — the house was the party best
// placed to trigger the move and the party that received it), to currentWeek() (finding 28
// — a destination evaluated at call time is a destination the caller chooses), and into the
// next week to be created (finding 31 — the caller creates that week, with one Buy, and can
// be its only entrant). THE COMMON FACTOR IS NOT WHICH DESTINATION WAS PICKED, IT IS THAT
// THERE WAS ONE. This money came from the duel players whose rake it is; giving it back to
// them, pro rata, in the week it is already in, leaves nothing for anybody to aim.
//
// AND "THEM" IS THE EARNED-ENTRY HOLDERS, NOT EVERY UNIT HOLDER — AUDIT-2026-09-28.md
// finding 34. THE SENTENCE ABOVE SAID THE WRONG THING FOR ONE DAY and the code divided on
// d.tickets.Total() to match it. The retired text, because it is the defect stated out loud:
//
//	"This money came from the duel players whose rake it is AND FROM THE BUYERS WHO BOUGHT
//	INTO THIS WEEK; giving it back to them, pro rata, in the week it is already in, leaves
//	nothing for anybody to aim."
//
// THE TWO UNIT KINDS DID NOT CONTRIBUTE EQUALLY TO THE THING BEING DIVIDED, so "pro rata"
// over both of them divided it on the wrong basis:
//
//	An EARNED unit PUT 150,000 ugnot INTO Sponsored — EntryUnitPrice scaled by the duel's
//	players' share, arcadeRakePotShareBps/arcadeBpsDenom — and IT IS the sponsorship. Its
//	holder can recover that money by no other route at all, because an earned entry has no
//	spendOf record and Refund pays spendOf and nothing else.
//
//	A BOUGHT unit PUT NOTHING INTO Sponsored. It put 250,000 ugnot into Pot and Cut, and its
//	holder recovers THAT IN FULL through Refund — the whole gross, fee included (finding 25).
//
// SO A REFUNDED BUYER ENDS AN ABANDONED WEEK WITH ZERO NET STAKE AND, UNDER THE OLD BASIS, A
// POSITIVE CLAIM ON THE DUEL PLAYERS' RAKE. They keep their units deliberately — fenwick
// refuses negative deltas by design, so a ticket cannot be retired once sold (see Refund) —
// so the refund returns every ugnot they paid AND leaves their share of somebody else's money
// standing. With equal counts of the two kinds, each duel player recovered HALF of what their
// own rake contributed and a buyer took the other half for nothing. Paying those players is
// finding 31's entire stated purpose, so this was not a rounding error in that fix: it was
// that fix missing its target.
//
// THE DRAW'S BASIS IS UNTOUCHED AND MUST STAY SO. tickets.Total(), ticketsOf, ownerOf and
// FrozenTotal still count both kinds identically, because a unit is a unit in the draw
// whoever paid for it — that indistinguishability is finding 15's design and the earned
// entry's whole point. Only the CLAIM has a second basis. Read Draw.earnedOf.
//
// PURE BOOKKEEPING: NO WUGNOT MOVES. The tokens have been inside this realm since FundPot
// pulled them in. Sponsored falls, Claims rises by the same amount less the dust, and the
// dust is reclassified from a pot to opsPot — both of which the realm already holds.
//
// IT IS O(1) AND THAT IS LOAD-BEARING, NOT AN OPTIMISATION. Its main caller is Refund's
// abandonment transition, and Refund MUST NOT FAIL: a buyer is waiting for their own money,
// so a path that can be made too expensive to execute is a "money in, no way out" defect
// wearing a gas limit. The obvious implementation — walk earnedOf and add each holder's
// share to a tree — is O(number of earned holders), and that set is unbounded (every
// duel played in the week appends two through FundPotWithEntries). One rate is written
// instead, and ClaimDeadWeek derives a holder's share from it in O(log N).
//
// FINDING 34 DID NOT COST THAT PROPERTY AND COULD NOT BE ALLOWED TO. Changing the basis from
// tickets.Total() to earnedTotal is ONE FIELD READ FOR ANOTHER: both are O(1) counters
// maintained incrementally by their single writer (fenwick's total, and appendEarnedTickets
// respectively). This function reads no tree, iterates nothing, and its statement count is
// unchanged. The ten-holder gas twins exist so that a reintroduced loop shows up as a number
// rather than as a review comment.
//
// THE TWO CASES ARE NAMED HERE AND AT EVERY CALL SITE, and the branch between them is
// earnedTotal and nothing else — IT WAS tickets.Total() UNTIL finding 34:
//
//   - THERE ARE EARNED HOLDERS (earnedTotal > 0). The money is theirs, and theirs alone:
//     every ugnot except the sub-unit dust becomes claimable in proportion to EARNED weight.
//     A buyer's bought weight is worth nothing here, because it contributed nothing here and
//     Refund gives it back in full.
//   - THERE ARE NO EARNED HOLDERS AT ALL (earnedTotal == 0). This is reachable and real, and
//     it is now the WIDER branch of the two: a plain FundPot from any caller that is not the
//     duel (into a week nobody entered OR into a week full of buyers), a duel flush whose
//     rake was below one entry unit, or a duel both of whose parties played from realm code.
//     That money PROVABLY HAS NO PLAYER BEHIND IT — no address earned a unit of this week —
//     so it goes to opsPot, the destination nobody can choose, and nobody is wronged. Note
//     what this branch does NOT do: it does not hand plain house money to the week's buyers,
//     who paid nothing towards it and get their own gross back regardless.
//     A WEEK WITH EARNED HOLDERS CAN NEVER FALL INTO THIS BRANCH: earnedTotal is
//     monotonically non-decreasing (appendEarnedTickets only ever adds, and nothing in this
//     file decrements or removes an earnedOf entry), so a week that has ever had one earned
//     unit has a positive earnedTotal for ever.
//
// THE DUST, EXPLICITLY, BECAUSE THE IDENTITY MUST HOLD EXACTLY AND NOT APPROXIMATELY.
// perUnit is floor(Sponsored / earnedTotal), so the shares sum to perUnit * earnedTotal, which
// is Sponsored - dust where 0 <= dust < earnedTotal. That dust has NO UNIT TO ATTACH TO: it is
// strictly smaller than one ugnot per earned unit, so there is no holder it could be given a
// share of without giving some holder more per unit than another. IT GOES TO opsPot IN THIS
// SAME STATEMENT and is reported in the event, so it is never left sitting in a pot with no
// claim on it and it CANNOT ACCUMULATE — there is exactly one retirement per week, for ever
// (Abandoned is one-way and this function refuses a second run).
//
// THE BOUND IMPROVED BY TWO ORDERS OF MAGNITUDE AS A SIDE EFFECT OF finding 34, AND THE
// ARITHMETIC IS WORTH WRITING OUT BECAUSE THE OLD BOUND WAS STATED AGAINST THE WRONG
// QUANTITY. It was "bounded above by the week's unit count in ugnot: 40 ugnot per
// ticket-equivalent against a 10,000,000 ugnot ticket, so at most four parts per million of a
// week's SALES" — a fraction of the sales, which have nothing to do with the sponsorship being
// divided. As a fraction of the money actually at stake it was unbounded:
//
//	1,000 tickets sold (40,000 bought units) and one rung-1 duel's rake of 1,800,000 ugnot
//	(12 earned units). Old divisor 40,012: perUnit = 44, distributed 1,760,528, DUST 39,472
//	— 2.2% of the players' rake to the house. New divisor 12: perUnit = 150,000,
//	distributed 1,800,000, DUST ZERO.
//
// THE NEW BOUND IS A FRACTION OF THE SPONSORSHIP ITSELF AND IS INDEPENDENT OF TICKET SALES:
//
//	dust < earnedTotal, and arcadeEntryUnitsBound caps every delivery at
//	units <= floor(floor(amount * arcadeBpsDenom / arcadeRakePotShareBps) / EntryUnitPrice)
//	<= amount * (10000/6000) / 250000 = amount / 150,000, which sums over deliveries to
//	earnedTotal <= Sponsored / 150,000.
//
//	So dust < Sponsored / 150,000: STRICTLY UNDER SEVEN PARTS PER MILLION of the amount
//	being retired, against 2.2% of it in the worked example above.
//
// AND THE SAME INEQUALITY MAKES perUnit >= 150,000 WHENEVER earnedTotal > 0, since
// Sponsored >= 150,000 * earnedTotal. So the "the whole amount was sub-unit dust" state —
// perUnit == 0 on a week that HAS holders — IS NO LONGER REACHABLE through the duel. THE CODE
// FOR IT IS KEPT ANYWAY AND IS NOT CONVERTED INTO AN ASSERTION, deliberately, for the reason
// that governs this whole function: a panic here is a panic inside Refund. Plain FundPot
// money can be any size and arcadeEntryUnitsBound is a constant somebody may retune, so an
// assertion would trade a bounded, already-handled rounding case for a buyer who cannot
// reclaim their own ticket money. Handle it, do not assert it. ClaimDeadWeek's
// "no dead-week share to claim" names the state for a caller either way.
//
// THE TWO ALTERNATIVES AND WHY NOT. A LARGEST-REMAINDER OR RUNNING-CUMULATIVE PASS
// distributes the dust exactly and leaves nothing for the house, but it is the O(holders)
// loop this function exists to avoid. GIVING THE DUST TO THE FIRST CLAIMANT keeps it with
// the players but makes it a RACE for a caller-chosen benefit, which is the exact shape of
// the three defects above, at a tiny scale — and this realm has now been wrong twice by
// accepting a small choosable benefit. opsPot is the destination nobody can choose.
//
// Panics, defensively, if the week is not in the state its two callers guarantee.
// foldSponsorCut turns a week's escrowed SPONSOR fee back into sponsorship.
//
// IDEMPOTENT, AND CALLED FROM BOTH EXITS A DEAD WEEK HAS. retireSponsorship runs
// it for the Refund path; SweepDrawlessWeek runs it BEFORE its own assertions,
// because one of those assertions is "a swept week holds no escrowed fee" and a
// sponsorship is the one way a fee can be present with no ticket sale behind it.
// Leaving the fold until after that check was a REAL DEFECT and not a tidiness
// one: the assertion fired, the sweep was the only exit a ticketless week has,
// and the whole week's pot — including unrelated duel rake — was stranded with
// AuditFailure reporting green over it. Found by the 2026-09-30 audit, R1.
//
// IT MOVES BETWEEN TWO TRACKED TOTALS AND CREATES NOTHING: heldCuts falls by
// exactly what heldPots rises by, so heldPots + heldCuts + opsPot is untouched.
func foldSponsorCut(d *Draw) {
	c := d.SponsorCut
	if c <= 0 {
		return
	}
	d.SponsorCut = 0
	d.Cut -= c
	heldCuts -= c
	d.Pot += c
	d.Sponsored += c
	heldPots += c
	heldSponsored += c
	if d.Cut < 0 {
		panic("raffle: retiring the sponsors' fee would overdraw the week's escrowed fee")
	}
}

func retireSponsorship(d *Draw) {
	// THE SPONSORS' FEE NEVER BECAME THE HOUSE'S, BECAUSE THE DRAW NEVER RAN. Fold it
	// back into the sponsorship it was taken from, so it leaves by the same door as
	// the rest of that money. Read Draw.SponsorCut for why it cannot leave by Refund's
	// door instead: Refund retires a fee it RE-DERIVES from a buyer's spendOf, and a
	// sponsor has no spendOf to derive one from.
	//
	// BEFORE THE REFUSALS BELOW ON PURPOSE, AND SAFE THERE: a panic reverts every
	// write in the transaction, so a fold followed by a refusal leaves nothing behind.
	// Putting it first means the guards see the folded figures and cannot be satisfied
	// by a state this function is about to change.
	//
	// IT MOVES BETWEEN TWO TRACKED TOTALS AND CREATES NOTHING: heldCuts falls by
	// exactly what heldPots rises by, so heldPots + heldCuts + opsPot is untouched.
	foldSponsorCut(d)

	s := d.Sponsored
	if s <= 0 {
		// Both callers test this before calling; a zero here would mean writing a claim
		// rate of zero over a week and emitting an event about nothing.
		panic("raffle: that week holds no sponsorship to retire")
	}
	if d.Resolved || !d.Abandoned {
		// Unreachable: both callers set Abandoned in the statement above the call, and a
		// week in refund or swept can never be resolved. Loud, because this function
		// stops money being refundable-as-sponsorship and starts it being claimable, and
		// doing that to a live week would take a prize away from a winner.
		panic("raffle: only an abandoned, unresolved week's sponsorship may be retired")
	}
	// d.SponsorRefundable JOINS THIS GUARD because the early-return shape — a week
	// whose whole sponsorship had a payer — leaves ClaimPerUnit and Claims at zero,
	// so the two fields below do not witness that retirement at all. Without this the
	// only thing standing between a second retirement and a doubled
	// heldSponsorRefunds would be the s <= 0 panic above, whose message describes a
	// different condition. 2026-09-30 audit, Y2.
	if d.ClaimPerUnit != 0 || d.Claims != 0 || d.SponsorRefundable != 0 {
		// Unreachable: Abandoned is one-way, Refund's transition is inside !d.Abandoned
		// and SweepDrawlessWeek refuses an abandoned week outright. Loud rather than
		// overwriting a rate holders have already been paid against.
		panic("raffle: that week's sponsorship has already been retired")
	}

	// THE EARNED UNIT TOTAL IS THE BASIS, NOT THE WEEK'S WHOLE UNIT TOTAL —
	// AUDIT-2026-09-28.md finding 34. This line read `total := d.tickets.Total()`, which
	// counted bought units alongside earned ones and so paid a refunded buyer out of the duel
	// players' rake. Read the block above for the arithmetic and Draw.earnedOf for the two
	// unit kinds. IT IS STILL ONE FIELD READ: the O(1) promise this function's whole shape
	// rests on is unaffected.
	total := d.earnedTotal
	if total < 0 || total > d.tickets.Total() {
		// Unreachable by construction: appendEarnedTickets is the only writer of earnedTotal
		// and it calls appendTickets in the same statement group, so every earned unit is also
		// a ticket unit and neither counter is ever decremented. Loud rather than dividing a
		// real balance by a counter that has drifted from the tree ClaimDeadWeek will pay
		// against — that is the one way the claim sum could stop being exact.
		panic("raffle: that week's earned unit total is not a subset of its ticket units")
	}
	// THE SPONSORS' MONEY IS CARVED OUT FIRST AND NEVER REACHES EITHER BRANCH BELOW.
	// Both of them dispose of money that has no payer — the duel's ownerless rake —
	// by dividing it among unit holders, or by sending it to the house when there are
	// no earned units. A sponsor's payment HAS a payer, and the owner ruled on
	// 2026-09-30 that it goes back to them rather than to either destination. So it
	// leaves d.Sponsored here, stays in d.Pot, and waits to be pulled.
	//
	// A PULL AND NOT A PUSH, deliberately: paying up to maxSponsorsPerWeek addresses
	// inside this function would put every one of those transfers on the critical
	// path of a buyer's own Refund, and one failing recipient would block the week.
	// ClaimSponsorRefund is the door; it is the same shape as ClaimDeadWeek.
	// A NOTE FOR THE DUST ARGUMENT ABOVE, WHICH IS STATED AGAINST d.Sponsored AND IS
	// NOW APPLIED TO s. The bound still holds, and it is worth one line saying WHY
	// rather than leaving the next reader to re-derive it: sponsor money buys no
	// entry units, so every earned unit was paid for out of the duel's rake alone.
	// F >= 150,000 * earnedTotal independently of anything a sponsor put in, and F is
	// exactly what survives the carve-out. 2026-09-30 audit, Y5.
	refundable := d.SponsorPaid
	if refundable > s {
		// Unreachable: foldSponsorCut has already returned the sponsors' fee to
		// Sponsored, so gross is fully inside s. Asserted because if it ever stopped
		// being true the carve-out would take money belonging to the duel's rake.
		panic("raffle: a week owes its sponsors more than the sponsorship it holds")
	}
	d.SponsorRefundable = refundable
	heldSponsorRefunds += refundable
	s -= refundable

	// heldSponsored falls by the WHOLE original figure, refundable part included:
	// none of it is sponsorship any more. The refundable part is now tracked by
	// heldSponsorRefunds instead, and both are subsets of heldPots, so the global
	// three-term equality is untouched and the ceiling below still holds.
	d.Sponsored = 0
	heldSponsored -= refundable + s

	if s == 0 {
		// EVERY UGNOT OF IT HAD A PAYER. Nothing is left for either branch below to
		// dispose of, and dividing zero among holders or sending zero to the house
		// would just be noise in the event log.
		chain.Emit("DeadWeekSponsorshipRefundable",
			"week", strconv.FormatInt(d.Week, 10),
			"owedToSponsors", strconv.FormatInt(refundable, 10),
			"ownerlessRake", "0",
			"height", strconv.FormatInt(runtime.ChainHeight(), 10))
		return
	}

	if total == 0 {
		// THE NO-CLAIMANT CASE, stated at the site as the doctrine demands. NO ADDRESS EARNED
		// A UNIT of this week, so no player is behind this money: there is no pro-rata share
		// to compute and no person whose money it is. The week may well have BUYERS — since
		// finding 34 that is the common shape of this branch, a plain FundPot into a week
		// with ticket sales — and they are not the claimants: they paid nothing towards this
		// amount and Refund returns their own gross in full regardless.
		d.Pot -= s
		heldPots -= s
		opsPot += s
		if d.Pot < 0 {
			// AUDIT-2026-09-28.md finding 35. Unreachable while
			// Pot + Cut == sum(spendOf) + Sponsored + Claims holds, because s is this week's
			// whole Sponsored term and the pot contains it by that identity. It is asserted
			// because THIS WAS THE ONE MONEY MOVER IN THE FILE WITHOUT THE GUARD: Refund
			// (twice) and ClaimDeadWeek all state it, and checkInvariant cannot stand in for
			// it — that checks the AGGREGATE heldPots, so a negative pot here could be masked
			// by a compensating positive pot on another week. Only AuditFailure's per-week
			// identity would see it, and AuditFailure never runs on a state-changing path.
			panic("raffle: retiring that week's sponsorship would overdraw its pot")
		}
		chain.Emit("DeadWeekSponsorshipToOps",
			"week", strconv.FormatInt(d.Week, 10),
			"amount", strconv.FormatInt(s, 10),
			"reason", "no earned-entry holders",
			"tickets", strconv.FormatInt(d.tickets.Total(), 10),
			"pot", strconv.FormatInt(d.Pot, 10),
			"height", strconv.FormatInt(runtime.ChainHeight(), 10))
		return
	}

	// THE CLAIMANT CASE. These are the duel players whose rake this is, and ONLY them: their
	// earned units ARE the sponsorship, at 150,000 ugnot each.
	perUnit := s / total
	distributed := perUnit * total
	dust := s - distributed
	if dust < 0 || dust >= total {
		// Unreachable by the definition of integer division. Stated because the whole
		// exactness argument is this one line.
		panic("raffle: dead-week dust is out of range")
	}

	d.ClaimPerUnit = perUnit
	d.Claims = distributed
	heldClaims += distributed
	if dust > 0 {
		d.Pot -= dust
		heldPots -= dust
		opsPot += dust
	}

	chain.Emit("DeadWeekSponsorshipDistributed",
		"week", strconv.FormatInt(d.Week, 10),
		"amount", strconv.FormatInt(s, 10),
		// BOTH TOTALS ARE REPORTED, AND THE DIVISOR IS THE EARNED ONE — finding 34. An
		// operator reading this event can see at a glance how much of the week was bought and
		// therefore excluded from the division; `units` alone used to be the ticket total and
		// silently WAS the divisor.
		"units", strconv.FormatInt(total, 10),
		"ticketUnits", strconv.FormatInt(d.tickets.Total(), 10),
		"perUnit", strconv.FormatInt(perUnit, 10),
		"distributed", strconv.FormatInt(distributed, 10),
		"dustToOps", strconv.FormatInt(dust, 10),
		"pot", strconv.FormatInt(d.Pot, 10),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10))
}

// weekIsOpenable IS GONE WITH ReclaimStrandedCarry — AUDIT-2026-09-28.md finding 31 — and
// its absence is worth a paragraph because it was finding 12's residual made visible. It
// read:
//
//	func weekIsOpenable() bool {
//		if !beacon.EstimateIsUsable() {
//			return false
//		}
//		return beacon.EstimatedLatestRound() <= maxPinnableLatest
//	}
//
// and it answered "could a new week's record be created right now?" without panicking, so
// that a caller who must not panic could ask before committing to a destination. EVERY
// CALLER OF IT WAS A CALLER THAT NEEDED A DESTINATION. There are none now: a dead week's
// money is claimed out of the week it is already in, and ClaimDeadWeek reads no beacon at
// all. So the state finding 12 recorded as a permanent residual — a chain whose average
// block time settles below 3.29998 s, in which no week can ever be opened again — NO LONGER
// STRANDS A DEAD WEEK'S SPONSORSHIP AT ALL, where before it needed a whole extra entry
// point (ReclaimStrandedCarry) and a three-week long stop to escape. Removing the need for
// a destination removed the need for the fallback.

// weekHasNoSpend reports whether NOBODY EVER BOUGHT A TICKET in this week — that is,
// whether sum(spendOf) is zero. It is the test SweepDrawlessWeek uses to tell money
// that belongs to nobody from money that belongs to buyers.
//
// IT IS AN ITERATION AND NOT A COUNTER, on purpose: a per-week spend total would be a
// fourth aggregate to keep in step with heldPots, heldSponsored and the per-week
// identity, and this is not on a hot path (SweepDrawlessWeek runs at most once per
// week, ever). AuditFailure already re-derives the same sum the same way.
//
// IT STOPS AT THE FIRST NON-ZERO ENTRY rather than summing, so it cannot overflow and
// costs one lookup on the common case.
//
// A ZERO ENTRY IS NOT A CLAIM, and that distinction is why this reads the values
// instead of asking Size(). Refund ZEROES a spend record rather than removing it
// (d.spendOf.Set(k, 0)), so a week that has taken refunds has entries whose values are
// zero — but such a week is Abandoned and SweepDrawlessWeek refuses it before asking
// this, so the two can never be confused.
//
// NEVER CALL IT FROM INSIDE ANOTHER avl.Iterate: nesting a second traversal inside the
// first's callback crashes this toolchain's VM outright (see AuditFailure).
func weekHasNoSpend(d *Draw) bool {
	none := true
	d.spendOf.Iterate("", "", func(_ string, v any) bool {
		if v.(int64) > 0 {
			none = false
			return true // stop
		}
		return false
	})
	return none
}

func treeInt64(t *avl.Tree, key string) int64 {
	if !t.Has(key) {
		return 0
	}
	return t.Get(key).(int64)
}

// appendTickets records a purchase of units by addr by APPENDING A NEW INDEX
// to this week's ticket index. It never touches an existing index, and that is
// the whole point — see Commit's frozen-ownership argument.
func appendTickets(d *Draw, addr address, units int64) {
	if units <= 0 {
		// fenwick.Append would reject a negative itself; failing here names
		// the caller that got it wrong, and a zero-unit purchase would create
		// an index that owns nothing.
		panic("raffle: ticket units must be positive")
	}
	i := d.tickets.Append(units)
	d.ownerOf.Set(indexKey(i), string(addr))
	k := string(addr)
	d.ticketsOf.Set(k, treeInt64(d.ticketsOf, k)+units)
}

// appendEarnedTickets is appendTickets PLUS the record that these units were EARNED rather
// than bought. It is the only writer of earnedOf and earnedTotal, and FundPotWithEntries is
// its only caller. AUDIT-2026-09-28.md finding 34.
//
// IT WRAPS appendTickets RATHER THAN SITTING BESIDE IT, AND THAT IS THE WHOLE GUARANTEE.
// sum(earnedOf) == earnedTotal has to hold identically, not approximately, because
// retireSponsorship divides a real wugnot balance by the counter and ClaimDeadWeek pays out
// against the tree — a drift of one unit between them is a week whose claims sum to more or
// less than its Claims. Two sibling calls in a caller's loop can drift the moment somebody
// adds an early `continue`; one function that cannot append the weight without recording the
// basis cannot. The three writes are one statement group from one `units` argument, and
// nothing in this file ever decrements or removes an entry of either.
//
// THERE IS DELIBERATELY NO `earned bool` PARAMETER ON appendTickets INSTEAD. Buy's call would
// then have to pass `false`, which is a place a future edit can pass `true` by accident and
// hand a buyer a claim on the duel's rake — the exact defect finding 34 is about. The
// bought path cannot name this function at all.
func appendEarnedTickets(d *Draw, addr address, units int64) {
	appendTickets(d, addr, units) // panics on a non-positive count before anything is written
	k := string(addr)
	d.earnedOf.Set(k, treeInt64(d.earnedOf, k)+units)
	d.earnedTotal += units
}

// ownerOfUnit is the draw rule's second half: who owns cumulative ticket unit
// k in this week's index. Factored out so the boundary tests can exercise the
// mapping over every interesting k without needing a signed beacon round for
// each one.
func ownerOfUnit(d *Draw, k int64) address {
	if d.tickets == nil || k < 0 || k >= d.tickets.Total() {
		panic("raffle: ticket unit out of range")
	}
	key := indexKey(d.tickets.Select(k))
	if !d.ownerOf.Has(key) {
		// Unreachable while appendTickets is the only writer: it sets the
		// reverse entry in the same statement group as the Append. Loud rather
		// than returning a zero address that would look like a winner.
		panic("raffle: ticket index has no owner")
	}
	return address(d.ownerOf.Get(key).(string))
}

// --- native coin -----------------------------------------------------------

// rejectAttachedCoin panics if the caller attached native coin to a call that
// has no use for it. Every money-in path in this realm is the wugnot GRC20
// allowance (Buy, Sponsor, FundPot, FundPotWithEntries), never the
// transaction's send envelope, so any attached ugnot would simply sit in this
// realm forever with no code path that ever looks at it — AUDIT-2026-10-07.md
// Y1. Call this as the first statement of every crossing entrypoint so the
// transaction reverts and the sender keeps their coin instead.
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
// COME DIRECTLY FROM A USER — which is every call FundPot and
// FundPotWithEntries ever accept, since both require cur.Previous().PkgPath()
// to be the duel's — THIS FUNCTION DOES NOT LOOK AT THE ENVELOPE AT ALL: it
// cannot be attributed to this call either way, so there is nothing sound to
// enforce, and guessing would be worse than staying silent.
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
		panic("raffle: " + what + " does not take native coin — pay through the wugnot allowance instead")
	}
}

// --- solvency ------------------------------------------------------------

// sweepDonations accounts for any wugnot that has arrived without going
// through Buy.
//
// IT HAS TO EXIST. wugnot.Transfer is permissionless: any address may push
// wugnot at this realm with no memo, no callback and no way for this realm to
// learn who sent it or why. Without a sweep, one unsolicited transfer would
// fail checkInvariant for every later caller and brick the realm.
//
// IT GOES TO opsPot, NOT TO THE CURRENT WEEK'S POT, which is the opposite of
// r/splash/game's choice and for a reason specific to this design: here
// Pot == sum(this week's spend records) is a load-bearing identity — it is what
// makes Refund unable to pay out more than was put in — and a donation credited
// to a pot would break it, silently converting somebody's gift into refundable
// balance that nobody has a claim on. The ops pot has no such identity to
// violate, and a donation there enlarges nothing it should not.
//
// IT EMITS A Donation EVENT FOR EVERY NON-ZERO ABSORPTION, and that is not
// bookkeeping decoration — it is the only record that the stream exists. Nothing
// else in this realm distinguishes a swept arrival from the house cut: both land
// in opsPot, both are withdrawn by WithdrawOps, and opsPot is a single number. So
// without this event an operator reading the chain cannot tell revenue from gifts,
// cannot see a donation arrive at all, and — the reason it matters — cannot see the
// masking case below.
//
// WHAT THE INVARIANT'S EQUALITY IS ACTUALLY WORTH, RECORDED HERE SO THE NEXT
// READER DOES NOT OVERTRUST IT. Suppose heldPots OVERCOUNTS by D because of a bug
// in this file — the realm believes it owes D more than it holds. Suppose donations
// totalling X > D have arrived. This function computes
// extra = bal - (heldPots + opsPot), which is X - D, absorbs it into opsPot, and
// afterwards heldPots + opsPot == bal EXACTLY. checkInvariant then passes, and so
// does AuditFailure's one-sided balance test. THE DEFICIT HAS NOT BEEN DETECTED, IT
// HAS BEEN PAID FOR OUT OF A STRANGER'S MONEY, and both solvency checks report
// green over it. The equality in checkInvariant is therefore weaker than it looks:
// it says "the books add up after absorbing whatever arrived", not "the books were
// already right". This event is what makes the absorption visible so the case can
// be noticed off-chain — a Donation for an amount no donor sent is the signature of
// exactly that state.
//
// FIXING THAT PROPERLY IS OUT OF SCOPE HERE, deliberately. It needs a separate
// counter for absorbed donations so the invariant can subtract them and state the
// pre-donation equality — a change to what the invariant MEANS, in a realm where
// every mutator asserts it, and therefore a separately-audited one. This function's
// destination is unchanged: donations still go to opsPot, not to any week's pot,
// for the reason above.
func sweepDonations() {
	if extra := absorbDonation(); extra > 0 {
		// EMITTED AFTER THE CREDIT, so the reported opsPot is the post-sweep figure
		// a reader can reconcile against OpsPot(). NOTHING IS EMITTED WHEN NOTHING
		// WAS ABSORBED: an empty sweep runs at the top of every mutator in this
		// file, and an event on each would bury the one that means something.
		chain.Emit("Donation",
			"amount", strconv.FormatInt(extra, 10),
			"opsPot", strconv.FormatInt(opsPot, 10))
	}
}

// absorbDonation is sweepDonations without the event: it credits opsPot with any
// unattributed arrival and RETURNS THE AMOUNT IT ABSORBED, zero if there was
// nothing. Everything said about the destination and the masking case is on
// sweepDonations.
//
// IT IS SPLIT OUT FOR ONE REASON, AND IT IS A TESTABILITY REASON STATED PLAINLY:
// this toolchain gives a Gno test no way to read emitted events, so the only
// statements about the Donation event that can be asserted on-chain are the value
// it would carry and whether it fires at all. Both are exactly this return value,
// and raffle_test.gno asserts it on both sides — a real arrival absorbed to the
// ugnot, and an empty sweep returning zero so the caller above emits nothing. The
// Emit is then a one-line function of a tested quantity rather than an untested
// branch. Do not inline it back without putting the event under test some other
// way.
func absorbDonation() int64 {
	bal := wugnot.BalanceOf(selfAddr())
	// heldCuts IS IN HERE BECAUSE IT IS WUGNOT THIS REALM HOLDS. Omitting it would make
	// every week's escrowed fee look like an unattributed arrival, and the first sweep
	// after any sale would move the whole of it into opsPot — banking the fee at sale
	// time by accident, which is exactly the behaviour finding 25 removed, and leaving
	// every refund unable to return a gross it no longer holds.
	extra := bal - (heldPots + heldCuts + opsPot)
	if extra <= 0 {
		return 0
	}
	opsPot += extra
	return extra
}

// checkInvariant is this realm's solvency statement: the wugnot it holds is
// exactly the sum of every unresolved week's pot plus the ops pot, and nothing
// else. O(1), using the incrementally-maintained heldPots; AuditFailure
// re-derives the same thing by iteration.
//
// CALLED AT THE END OF EVERY STATE-CHANGING FUNCTION. An equality, not a ">=":
// sweepDonations runs first in each of them, so unattributed arrivals are
// already accounted for and any remaining gap is a bug in this file.
//
// THE SPONSORSHIP HALF OF THE POT IDENTITY IS CHECKED HERE ONLY IN ITS O(1)
// FORM. The full statement is per week — Pot + Cut == sum(spendOf) + Sponsored — and
// verifying it directly would mean iterating every buyer of every week on every
// call, which is exactly the cost this function exists to avoid. What is
// affordable, and is asserted, is that the aggregate sponsorship is a
// non-negative part of the pots that hold it: more sponsorship than pots would
// mean the buyers' collective claim had gone negative somewhere. AuditFailure
// re-derives the per-week identity ONE WEEK AT A TIME (finding 27 — it used to do it
// summed over the unresolved weeks, which two weeks with compensating errors passed
// through silently).
func checkInvariant() {
	bal := wugnot.BalanceOf(selfAddr())
	// THREE TERMS SINCE 2026-09-29, NOT TWO. The house fee is escrowed per week in
	// Draw.Cut rather than banked into opsPot at sale time (finding 25), so the wugnot
	// this realm holds is the unresolved prize pots, PLUS the unearned fees held against
	// those weeks, PLUS the ops pot. Read heldCuts.
	if heldPots+heldCuts+opsPot != bal {
		panic("raffle: GNOT invariant violated")
	}
	if heldPots < 0 {
		// Would mean a pot was paid out twice.
		panic("raffle: heldPots negative")
	}
	if heldCuts < 0 {
		// Would mean a week's escrowed fee was released twice — a Resolve and a Refund
		// both taking it, or a refund re-deriving more cut than the buyer ever paid.
		// cutPerTicket's build guard is what makes the second impossible.
		panic("raffle: heldCuts negative")
	}
	if opsPot < 0 {
		panic("raffle: opsPot negative")
	}
	if heldSponsored < 0 {
		// Would mean sponsorship was removed from a week twice — retireSponsorship
		// running more than once over the same week, say.
		panic("raffle: heldSponsored negative")
	}
	if heldSponsorRefunds < 0 {
		panic("raffle: heldSponsorRefunds negative")
	}
	if heldClaims < 0 {
		// Would mean a dead week's share was paid twice: two ClaimDeadWeek calls for one
		// holder, or a claim derived from a unit count that grew after the retirement.
		panic("raffle: heldClaims negative")
	}
	if heldSponsored+heldClaims+heldSponsorRefunds > heldPots {
		// BOTH NON-BUYER CLAIM TERMS AT ONCE, SINCE FINDING 31, and they are summed rather
		// than checked one at a time because they are two states of the same money: a
		// week's sponsorship BEFORE it is abandoned and its holders' unclaimed shares
		// AFTER. Each is part of the pot it sits in, so together they can never exceed the
		// pots held. If they did, buyers' claims on those pots would sum to less than
		// nothing and Refund's overdraw guard would be all that stood between a caller and
		// another week's money.
		panic("raffle: sponsorship and unclaimed dead-week shares exceed the pots holding them")
	}
}

// AuditFailure re-derives the invariant BY ITERATION and reports the empty
// string when the books balance, otherwise which check failed and by how much.
// Never called from a state-changing path — checkInvariant is the O(1) guard
// for that — and exists so anyone can verify off-chain, and so a test can
// assert it after every operation.
//
// IT MUST BE ROBUST AGAINST ANYONE WHO CAN SEND THIS REALM TOKENS, which is
// everyone: wugnot.Transfer needs no permission. So the balance test below is a
// one-sided one — a shortfall is a violation, an unswept surplus is not. See the
// comment on that check.
func AuditFailure() string {
	i64 := strconv.FormatInt

	// ONE PASS THAT COLLECTS, THEN A LOOP THAT SUMS — never an Iterate inside
	// an Iterate. Nesting a second avl traversal inside the first one's callback
	// crashes this toolchain's VM outright (a Go-level nil dereference, not a
	// gno panic), so the two levels are kept strictly apart. A slice is fine
	// here because it is local scratch and never realm state.
	all := []*Draw{}
	sumPots := int64(0)
	sumCuts := int64(0)
	unresolvedPots := int64(0)
	unresolvedCuts := int64(0)
	sumSponsored := int64(0)
	sumSponsorCut := int64(0)
	sumSponsorRefunds := int64(0)
	sumClaims := int64(0)
	unresolvedClaims := int64(0)
	draws.Iterate("", "", func(_ string, value any) bool {
		d := value.(*Draw)
		all = append(all, d)
		sumPots += d.Pot
		sumCuts += d.Cut
		sumClaims += d.Claims
		if !d.Resolved {
			unresolvedPots += d.Pot
			unresolvedCuts += d.Cut
			sumSponsored += d.Sponsored
			sumSponsorCut += d.SponsorCut
			sumSponsorRefunds += d.SponsorRefundable
			unresolvedClaims += d.Claims
		}
		return false
	})

	// THE SECOND PASS, AND IT IS NOW PER WEEK — AUDIT-2026-09-28.md finding 27. It sums
	// each week's spendOf on its own and tests THAT WEEK'S identity immediately, instead
	// of accumulating one grand total and testing it once at the end. The cost is one
	// comparison per unresolved week; the loop, the slice and the single level of
	// iteration are all exactly as they were.
	//
	// WHY THE AGGREGATE FORM WAS NOT GOOD ENOUGH. Summed over the weeks, two weeks with
	// EQUAL AND OPPOSITE errors (+X here, -X there) cancel and the check passes with
	// both weeks wrong — and every path that moves money BETWEEN weeks is precisely the
	// shape that produces such a pair. This realm has two of them (Refund's abandonment
	// transition and SweepDrawlessWeek, now joined by the carry absorption in
	// getOrCreateDraw), all three new, and a half-applied move — one side of the
	// transfer written and not the other — is their most likely bug. The aggregate check
	// was blind to exactly that.
	//
	// THE FAILURE IS RECORDED AND REPORTED LOWER DOWN rather than returned from here, so
	// that the ORDER in which this function reports problems does not change: heldPots,
	// heldCuts and the balance shortfall still come first, as they did when the identity
	// was one aggregate test at the end.
	sumSpends := int64(0)
	perWeek := ""
	deadWeek := ""
	for _, d := range all {
		// THE DEAD-WEEK CLAIM SHAPE IS CHECKED ON EVERY WEEK, RESOLVED OR NOT, because
		// "a resolved week holding claims" is one of the states worth naming — see below.
		if deadWeek == "" {
			deadWeek = deadWeekClaimFailure(d, i64)
		}
		if d.Resolved {
			continue
		}
		weekSpends := int64(0)
		d.spendOf.Iterate("", "", func(_ string, v any) bool {
			weekSpends += v.(int64)
			return false
		})
		sumSpends += weekSpends
		// THE UNCLAIMED DEAD-WEEK SHARES JOIN THE CLAIMS SIDE — finding 31. They are the
		// same money d.Sponsored used to be, in its second state: not a buyer's, not the
		// house's, and part of d.Pot either way. A week is in exactly one of the two states
		// (retireSponsorship zeroes the one as it writes the other), so in practice one of
		// the two terms is always zero — which is asserted rather than assumed in
		// deadWeekClaimFailure.
		// d.SponsorCut JOINED THIS IDENTITY ON 2026-09-30 AND DOES NOT WEAKEN IT. A
		// sponsorship's GROSS splits the way a ticket's does — net to Pot and recorded
		// in Sponsored, fee to Cut and recorded in SponsorCut — so without this term
		// the identity is short by precisely the sponsors' escrowed fee. Every ugnot in
		// Pot+Cut still has to name an origin; there is one more origin than there was.
		if perWeek == "" && weekSpends+d.Sponsored+d.SponsorCut+d.Claims+d.SponsorRefundable != d.Pot+d.Cut {
			perWeek = "week " + i64(d.Week, 10) + ": pot " + i64(d.Pot, 10) +
				" and escrowed fee " + i64(d.Cut, 10) +
				" but buyers' gross claims total " + i64(weekSpends, 10) +
				", sponsorship " + i64(d.Sponsored, 10) +
				", sponsors' escrowed fee " + i64(d.SponsorCut, 10) +
				", owed back to sponsors " + i64(d.SponsorRefundable, 10) +
				" and unclaimed dead-week shares " + i64(d.Claims, 10)
		}
	}

	if sumPots != heldPots {
		return "heldPots is " + i64(heldPots, 10) + ", iterating the draws gives " + i64(sumPots, 10)
	}
	// THE ESCROWED FEES, RE-DERIVED THE SAME WAY AND FOR THE SAME REASON (finding 25).
	// Resolve zeroes a week's Cut when it releases it, so a resolved week contributes
	// nothing here and the sum over ALL draws is the same number as the sum over the
	// unresolved ones — which is asserted below rather than assumed, because the two
	// would part company if anything ever released a fee without zeroing the field.
	if sumCuts != heldCuts {
		return "heldCuts is " + i64(heldCuts, 10) + ", iterating the draws gives " + i64(sumCuts, 10)
	}
	if unresolvedCuts != sumCuts {
		return "escrowed fees total " + i64(sumCuts, 10) +
			" but only " + i64(unresolvedCuts, 10) + " of it is on an unresolved week" +
			" — a resolved week is holding a fee it should have released"
	}
	if sumSponsored != heldSponsored {
		return "heldSponsored is " + i64(heldSponsored, 10) +
			", iterating the unresolved draws gives " + i64(sumSponsored, 10)
	}
	// THE UNCLAIMED DEAD-WEEK SHARES, RE-DERIVED THE SAME WAY AND FOR THE SAME REASON
	// (finding 31). A resolved week can hold no claims — Abandoned and Resolved are mutually
	// exclusive and only an abandoned week ever gets a claim rate — so the sum over ALL
	// draws is the same number as the sum over the unresolved ones, which is asserted rather
	// than assumed just below.
	// EVERY OTHER MONEY AGGREGATE IN THIS FILE IS RE-DERIVED AND THIS ONE WAS NOT.
	// It feeds the ceiling panic below, and checkInvariant runs at the end of every
	// state-changing function — so an upward drift would freeze Buy, Refund, Resolve
	// and both claim doors at once, with AuditFailure still returning "". An identity
	// nothing re-derives is an identity nobody finds out about. 2026-09-30 audit, Y1.
	if sumSponsorRefunds != heldSponsorRefunds {
		return "heldSponsorRefunds is " + i64(heldSponsorRefunds, 10) +
			", iterating the draws gives " + i64(sumSponsorRefunds, 10)
	}
	if sumClaims != heldClaims {
		return "heldClaims is " + i64(heldClaims, 10) +
			", iterating the draws gives " + i64(sumClaims, 10)
	}
	if unresolvedClaims != sumClaims {
		return "unclaimed dead-week shares total " + i64(sumClaims, 10) +
			" but only " + i64(unresolvedClaims, 10) + " of it is on an unresolved week" +
			" — a resolved week is holding claims against a prize that has been paid"
	}
	// ONLY A DEFICIT IS A VIOLATION HERE — a surplus is not, and that asymmetry
	// is deliberate. This function is a READ: it cannot sweep, so any wugnot that
	// has arrived without going through Buy is still unattributed when it runs.
	// wugnot.Transfer is permissionless, so with an equality here a stranger could
	// make AuditInvariant() false and AuditFailure() shout by sending this realm
	// one ugnot — free, repeatable, attacker-controlled alert fatigue on the one
	// solvency signal an operator would page on, with nothing actually wrong and
	// nobody harmed. An unswept donation is a benign, expected state: the next
	// state-changing call sweeps it into the ops pot (see sweepDonations).
	//
	// A DEFICIT IS THE CASE THAT CAN HURT SOMEBODY: it means this realm has
	// promised more than it holds, so some pot cannot be paid. That is reported,
	// always.
	//
	// checkInvariant, in the mutators, KEEPS ITS EQUALITY and is untouched by
	// this: it runs after sweepDonations, so a surplus there really would be a
	// bug in this file.
	// STILL ONE-SIDED, AND THE ESCROWED FEES JOIN THE SIDE THEY BELONG ON. heldCuts is
	// money the realm is holding for somebody — either the house, once the week draws,
	// or the buyers, if it does not — so it counts towards what the realm must be able
	// to pay, exactly like a pot. A DEFICIT IS STILL THE ONLY VIOLATION: a surplus is
	// still benign and still must not be reported, or a stranger could make this
	// function shout for one ugnot (see above). Finding 9's asymmetry is unchanged.
	// heldClaims NEEDS NO TERM OF ITS OWN HERE, AND THAT IS NOT AN OVERSIGHT: an unclaimed
	// dead-week share is part of the week's Pot and is therefore already inside sumPots,
	// exactly as d.Sponsored always has been. The register this replaced held no money and
	// so added no term either; the difference is that this one is money the realm holds
	// against named addresses, which is why it gets its own re-derivation above.
	bal := wugnot.BalanceOf(selfAddr())
	if bal < sumPots+sumCuts+opsPot {
		return "pots + escrowed fees + ops is " + i64(sumPots+sumCuts+opsPot, 10) +
			", but the wugnot balance is only " + i64(bal, 10) +
			" — the realm is short by " + i64(sumPots+sumCuts+opsPot-bal, 10)
	}
	// Every unresolved week's pot must still be exactly its buyers' claims PLUS
	// the house money sponsored into it, or Refund could pay out more or less
	// than was put in. A resolved week is excluded: its pot is gone to the winner
	// and its spend records are dead.
	//
	// SPONSORSHIP IS ON THE CLAIMS SIDE OF THIS EQUATION and is not a tolerance:
	// it is a named, tracked quantity that belongs to no buyer, so a pot that
	// exceeded the spends by anything OTHER than the recorded sponsorship is
	// still reported here. That is the difference between this and weakening the
	// identity into an inequality.
	// THE PER-WEEK IDENTITY, WITH THE ESCROWED FEE ON THE POT SIDE OF IT:
	//
	//	Pot + Cut == sum(spendOf) + Sponsored
	//
	// summed over the unresolved weeks. A buyer's spendOf is their GROSS payment since
	// finding 25, and that gross was split at sale time into the part that went to the
	// prize (Pot) and the part held as the house's unearned fee (Cut) — so both must be
	// on the left or the equation is short by every fee ever taken. Sponsorship carries
	// no fee at all and goes wholly to Pot, which is why it appears only once.
	//
	// IT IS THIS IDENTITY, NOT AN INEQUALITY, THAT MAKES Refund PROVABLY UNABLE TO
	// OVERDRAW: a refund removes exactly one buyer's gross from the right and exactly
	// the same amount from the left, split across the two terms it arrived in.
	//
	// AND IT IS TESTED ONE WEEK AT A TIME SINCE 2026-09-29 (finding 27). The loop above
	// did the work; this is where its verdict is reported, in the position the old
	// aggregate test occupied.
	if perWeek != "" {
		return perWeek
	}
	// THE AGGREGATE FORM, KEPT AS A SECOND LOCK AND NO LONGER ABLE TO FIRE ON ITS OWN.
	// It is IMPLIED by the per-week loop — a sum of equalities is an equality — so it is
	// now a defensive check in the same sense as this file's several "unreachable" panics:
	// what it still guards is the ACCUMULATION, i.e. that the same numbers the per-week
	// test read add up to the aggregates the O(1) invariant is written in. It is deliberately
	// NOT deleted, because if a future edit ever narrows the per-week loop (by skipping a
	// class of week, say) this line is what still notices.
	if sumSpends+sumSponsored+sumSponsorCut+sumClaims+sumSponsorRefunds != unresolvedPots+unresolvedCuts {
		return "unresolved pots total " + i64(unresolvedPots, 10) +
			" and escrowed fees " + i64(unresolvedCuts, 10) +
			", buyers' gross claims total " + i64(sumSpends, 10) +
			", sponsorship totals " + i64(sumSponsored, 10) +
			", owed back to sponsors " + i64(sumSponsorRefunds, 10) +
			", sponsors' escrowed fees total " + i64(sumSponsorCut, 10) +
			" and unclaimed dead-week shares total " + i64(sumClaims, 10)
	}

	// AND THE DEAD-WEEK CLAIM SHAPE, REPORTED IN THE POSITION THE CARRY REGISTER'S
	// RE-DERIVATION OCCUPIED — finding 31. The register's version of this check was:
	//
	//	every entry must describe a week that exists, is unresolved, is abandoned and
	//	still holds the sponsorship the register claims for it
	//
	// and it was a separate pass over carryPending. THERE IS NO REGISTER TO DRIFT NOW, so
	// the equivalent statement is made about the weeks themselves and is computed in the
	// per-week loop above (deadWeekClaimFailure). The verdict is reported here so that the
	// ORDER in which this function reports problems does not change.
	if deadWeek != "" {
		return deadWeek
	}
	return ""
}

// deadWeekClaimFailure re-derives everything finding 31's fix asserts about ONE week's
// dead-money state, and returns the empty string when that week is consistent. Factored out
// of AuditFailure so the per-week loop stays readable, and called for EVERY week rather than
// only the unresolved ones — two of the five statements below are about a resolved week.
//
// THE FIVE STATEMENTS, and each one is a state that would mean money the realm holds has no
// claimant or two claimants:
//
//  1. AN ABANDONED WEEK HOLDS NO SPONSORSHIP. This is the one that replaces the whole carry
//     register and it is the strongest of the five: retireSponsorship runs in the same
//     statement group that sets Abandoned, so a non-zero Sponsored on an abandoned week
//     means money sitting in a pot whose draw can never happen and whose buyers' claims are
//     being zeroed one by one — the exact "money in, no way out" shape this realm's first
//     finding was about, and the shape the register only NAMED rather than removed.
//  2. A CLAIM RATE IMPLIES ABANDONMENT. A live week can still sell tickets and still
//     resolve, so a claim rate on one would be a claim against a prize somebody is about to
//     win.
//  3. A RESOLVED WEEK HOLDS NO CLAIMS AND NO RATE. Resolved and Abandoned are mutually
//     exclusive, so this is implied by (2) — and it is stated anyway because it is the
//     statement that the winner was not paid a pot somebody else still has a claim on.
//  4. THE UNCLAIMED TOTAL MATCHES THE RATE AND THE PAYMENTS. Claims must equal
//     ClaimPerUnit * earnedTotal minus everything claimedOf records as paid. This is the
//     independent re-derivation of the O(1) counter: ClaimDeadWeek writes both sides and a
//     half-applied payment is its most likely bug.
//  5. EVERY PAYMENT MATCHES ITS HOLDER'S EARNED WEIGHT. Each claimedOf entry must be exactly
//     that holder's EARNED units times the rate. Without this, (4) would still pass if one
//     holder had been overpaid and another underpaid by the same amount — the same
//     cancelling-pair blindness finding 27 was about, one level down.
//  6. THE EARNED BASIS IS INTERNALLY CONSISTENT — AUDIT-2026-09-28.md finding 34, and it is
//     checked on EVERY week including live ones, before any of the five above. Two statements:
//     sum(earnedOf) == earnedTotal, and earnedTotal <= tickets.Total().
//
//     WHY IT IS RE-DERIVED AT ALL, GIVEN THAT ONE FUNCTION WRITES BOTH. Because the whole
//     exactness argument of finding 31's fix — that every possible claim sums to exactly
//     Claims — now rests on it. retireSponsorship divides a real wugnot balance by the
//     COUNTER and ClaimDeadWeek pays out against the TREE; if the two ever disagreed by one
//     unit, the claims would sum to more or less than Claims and (4) would be the only thing
//     that noticed, one abandonment too late. The old design got this identity free because
//     sum(ticketsOf) == tickets.Total() was maintained by fenwick itself. The earned pair is
//     maintained by appendEarnedTickets instead, so the equivalent statement is made here
//     rather than assumed from the type.
//
//     THE SECOND HALF IS THE STRUCTURAL ONE: an earned unit is appended through appendTickets
//     in the same statement group, so it is always also a ticket unit. An earnedTotal larger
//     than the week's ticket total would mean weight claimed that the draw never saw.
//
// COLLECT-THEN-LOOP, NEVER A NESTED avl.Iterate. The claimedOf keys are gathered in one pass
// and every ticketsOf lookup happens after it, because nesting a second traversal inside the
// first's callback crashes this toolchain's VM outright (a Go-level nil dereference, not a
// gno panic). Its caller has already finished the draws traversal before calling, for the
// same reason.
func deadWeekClaimFailure(d *Draw, i64 func(int64, int) string) string {
	w := i64(d.Week, 10)

	// THE EARNED BASIS FIRST, AND ON EVERY WEEK — statement (6), finding 34. It is checked
	// before the dead-money statements because it is a property of the week's ticket
	// bookkeeping rather than of its abandonment: it must hold on a live week too, and a live
	// week is where a drift would be introduced. One traversal, and it finishes before the
	// claimedOf traversal below begins.
	sumEarned := int64(0)
	d.earnedOf.Iterate("", "", func(_ string, v any) bool {
		sumEarned += v.(int64)
		return false
	})
	if sumEarned != d.earnedTotal {
		return "week " + w + " counts " + i64(d.earnedTotal, 10) +
			" earned units but its per-holder records sum to " + i64(sumEarned, 10) +
			" — the dead-week claim basis and its divisor have drifted apart"
	}
	if d.earnedTotal < 0 || d.earnedTotal > d.tickets.Total() {
		return "week " + w + " counts " + i64(d.earnedTotal, 10) +
			" earned units against a ticket total of " + i64(d.tickets.Total(), 10) +
			" — every earned unit must also be a ticket unit"
	}

	if d.Abandoned && d.Sponsored != 0 {
		return "week " + w + " is abandoned but still holds " + i64(d.Sponsored, 10) +
			" of sponsorship — an abandoned week's draw can never happen, so that money has no claimant"
	}
	if d.ClaimPerUnit != 0 && !d.Abandoned {
		return "week " + w + " has a dead-week claim rate of " + i64(d.ClaimPerUnit, 10) +
			" but is not abandoned"
	}
	if d.Resolved && (d.Claims != 0 || d.ClaimPerUnit != 0) {
		return "week " + w + " is resolved but holds " + i64(d.Claims, 10) +
			" of unclaimed dead-week shares at a rate of " + i64(d.ClaimPerUnit, 10)
	}
	if d.Claims < 0 {
		return "week " + w + " has negative unclaimed dead-week shares: " + i64(d.Claims, 10)
	}
	if d.ClaimPerUnit == 0 {
		if d.Claims != 0 {
			return "week " + w + " holds " + i64(d.Claims, 10) +
				" of unclaimed dead-week shares with no claim rate to derive them from"
		}
		return ""
	}

	keys := []string{}
	paid := int64(0)
	d.claimedOf.Iterate("", "", func(k string, v any) bool {
		keys = append(keys, k)
		paid += v.(int64)
		return false
	})
	// THE DIVISOR IS earnedTotal, NOT tickets.Total() — finding 34. Both expressions were the
	// same number on a pure-earned week, which is why the old form survived its own tests; they
	// differ by exactly the bought units, which is the defect.
	if d.ClaimPerUnit*d.earnedTotal-paid != d.Claims {
		return "week " + w + " distributed " + i64(d.ClaimPerUnit*d.earnedTotal, 10) +
			" of dead-week shares and has paid out " + i64(paid, 10) +
			", so " + i64(d.ClaimPerUnit*d.earnedTotal-paid, 10) +
			" should be unclaimed, but the week says " + i64(d.Claims, 10)
	}
	for _, k := range keys {
		got := treeInt64(d.claimedOf, k)
		want := treeInt64(d.earnedOf, k) * d.ClaimPerUnit
		if got != want {
			return "week " + w + ": holder " + k + " was paid " + i64(got, 10) +
				" of dead-week share but holds " + i64(treeInt64(d.earnedOf, k), 10) +
				" earned units at " + i64(d.ClaimPerUnit, 10) + " each, which is " + i64(want, 10)
		}
	}
	return ""
}

// AuditInvariant is AuditFailure reduced to a bool.
func AuditInvariant() bool { return AuditFailure() == "" }

// --- Buy -----------------------------------------------------------------

// Buy sells `tickets` tickets in the CURRENT week to the caller.
//
// Cost is tickets * TicketPrice, pulled from the caller with the GRC20
// allowance path, so the caller wraps native ugnot with wugnot.Deposit and
// approves this realm first. HouseCutBps of the cost is ESCROWED AGAINST THIS WEEK in
// Draw.Cut; the remainder — and all integer-division dust, since the cut is floored —
// joins this week's prize pot.
//
// IT SAID "goes to the ops pot" UNTIL NOW AND THAT HAS BEEN FALSE SINCE 2026-09-29. A
// sale banks nothing for the house: the fee is unearned until the week actually draws,
// Resolve is what moves it to opsPot, and a week that fails hands it back as part of
// each buyer's gross refund. The distinction is the whole of finding 25 — "we earn when
// the game runs, not when it fails" — and a comment that says the money is already the
// house's describes a realm that cannot refund in full. AUDIT-2026-09-28.md finding 29.
//
// EVERY CHECK RUNS BEFORE THE PULL, and the week record is created only after
// it, so a failed Buy moves nothing and creates nothing.
//
// Each purchase APPENDS its own ticket index rather than growing an existing
// one. That is not a style choice: it is the property Commit depends on, and
// the reason is spelled out there.
//
// THE WEEK'S FIRST BUY PINS THE WEEK'S BEACON ROUND, as a side effect of creating
// the record (getOrCreateDraw). That is deliberate and is the only moment the round
// is ever chosen: read pinOffsetRounds. Two consequences a caller can see. First, a
// sale needs the beacon to have published at least one round ever, or it is refused
// with the beacon's own "no round published yet" — which is a refused sale rather
// than money accepted into a week that could never be drawn. Second, the buyer who
// opens a week does not get to pick anything useful: the round is fixed a week and
// more ahead of the moment the ticket set closes, so at the instant it is pinned
// there is no ticket set for it to be advantageous against.
//
// Panics if tickets is not positive, if the cost overflows int64, if the
// allowance is short, or if THIS WEEK IS ALREADY COMMITTED — the last of which
// is the frozen-total rule, not a convenience check. Once a week's total is
// frozen, no further ticket may join it.
//
// THAT LAST REFUSAL IS NOW UNREACHABLE, and is kept deliberately. Commit only
// accepts a week that is already over, and Buy only ever sells into
// currentWeek(), so the live week cannot be in a committed state — which is
// exactly why a commit can no longer shut a week's sales down early. The check
// stays as a second lock on the frozen-total rule: if the week's identity ever
// stops being "the one the clock is on", this is the line that still refuses to
// grow a frozen ticket set.
//
// ONLY A USER MAY BUY, AND THE REASON IS THE PAYOUT, NOT THE PURCHASE. A ticket
// is a claim on two transfers this realm will later push OUT: Resolve's whole pot
// to the winner's address, and Refund's spend back to the buyer's. Both go to
// cur.Previous().Address(), which for a realm caller is that realm's
// package-derived address — an address whose only "key" is its package path, so
// nothing can move wugnot out of it unless that realm happens to contain code
// that does. A realm with no such code that won a draw would have the entire
// week's pot transferred into an address it can never spend from: money that has
// left this realm's books (heldPots drops, the invariant stays green) and is
// unreachable by anybody, for ever. This realm cannot tell which realms those are
// and must not try, so it refuses them all at the door instead of stranding a pot
// at settlement time.
//
// cur.Previous().IsUserCall() IS THE CHECK, COPIED FROM r/splash/exchange:378 —
// AND IsUser() IS NOT. IsUser() also accepts a `maketx run` ephemeral realm, which
// is code executing under a user's signature and NOT an EOA: its address is still
// package-derived, so it can win a pot and then cease to exist with the money in
// it. The exchange states the same distinction for the same word, in the context
// of a send envelope rather than a payout; the failure mode differs but the
// property being asked for — "the thing in front of me is a wallet somebody holds
// a private key for" — is identical.
//
// FundPot IS DELIBERATELY NOT GUARDED THIS WAY, AND MUST NOT BE "MADE
// CONSISTENT". r/splash/arcade/duel calls it from realm code — from FlushPot, once per
// batch of collected duels; it was from Collect itself until AUDIT-2026-09-28.md finding
// 14 — so adding this check there would break the arcade's rake, the thing that makes the
// duel and the raffle one product. It is safe there precisely because sponsorship
// buys nothing: no ticket unit, no winning chance, no refundable claim (see
// FundPot and Draw.Sponsored), so a realm that funds a pot can never be the
// address a payout is pushed to, and the defect above has no way to arise. The
// asymmetry is the point: the guard belongs on the entry point that creates a
// claim on an outbound transfer, not on the one that only ever pays in.
//
// AND FundPotWithEntries DOES CREATE SUCH A CLAIM, WHICH IS WHY IT IS THE ONE
// GUARDED FUNCTION IN THIS FILE — WITH A DIFFERENT GUARD, FOR A DIFFERENT REASON.
// It appends ticket weight for addresses the CALLER names, so this finding's defect
// would arise there twice over if it were open: any caller could credit a realm
// address that can never spend a pot, and could do it for somebody else's benefit.
// IsUserCall cannot be the check there, because the only legitimate caller IS a
// realm. So that function admits exactly one package path, and the finding-8
// property — every holder of an earned entry is an address a payout can actually
// reach — is enforced where it is knowable: r/splash/arcade/duel records whether
// each party's own Post or Accept was a direct user call and credits only those.
// A REALM CANNOT PLAY A DUEL AT ALL SINCE 2026-09-30, and the sentence that stood here —
// "a realm may still play duels; it simply earns no raffle entries by doing so" — is
// corrected rather than deleted because the reason it stopped being true is this finding
// travelling one realm further. r/splash/arcade/duel found that leaving SETTLEMENT open to
// realms had the same defect in its own escrow: its Collect is winner-only, so a winning
// realm with no code calling it stranded both stakes with no exit. Post and Accept there
// now require a direct user call. The duel still records each party's flag and still
// credits entries only to eligible parties — nothing this realm relies on has weakened,
// and the property below is now enforced twice over.
// AUDIT-duel-2026-09-27.md addendum 2, finding D-1.
func Buy(cur realm, tickets int64) {
	rejectAttachedCoin(cur, "Buy")
	sweepDonations()

	if !cur.Previous().IsUserCall() {
		panic("raffle: Buy must be called directly by a user")
	}

	if tickets <= 0 {
		panic("raffle: ticket count must be positive")
	}
	cost := ticketCost(tickets)

	week := currentWeek()
	if d := getDraw(week); d != nil && d.Committed {
		panic("raffle: this week is already committed — tickets for it are closed")
	}

	caller := cur.Previous().Address()
	if wugnot.Allowance(caller, selfAddr()) < cost {
		panic("raffle: insufficient allowance — approve this realm for the ticket cost first")
	}

	wugnot.TransferFrom(cross(cur), caller, selfAddr(), cost)

	cut := int64(mulDiv(uint64(cost), uint64(HouseCutBps), uint64(bpsDenom)))
	net := cost - cut

	// THE WEIGHT THIS PURCHASE CARRIES, IN ENTRY UNITS AND NOT IN TICKETS. One ticket
	// is unitsPerTicket (40) units of weight; read EntryUnitPrice for why the two are
	// separate numbers now.
	//
	// IT IS DIVIDED OUT OF cost RATHER THAN MULTIPLIED UP FROM tickets, deliberately,
	// and the reason is the overflow argument rather than taste: cost has ALREADY been
	// range-checked into an int64 by ticketCost, and dividing an int64 by a positive
	// constant cannot overflow — so this line needs no second bits.Mul64 guard and no
	// new reasoning about how large a ticket count may be. The two are equal by the
	// build guard above (cost == tickets * TicketPrice and
	// TicketPrice == unitsPerTicket * EntryUnitPrice), which is exactly what
	// TestFix22_ATicketIsExactlyTicketPriceOverEntryUnitPrice asserts through the front door.
	units := cost / EntryUnitPrice
	if units <= 0 {
		// Unreachable: tickets >= 1 and unitsPerTicket >= 1 by the build guards above.
		// Loud rather than taking money for a purchase that appends no weight.
		panic("raffle: ticket purchase carries no entry units")
	}

	d := getOrCreateDraw(week)
	// THE FEE IS ESCROWED IN THE WEEK, NOT BANKED — AUDIT-2026-09-28.md finding 25.
	// This line was `opsPot += cut` until 2026-09-29, which meant the house had been
	// paid the moment a ticket was sold and a week that never drew refunded only 95%.
	// The owner's rule is that WE EARN WHEN THE GAME RUNS, NOT WHEN IT FAILS, so the
	// fee now sits in d.Cut — inside this week, outside the prize — and reaches opsPot
	// only when Resolve names a winner. If instead the week is abandoned or refunded,
	// d.Cut is returned to the buyers it came from, because spendOf below records the
	// GROSS and Refund pays the gross.
	//
	// d.Cut IS NOT IN d.Pot AND MUST NEVER BE. The winner must not win our fee: Resolve
	// pays d.Pot and moves d.Cut, and the two are separate terms in both the per-week
	// identity (d.Pot + d.Cut == sum(spendOf) + d.Sponsored) and the realm's solvency
	// statement (heldPots + heldCuts + opsPot == balance).
	d.Cut += cut
	heldCuts += cut
	d.Pot += net
	heldPots += net
	appendTickets(d, caller, units)
	k := string(caller)
	// THE GROSS, NOT THE NET. This is what Refund returns, and it is the buyer's whole
	// payment: the fee is only ours once the draw happens. The per-week identity is
	// preserved exactly — the gross recorded here equals the net that went to d.Pot plus
	// the cut that went to d.Cut, by construction, on this line and the two above it.
	d.spendOf.Set(k, treeInt64(d.spendOf, k)+cost)

	chain.Emit("Buy",
		"week", strconv.FormatInt(week, 10),
		"buyer", string(caller),
		"tickets", strconv.FormatInt(tickets, 10),
		"units", strconv.FormatInt(units, 10),
		"cost", strconv.FormatInt(cost, 10),
		"cut", strconv.FormatInt(cut, 10),
		"escrowedCut", strconv.FormatInt(d.Cut, 10),
		"pot", strconv.FormatInt(d.Pot, 10))
	checkInvariant()
}

// --- FundPot -------------------------------------------------------------

// FundPot adds house money to the CURRENT week's prize pot without buying a
// single ticket. PERMISSIONLESS and CALLER-PAYS: the funder pulls from their own
// allowance, exactly as Buy does, so this realm gains no authority over anybody
// and any address can call it with its own money.
//
// IT IS REALM-CALLABLE ON PURPOSE AND HAS NO IsUserCall GUARD. Do not add one for
// consistency with Buy. r/splash/arcade/duel calls this from realm code on every
// Collect — that is the arcade's rake, and gating it on an EOA would break the one
// mechanism that makes the duel and the raffle a single product. Buy's guard exists
// because a ticket is a claim on an outbound transfer (Resolve's pot, Refund's
// spend) and a realm's package-derived address may have no way to spend what
// arrives there; sponsorship creates no such claim at all — no ticket unit, no
// winning chance, no refundable record, see below — so a funder can never be the
// address a payout is pushed to and the defect Buy's guard closes cannot arise
// here. The asymmetry is deliberate and is stated at both ends.
//
// WHY IT EXISTS. r/splash/arcade/duel sends its rake here: every coin flip makes
// this week's raffle prize bigger, which is what makes the two contracts one
// product rather than two features. It used to fund r/splash/game's yield and
// prize pots; that product is retired, and nothing in SPLASH holds money beyond
// a week any more.
//
// IT CAN OPEN A WEEK, AND THEREFORE CAN PIN THAT WEEK'S BEACON ROUND. When the
// duel's rake arrives before anybody has bought a raffle ticket, this is the call
// that creates the week's record — and getOrCreateDraw pins Draw.Round there, once,
// for whichever entry point got there first (read pinOffsetRounds). A later Buy in
// the same week finds the record and never re-pins. The same beacon prerequisites as
// Buy therefore apply here, and there are now TWO: with no round ever published, and
// with no relay inside beacon.MaxEstimateStaleBlocks that raised the beacon's anchor,
// EstimatedLatestRound panics and THE SPONSORSHIP IS REFUSED.
//
// AND THAT REFUSAL IS NO LONGER A CROSS-REALM HAZARD, WHICH IS WHY THE STALENESS BOUND
// COULD BE ADOPTED AT ALL. It used to be: r/splash/arcade/duel's Collect called this
// function IN THE SAME TRANSACTION as the winner's payout, so a refusal here reverted
// that payout — permanently, since VoidStale refuses a resolved duel. Collect now BOOKS
// its rake and duel.FlushPot delivers it, so a refusal here costs the flusher a reverted
// transaction and the booked balance is still there for the next attempt. Any caller can
// clear the refusal with one Publish of drand's current round. AUDIT-2026-09-28.md
// findings 12 and 14.
//
// SPONSORSHIP BUYS NOTHING. d.tickets, d.ownerOf, d.ticketsOf and spendOf are
// all left alone: the funder gets no ticket unit, no winning chance, and no
// refundable claim. Only d.Sponsored and d.Pot move. A funder who never bought a
// ticket therefore cannot win the week they funded — ownerOfUnit can only ever
// name an address that appears in d.ownerOf, and nothing here writes to it.
//
// THAT IS STILL TRUE OF THIS FUNCTION AFTER FINDING 15, AND IT IS THE REASON THE
// EARNED-ENTRY DOOR IS A SEPARATE FUNCTION RATHER THAN A PARAMETER HERE.
// FundPotWithEntries appends ticket weight for named holders and calls this
// function for the money; this function appends nothing for anybody, and every
// caller of it — including a realm, including the duel when it has no eligible
// holders to credit — still buys exactly nothing. Do not add holders to this
// signature: the guard that makes the other door safe would then have to be here,
// on the permissionless path the arcade's rake depends on.
//
// WHY THE SEPARATE FIELD RATHER THAN JUST d.Pot += amount: read Draw.Sponsored.
// The one-line version is that d.Pot == sum(spendOf) is what makes Refund
// provably unable to overdraw, house money belongs to no buyer, and so the
// identity becomes d.Pot == sum(spendOf) + d.Sponsored rather than being
// quietly abandoned.
//
// IT FUNDS THE LIVE WEEK ONLY, AND THERE IS NO COMMITTED-WEEK RACE HERE. Commit
// accepts only a week that is already over (week < currentWeek()), so the week
// currentWeek() names is uncommitted BY CONSTRUCTION — no concurrent commit can
// freeze it under a funder's feet, and money can never land in a pot whose
// winner is already being drawn. The refusals below are therefore defensive
// rather than reachable, and are kept for the same reason Buy keeps its own
// committed-week check: if the week this funds ever stops being "the one the
// clock is on", these are the lines that still refuse.
//
// A SPONSORED WEEK WITH NO TICKETS IS NOT A DRAWABLE WEEK. Creating the week's
// record here is the same act Buy performs, and it does not make the week
// committable: Commit still panics on a zero ticket total, because there is no
// rollover and a drawless week must not exist. Such a week's sponsorship sits in
// the pot until somebody buys a ticket into it (the week is live, so they can) —
// and if the week ends with nobody having bought one, SweepDrawlessWeek registers that
// sponsorship for the next week to open (it names no destination itself — finding 28 —
// and it waits out a grace window first). THAT FUNCTION IS WHAT KEEPS THIS
// ONE SAFE: without it, funding a week that never sold a ticket stranded the money
// in a Draw that could never be committed, resolved or refunded. Refusing to create
// the record instead would mean the duel's rake bounced whenever it arrived before
// the week's first ticket sale, which would make settling a duel depend on somebody
// else's purchase.
//
// Panics if amount is not positive, if the allowance is short, or — defensively
// — if the target week is already committed or has been abandoned into refund
// (there is nothing left to fund: its buyers are taking their money back).
func FundPot(cur realm, amount int64) {
	rejectAttachedCoin(cur, "FundPot")
	// THE DUEL'S DOOR, AND ONLY THE DUEL'S, SINCE 2026-09-30. It was public and
	// unpriced until then, which made it a way to put money into a prize with no
	// floor, no fee and no credit line — i.e. everything Sponsor now charges for,
	// available for free next door. A priced door beside a free one prices nothing.
	//
	// SAME GUARD AND SAME REASONING AS FundPotWithEntries: PkgPath() is empty for a
	// user call and is the package path for realm code, so this admits exactly one
	// caller. IsUserCall would be wrong in both directions — the intended caller is a
	// realm, and any OTHER realm must still be refused.
	//
	// FundPotWithEntries REACHES THIS THROUGH ITS OWN cur, which it passes down
	// unchanged, so the previous realm is still the duel and this holds for that path
	// too. A person wanting to add to a prize calls Sponsor.
	if cur.Previous().PkgPath() != duelRealmPkgPath {
		panic("raffle: FundPot is the duel's door for its rake — to add to a prize, call Sponsor")
	}
	sweepDonations()

	if amount <= 0 {
		panic("raffle: sponsorship amount must be positive")
	}

	week := currentWeek()
	if d := getDraw(week); d != nil {
		if d.Committed {
			panic("raffle: this week is already committed — its pot is frozen")
		}
		if d.Abandoned {
			panic("raffle: this week was abandoned and refunded; there is nothing to fund")
		}
	}

	caller := cur.Previous().Address()
	if wugnot.Allowance(caller, selfAddr()) < amount {
		panic("raffle: insufficient allowance — approve this realm for the sponsorship amount first")
	}

	// EVERY CHECK ABOVE RUNS BEFORE THE PULL and the week record is created only
	// after it, so a refused call moves nothing and creates nothing. No overflow
	// guard is needed on the additions below: the transfer has already succeeded,
	// so `amount` is bounded by a real wugnot balance, and wugnot's supply is
	// bounded by the chain's ugnot supply.
	wugnot.TransferFrom(cross(cur), caller, selfAddr(), amount)

	d := getOrCreateDraw(week)
	d.Sponsored += amount
	d.Pot += amount
	heldPots += amount
	heldSponsored += amount

	chain.Emit("FundPot",
		"week", strconv.FormatInt(week, 10),
		"funder", string(caller),
		"amount", strconv.FormatInt(amount, 10),
		"sponsored", strconv.FormatInt(d.Sponsored, 10),
		"pot", strconv.FormatInt(d.Pot, 10))
	checkInvariant()
}

// Sponsor puts money into this week's prize and buys a credit line beside it.
// The sponsor gets no entries and cannot win: that is what separates a
// sponsorship from a ticket.
//
// THE PUBLIC DOOR, WHERE FundPot IS THE DUEL'S. They were one function until
// 2026-09-30 and splitting them is the whole reason the rules below can exist.
// FundPot carries the duel's rake, in whatever amount has accumulated — often
// far less than MinSponsorship, and already charged its ops share on the duel's
// side. Putting a floor or a second fee on that path would strand small flushes
// and double-charge money that has already paid. So the duel keeps its own
// unpriced door and this one is for people buying advertising.
//
// WHAT HAPPENS ON A WEEK THAT NEVER DRAWS, because a sponsor should be able to
// find it out before paying: the money stays with this week for as long as the
// week can still be drawn, which is indefinitely — Resolve has no deadline and
// the round stays publishable. A week only ends without drawing when a TICKET
// BUYER reclaims their own stake after the grace window, and at that moment this
// sponsorship, the house's cut of it included, is divided among the addresses
// holding units in this week. It does not roll forward to a future week: that
// was removed by AUDIT-2026-09-28.md findings 28 and 31, because the caller
// chose the destination by choosing when to call.
func Sponsor(cur realm, amount int64, label string) {
	rejectAttachedCoin(cur, "Sponsor")
	sweepDonations()

	if amount < MinSponsorship {
		panic("raffle: a sponsorship must be at least MinSponsorship — smaller top-ups have no credit line and no door")
	}
	checkSponsorLabel(label)

	week := currentWeek()
	if d := getDraw(week); d != nil {
		if d.Committed {
			panic("raffle: this week is already committed — its pot is frozen")
		}
		if d.Abandoned {
			panic("raffle: this week was abandoned and refunded; there is nothing to sponsor")
		}
		if len(d.Sponsors) >= maxSponsorsPerWeek {
			panic("raffle: this week already holds the maximum number of sponsorships")
		}
	}

	caller := cur.Previous().Address()
	if wugnot.Allowance(caller, selfAddr()) < amount {
		panic("raffle: insufficient allowance — approve this realm for the sponsorship amount first")
	}

	// THE SPLIT IS THE TICKET SPLIT, deliberately: one fee number across the whole
	// product rather than a second one to explain. mulDiv over the gross, exactly as
	// Buy does it, so the two doors cannot drift apart arithmetically.
	cutPart := int64(mulDiv(uint64(amount), uint64(HouseCutBps), uint64(bpsDenom)))
	potPart := amount - cutPart
	if potPart <= 0 || cutPart < 0 {
		// Unreachable at 500 bps against a floor of 100 tickets, and checked anyway:
		// this is the line where a future constant change would otherwise credit the
		// prize with nothing while still taking the fee.
		panic("raffle: sponsorship split left nothing for the pot")
	}

	// EVERY CHECK ABOVE RUNS BEFORE THE PULL and the week record is created only
	// after it, so a refused call moves nothing and creates nothing.
	wugnot.TransferFrom(cross(cur), caller, selfAddr(), amount)

	d := getOrCreateDraw(week)
	d.Sponsored += potPart
	d.Pot += potPart
	d.Cut += cutPart
	d.SponsorCut += cutPart
	d.SponsorPaid += amount
	heldPots += potPart
	heldCuts += cutPart
	heldSponsored += potPart
	d.Sponsors = append(d.Sponsors, Sponsorship{By: caller, Label: label, Amount: amount})

	chain.Emit("Sponsor",
		"week", strconv.FormatInt(week, 10),
		"sponsor", string(caller),
		"amount", strconv.FormatInt(amount, 10),
		"toPot", strconv.FormatInt(potPart, 10),
		"fee", strconv.FormatInt(cutPart, 10),
		"label", label,
		"sponsored", strconv.FormatInt(d.Sponsored, 10),
		"pot", strconv.FormatInt(d.Pot, 10))
	checkInvariant()
}

// checkSponsorLabel refuses anything that is not plain, bounded, single-line
// text. Same shape as the duel's checkLabel, and for the same reason: this is a
// stranger's text and it is about to be stored for ever.
//
// IT DOES NOT SANITISE. Escaping belongs at the point of rendering, where the
// target syntax is known — storing a pre-escaped string would mean the stored
// value and the value the sponsor typed were different things, and every later
// reader would have to know which one they held.
func checkSponsorLabel(label string) {
	if len(label) == 0 {
		panic("raffle: a sponsorship needs a credit line — that is what it buys")
	}
	if len(label) > maxSponsorLabelLen {
		panic("raffle: sponsor label too long")
	}
	if !utf8.ValidString(label) {
		panic("raffle: sponsor label is not valid UTF-8")
	}
	for i := 0; i < len(label); i++ {
		if label[i] < 0x20 || label[i] == 0x7f {
			panic("raffle: sponsor label contains a control character")
		}
	}
}

// --- the arcade's earned entries -----------------------------------------
//
// THE DEFECT THIS CLOSES (AUDIT-2026-09-28.md finding 15), in the owner's words:
// "so people could be gambling money on coinflip all week and some asshole with a
// 1cent ticket can win the pot?" Yes. The duel's rake flowed in here as
// sponsorship and PLAYING THE DUEL BOUGHT NOTHING, so a week with a busy coin
// flip and no ticket sales had a large pot, a ticket total of zero, and could be
// taken in its entirety by one 0.1 GNOT ticket bought in its final block. The
// money and the entrants came from different places.
//
// THE FIX IS THE OWNER'S OWN AND IT ADDRESSES THE CAUSE RATHER THAN GATING THE
// SYMPTOM. Duel players earn entries in the live week's draw, so the people whose
// money built the pot are in the draw for it and a lone late ticket is one entry
// among many. Nothing is refused, no minimum is imposed and no buyer is gated.
//
// RULE 1, AND IT IS THE ONE THAT MAKES THE FEATURE SAFE: ENTRIES ARE PRICED OFF
// THE RAKE PAID, NEVER OFF THE STAKE.
//
//	The duel lets a poster address an offer to one opponent, so two accounts
//	under one hand can flip each other all day and the only real cost of doing
//	it is the rake. WEIGHT ENTRIES BY STAKE AND THAT IS FREE MONEY: a 10 GNOT
//	rung is a 20 GNOT pool on a 0.6 GNOT rake, so stake-weighting would hand out
//	80 units of weight (20 GNOT / EntryUnitPrice) for 0.6 GNOT of cost — entries
//	at a THIRTY-THIRD of face value. Nobody would ever buy a ticket again and one
//	funded account would own every draw.
//
//	PRICING ENTRIES AT EXACTLY WHAT THE RAKE WOULD HAVE BOUGHT AT EntryUnitPrice
//	MAKES FLIPPING AND BUYING IDENTICAL VALUE. A self-dealer's net cost for a
//	rung-1 flip is the 3000000 ugnot rake and they earn 12 units: 250000 ugnot a
//	unit, which is EntryUnitPrice exactly. Self-dealing therefore gains nothing
//	— and is in fact weakly WORSE than buying, on two counts since 2026-09-29.
//	Only 60% of a rake reaches the pot against 95% of a ticket price, so the
//	flipper pays the same per unit into a smaller prize; and at rung 0 the floor
//	bites (600000 / 250000 = 2.4 units, floored to 2), so that rung pays 300000
//	a unit — 1.2x face value. BOTH ERRORS RUN THE SAFE WAY: flipping can be
//	dearer than buying and can never be cheaper. THAT INEQUALITY IS THE SECURITY
//	PROPERTY OF THIS WHOLE FEATURE, it is what the bound below enforces at the
//	door, and raffle_test.gno and duel_test.gno both assert the rate against
//	EntryUnitPrice rather than against a hardcoded entry count.
//
//	IT WAS TicketPrice ON BOTH SIDES OF THAT SENTENCE UNTIL 2026-09-29, when a
//	10 GNOT ticket made three of the four rungs earn nothing at all. The entry
//	unit exists so that the ticket price and the draw's granularity can move
//	independently; read EntryUnitPrice and AUDIT-2026-09-28.md finding 22.
//
// RULE 2: BOTH PLAYERS EARN, AND THE LOSER NEVER EARNS LESS. The split is the
// duel's to compute (at least one entry each, the remainder two thirds to the
// loser — see its splitEntries) and this realm neither knows nor cares which
// holder was which. What this realm enforces is the TOTAL, because the total is the
// only part that could be an attack: an uneven split of a fixed total costs nothing
// and creates no edge.
//
// "AND THE LOSER EARNS MORE" IS WHAT THIS SAID UNTIL 2026-09-29, and it is corrected
// rather than left: at the duel's bottom rung the two shares are now EQUAL, one each
// out of a two-unit total, because a floored third of 2 gave the WINNER ZERO.
// AUDIT-2026-09-28.md finding 26. Nothing this realm enforces moved — the total per
// rung is the same number it was, which is exactly why the change needed no
// permission from this side of the door.
//
// RULE 3: IT TRAVELS THE SAFE ROUTE. duel.Collect books; duel.FlushPot delivers
// and is the only caller of the function below. Collect still calls NO raffle code
// at all, which is AUDIT-2026-09-28.md finding 14 and must stay true: a panic in
// here — including this function's own refusals — costs the flusher a reverted
// transaction and can never stop a duel winner collecting.
const (
	// duelRealmPkgPath is the ONE package path FundPotWithEntries admits.
	//
	// IT IS THE FIRST AUTHORITY ANY REALM HAS EVER HELD OVER THIS ONE, and that is
	// not a small change: r/splash/game records declining a privileged cross-realm
	// entry point FIVE times, calling it "a write path on the largest pot in the
	// system sitting behind the single most commonly botched check class in Gno".
	// The reasons it is unavoidable here, each checked against the alternative:
	//
	//   - A PERMISSIONLESS entry-granting door cannot exist. Whoever calls it names
	//     the holders, so it would let anyone credit entries to any address —
	//     including a realm address whose package-derived key nobody holds, which
	//     is AUDIT-2026-09-28.md finding 8 reopened (a winner that cannot spend its
	//     pot strands the whole week's money). It would also bypass Buy's 5% house
	//     cut, so every rational buyer would use it instead of Buy and the realm's
	//     entire revenue would go to zero.
	//   - PRICING ENTRIES FROM THE DELIVERED MONEY ALONE does not need a guard, but
	//     it cannot express rule 1: the duel delivers the rake's POT SHARE (60%
	//     since 2026-09-29), so a self-enforcing floor(amount/EntryUnitPrice) would
	//     credit 1 unit for a rung-0 flip that paid 2 units' worth of rake, and the
	//     owner's design is the rake, not the part of it this realm happens to
	//     receive. The mismatch got WIDER with the 60/40 split, not narrower.
	//   - PAYING THE WHOLE RAKE THROUGH THIS REALM would make the bound exact with
	//     no guard at all, but it moves the duel's 40% ops share onto this realm's
	//     books and therefore onto its liveness. The house/player split must not
	//     move (BIBLE.md §2.6, and AUDIT-2026-09-28.md finding 14's "the split does
	//     not move on the delivery path"), so it was not done.
	//
	// SO THE GUARD IS REAL AND WHAT LIMITS IT IS THE BOUND, NOT THE GUARD. Read
	// arcadeEntryUnitsBound: a compromised duel cannot mint entries, it can only buy them,
	// and the most it can do is buy them AT 60% OF FACE VALUE with money it actually
	// delivers. It can never move a single ugnot OUT of this realm, touch spendOf, reach a
	// past week, or resolve anything.
	//
	// THE FIGURE WAS 80% UNTIL NOW AND THE CONSTANT IT DEPENDS ON MOVED WITHOUT IT —
	// AUDIT-2026-09-28.md finding 30. arcadeEntryUnitsBound grosses a delivery up by
	// arcadeBpsDenom/arcadeRakePotShareBps, which was 10000/8000 and became 10000/6000 when
	// the duel's rake split went 80/20 -> 60/40 (finding 24). RECOMPUTED FROM THE CONSTANTS
	// AS THEY STAND: one entry unit is admitted for every EntryUnitPrice of GROSSED-UP rake,
	// so the DELIVERED money per unit is EntryUnitPrice * 6000/10000 = 150,000 ugnot against
	// a face value of 250,000 — 60%, and 150,000 x 40 = 6,000,000 buys a whole ticket's
	// worth of weight for a 10,000,000 ticket price. The old figure was not wrong when it
	// was written; it was a live number written down as prose, which is how it went stale.
	//
	// IS THE DOOR STILL ADEQUATELY CONTAINED AT 60%? YES, AND THE REASON IS NOT THE
	// PERCENTAGE — this is the sentence a future reviewer should rely on, so it is written
	// out rather than implied:
	//
	//   - WHAT THE DOOR CAN DO IS UNCHANGED IN KIND. A compromised duel still cannot mint
	//     weight (every unit is paid for in delivered wugnot), cannot take money out (this
	//     realm has no outbound path it can reach), cannot touch spendOf or any past week,
	//     and cannot resolve, commit or refund anything. Its entries land in the live week
	//     and compete for a prize its own delivery enlarges.
	//   - WHAT CHANGED IS THE SIZE OF THE DISCOUNT, and it is a dilution advantage rather
	//     than a theft. Per ugnot delivered, the door now buys 1/0.6 = 1.67x the weight a
	//     buyer's ticket buys, up from 1.25x. Measured against POT CONTRIBUTION — the
	//     comparison that decides who is diluting whom, since a buyer's ticket leaves 5% in
	//     escrow — it is 237,500/150,000 = 1.58x, up from 1.19x. The attacker's cost is
	//     still real money it must hand over and which mostly ends up in the pot it is
	//     competing for; the honest buyers' loss is bounded by that dilution and is not a
	//     transfer of anything they have already paid.
	//   - AND THE LIMIT IS THE SPLIT ITSELF, WHICH IS WHY THE GUARD BELOW EXISTS. The
	//     gross-up is 10000/arcadeRakePotShareBps, so the discount is a pure function of the
	//     players' share: 80/20 gave 80%, 60/40 gives 60%, and a hypothetical 20/80 would
	//     give 20% — four ugnot of face value per ugnot delivered, at which point "it can
	//     only buy" stops being a containment argument at all. The build guard under
	//     arcadeBpsDenom refuses any split below half, so this paragraph cannot be quietly
	//     invalidated again by a change to a constant in another realm.
	duelRealmPkgPath = "gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/arcade/duel/v2"

	// arcadeRakePotShareBps and arcadeBpsDenom RESTATE r/splash/arcade/duel's
	// rakePotShareBps and bpsDenom — 6000 of 10000, the players' side of the rake.
	//
	// IT WAS 8000 UNTIL 2026-09-29. The rake total is unchanged at 300 bps of the pool
	// and the player's edge against the house in the duel did not move; only the
	// internal split did, 80/20 to 60/40 (AUDIT-2026-09-28.md finding 24). If this
	// number ever drifts from the duel's, honest batches are either refused (a stuck
	// flush) or over-admitted (finding 15 reopened) — which is why the coupling is
	// asserted from the only side that can see both, below.
	//
	// THEY ARE RESTATED BECAUSE THE IMPORT ONLY GOES ONE WAY: the duel imports this
	// realm, so this realm cannot import the duel to read them, and they are
	// unexported there in any case. Same situation as opsVaultAddr and blocksPerDay,
	// which are duplicated across three realms for the same reason.
	//
	// AND THE DUPLICATION IS CHECKED, FROM THE SIDE THAT CAN SEE BOTH. A Gno test in
	// THIS package cannot import the duel either, so the coupling is asserted in
	// duel_test.gno — TestFix15_TheRafflesEntryBoundIsExactlyThisRealmsRakeEquivalent
	// computes a rake from the duel's own constants and requires
	// raffle.ArcadeEntryUnitsBound(potShare) to equal it, to the entry. If either
	// side's split ever moves, that test fails and names both files. Do not "tidy"
	// these constants away into bpsDenom above: bpsDenom is this realm's house cut
	// denominator and has no business being load-bearing for another realm's rake.
	arcadeRakePotShareBps int64 = 6_000
	arcadeBpsDenom        int64 = 10_000
)

// THE PLAYERS' SHARE MUST BE AT LEAST HALF THE RAKE, and this line fails the BUILD if a
// future edit takes it below — a negative array length is a compile error. 6000 - 5000 =
// 1000 as the constants stand.
//
// IT GUARDS AN ARGUMENT, NOT AN ARITHMETIC PROPERTY, and that is exactly why it is here.
// arcadeEntryUnitsBound grosses a delivery up by 10000/arcadeRakePotShareBps, so the
// privileged door buys entry weight at arcadeRakePotShareBps/10000 of face value: 80% at
// the old split, 60% at this one. The containment argument above — "the most it can do is
// buy them at 60% of face value" — is a statement about THAT RATIO, and it decays as the
// players' share falls, with no arithmetic anywhere in either realm going wrong as it
// does. The figure in that paragraph had already gone stale once by exactly this route
// (AUDIT-2026-09-28.md finding 30). Half is the line at which a delivery still buys less
// than two units of face value per unit of money; below it, "it can only buy entries"
// stops containing anything and the door has to be re-audited rather than re-worded.
// Moving the split further towards ops must therefore break the build and send the editor
// to the paragraph above duelRealmPkgPath. AUDIT-2026-09-28.md findings 24 and 30.
var _ [arcadeRakePotShareBps - 5_000]struct{}

// arcadeEntryUnitsBound is the MOST entry units a delivery of `amount` ugnot of
// duel rake pot share may ever carry, and it is the security property of finding
// 15 stated in one line of arithmetic at the door.
//
// THE DERIVATION. The duel's rake splits potShare = rake - floor(rake * 4000 /
// 10000), so potShare >= rake * 6000/10000 and therefore
//
//	rake <= amount * arcadeBpsDenom / arcadeRakePotShareBps
//
// for a delivery of amount = potShare. Rule 1 prices an entry at ONE EntryUnitPrice
// of rake, so the unit ceiling is that gross-up divided by EntryUnitPrice. At rung 0:
// amount 360000 -> gross 600000 -> 2 units, which is EXACTLY what the duel credits, so
// this bound is tight rather than generous and one unit of over-issuance fails it.
//
// IT IS PRICED PER ENTRY UNIT AND NOT PER TICKET, SINCE 2026-09-29, AND THAT IS
// FINDING 22. Divided by a 10 GNOT TicketPrice this ceiling would be 0 at rung 0, 0 at
// rung 1 and 1 at rung 2 — it would refuse the duel's own honest batch at three of the
// four rungs, and a refused batch is a FlushPot that can never land, i.e. rake that
// reaches this realm's prize pot never at all. The ceiling and the duel's own
// rakeEntryUnits have to be denominated in the same unit or one of them is wrong; the
// unit is EntryUnitPrice.
//
// AND NOTE WHAT IT IS *NOT*: floor(amount / EntryUnitPrice), i.e. the units the
// DELIVERED money alone would buy. That is 1 unit at rung 0 (360000 / 250000), and it
// would refuse the honest 2-unit batch for exactly the reason the gross-up exists —
// this realm receives the players' share and prices entries off the whole rake. It is
// alternative 2 from the block above duelRealmPkgPath, rejected there because it cannot
// express the owner's pricing rule.
//
// IT NEVER REFUSES AN HONEST BATCH, INCLUDING AN AGGREGATED ONE. FlushPot delivers
// the sum of several duels' pot shares against the sum of their entries. Each
// duel's rake_i <= potShare_i * 1.25 exactly, sum(rake_i) is an integer no greater
// than amount * 1.25, and floor() of a real bound is still >= any integer below
// it — so the aggregate bound is never smaller than the aggregate claim. Dust can
// only ever make the bound looser, never tighter.
//
// EXPORTED so the duel's suite can pin the two realms' arithmetic to each other
// (see arcadeRakePotShareBps), and so anybody can check the rate off-chain. A
// plain read: no state, no authority, nothing it can be called for.
func ArcadeEntryUnitsBound(amount int64) int64 {
	if amount <= 0 {
		return 0
	}
	return arcadeEntryUnitsBound(amount)
}

func arcadeEntryUnitsBound(amount int64) int64 {
	// mulDiv, not a raw product: amount is token-scale and bps-scale multiplication
	// on int64 wraps silently on this VM (see mulDiv).
	gross := int64(mulDiv(uint64(amount), uint64(arcadeBpsDenom), uint64(arcadeRakePotShareBps)))
	return gross / EntryUnitPrice
}

// FundPotWithEntries is FundPot plus the earned entries that rake bought, in ONE
// call, and it is callable only by r/splash/arcade/duel. Returns the total entry
// units credited.
//
// READ THE BLOCK ABOVE duelRealmPkgPath FIRST: it has the defect, the three rules,
// why this door is privileged and why the bound rather than the guard is what
// makes it safe.
//
// WHY ONE CALL AND NOT TWO. The money and the entries must land in the SAME week
// and the same transaction, or the pot identity and the ticket index could
// disagree about which week the duel's rake belonged to. A caller cannot deliver
// one without the other, cannot deliver entries worth more than the money, and
// cannot choose the week — currentWeek() decides, exactly as FundPot's does.
//
// THE MONEY PATH IS FundPot'S, UNCHANGED AND NOT COPIED. This function calls
// FundPot directly (a non-crossing call within this realm, so cur.Previous() is
// still the duel and the pull is still caller-pays out of the duel's own
// allowance). Every refusal FundPot makes — non-positive amount, a committed or
// abandoned week, a short allowance, a beacon too stale to pin a new week's round
// — therefore applies here identically, and no second version of the sponsorship
// bookkeeping exists to drift from the first.
//
// WHAT AN EARNED ENTRY IS, EXACTLY: one unit appended to this week's ticket index
// with NO spendOf record.
//
//	APPENDED, NEVER INSERTED OR ADJUSTED. appendTickets is the same function Buy
//	uses, so an earned entry is a new index whose prefix starts at the whole
//	total at the moment it was appended. That is the frozen-ownership property
//	Commit's argument rests on (finding 10) and the reason fenwick rejects
//	negative deltas by design. Nothing here touches an existing index.
//
//	AND NO spendOf RECORD, WHICH IS CORRECT AND IS NOT AN OVERSIGHT. The holder
//	paid no ticket money to this realm; what they paid was the duel's rake, and
//	that money is in this week's pot as Sponsored. So:
//
//	  - Pot == sum(spendOf) + Sponsored is UNAFFECTED. Entries carry no money of
//	    their own; the money term is FundPot's, and it is counted once.
//	  - Refund pays spendOf only, so a holder of nothing but earned entries
//	    reclaims nothing, which is right: they have no ticket money here to
//	    reclaim, and their rake is in Sponsored.
//	  - On an abandoned week THE SPONSORSHIP GOES TO THE EARNED-ENTRY HOLDERS, pro
//	    rata, as a claim on that same week, and buyers reclaim their own gross. The
//	    sentence that stood here was PRECISELY INVERTED and is kept because a reader
//	    who has read this file before will be carrying it: "On an abandoned week
//	    Sponsored goes to opsPot and buyers reclaim their spend; EARNED-ENTRY HOLDERS
//	    GET NOTHING. Also right, and it is the same money-belongs-to-no-buyer rule
//	    Refund already applies." Earned-entry holders are the INTENDED BENEFICIARIES —
//	    the rake is theirs and they can recover it by no other route — and it is
//	    BUYERS who get nothing from it, having contributed nothing to it and having
//	    their whole ticket price back. AUDIT-2026-09-28.md findings 16, 31 and 34; read
//	    retireSponsorship and ClaimDeadWeek. Only a week with NO earned holder at all
//	    sends this money to opsPot.
//	  - A WEEK CAN NOW HAVE TICKETS AND ZERO spendOf — every entry earned, none
//	    bought. Commit requires tickets > 0 and gets it, Resolve pays the winner
//	    the sponsorship, and that is precisely the intent: the flippers draw for
//	    the pot their own rake built. SWEEPING SUCH A WEEK IS ITS SHAPE 2 AND FIRES ON
//	    EXACTLY IT, once committed and once the grace window has passed with no draw.
//	    The retired claim, which was wrong from the day finding 17 was implemented:
//	    "SweepDrawlessWeek requires ZERO tickets and therefore correctly will not fire
//	    on such a week — its sponsorship is a real prize now, not stranded money." The
//	    ZERO-TICKET requirement is shape 1 only. Finding 17 added shape 2 for this very
//	    week, because Resolve was otherwise its ONLY exit and no clock could rescue it —
//	    and shape 2 then retires the sponsorship to the earned holders rather than
//	    stranding it. Read SweepDrawlessWeek's two shapes.
//	  - Finding 3's one-way Abandoned flag still covers the fact that refunds
//	    cannot retire tickets. An earned entry is as un-retirable as a bought
//	    one and is safe for the same reason: no draw over an abandoned week's
//	    ticket set will ever happen.
//
// THE HOLDERS ARE THE DUEL'S TO NAME AND THIS REALM DOES NOT SECOND-GUESS THEM,
// with one exception it cannot check and one it can. It cannot check that a holder
// is an EOA — there is no such predicate for a bare address on this toolchain —
// so THE DUEL credits only parties whose own Post or Accept was a direct user
// call, which is where finding 8's reasoning has to live for earned entries. It
// can and does check that every holder is a valid non-empty address and every
// unit count is positive, so a malformed batch fails loudly instead of appending
// an index nobody owns.
//
// Panics if the caller is not the duel realm, if the two slices disagree in
// length, if either is empty, if any unit count is not positive, if any holder is
// invalid, or if the batch claims more units than the delivered money could have
// bought.
func FundPotWithEntries(cur realm, amount int64, holders []address, units []int64) int64 {
	rejectAttachedCoin(cur, "FundPotWithEntries")
	// THE GUARD. There are TWO in this file since 2026-09-30 — FundPot gained the same one. PkgPath() is empty for a user
	// call and is the package path for realm code, so this admits exactly one
	// caller: the duel's FlushPot. IsUserCall/IsUser would be the wrong check here
	// in both directions — the intended caller is a realm, and any OTHER realm must
	// still be refused.
	if cur.Previous().PkgPath() != duelRealmPkgPath {
		panic("raffle: only " + duelRealmPkgPath + " may credit earned entries")
	}
	if len(holders) != len(units) {
		panic("raffle: earned entries: holders and units must have the same length")
	}
	if len(holders) == 0 {
		panic("raffle: earned entries: nothing to credit — use FundPot for a plain sponsorship")
	}

	// THE BOUND IS COMPUTED AND CHECKED BEFORE ANY MONEY MOVES, this file's
	// discipline everywhere. The per-element test is not redundant with the running
	// one: without it a single absurd unit count could carry the sum past an int64
	// and land back inside the bound. With both, the sum never exceeds 2 * bound.
	bound := arcadeEntryUnitsBound(amount)
	total := int64(0)
	for i := 0; i < len(units); i++ {
		if units[i] <= 0 {
			panic("raffle: earned entry units must be positive")
		}
		if holders[i] == "" || !holders[i].IsValid() {
			panic("raffle: earned entries must name a valid holder address")
		}
		if holders[i] == cur.Previous().Address() {
			// THE CALLER MAY NOT CREDIT ITSELF, which is the one finding-8 case this
			// realm CAN see: the caller is a realm by construction here, so its address
			// is package-derived, and a realm holding ticket weight could win a week and
			// strand the whole pot in an address nobody can spend from. No honest batch
			// contains it — the duel credits the two players of a settled duel and never
			// the realm — so this costs nothing and closes the most likely shape of a
			// future bug on the other side of the boundary.
			panic("raffle: earned entries may not be credited to the calling realm itself")
		}
		// AND THE DOOR MUST REFUSE THIS REALM'S OWN ADDRESS TOO — AUDIT-2026-09-28.md
		// finding 18. The guard above rejected the duel and not the raffle, which left the
		// containment argument one address short of complete.
		//
		// WHAT IT COSTS TO OMIT IT, AND NOTE THAT THE CEILING DOES NOT HELP HERE. The
		// whole authorisation argument for this privileged door is "the money-backed
		// ceiling limits what it can do, not the guard" (see duelRealmPkgPath and
		// arcadeEntryUnitsBound) — but the ceiling has no opinion about WHO holds a unit.
		// A holder of selfAddr() that wins reaches
		// wugnot.Transfer(cross(cur), winner = selfAddr(), pot) in Resolve, AFTER
		// heldPots -= pot has already been written. Either wugnot refuses a self-transfer
		// and Resolve panics, or it succeeds as a no-op while heldPots has dropped and
		// checkInvariant's heldPots + opsPot == balance fails. BOTH BRANCHES REVERT Resolve
		// PERMANENTLY AND STRAND THAT WEEK'S WHOLE POT — the same class as findings 1, 6
		// and 7. Which branch actually applies is pinned by
		// TestFix18_WugnotRefusesAnAddressTransferringToItself rather than reasoned about.
		//
		// THE OPS VAULT IS REFUSED ON THE SAME REASONING. opsVaultAddr is
		// gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops, a PACKAGE-DERIVED address at which no code exists yet
		// (AUDIT-2026-09-28.md findings 11-14's fourth, still-blocking defect), so a pot
		// pushed there is a pot nobody can spend — finding 8 exactly, and the reason Buy
		// requires IsUserCall.
		//
		// UNREACHABLE THROUGH THE HONEST DUEL TODAY, which is why this is a contingency
		// fix and not an emergency: the duel credits the two parties of a settled duel and
		// they are EOAs by its own PosterIsUser/TakerIsUser gate. It restores the
		// containment this door's authorisation rests on, and it costs an honest batch two
		// comparisons.
		if holders[i] == selfAddr() {
			panic("raffle: earned entries may not be credited to this realm itself")
		}
		if holders[i] == opsVaultAddr {
			panic("raffle: earned entries may not be credited to the ops vault")
		}
		if units[i] > bound {
			panic("raffle: earned entries exceed what the delivered rake could buy at the entry unit price")
		}
		total += units[i]
		if total > bound {
			panic("raffle: earned entries exceed what the delivered rake could buy at the entry unit price")
		}
	}

	// THE MONEY, THROUGH THE AUDITED PATH. Non-crossing, so cur.Previous() inside
	// FundPot is still the duel: it sweeps donations, applies every one of its own
	// refusals, pulls the duel's own wugnot, credits Sponsored and Pot, and checks
	// the invariant. If it refuses, this whole transaction reverts and the duel's
	// booked rake is untouched — which is finding 14's property and the reason
	// Collect must never call any of this.
	FundPot(cur, amount)

	week := currentWeek()
	d := getDraw(week)
	if d == nil {
		// Unreachable: FundPot above created the week's record if it did not exist.
		// Loud rather than dropping entries the money has already been taken for.
		panic("raffle: earned entries: the week has no record after funding it")
	}

	// appendEarnedTickets, NOT appendTickets — AUDIT-2026-09-28.md finding 34. It appends the
	// draw weight exactly as a purchase does AND records that this weight was EARNED, which is
	// the basis a dead week's sponsorship is divided on. Read Draw.earnedOf for why the draw
	// and the claim cannot share one basis, and appendEarnedTickets for why the two writes are
	// inside one function rather than two lines of this loop.
	for i := 0; i < len(holders); i++ {
		appendEarnedTickets(d, holders[i], units[i])
		chain.Emit("ArcadeEntries",
			"week", strconv.FormatInt(week, 10),
			"holder", string(holders[i]),
			"units", strconv.FormatInt(units[i], 10),
			"heldUnits", strconv.FormatInt(treeInt64(d.ticketsOf, string(holders[i])), 10),
			"heldEarnedUnits", strconv.FormatInt(treeInt64(d.earnedOf, string(holders[i])), 10),
			"weekTickets", strconv.FormatInt(d.tickets.Total(), 10),
			"weekEarned", strconv.FormatInt(d.earnedTotal, 10))
	}

	chain.Emit("ArcadeEntriesCredited",
		"week", strconv.FormatInt(week, 10),
		"holders", strconv.Itoa(len(holders)),
		"units", strconv.FormatInt(total, 10),
		"weekEarned", strconv.FormatInt(d.earnedTotal, 10),
		"amount", strconv.FormatInt(amount, 10),
		"unitsBound", strconv.FormatInt(bound, 10),
		"entryUnitPrice", strconv.FormatInt(EntryUnitPrice, 10))
	checkInvariant()
	return total
}

// --- Commit --------------------------------------------------------------

// Commit commits an ALREADY-FINISHED week to a future beacon round. Returns
// that round.
//
// THE WEEK IS A PARAMETER AND IT MUST BE OVER — week < currentWeek(). Both
// halves of that sentence are load-bearing, and each fixes a defect the first
// version of this function had:
//
//   - IT TAKES A WEEK, so any past week can be committed at any time, by
//     anyone. Before, Commit could only ever act on currentWeek(), which meant
//     a week whose clock ran out before anybody called it could never be
//     committed — and because Resolve and Refund both require Committed, that
//     week's whole pot was unreachable forever while heldPots went on counting
//     it, so the invariant and the audit both stayed green over money nobody
//     could ever get back. A stranded week is now always recoverable: commit
//     it, then resolve it, or refund it if its round was lost.
//
//   - THE LIVE WEEK CAN NEVER BE COMMITTED, so a commit can no longer cut a
//     week's sales short. Before, anyone could Buy(1) and immediately Commit:
//     that made them the sole owner of a FrozenTotal of 1 — the guaranteed
//     winner — and, because Buy refuses a committed week, shut the week's sales
//     for its remaining days. It cost the attacker the 5% cut on one ticket and
//     was repeatable every week with no admin and no pause to stop it; the
//     front-running variant landed a commit just ahead of somebody's large Buy
//     and made their purchase panic. Refusing week >= currentWeek() closes all
//     of that at the root rather than with a minimum-tickets or minimum-elapsed
//     heuristic: the week being sold into is simply not a committable week.
//
// PERMISSIONLESS: there is no keeper and no admin. Anyone who wants the draw to
// happen — every ticket holder, for a start — can call it, once the week is up.
//
// It freezes two numbers, and CHOOSES NOTHING:
//
//   - FrozenTotal = the week's final ticket total. The week is over and Buy
//     only ever sells into currentWeek(), so this total can no longer grow
//     BY CONSTRUCTION; it is still assigned explicitly, because Resolve reads
//     this field and not the live total.
//   - Pot, which stops growing for the same reason (and Buy also refuses a
//     committed week, which is now a second, unreachable-by-design lock).
//   - AND IT USES Draw.Round EXACTLY AS PINNED, which was written when this week's
//     record was created and is not this function's business. See below.
//
// THE SECURITY RULE, AND THE ONLY REASON THIS IS THREE PHASES: the ticket set
// must be frozen BEFORE the randomness is knowable. If the total were read at
// resolve time, anybody who saw the published round could compute the winning
// unit and then buy precisely enough tickets to own it — which turns a raffle
// into a purchase.
//
// THIS FUNCTION NO LONGER BINDS THE ROUND, AND THAT IS THE 2026-09-28 FIX. It used
// to set Round = beacon.Latest() + 1 here, which looked like the conservative
// choice — the round is unpublished at commit time, so its randomness "does not
// exist yet" — and was in fact the operator's cheapest attack on the product: the
// beacon's key holder knows every round's randomness in advance, and Commit ran
// AFTER the week's ticket set was frozen and public, so they could enumerate
// candidate rounds, Publish until Latest()+1 named them, and commit. The round is
// now pinned at record creation instead; read pinOffsetRounds for the full account,
// including what remains open.
//
// THERE IS DELIBERATELY NO "THE ROUND MUST STILL BE IN THE FUTURE" CHECK HERE, and
// the old `round <= latest` wrap check is gone with it. A reader who expects one
// has the fix backwards. A week is committed at least a week after its round was
// pinned, so by now the pinned round MAY LEGITIMATELY ALREADY BE PUBLISHED — that
// is the ordinary case for a week whose record opened early, and it is harmless
// precisely because nobody chose it: the round was fixed before a single ticket of
// that week had been sold. Requiring it to be unpublished would refuse the honest
// case and, worse, would reintroduce round selection through the back door, since
// the only way to satisfy such a check would be to recompute the round here. The
// wrap case the old check guarded is now handled where the arithmetic happens, at
// maxPinnableLatest.
//
// WHY FREEZING THE TOTAL ALSO FREEZES WHO OWNS UNIT k — the part the old realm
// got wrong first time, and the reason Buy appends:
//
//   - Every purchase APPENDS A NEW ticket index (appendTickets). No index's
//     value is ever increased afterwards, and fenwick.Add is not called from
//     this realm at all.
//   - An appended index therefore starts at a prefix equal to the whole total
//     at the moment it was appended, so anything appended after Commit lies at
//     or beyond FrozenTotal — outside the frozen range by construction, not by
//     convention.
//   - And because no earlier index's value changes, no earlier prefix moves:
//     the owner of every unit below FrozenTotal is fixed from the instant that
//     unit was sold.
//
// WITH ONE INDEX PER BUYER INSTEAD, a further purchase would grow that buyer's
// existing value, widening their range IN PLACE, from its start, inside the
// frozen range, and pushing every later buyer along. The earliest buyer (prefix
// 0 forever) could then wait for the round to publish, compute
// k = randomness mod FrozenTotal, buy until their own value exceeded k, and
// call Resolve to take the pot: a free option on the whole pot. That exploit
// was real in r/splash/game and its fix is what this realm inherits. Buy's
// refusal after commit closes the same door a second time.
//
// A WEEK'S TICKET TOTAL MAY BE ENTIRELY EARNED AND THIS FUNCTION DOES NOT CARE.
// Since finding 15 a week can reach this point with tickets and NO spend records at
// all — every entry credited to a duel player through FundPotWithEntries, not one
// ticket bought. total > 0 is satisfied, the week commits, and Resolve pays the
// winner a pot made purely of the rake those players paid. That is the intent, and
// it is why the zero-ticket refusal below is a check on the TICKET INDEX and not on
// the spend records: a drawless week is one nobody entered, not one nobody paid
// this realm directly.
//
// Panics if the week is not over yet, if it is already committed, or if it has no
// tickets at all (there is NO ROLLOVER, so a drawless week must never be allowed
// to exist). It no longer reads the beacon at all: the "no round has ever been
// published" refusal moved to the pin, which is to say to Buy and FundPot, where a
// sale is refused rather than accepted into a week that could never be drawn.
func Commit(cur realm, week int64) int64 {
	rejectAttachedCoin(cur, "Commit")
	sweepDonations()

	if week >= currentWeek() {
		// THE WHOLE OF THE GRIEFING FIX. Tickets are still being sold into
		// currentWeek(), and a future week is not a week at all yet.
		panic("raffle: a week can only be committed once it is over")
	}

	d := getDraw(week)
	if d == nil {
		panic("raffle: no tickets sold this week — there is no rollover, so a drawless week must not exist")
	}
	if d.Committed {
		panic("raffle: this week is already committed")
	}
	total := d.tickets.Total()
	if total == 0 {
		panic("raffle: no tickets sold this week — there is no rollover, so a drawless week must not exist")
	}

	// THE ROUND IS READ, NOT CHOSEN. getOrCreateDraw pinned it when this week's
	// record was created; see pinOffsetRounds and the note above about why there is
	// no check on its publication state here.
	round := d.Round
	if round <= 0 {
		// Unreachable: getOrCreateDraw is the only way a Draw comes into existence
		// and it always pins a positive round. Stated loudly because the pin IS the
		// security property — and deliberately NOT "pin one now as a fallback",
		// which would hand the round choice straight back to the committer.
		panic("raffle: this week's record has no pinned beacon round")
	}

	d.Committed = true
	d.FrozenTotal = total
	// d.Round IS NOT ASSIGNED HERE. It was pinned at record creation and this
	// function must never write it; `round` above is a read.
	//
	// THE HEIGHT THE REFUND GRACE WINDOW COUNTS FROM. Recorded here and nowhere
	// else, because this is the moment the pot becomes unreachable by any route
	// except Resolve or Refund — so it is the moment from which a buyer's
	// beacon-independent claim on their own money starts to age. See
	// refundGraceBlocks and Refund.
	d.CommittedAt = runtime.ChainHeight()

	chain.Emit("Commit",
		"week", strconv.FormatInt(week, 10),
		"frozenTotal", strconv.FormatInt(total, 10),
		"round", strconv.FormatInt(round, 10),
		"pot", strconv.FormatInt(d.Pot, 10),
		"committedAt", strconv.FormatInt(d.CommittedAt, 10),
		"refundOpensAt", strconv.FormatInt(d.CommittedAt+refundGraceBlocks, 10))
	checkInvariant()
	return round
}

// --- Capture -------------------------------------------------------------

// Capture copies a committed week's beacon randomness into the draw.
//
// IT IS NO LONGER A SAFETY MECHANISM, AND SAYING SO IS THE POINT OF THIS COMMENT.
// What it used to say: "the beacon keeps signatures for beacon.PruneWindow = 2016
// rounds, about seven days at a five-minute cadence; this raffle is WEEKLY, so a draw
// settled late can find its round already pruned and the pot would have no way to name
// a winner. Capture preserves the value while it is still there." Every clause of that
// is now false. r/splash/beacon has no retention window and no Prune, drand serves
// every round for ever from at least three public relays, and Publish is
// permissionless — SO THERE IS NOTHING TO PRESERVE THE VALUE FROM. There is no capture
// window either; the old paragraph computed one, and it does not exist.
//
// WHAT IT STILL DOES, which is why it is kept rather than removed:
//
//   - it copies a public value into the draw's own state, so Resolve needs no beacon
//     read later and the settled draw is self-contained;
//   - it makes the value visible through CapturedRandomness and the Capture event
//     before the week is settled, which a front end and an auditor can both use.
//
// A CONVENIENCE, then. Removing it would delete an exported realm function and a
// large block of correct, tested behaviour in order to retire a comment; retiring the
// comment is enough. Nothing in this realm's safety now depends on anyone calling it —
// see resolvable()'s removal and Refund's gate.
//
// PERMISSIONLESS, deliberately. Its only effect is to store a value that is
// already public — the round's randomness, readable by anyone the moment it is
// published. Gating it on an operator would buy nothing and would put a
// liveness dependency for the whole pot back onto one key.
//
// WHAT IS STORED IS THE 64-CHARACTER HEX RANDOMNESS — sha256 of the signature,
// a hash, not the signature itself — and it is NOT re-verified here. The
// pairing check happened once already inside beacon.Publish on the way in;
// redoing it would be expensive duplicated work on an input that is already
// known good, and the beacon has no route by which a published round's
// randomness can change afterwards.
//
// A SECOND Capture NEVER OVERWRITES THE FIRST, and is a silent no-op rather
// than a panic: two callers racing to perform a permissionless public good
// should not make one of them fail.
//
// Capturing before the round is published PANICS. There is nothing to preserve
// yet, and storing anything else — least of all some already-published value —
// would hand the draw a randomness for a round nobody pinned, which is the exact
// attack the pin exists to prevent.
//
// COMMIT DOES NOT CAPTURE, AND MUST NOT START. Since the round is pinned at record
// creation, a week's round may well be published by the time it is committed, so a
// capture there would often succeed — and it would put a beacon read back inside the
// one function whose job is to choose nothing. Capture staying separate and
// permissionless is what keeps the commit path free of any beacon dependency at all;
// see Commit's note on why there is no publication check there either.
func Capture(cur realm, week int64) {
	rejectAttachedCoin(cur, "Capture")
	sweepDonations()

	d := getDraw(week)
	if d == nil {
		panic("raffle: no draw for that week")
	}
	if !d.Committed {
		panic("raffle: this week is not committed yet")
	}
	if d.Resolved {
		panic("raffle: this week's draw is already resolved")
	}
	if d.Abandoned {
		// The week is in refund and can never be resolved, so there is nothing
		// left for a captured randomness to be used for. Refusing keeps the one
		// exit one-way at every entry point rather than only at Resolve.
		panic("raffle: this week was abandoned and refunded; there is nothing to capture")
	}
	if d.Randomness != "" {
		// Already captured: keep the first value, without failing the caller.
		return
	}
	if !beacon.Published(d.Round) {
		panic("raffle: beacon round not published yet")
	}

	rnd := beacon.Randomness(d.Round)
	if len(rnd) != randomnessHexLen {
		// A length check, NOT a re-verification: it only asserts the shape of
		// the value this realm is about to depend on, so that an empty or
		// truncated string can never be mistaken for "captured" (the empty
		// string is this field's "not captured" sentinel).
		panic("raffle: beacon randomness has the wrong length")
	}
	d.Randomness = rnd

	chain.Emit("Capture",
		"week", strconv.FormatInt(week, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"randomness", rnd)
	checkInvariant()
}

// --- Resolve -------------------------------------------------------------

// Resolve picks the week's winner and PAYS THEIR WALLET. PERMISSIONLESS.
//
// THIS IS THE ONE PLACE THIS REALM DIVERGES FROM r/splash/game ON PURPOSE.
// There, the pot was credited to the winner's locked position, which meant the
// prize could never be spent and the winner's stake grew instead. Here the
// whole pot leaves this realm in a single wugnot.Transfer to the winner's
// address. No internal balance is credited, there is nothing left to claim
// afterwards, and no buyer's money is held past the week they bought into.
//
// winner = ownerOfUnit(randomness mod FrozenTotal). FrozenTotal, NOT the live
// ticket total: recomputing it here would reopen the buy-the-winning-unit
// attack described on Commit.
//
// THE POT PAYS OUT UNTAXED, AND THE FEE IS TAKEN HERE — NOT AT SALE TIME. This
// paragraph read "The house cut was already taken on the way in, at sale time; taxing
// the payout as well would be charging twice for the same ticket" until 2026-09-29, and
// the first half stopped being true that day: since finding 25 a sale ESCROWS the fee in
// Draw.Cut and this function is what earns it, moving the week's whole escrow to opsPot
// in a separate step from the prize. The conclusion is unchanged and so is the money —
// the winner still receives Pot and nothing is deducted from it here — but a reader
// looking for where the house is paid must look at this function and not at Buy.
// AUDIT-2026-09-28.md finding 29.
//
// RANDOMNESS SOURCE: a captured value if there is one, otherwise the beacon
// directly — so the happy path needs no extra transaction.
//
// THERE IS ONE FAILURE MESSAGE, AND THERE USED TO BE TWO. The pair was
// "not published yet" (wait and retry; the draw is fine) and "published and is now
// pruned, and nobody captured it" (the signature is gone, retrying will never help,
// Refund is the way out), and keeping them distinguishable was load-bearing because
// Refund's precondition WAS that distinction. Since the drand migration the second
// state cannot occur: no round is ever unobtainable, so "retrying will never help" is
// never true. Collapsing the two was therefore required, not a simplification — a
// realm that still said it would be steering buyers into refunds they do not need.
// Anyone who sees the remaining message can relay the round themselves.
//
// THERE IS NO HEIGHT GATE HERE, AND THERE MUST NEVER BE ONE. refundGraceBlocks
// does not appear in this function and CommittedAt is not read: the grace window
// is a FLOOR ON BUYER ACCESS, NOT A DEADLINE ON THE DRAW. It only ever opens
// Refund; it never closes Resolve.
//
// WHY THAT ASYMMETRY IS THE RIGHT ONE. The defect the grace window closes is that
// a stalled beacon left the buyers with no way to reach their own money. It is not
// that a late draw is illegitimate — an honest publication that arrives a fortnight
// after commit, before anybody has refunded, should still pay the winner it always
// would have, and the FrozenTotal it draws over is exactly the set it was frozen
// with. Adding a height deadline here would create a second class of dead week —
// past the grace, published, and resolvable by nobody — which is the very shape of
// defect this window exists to remove.
//
// WHAT DOES CLOSE THIS FUNCTION IS Abandoned, as before, and that is enough. Once
// the grace window has opened, Resolve and Refund are both available and the first
// one called wins: a refund sets Abandoned and this function refuses for ever, a
// resolve pays the winner and Refund's Resolved check refuses for ever. Neither
// ordering can pay the same ugnot twice, which is the property that matters. (The
// fairness cost of that race is recorded in AUDIT-2026-09-28.md finding 7: past the
// grace window, on a week whose round HAS since been published, a buyer who can see
// they did not win can refund rather than lose. It is bounded by the window being
// twice the beacon's entire retention — the state only exists after an outage — and
// closing it properly means a two-phase refund, which is a separate change.)
func Resolve(cur realm, week int64) {
	rejectAttachedCoin(cur, "Resolve")
	sweepDonations()

	d := getDraw(week)
	if d == nil {
		panic("raffle: no draw for that week")
	}
	if !d.Committed {
		panic("raffle: this week is not committed yet")
	}
	if d.Resolved {
		panic("raffle: this week's draw is already resolved")
	}
	if d.Abandoned {
		// PERMANENT, AND DELIBERATELY NOT CONDITIONAL ON THE BEACON. Refunds are
		// open on this week and at least one buyer has already taken their money
		// out, so the frozen range no longer corresponds to who is still owed.
		// Resolving now would draw over the original range and pay whatever is
		// left of the pot — other buyers' money — to a possibly-refunded winner.
		// See Draw.Abandoned for why the beacon cannot be trusted to keep this
		// week unresolvable on its own.
		panic("raffle: this week was abandoned and refunded; it can never be resolved")
	}
	if d.FrozenTotal <= 0 {
		// Unreachable: Commit refuses a zero total. Loud rather than a
		// division by zero inside randomnessMod.
		panic("raffle: draw has no frozen tickets")
	}

	rnd := d.Randomness
	if rnd == "" {
		if beacon.Published(d.Round) {
			rnd = beacon.Randomness(d.Round)
		} else {
			// ONE MESSAGE, NOT TWO, SINCE THE DRAND MIGRATION — AND THE OTHER ONE
			// MUST NOT COME BACK. There used to be a second branch here, reached
			// when d.Round fell outside beacon.PruneWindow, saying "beacon round
			// was published and is now pruned, and nobody captured it": the draw is
			// dead, retrying will never help, Refund is the way out. THAT STATE NO
			// LONGER EXISTS. r/splash/beacon has no retention window and no Prune,
			// every drand round is served for ever by at least three public relays,
			// and Publish is permissionless — so any caller who sees the message
			// below can make it stop being true for ~17.0M gas. "Retrying will never
			// help" is never true again, and a realm that said otherwise would be
			// steering buyers into a refund they did not need.
			// The wording is UNCHANGED from before the migration, deliberately:
			// it was already the correct thing to say, and it is now the only
			// thing there is to say.
			panic("raffle: beacon round not published yet")
		}
	}

	winner := ownerOfUnit(d, randomnessMod(rnd, d.FrozenTotal))

	pot := d.Pot
	// THE ONE MOMENT THE HOUSE'S FEE IS EARNED — AUDIT-2026-09-28.md finding 25. The
	// draw happened, so the week's escrowed Cut becomes ops revenue here and NOWHERE
	// ELSE. Buy does not credit opsPot, Commit does not, Capture does not; a week that
	// reaches any other terminal state returns the fee to its buyers instead.
	//
	// IT IS MOVED, NOT PAID: no wugnot leaves the realm for it, so the balance side of
	// checkInvariant does not move for this half at all. heldCuts falls by exactly what
	// opsPot gains, which is why the three-term equality still holds across the whole
	// function even though the transfer below reduces the balance by `pot`.
	//
	// AND IT IS DELIBERATELY NOT ADDED TO `pot`. The winner must not win our fee (read
	// Draw.Cut); the two amounts are computed, booked and reported separately, and the
	// only transfer out of this function is the prize.
	cut := d.Cut
	d.Resolved = true
	d.Winner = winner
	d.Pot = 0
	d.Cut = 0
	// AND SponsorCut WITH IT: it describes a SUBSET of d.Cut, and d.Cut is now zero.
	// Leaving it set made SponsorCutOf report an escrowed fee on a week whose fee had
	// already been released to ops — the only state in which SponsorCut > Cut, and a
	// direct contradiction of that read's own documented contract. 2026-09-30 audit,
	// finding Y1. No money moves here; the fee went to ops with the rest, which is the
	// rule for a week that DID draw.
	d.SponsorCut = 0
	heldPots -= pot
	heldCuts -= cut
	opsPot += cut
	// THE WINNER TAKES THE SPONSORSHIP TOO — that is the point of it: the pot is
	// the buyers' money plus whatever the duel's rake and any other funder added,
	// and it leaves in one transfer. d.Sponsored is deliberately NOT zeroed: it
	// stays as the record of what this week's prize was made of, and heldSponsored
	// counts unresolved weeks only (see its comment), so it is what drops here.
	heldSponsored -= d.Sponsored

	if pot > 0 {
		// Books first, transfer second. wugnot's Transfer has no hook or
		// callback, so there is no reentrancy to fear either way, but writing
		// the state first means a future GRC20 with a hook cannot see a pot
		// that has already been promised and not yet zeroed.
		wugnot.Transfer(cross(cur), winner, pot)
	}

	chain.Emit("Resolve",
		"week", strconv.FormatInt(week, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"winner", string(winner),
		"pot", strconv.FormatInt(pot, 10),
		"cutEarned", strconv.FormatInt(cut, 10),
		"sponsored", strconv.FormatInt(d.Sponsored, 10))
	checkInvariant()
}

// --- Refund --------------------------------------------------------------

// resolvable() IS GONE, AND ITS ABSENCE IS THE LARGEST SINGLE CONSEQUENCE OF THE
// DRAND MIGRATION IN THIS FILE. It read:
//
//	func resolvable(d *Draw) bool {
//		if d.Randomness != "" { return true }
//		if beacon.Published(d.Round) { return true }
//		latest, _ := beacon.Latest()
//		return d.Round > latest-beacon.PruneWindow
//	}
//
// The third line was the whole function: it is how this realm decided "the round
// came and went, nobody kept it, and so this draw can NEVER be resolved". Refund
// existed for precisely that state and said so.
//
// THAT STATE CANNOT OCCUR AGAINST DRAND. Every round from 1 to the head is served
// for ever by at least three independent public relays; r/splash/beacon has no
// PruneWindow and no Prune, so nothing on this chain deletes a stored round either;
// and Publish is permissionless, so a round that is missing here is a round anyone
// can put here. A pinned round is ALWAYS eventually resolvable. The failure mode
// that remains is not "the randomness is lost", it is "nobody has bothered to relay
// it" — a LIVENESS failure.
//
// SO THE FUNCTION IS IDENTICALLY TRUE, AND IT IS DELETED RATHER THAN LEFT RETURNING
// true. A stub that always returns true is a place for someone to add a condition.
//
// AND MIND THE TRAP IN THE OBVIOUS ALTERNATIVE, because it is a fund-drain and not
// a cosmetic error. Dropping only the PruneWindow term and keeping the other two
// would make a freshly committed week whose round is not yet relayed report NOT
// resolvable — and Refund's gate opens as soon as resolvable() is false. Refunds
// would open IMMEDIATELY on every live draw. Deleting the term looked like the small
// change; deleting the function is the correct one.
//
// WHAT REFUND NOW GATES ON is refundGraceElapsed alone — the height window added as
// AUDIT-2026-09-28.md finding 7. It was one of two independent openers and is now
// the only one, which is the right shape: a beacon-state gate cannot distinguish
// "not relayed yet" from "never will be", and a clock can.
//
// AND FINDING 7'S RECORDED FAIRNESS COST STOPS BEING EXOTIC, which must be said out
// loud rather than inherited. Past the grace window, on a week whose round HAS since
// been relayed, a buyer who can see they did not win can refund instead of losing.
// Under the old design that state only existed after a beacon OUTAGE — the window was
// twice the beacon's entire retention. Now it exists whenever nobody relayed one
// round for three weeks, which is an ordinary thing rather than an incident. Closing
// it properly still means a two-phase refund, and that is still a separate change.



// refundGraceElapsed reports whether refundGraceBlocks have passed since Commit
// froze this week. IT READS NO BEACON STATE AT ALL, and that is its entire
// purpose: it is the one condition in this file that a stopped, lost or hostile
// publisher cannot hold false. See refundGraceBlocks for the derivation and for
// the two ways the beacon otherwise traps a pot forever.
//
// IT IS MONOTONE, unlike resolvable(): chain height only rises and CommittedAt
// never moves once set, so this goes true exactly once and stays true. Refund
// therefore never needs Abandoned to protect it from this half of the gate — only
// from resolvable().
//
// A ZERO CommittedAt RETURNS false, and false is the safe direction. It is
// unreachable through the entry points: Refund tests Committed first, and Commit
// sets both fields in the same statement group. If it ever were reachable — a
// week committed by some future code path that forgot this field — withholding
// the extra escape hatch is a liveness cost, whereas granting it would open
// refunds on a live draw at any height past refundGraceBlocks.
func refundGraceElapsed(d *Draw) bool {
	if d.CommittedAt <= 0 {
		return false
	}
	return runtime.ChainHeight()-d.CommittedAt >= refundGraceBlocks
}

// --- the three retired destinations ------------------------------------------
//
// THERE IS NO DESTINATION IN THIS FILE ANY MORE, AND THIS SECTION IS THE RECORD OF THE
// THREE THAT WERE TRIED. A dead week's sponsorship is now returned to the addresses
// holding units in THAT week (retireSponsorship, ClaimDeadWeek), so nothing below has a
// successor — read this section as a list of closed defects, not as a pointer to current
// code. AUDIT-2026-09-28.md findings 16, 28 and 31.
//
// rolloverTarget IS GONE AS OF 2026-09-29 AND ITS WHOLE COMMENT IS KEPT BELOW, BECAUSE
// THE CLAIM IT RESTED ON IS THE DEFECT. It returned currentWeek()'s draw — "the LIVE
// week" — and both paths that retire a dead week's sponsorship pushed money into
// whatever week that happened to be at the moment a permissionless caller fired. That
// is AUDIT-2026-09-28.md finding 28: A DESTINATION EVALUATED AT CALL TIME IS A
// DESTINATION THE CALLER CHOOSES. Nothing about the function was wrong on its own
// terms; what was wrong is that its answer depended on WHEN it was asked, and every
// caller of it was permissionless.
//
// THE RETIRED TEXT, VERBATIM:
//
// rolloverTarget returns the LIVE week's draw, to roll a dead week's sponsorship
// forward into, or nil if no such week can be had. IT NEVER PANICS, and that is its
// entire reason for existing as a separate function.
//
// WHO USES IT AND WHY IT CANNOT BE THE SAME CODE AS SweepDrawlessWeek'S. Refund's
// abandonment transition calls it (see there for the finding that put it here).
// SweepDrawlessWeek deliberately does NOT: that function is allowed to refuse, and
// refusing is the right answer for it — a drawless week's sponsorship has no deadline,
// so leaving it where it is and letting any caller retry after one beacon Publish
// costs nobody anything. A REFUND HAS A CLAIMANT WAITING AND MUST NOT BE REFUSED FOR A
// REASON IN ANOTHER REALM. If this returned a panic instead of nil, a stale beacon
// would mean a buyer could never reclaim their own ticket money — a fresh "money in,
// no way out" path, which is the shape six of this product's findings have had.
//
// THE THREE WAYS IT RETURNS nil, all of them states in which there is genuinely
// nowhere to put the money:
//
//   - THE BEACON IS TOO STALE TO OPEN A WEEK. getOrCreateDraw pins the new week's
//     round against beacon.EstimatedLatestRound(), which REFUSES past
//     beacon.MaxEstimateStaleBlocks (AUDIT-2026-09-28.md finding 12). EstimateIsUsable
//     is the non-panicking form of exactly that condition, so it is asked FIRST and
//     the pin is only attempted when it cannot fail. In the one state where that
//     refusal is permanent — a chain whose average block time has settled below
//     3.29998 s — no week can be opened at all, which is finding 12's own recorded
//     residual and is the same state in which SweepDrawlessWeek stops working.
//   - THE PIN WOULD WRAP. Checked here rather than left to getOrCreateDraw's panic,
//     for the same no-panic reason. Unreachable in practice (drand cannot sign a round
//     near the int64 maximum), and the cost of checking it is one beacon read.
//   - THE LIVE WEEK IS COMMITTED OR ABANDONED. Unreachable by construction — Commit
//     refuses week >= currentWeek() and abandonment requires a commit — and these are
//     the same two defensive refusals SweepDrawlessWeek states about the same
//     destination. Here they are a nil rather than a panic, because the caller has a
//     fallback and must not be stopped.
//
// If it returns a draw, that draw is safe to add sponsorship to: it is the live week,
// uncommitted and unabandoned, and its round is pinned.
//
// (END OF THE RETIRED TEXT.)
//
// WHAT SURVIVED OF IT FOR ONE DAY WAS THE LAST BULLET'S REASONING, IN A FUNCTION CALLED
// ReclaimStrandedCarry, AND THAT IS GONE TOO — finding 31. The argument was: in the one
// state where NO week can ever be opened again there is genuinely nowhere to CARRY the
// money to, so it must still end in opsPot, behind the same beacon test (weekIsOpenable)
// and a three-week long stop. Every word of that was conditional on the money needing to
// GO somewhere. It does not any more: a dead week's sponsorship is claimed by that week's
// own unit holders, ClaimDeadWeek reads no beacon and has no clock, and the whole
// "nowhere to put it" state stops existing. AN ENTRY POINT, A REGISTER, A LONG STOP AND A
// BEACON TEST ALL DELETED BY REMOVING THE NEED FOR A DESTINATION RATHER THAN BY CHOOSING
// A BETTER ONE.
//
// AND ONE SENTENCE IN IT WAS SIMPLY WRONG, WHICH IS WORTH RECORDING BECAUSE IT WAS THE
// SENTENCE THAT MADE THE REGISTER LOOK SAFE. It said of the state the function required:
//
//	One Buy, one FundPot or one duel flush in three weeks defeats it. The state it
//	requires is not "the beacon went quiet for a day", it is "this realm is dead".
//
// Only a call that CREATED A WEEK RECORD absorbed a carry, so the true condition was "one
// week-OPENING event in three weeks" — and a Buy, a FundPot or a flush into a week that
// already had a record did nothing at all. The sentence overstated how easily the pending
// state cleared, which is the optimistic direction, and the same mis-statement is the
// reason finding 31's exploit had pending carries to collect in the first place: quiet
// weeks that never opened a record are exactly what let them accumulate.

// Refund returns the caller's own ticket money for a week whose draw can never
// be resolved. PERMISSIONLESS, and self-service only: a caller can only ever
// reclaim their own record.
//
// THIS IS THE SAFETY VALVE r/splash/game COULD NOT HAVE. There, the pot was
// accrued protocol fees, nobody had staked anything, and an unresolved draw
// could simply wait forever with no one out of pocket — so a void path would
// have been the only route by which a prize could move without a winner, and
// was deliberately omitted. Here the pot is the buyers' own money, and without
// this function a week nobody settles would lose every ticket bought into it.
//
// ITS JUSTIFICATION CHANGED COMPLETELY IN THE DRAND MIGRATION, AND THE OLD ONE IS
// WRITTEN OUT HERE BECAUSE A READER WILL COME LOOKING FOR IT. It used to be: "the
// committed beacon round was published and PRUNED with nobody calling Capture, so no
// winner can ever be named". That was a claim about a beacon that forgot things.
// r/splash/beacon does not forget, drand's API serves every round for ever, and
// Publish is permissionless — so no draw is ever unresolvable, and the precondition
// this function was built on no longer exists (see resolvable()'s removal, above).
//
// WHAT IT IS FOR NOW IS LIVENESS, NOT LOSS. A week's pot must not be hostage to
// whether anybody spends ~17.0M gas relaying one drand round. That is the only
// failure left, and it is unbounded in time, so the exit is a CLOCK: refunds open
// refundGraceBlocks (21 days) after Commit and not before.
//
// THE PRECONDITION IS THEREFORE NO LONGER THE COMPLEMENT OF Resolve's — the two now
// OVERLAP for ever once the window opens, and that is fine and is handled by
// Abandoned. There is no state in which Resolve is impossible, so a refund gate that
// waited for one would never open at all.
//
// AND THE EXIT IS ONE-WAY, WHICHEVER WAY IT GOES. Refund and Resolve are
// permanently mutually exclusive per week: the first refund that pays out sets
// Abandoned, after which Resolve and Capture refuse that week forever and every
// later refund proceeds without consulting the beacon again. THE ONE-WAY EXIT
// MATTERS MORE NOW, NOT LESS: it used to protect against a round being published
// late or re-published after a prune, and it now carries the whole burden, because a
// pinned round can be relayed by anyone at any time for ever — so a week in refund
// would otherwise be re-resolvable indefinitely. Without it, a week could take
// refunds from some buyers and then be resolved over the original frozen ticket set,
// paying the remaining pot — those other buyers' money — to a winner who may already
// have been refunded.
//
// AND THE ESCROWED FEE FOLLOWS THE SAME PRINCIPLE AS THE SPONSORSHIP, BY A DIFFERENT
// ROUTE — BUT THE SPONSORSHIP DOES NOT ROLL ANYWHERE AND HAS NOT SINCE 2026-09-29. The
// retired sentence, ~240 lines above a transition that does nothing of the kind:
//
//	"An abandoned week's Sponsored ROLLS FORWARD TO THE LIVE WEEK (finding 16), because it
//	belongs to no buyer and there is nobody to hand it back to."
//
// BOTH HALVES WERE WRONG BY THE TIME IT WAS WRITTEN. Rolling forward to the live week was
// AUDIT-2026-09-28.md finding 28 — the live week is whichever week the permissionless caller
// chose to fire in, so the caller picked the destination by picking the moment — and the
// premise "there is nobody to hand it back to" is false whenever a duel was played in the
// week: THE EARNED-ENTRY HOLDERS ARE EXACTLY THE PEOPLE WHOSE RAKE IT IS (findings 31 and
// 34). The sponsorship becomes a per-unit claim on THIS week, payable to the holders of its
// EARNED entries, and it never changes weeks.
//
// SO THE TWO AMOUNTS NOW ANSWER THE SAME QUESTION THE SAME WAY, AND THE PARALLEL IS TIGHTER
// THAN IT WAS. An abandoned week's Cut does not roll anywhere: it belongs to specific buyers,
// so it goes BACK to them, one gross refund at a time, and the abandonment transition below
// deliberately does not touch d.Cut at all. The sponsorship likewise goes back to the people
// it came from, in place. We did not run a draw, so we keep neither — and the only money that
// reaches the house is a sponsorship with no player behind it at all.
//
// A BUYER WHO NEVER CALLS THIS LEAVES THEIR OWN GROSS SITTING IN THE WEEK, fee part
// included, and that is not a new stranded-money path: there is no deadline on a refund,
// Abandoned is one-way so nothing else can take it, and the only address that can ever
// reclaim it is theirs. It is the same "unclaimed, not unreachable" state the prize half
// has always had.
//
// AN EARNED ENTRY RECLAIMS NOTHING *HERE*, AND THAT IS CORRECT RATHER THAN A GAP — BUT IT
// RECLAIMS EVERYTHING THROUGH ClaimDeadWeek. Finding 15 lets duel play earn ticket weight with
// no spendOf record (FundPotWithEntries), and this function pays spendOf and nothing else — so
// a holder of only earned entries is refused with "nothing to reclaim for that week". They
// paid this realm no ticket money to get back: what they paid was the duel's rake, and the
// abandonment transition below turns that rake into THEIR claim on this same week
// (AUDIT-2026-09-28.md findings 31 and 34).
//
// THE TWO SENTENCES THAT FOLLOWED WERE BOTH FALSE AND ARE KEPT BECAUSE EACH WAS LOAD-BEARING
// FOR A DIFFERENT READER:
//
//	"A week whose entries are ALL earned therefore refunds nobody and MOVES ITS WHOLE POT TO
//	opsPot ON THE FIRST REFUND ATTEMPT — except that there can be no first refund attempt,
//	because no caller has a spend record, so such a week simply stays unrefundable and
//	RESOLVE REMAINS ITS ONLY EXIT."
//
// The first clause contradicted itself in its own sentence (a refund attempt that cannot
// happen cannot move anything) and named a destination that is deleted. The second was true
// when it was written and was FIXED BY finding 17 in the same audit: a pure-earned week has a
// SECOND exit, SweepDrawlessWeek's shape 2, gated on the same grace window this function uses,
// and that exit retires the sponsorship to the earned holders. Leaving "Resolve remains its
// only exit" standing is how a reader concludes that the stranding finding 17 closed is still
// open — or, worse, re-derives finding 17 as a new idea and implements it a second time.
//
// WHAT IS TRUE: such a week refunds nobody through this function, its draw is Resolve, and if
// no draw happens for the whole grace window then SweepDrawlessWeek marks it abandoned and its
// sponsorship becomes its earned holders' claim. It strands nothing by either route.
//
// EACH BUYER RECLAIMS EXACTLY THEIR OWN RECORDED SPEND, ONCE. The record is
// zeroed before the transfer, so a second call finds nothing and panics; and
// because Pot == sum(spends) + Sponsored for an unresolved week — with the
// sponsorship term taken out of the pot the moment the week is abandoned, see
// below — the refunds can never total more than the pot holds.
//
// SPONSORSHIP IS NOT REFUNDABLE AND IS NOT LEFT BEHIND. House money added by
// FundPot (the duel's rake, for one) belongs to no buyer, so nobody can claim it
// here; the first refund that pays out ROLLS IT FORWARD INTO THE LIVE WEEK'S POT —
// exactly as SweepDrawlessWeek does for a week nobody entered — instead of leaving
// it stranded in a pot whose every claim has been zeroed. It went to opsPot until
// 2026-09-29, and the two paths disagreeing about the same money was
// AUDIT-2026-09-28.md finding 16. The code and the reasoning are at the transition
// below.
//
// THE HOUSE FEE *IS* REFUNDED, SINCE 2026-09-29, AND THE PARAGRAPH THAT USED TO BE
// HERE SAID THE OPPOSITE. It read: "What a buyer gets back is their post-cut
// contribution — the part that was ever in the prize pot — not the gross ticket price.
// The 5% was taken at sale time and is already in the ops pot; clawing it back would
// mean the ops pot could go negative, or that this realm had to hold every cut in
// escrow for a week against the small chance of a pruned round." IT IS KEPT VERBATIM
// BECAUSE IT NAMES THE COST OF THE FIX AND THE FIX PAID IT: the realm now DOES hold
// every fee in escrow per week (Draw.Cut), which is the second option that sentence
// dismissed, and the ops pot cannot go negative because nothing credits it until a
// draw succeeds.
//
// WHAT A BUYER GETS BACK IS THEREFORE THE WHOLE TICKET PRICE. The owner's rule is that
// WE EARN WHEN THE GAME RUNS, NOT WHEN IT FAILS, and a refunded week is a week that did
// not run: the fee was a charge for a draw that never happened. This is a REDUCTION IN
// HOUSE REVENUE in the failure case, which needs no permission and is the safe
// direction — the same shape as finding 16 sending an abandoned week's sponsorship back
// to players rather than to the house.
//
// THE SPLIT IS IN THE BODY, and it is where the only rounding risk in the change lives;
// read it there. AUDIT-2026-09-28.md finding 25.
//
// A WEEK THAT WAS NEVER COMMITTED IS NOT REFUNDABLE HERE, and needs no separate
// path — but only because Commit TAKES THE WEEK AS AN ARGUMENT and any week
// that is over can be committed by anyone at any time. So a buyer holding a
// stranded week's tickets names that week to Commit themselves, and then either
// Resolves it (the normal outcome) or refunds it here if its round was lost.
// Before Commit took that argument this paragraph was simply false: a caller
// could not name the week, Commit could only act on the live one, and a week
// the clock had passed was unreachable by every path in this file — committed
// never, resolved never, refunded never, and counted in heldPots forever.
func Refund(cur realm, week int64) {
	rejectAttachedCoin(cur, "Refund")
	sweepDonations()

	d := getDraw(week)
	if d == nil {
		panic("raffle: no draw for that week")
	}
	if d.Resolved {
		panic("raffle: this week's draw is already resolved")
	}
	if !d.Committed {
		panic("raffle: this week is not committed yet — commit it first; refunds only open on a week nobody settled")
	}
	// TWO TERMS, NOT THREE, SINCE THE DRAND MIGRATION. This gate read
	//
	//	if !d.Abandoned && resolvable(d) && !refundGraceElapsed(d) {
	//
	// where resolvable(d) was the beacon-derived opener: "the round's signature is
	// gone, so this draw is dead". THAT OPENER IS DELETED, not rescaled, because the
	// state it detected cannot occur against drand — see resolvable()'s removal
	// above for why, and for why keeping a reduced version of it would have opened
	// refunds on every live draw immediately.
	//
	// THE Abandoned CHECK STILL COMES FIRST, and its reason is unchanged and is now
	// load-bearing for longer: once this week is in refund it stays in refund,
	// whatever the beacon says later. A pinned round can be relayed by anybody at any
	// time, for ever, so without this a week with some buyers already refunded could
	// be resolved over the original frozen range.
	//
	// THE HEIGHT GATE IS NOW THE ONLY OPENER. Refusing needs both terms — not
	// abandoned, and still inside the grace window. Read refundGraceBlocks for the
	// derivation and for why a beacon-state gate cannot do this job: it cannot
	// distinguish "nobody has relayed the round yet" from "nobody ever will".
	//
	// THE MESSAGE TELLS THE CALLER WHICH OF THE TWO THINGS TO DO, because both are
	// available to them: wait for the window, or relay the round themselves and
	// resolve. The height the window opens at is in Render, in DrawOf and in the
	// Commit event.
	if !d.Abandoned && !refundGraceElapsed(d) {
		panic("raffle: this week's draw is still live — refunds only open once the grace window has elapsed")
	}

	caller := cur.Previous().Address()
	k := string(caller)
	amount := treeInt64(d.spendOf, k)
	if amount <= 0 {
		panic("raffle: nothing to reclaim for that week")
	}

	// THE POINT OF NO RETURN, set on the first refund that actually pays out —
	// never by a refusal above, which must leave the week exactly as it was.
	//
	// AND THE ONE MOMENT SPONSORSHIP IS RETIRED FROM THE DRAW. A sponsored ugnot is
	// attributable to no buyer (see Draw.Sponsored and FundPot), so no Refund can
	// ever return it: if it just sat in d.Pot while every spendOf was zeroed AND NO
	// PATH COULD REACH IT, this week would end with Pot > 0, no claimant and no exit —
	// permanently unreachable money the invariant would go on counting, which is
	// precisely the defect the 2026-09-28 audit's first finding was about.
	//
	// THE FIRST HALF OF THAT SENTENCE IS NO LONGER WHAT HAPPENS AND THE SECOND HALF IS
	// STILL WHY. The money stays in d.Pot and STOPS BEING SPONSORSHIP: retireSponsorship
	// turns it into a per-unit claim held by the addresses that hold units in THIS week —
	// the duel players whose rake it is and the buyers who bought in. So there is a path to
	// it (ClaimDeadWeek), the claim is on named addresses rather than named in a register,
	// and the "unreachable money" objection is answered by the money already being where its
	// owners are. The call is INSIDE the `!d.Abandoned` branch, so it happens exactly once:
	// on the transition, not on every later refund.
	//
	// IT IS ALWAYS THE CLAIMANT CASE HERE, AND THAT IS STRUCTURAL RATHER THAN CHECKED. To
	// reach this line a caller must have a positive spendOf for this week, which only Buy
	// writes, and Buy appends unit weight in the same statement group — so d.tickets.Total()
	// is positive whenever this runs and retireSponsorship's no-holders branch is
	// unreachable from Refund. The no-holders branch belongs to SweepDrawlessWeek's shape 1.
	//
	// AND IT DOES NOT DISTURB THIS CALLER'S OWN REFUND. `amount` was read from spendOf
	// above and retireSponsorship does not touch spendOf, Pot's buyer-facing part, or Cut —
	// so the split below is over exactly the gross this buyer paid. Their share of the dead
	// week's sponsorship is a SEPARATE, later ClaimDeadWeek call. That separation is
	// deliberate: folding the share into spendOf instead would have made Refund re-derive a
	// house cut over money that never paid one, which drives d.Cut negative and turns a
	// buyer's own reclaim into a panic. The arithmetic is in AUDIT-2026-09-28.md finding 31.
	//
	// WHERE IT GOES CHANGED ON 2026-09-29, AND THE OLD DESTINATION WAS A FINDING
	// RATHER THAN UNTIDINESS. This branch used to do `opsPot += s` — the players'
	// side of the duel rake to the house — while SweepDrawlessWeek, twenty lines
	// further down this file, rolled THE SAME MONEY forward into the live week's pot
	// and said in as many words that "a week nobody entered should not hand the
	// players' share back to the house". Two functions moved identical money to
	// opposite destinations and nothing reconciled them. AUDIT-2026-09-28.md finding
	// 16 records the general lesson: THAT ASYMMETRY IS A FINDING, NOT A TIDINESS
	// PROBLEM — it will be exploited in whichever direction pays.
	//
	// AND SINCE EARNED ENTRIES EXIST IT WAS EXPLOITABLE, CHEAPLY. A week can now
	// accumulate a whole week of duel rake as ticket weight with no spendOf backing
	// (FundPotWithEntries). A griefer bought ONE ticket into such a week, waited for
	// it to end, committed it (permissionless), let refundGraceBlocks pass with
	// nobody relaying the round, and then called Refund: the branch fired, the ENTIRE
	// week of rake moved to opsPot, Resolve was shut for ever, every earned-entry
	// holder got nothing, and WithdrawOps — permissionless, fixed destination — sent
	// the lot to the ops vault. Net cost 5,000 ugnot of house cut; net beneficiary
	// the house. THE PARTY BEST PLACED TO TRIGGER IT WAS THE PARTY THAT RECEIVED THE
	// PROCEEDS, which is what makes it unacceptable regardless of how long the window
	// is.
	//
	// SO IT DOES NOT GO TO THE HOUSE, AND THE TWO PATHS AGREE: an abandoned week's
	// sponsorship is the players' money and it stays the players' money. It reduces house
	// revenue in an edge case, which is the safe direction.
	//
	// IT NO LONGER GOES FORWARD TO A FUTURE WEEK EITHER, AND THE PARAGRAPH THAT SAID IT DID
	// IS KEPT BECAUSE IT IS THE ONE A READER WILL HAVE IN THEIR HEAD. It said: "SO IT NOW
	// GOES FORWARD TO A FUTURE WEEK'S POT RATHER THAN TO THE HOUSE, EXACTLY AS
	// SweepDrawlessWeek DOES... it becomes part of a prize somebody can still win." Which
	// week that prize belonged to was the whole of findings 28 and 31, and forward motion is
	// what both of them had in common. It now goes NOWHERE: the week's own unit holders take
	// it, in the week it is already in.
	//
	// AND WHICH FUTURE WEEK IS NOT THIS CALLER'S TO DECIDE — FINDING 28, AND THE
	// PARAGRAPH THAT USED TO BE HERE IS WHY. It said: "THE ONE CASE SweepDrawlessWeek
	// ALREADY DOCUMENTS IS THE ONE CASE THAT FALLS BACK: if no live week can be opened
	// there is nowhere to roll it to. See rolloverTarget, which is the shared decision...
	// So when there is no live week the money goes to opsPot as it always did, which is
	// finding 12's residual and nothing wider." BOTH SENTENCES WERE TRUE AND TOGETHER
	// THEY WERE A DEFECT:
	//
	//   - THE DESTINATION WAS currentWeek(), evaluated in this call, so a caller chose
	//     it by choosing when to call. Buy into a week at its very end, refund the dead
	//     week in the same block, and a week of duel rake joins a pot whose competing
	//     ticket set is already known and closed. The loss fell on the dead week's
	//     earned-entry holders — duel players who paid the rake — and the beneficiary
	//     was whoever dominated the week the caller picked.
	//   - AND THE "no live week" FALLBACK WAS NOT AN EDGE CASE AT ALL. Refunds open 21
	//     days after a commit; the beacon's estimate goes unusable after ONE day without
	//     a relay. In the scenario a refund exists for, the beacon is stale by
	//     definition, so on a quiet realm the fallback was the NORMAL path and the rake
	//     went to the house — finding 16 undone by its own escape hatch.
	//
	// WHAT HAPPENS INSTEAD, IN ONE LINE: the sponsorship becomes a per-unit claim on THIS
	// week, payable to THIS week's unit holders, and nothing in this call names a week,
	// reads a clock or reads the beacon. Read retireSponsorship for the arithmetic and the
	// dust, and ClaimDeadWeek for the exit.
	//
	// THE INTERMEDIATE DESIGN, RECORDED BECAUSE IT WAS WRONG IN A WAY THAT LOOKED RIGHT.
	// For one day this branch called markCarryPending: the week was REGISTERED and the next
	// week record to be created pulled the money in at its own birth, which was meant to
	// make the destination unchoosable. It did not. The caller who creates that week is the
	// caller who calls Buy, so buying one ticket in the final block of a quiet week both
	// opened the record and absorbed every pending carry into a week whose entire ticket set
	// was theirs — certainty, for the price of the house cut. AUDIT-2026-09-28.md finding 31.
	//
	// THIS FUNCTION THEREFORE NO LONGER HAS A DESTINATION TO FAIL TO FIND, which is a
	// strictly stronger form of the promise it always had to keep: Refund must never
	// panic for a reason in another realm, because a payout path a stale beacon could
	// hold shut would be a fresh "money in, no way out" defect. It now reads no beacon at
	// all on this path. THE SWEEP MAY STILL REFUSE AND THIS FUNCTION STILL MAY NOT — see
	// SweepDrawlessWeek's clock — but the asymmetry is now about a clock, not about
	// whether a destination exists.
	//
	// AND IT CANNOT BE MADE EXPENSIVE ENOUGH TO FAIL EITHER, WHICH IS THE OTHER HALF OF THAT
	// PROMISE AND IS WHY retireSponsorship IS O(1). The obvious way to return money pro rata
	// is to walk the holders and credit each one, and a week's holder set is unbounded — two
	// more holders for every duel played. A loop here would have put a gas ceiling on the
	// FIRST REFUND OF A BUSY WEEK, which is a "money in, no way out" path created by the fix
	// for one. One rate is written instead, in constant time, and each holder derives their
	// own share when they claim.
	//
	// NO WUGNOT LEAVES THE REALM FOR THE TRANSITION, and the week's identity
	// Pot + Cut == sum(spendOf) + Sponsored + Claims holds across it: Sponsored falls by
	// exactly what Claims rises by, except for the sub-unit dust, which leaves Pot and
	// enters opsPot in the same statement. It holds across every refund below too, each of
	// which removes one buyer's gross from both sides. After the last refund this week is
	// Pot == Claims, and every ugnot of that has a named holder who can take it.
	if !d.Abandoned {
		d.Abandoned = true
		if d.Sponsored > 0 {
			retireSponsorship(d)
		}
	}

	// THE REFUNDED BUYER KEEPS THEIR TICKETS ON PURPOSE. d.tickets, d.ownerOf and
	// d.ticketsOf are deliberately NOT touched here: fenwick rejects negative
	// deltas by design and FrozenTotal must never move, so a ticket cannot be
	// retired once sold. That used to mean a refunded buyer kept their full
	// winning probability while holding their money back — harmless now, and only
	// because the line above makes this week unresolvable forever, so no draw over
	// this ticket set will ever happen. DO NOT "FIX" THE UN-RETIRED TICKETS by
	// reopening Resolve on an abandoned week: the tickets are dead weight, the
	// week's exit being one-way is what makes them safe.
	// THE GROSS IS SPLIT BACK INTO THE TWO TERMS IT ARRIVED IN — AUDIT-2026-09-28.md
	// finding 25, and this is the part of that change where the rounding lives.
	//
	// `amount` is the buyer's GROSS payment. At sale time Buy put
	// floor(cost * HouseCutBps / bpsDenom) of each purchase into d.Cut and the rest into
	// d.Pot. To take the money back out without leaving dust in either term, the split
	// is DERIVED THE SAME WAY BUY DERIVED IT — the same mulDiv, the same constants, over
	// this buyer's accumulated gross.
	//
	// WHY THAT IS EXACT AND NOT MERELY CLOSE, which is the whole question:
	//
	//   - THE TWO PARTS ALWAYS SUM TO THE GROSS, unconditionally, because cutPart is
	//     computed and potPart is the REMAINDER. So the per-week identity
	//     Pot + Cut == sum(spendOf) + Sponsored survives ANY rounding whatever: this
	//     call removes `amount` from the right and `amount` from the left. That is what
	//     makes Refund unable to overdraw, and it holds after a partial refund, after
	//     every ordering, and for every value of HouseCutBps.
	//   - THE SPLIT ALSO LANDS ON THE SAME SIDE AS BUY'S, because cutPerTicket's build
	//     guard forbids a TicketPrice/HouseCutBps pair for which the flooring discards
	//     anything. Every cost is a whole number of tickets, so every cut is
	//     tickets * cutPerTicket exactly, and so is every partial sum of them —
	//     therefore floor over the accumulated gross returns precisely the sum of the
	//     cuts that gross contributed. WITHOUT THAT GUARD the two could differ by one
	//     ugnot per buyer, d.Cut could be driven negative by a refund, and
	//     checkInvariant would abort a buyer's reclaim of their own money. The guard is
	//     load-bearing, not hygiene.
	//
	// THE SPONSORSHIP TERM IS ALREADY OUT OF THE POT by the time this runs (the
	// transition above), so the only claims left on this week are gross spends.
	cutPart := int64(mulDiv(uint64(amount), uint64(HouseCutBps), uint64(bpsDenom)))
	potPart := amount - cutPart

	d.spendOf.Set(k, int64(0))
	d.Pot -= potPart
	d.Cut -= cutPart
	heldPots -= potPart
	heldCuts -= cutPart
	if d.Pot < 0 {
		// Unreachable while Pot + Cut == sum(spends) + Sponsored. Loud rather than
		// paying out money that belongs to another week.
		panic("raffle: refund would overdraw the week's pot")
	}
	if d.Cut < 0 {
		// Unreachable for the reason spelled out above: the build guard makes the
		// per-buyer cut derivation exact, so the cut parts of a week's buyers sum to
		// exactly the Cut those buys booked. Loud rather than releasing a fee twice or
		// paying one buyer out of another week's escrow.
		panic("raffle: refund would overdraw the week's escrowed fee")
	}

	// THE FULL TICKET PRICE GOES BACK, NOT 95% OF IT. This is the behaviour change
	// finding 25 is about: the fee was never earned, because the draw never ran.
	wugnot.Transfer(cross(cur), caller, amount)

	chain.Emit("Refund",
		"week", strconv.FormatInt(week, 10),
		"buyer", string(caller),
		"amount", strconv.FormatInt(amount, 10),
		"prizePart", strconv.FormatInt(potPart, 10),
		"feeReturned", strconv.FormatInt(cutPart, 10),
		"pot", strconv.FormatInt(d.Pot, 10),
		"escrowedCut", strconv.FormatInt(d.Cut, 10))
	checkInvariant()
}

// --- ClaimDeadWeek -------------------------------------------------------

// ClaimDeadWeek pays the caller their pro-rata share of the sponsorship that a DEAD week's
// draw never got to pay out, and returns the amount. PERMISSIONLESS, self-service only —
// a caller can only ever claim their own share — and it is the EXIT for the claim term
// retireSponsorship creates. AUDIT-2026-09-28.md finding 31.
//
// WHY IT IS A NEW ENTRY POINT AT ALL, WHICH IS THE ONE QUESTION WORTH ANSWERING HERE. The
// cheaper design is to fold each holder's share into their spendOf and let the existing,
// already-audited Refund be the exit — no new function, no new term, no new tree. THAT DOES
// NOT WORK, AND THE ARITHMETIC IS WHY RATHER THAN A JUDGEMENT CALL:
//
//	Refund re-derives the house fee it must give back as
//	    cutPart = floor(gross * HouseCutBps / bpsDenom)
//	and decrements d.Cut by it. That derivation is EXACT — see cutPerTicket's build guard —
//	only because a spendOf is always a whole number of ticket prices, so its floor is
//	precisely the sum of the cuts those purchases booked.
//
//	A sponsorship share booked NO CUT. Add a share s to a buyer whose gross was
//	g = n * TicketPrice and Refund derives floor((g+s)/20) = n*500_000 + floor(s/20), while
//	d.Cut only ever received n*500_000. d.Cut goes NEGATIVE by floor(s/20) and Refund's own
//	"refund would overdraw the week's escrowed fee" panic fires — so the buyer cannot
//	reclaim their own ticket money at all. Worse in the pure-earned case: a holder with no
//	purchase gets gross s against a week whose Cut is 0, and floor(s/20) is stolen from
//	nothing. THE FIX FOR A FUND-STRANDING DEFECT WOULD HAVE CREATED ONE.
//
//	The identity itself survives — Refund removes `amount` from both sides whatever the
//	rounding — which is exactly what makes this dangerous: checkInvariant and AuditFailure
//	stay green right up to the panic. It is the Cut term, not the identity, that breaks.
//
// SO THE CLAIM IS A SEPARATE TERM WITH ITS OWN EXIT, AND IT CARRIES NO FEE BY CONSTRUCTION:
// sponsorship never paid a house cut on the way in and this pays none on the way out. The
// term appears in checkInvariant (heldClaims) and in AuditFailure (per week, and in the
// aggregate, and re-derived against claimedOf by deadWeekClaimFailure), which is the price
// of not reusing Refund and is paid in full.
//
// IT HAS NO CLOCK, NO BEACON READ AND NO REFUSABLE DEPENDENCY, deliberately. By the time a
// claim exists the week is already abandoned — every gate that had to be waited out
// (Refund's grace window, or SweepDrawlessWeek's) was waited out before retireSponsorship
// ran — so a second wait would only be a second thing that could go wrong on a payout path.
// Compare ReclaimStrandedCarry, which this replaces: that needed a beacon test AND a
// three-week long stop because it was trying to find a destination. There is nothing to
// find.
//
// IT IS O(log N) AND ALL-OR-NOTHING PER HOLDER. The share is derived from the rate and the
// holder's unit weight at call time rather than stored per holder at abandonment, which is
// what keeps the abandonment transition constant-time (read retireSponsorship). The weight
// cannot have changed since: an abandoned week is always a past week, and Buy and
// FundPotWithEntries only ever touch currentWeek(). One claimedOf entry therefore settles a
// holder for ever, and a second call finds it and refuses.
//
// A REFUNDED BUYER MAY STILL CLAIM, AND THAT IS CORRECT, NOT A LOOPHOLE. Refund returns the
// gross they paid for their tickets; this returns their share of money that was never
// theirs to pay and never anybody's to win. The two are different money with different
// owners, and the week's identity keeps them apart — spendOf on one side, Claims on the
// other. A holder with earned entries and no purchase has a claim here and nothing to
// refund, which is the whole point of finding 15's players being paid.
//
// BOOKS FIRST, TRANSFER SECOND, as in Resolve, Refund and WithdrawOps.
//
// Panics if there is no record for the week, if that week never distributed anything, if
// the caller holds no units in it, or if the caller has already claimed.
// ClaimSponsorRefund returns a sponsor's payment from a week that died without
// drawing. It pays the GROSS — the house's 5% included — because the fee was only
// ever earned by a draw actually running, and this draw never ran.
//
// THE OWNER'S RULING, 2026-09-30: a sponsor's money is "either returned to
// sponsor or rolls over until a draw happens". Rolling forward is what
// AUDIT-2026-09-28.md findings 28 and 31 removed — the caller chose which week it
// landed in by choosing when to call, and could aim it at a draw they already
// dominated. So it is returned, and it is PULLED rather than pushed: paying up to
// maxSponsorsPerWeek addresses inside retireSponsorship would put those transfers
// on the critical path of a buyer's own Refund, where one failing recipient could
// block the week.
//
// IT DOES NOT COMPETE WITH ClaimDeadWeek. That pays earned-entry holders out of
// the duel's OWNERLESS rake; this pays named sponsors out of money that never
// entered that pool, because retireSponsorship carves it out first. The two draw
// on different halves of the same pot and neither can reach the other's.
func ClaimSponsorRefund(cur realm, week int64) int64 {
	rejectAttachedCoin(cur, "ClaimSponsorRefund")
	sweepDonations()

	d := getDraw(week)
	if d == nil {
		panic("raffle: no draw for that week")
	}
	if d.Resolved {
		panic("raffle: that week's draw was resolved — the sponsorship did its job and there is nothing to refund")
	}
	if !d.Abandoned {
		panic("raffle: that week is not dead — a sponsorship is only refundable once the week has been abandoned")
	}
	// THE ALREADY-CLAIMED CHECK COMES FIRST, and the order is the whole point. The
	// last sponsor to claim takes SponsorRefundable to zero, so a caller checking
	// their own second attempt would otherwise be told the week owes nobody anything
	// — true, and useless to them. They want to know THEY have already had it.
	caller := cur.Previous().Address()
	k := string(caller)
	if d.sponsorRefundedOf != nil && d.sponsorRefundedOf.Has(k) {
		panic("raffle: you have already reclaimed this week's sponsorship")
	}
	if d.SponsorRefundable <= 0 {
		panic("raffle: that week owes its sponsors nothing")
	}

	// THE SUM OF THIS CALLER'S OWN ENTRIES, and nobody else's. Walking the list is
	// bounded by maxSponsorsPerWeek, which is why that bound exists.
	owed := int64(0)
	for _, sp := range d.Sponsors {
		if sp.By == caller {
			owed += sp.Amount
		}
	}
	if owed <= 0 {
		panic("raffle: you did not sponsor that week")
	}
	if owed > d.SponsorRefundable {
		// Unreachable while the carve-out is exact, and asserted rather than assumed:
		// this is the line between paying a sponsor and overdrawing the pool that
		// holds every other sponsor's money.
		panic("raffle: that refund would overdraw what the week owes its sponsors")
	}

	if d.sponsorRefundedOf == nil {
		d.sponsorRefundedOf = avl.NewTree()
	}
	d.sponsorRefundedOf.Set(k, true)
	d.SponsorRefundable -= owed
	heldSponsorRefunds -= owed
	d.Pot -= owed
	heldPots -= owed
	if d.Pot < 0 {
		panic("raffle: that refund would overdraw the week's pot")
	}

	wugnot.Transfer(cross(cur), caller, owed)

	chain.Emit("ClaimSponsorRefund",
		"week", strconv.FormatInt(week, 10),
		"sponsor", string(caller),
		"amount", strconv.FormatInt(owed, 10),
		"stillOwed", strconv.FormatInt(d.SponsorRefundable, 10),
		"pot", strconv.FormatInt(d.Pot, 10))
	checkInvariant()
	return owed
}

// SponsorRefundableFor is what a dead week owes ONE sponsor, and zero once they
// have pulled it. Without it a sponsor has to fetch SponsorsOf, sum their own
// rows by hand, and still cannot tell whether they already claimed — the tree
// that records that is unexported. 2026-09-30 audit, Y3.
func SponsorRefundableFor(week int64, addr address) int64 {
	d := getDraw(week)
	if d == nil || d.SponsorRefundable <= 0 {
		return 0
	}
	if d.sponsorRefundedOf != nil && d.sponsorRefundedOf.Has(string(addr)) {
		return 0
	}
	owed := int64(0)
	for _, sp := range d.Sponsors {
		if sp.By == addr {
			owed += sp.Amount
		}
	}
	return owed
}

// SponsorRefundableOf is what a dead week still owes its sponsors.
func SponsorRefundableOf(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.SponsorRefundable
}

func ClaimDeadWeek(cur realm, week int64) int64 {
	rejectAttachedCoin(cur, "ClaimDeadWeek")
	sweepDonations()

	d := getDraw(week)
	if d == nil {
		panic("raffle: no draw for that week")
	}
	if d.ClaimPerUnit <= 0 {
		// COVERS THREE STATES AND THE MESSAGE NAMES THE USEFUL ONE: the week is still live,
		// or it is dead but held no sponsorship, or its sponsorship was smaller than its
		// unit count and was therefore all sub-unit dust (read retireSponsorship). None of
		// them owes the caller anything.
		panic("raffle: that week has no dead-week share to claim")
	}
	if d.Resolved {
		// Unreachable: a claim rate is only ever written on an abandoned week and an
		// abandoned week can never be resolved. Loud rather than paying a claim out of a
		// pot that has already gone to a winner.
		panic("raffle: that week's draw was resolved — its pot went to the winner")
	}

	caller := cur.Previous().Address()
	k := string(caller)
	// EARNED UNITS ONLY — AUDIT-2026-09-28.md finding 34. This read was
	// treeInt64(d.ticketsOf, k), which counted the caller's BOUGHT units too and so paid a
	// refunded buyer a share of the duel players' rake, against a refund that had already
	// returned their whole gross. The two bases must agree with the divisor
	// retireSponsorship used, and that divisor is earnedTotal.
	units := treeInt64(d.earnedOf, k)
	if units <= 0 {
		// THE MESSAGE NAMES THE BASIS, because "I hold 400 units of that week" is exactly what
		// a refused buyer will be looking at. Bought units are not a claim on this money: they
		// contributed nothing to it and Refund returns what they did contribute, in full.
		panic("raffle: you hold no earned entries in that week")
	}
	if d.claimedOf.Has(k) {
		panic("raffle: you have already claimed that week's share")
	}

	// NO OVERFLOW GUARD IS NEEDED AND THE BOUND IS WORTH STATING. units <= earnedTotal
	// always (earnedOf and earnedTotal have one writer and it increments both by the same
	// amount), and ClaimPerUnit was floor(Sponsored / earnedTotal), so
	// units * ClaimPerUnit <= earnedTotal * ClaimPerUnit <= Sponsored, which was a real wugnot
	// balance. The Claims comparison below is the belt to that: it is the same statement
	// made against a number the audit re-derives independently.
	amount := units * d.ClaimPerUnit
	if amount <= 0 || amount > d.Claims {
		// Unreachable while deadWeekClaimFailure's re-derivation holds. Loud rather than
		// paying one holder out of another's share.
		panic("raffle: that week's dead-week share does not cover this holder's claim")
	}

	d.claimedOf.Set(k, amount)
	d.Claims -= amount
	d.Pot -= amount
	heldPots -= amount
	heldClaims -= amount
	if d.Pot < 0 {
		// Unreachable while Pot + Cut == sum(spendOf) + Sponsored + Claims. Loud rather
		// than paying out money that belongs to another week.
		panic("raffle: claim would overdraw the week's pot")
	}

	wugnot.Transfer(cross(cur), caller, amount)

	chain.Emit("ClaimDeadWeek",
		"week", strconv.FormatInt(week, 10),
		"holder", string(caller),
		"units", strconv.FormatInt(units, 10),
		"perUnit", strconv.FormatInt(d.ClaimPerUnit, 10),
		"amount", strconv.FormatInt(amount, 10),
		"unclaimed", strconv.FormatInt(d.Claims, 10),
		"pot", strconv.FormatInt(d.Pot, 10))

	// AND WHEN THE LAST HOLDER IS PAID, SAY SO — AUDIT-2026-09-28.md finding 37, which is the
	// 2026-09-29 audit's open question about heldClaims. THE AGGREGATE CANNOT DISTINGUISH
	// "AWAITING HOLDERS WHO WILL COME" FROM "FROZEN FOR EVER": both are a positive number. This
	// event is the moment one week stops being either, it fires exactly ONCE per week — on the
	// claim that empties it, and Claims can never rise again — so an operator can subtract
	// settled weeks from heldClaims by reading the log alone, with no iteration over the realm.
	// UnclaimedHoldersOf answers the complementary question for a week that has NOT emptied:
	// how many named addresses are still owed.
	//
	// EMITTED AFTER THE PAYMENT'S OWN EVENT AND AFTER THE TRANSFER, so a reader of the log sees
	// the claim and then the week closing, in that order, and a reverted transaction emits
	// neither.
	if d.Claims == 0 {
		chain.Emit("DeadWeekFullyClaimed",
			"week", strconv.FormatInt(week, 10),
			"perUnit", strconv.FormatInt(d.ClaimPerUnit, 10),
			"earnedUnits", strconv.FormatInt(d.earnedTotal, 10),
			"heldClaims", strconv.FormatInt(heldClaims, 10),
			"height", strconv.FormatInt(runtime.ChainHeight(), 10))
	}
	checkInvariant()
	return amount
}

// --- SweepDrawlessWeek ---------------------------------------------------

// SweepDrawlessWeek rolls a FINISHED week's sponsorship forward into the live week's
// pot, when nobody ever bought a ticket in it. PERMISSIONLESS, like Commit.
//
// THERE ARE TWO SWEEPABLE SHAPES SINCE 2026-09-29 AND THE SECOND HAS A CLOCK ON IT:
// a week with NO TICKETS AT ALL (the original drawless week, sweepable as soon as it is
// over) and a week with TICKETS BUT NO SPEND — every entry earned by duel play — which
// is sweepable only once it is committed and refundGraceElapsed has gone true, and
// which is marked Abandoned when it is. The full reasoning, including why "zero spend"
// alone would have been a fund-destroying gate, is in the body above the shape test.
// AUDIT-2026-09-28.md finding 17.
//
// FINDING 15 MADE THIS FUNCTION MUCH HARDER TO REACH AND IT IS DELIBERATELY KEPT.
// A week of duel rake used to end with sponsorship and a zero ticket total, which is
// exactly the state this function exists for. Now the duel's deliveries bring
// ENTRIES with them (FundPotWithEntries), so such a week normally has tickets, is a
// real draw, and this function correctly refuses it — its sponsorship is a prize
// somebody can win rather than money nobody can reach. The states that still land
// here are real and small: a rake too small to buy one whole entry
// (rake < EntryUnitPrice), a duel both of whose parties played from realm code and so
// earned nothing, and any plain FundPot sponsorship from a caller that is not the
// duel. DO NOT DELETE IT ON THE GROUNDS THAT THE COMMON CASE IS GONE: every one of
// those states still strands money without it, and that was the sixth of this
// product's "money in, no way out" findings.
//
// THE DEFECT IT CLOSES. FundPot credits the live week and creates that week's
// record if it does not exist yet, so a week in which duels were collected but
// nobody ever bought a raffle ticket ends the week holding sponsorship in a Draw
// with a zero ticket total. Commit rightly refuses that week (no tickets, no unit
// to draw, no owner to pay), Resolve and Refund both require Committed, and
// FundPot only ever funds the live week — so before this function that
// sponsorship was unreachable by EVERY path in this realm, permanently, while
// heldPots went on counting it and checkInvariant and AuditFailure stayed green
// over money that was gone. That is the same class of defect as the 2026-09-28
// audit's first and most serious finding, and it is not an exotic state: a quiet
// raffle week with an active coin flip is an ordinary Tuesday.
//
// WHERE THE MONEY GOES, AND WHY NOT opsPot, AND WHY IT DOES NOT GO ANYWHERE AT ALL. It
// goes BACK TO THE PEOPLE WHO HOLD UNITS IN THIS WEEK, pro rata — and for shape 1, which
// has no unit holders whatsoever, it goes to opsPot because there is provably nobody else.
// Read retireSponsorship; the branch this function takes is exactly `pureEarned` and is
// stated again at the call site. This money is the PLAYERS' side of the duel rake (see
// r/splash/arcade/duel's Collect: the ops share went to r/splash/ops already, and what
// arrives here is deliberately the rest), so on shape 2 it lands back on the duel players
// who generated it.
//
// TWO SENTENCES THIS REPLACES, IN ORDER, BECAUSE THE SEQUENCE IS THE LESSON. First: "So it
// rolls forward to the live week's pot" — the live week being whichever week the caller
// chose to fire in (finding 28). Then: "It marks the week and registers it
// (markCarryPending); the next week record to be created absorbs it at its own birth...
// to a week nobody in this transaction can name" — except that the caller who opens that
// week is the caller who calls Buy, so they could name it after all, and be its only
// entrant (finding 31). Both sentences described a destination. There is none now.
//
// AND REFUND NOW AGREES, WHICH IT DID NOT UNTIL 2026-09-29. This paragraph used to
// end "Contrast Refund, which moves an abandoned week's sponsorship to opsPot: there
// the week HAD entrants and they are being paid back individually, so there is no
// prize left for the sponsorship to enlarge." THE CONTRAST WAS THE DEFECT. Two
// functions in one file moved the same field's money to opposite destinations, and
// since earned entries exist an abandoned week's "entrants" are mostly duel players
// with no spendOf to be paid back at all — so the rationale did not hold either. One
// ticket plus the grace window turned the whole argument into a cheap transfer of a
// week of rake to the house. AUDIT-2026-09-28.md finding 16. Refund's transition now
// retires the sponsorship exactly as this function does, and retireSponsorship is the
// shared step — a step with no destination in it.
//
// THIS FUNCTION STILL DIFFERS FROM REFUND IN ONE WAY, AND MUST, BUT THE DIFFERENCE IS NOW
// A CLOCK RATHER THAN A DESTINATION. It may REFUSE — the live-week rule, the shape tests,
// and the grace window each shape must wait out — because a dead week's sponsorship has no
// claimant and no deadline, so a refusal costs nobody anything and any caller may retry
// for ever. Refund may not refuse, because a buyer is waiting; and since neither function
// looks for a destination any more, there is no longer any state in which Refund COULD be
// refused for want of one. That is strictly stronger than both fallbacks it replaced — the
// immediate opsPot bank of finding 16 and ReclaimStrandedCarry's three-week long stop of
// finding 28 — and both of them are now deleted rather than relocated, because a claim on
// the week the money is already in cannot fail to find anything.
//
// THE DESIGN TENSION, RESOLVED EXPLICITLY SO IT IS NOT "FIXED" BACK. This realm's
// stated principle is that THERE IS NO ROLLOVER, so a drawless week must not
// exist — and Commit still enforces exactly that, unchanged. That principle is
// about TICKET HOLDERS' pots: it stops a week's prize being deferred away from the
// people who entered that week and paid for it. Rolling SPONSORSHIP forward from a
// week that had no entrants whatsoever does not violate it, because there was
// nobody to defer anything away from — no ticket was sold, so no buyer's
// expectation of this week's prize exists to be broken. Do not "restore
// consistency" by deleting this function or by letting Commit accept a zero total;
// the second would reopen the drawless-draw hole, and the first would reopen the
// stranded-money hole.
//
// NO WUGNOT MOVES HERE, and a reader looking for the missing Transfer should stop
// looking. The tokens are already inside this realm — FundPot pulled them in when
// the dead week was sponsored — so this is PURE BOOKKEEPING between two weeks of
// the same realm. The realm's wugnot balance is identical before and after;
// heldPots and heldSponsored each lose and regain exactly the same amount, which
// is why checkInvariant's equality still holds at the end.
//
// Panics if the week is not over yet (a live week may still sell a ticket, which
// would make it a real draw), if there is no record for it, if anybody BOUGHT a
// ticket in it, if it holds no sponsorship, if it is resolved or already abandoned,
// if its entries are all earned and its draw can still happen (uncommitted, or
// inside the grace window), or — defensively — if a ticketless week is somehow
// committed.
func SweepDrawlessWeek(cur realm, week int64) {
	rejectAttachedCoin(cur, "SweepDrawlessWeek")
	sweepDonations()

	if week >= currentWeek() {
		// THE SAME "ONLY ONCE IT IS OVER" RULE AS Commit, and for a reason of its
		// own: the live week can still sell its first ticket, at which point it is
		// a real draw whose buyers are entitled to the sponsorship sitting in it.
		// Sweeping it would take the prize out from under a buyer mid-week.
		panic("raffle: a week can only be swept once it is over")
	}

	d := getDraw(week)
	if d == nil {
		panic("raffle: no draw for that week")
	}
	// RESOLVED AND ABANDONED ARE ASKED FIRST, and for the PURE-EARNED shape below they
	// are not defensive at all: a swept pure-earned week IS abandoned afterwards, so
	// this is what makes a second sweep of one impossible.
	if d.Resolved {
		panic("raffle: that week's draw is already resolved")
	}
	if d.Abandoned {
		panic("raffle: that week was abandoned and refunded; its sponsorship has already left the pot")
	}

	// THERE ARE TWO SWEEPABLE SHAPES AND THE SECOND IS GATED ON A CLOCK. Both are
	// "money arrived and no ticket was ever BOUGHT", which is what weekHasNoSpend
	// tests; they differ in whether any ticket WEIGHT exists.
	//
	//  1. NO TICKETS AT ALL — the original drawless week. Never committable, so never
	//     resolvable or refundable: sweepable the moment it is over.
	//  2. TICKETS BUT NO SPEND — a PURE-EARNED week (finding 15). Every unit credited
	//     to a duel player through FundPotWithEntries, not one ticket bought. It IS a
	//     real draw and Resolve is its proper exit, so it is sweepable ONLY once its
	//     draw can no longer happen: committed, and refundGraceElapsed.
	//
	// WHY SHAPE 2 EXISTS AT ALL — AUDIT-2026-09-28.md finding 17. Such a week is
	// committable, is not shape 1, and CANNOT BE REFUNDED BY ANYBODY: Refund pays
	// spendOf and no caller has a record, so it panics "nothing to reclaim for that
	// week" before it can even set Abandoned. Resolve was therefore its ONLY exit, with
	// no clock-based fallback — and that contradicts this realm's own doctrine at
	// refundGraceBlocks, which says in as many words that a beacon-state gate cannot
	// detect "nobody bothered to relay one" and a clock can. Finding 15 named the state
	// and argued it strands nothing because "the round can always be relayed"; that is
	// an argument about possibility, not about anybody's incentive to spend ~17.0M gas.
	//
	// AND THE GATE IS THE GRACE WINDOW, NOT MERELY "ZERO SPEND", BECAUSE THE NAIVE
	// VERSION IS THE TRAP. Letting this function act on any week with sum(spendOf) == 0
	// would let ANYONE sweep a LIVE, RESOLVABLE pure-earned week forward the instant it
	// ended — destroying a legitimate draw and taking the prize away from the very
	// earned-entry holders the whole of finding 15 exists to pay. That would be worse
	// than the problem. Gating on refundGraceElapsed(d) — the same clock, the same
	// constant and the same derivation that opens Refund for a week with buyers — means
	// the sweep can only fire once the draw has demonstrably NOT happened for the full
	// window. Before that, Resolve is the only exit and that is correct.
	//
	// IT MARKS THE WEEK WITH THE EXISTING ONE-WAY Abandoned FLAG rather than inventing a
	// second one, so Resolve and Capture refuse it for ever by exactly the checks they
	// already apply to a refunded week. See the transition further down.
	noSpend := weekHasNoSpend(d)
	if !noSpend {
		// A WEEK SOMEBODY BOUGHT A TICKET IN IS A REAL DRAW and belongs to
		// Commit/Resolve/Refund. Sweeping one would take a pot away from the buyers who
		// paid into it, which is the very thing the no-rollover principle forbids.
		panic("raffle: that week sold tickets — it is a real draw, so Commit and Resolve it (or Refund it), never sweep it")
	}
	pureEarned := d.tickets.Total() != 0
	if pureEarned {
		if !d.Committed {
			// THE DRAW CAN STILL HAPPEN AND IS THE RIGHT EXIT. Commit is permissionless
			// and takes the week as an argument, so anyone who wants this week settled —
			// every earned-entry holder, for a start — can commit it right now.
			panic("raffle: that week's entries were all earned and its draw can still happen — commit it and resolve it, and only sweep it if the grace window passes with no draw")
		}
		if !refundGraceElapsed(d) {
			// THE SAME CLOCK REFUND USES, FOR THE SAME REASON. Read the block above: a
			// sweep before this point would destroy a live draw.
			panic("raffle: that week's draw is still live — a week whose entries were all earned may only be swept once the grace window has elapsed")
		}
	} else {
		// DEFENSIVE AND UNREACHABLE. With a zero ticket total the week can never have
		// been committed (Commit refuses a zero total). Stated anyway, loudly, because
		// this function retires money from a week and a silent sweep of a week that had
		// somehow reached that state would be far worse than a failed transaction. (The
		// Resolved and Abandoned halves of the old trio moved above, where they are
		// load-bearing for shape 2.)
		if d.Committed {
			panic("raffle: that week is committed — it is a real draw, not a drawless one")
		}

		// AND SHAPE 1 HAS A CLOCK TOO, SINCE 2026-09-29 — AUDIT-2026-09-28.md finding 28.
		// It is the SAME WINDOW shape 2 waits out (refundGraceBlocks), counted from the
		// height the week ENDED rather than from a commit, because a ticketless week can
		// never be committed and therefore has no CommittedAt to count from.
		//
		// WHY A TICKETLESS WEEK NEEDS A CLOCK AT ALL, GIVEN THAT ITS MONEY HAS NO
		// CLAIMANT AND NO DEADLINE. Because without one, the sweep was FREE AND INSTANT
		// THE MOMENT A WEEK ENDED, and that is what made finding 28's chain possible: a
		// week that receives carried sponsorship is created EMPTY, so if nobody buys into
		// it, it is a ticketless, spend-free week holding sponsorship the instant it ends
		// — this exact shape. One transaction per hop, no wait, and the money could be
		// walked week by week until it stood where the caller wanted it.
		//
		// THAT CHAIN CANNOT BE BUILT ANY MORE AND THE CLOCK IS KEPT ANYWAY, DELIBERATELY.
		// Finding 31 removed the hop itself: no week ever receives another week's
		// sponsorship, so there is no such thing as a week "created empty holding carried
		// money", and the shape this clock was the belt for no longer exists. The gate is
		// retained because it costs nobody anything — the money has no claimant and no
		// deadline, and any caller may sweep the moment the window passes or a year later —
		// and because removing a gate is a change with its own risk, made on its own day.
		// THIS COMMENT IS THE RECORD THAT ITS ORIGINAL JUSTIFICATION IS RETIRED, so that
		// nobody later cites the chain as a live reason.
		//
		// IT STRANDS NOTHING. The money stays in the week, visible in SponsoredOf and in
		// Render, and the sweep has no expiry: any caller may sweep it the moment the
		// window passes, or a year later. The only thing the clock removes is the ability
		// to do it IMMEDIATELY AND REPEATEDLY.
		if runtime.ChainHeight() < weekEndHeight(week)+refundGraceBlocks {
			panic("raffle: that week has no tickets, but its sweep window has not opened yet — a ticketless week may only be swept once the grace window has elapsed since it ended")
		}
	}

	// BEFORE THE ASSERTIONS BELOW, WHICH IS THE WHOLE POINT. d.Cut != 0 asserts that
	// a swept week holds no escrowed fee, on the reasoning that a fee can only arrive
	// with a ticket SALE — true until Sponsor gave a fee a second way in. Folding
	// first restores the assertion's original meaning exactly: whatever Cut remains
	// after the sponsors' share has gone home must still be a ticket-sale fee, and
	// must still be impossible here.
	foldSponsorCut(d)

	amount := d.Sponsored
	if amount <= 0 {
		panic("raffle: that week holds no sponsorship — there is nothing to sweep")
	}
	if d.Pot != amount {
		// Unreachable: BOTH sweepable shapes have no spend record — that is what
		// weekHasNoSpend established above — so the pot identity
		// Pot + Cut == sum(spendOf) + Sponsored reduces to Pot == Sponsored for either
		// of them, given the zero Cut asserted just below. Loud rather than moving a
		// number that does not describe the week it came from.
		panic("raffle: drawless week's pot does not equal its sponsorship")
	}
	if d.Cut != 0 {
		// Unreachable, and asserted rather than assumed — AUDIT-2026-09-28.md finding
		// 25. An escrowed fee can only arrive with a ticket SALE, and both sweepable
		// shapes require sum(spendOf) == 0, so a swept week has no fee to release.
		// Stating it here is what stops this function silently moving a week's
		// sponsorship forward while leaving an unearned fee behind in a week it has
		// just marked Abandoned — which, having no spendOf record to refund it
		// through, nobody could ever reclaim. That would be a new "money in, no way
		// out" path, so it is a loud refusal and not a rollover.
		panic("raffle: a week with no spend is holding an escrowed fee")
	}

	// THE DESTINATION USED TO BE CHOSEN HERE AND IT IS NOT CHOSEN ANYWHERE ANY MORE —
	// AUDIT-2026-09-28.md finding 28. These lines stood here:
	//
	//	dest := currentWeek()
	//	if dd := getDraw(dest); dd != nil {
	//		if dd.Committed { panic(...) }
	//		if dd.Abandoned { panic(...) }
	//	}
	//
	// with a `dd := getOrCreateDraw(dest)` and a two-sided transfer below. Every one of
	// those lines was correct about the week it named; what was wrong is that it named
	// the week that was live AT THE MOMENT A PERMISSIONLESS CALLER CHOSE TO FIRE, so the
	// caller selected where other people's money went by selecting when to call. The
	// defensive refusals are gone with it because there is nothing left to refuse: this
	// function no longer touches a second week, creates no record, reads no beacon, and
	// takes no destination. It retires the money where it stands (retireSponsorship).
	//
	// THE SENTENCE THAT STOOD HERE FOR ONE DAY — "It registers, and the destination pulls at
	// its own birth" — WAS FINDING 31. The destination that pulls is a week the caller
	// creates, so the caller still chose it, and could be its only entrant.

	// A SWEPT PURE-EARNED WEEK IS ABANDONED, PERMANENTLY, AND THAT IS THE OTHER HALF
	// OF FINDING 17. Its ticket weight is real and its prize has just left, so
	// without this flag Resolve would still name a winner over the frozen range and
	// pay them a pot of zero — or, worse, a pot the NEXT sweep or sponsorship had
	// refilled. The existing one-way flag is reused rather than a second one invented:
	// Resolve and Capture already refuse an abandoned week with the exact words they
	// use for a refunded one, Refund's own gate then finds nothing to reclaim, and
	// this function refuses it too (the Abandoned check at the top). There is no path
	// that un-sets it.
	//
	// A SHAPE-1 WEEK IS NOW MARKED TOO, AND IT USED NOT TO BE. The retired reasoning:
	// "A SHAPE-1 WEEK IS NOT MARKED, deliberately: it has no tickets, so Commit refuses
	// it for ever anyway and Resolve and Capture cannot be reached at all. Marking it
	// would be a state change with no meaning." THE FLAG HAS A MEANING NOW, which is what
	// changed: Abandoned is the flag retireSponsorship demands before it will convert a
	// week's sponsorship into a claim, the flag that stops this function sweeping the same
	// week twice (the Abandoned check at the top, which for shape 1 was previously
	// unreachable and is now what makes a second sweep impossible), the flag Refund's gate
	// reads, and the flag AuditFailure's "an abandoned week holds no sponsorship" statement
	// is written in. So both shapes are marked, by one line, and "abandoned" now means
	// exactly "this week's draw will never happen and its money has stopped being a prize".
	d.Abandoned = true
	if pureEarned {
		chain.Emit("SweepAbandonedPureEarnedWeek",
			"week", strconv.FormatInt(week, 10),
			"frozenTotal", strconv.FormatInt(d.FrozenTotal, 10),
			"tickets", strconv.FormatInt(d.tickets.Total(), 10),
			"committedAt", strconv.FormatInt(d.CommittedAt, 10),
			"height", strconv.FormatInt(runtime.ChainHeight(), 10))
	}

	// AND THE MONEY IS RETIRED WHERE IT STANDS. The two-sided transfer that used to be here
	// — d.Sponsored to zero, d.Pot down, heldPots and heldSponsored down and back up
	// against a destination week — is gone with the destination, and so is the register
	// (markCarryPending) that replaced it for one day. Read retireSponsorship.
	//
	// WHICH OF ITS TWO BRANCHES RUNS IS STILL EXACTLY `pureEarned`, AND THAT IS THE WHOLE OF
	// THE "SAY WHICH CASE YOU ARE IN" REQUIREMENT AT THIS SITE — but since
	// AUDIT-2026-09-28.md finding 34 the branch retireSponsorship actually tests is
	// d.earnedTotal, so the equality of the two is asserted below rather than assumed:
	//
	//   - SHAPE 2, pureEarned == true: THE CLAIMANT CASE runs. Every unit of this week was
	//     credited to a duel player through FundPotWithEntries — that is what "no spend and a
	//     non-zero ticket total" means — so earnedTotal == tickets.Total() != 0, and the people
	//     who get this money back are exactly the players whose rake it was. This is the case
	//     finding 16 was about, answered without a destination.
	//   - SHAPE 1, pureEarned == false: d.tickets.Total() == 0, so earnedTotal is 0 too (it can
	//     never exceed the ticket total) and THE NO-CLAIMANT CASE runs: the money goes to
	//     opsPot. No address earned a unit of this week — this is a plain FundPot into a week
	//     nobody entered, a duel rake below one entry unit, or a duel both of whose parties
	//     played from realm code. Nobody is wronged because there is nobody to wrong. A week
	//     that HAS earned holders cannot reach this branch: earnedTotal never decreases.
	//
	// THE SHAPE-2 EQUALITY IS ASSERTED, NOT ASSUMED — finding 34's one new obligation at this
	// site. "No spend implies every unit was earned" is true only because appendTickets has
	// exactly two callers and Buy writes a spendOf record in the same transaction as its
	// append; Refund ZEROES a spend record rather than removing it, but an abandoned week is
	// refused at the top of this function, so a refunded week can never arrive here looking
	// spend-free. That is a four-step argument about three other functions, and it decides
	// whether a week's whole sponsorship goes to its players or to the house. So it is
	// checked, loudly, in the one place that depends on it. UNLIKE THE GUARDS INSIDE
	// retireSponsorship, A PANIC HERE COSTS NOBODY THEIR OWN MONEY: this is the sweep, which
	// may refuse (a dead week's sponsorship has no claimant and no deadline, so any caller may
	// retry for ever) — it is emphatically not Refund.
	if pureEarned && d.earnedTotal != d.tickets.Total() {
		panic("raffle: that week has no spend but its earned units do not account for all its ticket units")
	}
	retireSponsorship(d)

	chain.Emit("SweepDrawlessWeek",
		"week", strconv.FormatInt(week, 10),
		"amount", strconv.FormatInt(amount, 10),
		"pureEarned", strconv.FormatBool(pureEarned),
		"pot", strconv.FormatInt(d.Pot, 10),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10))
	checkInvariant()
}

// --- WithdrawOps ---------------------------------------------------------

// WithdrawOps pushes the whole ops pot to opsVaultAddr and returns the amount
// moved. PERMISSIONLESS.
//
// THE DEFECT IT CLOSES, found 2026-09-28 by the engineer implementing that day's
// fifth fix rather than by the audit: opsPot only ever increased. It was written
// in three places — Buy's house cut (now Resolve's released escrow, finding 25),
// sweepDonations' absorbed arrivals, and
// Refund's move of an abandoned week's sponsorship — and read by nothing but the
// invariant and the reads. There was no outflow anywhere in this file, so three
// separate streams of money became permanently unreachable by every path in the
// realm, THE PRODUCT'S ENTIRE REVENUE AMONG THEM. checkInvariant and AuditFailure
// both stayed green over it, because both count opsPot as money the realm holds
// and neither has an opinion about whether anybody can ever reach it. That is the
// same class of defect as the unreachable week (the audit's first finding) and the
// stranded drawless-week sponsorship (SweepDrawlessWeek).
//
// PERMISSIONLESS, AND THAT IS SAFE PRECISELY BECAUSE THE DESTINATION IS FIXED AT
// COMPILE TIME. A reader will look for a caller check here and there is none, on
// purpose: opsVaultAddr is a const, so the caller does not choose where the money
// goes, cannot name themselves, and cannot name a week's pot. All they can do is
// push the house's money to the house — and paying the gas to do somebody else's
// bookkeeping is a favour, not an attack. Gating it on an operator key would buy
// nothing and would put a liveness dependency for the realm's revenue onto one
// key, exactly as it would for Commit, Capture and Resolve. This is
// r/splash/exchange's SettleOps shape, and the property that makes it sound is the
// one tools/raffle_addr_test.go exists to keep true.
//
// IT NEVER REACHES A PLAYER'S MONEY. No Draw is touched: not Pot, not Sponsored,
// not spendOf, not a ticket. The only book that moves is opsPot, which by
// construction holds nothing any buyer can claim — the fee in it was EARNED BY A DRAW
// THAT ACTUALLY RAN (Resolve releases the week's escrow; a week that fails refunds it
// with the gross, finding 25), a donation belongs to whoever chose to give it away, and
// a dead week's sponsorship was never attributable to a buyer at all.
//
// THE CITATION THAT USED TO STAND HERE IS RETIRED: this paragraph said "the cut was
// taken at sale time (see Refund's 'THE HOUSE CUT IS NOT REFUNDED')", and there is no
// such section in Refund any more — finding 25 deleted the behaviour and Refund records
// the retired paragraph verbatim in its place. A citation that outlives the thing it
// cites is how a reader ends up trusting a rule the code stopped following.
// AUDIT-2026-09-28.md finding 29. NOTE THAT THE THIRD STREAM IS NOW ALMOST CLOSED:
// since 2026-09-29 a dead week's sponsorship goes forward to a future week's prize
// and reaches this counter only when no week can be opened at all (Refund's
// transition, and AUDIT-2026-09-28.md finding 16). That is a deliberate reduction in
// house revenue and it is the safe direction.
//
// AND SINCE 2026-09-29 IT CANNOT REACH AN UNEARNED FEE EITHER, which is the point of
// finding 25 from this function's side. The house cut used to arrive in opsPot the
// instant a ticket was sold, so this call could push out money for draws that had not
// happened yet — and the buyers of a week that then failed got 95% back while the
// missing 5% had already left the realm. The fee now sits in Draw.Cut until Resolve
// releases it, heldCuts is a separate term in checkInvariant, and this function does not
// mention either. A caller who withdraws every block still cannot touch a live week's
// escrow.
//
// sweepDonations RUNS FIRST, as in every other mutator, so a donation that
// arrived since the last state change is included in this withdrawal rather than
// left behind for the next one.
//
// BOOKS FIRST, TRANSFER SECOND, exactly as Resolve and Refund do it: opsPot is
// zeroed BEFORE the wugnot leaves, so a re-entrant call — which wugnot's Transfer
// cannot cause today, having no hook or callback, but a future GRC20 might — finds
// an empty pot and panics rather than a balance it can take twice.
//
// THE INVARIANT IS EXACT ACROSS IT, not merely preserved one-sidedly:
// checkInvariant asserts heldPots + opsPot == balance, and this call reduces both
// sides by the same amount. heldPots and heldSponsored are deliberately untouched.
//
// Panics if there is nothing to withdraw.
func WithdrawOps(cur realm) int64 {
	rejectAttachedCoin(cur, "WithdrawOps")
	sweepDonations()

	amount := opsPot
	if amount <= 0 {
		panic("raffle: the ops pot is empty — there is nothing to withdraw")
	}

	opsPot = 0
	wugnot.Transfer(cross(cur), opsVaultAddr, amount)

	chain.Emit("WithdrawOps",
		"amount", strconv.FormatInt(amount, 10),
		"destination", string(opsVaultAddr))
	checkInvariant()
	return amount
}

// --- reads ---------------------------------------------------------------
//
// All plain and non-crossing: a read needs no authority check.

// PotSize is the CURRENT week's prize pot in ugnot: ticket sales after the house
// cut, PLUS whatever FundPot has sponsored into it (Sponsored, below). It is the
// whole amount the winner takes.
func PotSize() int64 {
	d := getDraw(currentWeek())
	if d == nil {
		return 0
	}
	return d.Pot
}

// TicketTotal is the CURRENT week's ticket units sold.
func TicketTotal() int64 {
	return TicketTotalOfWeek(currentWeek())
}

// TicketTotalOfWeek is a given week's ticket units sold: the LIVE total, not
// FrozenTotal, so it is readable before a commit and is zero for a week that
// never sold a ticket.
//
// IT IS THE READ THAT MAKES A DRAWLESS WEEK VISIBLE. DrawOf reports FrozenTotal,
// which is zero on any uncommitted week, so a caller cannot use it to tell "sold
// nothing" from "sold plenty and was never committed". Sweepability turns on
// exactly that distinction: a past week is sweepable when this is zero and
// SponsoredOf is positive. See SweepDrawlessWeek.
func TicketTotalOfWeek(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.tickets.Total()
}

// TicketsOf is addr's ticket units in the CURRENT week.
func TicketsOf(addr address) int64 {
	return TicketsOfWeek(currentWeek(), addr)
}

// SpendOf is addr's refundable contribution to the CURRENT week in ugnot: THE GROSS
// TICKET PRICE THEY PAID, house fee included, which is exactly what Refund returns.
//
// THIS COMMENT SAID THE OPPOSITE UNTIL NOW AND THE VALUE NEVER CHANGED. It read: "what
// they paid MINUS the house cut, which is what Refund would return. It is not the gross
// ticket price they paid." That was true until 2026-09-29, when the house fee stopped
// being banked at sale time and started being escrowed per week in Draw.Cut
// (AUDIT-2026-09-28.md finding 25): spendOf became the GROSS in the same change, and
// Refund returns the whole ticket price. The function was correct and its documentation
// was not — THE WORST SHAPE OF ALL FOR AN EXPORTED, FRONT-END-FACING READ, because a
// caller who believed it would display a refund quote 5% short and nothing would ever
// fail. Corrected rather than deleted, because the old sentence is the one a reader may
// have in their head. AUDIT-2026-09-28.md finding 29.
func SpendOf(addr address) int64 {
	return SpendOfWeek(currentWeek(), addr)
}

// TicketsOfWeek is addr's ticket units in a given week, so a front end can
// still show a buyer their past weeks once the clock has moved on.
func TicketsOfWeek(week int64, addr address) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return treeInt64(d.ticketsOf, string(addr))
}

// SpendOfWeek is addr's remaining refundable contribution to a given week: their GROSS
// ticket spend, fee included, which is what Refund pays them. Zero once they have been
// refunded. Read SpendOf for the claim this pair used to make and why it is retired.
func SpendOfWeek(week int64, addr address) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return treeInt64(d.spendOf, string(addr))
}

// CurrentWeek is the week tickets are being sold into right now.
func CurrentWeek() int64 {
	return currentWeek()
}

// WeekEndHeight is weekEndHeight, EXPORTED: the chain height at which a given week
// stops being the live one. A week is live for heights [WeekEndHeight(week-1),
// WeekEndHeight(week)) — the returned height is the FIRST height of week+1, NOT the
// last height of week, so at exactly this height CurrentWeek already reads week+1.
// A countdown that showed "1 block left" here would be off by one.
//
// IT IS A BLOCK HEIGHT AND DELIBERATELY NOT A TIME. This realm's week is
// raffleWeekDays*blocksPerDay blocks, and blocksPerDay = 26182 encodes an ASSUMED
// 86400/26182 = 3.29998 s per block (read blocksPerDay for how much that assumption is
// allowed to be wrong). The chain does not actually run at that rate: 3.306 s measured
// on gno.land mainnet and 3.376 s on onyx-1. So a caller wanting a wall-clock countdown
// must multiply by a block time IT chooses and own the error; this realm will not
// return seconds or "time remaining", because that would bake one clock's rounding into
// every front end that reads it and make the contract the source of a number it cannot
// know. Nothing on chain converts blocks to seconds and neither does this.
//
// WHY THIS AND NOT AN EXPORTED launchHeight: it is the stronger primitive, not the
// weaker one. raffleWeekDays and blocksPerDay are both unexported, so a LaunchHeight()
// alone could not be turned into a boundary without a caller hardcoding 7*26182 and
// re-implementing the +1 above. This read goes the other way: launchHeight is
// WeekEndHeight(0) - (WeekEndHeight(1) - WeekEndHeight(0)) and the week's length is
// WeekEndHeight(1) - WeekEndHeight(0), so one function answers every question the
// constant would have, with the off-by-one computed once, here, on chain.
//
// NEGATIVE OR FAR-FUTURE week IS NOT REFUSED and returns the arithmetic for it, exactly
// as weekEndHeight does — this is a pure function of week and launchHeight with no
// record lookup, so there is no "no such week" state to report. WeekEndHeight(-1) is
// launchHeight, the height this realm's week 0 began at, which is a useful answer rather
// than an error.
func WeekEndHeight(week int64) int64 {
	return weekEndHeight(week)
}

// CurrentWeekEndHeight is the chain height at which the LIVE week ends: the one number
// a countdown wants. WeekEndHeight(CurrentWeek()), read in a single call.
//
// IT IS ONE CALL ON PURPOSE. Composing the two exported reads off chain means two
// queries at two different chain heights, and a week that turns over between them yields
// a boundary for a week that has already ended — a countdown that jumps backwards by a
// whole week exactly at the moment it matters most. Read here, both halves see one
// height.
//
// A BLOCK HEIGHT, NOT A TIME, for the reasons on WeekEndHeight.
func CurrentWeekEndHeight() int64 {
	return weekEndHeight(currentWeek())
}

// DrawOf reports a week's record: committed, frozen ticket total, beacon round,
// pot, resolved, winner, abandoned, sponsored. All zero for a week that never
// sold a ticket.
//
// ABANDONED IS PART OF THIS TUPLE rather than a separate read because it is not
// a detail: it is the difference between a week that is waiting for its
// randomness and a week that is paying its buyers back and will never have a
// winner. A front end that showed "unresolved" for both would be lying to a
// buyer about whether to expect a draw or to go and claim a refund.
//
// SPONSORED IS PART OF IT for a related reason: pot minus sponsored is what the
// week's buyers put in and could reclaim, and sponsored is what the arcade added
// on top. A buyer looking at a pot deserves to know which part of it is a claim
// of theirs and which is house money that will never be refunded.
//
// COMMITTED-AT IS THE LAST ELEMENT, and it is here so a front end can compute the
// one number a buyer of a stuck week actually wants: CommittedAt +
// refundGraceBlocks, the height at which their money becomes reclaimable whatever
// the beacon does. RefundOpensAt does that arithmetic; this returns the raw
// height so a caller can also show how long the week has been waiting. Zero on an
// uncommitted week, which is exactly the "no refund clock is running yet" case.
func DrawOf(week int64) (bool, int64, int64, int64, bool, address, bool, int64, int64) {
	d := getDraw(week)
	if d == nil {
		return false, 0, 0, 0, false, address(""), false, 0, 0
	}
	return d.Committed, d.FrozenTotal, d.Round, d.Pot, d.Resolved, d.Winner, d.Abandoned, d.Sponsored, d.CommittedAt
}

// RefundGraceBlocks is refundGraceBlocks, EXPORTED so a front end can state the
// window without hardcoding it — the same reason TicketPrice is exported. Read
// refundGraceBlocks for what it means and how it was derived.
func RefundGraceBlocks() int64 { return refundGraceBlocks }

// RefundOpensAt is the chain height from which Refund will pay this week's buyers
// REGARDLESS OF THE BEACON: CommittedAt + refundGraceBlocks.
//
// ZERO MEANS "THERE IS NO FUTURE HEIGHT TO WAIT FOR", which covers three unrelated
// states and a caller must not read any of them as "refundable now": no record for
// the week, not committed yet (nothing is locked up), already resolved (the pot has
// gone to its winner), or already abandoned (refunds are open this instant and the
// height is behind us). Render draws the same distinction, as "n/a".
//
// IT IS NOW AN EXACT HEIGHT, NOT A CEILING, and the change is worth noting because the
// comment used to hedge. It said refunds "may open much earlier through the
// beacon-derived half of Refund's gate — the moment the committed round falls outside
// beacon.PruneWindow unresolved". THAT HALF OF THE GATE NO LONGER EXISTS (see
// resolvable()'s removal), so this height is the only one at which a refund opens, and
// a front end can show it as a fact rather than as a worst case.
func RefundOpensAt(week int64) int64 {
	d := getDraw(week)
	if d == nil || !d.Committed || d.Resolved || d.Abandoned || d.CommittedAt <= 0 {
		return 0
	}
	return d.CommittedAt + refundGraceBlocks
}

// SponsoredOf is the house money in a given week's pot: what FundPot added, and
// therefore the part of the pot no buyer can ever reclaim. Zero for a week that
// was never sponsored.
//
// THE SECOND HALF OF THIS COMMENT WAS FALSE, WAS CORRECTED, AND IS NOW TRUE AGAIN FOR A
// DIFFERENT REASON. It originally said "and zero again once an abandoned week's
// sponsorship has been moved to the ops pot"; that became wrong when the money started
// going forward to a future week (finding 16) and wrong twice over when it stopped moving
// at the moment of abandonment at all (finding 28).
//
// SINCE FINDING 31 THIS IS ZERO ON EVERY ABANDONED WEEK, and that is a guarantee rather
// than an accident: retireSponsorship zeroes the field in the same statement group that
// sets Abandoned, and AuditFailure reports any week where the two disagree. What the money
// became is a per-unit claim on the SAME week — read ClaimPerUnitOf, UnclaimedOf and
// ClaimableOf, and ClaimDeadWeek for the exit. A front end showing an abandoned week should
// show those three, not this one.
// SponsorsOf is the credit lines a week carries, in the order they were bought.
//
// A COPY, NOT THE SLICE. Returning d.Sponsors itself would hand a caller a
// reference into this realm's own storage; the copy is the same discipline as
// every other read here returning values rather than pointers.
func SponsorsOf(week int64) []Sponsorship {
	d := getDraw(week)
	if d == nil {
		return nil
	}
	out := make([]Sponsorship, len(d.Sponsors))
	copy(out, d.Sponsors)
	return out
}

// SponsorCutOf is how much of a week's escrowed fee came from sponsorships
// rather than ticket sales. Zero on a week that has retired its sponsorship,
// which is what makes "the fee found its way out" checkable from outside.
func SponsorCutOf(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.SponsorCut
}

func SponsoredOf(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.Sponsored
}

// CarryPendingSince AND CarryPendingTotal ARE GONE — AUDIT-2026-09-28.md finding 31. They
// read the carry register, which no longer exists, and there is deliberately no successor
// with the same shape: "how much money is waiting to be moved somewhere" is not a question
// this realm can be asked any more, because no money is waiting and there is nowhere to
// move it to. The three reads below answer the questions that replace it.

// ClaimPerUnitOf is the ugnot each ticket UNIT of a week may reclaim from the sponsorship
// that week's draw never paid out, or 0 for any week that is not abandoned. Read
// Draw.ClaimPerUnit and retireSponsorship.
//
// ZERO ON AN ABANDONED WEEK IS MEANINGFUL AND IS NOT AN ERROR: it means either that the
// week held no sponsorship at all, or that the sponsorship was smaller than the week's unit
// count, so no unit could be given a whole ugnot and the whole amount was sub-unit dust. The
// DeadWeekSponsorshipDistributed and DeadWeekSponsorshipToOps events distinguish the cases.
func ClaimPerUnitOf(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.ClaimPerUnit
}

// UnclaimedOf is how much of a dead week's distributed sponsorship its holders have not
// taken yet — Draw.Claims. It is PART OF THAT WEEK'S POT, so PotSizeOf-style reads already
// include it; this read exists so an operator can see how much of a dead week's money is
// still sitting there, and so AuditFailure's heldClaims re-derivation can be read alongside
// it.
func UnclaimedOf(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.Claims
}

// ClaimableOf is what `addr` may take out of a dead week right now: their EARNED unit weight
// times the week's claim rate, or 0 once they have taken it. IT IS EXACTLY WHAT ClaimDeadWeek
// WILL PAY, derived the same way and off the same tree, so a front end never has to guess.
//
// IT READS earnedOf AND NOT ticketsOf — AUDIT-2026-09-28.md finding 34, and this read had to
// move in the same commit as ClaimDeadWeek's. A read that disagrees with the entry point it
// mirrors is worse than no read at all: a front end would have shown a refunded buyer a
// positive claimable figure and then watched their transaction abort, which is how a caller
// learns to distrust the whole realm. THE TWO DERIVATIONS ARE NOW ONE EXPRESSION, DUPLICATED
// — earnedOf times ClaimPerUnit — and every test that asserts ClaimDeadWeek's return value
// against this read is what keeps them equal.
//
// A BUYER WHO HOLDS ONLY BOUGHT UNITS READS ZERO HERE, AND THAT IS THE ANSWER, NOT A GAP.
// Their money comes back through Refund, in full, fee included. Read EarnedOfWeek alongside
// TicketsOfWeek to see the two kinds of weight separately.
func ClaimableOf(week int64, addr address) int64 {
	d := getDraw(week)
	if d == nil || d.ClaimPerUnit <= 0 {
		return 0
	}
	k := string(addr)
	if d.claimedOf.Has(k) {
		return 0
	}
	return treeInt64(d.earnedOf, k) * d.ClaimPerUnit
}

// EarnedOfWeek is how many of `addr`'s units in a week were EARNED through duel play rather
// than bought — the basis a dead week's sponsorship is divided on. AUDIT-2026-09-28.md
// finding 34.
//
// IT EXISTS SO THE TWO KINDS OF WEIGHT ARE VISIBLE SEPARATELY. TicketsOfWeek returns the
// draw's basis (both kinds, indistinguishable, which is finding 15's design) and this returns
// the claim's. A front end showing a dead week needs both, because "you hold 412 units and
// your claim is on 12 of them" is the only explanation of a zero ClaimableOf that a buyer
// will accept.
func EarnedOfWeek(week int64, addr address) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return treeInt64(d.earnedOf, string(addr))
}

// EarnedTotalOfWeek is a week's whole earned unit count — the divisor retireSponsorship used,
// or will use. Zero on a week whose every unit was bought, which is the state that routes a
// dead week's sponsorship to opsPot rather than to holders.
func EarnedTotalOfWeek(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.earnedTotal
}

// UnclaimedHoldersOf is how many named addresses a dead week still owes a share to, and it is
// the other half of AUDIT-2026-09-28.md finding 37 — the audit's open question, "let an
// operator distinguish heldClaims AWAITING LIVE HOLDERS from heldClaims FROZEN FOR EVER".
//
// heldClaims ON ITS OWN CANNOT ANSWER THAT and neither can UnclaimedOf: a positive number
// means the same thing in both cases. This read turns the amount into a COUNT OF PEOPLE, so
// "3,600,000 ugnot owed to 24 addresses" reads differently from "3,600,000 ugnot owed to 24
// addresses that have not moved in a year", and an operator can at least see which weeks are
// settled and which are not. The DeadWeekFullyClaimed event in ClaimDeadWeek is the push
// version of the same fact, for a week that reaches zero.
//
// IT IS O(EARNED HOLDERS) AND THEREFORE A READ-ONLY FUNCTION AND NOTHING ELSE. It is never
// called from a state-changing path — that is the whole reason retireSponsorship writes a
// rate instead of a tree — and a caller who pays the gas to ask is paying for their own
// answer. COLLECT-THEN-LOOP, NEVER A NESTED avl.Iterate: the earnedOf keys are gathered in
// one pass and every claimedOf lookup happens after it, because nesting a second traversal
// inside the first's callback crashes this toolchain's VM outright (see AuditFailure).
//
// ZERO MEANS "NOTHING LEFT TO PAY" and is the answer on a live week, a resolved week, a week
// that never distributed anything, and a week every holder has claimed out.
func UnclaimedHoldersOf(week int64) int64 {
	d := getDraw(week)
	if d == nil || d.ClaimPerUnit <= 0 {
		return 0
	}
	keys := []string{}
	d.earnedOf.Iterate("", "", func(k string, _ any) bool {
		keys = append(keys, k)
		return false
	})
	n := int64(0)
	for _, k := range keys {
		if !d.claimedOf.Has(k) {
			n++
		}
	}
	return n
}

// Unclaimed is the sum of every week's unclaimed dead-week shares — the aggregate
// heldClaims, exposed so it can be read without iterating. It is already inside the pots, so
// it is not a fourth balance.
func Unclaimed() int64 {
	return heldClaims
}

// Sponsored is the house money in the CURRENT week's pot.
func Sponsored() int64 {
	return SponsoredOf(currentWeek())
}

// CapturedRandomness returns what Capture stored for a week, or the empty
// string if nothing was captured. Kept out of DrawOf so DrawOf's shape stays
// stable for callers.
func CapturedRandomness(week int64) string {
	d := getDraw(week)
	if d == nil {
		return ""
	}
	return d.Randomness
}

// OpsPot is the house's EARNED revenue this realm holds, in ugnot: the fees of weeks
// that actually drew, plus absorbed donations, plus any abandoned week's sponsorship
// that had no live week to roll into.
//
// IT IS NOT "THE ACCUMULATED HOUSE CUT" ANY MORE, which is what this comment said until
// 2026-09-29. A live week's fee is NOT in here — it is escrowed in that week and is
// still refundable. Read EscrowedCut and HeldCuts for the unearned half, and finding 25
// for why the two are separate numbers.
func OpsPot() int64 {
	return opsPot
}

// EscrowedCut is the house fee held against one week and NOT YET EARNED, in ugnot: it
// becomes ops revenue if that week resolves and goes back to the buyers if it does not.
// Zero for a week that has resolved, been fully refunded, or never sold a ticket.
func EscrowedCut(week int64) int64 {
	d := getDraw(week)
	if d == nil {
		return 0
	}
	return d.Cut
}

// HeldCuts is the total unearned house fee this realm holds across every week, in ugnot
// — the aggregate of EscrowedCut and the third term in the solvency equality.
func HeldCuts() int64 {
	return heldCuts
}

// --- enumerating the weeks -----------------------------------------------
//
// WHY A LISTER EXISTS AT ALL. Every other read here needs a week number the
// caller already has, and Render is prose. A front end looking for weeks to
// sweep (see SweepDrawlessWeek) had no way to find them except by parsing the
// rendered table, which is a human-readable format with no stability promise.
// Same shape as r/splash/arcade/duel's OfferIDs / DuelIDs, down to the clamp:
// an offset and a limit in, at most `limit` week numbers out, `limit` clamped to
// PageLimit rather than refused. Week numbers only — DrawOf, SponsoredOf and
// TicketTotalOfWeek are the per-week readers, and a batched row reader would mean
// inventing a second serialisation of the same page for callers to parse.

// PageLimit is the most week numbers one Weeks call returns. A larger limit is
// clamped to it, not refused.
const PageLimit int64 = 100

// WeekCount is the number of weeks that have a record: weeks that sold a ticket
// or were sponsored. O(1); avl keeps its size.
func WeekCount() int64 {
	return int64(draws.Size())
}

// Weeks is a window over the recorded week numbers in ASCENDING ORDER: it skips
// `offset` weeks and holds at most min(limit, PageLimit). Empty past the end.
// Negative arguments are a caller error and panic.
//
// Ascending order is week order, not merely key order, because weekKey is
// fixed-width and zero-padded (see keyWidth) — the same property Render relies on.
//
// A CALLER FINDS THE SWEEPABLE WEEKS by walking this and keeping those where
// week < CurrentWeek(), TicketTotalOfWeek(week) == 0 and SponsoredOf(week) > 0.
func Weeks(offset, limit int64) []int64 {
	if offset < 0 {
		panic("raffle: negative offset")
	}
	if limit < 0 {
		panic("raffle: negative limit")
	}
	if limit > PageLimit {
		limit = PageLimit
	}
	remaining := int64(draws.Size()) - offset
	if remaining < limit {
		limit = remaining
	}
	if limit <= 0 {
		return []int64{}
	}
	weeks := make([]int64, 0, limit)
	// IterateByOffset is avl's own offset-and-count traversal, O(log n + limit);
	// it is not a full scan followed by a slice.
	draws.IterateByOffset(int(offset), int(limit), func(key string, _ any) bool {
		weeks = append(weeks, weekOfKey(key))
		return false
	})
	return weeks
}

// weekOfKey inverts weekKey. ParseInt reads the zero padding fine; a key that
// does not parse cannot have come from weekKey, so it is a corrupt tree and not
// a case to paper over.
func weekOfKey(key string) int64 {
	week, err := strconv.ParseInt(key, 10, 64)
	if err != nil {
		panic("raffle: malformed week key " + key)
	}
	return week
}

// Render is the human-readable view. It ITERATES THE avl.Tree in key order,
// which is week order because weekKey is fixed-width and zero-padded, so the
// output is byte-identical across runs. A Go map here would randomise the order
// and make the rendered state unreproducible.
// sponsorText makes a stranger's credit line safe to put in this realm's markdown.
//
// TWO ESCAPES, NOT ONE. sanitize.InlineText handles the markdown and HTML
// metacharacters; the pipe is escaped separately because Render's per-week table
// is pipe-delimited and a label is allowed to contain '|' — 64 bytes is ample to
// forge a cell and fake a column. The list below is not a table today, and the
// pipe escape is here anyway so that moving this text into one later cannot
// reintroduce the hole. Same two-step, and the same reasoning, as the duel's.
//
// THE ESCAPING IS HERE AND NOT IN Sponsor DELIBERATELY: the stored value stays
// exactly what the sponsor typed, so every reader holds one thing rather than
// having to know whether their copy was pre-escaped.
func sponsorText(s string) string {
	return strings.ReplaceAll(sanitize.InlineText(s), "|", "\\|")
}

// renderSponsors lists a week's credit lines — the thing a sponsorship actually
// buys. Empty string when there are none, so the section simply does not appear.
func renderSponsors(week int64) string {
	d := getDraw(week)
	if d == nil || len(d.Sponsors) == 0 {
		return ""
	}
	out := "\n### Sponsored by\n\n"
	for _, sp := range d.Sponsors {
		out += "- **" + sponsorText(sp.Label) + "** — " + strconv.FormatInt(sp.Amount, 10) + " ugnot\n"
	}
	out += "\nA sponsorship raises the prize and buys no entries: a sponsor cannot win this draw.\n"
	return out
}

func Render(path string) string {
	i64 := strconv.FormatInt

	out := "# SPLASH weekly raffle\n\n"
	out += "Tickets are " + i64(TicketPrice, 10) + " ugnot each (wrapped GNOT, 6 decimals: 1 GNOT = 1000000 ugnot).\n"
	out += "One ticket is " + i64(unitsPerTicket, 10) + " units of draw weight, at " + i64(EntryUnitPrice, 10) + " ugnot a unit.\n"
	out += "The house takes " + i64(HouseCutBps, 10) + " bps of each sale; the rest is the prize, and the whole prize is paid to the winner's wallet.\n"
	out += "THE HOUSE FEE IS HELD IN ESCROW PER WEEK AND IS EARNED ONLY BY A DRAW: a week that is refunded returns the FULL ticket price.\n\n"
	out += "The arcade's rake is sponsored straight into this week's pot, so every duel makes the prize bigger.\n\n"
	out += "- current week: " + i64(currentWeek(), 10) + "\n"
	out += "- this week's pot: " + i64(PotSize(), 10) + " ugnot\n"
	out += "- of which sponsored: " + i64(Sponsored(), 10) + " ugnot\n"
	out += "- this week's tickets: " + i64(TicketTotal(), 10) + "\n"
	out += "- held across all unresolved weeks: " + i64(heldPots, 10) + " ugnot\n"
	out += "- house fees held in escrow, NOT yet earned and still refundable: " + i64(heldCuts, 10) + " ugnot\n"
	out += "- ops pot (earned): " + i64(opsPot, 10) + " ugnot\n"
	// THE UNCLAIMED DEAD-WEEK SHARES, SHOWN BECAUSE THEY ARE MONEY IN A DEAD WEEK'S POT AND A
	// READER WOULD OTHERWISE HAVE TO SUBTRACT THEM OUT BY HAND. Already inside "held across
	// all unresolved weeks" above, so this line is a breakdown and not a fourth term.
	//
	// THE LINE IT REPLACES WAS "sponsorship awaiting the next week to open" (finding 28's
	// register). Nothing awaits a week any more — finding 31 — so the question the old line
	// answered has no answer and the new one names the holders' claim instead.
	out += "- dead weeks' sponsorship owed back to their sponsors, not yet claimed: " +
		i64(heldSponsorRefunds, 10) + " ugnot\n"
	out += "- dead weeks' sponsorship returned to their own holders, not yet claimed: " +
		i64(heldClaims, 10) + " ugnot\n"
	out += "- weeks recorded: " + strconv.Itoa(draws.Size()) + "\n"
	out += renderSponsors(currentWeek())
	// THE TWO NUMBERS A BUYER OF A STUCK WEEK NEEDS. The grace window is stated
	// once here and the per-week table below gives the height it lands on, so a
	// front end can tell a buyer when their money becomes reclaimable even if the
	// beacon never publishes their round again. See refundGraceBlocks.
	out += "- current chain height: " + i64(runtime.ChainHeight(), 10) + "\n"
	out += "- refunds open unconditionally " + i64(refundGraceBlocks, 10) +
		" blocks after a week is committed (about " + i64(refundGraceDays, 10) +
		" days), whatever the beacon does\n"

	if draws.Size() == 0 {
		out += "\nNo tickets have been sold yet.\n"
		return out
	}

	// THE DEAD-WEEK COLUMNS ARE NEW SINCE FINDING 31 AND ARE NOT DECORATION. On an abandoned
	// week `sponsored` is now always 0 — retireSponsorship zeroes it — so without these two a
	// front end reading this table would see a week with a POT, no sponsorship and no buyer
	// claims and have no way to learn that the money is claimable, or by whom. "unclaimed" is
	// what the week still owes its holders and "per unit" is the rate to multiply their weight
	// by; ClaimableOf answers it per address. A pot nobody can see a claim on is how money
	// goes missing quietly, which is the same sentence Draw.Cut carries.
	out += "\n| week | tickets | pot | sponsored | unclaimed | per unit | escrowed fee | committed | round | captured | winner | abandoned | refund opens at |\n"
	out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
	draws.Iterate("", "", func(_ string, value any) bool {
		d := value.(*Draw)
		committed := "no"
		total := d.tickets.Total()
		if d.Committed {
			committed = "yes"
			total = d.FrozenTotal
		}
		captured := "no"
		if d.Randomness != "" {
			captured = "yes"
		}
		winner := "unresolved"
		if d.Resolved {
			winner = string(d.Winner)
		}
		// ABANDONED IS SHOWN, and shown separately from the winner column: a
		// reader must be able to tell a week still waiting for its randomness
		// from one that is refunding and will never be drawn.
		abandoned := "no"
		if d.Abandoned {
			abandoned = "yes"
			if !d.Resolved {
				winner = "refunding"
			}
		}
		// THE HEIGHT A BUYER CAN STOP WAITING AT, per week. "n/a" on a week with
		// no refund clock running: uncommitted (nothing is locked yet), already
		// resolved (the pot has gone to its winner), or already abandoned (refunds
		// are open now and this number is behind us). A bare height rather than a
		// countdown, because Render must be byte-identical for the same state and
		// a countdown would also have to be recomputed by every reader anyway.
		refundOpens := "n/a"
		if d.Committed && !d.Resolved && !d.Abandoned && d.CommittedAt > 0 {
			refundOpens = i64(d.CommittedAt+refundGraceBlocks, 10)
		}
		out += "| " + i64(d.Week, 10) +
			" | " + i64(total, 10) +
			" | " + i64(d.Pot, 10) +
			" | " + i64(d.Sponsored, 10) +
			" | " + i64(d.Claims, 10) +
			" | " + i64(d.ClaimPerUnit, 10) +
			" | " + i64(d.Cut, 10) +
			" | " + committed +
			" | " + i64(d.Round, 10) +
			" | " + captured +
			" | " + winner +
			" | " + abandoned +
			" | " + refundOpens + " |\n"
		return false
	})
	return out
}
