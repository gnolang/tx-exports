// Package speed is the SPLASH HOURLY ticket draw: a draw every hour instead of
// every week.
//
// WHY IT IS A SEPARATE REALM AND NOT A PARAMETER ON r/splash/arcade/raffle. The
// weekly raffle's cadence is woven into eight constants, four build guards and the
// refund grace window, and every one of them had to be re-derived from first
// principles here (see "the two clocks" below). A shared realm with a cadence dial
// would have had to satisfy BOTH sets of constraints simultaneously, which is how a
// margin gets shaved: the hourly window's pin offset is 2400 rounds and the weekly
// one's is 230400, and no single guard can assert both. Two realms, each with its own
// derivation and its own asserted margins, is the honest shape. The mechanics below
// are the raffle's, deliberately: the ticket index, the Commit/Capture/Resolve
// three-phase cycle, the FROZEN-TOTAL property, the one-way refund exit, and the
// pin-at-record-creation rule. Read r/splash/arcade/raffle/AUDIT-2026-09-28.md before
// changing any of them; this file's job was to re-scale the timing without
// re-introducing one of its fourteen findings.
//
// ==========================================================================
// V1 IS SELF-CONTAINED: THERE IS NO SPONSORSHIP AND THERE IS NO FundPot.
// ==========================================================================
//
// The pot is ENTRY MONEY ONLY. Nothing outside this realm can put a coin into a
// window's pot, and this realm calls no other realm's code except r/gnoland/wugnot
// (to move money) and r/splash/beacon (to read a round). There is no cross-realm feed
// in either direction, on purpose, in both directions:
//
//   - NOTHING FEEDS THIS POT. r/splash/arcade/duel's rake goes to the weekly raffle
//     and stays there. Adding a second consumer of that rake would make the duel's
//     settlement depend on two realms' bookkeeping instead of one, and the duel's
//     Collect depending on the raffle's bookkeeping was AUDIT-2026-09-28.md finding
//     14 — the worst liveness defect of the day, in which any raffle panic trapped a
//     resolved duel's whole pool in both realms. It was severed that evening (Collect
//     books, FlushPot delivers) and this realm does not reinstate the shape.
//   - THIS REALM FEEDS NOTHING. No rake, no share, no callback. Its only outbound
//     transfers are wugnot to a winner's wallet, wugnot to a refunding buyer's wallet,
//     and wugnot to opsVaultAddr.
//
// AND THE PROPERTY THAT MAKES THE ABSENCE OF SPONSORSHIP A SECURITY FEATURE RATHER
// THAN A MISSING ONE — THE SOLE-ENTRANT PROPERTY:
//
//	WITH NO HOUSE MONEY IN THE POT, A SOLE ENTRANT MERELY WINS BACK THEIR OWN STAKE
//	MINUS THE HOUSE CUT. The weekly raffle still has the sole-entrant attack, and it
//	is a real one there: the duel's rake is sponsored into the live week's pot, so
//	somebody who buys one ticket into a quiet week with a large sponsored balance
//	collects the sponsorship for the price of the fee on that ticket. Here Pot is
//	exactly sum(spendOf) by construction, so a sole entrant's pot IS their own
//	post-cut spend: they pay 100,000 ugnot, and if they are the only entrant they win
//	95,000 back. THERE IS NO POSITIVE-EXPECTATION SOLO PLAY, so the attack cannot
//	exist — not mitigated, not made expensive, ABSENT, as an arithmetic consequence
//	of the pot's definition.
//
//	(A SOLE ENTRANT IS NO LONGER INDIFFERENT BETWEEN Resolve AND Refund, AND THIS
//	PARAGRAPH SAID THEY WERE. It read: "The same arithmetic makes a sole entrant
//	indifferent between Resolve and Refund: both return exactly their own 95,000."
//	Since 2026-09-29 the fee is ESCROWED per window and earned only by a draw
//	(AUDIT-2026-09-28.md finding 25), so a refund returns the whole 100,000 and a
//	resolve returns 95,000: THE SOLE ENTRANT STRICTLY PREFERS THE DRAW TO FAIL, by
//	exactly the fee. The conclusion this paragraph was supporting is unaffected —
//	solo play is still never positive-expectation, which is what kills the
//	sole-entrant attack — but the incentive it describes is now the general one the
//	owner is weighing: with a refund at 100% of stake, every non-winner prefers a
//	failed window to a drawn one. That is a product decision and is deliberately NOT
//	fixed here; it is recorded in AUDIT-2026-09-28.md so that the next reader of this
//	paragraph does not mistake it for a property of this realm's design. The refund
//	grace window below is therefore not only a multi-entrant concern any more.)
//
// SO DO NOT ADD FundPot, A SPONSORED FIELD, A ROLLOVER OR A JACKPOT WITHOUT
// RE-AUDITING THIS PARAGRAPH. Every one of them puts money in the pot that belongs to
// no entrant, which (a) resurrects the sole-entrant attack, (b) turns the invariant
// Pot == sum(spendOf) into Pot == sum(spendOf) + Sponsored with everything that
// follows from it (see the raffle's Draw.Sponsored, Refund's sponsorship transition
// and SweepDrawlessWeek — three separate mechanisms that exist only because house
// money belongs to nobody), and (c) makes this realm's liveness someone else's
// problem again.
//
// ==========================================================================
// THE ONE-HOUR CADENCE, AND THE TWO CLOCKS
// ==========================================================================
//
// Every duration in the weekly raffle shrinks by roughly 168x here, and THE FAILURE
// MODE OF GETTING ONE WRONG IS SILENT — it is not a panic, it is a draw whose winning
// randomness was public on api.drand.sh before entries closed (finding 10). So each
// constant below is derived in place, and each is asserted by a build guard that obeys
// the doctrine that finding 11 cost three attempts to learn:
//
//	A GUARD THAT PROTECTS A REAL-WORLD DURATION MUST HAVE SECONDS ON BOTH SIDES,
//	SOURCED FROM TWO DIFFERENT CLOCKS, OR IT CANNOT FAIL.
//
// The two clocks available to a realm on this toolchain, neither of which it can
// measure at runtime (there is no block-timestamp getter):
//
//   - DRAND'S PERIOD: beacon.PeriodSeconds = 3 s, EXACT. A round count multiplied by
//     it is real seconds by definition of the beacon.
//   - THE CHAIN'S BLOCK TIME: assumed 86400/blocksPerDay = 3.29998 s, written as the
//     integer 33/10 in guards because 3.3 is not an integer constant. MEASURED ON LIVE
//     gno.land MAINNET ON 2026-09-28: 3.306 s/block over 200,000 blocks and 3.311 s
//     over 20,000. So reality is very slightly SLOWER than this file assumes, by about
//     0.2%. That is the benign direction for every margin here (a slower chain means
//     the beacon's estimate LAGS drand rather than outrunning it, and lagging is
//     correctable by any relay of drand's head — see speedMaxStaleBlocks), but the
//     guards below are stated against a ±10% band rather than against the measurement,
//     because the measurement is of the past.
//
// Nothing in this realm is a timestamp. A window is a sequence number derived from
// chain height; no ticket, spend or draw is dated.
package speed

import (
	"math/bits"
	"strconv"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/fenwick"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/beacon"
)

// --- the economics -------------------------------------------------------

const (
	// TicketPrice is the cost of one ticket in ugnot: 1 GNOT. Money here is wrapped
	// GNOT (r/gnoland/wugnot), a GRC20 with 6 decimals, so 1 GNOT is 1_000_000 ugnot
	// and every amount in this file is an int64 count of ugnot.
	//
	// IT IS NO LONGER "THE SAME PRICE AS THE WEEKLY RAFFLE'S", which is what this
	// comment said until 2026-09-29. The two are now deliberately different — 1 GNOT
	// for an hourly draw, 10 GNOT for a weekly one — and the sentence is corrected
	// rather than deleted, because a reader who remembers the old claim should learn
	// that it moved instead of finding it silently gone.
	//
	// EXPORTED because a front end must be able to quote the price without
	// hardcoding it. A buyer's cost is tickets * this and nothing else: no dynamic
	// pricing, no discount tier, no bonding curve.
	TicketPrice int64 = 1_000_000

	// THERE IS NO EntryUnitPrice IN THIS REALM AND THERE MUST NOT BE ONE. DO NOT ADD
	// IT IN THE NAME OF CONSISTENCY WITH r/splash/arcade/raffle, which grew exactly
	// such a constant on 2026-09-29.
	//
	// HERE ONE TICKET IS ONE UNIT OF WEIGHT, AND THAT IS CORRECT RATHER THAN AN
	// OVERSIGHT, because every unit of weight in this realm is BOUGHT. There is no
	// FundPot, no rake feed, no FundPotWithEntries and no earned entry of any kind
	// (read the package doc — the absence of sponsorship is the simplification this
	// realm is built on), so no money ever has to be turned into weight at a
	// granularity finer than one ticket.
	//
	// The raffle needs the second constant because it has a SECOND, INDEPENDENT
	// producer of weight: duel play, priced off a rake far smaller than a ticket. One
	// constant serving both jobs is what silently deleted that feature for three of
	// the duel's four rungs when the ticket price rose — AUDIT-2026-09-28.md finding
	// 22. That pressure does not exist here, and inventing the constant anyway would
	// buy a divisibility build guard, a units-per-ticket conversion and a second
	// number to keep in step, all to express `units = tickets`.

	// houseCutBps is the share of every ticket sale that is the house's FEE rather
	// than prize money: 500 bps, 5%. Same as the raffle's and the duel's.
	//
	// IT IS ESCROWED PER WINDOW AND EARNED ONLY BY A DRAW, since 2026-09-29, exactly
	// as in the raffle: Buy credits Draw.Cut and not opsPot, Resolve moves it, and a
	// window that never draws refunds the FULL ticket price. AUDIT-2026-09-28.md
	// finding 25.
	houseCutBps int64 = 500
	bpsDenom    int64 = 10_000

	// cutPerTicket is the house fee on ONE ticket: 50_000 ugnot. It exists for the
	// build guard below, not for the arithmetic — read the guard.
	cutPerTicket = TicketPrice * houseCutBps / bpsDenom
)

// GUARD 1 (DESIGN.md section 4 numbers all seven). A NEGATIVE ARRAY LENGTH IS A COMPILE
// ERROR, so this line fails the BUILD if a
// future edit pushes the house cut to or past the denominator — the case in which
// the prize remainder is zero or negative and tickets are sold into a pot that can
// never hold anything.
//
// THE `- 1` IS NOT DECORATION. Without it the guard admits houseCutBps == bpsDenom,
// which compiles to a length of ZERO and is therefore SATISFIED, while the house
// takes 100% of every sale and Buy credits the prize pot with nothing at all. That
// exact omission shipped in the raffle and is AUDIT-2026-09-28.md finding 11's
// second half; the cost of the character is nothing.
var _ [bpsDenom - houseCutBps - 1]struct{}

// GUARD 1b — THE HOUSE CUT MUST BE EXACT ON A SINGLE TICKET. Length 0 when
// TicketPrice * houseCutBps divides bpsDenom exactly, NEGATIVE — a compile error —
// otherwise.
//
// IT IS THE GUARD THE ESCROWED FEE'S REFUND PATH RESTS ON, and it is a verbatim
// transcription of the raffle's, for the same reason. Buy floors the cut over a whole
// call's cost and books it to Draw.Cut; Refund re-derives one buyer's share of that Cut
// by flooring over their accumulated GROSS. The two agree for every possible sequence
// of purchases only if the flooring never discards anything, because
// floor(a/n) + floor(b/n) can be one LESS than floor((a+b)/n). With a remainder, two
// separate one-ticket buys would book less Cut than a single refund re-derives,
// Draw.Cut would go NEGATIVE and checkInvariant would abort the refund of a buyer whose
// own money sits in this realm — a "money in, no way out" path manufactured by a
// rounding error. With the guard, cut == tickets * cutPerTicket for every call and every
// partial sum. AUDIT-2026-09-28.md finding 25.
var _ [cutPerTicket*bpsDenom - TicketPrice*houseCutBps]struct{}

// --- the ops destination -------------------------------------------------
//
// opsVaultAddr — gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops. THE ONE PLACE THE HOUSE'S MONEY CAN GO,
// fixed at compile time, and a VERBATIM DUPLICATE of r/splash/arcade/raffle's,
// r/splash/arcade/duel's and r/splash/exchange's constant of the same name.
//
// IT IS DUPLICATED RATHER THAN IMPORTED for the reason those three state: a realm's
// address is a pure function of its package path (gnolang.DerivePkgCryptoAddr), the
// sibling realms' constants are unexported, and this is a different package. The
// realm at that path need not exist yet for the address to be right.
//
// tools/speed_addr_test.go re-derives it from the package path on every
// `go test ./tools`, fails on a mismatch, fails on any address constant in this file
// it has not been told about, and pins it to the raffle's and the duel's copies. A
// Gno-side test cannot be that guard: an assertion that WithdrawOps' transfer landed
// at opsVaultAddr is true for ANY value of opsVaultAddr, including a wrong one, so a
// passing suite would pin the defect rather than catch it. That is exactly how
// r/splash/exchange's R3 finding (a label hash shipped as a live destination)
// happened.
//
// BEING A COMPILE-TIME CONSTANT IS ALSO THE WHOLE AUTHORISATION ARGUMENT FOR
// WithdrawOps BEING PERMISSIONLESS — see there.
//
// KNOWN AND NAMED, NOT DISCOVERED: gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/ops DOES NOT EXIST YET. This is
// AUDIT-2026-09-28.md's fourth unfixed defect (findings 11-14 preamble) and it is
// still blocking for deployment — of this realm as much as of the other three. Until
// a realm with a withdrawal path is deployed at that package path, WithdrawOps
// pushes wugnot to a package-derived address with no code at it, which is money out
// of this realm and into one nobody can spend from. THIS REALM DOES NOT MAKE THAT
// WORSE (it adds a fourth stream to a destination that already has three) AND IT
// MUST NOT BE READ AS ACCEPTING IT: the owner's address is the missing input.
const opsVaultAddr address = "g1dqnxfp5zj89ggfcfzvampmhmrkjq36d2zvdyk7"

// --- the chain's clock ---------------------------------------------------

// blocksPerDay is the block-count day unit, copied verbatim from r/splash/game,
// r/splash/arcade/raffle, r/splash/arcade/duel and r/splash/beacon, all of which
// use the same figure: this toolchain exposes no block-timestamp getter, so the
// only clock a realm can read is chain height, and 26182 blocks is one day at the
// assumed 3.29998 s a block.
//
// IT IS AN ASSUMPTION AND IT IS DEPLOYMENT-BLOCKING, and that is the beacon's
// finding-12 residual, inherited here unchanged: if the chain's average block time
// settles persistently BELOW 3.29998 s, beacon.EstimatedLatestRound's refusal
// becomes permanent and no new window can ever be opened in this realm. Already-open
// windows still resolve or refund on their own clocks and WithdrawOps still runs, so
// no money is trapped; new business stops. Measured on live mainnet 2026-09-28 at
// 3.306-3.311 s, i.e. on the SAFE side of that threshold by ~0.2%, which is not much
// margin — see beacon.maxEstimateStaleBlocks.
const blocksPerDay = 26182

// windowBlocks is ONE DRAW WINDOW in blocks: one hour.
//
// THE DERIVATION. blocksPerDay / 24 = 26182/24 = 1090.9167, and a block count must
// be an integer, so the integer division truncates to 1090 blocks. At the assumed
// 3.29998 s a block that is 3596.98 real seconds — 3.02 s short of an hour, an error
// of 0.08%, which is two orders of magnitude smaller than the ±10% block-time band
// every margin below is stated against. Rounding UP to 1091 (3600.28 s) would be
// equally defensible; truncation is chosen because `blocksPerDay / 24` is a
// derivation a reader can check without a calculator, and because a slightly SHORT
// window is the safe direction for the pin guard (the pin must outlast the window).
//
// THERE IS NO INTERMEDIATE DAY UNIT AND NO windowHours DIAL. The raffle has
// currentDay() and raffleWeekDays because a week is naturally seven of something;
// an hour is not naturally n of anything shorter that this chain can measure, so
// this constant is the single dial and currentWindow() divides by it directly.
const windowBlocks = blocksPerDay / 24

// GUARDS 2 AND 3 — THE WINDOW IS AN HOUR, TO WITHIN 1%, AND THESE TWO LINES FAIL THE
// BUILD IF IT STOPS
// BEING ONE. A negative array length is a compile error.
//
// SECONDS ON BOTH SIDES, FROM TWO DIFFERENT CLOCKS, as the doctrine requires:
//
//	LEFT/RIGHT — the window's real duration via the CHAIN's clock:
//	             windowBlocks * 33/10 = 1090 * 3.3 = 3597 s
//	THE OTHER  — 3600 seconds, which is what an hour IS. Not a constant of this file,
//	             not derived from blocksPerDay, and impossible to cancel against
//	             anything on the left: it is the wall clock.
//
// The band is ±1% (3564 s .. 3636 s). 3597 sits 33 s above the floor and 39 s below
// the ceiling, so either guard fails on a ~1% move in blocksPerDay — which is the
// point. If the owner re-measures the block time and blocksPerDay moves by more than
// a percent, the build stops and every derivation below has to be re-read rather than
// silently rescaled. That is the whole reason a "window length" guard exists at all:
// an hourly draw whose window is quietly 40 minutes is not a rounding error, it is a
// different product with a pin offset sized for a different one.
var _ [windowBlocks*33/10 - 3564]struct{}
var _ [3636 - windowBlocks*33/10]struct{}

// randomnessHexLen is the length of a beacon randomness string: sha256, hex-encoded,
// 64 characters.
const randomnessHexLen = 64

// --- the beacon's cadence ------------------------------------------------

// roundsPerWindow is one draw window in DRAND ROUNDS: 28800/24 = 1200 rounds an hour
// at drand evmnet's three-second period.
//
// IT IS TAKEN FROM THE BEACON AND IS NOT A NUMBER TYPED INTO THIS FILE, and that is
// the single most important line of the migration this realm inherits. The weekly
// raffle carried `const beaconRoundsPerDay = 288` — the cadence of the beacon SPLASH
// itself used to run, one round every five minutes — and when r/splash/beacon
// switched to drand evmnet (period THREE seconds) every round-denominated constant
// derived from it was wrong by a factor of 100 the moment the key changed, silently
// re-opening finding 10. Reading the cadence from beacon.RoundsPerDay means the two
// can never disagree again. See AUDIT-2026-09-28.md section A1.
const roundsPerWindow = beacon.RoundsPerDay / 24

// --- pinning the window's beacon round -----------------------------------
//
// THE ROUND A WINDOW IS DRAWN ON IS FIXED WHEN THE WINDOW'S RECORD IS CREATED — by
// its first ticket sale — AND NEVER WHEN IT IS COMMITTED. getOrCreateDraw writes
// Draw.Round exactly once and nothing else in this file ever writes it again.
//
// WHY, IN ONE PARAGRAPH, BECAUSE THE FULL ACCOUNT IS AUDIT-2026-09-28.md FINDING 10
// AND IT IS THE WORST DEFECT OF THAT DAY. If the committer chose the round — the
// raffle bound Round = beacon.Latest() + 1 inside Commit — then the round was chosen
// AFTER the ticket set was already frozen and public, so anybody who could produce or
// foresee a signature could enumerate candidate rounds off-chain, compute
// ownerOfUnit(d, randomness(r) mod FrozenTotal) for each, and steer the draw onto one
// that named them. Pinning at record creation removes the choice entirely: at the
// instant the number is written there is no ticket set for it to be advantageous
// against, and Commit has nothing to compute.
//
// THE PROPERTY THE OFFSET MUST HAVE, AND IT IS A REAL-TIME PROPERTY:
//
//	THE PINNED ROUND MUST BE SIGNED AFTER ENTRIES CLOSE. If it is signed before,
//	the last buyer of the window can read its randomness off api.drand.sh, compute
//	the winning unit for every candidate purchase size, and buy exactly enough
//	tickets to land on a unit they own. That is not a theoretical attack against
//	drand: drand's randomness is PUBLIC the moment it is signed, which makes this
//	strictly easier than the version finding 10 describes (there it needed the
//	beacon's key).
//
//	THE WORST CASE IS A WINDOW WHOSE RECORD IS CREATED IN ITS FIRST BLOCK: the whole
//	window still has to elapse before entries close, so the offset must exceed ONE
//	WHOLE WINDOW of real time. That is 3597 s at the nominal block time, and more
//	when the chain is slow, because a window is a BLOCK count while the offset is a
//	ROUND count and drand rounds are real time by definition.
//
// THE DERIVATION OF THE MARGIN, WHICH IS ONE WHOLE WINDOW AND NOT A FRACTION OF ONE.
// The raffle's margin is one day on a seven-day week — 1/7 — and copying that ratio
// here would give ~8.5 minutes, which is NOT ENOUGH, and the reason is the term that
// does not shrink with the cadence: the beacon's own admitted extrapolation error.
// beacon.EstimatedLatestRound is a line fitted at the assumed block time, so its
// error is |A - B| seconds of drand time per block since its anchor was last raised —
// 0.33 s a block at the edges of the ±10% band — and over the beacon's default
// backstop of one day of blocks that is 8640 s, 2.4 HOURS. That single term is 2.4
// times a whole hourly window. So:
//
//	EITHER the pin offset is several hours (and the game stops being hourly, because
//	Resolve cannot run until the pinned round is signed),
//	OR the staleness tolerance is tightened far below the beacon's backstop so that
//	the error term shrinks to fit inside an hour-scale margin.
//
// THE SECOND, and that is what speedMaxStaleBlocks below is. It is the reason
// beacon.EstimatedLatestRoundWithin exists ("a consumer can tighten and cannot
// loosen"), and r/splash/arcade/duel already uses it at the other extreme of the
// scale (450 blocks, for a 300-second bind margin).
//
// SO: ONE WINDOW FOR THE WINDOW, PLUS ONE WINDOW OF MARGIN.
//
//	pinOffsetWindows = 2
//	pinOffsetRounds  = 2 * 1200 = 2400 rounds = 7200 seconds EXACTLY (drand's clock)
//
//	MARGIN AT THE NOMINAL BLOCK TIME  = 7200 - 3597          = 3603 s  (1.00 h)
//	MARGIN AT THE SLOW EDGE (3.63 s)  = 7200 - 3956          = 3244 s  (0.90 h)
//	LESS THE BEACON'S ADMITTED ERROR  = 3244 - 719           = 2525 s  (0.70 h)
//
// and the last line is asserted at compile time by guard 5 below. A 42-minute
// margin on a one-hour window, in the worst admitted combination of a 10% block-time
// drift and a maximally stale beacon.
//
// WHAT THE MARGIN COSTS, STATED BECAUSE IT IS NOT FREE: a window pinned in its LAST
// block has its round signed pinOffsetRounds = 2 hours after it closes, so Resolve may
// have to wait that long after Commit. That wait is the bounded part of the honest
// cycle, and the refund grace window has to outlast it — see refundGraceBlocks, where
// this constant reappears.
//
// WHY A ROUND NUMBER AND NOT A HEIGHT: rounds are a beacon counter with no on-chain
// mapping to chain height, so the only anchor a realm has is what the beacon reports
// at pin time. That is also why pinning requires the beacon to have published at least
// once — see getOrCreateDraw.
const (
	// pinOffsetWindows is how many whole windows past the pin the round sits: the
	// window itself, plus one window of margin. THE ONE DIAL — raising it lengthens
	// the honest cycle and therefore feeds refundGraceBlocks.
	pinOffsetWindows = 2

	// pinOffsetRounds is that in beacon rounds: 2 * 1200 = 2400.
	pinOffsetRounds = roundsPerWindow * pinOffsetWindows
)

// GUARD 4 (DESIGN.md section 4's numbering) — THE PINNED ROUND MUST OUTLAST THE WINDOW'S
// ENTRIES, AT THE NOMINAL BLOCK
// TIME. This line fails the BUILD if it ever stops doing so.
//
// READ THE UNITS, BECAUSE THE UNITS ARE THE WHOLE POINT. The guard this replaces in
// the raffle's history was
//
//	var _ [pinOffsetRounds - raffleWeekDays*beaconRoundsPerDay - 1]struct{}
//
// which is ROUNDS on the left and ROUNDS on the right with the cadence on both sides,
// CANCELLING: set the cadence to 288, to 28800 or to 3 and it is equally satisfied
// while the real-time distance it protects changes by two orders of magnitude. It is
// the reason the five-minute-to-three-second switch could have shipped with finding 10
// wide open. An assertion that cannot fail is not an assertion.
//
// THIS ONE COMPARES SECONDS TO SECONDS FROM TWO DIFFERENT CLOCKS:
//
//	LEFT  — the pinned round's distance in real seconds, via DRAND's period:
//	        pinOffsetRounds * beacon.PeriodSeconds = 2400 * 3 = 7200 s = 2.000 hours
//	RIGHT — one window in real seconds, via the CHAIN's ~3.3 s block time:
//	        windowBlocks * 33/10 = 1090 * 3.3 = 3597 s = 0.99916 hours
//	MARGIN = 3603 seconds, the one window pinOffsetWindows asks for.
//
// MUTATION-TESTED, NOT REASONED ABOUT, and the failing build output is recorded in
// DESIGN.md section 4: replacing the derived `beacon.RoundsPerDay / 24` with a
// hardcoded five-minute-cadence figure (`const roundsPerWindow = 12`, the exact class
// of error section A1 is about) makes this length -3526 and the build fails.
var _ [pinOffsetRounds*beacon.PeriodSeconds - windowBlocks*33/10 - 1]struct{}

// GUARD 5 — AND THE MARGIN MUST SURVIVE THE WORST ADMITTED COMBINATION: THE WINDOW
// MEASURED AT THE SLOW EDGE OF THE BLOCK-TIME BAND, LESS THE BEACON'S WORST ADMITTED
// EXTRAPOLATION ERROR AT THIS REALM'S OWN STALENESS TOLERANCE.
//
// Guard 4 above compares the pin against a window at the NOMINAL block time and says
// nothing about either the window LENGTHENING or the anchor being WRONG. Both terms are
// real, and omitting the first of them was AUDIT-2026-09-28.md finding 13's "term nobody
// had written down".
//
// THREE TERMS, THREE CLOCKS, NO CONSTANT ON BOTH SIDES:
//
//	LEFT   = pinOffsetRounds * beacon.PeriodSeconds        = 7200 s   (drand's clock, exact)
//	MINUS    windowBlocks * 363/100                        = 3956 s   (the chain's, slow edge
//	                                                                   of the ±10% band: 3.63 s)
//	MINUS    speedMaxStaleBlocks * 33/100                  =  719 s   (the beacon's admitted
//	                                                                   error: 0.33 s a block over
//	                                                                   this realm's own tolerance)
//	MARGIN                                                 = 2524 s   = 42 minutes
//
// THE WINDOW LENGTHENS AND THE PIN DOES NOT, which is the second term's whole reason:
// a window is a BLOCK count (windowBlocks, read through currentWindow) while
// pinOffsetRounds is a ROUND count, and drand's rounds are real time by definition. So
// at a block time B the margin is 7200 - 1090*B seconds:
//
//	B = 3.29998 (nominal)   margin = 3603 s = 60.0 min
//	B = 3.63    (10% slow)  margin = 3244 s = 54.1 min   — before any staleness at all
//	B = 6.606   (2x slow)   margin = 0      — GONE
//
// so this realm's finding-10 defence rests on a 100% tolerance in blocksPerDay, where
// the weekly raffle's rests on 14.3%. THAT IS THE ONE PLACE THE HOURLY CADENCE IS
// STRUCTURALLY SAFER THAN THE WEEKLY ONE, and it is worth stating: the pin margin is a
// whole window rather than 1/7 of one, so a block-time error has to be enormous rather
// than merely large before it eats the margin. The cost of that ratio is paid in
// Resolve's wait, not in safety.
//
// IT CAN FAIL: tighten nothing and set pinOffsetWindows = 1 and the length goes
// negative (3600 - 3956 - 719 - 1 = -1076); loosen speedMaxStaleBlocks to the beacon's
// backstop and it goes negative (7200 - 3956 - 8640 - 1 = -5397); lengthen windowBlocks
// and it goes negative. Each of those is a real design mistake and each stops the build.
var _ [pinOffsetRounds*beacon.PeriodSeconds - windowBlocks*363/100 - speedMaxStaleBlocks*33/100 - 1]struct{}

// --- the beacon's staleness tolerance ------------------------------------

// speedMaxStaleBlocks is how stale this realm is willing to let r/splash/beacon's
// anchor be before it refuses to open a new window: TWO WINDOWS of blocks, 2180, about
// two hours.
//
// IT IS PASSED TO beacon.EstimatedLatestRoundWithin RATHER THAN USING
// beacon.EstimatedLatestRound, AND THAT IS NOT A MICRO-OPTIMISATION — THE DEFAULT IS
// FAR TOO LOOSE FOR AN HOURLY DRAW. The beacon's backstop is
// beacon.MaxEstimateStaleBlocks = blocksPerDay = 26182 blocks, sized for the weekly
// raffle, and it admits 26182 * 0.33 = 8640 s = 2.4 HOURS of error in the pin. The
// weekly raffle's nominal pin margin is 24 hours, so 2.4 hours fits with room. THIS
// realm's whole pin margin is ONE HOUR. Anchoring against the default would admit an
// error 2.4x the entire margin, which is finding 10 with the guard satisfied — the
// pinned round's randomness public before entries close, and no guard in the file able
// to see it, because nothing distinguishes a fresh anchor from a stale one.
//
// THE DERIVATION, FROM THE MARGIN IT PROTECTS:
//
//	The error is |A - B| seconds of drand time per block since the anchor was last
//	RAISED, where A = 3.29998 s is assumed and B is real — so 0.33 s a block at the
//	edges of the stated ±10% band (2.97 s .. 3.63 s; the band is r/splash/beacon's,
//	stated there, and 2026-09-28's live measurement of 3.306-3.311 s sits well inside
//	it). For S blocks of staleness the error is S * 0.33 seconds.
//
//	The margin it must fit inside is the slow-edge pin margin, 7200 - 3956 = 3244 s.
//	Spending ALL of it would leave zero, so the tolerance is sized to spend about a
//	fifth of it:
//
//	    S = 2 * windowBlocks = 2180 blocks  ->  2180 * 0.33 = 719 s of error
//	    remaining margin                    ->  3244 - 719  = 2525 s = 42 minutes
//
//	i.e. a 4.5x margin over the error admitted, against the raffle's 3x. Guard 5 above
//	asserts exactly this relation at compile time.
//
// WHY TWO WINDOWS AND NOT ONE, OR TEN. It is a LIVENESS price, not a safety one, and
// the two directions are not symmetric:
//
//   - TOO TIGHT and nobody can open a window unless somebody relayed a drand round very
//     recently, so the game is unplayable between relays. One relay costs ~17.0M gas
//     (~0.57% of a 3e9 block), so this is a real cost somebody has to want to pay.
//   - TOO LOOSE and the pin margin goes, which is finding 10.
//
// Two hours is chosen because it is the same order as the honest cycle it sits beside:
// resolving a window requires relaying its pinned round, which is signed 2 hours after
// the window opened, so A REALM BEING PLAYED AT ALL PRODUCES A RELAY ROUGHLY EVERY
// WINDOW. The tolerance is set to twice that so one skipped hour does not close the
// game, and any caller can clear a refusal with a single Publish of drand's current
// round.
//
// AND THE RELAY THAT CLEARS IT IS ALWAYS AVAILABLE IN THE DIRECTION THE CHAIN ACTUALLY
// DRIFTS. Raising the beacon's anchor needs a signature for a round ABOVE its current
// estimate, which exists precisely when the estimate is BEHIND drand's head — i.e. when
// the chain is slower than 3.29998 s a block. Live mainnet measures 3.306-3.311 s, so
// that is today's direction and the refusal is clearable. In the other direction it is
// not, and that is the beacon's finding-12 residual, recorded at blocksPerDay above.
const speedMaxStaleBlocks = windowBlocks * 2

// GUARD 6 — THIS REALM MAY ONLY EVER TIGHTEN THE BEACON'S BOUND, NEVER LOOSEN IT, and
// this line
// fails the BUILD if it stops holding. beacon.EstimatedLatestRoundWithin PANICS on a
// tolerance above beacon.MaxEstimateStaleBlocks, so without this guard a raised
// speedMaxStaleBlocks would compile and then refuse every single Buy at runtime — a
// realm that cannot sell a ticket, discovered on chain rather than at build time.
//
// BLOCKS ON BOTH SIDES, FROM THE SAME CLOCK, AND THAT IS CORRECT HERE: this guard does
// NOT protect a real-world duration, it protects an API PRECONDITION whose own units
// are blocks on both sides by definition (beacon.MaxEstimateStaleBlocks is a block
// count and the argument is a block count). The seconds-from-two-clocks doctrine
// applies to the duration guards — 2, 3, 4, 5 and 7 — and applying it here would be
// cargo-culting it. 26182 - 2180 = 24002.
var _ [beacon.MaxEstimateStaleBlocks - speedMaxStaleBlocks]struct{}

// maxPinnableLatest is the highest anchor round from which a round can still be pinned
// without the int64 addition wrapping. A wrapped pin would be a NEGATIVE round — a
// round nobody can ever publish, and therefore a window that could never be resolved.
// getOrCreateDraw refuses instead, loudly.
//
// IT IS BELT-AND-BRACES ON AN ADDITION AND NOT A LIVE GRIEFING SURFACE, because drand
// cannot sign a round whose time has not come: the beacon's latest round is bounded
// above by drand's real head (~2.1e7, gaining ~1.05e7 a year, reaching 9.2e18 in about
// 880 billion years). It stays because the arithmetic still must not wrap, and because
// a future change of beacon must not silently inherit the assumption that it cannot.
// See AUDIT-2026-09-28.md section C.
const maxPinnableLatest = int64(maxInt64) - pinOffsetRounds

// --- the refund grace window ---------------------------------------------
//
// refundGraceBlocks IS A BEACON-INDEPENDENT FLOOR ON BUYER ACCESS, and it is the ONLY
// thing in this file that lets a committed window's pot out when nobody relays its
// pinned round. Read Refund with it.
//
// THE DEFECT IT CLOSES, inherited from AUDIT-2026-09-28.md finding 7 rather than
// rediscovered: a window's round is pinned at anchor + pinOffsetRounds, and if nobody
// ever relays that round then Resolve panics "beacon round not published yet" for
// ever. Refund requires Committed, so not committing is not a defence — the only route
// out of a stranded window runs through the very act that would set the trap. Without
// a clock-based exit the window's whole pot — the buyers' OWN money — would be
// unreachable by every path in this file while heldPots went on counting it, so
// checkInvariant and AuditFailure would both stay green over money that was gone. That
// is the same class of defect as findings 1, 5, 6 and 7 and it is the class this realm
// was written to avoid reproducing.
//
// A BEACON-STATE GATE CANNOT DO THIS JOB, and the reason is worth keeping: since the
// drand migration nothing is ever LOST — every round is served for ever by at least
// three public relays and beacon.Publish is permissionless — so the failure mode is
// pure LIVENESS, "nobody has bothered to relay it". No property of the beacon's state
// distinguishes "not relayed yet" from "never will be". A CLOCK CAN. That is precisely
// what this constant is, and it is why r/splash/arcade/raffle deleted its resolvable()
// helper entirely rather than rescaling it (see the note at Refund).
//
// THE DERIVATION, because the number must not be picked.
//
//	THE BOUNDED PART OF THE HONEST CYCLE, measured from Commit because Commit is what
//	CommittedAt records:
//
//	  1. WAITING FOR THE PINNED ROUND TO BE SIGNED: up to pinOffsetRounds = 2400
//	     rounds = 7200 s = 2 HOURS EXACTLY. The worst case is a window whose record was
//	     created in its final block, so the pin is measured from almost exactly the
//	     moment entries close and the round lands the whole offset after Commit. (A
//	     window opened early pins a round that is already signed by Commit time, which
//	     is fine and is the point: nobody CHOSE it.)
//	  2. WAITING FOR SOMEBODY TO RELAY IT: UNBOUNDED. Nothing forces anyone to spend
//	     ~17.0M gas relaying a round for a pot of a few tenths of a GNOT, and no
//	     deadline exists past which the round becomes unobtainable. So this term cannot
//	     appear in the derivation at all, and the grace window is not one of two
//	     independent openers — IT IS THE ONLY ONE.
//
//	SO THE GRACE MUST BE STRICTLY LONGER THAN 2 HOURS, or refunds would open on windows
//	whose pinned round has not even been signed yet, which is a FUND DRAIN and not an
//	inconvenience: a buyer who can compute that they did not win would refund, annulling
//	a live draw.
//
//	TWELVE WINDOWS — TWELVE HOURS — IS CHOSEN, giving a 6x margin over the bounded part
//	(43164 s against 7200 s; asserted below). The ten hours above the bound are the
//	RELAY ALLOWANCE: how long this realm is willing to wait for somebody to relay one
//	round before it hands the money back.
//
//	WHY NOT THE RAFFLE'S RATIO. The raffle's window is 21 days against an 8-day bound,
//	2.6x. Copying 2.6x here would give ~5 hours. Twelve hours is chosen instead for a
//	reason specific to this cadence, and it is the one place the hourly draw is WORSE
//	than the weekly one:
//
//	  THE FAIRNESS RACE FINDING 7 RECORDS GETS CHEAPER AS THE WINDOW SHORTENS. Past the
//	  grace window, on a window whose round HAS since been relayed, Resolve and Refund
//	  are both open and the first caller wins — so a buyer who can see they did not win
//	  refunds instead of losing, which sets Abandoned and ANNULS THE DRAW for everyone
//	  (every other buyer then takes their own spend back too). Nobody can take anybody
//	  else's money — that is what Abandoned and the per-buyer spend record guarantee —
//	  so this is a fairness and liveness cost, not a solvency one. But the state that
//	  produces it needs only "nobody relayed one round for twelve hours" here, where the
//	  raffle needs "nobody relayed one round for three weeks". A LONGER WINDOW MAKES THE
//	  STATE RARER; a shorter one gets buyers their money back sooner. Twelve hours
//	  (same-day) is the balance struck, it is A DIAL, and closing the race properly
//	  still means a two-phase refund — announce, then claim — which is a separate change
//	  in this realm exactly as it is in the raffle.
const (
	// refundGraceWindows is the window count. THE ONE DIAL: refundGraceBlocks is
	// derived from it, so re-tuning it cannot leave two units disagreeing.
	refundGraceWindows = 12

	// refundGraceBlocks is that in blocks — the value Refund actually compares
	// against runtime.ChainHeight(). 12 * 1090 = 13080.
	refundGraceBlocks = windowBlocks * refundGraceWindows
)

// GUARD 7 — THE GRACE MUST OUTLAST THE BOUNDED PART OF THE HONEST CYCLE, and this line
// fails the BUILD if it ever stops doing so.
//
// IT IS NOT A BARE INTEGER COMPARISON, AND THE BARE VERSION IS AUDIT-2026-09-28.md
// FINDING 11. The raffle carried
//
//	var _ [refundGraceDays - pinOffsetDays - 1]struct{}   // 21 - 8 - 1 = 12
//
// with a comment claiming "the units are days on both sides, and days are real time".
// THEY ARE NOT THE SAME DAY: the left became BLOCKS (a real duration of blocks x an
// unknown block time B) and the right became DRAND ROUNDS (a real duration of exactly
// 3 s each). The guard compared the bare integers 21 and 8, named neither cadence, and
// therefore COULD NOT FAIL FOR ANY VALUE OF ANYTHING — at blocksPerDay = 2618 it still
// compiled while the grace shrank to 2.4 real days against an 8-real-day bound. The
// equivalent mistake here would be `[refundGraceWindows - pinOffsetWindows - 1]`
// (12 - 2 - 1 = 9), which would compile happily at any block time and any drand period.
//
// SO IT COMPARES SECONDS TO SECONDS, FROM TWO DIFFERENT CLOCKS:
//
//	LEFT  — the grace window in real seconds, via the CHAIN's ~3.3 s block time:
//	        refundGraceBlocks * 33/10 = 13080 * 3.3 = 43164 s = 11.99 hours
//	RIGHT — the bounded honest cycle in real seconds, via DRAND's period:
//	        pinOffsetRounds * beacon.PeriodSeconds = 2400 * 3 = 7200 s = 2 hours exactly
//	MARGIN = 35963 seconds = 9.99 hours, the relay allowance the derivation asks for —
//	        a 6x margin, and it NAMES the constants it depends on.
//
// MUTATION-TESTED, with the real failing build output recorded in DESIGN.md section 4:
// blocksPerDay = 26182 -> 2618 (a tenfold error in the chain-clock constant, the exact
// mutation finding 11 used) makes this length negative and the build fails, while the
// bare-integer form above compiles unchanged at that value.
var _ [refundGraceBlocks*33/10 - pinOffsetRounds*beacon.PeriodSeconds - 1]struct{}

// --- state ---------------------------------------------------------------

// Draw is one hourly window's draw: the pot, the ticket index that decides it, and
// the beacon round it is committed to.
//
// THERE IS NO Sponsored FIELD, AND ITS ABSENCE IS A DELIBERATE SIMPLIFICATION, NOT AN
// OVERSIGHT. The raffle needs one because house money in a prize pot belongs to no
// buyer, so its refund-safety property has to be stated as Pot == sum(spendOf) +
// Sponsored, and several separate mechanisms exist only to keep that term from being
// stranded (heldSponsored, retireSponsorship, the per-unit claim it writes, ClaimDeadWeek's
// whole entry point, and SweepDrawlessWeek). THE THREE THIS SENTENCE USED TO NAME WERE
// "Refund's move to opsPot, SweepDrawlessWeek's roll-forward, and heldSponsored", and the
// first two of those no longer exist: an abandoned week's sponsorship goes to NEITHER the
// house NOR a later week — it becomes a per-unit claim on the week it is already in, payable
// to the holders of that week's EARNED entries (AUDIT-2026-09-28.md findings 16, 28, 31 and
// 34). The count went UP, not down, which is the point this paragraph is making.
// HERE THE POT IS ENTRY MONEY ONLY, so the identity is simply
//
//	Pot + Cut == sum(spendOf)
//
// for every unresolved window, all three mechanisms are unnecessary, and the
// sole-entrant attack the sponsorship enables cannot exist. Read the package comment
// before adding one.
//
// THE Cut TERM IS NEW SINCE 2026-09-29 AND IT IS NOT SPONSORSHIP BY ANOTHER NAME. It is
// the house's own fee, held in escrow for the window rather than banked at sale time, so
// that a window which never draws returns the FULL ticket price. It belongs to specific
// buyers until a draw happens, which is exactly why it appears on the same side of the
// identity as the pot and not as a third party's money. AUDIT-2026-09-28.md finding 25.
type Draw struct {
	Window int64

	// Pot is the prize pot in ugnot: the sum of every entrant's contribution AFTER
	// the house cut, and NOTHING ELSE. Zeroed by Resolve when it pays the winner,
	// and decremented by Refund as each buyer reclaims their share.
	//
	// THE IDENTITY IS NOW Pot + Cut == sum(spendOf), and it is what makes Refund
	// unable to overdraw and what makes a sole entrant's prize exactly their own
	// post-fee stake back. It was Pot == sum(spendOf) until 2026-09-29, when spendOf
	// started recording the GROSS and the fee started being escrowed in Cut. Read Cut.
	Pot int64

	// Cut is THE HOUSE'S FEE FOR THIS WINDOW, HELD IN ESCROW AND NOT YET EARNED: the
	// sum of houseCutBps of every ticket sold into this window.
	//
	// IT IS NOT PART OF Pot AND THE WINNER MUST NEVER WIN IT. Resolve pays Pot to the
	// winner and moves Cut to opsPot, as two separate amounts.
	//
	// THE RULE IT IMPLEMENTS IS THE OWNER'S, AND IT IS THE SAME RULE THE WEEKLY REALM
	// NOW FOLLOWS: WE EARN WHEN THE GAME RUNS, NOT WHEN IT FAILS. Two destinations and
	// no third — a successful Resolve moves it to opsPot, and any other outcome refunds
	// it as part of each buyer's gross. AUDIT-2026-09-28.md finding 25.
	//
	// IT IS A TERM IN BOTH SOLVENCY STATEMENTS. The realm holds this wugnot, so
	// checkInvariant is heldPots + heldCuts + opsPot == balance and AuditFailure
	// re-derives both new terms by iteration.
	//
	// A SWEPT, TICKETLESS WINDOW HAS Cut == 0 BY CONSTRUCTION, because a fee can only
	// arrive with a ticket sale and SweepDrawlessWindow requires a zero ticket total.
	// That is asserted there rather than assumed.
	Cut int64

	Committed   bool
	FrozenTotal int64 // ticket units at commit. NEVER recomputed at resolve.

	// Round is the beacon round this window is drawn on. WRITTEN EXACTLY ONCE, by
	// getOrCreateDraw, at the moment this record is created — which is before the
	// window's first ticket exists — and never written again by anything, Commit
	// included. Read pinOffsetRounds for why.
	Round int64

	// CommittedAt is the CHAIN HEIGHT at which Commit froze this window, and it is
	// the only clock the refund grace window reads. Zero on an uncommitted window.
	//
	// IT IS STORED AND CANNOT BE DERIVED. The window number comes from the same
	// global clock, but a window may be committed at any time after it ends (Commit
	// takes the window as an argument precisely so a stranded window is always
	// recoverable), so "when was this committed" is not a function of which window
	// it is. Round cannot stand in for it either: Round is beacon state, and the
	// whole point of this field is to give Refund a gate the beacon cannot hold shut.
	CommittedAt int64

	// Randomness is the round's randomness, copied in by Capture. Empty means "not
	// captured"; Resolve then reads the beacon directly. A CONVENIENCE, NOT A
	// RESCUE: the beacon cannot lose a round, so nothing is preserved by copying it
	// here. See Capture.
	Randomness string

	Resolved bool
	Winner   address

	// Abandoned is set by the FIRST successful Refund for this window and is never
	// cleared by anything. It makes the window's exit ONE-WAY: once one buyer has
	// taken their money back, this window can never be resolved, and every later
	// refund proceeds without re-asking whether the draw looks resolvable again.
	//
	// IT CARRIES THE WHOLE MUTUAL-EXCLUSION BURDEN, and it has to, because a pinned
	// round can be relayed by ANYONE, from drand, AT ANY TIME, FOR EVER — so a
	// window in refund would otherwise stay resolvable indefinitely. Without this
	// flag, anyone could let refunds open, wait for some buyers to reclaim, then
	// relay the round and Resolve — drawing over the ORIGINAL frozen range, so a
	// buyer who had already been refunded could win and collect what was left in the
	// pot: the money of the buyers who had not reclaimed yet. Someone who had
	// already fetched the signature did strictly better still, computing the winner
	// first and then choosing Refund if it was not them and relay-and-Resolve if it
	// was. Pot == sum(spendOf) held throughout, so neither checkInvariant nor
	// AuditFailure saw anything — the identity is sound, it is just blind to WHO is
	// paid. That is AUDIT-2026-09-28.md finding 3, verbatim.
	Abandoned bool

	// tickets is the weighted ticket index for this window. ONE INDEX PER PURCHASE
	// is appended and no existing index's value is ever changed — that immutability
	// is the whole frozen-ownership argument on Commit.
	tickets *fenwick.Tree

	// ownerOf is index -> string(address), the reverse lookup that turns a drawn
	// unit back into a winner. MANY INDICES MAP TO THE SAME ADDRESS and that is
	// expected: one entry per purchase.
	ownerOf *avl.Tree

	// ticketsOf is string(address) -> int64 ticket units, a read-side running total
	// so TicketsOf is O(log N) and never has to walk the index. It is NOT read by
	// the draw: Select and ownerOf decide the winner.
	ticketsOf *avl.Tree

	// spendOf is string(address) -> int64, the buyer's GROSS payment for this window's
	// tickets — the whole ticket price, house fee included — which is exactly what
	// Refund returns.
	//
	// IT WAS THE POST-CUT CONTRIBUTION UNTIL 2026-09-29 and the old comment said "the
	// house cut is not in here and is never refunded". BOTH HALVES OF THAT ARE NOW
	// FALSE, and the sentence is corrected rather than removed because it is the one a
	// reader will have in their head. AUDIT-2026-09-28.md finding 25.
	spendOf *avl.Tree
}

var (
	// draws is window -> *Draw. AN avl.Tree, NEVER A MAP: Render iterates it, and a
	// Go map's iteration order is deliberately randomised, which would make this
	// realm's rendered output non-deterministic and its audit unreproducible.
	draws = avl.NewTree()

	// opsPot is the house's money this realm holds, so it is a term in
	// checkInvariant. TWO STREAMS FLOW IN — the 5% cut on every ticket (Buy) and any
	// unsolicited wugnot arrival (sweepDonations) — plus one that should be
	// unreachable (SweepDrawlessWindow; see there). ONE FUNCTION FLOWS OUT:
	// WithdrawOps. That there is an outflow at all is AUDIT-2026-09-28.md finding 6,
	// which the raffle shipped without and which burned the product's entire revenue.
	opsPot int64

	// heldPots is the sum of Pot over every draw, maintained incrementally so
	// checkInvariant is O(1). Resolve zeroes a window's Pot, so a resolved window
	// contributes nothing and this is exactly "the sum of all unresolved window
	// pots". AuditFailure re-derives it by iteration so it cannot drift.
	heldPots int64

	// heldCuts is the sum of Cut over every draw — every window's ESCROWED, NOT YET
	// EARNED house fee — maintained incrementally for the same reason heldPots is, and
	// re-derived by AuditFailure the same way.
	//
	// IT IS A THIRD TERM IN THE SOLVENCY EQUALITY AND ADDING IT IS WHAT MAKES THE ESCROW
	// SAFE. The fee is wugnot this realm holds, so before 2026-09-29 it was counted by
	// being inside opsPot. A balance term the invariant does not mention is how money goes
	// missing quietly. It rises only in Buy and falls in exactly two places: Resolve (the
	// fee is earned and moves to opsPot, so the balance does not move) and Refund (the fee
	// goes back to the buyer with their gross, so the balance falls with it).
	heldCuts int64

	// launchHeight is the chain height at deploy, so window numbers start at 0 for
	// this realm rather than at some arbitrary point in chain history.
	launchHeight int64
)

func init() {
	launchHeight = runtime.ChainHeight()
}

// realmSelf is this realm's own address, resolved ONCE at package initialisation and
// never recomputed.
//
// WHY NOT unsafe.CurrentRealm() PER USE: CurrentRealm resolves against whatever frame
// is executing. Inside a crossing entrypoint that is this realm, which is correct —
// but Render and the audit reads are deliberately NOT crossing functions (anyone must
// be able to read them), so when they are called directly the "current realm" is the
// CALLER and BalanceOf(selfAddr()) would silently read the caller's wallet.
// r/splash/game learned this the hard way; the fix is to resolve the address once,
// since it is constant for the life of the realm.
var realmSelf = unsafe.CurrentRealm().Address()

func selfAddr() address {
	return realmSelf
}

// --- keys ----------------------------------------------------------------

// keyWidth is enough decimal digits for any non-negative int64 (max is
// 9223372036854775807, 19 digits). Keys are fixed-width and zero-padded so that
// avl.Tree's lexicographic order matches numeric order — the same convention as
// r/splash/beacon's roundKey, and the reason Render lists windows as 1, 2, ... 10
// rather than 1, 10, 2.
const keyWidth = 19

const zeroPad = "0000000000000000000"

func pad(s string) string {
	if len(s) < keyWidth {
		return zeroPad[:keyWidth-len(s)] + s
	}
	return s
}

func windowKey(window int64) string { return pad(strconv.FormatInt(window, 10)) }

func indexKey(i int) string { return pad(strconv.Itoa(i)) }

// --- clock ---------------------------------------------------------------

// currentWindow is the window tickets are being sold into right now: the single
// global clock this realm reads, never a per-ticket one. See windowBlocks.
func currentWindow() int64 {
	h := runtime.ChainHeight() - launchHeight
	if h < 0 {
		h = 0
	}
	return h / windowBlocks
}

// windowEndHeight is the chain height at which a window stops being the live one — the
// FIRST height of window+1. Derived from the same constant and the same launchHeight
// currentWindow reads, so the two clocks can never disagree: for every height h >=
// launchHeight, currentWindow() == w exactly while h is in [windowEndHeight(w-1),
// windowEndHeight(w)).
//
// IT GATES NOTHING, and that is the difference between this and the raffle's
// weekEndHeight, which exists for SweepDrawlessWeek's ticketless clock. This realm's
// sweep compares window indices (`window >= currentWindow()`) and its refund clock
// counts from CommittedAt, so NO MONEY PATH IN THIS FILE READS THIS FUNCTION. It is here
// only so WindowEndHeight has one place to compute the boundary, in the clock section
// where the rest of the clock lives rather than in the read surface.
//
// NO OVERFLOW for any window this realm has a record for: such a window is bounded by
// the chain's own height divided by windowBlocks.
func windowEndHeight(window int64) int64 {
	return launchHeight + (window+1)*windowBlocks
}

// --- arithmetic ----------------------------------------------------------

// mulDiv returns floor(a*b/d) via a 128-bit intermediate product. Raw a*b/d on
// token-scale quantities wraps silently on the GnoVM (see
// ../../../../tools/muldiv_probe.gno) instead of panicking, so every split in this
// realm goes through here.
func mulDiv(a, b, d uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	if d == 0 {
		panic("speed: mulDiv: division by zero")
	}
	if hi >= d {
		panic("speed: mulDiv: overflow")
	}
	q, _ := bits.Div64(hi, lo, d)
	return q
}

// maxInt64 as a uint64, for the overflow guards below.
const maxInt64 = uint64(1)<<63 - 1

// ticketCost is tickets * TicketPrice, GUARDED AGAINST int64 OVERFLOW.
//
// A raw multiplication here is the classic money bug: on the GnoVM an int64 product
// wraps silently, so a caller passing a large enough ticket count would buy an
// enormous number of ticket units for a small — or negative — cost. The product is
// therefore taken in 128 bits and REJECTED unless it fits in an int64: the high word
// must be zero AND the low word must be within int64 range, because hi == 0 alone
// still admits values above 2^63-1 that would land negative.
func ticketCost(tickets int64) int64 {
	if tickets <= 0 {
		panic("speed: ticket count must be positive")
	}
	hi, lo := bits.Mul64(uint64(tickets), uint64(TicketPrice))
	if hi != 0 || lo > maxInt64 {
		panic("speed: ticket count overflows int64 ugnot")
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

// randomnessMod reduces a 256-bit hex randomness string modulo m, which gives the
// draw's winning ticket unit. Verbatim in behaviour from r/splash/arcade/raffle, for
// the reasons stated there:
//
// The randomness is 256 bits; an int64 holds 63. Any truncation (taking the first or
// last 16 hex digits, say) throws away most of the beacon's entropy and does it in a
// way an attacker can reason about. math/big does not exist on this toolchain, so the
// reduction is schoolbook: fold four bits at a time, reducing as we go. The
// intermediate r*16 + digit does NOT fit in 64 bits when m is near the int64 maximum,
// so it goes through the 128-bit path rather than wrapping. `hi %= um` before the
// divide is required by bits.Div64 (which panics unless the high word is smaller than
// the divisor) and is sound because hi*2^64 == (hi mod m)*2^64 (mod m).
func randomnessMod(randomness string, m int64) int64 {
	if m <= 0 {
		panic("speed: randomness modulus must be positive")
	}
	if len(randomness) == 0 {
		panic("speed: empty randomness")
	}
	um := uint64(m)
	r := uint64(0)
	for i := 0; i < len(randomness); i++ {
		d, ok := hexDigit(randomness[i])
		if !ok {
			panic("speed: beacon randomness is not hex")
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

// --- window records ------------------------------------------------------

// getDraw returns the draw for window, or nil. avl's Get returns a SINGLE value and
// existence is a separate Has, so the check comes first — otherwise a missing window
// type-asserts nil and panics with avl's message rather than this realm's.
func getDraw(window int64) *Draw {
	key := windowKey(window)
	if !draws.Has(key) {
		return nil
	}
	return draws.Get(key).(*Draw)
}

// getOrCreateDraw returns the window's draw, creating an empty one if needed. Called
// only AFTER a sale's money has moved, so a rejected Buy never leaves an empty record
// behind.
//
// THIS IS WHERE THE WINDOW'S BEACON ROUND IS PINNED, AND IT IS THE ONLY WRITER OF
// Draw.Round IN THIS FILE. Read pinOffsetRounds for the attack this closes and for
// the derivation of the offset. Buy is its only caller in v1; it is factored out
// anyway, because the raffle's history is that a SECOND caller appeared (FundPot) and
// the pin had to happen exactly once per window whichever of them got there first. A
// second pin would be a second choice, and choice is the whole defect.
//
// THE ANCHOR IS beacon.EstimatedLatestRoundWithin(speedMaxStaleBlocks), AND EVERY WORD
// OF THAT IS LOAD-BEARING:
//
//   - NOT beacon.Latest(). That is whatever round somebody last had a reason to relay,
//     which under an on-demand record is arbitrarily stale; pinning against a stale
//     anchor measures the offset FROM THE PAST, so the pinned round lands earlier in
//     real time than intended and its randomness can be public before entries close.
//     With a one-hour window and a two-hour offset, 3600 seconds of staleness — about
//     1090 blocks — is enough to destroy the property completely. That is
//     AUDIT-2026-09-28.md finding 10's last-buyer attack and no guard in this file can
//     see it, because nothing here distinguishes a fresh anchor from a stale one.
//   - NOT the default EstimatedLatestRound() either, which tolerates a whole day of
//     staleness — an admitted error of 2.4 hours against this realm's one-hour pin
//     margin. See speedMaxStaleBlocks for the derivation of the tighter tolerance.
//
// IT THEREFORE NEEDS A BEACON THAT HAS PUBLISHED AT LEAST ONCE AND HAS BEEN RELAYED
// RECENTLY, and if either is untrue THE SALE IS REFUSED with the beacon's own message.
// That is the safe direction and is strictly better than what it replaces: before the
// pin existed, such a Buy succeeded and the window could then never be committed,
// never resolved and never refunded, so the money entered a window no path in the
// realm could ever empty. A refused sale leaves the money in the buyer's wallet. The
// refusal happens after the wugnot pull inside Buy, which is harmless — a panic
// reverts the whole transaction, exactly as checkInvariant's panics already rely on.
//
// AND THE REFUSAL COSTS NOTHING CROSS-REALM, WHICH IS WHY IT COULD BE ADOPTED AT THE
// TIGHTER TOLERANCE. Nothing outside this realm calls into it (see the package
// comment: there is no FundPot and no rake feed), so a refusal here reverts one
// buyer's transaction and affects nobody else. The raffle could not say that until
// AUDIT-2026-09-28.md finding 14 severed duel.Collect's dependency on its bookkeeping,
// and the cross-realm coupling is exactly why bounding the extrapolation looked like a
// liveness cost there for as long as it did.
func getOrCreateDraw(window int64) *Draw {
	if d := getDraw(window); d != nil {
		return d
	}
	anchor := beacon.EstimatedLatestRoundWithin(speedMaxStaleBlocks)
	if anchor > maxPinnableLatest {
		// Loud rather than pinning a wrapped, negative round nobody could ever
		// publish. drand cannot sign a round anywhere near the int64 maximum so this
		// is unreachable in practice; see maxPinnableLatest.
		panic("speed: the beacon's estimated round is too high to pin a future round against")
	}
	d := &Draw{
		Window: window,
		// THE PIN. Never recomputed, never rebound — not by a later Buy and above all
		// not by Commit.
		Round:     anchor + pinOffsetRounds,
		tickets:   fenwick.NewTree(),
		ownerOf:   avl.NewTree(),
		ticketsOf: avl.NewTree(),
		spendOf:   avl.NewTree(),
	}
	draws.Set(windowKey(window), d)

	// EMITTED SO THE PIN IS AUDITABLE FROM THE BLOCK LOG ALONE. The whole security
	// argument is "this number was fixed before the ticket set existed", and that is a
	// statement about WHEN it was written — which no later read of the realm's state
	// can establish on its own. The height and the anchor are included for the same
	// reason: together they let a reader recompute the pin and check the staleness.
	chain.Emit("PinRound",
		"window", strconv.FormatInt(window, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"beaconAnchor", strconv.FormatInt(anchor, 10),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10))
	return d
}

func treeInt64(t *avl.Tree, key string) int64 {
	if !t.Has(key) {
		return 0
	}
	return t.Get(key).(int64)
}

// appendTickets records a purchase of units by addr by APPENDING A NEW INDEX to this
// window's ticket index. It never touches an existing index, and that is the whole
// point — see Commit's frozen-ownership argument.
func appendTickets(d *Draw, addr address, units int64) {
	if units <= 0 {
		// fenwick.Append would reject a negative itself; failing here names the
		// caller that got it wrong, and a zero-unit purchase would create an index
		// that owns nothing.
		panic("speed: ticket units must be positive")
	}
	i := d.tickets.Append(units)
	d.ownerOf.Set(indexKey(i), string(addr))
	k := string(addr)
	d.ticketsOf.Set(k, treeInt64(d.ticketsOf, k)+units)
}

// ownerOfUnit is the draw rule's second half: who owns cumulative ticket unit k in
// this window's index. Factored out so the boundary tests can exercise the mapping
// over every interesting k without needing a signed beacon round for each one.
func ownerOfUnit(d *Draw, k int64) address {
	if d.tickets == nil || k < 0 || k >= d.tickets.Total() {
		panic("speed: ticket unit out of range")
	}
	key := indexKey(d.tickets.Select(k))
	if !d.ownerOf.Has(key) {
		// Unreachable while appendTickets is the only writer: it sets the reverse
		// entry in the same statement group as the Append. Loud rather than returning
		// a zero address that would look like a winner.
		panic("speed: ticket index has no owner")
	}
	return address(d.ownerOf.Get(key).(string))
}

// --- native coin -----------------------------------------------------------

// rejectAttachedCoin panics if the caller attached native coin to a call that
// has no use for it. Every money-in path in this realm is the wugnot GRC20
// allowance (see Buy), never the transaction's send envelope, so any attached
// ugnot would simply sit in this realm forever with no code path that ever
// looks at it — AUDIT-2026-10-07.md Y1. Call this as the first statement of
// every crossing entrypoint so the transaction reverts and the sender keeps
// their coin instead.
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
// COME DIRECTLY FROM A USER, THIS FUNCTION DOES NOT LOOK AT THE ENVELOPE AT
// ALL: it cannot be attributed to this call either way, so there is nothing
// sound to enforce, and guessing would be worse than staying silent.
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
		panic("speed: " + what + " does not take native coin — pay through the wugnot allowance instead")
	}
}

// --- solvency ------------------------------------------------------------

// sweepDonations accounts for any wugnot that has arrived without going through Buy.
//
// IT HAS TO EXIST. wugnot.Transfer is permissionless: any address may push wugnot at
// this realm with no memo, no callback and no way for this realm to learn who sent it
// or why. Without a sweep, one unsolicited transfer would fail checkInvariant for
// every later caller and BRICK THE REALM.
//
// IT GOES TO opsPot, NOT TO THE CURRENT WINDOW'S POT. Here Pot == sum(spendOf) is a
// load-bearing identity — it is what makes Refund unable to pay out more than was put
// in, and what makes a sole entrant win exactly their own stake back — and a donation
// credited to a pot would break it, silently converting somebody's gift into
// refundable balance nobody has a claim on. The ops pot has no such identity to
// violate.
//
// IT EMITS A Donation EVENT FOR EVERY NON-ZERO ABSORPTION, and that is not
// bookkeeping decoration: nothing else in this realm distinguishes a swept arrival
// from the house cut, since both land in opsPot and opsPot is a single number.
//
// WHAT THE INVARIANT'S EQUALITY IS ACTUALLY WORTH, recorded here so the next reader
// does not overtrust it (AUDIT-2026-09-28.md finding 9). Suppose heldPots OVERCOUNTS
// by D because of a bug in this file — the realm believes it owes D more than it holds
// — and donations totalling X > D have arrived. This function computes
// extra = bal - (heldPots + opsPot) = X - D, absorbs it, and afterwards
// heldPots + opsPot == bal EXACTLY. checkInvariant then passes and so does
// AuditFailure's one-sided balance test. THE DEFICIT HAS NOT BEEN DETECTED, IT HAS
// BEEN PAID FOR OUT OF A STRANGER'S MONEY. The equality therefore says "the books add
// up after absorbing whatever arrived", not "the books were already right". This event
// is what makes the absorption visible so the case can be noticed off-chain — a
// Donation for an amount no donor sent is the signature of exactly that state. Fixing
// it properly needs a separate counter for absorbed donations so the invariant can
// state the pre-donation equality, which changes what checkInvariant MEANS in a realm
// where every mutator asserts it; it is a separately-audited change, here as there.
func sweepDonations() {
	if extra := absorbDonation(); extra > 0 {
		// EMITTED AFTER THE CREDIT, so the reported opsPot is the post-sweep figure a
		// reader can reconcile against OpsPot(). NOTHING IS EMITTED WHEN NOTHING WAS
		// ABSORBED: an empty sweep runs at the top of every mutator in this file, and
		// an event on each would bury the one that means something.
		chain.Emit("Donation",
			"amount", strconv.FormatInt(extra, 10),
			"opsPot", strconv.FormatInt(opsPot, 10))
	}
}

// absorbDonation is sweepDonations without the event: it credits opsPot with any
// unattributed arrival and RETURNS THE AMOUNT IT ABSORBED, zero if there was nothing.
//
// IT IS SPLIT OUT FOR A TESTABILITY REASON, STATED PLAINLY: this toolchain gives a Gno
// test no way to read emitted events, so the only assertable statements about the
// Donation event are the value it would carry and whether it fires at all. Both are
// exactly this return value, and speed_test.gno asserts it on both sides. Do not
// inline it back without putting the event under test some other way.
func absorbDonation() int64 {
	bal := wugnot.BalanceOf(selfAddr())
	// heldCuts IS IN HERE BECAUSE IT IS WUGNOT THIS REALM HOLDS. Omitting it would make
	// every window's escrowed fee look like an unattributed arrival, and the first sweep
	// after any sale would move the whole of it into opsPot — banking the fee at sale time
	// by accident, and leaving every refund unable to return a gross the realm no longer
	// holds. Finding 25.
	extra := bal - (heldPots + heldCuts + opsPot)
	if extra <= 0 {
		return 0
	}
	opsPot += extra
	return extra
}

// checkInvariant is this realm's solvency statement: the wugnot it holds is exactly
// the sum of every unresolved window's pot plus the ops pot, and nothing else. O(1),
// using the incrementally-maintained heldPots; AuditFailure re-derives the same thing
// by iteration.
//
// CALLED AT THE END OF EVERY STATE-CHANGING FUNCTION. An equality, not a ">=":
// sweepDonations runs first in each of them, so unattributed arrivals are already
// accounted for and any remaining gap is a bug in this file.
//
// THERE IS NO SPONSORSHIP TERM HERE and there is nothing missing: the per-window
// identity is Pot + Cut == sum(spendOf) with no house money in it, and AuditFailure
// re-derives it ONE WINDOW AT A TIME (finding 27 — it used to do it summed over the
// unresolved windows, which two windows with compensating errors passed through
// silently). See Draw.
func checkInvariant() {
	bal := wugnot.BalanceOf(selfAddr())
	// THREE TERMS SINCE 2026-09-29, NOT TWO. The house fee is escrowed per window in
	// Draw.Cut rather than banked into opsPot at sale time (finding 25), so the wugnot this
	// realm holds is the unresolved prize pots, PLUS the unearned fees held against those
	// windows, PLUS the ops pot. Read heldCuts.
	if heldPots+heldCuts+opsPot != bal {
		panic("speed: GNOT invariant violated")
	}
	if heldPots < 0 {
		// Would mean a pot was paid out twice.
		panic("speed: heldPots negative")
	}
	if heldCuts < 0 {
		// Would mean a window's escrowed fee was released twice — a Resolve and a Refund
		// both taking it, or a refund re-deriving more fee than the buyer ever paid. The
		// cutPerTicket build guard is what makes the second impossible.
		panic("speed: heldCuts negative")
	}
	if opsPot < 0 {
		panic("speed: opsPot negative")
	}
}

// AuditFailure re-derives the invariant BY ITERATION and reports the empty string when
// the books balance, otherwise which check failed and by how much. Never called from a
// state-changing path — checkInvariant is the O(1) guard for that — and exists so
// anyone can verify off-chain, and so a test can assert it after every operation.
//
// IT MUST BE ROBUST AGAINST ANYONE WHO CAN SEND THIS REALM TOKENS, which is everyone:
// wugnot.Transfer needs no permission. So the balance test below is ONE-SIDED — a
// shortfall is a violation, an unswept surplus is not. See the comment on that check.
func AuditFailure() string {
	i64 := strconv.FormatInt

	// ONE PASS THAT COLLECTS, THEN A LOOP THAT SUMS — never an Iterate inside an
	// Iterate. Nesting a second avl traversal inside the first one's callback crashes
	// this toolchain's VM outright (a Go-level nil dereference, not a gno panic), so
	// the two levels are kept strictly apart. A slice is fine here because it is local
	// scratch and never realm state.
	all := []*Draw{}
	sumPots := int64(0)
	sumCuts := int64(0)
	unresolvedPots := int64(0)
	unresolvedCuts := int64(0)
	draws.Iterate("", "", func(_ string, value any) bool {
		d := value.(*Draw)
		all = append(all, d)
		sumPots += d.Pot
		sumCuts += d.Cut
		if !d.Resolved {
			unresolvedPots += d.Pot
			unresolvedCuts += d.Cut
		}
		return false
	})

	// THE SECOND PASS, AND IT IS NOW PER WINDOW — AUDIT-2026-09-28.md finding 27. It sums
	// each window's spendOf on its own and tests THAT WINDOW'S identity immediately, instead
	// of accumulating one grand total and testing it once at the end. The cost is one
	// comparison per unresolved window; the loop, the slice and the single level of
	// iteration are all exactly as they were.
	//
	// WHY THE AGGREGATE FORM WAS NOT GOOD ENOUGH. Summed over the windows, two windows with
	// EQUAL AND OPPOSITE errors (+X here, -X there) cancel and the check passes with both
	// windows wrong. This realm has no path that moves money between windows at all — which
	// is why the defect was found in the raffle and not here — so the per-window form is a
	// strengthening against a class of bug rather than a fix for a live one; it costs one
	// comparison and it is the shape the comment always claimed.
	//
	// THE FAILURE IS RECORDED AND REPORTED LOWER DOWN rather than returned from here, so that
	// the ORDER in which this function reports problems does not change.
	sumSpends := int64(0)
	perWindow := ""
	for _, d := range all {
		if d.Resolved {
			continue
		}
		windowSpends := int64(0)
		d.spendOf.Iterate("", "", func(_ string, v any) bool {
			windowSpends += v.(int64)
			return false
		})
		sumSpends += windowSpends
		if perWindow == "" && windowSpends != d.Pot+d.Cut {
			perWindow = "window " + i64(d.Window, 10) + ": pot " + i64(d.Pot, 10) +
				" and escrowed fee " + i64(d.Cut, 10) +
				" but buyers' gross claims total " + i64(windowSpends, 10)
		}
	}

	if sumPots != heldPots {
		return "heldPots is " + i64(heldPots, 10) + ", iterating the draws gives " + i64(sumPots, 10)
	}
	// THE ESCROWED FEES, RE-DERIVED THE SAME WAY AND FOR THE SAME REASON (finding 25).
	// Resolve zeroes a window's Cut when it releases it, so a resolved window contributes
	// nothing and the sum over ALL draws is the same number as the sum over the unresolved
	// ones — asserted below rather than assumed, because the two would part company if
	// anything ever released a fee without zeroing the field.
	if sumCuts != heldCuts {
		return "heldCuts is " + i64(heldCuts, 10) + ", iterating the draws gives " + i64(sumCuts, 10)
	}
	if unresolvedCuts != sumCuts {
		return "escrowed fees total " + i64(sumCuts, 10) +
			" but only " + i64(unresolvedCuts, 10) + " of it is on an unresolved window" +
			" — a resolved window is holding a fee it should have released"
	}
	// ONLY A DEFICIT IS A VIOLATION HERE — a surplus is not, and that asymmetry is
	// deliberate (AUDIT-2026-09-28.md finding 9). This function is a READ: it cannot
	// sweep, so any wugnot that has arrived without going through Buy is still
	// unattributed when it runs. wugnot.Transfer is permissionless, so with an
	// equality here a stranger could make AuditInvariant() false and AuditFailure()
	// shout by sending this realm ONE ugnot — free, repeatable, attacker-controlled
	// alert fatigue on the one solvency signal an operator would page on, with nothing
	// actually wrong and nobody harmed. An unswept donation is a benign, expected
	// state: the next state-changing call sweeps it into the ops pot.
	//
	// A DEFICIT IS THE CASE THAT CAN HURT SOMEBODY: it means this realm has promised
	// more than it holds, so some pot cannot be paid. That is reported, always.
	//
	// checkInvariant, in the mutators, KEEPS ITS EQUALITY and is untouched by this: it
	// runs after sweepDonations, so a surplus there really would be a bug.
	// STILL ONE-SIDED, AND THE ESCROWED FEES JOIN THE SIDE THEY BELONG ON: heldCuts is
	// money the realm holds for somebody — the house if the window draws, the buyers if it
	// does not — so it counts towards what the realm must be able to pay, exactly like a
	// pot. A DEFICIT IS STILL THE ONLY VIOLATION.
	bal := wugnot.BalanceOf(selfAddr())
	if bal < sumPots+sumCuts+opsPot {
		return "pots + escrowed fees + ops is " + i64(sumPots+sumCuts+opsPot, 10) +
			", but the wugnot balance is only " + i64(bal, 10) +
			" — the realm is short by " + i64(sumPots+sumCuts+opsPot-bal, 10)
	}
	// EVERY UNRESOLVED WINDOW'S POT PLUS ITS ESCROWED FEE MUST BE EXACTLY ITS BUYERS'
	// GROSS CLAIMS, or Refund could pay out more or less than was put in. AN EQUALITY, NOT
	// A TOLERANCE: there is no sponsorship term here and no ugnot in any pot that belongs
	// to nobody, so a discrepancy of ANY size is a bug and is reported. A resolved window
	// is excluded: its pot is gone to the winner, its fee to the house, and its spend
	// records are dead.
	//
	// THE FEE TERM IS ON THE LEFT BECAUSE spendOf IS NOW THE GROSS (finding 25): that gross
	// was split at sale time into the prize part and the escrowed fee part, so both must be
	// on the pot side or the equation is short by every fee ever taken. IT IS THIS
	// IDENTITY, NOT AN INEQUALITY, THAT MAKES Refund PROVABLY UNABLE TO OVERDRAW.
	//
	// AND IT IS TESTED ONE WINDOW AT A TIME SINCE 2026-09-29 (finding 27). The loop above did
	// the work; this is where its verdict is reported, in the position the old aggregate test
	// occupied.
	if perWindow != "" {
		return perWindow
	}
	// THE AGGREGATE FORM, KEPT AS A SECOND LOCK AND NO LONGER ABLE TO FIRE ON ITS OWN. It is
	// IMPLIED by the per-window loop — a sum of equalities is an equality — so what it still
	// guards is the ACCUMULATION: that the same numbers the per-window test read add up to the
	// aggregates the O(1) invariant is written in. Deliberately not deleted, because if a
	// future edit ever narrows the per-window loop this line is what still notices.
	if sumSpends != unresolvedPots+unresolvedCuts {
		return "unresolved pots total " + i64(unresolvedPots, 10) +
			" and escrowed fees " + i64(unresolvedCuts, 10) +
			" but buyers' gross claims total " + i64(sumSpends, 10)
	}
	return ""
}

// AuditInvariant is AuditFailure reduced to a bool.
func AuditInvariant() bool { return AuditFailure() == "" }

// --- Buy -----------------------------------------------------------------

// Buy sells `tickets` tickets in the CURRENT window to the caller.
//
// Cost is tickets * TicketPrice, pulled from the caller with the GRC20 allowance path,
// so the caller wraps native ugnot with wugnot.Deposit and approves this realm first.
// houseCutBps of the cost goes to the ops pot; the remainder — and all
// integer-division dust, since the cut is floored — joins this window's prize pot and
// is recorded in the caller's spend for the window.
//
// EVERY CHECK RUNS BEFORE THE PULL, and the window record is created only after it, so
// a failed Buy moves nothing and creates nothing.
//
// Each purchase APPENDS ITS OWN ticket index rather than growing an existing one. That
// is not a style choice: it is the property Commit depends on, and the reason is
// spelled out there.
//
// THE WINDOW'S FIRST BUY PINS THE WINDOW'S BEACON ROUND, as a side effect of creating
// the record (getOrCreateDraw). That is deliberate and is the only moment the round is
// ever chosen. Two consequences a caller can see. First, a sale needs a beacon that has
// published at least once AND been relayed within speedMaxStaleBlocks, or it is refused
// with the beacon's own message — a refused sale rather than money accepted into a
// window that could never be drawn fairly. Second, the buyer who opens a window does
// not get to pick anything useful: the round is fixed two hours ahead of the moment the
// ticket set closes, so at the instant it is pinned there is no ticket set for it to be
// advantageous against.
//
// Panics if tickets is not positive, if the cost overflows int64, if the allowance is
// short, or if THIS WINDOW IS ALREADY COMMITTED — the last of which is the
// frozen-total rule, not a convenience check. Once a window's total is frozen, no
// further ticket may join it.
//
// THAT LAST REFUSAL IS UNREACHABLE THROUGH THE ENTRY POINTS, and is kept deliberately.
// Commit only accepts a window that is already over, and Buy only ever sells into
// currentWindow(), so the live window cannot be in a committed state — which is
// exactly why a commit can no longer shut a window's sales down early
// (AUDIT-2026-09-28.md finding 2). The check stays as a second lock on the
// frozen-total rule: if the window's identity ever stops being "the one the clock is
// on", this is the line that still refuses to grow a frozen ticket set.
//
// ONLY A USER MAY BUY, AND THE REASON IS THE PAYOUT, NOT THE PURCHASE
// (AUDIT-2026-09-28.md finding 8). A ticket is a claim on two transfers this realm
// will later push OUT: Resolve's whole pot to the winner's address, and Refund's spend
// back to the buyer's. Both go to cur.Previous().Address(), which for a realm caller
// is that realm's PACKAGE-DERIVED address — an address whose only "key" is its package
// path, so nothing can move wugnot out of it unless that realm happens to contain code
// that does. A realm with no such code that won a draw would have the entire window's
// pot transferred into an address it can never spend from: money that has left this
// realm's books (heldPots drops, the invariant stays green) and is unreachable by
// anybody, for ever. This realm cannot tell which realms those are and must not try,
// so it refuses them all at the door instead of stranding a pot at settlement time.
//
// cur.Previous().IsUserCall() IS THE CHECK — AND IsUser() IS NOT. IsUser() also
// accepts a `maketx run` ephemeral realm, which is code executing under a user's
// signature and NOT an EOA: its address is still package-derived, so it can win a pot
// and then cease to exist with the money in it. r/splash/exchange states the same
// distinction about the same word for a different failure mode (a shared send
// envelope); the property being asked for — "the thing in front of me is a wallet
// somebody holds a private key for" — is identical.
//
// THERE IS NO SECOND, UNGUARDED ENTRY POINT HERE, and that is a difference from the
// raffle worth naming: the raffle must leave FundPot realm-callable for the duel's
// rake, so its asymmetry has to be documented at both ends to stop someone "making it
// consistent". THIS REALM HAS NO FundPot (see the package comment), so THE GUARD ABOVE
// IS THE ONLY DOOR MONEY COMES IN BY, and every ugnot in a pot is therefore
// attributable to a user address that can receive it back.
func Buy(cur realm, tickets int64) {
	rejectAttachedCoin(cur, "Buy")
	sweepDonations()

	if !cur.Previous().IsUserCall() {
		panic("speed: Buy must be called directly by a user")
	}

	if tickets <= 0 {
		panic("speed: ticket count must be positive")
	}
	cost := ticketCost(tickets)

	window := currentWindow()
	if d := getDraw(window); d != nil && d.Committed {
		panic("speed: this window is already committed — tickets for it are closed")
	}

	caller := cur.Previous().Address()
	if wugnot.Allowance(caller, selfAddr()) < cost {
		panic("speed: insufficient allowance — approve this realm for the ticket cost first")
	}

	wugnot.TransferFrom(cross(cur), caller, selfAddr(), cost)

	cut := int64(mulDiv(uint64(cost), uint64(houseCutBps), uint64(bpsDenom)))
	net := cost - cut

	d := getOrCreateDraw(window)
	// THE FEE IS ESCROWED IN THE WINDOW, NOT BANKED — AUDIT-2026-09-28.md finding 25. This
	// line was `opsPot += cut` until 2026-09-29, which meant the house had been paid the
	// moment a ticket was sold and a window that never drew refunded only 95%. The owner's
	// rule is that WE EARN WHEN THE GAME RUNS, NOT WHEN IT FAILS, so the fee now sits in
	// d.Cut — inside this window, outside the prize — and reaches opsPot only when Resolve
	// names a winner. If instead the window is abandoned and refunded, d.Cut goes back to
	// the buyers it came from, because spendOf below records the GROSS.
	//
	// d.Cut IS NOT IN d.Pot AND MUST NEVER BE: the winner must not win our fee, and both
	// identities name the two as separate terms.
	d.Cut += cut
	heldCuts += cut
	d.Pot += net
	heldPots += net
	// ONE TICKET IS ONE UNIT OF WEIGHT HERE, deliberately, and this line is where that is
	// true. Do not "make it consistent" with r/splash/arcade/raffle, which multiplies by a
	// units-per-ticket factor: read TicketPrice's comment for why this realm has no entry
	// unit and must not acquire one.
	appendTickets(d, caller, tickets)
	k := string(caller)
	// THE GROSS, NOT THE NET. This is what Refund returns, and it is the buyer's whole
	// payment: the fee is only ours once the draw happens. The per-window identity is
	// preserved exactly — the gross recorded here equals the net that went to d.Pot plus
	// the fee that went to d.Cut, by construction, on this line and the ones above it.
	d.spendOf.Set(k, treeInt64(d.spendOf, k)+cost)

	chain.Emit("Buy",
		"window", strconv.FormatInt(window, 10),
		"buyer", string(caller),
		"tickets", strconv.FormatInt(tickets, 10),
		"cost", strconv.FormatInt(cost, 10),
		"cut", strconv.FormatInt(cut, 10),
		"escrowedCut", strconv.FormatInt(d.Cut, 10),
		"pot", strconv.FormatInt(d.Pot, 10))
	checkInvariant()
}

// --- Commit --------------------------------------------------------------

// Commit commits an ALREADY-FINISHED window to its pinned beacon round. Returns that
// round.
//
// THE WINDOW IS A PARAMETER AND IT MUST BE OVER — window < currentWindow(). Both
// halves are load-bearing, and each closes a defect the raffle's first version had:
//
//   - IT TAKES A WINDOW, so any past window can be committed at any time, by anyone. A
//     window whose clock ran out before anybody called it would otherwise be
//     unreachable for ever — Resolve and Refund both require Committed — so its whole
//     pot would be lost while heldPots went on counting it and both solvency checks
//     stayed green over money nobody could ever get back. That is
//     AUDIT-2026-09-28.md finding 1, and at an hourly cadence it would happen 24 times
//     a day rather than once a week: MOST WINDOWS OF A QUIET DAY WILL BE COMMITTED LATE
//     BY SOMEBODY WHO WANTS THEIR MONEY, and that path has to work.
//   - THE LIVE WINDOW CAN NEVER BE COMMITTED, so a commit can no longer cut a window's
//     sales short. Otherwise anyone could Buy(1) and immediately Commit: that makes
//     them the sole owner of a FrozenTotal of 1 — the guaranteed winner — and, because
//     Buy refuses a committed window, shuts the window's sales for the rest of its
//     hour. That is AUDIT-2026-09-28.md finding 2. Note that the PRIZE half of that
//     attack is already dead here by the sole-entrant property (winning a one-ticket
//     window returns the attacker's own 95,000 ugnot out of the 100,000 they staked), so
//     what remains is pure griefing — and refusing the live window closes it at the
//     root anyway, rather than with a minimum-tickets or minimum-elapsed heuristic.
//     THIS USED TO SAY THE GRIEFER'S WIN "costs them the 5,000 cut", AND IT COSTS THEM
//     NOTHING NOW: since finding 25 the fee is escrowed and earned only by a draw, so
//     the griefer who DOES NOT resolve pays nothing at all and reclaims the whole
//     100,000 through Refund. The reason the attack is dead is the refusal below, not a
//     5,000 ugnot price on it. AUDIT-2026-09-28.md finding 29.
//
// PERMISSIONLESS: there is no keeper and no admin. Anyone who wants the draw to happen
// — every ticket holder, for a start — can call it once the window is up.
//
// It freezes two numbers and CHOOSES NOTHING:
//
//   - FrozenTotal = the window's final ticket total. The window is over and Buy only
//     ever sells into currentWindow(), so this total can no longer grow BY
//     CONSTRUCTION; it is still assigned explicitly, because Resolve reads this field
//     and not the live total.
//   - CommittedAt, the height the refund grace window counts from.
//   - AND IT USES Draw.Round EXACTLY AS PINNED, which was written when this window's
//     record was created and is not this function's business.
//
// THE SECURITY RULE, AND THE ONLY REASON THIS IS THREE PHASES: the ticket set must be
// frozen BEFORE the randomness is knowable. If the total were read at resolve time,
// anybody who saw the published round could compute the winning unit and then buy
// precisely enough tickets to own it — which turns a draw into a purchase.
//
// THERE IS DELIBERATELY NO "THE ROUND MUST STILL BE IN THE FUTURE" CHECK HERE. A
// reader who expects one has the pin backwards. A window is committed at least an hour
// after its round was pinned, so by now the pinned round MAY LEGITIMATELY ALREADY BE
// SIGNED AND RELAYED — that is the ordinary case for a window whose record opened
// early in its hour, and it is harmless precisely because nobody CHOSE it. Requiring
// it to be unpublished would refuse the honest case and, worse, would reintroduce
// round selection through the back door, since the only way to satisfy such a check
// would be to recompute the round here. The int64 wrap case lives where the arithmetic
// is, at maxPinnableLatest.
//
// WHY FREEZING THE TOTAL ALSO FREEZES WHO OWNS UNIT k — the part r/splash/game got
// wrong first time, and the reason Buy appends:
//
//   - Every purchase APPENDS A NEW ticket index (appendTickets). No index's value is
//     ever increased afterwards, and fenwick.Add is not called from this realm at all.
//   - An appended index therefore starts at a prefix equal to the whole total at the
//     moment it was appended, so anything appended after Commit lies at or beyond
//     FrozenTotal — outside the frozen range by construction, not by convention.
//   - And because no earlier index's value changes, no earlier prefix moves: the owner
//     of every unit below FrozenTotal is fixed from the instant that unit was sold.
//
// WITH ONE INDEX PER BUYER INSTEAD, a further purchase would grow that buyer's
// existing value, widening their range IN PLACE, from its start, inside the frozen
// range, and pushing every later buyer along. The earliest buyer (prefix 0 for ever)
// could then wait for the round to publish, compute k = randomness mod FrozenTotal,
// buy until their own value exceeded k, and call Resolve to take the pot: a free option
// on the whole pot. That exploit was real in r/splash/game.
//
// Panics if the window is not over yet, if it is already committed, or if it has NO
// TICKETS AT ALL. The last is not a formality: there is no rollover, so a drawless
// window must never be allowed to exist — there is no unit to draw and no owner to
// pay. It reads no beacon state at all; the "beacon must exist and be fresh" refusal
// lives at the pin, which is to say in Buy, where a sale is refused rather than
// accepted into a window that could never be drawn.
func Commit(cur realm, window int64) int64 {
	rejectAttachedCoin(cur, "Commit")
	sweepDonations()

	if window >= currentWindow() {
		// THE WHOLE OF THE GRIEFING FIX. Tickets are still being sold into
		// currentWindow(), and a future window is not a window at all yet.
		panic("speed: a window can only be committed once it is over")
	}

	d := getDraw(window)
	if d == nil {
		panic("speed: no tickets sold in that window — there is no rollover, so a drawless window must not exist")
	}
	if d.Committed {
		panic("speed: this window is already committed")
	}
	total := d.tickets.Total()
	if total == 0 {
		panic("speed: no tickets sold in that window — there is no rollover, so a drawless window must not exist")
	}

	// THE ROUND IS READ, NOT CHOSEN. getOrCreateDraw pinned it when this window's
	// record was created; see pinOffsetRounds.
	round := d.Round
	if round <= 0 {
		// Unreachable: getOrCreateDraw is the only way a Draw comes into existence and
		// it always pins a positive round. Stated loudly because the pin IS the
		// security property — and deliberately NOT "pin one now as a fallback", which
		// would hand the round choice straight back to the committer.
		panic("speed: this window's record has no pinned beacon round")
	}

	d.Committed = true
	d.FrozenTotal = total
	// d.Round IS NOT ASSIGNED HERE. It was pinned at record creation and this function
	// must never write it; `round` above is a read.
	//
	// THE HEIGHT THE REFUND GRACE WINDOW COUNTS FROM. Recorded here and nowhere else,
	// because this is the moment the pot becomes unreachable by any route except
	// Resolve or Refund — so it is the moment from which a buyer's beacon-independent
	// claim on their own money starts to age. See refundGraceBlocks and Refund.
	d.CommittedAt = runtime.ChainHeight()

	chain.Emit("Commit",
		"window", strconv.FormatInt(window, 10),
		"frozenTotal", strconv.FormatInt(total, 10),
		"round", strconv.FormatInt(round, 10),
		"pot", strconv.FormatInt(d.Pot, 10),
		"committedAt", strconv.FormatInt(d.CommittedAt, 10),
		"refundOpensAt", strconv.FormatInt(d.CommittedAt+refundGraceBlocks, 10))
	checkInvariant()
	return round
}

// --- Capture -------------------------------------------------------------

// Capture copies a committed window's beacon randomness into the draw.
//
// IT IS A CONVENIENCE AND NOT A SAFETY MECHANISM, and saying so is the point of this
// comment. In the raffle's pre-drand design its job was "save the randomness before
// the beacon prunes it"; r/splash/beacon has no retention window and no Prune, drand
// serves every round for ever from at least three public relays, and Publish is
// permissionless, so THERE IS NOTHING TO PRESERVE THE VALUE FROM. What it still does:
//
//   - it copies a public value into the draw's own state, so Resolve needs no beacon
//     read later and the settled draw is self-contained;
//   - it makes the value visible through CapturedRandomness and the Capture event
//     before the window is settled, which a front end and an auditor can both use.
//
// NOTHING IN THIS REALM'S SAFETY DEPENDS ON ANYONE CALLING IT.
//
// PERMISSIONLESS, deliberately. Its only effect is to store a value that is already
// public — the round's randomness, readable by anyone the moment it is relayed. Gating
// it on an operator would buy nothing and would put a liveness dependency for the
// whole pot onto one key.
//
// WHAT IS STORED IS THE 64-CHARACTER HEX RANDOMNESS — sha256 of the signature, a hash,
// not the signature itself — and it is NOT re-verified here. The pairing check happened
// once already inside beacon.Publish on the way in; redoing it would be expensive
// duplicated work on an input that is already known good, and the beacon has no route
// by which a published round's randomness can change afterwards.
//
// A SECOND Capture NEVER OVERWRITES THE FIRST, and is a silent no-op rather than a
// panic: two callers racing to perform a permissionless public good should not make one
// of them fail.
//
// Capturing before the round is relayed PANICS. There is nothing to preserve yet, and
// storing anything else — least of all some already-published value — would hand the
// draw a randomness for a round nobody pinned, which is the exact attack the pin exists
// to prevent.
//
// COMMIT DOES NOT CAPTURE, AND MUST NOT START. Since the round is pinned at record
// creation, a window's round may well be relayed by the time it is committed, so a
// capture there would often succeed — and it would put a beacon read back inside the
// one function whose job is to choose nothing.
func Capture(cur realm, window int64) {
	rejectAttachedCoin(cur, "Capture")
	sweepDonations()

	d := getDraw(window)
	if d == nil {
		panic("speed: no draw for that window")
	}
	if !d.Committed {
		panic("speed: this window is not committed yet")
	}
	if d.Resolved {
		panic("speed: this window's draw is already resolved")
	}
	if d.Abandoned {
		// The window is in refund and can never be resolved, so there is nothing left
		// for a captured randomness to be used for. Refusing keeps the one exit one-way
		// at every entry point rather than only at Resolve.
		panic("speed: this window was abandoned and refunded; there is nothing to capture")
	}
	if d.Randomness != "" {
		// Already captured: keep the first value, without failing the caller.
		return
	}
	if !beacon.Published(d.Round) {
		panic("speed: beacon round not published yet")
	}

	rnd := beacon.Randomness(d.Round)
	if len(rnd) != randomnessHexLen {
		// A length check, NOT a re-verification: it only asserts the shape of the value
		// this realm is about to depend on, so that an empty or truncated string can
		// never be mistaken for "captured" (the empty string is this field's "not
		// captured" sentinel).
		panic("speed: beacon randomness has the wrong length")
	}
	d.Randomness = rnd

	chain.Emit("Capture",
		"window", strconv.FormatInt(window, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"randomness", rnd)
	checkInvariant()
}

// --- Resolve -------------------------------------------------------------

// Resolve picks the window's winner and PAYS THEIR WALLET. PERMISSIONLESS.
//
// The whole pot leaves this realm in a single wugnot.Transfer to the winner's address.
// No internal balance is credited, there is nothing left to claim afterwards, and no
// buyer's money is held past the window they bought into.
//
// winner = ownerOfUnit(randomness mod FrozenTotal). FrozenTotal, NOT the live ticket
// total: recomputing it here would reopen the buy-the-winning-unit attack described on
// Commit.
//
// The pot pays out UNTAXED. The house cut was already taken on the way in, at sale
// time; taxing the payout as well would be charging twice for the same ticket.
//
// RANDOMNESS SOURCE: a captured value if there is one, otherwise the beacon directly —
// so the happy path needs no extra transaction.
//
// THERE IS ONE FAILURE MESSAGE AND THERE CAN ONLY BE ONE. "Not relayed yet" is always
// a wait-and-retry, never "this draw is dead": no round is ever unobtainable, so
// anybody who sees that message can make it stop being true by relaying the round
// themselves for ~17.0M gas. A realm that offered a second, terminal message would be
// steering buyers into refunds they do not need.
//
// THERE IS NO HEIGHT GATE HERE AND THERE MUST NEVER BE ONE. refundGraceBlocks does not
// appear in this function and CommittedAt is not read: the grace window is a FLOOR ON
// BUYER ACCESS, NOT A DEADLINE ON THE DRAW. It only ever opens Refund; it never closes
// Resolve. An honest relay that arrives a day after Commit, before anybody has
// refunded, should still pay the winner it always would have, over exactly the
// FrozenTotal it was frozen with. Adding a height deadline here would manufacture a
// second class of dead window — past the grace, relayed, and resolvable by nobody —
// which is the very shape of defect the grace window exists to remove.
//
// WHAT DOES CLOSE THIS FUNCTION IS Abandoned, and that is enough. Once the grace window
// has opened, Resolve and Refund are both available and the first one called wins: a
// refund sets Abandoned and this function refuses for ever, a resolve pays the winner
// and Refund's Resolved check refuses for ever. NEITHER ORDERING CAN PAY THE SAME UGNOT
// TWICE, which is the property that matters. The fairness cost of that race — a buyer
// who can see they did not win refunds instead, annulling the draw — is
// AUDIT-2026-09-28.md finding 7's recorded residual, and it is CHEAPER HERE THAN THERE
// because the window that produces it is twelve hours rather than three weeks. It is
// derived and discussed at refundGraceBlocks rather than buried here.
func Resolve(cur realm, window int64) {
	rejectAttachedCoin(cur, "Resolve")
	sweepDonations()

	d := getDraw(window)
	if d == nil {
		panic("speed: no draw for that window")
	}
	if !d.Committed {
		panic("speed: this window is not committed yet")
	}
	if d.Resolved {
		panic("speed: this window's draw is already resolved")
	}
	if d.Abandoned {
		// PERMANENT, AND DELIBERATELY NOT CONDITIONAL ON THE BEACON. Refunds are open
		// on this window and at least one buyer has already taken their money out, so
		// the frozen range no longer corresponds to who is still owed. Resolving now
		// would draw over the original range and pay whatever is left of the pot —
		// other buyers' money — to a possibly-refunded winner. See Draw.Abandoned.
		panic("speed: this window was abandoned and refunded; it can never be resolved")
	}
	if d.FrozenTotal <= 0 {
		// Unreachable: Commit refuses a zero total. Loud rather than a division by zero
		// inside randomnessMod.
		panic("speed: draw has no frozen tickets")
	}

	rnd := d.Randomness
	if rnd == "" {
		if beacon.Published(d.Round) {
			rnd = beacon.Randomness(d.Round)
		} else {
			panic("speed: beacon round not published yet")
		}
	}

	winner := ownerOfUnit(d, randomnessMod(rnd, d.FrozenTotal))

	pot := d.Pot
	// THE ONE MOMENT THE HOUSE'S FEE IS EARNED — AUDIT-2026-09-28.md finding 25. The draw
	// happened, so the window's escrowed Cut becomes ops revenue here and NOWHERE ELSE.
	// Buy does not credit opsPot, Commit does not, Capture does not; a window that reaches
	// any other terminal state returns the fee to its buyers instead.
	//
	// IT IS MOVED, NOT PAID: no wugnot leaves the realm for it, so heldCuts falls by
	// exactly what opsPot gains and the balance side of checkInvariant does not move for
	// this half at all. AND IT IS DELIBERATELY NOT ADDED TO `pot` — the winner must not win
	// our fee.
	cut := d.Cut
	d.Resolved = true
	d.Winner = winner
	d.Pot = 0
	d.Cut = 0
	heldPots -= pot
	heldCuts -= cut
	opsPot += cut

	if pot > 0 {
		// Books first, transfer second. wugnot's Transfer has no hook or callback, so
		// there is no reentrancy to fear either way, but writing the state first means
		// a future GRC20 with a hook cannot see a pot that has already been promised
		// and not yet zeroed.
		wugnot.Transfer(cross(cur), winner, pot)
	}

	chain.Emit("Resolve",
		"window", strconv.FormatInt(window, 10),
		"round", strconv.FormatInt(d.Round, 10),
		"winner", string(winner),
		"pot", strconv.FormatInt(pot, 10),
		"cutEarned", strconv.FormatInt(cut, 10))
	checkInvariant()
}

// --- Refund --------------------------------------------------------------

// THERE IS NO resolvable() HELPER IN THIS FILE AND NOTHING SHOULD ADD ONE. The raffle
// had one and it was DELETED in the drand migration rather than rescaled. It read
// "the round came and went, nobody kept it, and so this draw can NEVER be resolved",
// which was a claim about a beacon that forgot things. r/splash/beacon has no
// PruneWindow and no Prune, drand serves every round for ever from at least three
// independent relays, and Publish is permissionless — so A PINNED ROUND IS ALWAYS
// EVENTUALLY RESOLVABLE and such a function is identically true.
//
// AND MIND THE TRAP IN THE OBVIOUS ALTERNATIVE, because it is a fund drain and not a
// tidy-up. A "resolvable" predicate that merely checked `d.Randomness != "" ||
// beacon.Published(d.Round)` would report a freshly committed window whose round is not
// yet relayed as NOT resolvable — and a refund gate that opens when resolvable() is
// false would then open REFUNDS ON EVERY LIVE DRAW IMMEDIATELY. The height gate below
// is the only correct shape: a beacon-state gate cannot distinguish "not relayed yet"
// from "never will be", and a clock can.

// refundGraceElapsed reports whether refundGraceBlocks have passed since Commit froze
// this window. IT READS NO BEACON STATE AT ALL, and that is its entire purpose: it is
// the one condition in this file that a stopped, lost or simply uninterested relayer
// cannot hold false. See refundGraceBlocks for the derivation.
//
// IT IS MONOTONE: chain height only rises and CommittedAt never moves once set, so this
// goes true exactly once and stays true.
//
// A ZERO CommittedAt RETURNS false, and false is the safe direction. It is unreachable
// through the entry points — Refund tests Committed first, and Commit sets both fields
// in the same statement group. If it ever were reachable, withholding the escape hatch
// is a liveness cost, whereas granting it would open refunds on a live draw at any
// height past refundGraceBlocks.
func refundGraceElapsed(d *Draw) bool {
	if d.CommittedAt <= 0 {
		return false
	}
	return runtime.ChainHeight()-d.CommittedAt >= refundGraceBlocks
}

// Refund returns the caller's own ticket money for a window nobody settled.
// PERMISSIONLESS, and self-service only: a caller can only ever reclaim their own
// record.
//
// WHAT IT IS FOR IS LIVENESS, NOT LOSS. A window's pot must not be hostage to whether
// anybody spends ~17.0M gas relaying one drand round, and at an hourly cadence with
// pots of a few tenths of a GNOT that is not an exotic worry — IT IS THE EXPECTED
// OUTCOME OF A QUIET HOUR. That is the only failure left, it is unbounded in time, so
// the exit is A CLOCK: refunds open refundGraceBlocks (twelve hours) after Commit and
// not before.
//
// THE PRECONDITION IS THEREFORE NOT THE COMPLEMENT OF Resolve's — the two OVERLAP for
// ever once the window opens, and that is fine and is handled by Abandoned. There is no
// state in which Resolve is impossible, so a refund gate that waited for one would never
// open at all.
//
// AND THE EXIT IS ONE-WAY, WHICHEVER WAY IT GOES. Refund and Resolve are permanently
// mutually exclusive per window: the first refund that pays out sets Abandoned, after
// which Resolve and Capture refuse that window for ever and every later refund proceeds
// without consulting the beacon again. Read Draw.Abandoned for the theft this prevents
// — it is AUDIT-2026-09-28.md finding 3 and it carries more weight since the drand
// migration, not less, because a pinned round can be relayed by anyone at any time for
// ever.
//
// EACH BUYER RECLAIMS EXACTLY THEIR OWN RECORDED SPEND, ONCE. The record is zeroed
// before the transfer, so a second call finds nothing and panics; and because
// Pot + Cut == sum(spendOf) for an unresolved window — WITH NO SPONSORSHIP TERM TO GET IN
// THE WAY, which is the whole simplification this realm buys by having no FundPot — the
// refunds can never total more than the realm holds against this window.
//
// THE HOUSE FEE *IS* REFUNDED, SINCE 2026-09-29, AND THE PARAGRAPH THAT USED TO BE HERE
// SAID THE OPPOSITE. It read: "What a buyer gets back is their post-cut contribution — the
// part that was ever in the prize pot — not the gross ticket price. The 5% was taken at
// sale time and is already in the ops pot; clawing it back would mean the ops pot could go
// negative, or that this realm had to hold every cut in escrow against the chance of an
// unrelayed round." IT IS KEPT VERBATIM BECAUSE IT NAMES THE COST OF THE FIX AND THE FIX
// PAID IT: the realm now DOES hold every fee in escrow per window (Draw.Cut), which is the
// second option that sentence dismissed, and the ops pot cannot go negative because
// nothing credits it until a draw succeeds.
//
// WHAT A BUYER GETS BACK IS THEREFORE THE WHOLE TICKET PRICE. A refunded window is a
// window that did not run, and the fee was a charge for a draw that never happened. This
// is a REDUCTION IN HOUSE REVENUE in the failure case, which needs no permission and is
// the safe direction. AUDIT-2026-09-28.md finding 25.
//
// A WINDOW THAT WAS NEVER COMMITTED IS NOT REFUNDABLE HERE, and needs no separate path
// — but only because Commit TAKES THE WINDOW AS AN ARGUMENT and any window that is over
// can be committed by anyone at any time. So a buyer holding a stranded window's tickets
// names that window to Commit themselves, and then either Resolves it (the normal
// outcome, once somebody relays the round) or refunds it here twelve hours later. Before
// Commit took that argument the equivalent sentence in the raffle was simply FALSE, and
// that was AUDIT-2026-09-28.md finding 1.
func Refund(cur realm, window int64) {
	rejectAttachedCoin(cur, "Refund")
	sweepDonations()

	d := getDraw(window)
	if d == nil {
		panic("speed: no draw for that window")
	}
	if d.Resolved {
		panic("speed: this window's draw is already resolved")
	}
	if !d.Committed {
		panic("speed: this window is not committed yet — commit it first; refunds only open on a window nobody settled")
	}
	// THE Abandoned CHECK COMES FIRST, and it must: once this window is in refund it
	// stays in refund, whatever the beacon says later. A pinned round can be relayed by
	// anybody at any time, for ever, so without this a window with some buyers already
	// refunded could be resolved over the original frozen range.
	//
	// THE HEIGHT GATE IS THE ONLY OPENER. Refusing needs both terms — not abandoned, and
	// still inside the grace window. The message tells the caller which of the two things
	// to do, because both are available to them: wait for the window, or relay the round
	// themselves and resolve. The height the window opens at is in Render, in DrawOf and
	// in the Commit event.
	if !d.Abandoned && !refundGraceElapsed(d) {
		panic("speed: this window's draw is still live — refunds only open once the grace window has elapsed")
	}

	caller := cur.Previous().Address()
	k := string(caller)
	amount := treeInt64(d.spendOf, k)
	if amount <= 0 {
		panic("speed: nothing to reclaim for that window")
	}

	// THE POINT OF NO RETURN, set on the first refund that actually pays out — never by
	// a refusal above, which must leave the window exactly as it was.
	//
	// AND THERE IS NOTHING ELSE TO DO HERE, which is worth noticing. The raffle's
	// equivalent branch has to RETIRE that week's SPONSORSHIP, because house money is
	// attributable to no buyer and would otherwise sit for ever in a pot whose every claim
	// had been zeroed — money in, no way out, the class of defect seven of its findings are
	// about. This realm has no sponsorship, so Pot == sum(spendOf) already and the whole pot
	// is claimable by the people who own it.
	//
	// THIS PARAGRAPH SAID "MOVE THAT WEEK'S SPONSORSHIP TO opsPot" UNTIL 2026-09-29 AND THAT
	// DESTINATION IS DELETED — AUDIT-2026-09-28.md findings 16, 28, 31 and 34. The raffle's
	// transition now converts the sponsorship into a PER-UNIT CLAIM ON THE SAME WEEK, held by
	// the addresses that EARNED entries in it through duel play, and moves nothing anywhere;
	// only a week with no earned holders at all reaches opsPot. The correction is recorded
	// rather than made silently because a reader comparing the two files will be looking for
	// the branch this sentence describes.
	if !d.Abandoned {
		d.Abandoned = true
		chain.Emit("Abandon",
			"window", strconv.FormatInt(window, 10),
			"pot", strconv.FormatInt(d.Pot, 10),
			"escrowedCut", strconv.FormatInt(d.Cut, 10))
	}

	// AND THE ESCROWED FEE IS NOT TOUCHED BY THE TRANSITION EITHER, WHICH IS THE POINT.
	// The raffle's equivalent branch has to RETIRE that week's SPONSORSHIP, because it belongs
	// to no buyer — and "move it somewhere", which is what this sentence said until
	// 2026-09-29, is precisely the thing three of that realm's findings were about: there is
	// no destination any more, only a per-unit claim on the week the money is already in
	// (AUDIT-2026-09-28.md findings 28, 31 and 34). A FEE BELONGS TO SPECIFIC BUYERS, so it
	// needs no transition at all: it goes back to them one gross refund at a time, in the
	// split below. Finding 25's
	// abandonment rule — we did not run a draw, so we do not keep the fee — is therefore
	// implemented here by doing nothing special, and that is worth stating so a reader does
	// not go looking for the missing branch.
	//
	// A BUYER WHO NEVER CALLS THIS LEAVES THEIR OWN GROSS SITTING IN THE WINDOW, fee part
	// included, and that is not a new stranded-money path: there is no deadline on a refund,
	// Abandoned is one-way so nothing else can take it, and the only address that can ever
	// reclaim it is theirs.

	// THE REFUNDED BUYER KEEPS THEIR TICKETS ON PURPOSE. d.tickets, d.ownerOf and
	// d.ticketsOf are deliberately NOT touched here: fenwick rejects negative deltas by
	// design and FrozenTotal must never move, so a ticket cannot be retired once sold.
	// That would mean a refunded buyer kept their full winning probability while holding
	// their money back — harmless ONLY because the line above makes this window
	// unresolvable for ever, so no draw over this ticket set will ever happen. DO NOT
	// "FIX" THE UN-RETIRED TICKETS by reopening Resolve on an abandoned window: the
	// tickets are dead weight, and the window's exit being one-way is what makes them
	// safe.
	// THE GROSS IS SPLIT BACK INTO THE TWO TERMS IT ARRIVED IN — AUDIT-2026-09-28.md
	// finding 25, and this is where the rounding lives. Transcribed from the raffle's
	// Refund, which has the full argument; the short form:
	//
	//   - THE TWO PARTS ALWAYS SUM TO THE GROSS, unconditionally, because cutPart is
	//     computed and potPart is the REMAINDER. So the per-window identity
	//     Pot + Cut == sum(spendOf) survives ANY rounding: this call removes `amount` from
	//     both sides. That is what makes Refund unable to overdraw, and it holds after a
	//     partial refund and in every ordering.
	//   - THE SPLIT ALSO LANDS ON THE SAME SIDE AS BUY'S, because the cutPerTicket build
	//     guard forbids a TicketPrice/houseCutBps pair for which the flooring discards
	//     anything — so every cut is tickets * cutPerTicket exactly, and so is every
	//     partial sum of them. Without that guard the two could differ by one ugnot per
	//     buyer and d.Cut could be driven negative by a refund of a buyer's own money.
	cutPart := int64(mulDiv(uint64(amount), uint64(houseCutBps), uint64(bpsDenom)))
	potPart := amount - cutPart

	d.spendOf.Set(k, int64(0))
	d.Pot -= potPart
	d.Cut -= cutPart
	heldPots -= potPart
	heldCuts -= cutPart
	if d.Pot < 0 {
		// Unreachable while Pot + Cut == sum(spendOf). Loud rather than paying out money
		// that belongs to another window.
		panic("speed: refund would overdraw the window's pot")
	}
	if d.Cut < 0 {
		// Unreachable for the reason above: the build guard makes the per-buyer fee
		// derivation exact. Loud rather than releasing a fee twice or paying one buyer out
		// of another window's escrow.
		panic("speed: refund would overdraw the window's escrowed fee")
	}

	// THE FULL TICKET PRICE GOES BACK, NOT 95% OF IT. That is the behaviour change finding
	// 25 is about: the fee was never earned, because the draw never ran.
	wugnot.Transfer(cross(cur), caller, amount)

	chain.Emit("Refund",
		"window", strconv.FormatInt(window, 10),
		"buyer", string(caller),
		"amount", strconv.FormatInt(amount, 10),
		"prizePart", strconv.FormatInt(potPart, 10),
		"feeReturned", strconv.FormatInt(cutPart, 10),
		"pot", strconv.FormatInt(d.Pot, 10),
		"escrowedCut", strconv.FormatInt(d.Cut, 10))
	checkInvariant()
}

// --- SweepDrawlessWindow -------------------------------------------------

// SweepDrawlessWindow moves a FINISHED, TICKETLESS window's pot to the ops pot, so
// that money in such a window can leave. PERMISSIONLESS, like Commit. Returns the
// amount moved.
//
// READ THIS WHOLE COMMENT BEFORE DELETING THE FUNCTION AS DEAD CODE, because in v1 IT
// IS UNREACHABLE THROUGH EVERY ENTRY POINT and that is deliberate.
//
// WHY IT IS UNREACHABLE HERE. A Draw record comes into existence in exactly one place
// (getOrCreateDraw) with exactly one caller (Buy), and Buy appends a positive ticket
// count in the same transaction; a panic anywhere after the record is created reverts
// the whole transaction, record included. So there is NO SEQUENCE OF CALLS that leaves
// a window with a record, a zero ticket total and a positive pot. That argument is
// asserted by the suite (a ticketless window cannot be produced through Buy) and the
// function's own preconditions are exercised by installing the state directly.
//
// WHY IT EXISTS ANYWAY. It is the shape of AUDIT-2026-09-28.md's fifth fix, and the
// defect it exists against is the single most common one in that document — SIX of the
// fourteen findings are "money is in the realm and no path can ever get it out", and
// four of those six were found by an engineer implementing something else, not by an
// audit. In the raffle the state is REACHABLE: FundPot credits the live week and
// creates its record, so a week in which the duel's rake arrived but nobody bought a
// ticket ends holding money in a Draw that Commit rightly refuses (no tickets), that
// Resolve and Refund cannot touch (both require Committed) and that FundPot will never
// revisit (it only funds the live week). ADDING ANY OF THE THINGS THE PACKAGE COMMENT
// WARNS AGAINST — sponsorship, a rake feed, a jackpot, a rollover — MAKES IT REACHABLE
// HERE TOO, and the day that happens this exit should already be in place and tested
// rather than being the thing somebody forgot.
//
// WHERE THE MONEY GOES, AND WHY IT IS NOT "ROLLED FORWARD" INTO THE LIVE WINDOW'S POT.
//
// THE PARAGRAPH THAT STOOD HERE RECOMMENDED A DESIGN TWO AUDITS FOUND EXPLOITABLE, AND
// THAT IS WHY IT IS QUOTED RATHER THAN QUIETLY REPLACED — AUDIT-2026-09-28.md finding 36.
// It read:
//
//	"The raffle rolls a drawless week's sponsorship into the live week's pot, AND IT IS
//	RIGHT TO: that money is the PLAYERS' side of the duel rake, so handing it to the house
//	would take the players' share away from players, and the raffle has a Sponsored field
//	that lets the destination week's pot exceed its spend records without breaking
//	anything."
//
// EVERY CLAUSE OF IT IS NOW FALSE, AND THE "AND IT IS RIGHT TO" WAS THE DEFECT. The raffle
// does not roll a dead week's sponsorship anywhere: rolling it into the live week was
// AUDIT-2026-09-28.md finding 28 (a destination evaluated at call time is a destination the
// permissionless caller chooses, by choosing when to fire), and the register that replaced it
// for one day was finding 31 (the caller who opens the destination week is the caller who
// calls Buy, so they could be its only entrant and capture the whole amount for the price of
// the house cut). A dead week's sponsorship now becomes a PER-UNIT CLAIM ON THE WEEK IT IS
// ALREADY IN, payable to the holders of that week's EARNED entries — read the raffle's
// retireSponsorship and ClaimDeadWeek. There is no destination at all.
//
// SO A READER WHO PORTS SPONSORSHIP INTO THIS FILE MUST NOT PORT THE SENTENCE ABOVE. The
// half of it that was sound — this money is the PLAYERS' share and must not end up with the
// house — is satisfied by giving it back to the players who earned it, in place, and never by
// moving it to a week somebody can pick. This comment is where an engineer adding a rake feed
// here would look first, which is exactly why a recommendation for a broken design sitting in
// it is a defect and not untidiness.
//
// NEITHER HALF OF THE ORIGINAL APPLIED HERE IN ANY CASE.
//
//   - This realm has no sponsorship and no rake, so there is no players' share to
//     protect: any money in a ticketless window is unattributable by construction —
//     exactly like a stranger's unsolicited transfer, which sweepDonations also sends
//     to opsPot.
//   - Crediting the live window's Pot would BREAK Pot == sum(spendOf) for that window,
//     which is the identity that makes Refund unable to overdraw and makes a sole
//     entrant's prize exactly their own stake. AuditFailure would then report the live
//     window as short, correctly, and the only way to "fix" it would be to add the
//     Sponsored field and the three mechanisms that come with it — porting the
//     complexity the package comment says not to port, to launder money that cannot
//     exist.
//
// SO opsPot — AND SINCE 2026-09-29 THE TWO REALMS AGREE ON THIS SHAPE RATHER THAN
// DIFFERING, which is the opposite of what this paragraph used to say. It read: "SO opsPot,
// WHICH IS A DELIBERATE DEVIATION FROM THE WEEKLY REALM'S CHOICE AND IS NAMED AS ONE ... the
// routing question ('where does it belong') is answered differently because the money has a
// different origin." The raffle's own no-claimant branch now sends a dead week's sponsorship
// to opsPot for exactly the reason given here — there is provably no address holding a unit of
// that week, so there is nobody to wrong — and it only pays holders when holders exist. Read
// the raffle's retireSponsorship: the branch is on its EARNED unit total and nothing else.
// The essential property of the fifth fix is preserved in full either way: money in the
// realm has a path out, here through WithdrawOps.
//
// Panics if the window is not over yet (a live window may still sell its first ticket,
// which would make it a real draw whose buyers are entitled to everything in its pot),
// if there is no record for it, if it sold ANY tickets, if it holds nothing, or —
// defensively — if it is committed, resolved or abandoned.
func SweepDrawlessWindow(cur realm, window int64) int64 {
	rejectAttachedCoin(cur, "SweepDrawlessWindow")
	sweepDonations()

	if window >= currentWindow() {
		// THE SAME "ONLY ONCE IT IS OVER" RULE AS Commit, and for a reason of its own:
		// the live window can still sell its first ticket, at which point it is a real
		// draw whose buyers are entitled to the whole pot. Sweeping it would take the
		// prize out from under a buyer mid-window.
		panic("speed: a window can only be swept once it is over")
	}

	d := getDraw(window)
	if d == nil {
		panic("speed: no draw for that window")
	}
	if total := d.tickets.Total(); total != 0 {
		// A WINDOW WITH TICKETS IS A REAL DRAW and belongs to Commit/Resolve/Refund.
		// Sweeping one would take a pot away from the buyers who paid into it.
		panic("speed: that window sold tickets — it is a real draw, so Commit and Resolve it (or Refund it), never sweep it")
	}
	// THE THREE CHECKS BELOW ARE DEFENSIVE AND SHOULD BE DOUBLY UNREACHABLE. With a
	// zero ticket total the window can never have been committed (Commit refuses a zero
	// total), so it can never have been resolved or abandoned either (both require
	// Committed). They are stated anyway, loudly, because this function moves money and
	// a silent sweep of a window that had somehow reached one of those states would be
	// far worse than a failed transaction.
	if d.Committed {
		panic("speed: that window is committed — it is a real draw, not a drawless one")
	}
	if d.Resolved {
		panic("speed: that window's draw is already resolved")
	}
	if d.Abandoned {
		panic("speed: that window was abandoned and refunded")
	}

	amount := d.Pot
	if amount <= 0 {
		panic("speed: that window holds nothing — there is nothing to sweep")
	}
	if d.Cut != 0 {
		// Unreachable, and asserted rather than assumed — AUDIT-2026-09-28.md finding 25.
		// An escrowed fee can only arrive with a ticket SALE, and this function has already
		// refused any window with a non-zero ticket total, so a sweepable window has no fee
		// to release. Stating it stops this function silently moving a window's pot to the
		// house while leaving an unearned fee behind in a window with no spendOf record to
		// refund it through — which nobody could ever reclaim. A loud refusal, not a
		// rollover.
		panic("speed: a ticketless window is holding an escrowed fee")
	}

	// NO WUGNOT MOVES HERE, and a reader looking for the missing Transfer should stop
	// looking. The tokens are already inside this realm, so this is PURE BOOKKEEPING:
	// the realm's wugnot balance is identical before and after, heldPots loses exactly
	// what opsPot gains, and checkInvariant's equality therefore still holds at the end.
	// WithdrawOps is what actually takes it out.
	d.Pot = 0
	heldPots -= amount
	opsPot += amount

	chain.Emit("SweepDrawlessWindow",
		"window", strconv.FormatInt(window, 10),
		"amount", strconv.FormatInt(amount, 10),
		"opsPot", strconv.FormatInt(opsPot, 10))
	checkInvariant()
	return amount
}

// --- WithdrawOps ---------------------------------------------------------

// WithdrawOps pushes the whole ops pot to opsVaultAddr and returns the amount moved.
// PERMISSIONLESS.
//
// THE DEFECT IT CLOSES IS AUDIT-2026-09-28.md FINDING 6, and it is in this file from
// the start rather than added later: without it opsPot only ever increases — the 5% cut
// on every ticket (the product's entire revenue), every swept donation, and anything
// SweepDrawlessWindow ever moves — and all of it would be permanently unreachable by
// every path in the realm while checkInvariant and AuditFailure both stayed green,
// because both count opsPot as money the realm holds and neither has an opinion about
// whether anybody can reach it.
//
// PERMISSIONLESS, AND THAT IS SAFE PRECISELY BECAUSE THE DESTINATION IS FIXED AT
// COMPILE TIME. A reader will look for a caller check here and there is none, on
// purpose: opsVaultAddr is a const, so the caller does not choose where the money goes,
// cannot name themselves, and cannot name a window's pot. All they can do is push the
// house's money to the house — and paying the gas to do somebody else's bookkeeping is
// a favour, not an attack. Gating it on an operator key would buy nothing and would put
// a liveness dependency for the realm's revenue onto one key, exactly as it would for
// Commit, Capture and Resolve. The property that makes it sound is the one
// tools/speed_addr_test.go exists to keep true.
//
// IT NEVER REACHES A PLAYER'S MONEY. No Draw is touched: not Pot, not spendOf, not a
// ticket. The only book that moves is opsPot, which by construction holds nothing any
// buyer can claim — the fee in it was EARNED BY A WINDOW THAT ACTUALLY DREW (Resolve
// releases that window's escrow; a window that fails refunds it with the gross) and a
// donation belongs to whoever chose to give it away.
//
// THE CITATION THAT USED TO STAND HERE IS RETIRED: this paragraph said "the cut was
// taken at sale time (see Refund's 'THE HOUSE CUT IS NOT REFUNDED')", and neither half
// survives — finding 25 stopped the fee being taken at sale time and deleted that
// section of Refund. A citation that outlives the thing it cites is how a reader ends
// up trusting a rule the code stopped following. AUDIT-2026-09-28.md finding 29.
//
// sweepDonations RUNS FIRST, as in every other mutator, so a donation that arrived
// since the last state change is included in this withdrawal rather than left behind.
//
// BOOKS FIRST, TRANSFER SECOND, exactly as Resolve and Refund do it: opsPot is zeroed
// BEFORE the wugnot leaves, so a re-entrant call — which wugnot's Transfer cannot cause
// today, having no hook or callback, but a future GRC20 might — finds an empty pot and
// panics rather than a balance it can take twice.
//
// THE INVARIANT IS EXACT ACROSS IT, not merely preserved one-sidedly: checkInvariant
// asserts heldPots + opsPot == balance, and this call reduces both sides by the same
// amount. heldPots is deliberately untouched.
//
// Panics if there is nothing to withdraw.
func WithdrawOps(cur realm) int64 {
	rejectAttachedCoin(cur, "WithdrawOps")
	sweepDonations()

	amount := opsPot
	if amount <= 0 {
		panic("speed: the ops pot is empty — there is nothing to withdraw")
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

// PotSize is the CURRENT window's prize pot in ugnot: ticket sales after the house cut,
// and nothing else. It is the whole amount the winner takes.
func PotSize() int64 {
	d := getDraw(currentWindow())
	if d == nil {
		return 0
	}
	return d.Pot
}

// TicketTotal is the CURRENT window's ticket units sold.
func TicketTotal() int64 {
	return TicketTotalOfWindow(currentWindow())
}

// TicketTotalOfWindow is a given window's ticket units sold: the LIVE total, not
// FrozenTotal, so it is readable before a commit and is zero for a window that never
// sold a ticket. DrawOf reports FrozenTotal, which is zero on any uncommitted window,
// so a caller cannot use it to tell "sold nothing" from "sold plenty and was never
// committed"; this read is that distinction.
func TicketTotalOfWindow(window int64) int64 {
	d := getDraw(window)
	if d == nil {
		return 0
	}
	return d.tickets.Total()
}

// TicketsOf is addr's ticket units in the CURRENT window.
func TicketsOf(addr address) int64 {
	return TicketsOfWindow(currentWindow(), addr)
}

// TicketsOfWindow is addr's ticket units in a given window, so a front end can still
// show a buyer their past windows once the clock has moved on.
func TicketsOfWindow(window int64, addr address) int64 {
	d := getDraw(window)
	if d == nil {
		return 0
	}
	return treeInt64(d.ticketsOf, string(addr))
}

// SpendOf is addr's refundable contribution to the CURRENT window's pot in ugnot: what
// they paid MINUS the house cut, which is what Refund would return. It is not the gross
// ticket price they paid.
func SpendOf(addr address) int64 {
	return SpendOfWindow(currentWindow(), addr)
}

// SpendOfWindow is addr's remaining refundable contribution to a given window's pot.
// Zero once they have been refunded.
func SpendOfWindow(window int64, addr address) int64 {
	d := getDraw(window)
	if d == nil {
		return 0
	}
	return treeInt64(d.spendOf, string(addr))
}

// CurrentWindow is the window tickets are being sold into right now.
func CurrentWindow() int64 {
	return currentWindow()
}

// WindowBlocks is windowBlocks, EXPORTED so a front end can show how long a window
// lasts and compute when the current one ends without hardcoding the cadence.
func WindowBlocks() int64 { return windowBlocks }

// WindowEndHeight is windowEndHeight, EXPORTED: the chain height at which a given window
// stops being the live one. A window is live for heights [WindowEndHeight(window-1),
// WindowEndHeight(window)) — the returned height is the FIRST height of window+1, NOT
// the last height of window, so at exactly this height CurrentWindow already reads
// window+1. A countdown that showed "1 block left" here would be off by one.
//
// IT IS A BLOCK HEIGHT AND DELIBERATELY NOT A TIME. A window is windowBlocks =
// blocksPerDay/24 = 1090 blocks, and blocksPerDay = 26182 encodes an ASSUMED
// 86400/26182 = 3.29998 s per block (read blocksPerDay and windowBlocks for how much
// that assumption is allowed to be wrong). The chain does not actually run at that rate:
// 3.306 s measured on gno.land mainnet and 3.376 s on onyx-1. So a caller wanting a
// wall-clock countdown must multiply by a block time IT chooses and own the error; this
// realm will not return seconds or "time remaining", because that would bake one clock's
// rounding into every front end that reads it and make the contract the source of a
// number it cannot know. Nothing on chain converts blocks to seconds and neither does
// this.
//
// WHY THIS AND NOT AN EXPORTED launchHeight: WindowBlocks is already exported, so
// LaunchHeight() + WindowBlocks() would indeed let a caller derive the boundary — but it
// would leave the +1 above to be re-implemented off chain in every reader, and the
// raffle cannot offer the same pair at all (both raffleWeekDays and blocksPerDay are
// unexported there). One read with one name in both realms beats two constants and a
// formula the caller has to get right twice. This read also subsumes the constant:
// launchHeight is WindowEndHeight(-1).
//
// NEGATIVE OR FAR-FUTURE window IS NOT REFUSED and returns the arithmetic for it,
// exactly as windowEndHeight does — this is a pure function of window and launchHeight
// with no record lookup, so there is no "no such window" state to report.
func WindowEndHeight(window int64) int64 {
	return windowEndHeight(window)
}

// CurrentWindowEndHeight is the chain height at which the LIVE window ends: the one
// number a countdown wants. WindowEndHeight(CurrentWindow()), read in a single call.
//
// IT IS ONE CALL ON PURPOSE, and it matters more here than in the raffle because this
// realm's window is an HOUR rather than a week. Composing the two exported reads off
// chain means two queries at two different chain heights, and a window that turns over
// between them yields a boundary for a window that has already ended — a countdown that
// jumps backwards by a whole hour exactly at the moment it matters most. Read here, both
// halves see one height.
//
// A BLOCK HEIGHT, NOT A TIME, for the reasons on WindowEndHeight.
func CurrentWindowEndHeight() int64 {
	return windowEndHeight(currentWindow())
}

// PinOffsetRounds is pinOffsetRounds, EXPORTED so a front end (or an auditor) can check
// a window's pinned round against the anchor in its PinRound event without hardcoding
// the offset. Read pinOffsetRounds for what it protects.
func PinOffsetRounds() int64 { return pinOffsetRounds }

// MaxStaleBlocks is speedMaxStaleBlocks, EXPORTED so a front end can tell a player why
// a Buy was refused — the beacon needs a relay — rather than showing them a panic.
// beacon.StaleBlocks() is the number to compare it against.
func MaxStaleBlocks() int64 { return speedMaxStaleBlocks }

// DrawOf reports a window's record: committed, frozen ticket total, beacon round, pot,
// resolved, winner, abandoned, committed-at-height. All zero for a window that never
// sold a ticket.
//
// ABANDONED IS PART OF THIS TUPLE rather than a separate read because it is not a
// detail: it is the difference between a window that is waiting for its randomness and
// a window that is paying its buyers back and will never have a winner. A front end that
// showed "unresolved" for both would be lying to a buyer about whether to expect a draw
// or to go and claim a refund.
//
// COMMITTED-AT IS THE LAST ELEMENT, and it is here so a front end can compute the one
// number a buyer of a stuck window actually wants: CommittedAt + refundGraceBlocks, the
// height at which their money becomes reclaimable whatever the beacon does.
// RefundOpensAt does that arithmetic; this returns the raw height so a caller can also
// show how long the window has been waiting. Zero on an uncommitted window, which is
// exactly the "no refund clock is running yet" case.
//
// THERE IS NO SPONSORED ELEMENT, unlike the raffle's nine-tuple: this realm's pot is
// entry money only, so "pot minus sponsored" — the number a raffle buyer needs to know
// which part of the pot is a claim of theirs — is just the pot.
func DrawOf(window int64) (bool, int64, int64, int64, bool, address, bool, int64) {
	d := getDraw(window)
	if d == nil {
		return false, 0, 0, 0, false, address(""), false, 0
	}
	return d.Committed, d.FrozenTotal, d.Round, d.Pot, d.Resolved, d.Winner, d.Abandoned, d.CommittedAt
}

// RefundGraceBlocks is refundGraceBlocks, EXPORTED so a front end can state the window
// without hardcoding it. Read refundGraceBlocks for what it means and how it was
// derived.
func RefundGraceBlocks() int64 { return refundGraceBlocks }

// RefundOpensAt is the chain height from which Refund will pay this window's buyers
// REGARDLESS OF THE BEACON: CommittedAt + refundGraceBlocks.
//
// ZERO MEANS "THERE IS NO FUTURE HEIGHT TO WAIT FOR", which covers four unrelated
// states and a caller must not read any of them as "refundable now": no record for the
// window, not committed yet (nothing is locked up), already resolved (the pot has gone
// to its winner), or already abandoned (refunds are open this instant and the height is
// behind us). Render draws the same distinction, as "n/a".
func RefundOpensAt(window int64) int64 {
	d := getDraw(window)
	if d == nil || !d.Committed || d.Resolved || d.Abandoned || d.CommittedAt <= 0 {
		return 0
	}
	return d.CommittedAt + refundGraceBlocks
}

// CapturedRandomness returns what Capture stored for a window, or the empty string if
// nothing was captured. Kept out of DrawOf so DrawOf's shape stays stable for callers.
func CapturedRandomness(window int64) string {
	d := getDraw(window)
	if d == nil {
		return ""
	}
	return d.Randomness
}

// OpsPot is the house's EARNED revenue this realm holds, in ugnot: the fees of windows
// that actually drew, plus absorbed donations, plus any swept ticketless window's pot.
//
// IT IS NOT "THE ACCUMULATED HOUSE CUT" ANY MORE, which is what this comment said until
// 2026-09-29. A live window's fee is NOT in here — it is escrowed in that window and is
// still refundable. Read EscrowedCut and HeldCuts, and finding 25.
func OpsPot() int64 {
	return opsPot
}

// EscrowedCut is the house fee held against one window and NOT YET EARNED, in ugnot: it
// becomes ops revenue if that window resolves and goes back to the buyers if it does not.
// Zero for a window that has resolved, been fully refunded, or never sold a ticket.
func EscrowedCut(window int64) int64 {
	d := getDraw(window)
	if d == nil {
		return 0
	}
	return d.Cut
}

// HeldCuts is the total unearned house fee this realm holds across every window, in ugnot
// — the aggregate of EscrowedCut and the third term in the solvency equality.
func HeldCuts() int64 {
	return heldCuts
}

// --- enumerating the windows ---------------------------------------------
//
// WHY A LISTER EXISTS AT ALL. Every other read here needs a window number the caller
// already has, and Render is prose. AND AT AN HOURLY CADENCE THE NEED IS SHARPER THAN
// IN THE WEEKLY REALM: 24 windows a day accumulate, most of them settled promptly and
// some of them not, so a front end looking for the windows that still need a Commit, a
// Resolve or a Refund has a real list to walk. Same shape as
// r/splash/arcade/raffle's Weeks and r/splash/arcade/duel's OfferIDs, down to the
// clamp: an offset and a limit in, at most `limit` window numbers out, `limit` clamped
// to PageLimit rather than refused. Window numbers only — DrawOf and
// TicketTotalOfWindow are the per-window readers, and a batched row reader would mean
// inventing a second serialisation of the same page for callers to parse.

// PageLimit is the most window numbers one Windows call returns. A larger limit is
// clamped to it, not refused.
const PageLimit int64 = 100

// WindowCount is the number of windows that have a record: the windows that sold at
// least one ticket. O(1); avl keeps its size.
func WindowCount() int64 {
	return int64(draws.Size())
}

// Windows is a window over the recorded window numbers in ASCENDING ORDER: it skips
// `offset` of them and holds at most min(limit, PageLimit). Empty past the end.
// Negative arguments are a caller error and panic.
//
// Ascending order is window order, not merely key order, because windowKey is
// fixed-width and zero-padded (see keyWidth) — the same property Render relies on.
//
// A CALLER FINDS THE WINDOWS THAT STILL NEED SOMETHING DOING by walking this and
// keeping those where window < CurrentWindow() and DrawOf reports not resolved: those
// need a Commit if not committed, a Resolve once their round is relayed, and a Refund
// past RefundOpensAt if nobody relays it.
func Windows(offset, limit int64) []int64 {
	if offset < 0 {
		panic("speed: negative offset")
	}
	if limit < 0 {
		panic("speed: negative limit")
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
	windows := make([]int64, 0, limit)
	// IterateByOffset is avl's own offset-and-count traversal, O(log n + limit); it is
	// not a full scan followed by a slice.
	draws.IterateByOffset(int(offset), int(limit), func(key string, _ any) bool {
		windows = append(windows, windowOfKey(key))
		return false
	})
	return windows
}

// windowOfKey inverts windowKey. ParseInt reads the zero padding fine; a key that does
// not parse cannot have come from windowKey, so it is a corrupt tree and not a case to
// paper over.
func windowOfKey(key string) int64 {
	window, err := strconv.ParseInt(key, 10, 64)
	if err != nil {
		panic("speed: malformed window key " + key)
	}
	return window
}

// Render is the human-readable view. It ITERATES THE avl.Tree in key order, which is
// window order because windowKey is fixed-width and zero-padded, so the output is
// byte-identical across runs. A Go map here would randomise the order and make the
// rendered state unreproducible.
//
// IT LISTS EVERY RECORDED WINDOW, and at 24 a day that table grows without bound —
// which is the same unbounded growth r/splash/arcade/raffle's Render has at 52 a year,
// reached ~168x faster. It is left unbounded here deliberately rather than silently
// truncated: Windows/PageLimit is the paged reader for a front end, and a Render that
// quietly stopped at N would be a page that lies about the realm's state. If gnoweb's
// response size ever becomes the binding constraint, the right change is an explicit
// "showing the last N of M" line, not a silent cap.
func Render(path string) string {
	i64 := strconv.FormatInt

	out := "# SPLASH hourly draw\n\n"
	out += "A draw every hour: " + i64(windowBlocks, 10) + " blocks, about one hour at ~3.3s a block.\n"
	out += "Tickets are " + i64(TicketPrice, 10) + " ugnot each (wrapped GNOT, 6 decimals: 1 GNOT = 1000000 ugnot).\n"
	out += "The house takes " + i64(houseCutBps, 10) + " bps of each sale; the rest is the prize, and the whole prize is paid to the winner's wallet.\n"
	out += "THE HOUSE FEE IS HELD IN ESCROW PER WINDOW AND IS EARNED ONLY BY A DRAW: a window that is refunded returns the FULL ticket price.\n"
	out += "One ticket is one unit of draw weight here — unlike the weekly raffle, every unit in this realm is bought.\n\n"
	// THE SELF-CONTAINED PROPERTY, SAID ON THE PAGE AND NOT ONLY IN THE SOURCE. A
	// player deciding whether to enter alone deserves to know that the pot is entry
	// money only, because it is exactly what makes playing alone pointless rather than
	// profitable.
	out += "The pot is entry money only: there is no sponsorship and nothing outside this realm can add to it.\n"
	out += "So a sole entrant simply wins their own stake back less the house cut — there is no jackpot to farm.\n\n"
	out += "- current window: " + i64(currentWindow(), 10) + "\n"
	out += "- this window's pot: " + i64(PotSize(), 10) + " ugnot\n"
	out += "- this window's tickets: " + i64(TicketTotal(), 10) + "\n"
	out += "- held across all unresolved windows: " + i64(heldPots, 10) + " ugnot\n"
	out += "- house fees held in escrow, NOT yet earned and still refundable: " + i64(heldCuts, 10) + " ugnot\n"
	out += "- ops pot (earned): " + i64(opsPot, 10) + " ugnot\n"
	out += "- windows recorded: " + strconv.Itoa(draws.Size()) + "\n"
	out += "- current chain height: " + i64(runtime.ChainHeight(), 10) + "\n"
	// THE TWO NUMBERS A BUYER OF A STUCK WINDOW NEEDS. The grace window is stated once
	// here and the per-window table below gives the height it lands on, so a front end
	// can tell a buyer when their money becomes reclaimable even if nobody ever relays
	// their round. See refundGraceBlocks.
	out += "- refunds open unconditionally " + i64(refundGraceBlocks, 10) +
		" blocks after a window is committed (about " + i64(refundGraceWindows, 10) +
		" hours), whatever the beacon does\n"
	// THE PIN, ON THE PAGE, because the honesty of the draw rests on it and a reader
	// should not have to read the source to find the number.
	out += "- each window's beacon round is pinned " + i64(pinOffsetRounds, 10) +
		" drand rounds ahead when the window opens (" + i64(pinOffsetRounds*beacon.PeriodSeconds, 10) +
		" seconds), so it is signed after entries close\n"

	if draws.Size() == 0 {
		out += "\nNo tickets have been sold yet.\n"
		return out
	}

	out += "\n| window | tickets | pot | escrowed fee | committed | round | captured | winner | abandoned | refund opens at |\n"
	out += "|---|---|---|---|---|---|---|---|---|---|\n"
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
		// ABANDONED IS SHOWN, and shown separately from the winner column: a reader must
		// be able to tell a window still waiting for its randomness from one that is
		// refunding and will never be drawn.
		abandoned := "no"
		if d.Abandoned {
			abandoned = "yes"
			if !d.Resolved {
				winner = "refunding"
			}
		}
		// THE HEIGHT A BUYER CAN STOP WAITING AT, per window. "n/a" on a window with no
		// refund clock running: uncommitted (nothing is locked yet), already resolved
		// (the pot has gone to its winner), or already abandoned (refunds are open now
		// and this number is behind us). A bare height rather than a countdown, because
		// Render must be byte-identical for the same state.
		refundOpens := "n/a"
		if d.Committed && !d.Resolved && !d.Abandoned && d.CommittedAt > 0 {
			refundOpens = i64(d.CommittedAt+refundGraceBlocks, 10)
		}
		out += "| " + i64(d.Window, 10) +
			" | " + i64(total, 10) +
			" | " + i64(d.Pot, 10) +
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
