// Package garden is Gnotchi's pet realm, v6: the free, allowlisted, drand-rolled, hold-many
// realm MINT.md designs end to end. It inherits garden/v4's machinery -- the SaveDay shape,
// meters, garden plots, levels, and the List/Buy/Cancel trading surface -- but NOT v4's
// invariants (MINT.md section 6). garden/v4 is live, immutable and untouched by this file; its
// two gnomes stay exactly where they are forever (MINT.md section 6, BATCH-ONE.md section 0).
//
// ============================================================================================
// WHAT v6 IS: v5 PLUS EXACTLY TWO FIXES, AND NOTHING ELSE. READ THIS FIRST.
// ============================================================================================
//
// garden/v5 is DEPLOYED AND LIVE on the onyx testnet. v6 exists because a review on 2026-10-16
// found a hole that the original design, the test suite and the adversarial security review
// (ATTACK-REVIEW.md, eight attack goals) all missed -- not a vulnerability, a MISSING FEATURE
// that contradicts something the owner asked for in his own words. This file is a DELIBERATELY
// NARROW, SURGICAL COPY of v5. Every line of v5 that is not one of the two fixes below is
// carried forward byte-for-byte, including every comment recording why something is shaped as
// it is and the three real defects mutation testing found and fixed. v5 survived a security
// audit; every unrelated change made here would be a change that has not been audited, so none
// was made. If you are about to "also improve" something while reading this file: don't. Write
// a v7.
//
// FIX 1 -- A v5 GNOME CANNOT HAVE A NAME, AND THE GAME NEEDS ONE.
//
//	v5's gnome struct has no name field, no setter, and `character` -- the only identity string
//	it carries -- is "" for every gnome outside the three capped one-of-ones. Confirmed on the
//	LIVE CHAIN, not inferred: `GnomeByToken("0000002")` on the deployed v5 returns
//	character "". So 21 of Batch One's 24 gnomes would have been permanently anonymous, with no
//	way ever to fix it, because the realm is immutable.
//
//	That directly contradicts the owner's own instruction that in-game characters "should
//	refer to you as your gnome name" -- the adventure's whole NPC dialogue surface is built on
//	a name existing. v5's own package doc argued the opposite ("NO PLAYER-CHOSEN NAME... the
//	app is free to let an owner caption their own gnome off chain"), and that argument was
//	WRONG in one specific, load-bearing way worth recording rather than quietly deleting: an
//	off-chain caption is not an identity. It cannot travel with the token through a sale, it
//	cannot be read by another realm, it cannot be reserved against impersonation, and the
//	adventure realm cannot greet you by it. The reasoning that was right -- that nothing
//	should be CHOSEN at mint time -- is preserved exactly: see SetName below.
//
//	THE SHAPE, AND WHY. Naming is a SEPARATE ACT, AFTER the roll, never part of it. `Claim`
//	still takes no arguments and `Settle` still takes no name: the entire point of the mint is
//	that you do not choose what you get (MINT.md section 1a/section 2), and nothing here
//	weakens that. Naming what you already got is a different act entirely, performed by a
//	different function, at a different time, by the token's current owner only.
//
// FIX 2 -- v5 NEVER STORED THE DRAND ROUND THAT PRODUCED EACH GNOME.
//
//	v5 emits the settling round in its `Settle` event and then forgets it. "Which round made
//	this gnome" was therefore a transaction-log archaeology problem rather than a state read:
//	`Provenance` returns adoptedAt/acquiredAt/saleCount and there was no getter for the round
//	at all. Since "provably unrigged" is this project's headline claim (ECONOMY.md section 1),
//	a holder being unable to verify their own gnome with one query was a gap between what the
//	project says and what the chain can answer. v6 stores the round on the gnome itself
//	(gnome.settledRound) and exposes it (SettledRound). See settleCore.
//
// ============================================================================================
//
// WHAT CHANGES FROM v4, IN ONE TABLE, EACH CITED TO THE DOCUMENT THAT DECIDED IT:
//
//   - Adopt(name, hat, coat, eyes, nose) is GONE. Nothing is chosen by a caller any more.
//     DECISIONS.md 2026-10-15 deprecates the DIY picker as a product direction; MINT.md
//     section 1a/section 2 replace it with a roll.
//   - An ALLOWLIST gates who may ever claim (MINT.md section 11: "gate issuance, never the
//     secondary market"). Admin-managed, additive and removable, never touching the mint
//     itself once a claim has spent its roll.
//   - ONE ROLL PER WALLET, FOREVER, enforced independently of whether the resulting gnome is
//     still held (MINT.md section 1a/section 2.3). hasRolled is permanent; nothing in this file
//     clears it, and selling the gnome does not refund the roll.
//   - FREE. Claim refuses coins exactly as v4's Adopt refuses them (MINT.md section 1a/2.5,
//     GAMES.md rule 6: "random when earned, exact when bought... free: random is allowed").
//   - THE ROLL IS TWO-PHASE, SETTLED BY DRAND (MINT.md section 10, the load-bearing finding of
//     this whole file). A single-transaction roll is peekable two ways, verified against
//     gno.land's own source and binary rather than assumed from Ethereum's model: vm/qeval can
//     call a crossing function for free with no signature, and `gnokey maketx call -simulate
//     only` previews a real signed call against the last committed block with no gas and no
//     broadcast. Neither tool is the cause; the cause is that gno.land exposes NO on-chain
//     entropy at all -- chain/runtime has ChainHeight and nothing else, math/rand is PCG seeded
//     (0,0) on every node forever, and there is no shipped VRF -- so any single-transaction
//     formula, however it is dressed up, is something a caller can evaluate offline for every
//     block it might land in before ever deciding to broadcast. The fix MINT.md section 10.5
//     settles on, and this file builds, is a commit/reveal split across this project's own
//     deployed drand verifier: Claim spends the one-time roll and pins a ROUND THAT DOES NOT
//     EXIST YET; Settle, permissionless, computes the result once that round is actually
//     published. One player signature, not two -- the player signs Claim only.
//   - PARTS FROM A WEIGHTED TABLE (ECONOMY.md section 3), not a player's choice, with three
//     named one-of-ones (Hob, Thistle, Wick -- BATCH-ONE.md section 7) capped at one each.
//   - COUNTED RARITY. Every part's population is tracked on chain and readable by anyone --
//     MINT.md section 13's "nine gnomes in the world have this nose" has to be a chain fact,
//     and EyesCount/NoseCount/HatCount/CoatCount below are that fact, not an app claim layered
//     on top.
//   - MINT ONE, HOLD MANY, PLAY ONE (MINT.md section 2a). Buy's one-gnome-per-address refusal is
//     GONE -- deliberately, and only from Buy, never from Claim (see Claim's hasRolled gate,
//     which is the cap that still matters). An address may hold any number of gnomes; exactly
//     one is ever AWAKE, tracked by activeToken, and only the awake one can ever gain a cared
//     day, a streak, a level or XP. SaveDay and ChooseType resolve through activeToken, never
//     through "the" gnome for an address, because there no longer is one.
//   - SWITCHING (Wake) is free, at most once per UTC day (MINT.md section 2a), the same
//     day-boundary discipline SaveDay's own dailyCareDay already uses.
//   - THE SECONDARY MARKET IS OPEN: Buy/List/Cancel carry over v4's shape and fee (MINT.md
//     section 11), with no allowlist on buying and no hold cap.
//   - THE LOCK: the three named one-of-ones cannot be listed until they have lockCaredDays
//     cared days; every ordinary gnome trades from day one (MINT.md section 12/13, "Option A" --
//     lock only the named one-of-ones, recommended there and NOT YET CONFIRMED BY THE OWNER,
//     which is why lockCaredDays is one named constant and nothing else in this file assumes
//     its value). A gnome's own caredDayCount never decreases and is not reset by Buy, so once
//     a named gnome unlocks it stays unlocked through every future sale.
//   - A GENESIS GNOME, minted to this realm's own address at deploy, non-transferable, never
//     listable, separate from the 24-gnome batch (DECISIONS.md 2026-10-15: "the genesis gnome
//     belongs to nobody, permanently, on purpose"). Its name is not yet settled anywhere in this
//     project's documents; genesisGnomeName below is a placeholder, named as one.
//
// WHAT IS DELIBERATELY OUT OF SCOPE FOR THIS FILE, EACH A SCOPING DECISION MADE BY THIS PASS,
// NOT A GAP IN THE BRIEF THAT ASKED FOR IT. Recorded here in the open the same way MINT.md
// records its own open questions, so a future reader finds the reasoning in one hop:
//
//   - NO SetRule/FreezeRules TUNABLE ADMIN SURFACE. v4's ruleBand/SetRule/FreezeRules machinery
//     is real and proven, but every care-mechanic number below is a fixed constant at v4's own
//     deploy defaults instead. The brief this file was written against lists eleven concrete
//     requirements and none of them is "tunable rules"; adding v4's whole admin-ratchet surface
//     on top of everything already new here would have roughly doubled this file's size and
//     its audit surface for a feature nobody asked for in this pass. A FUTURE VERSION can add
//     it back following v4's own pattern exactly if the owner wants it. (v5 said "a v6" here;
//     v6 exists now and deliberately did not, for the same reason it added nothing else.)
//   - NO NAME AT MINT TIME. This entry REPLACES v5's own "NO PLAYER-CHOSEN NAME" entry, which
//     is the thing v6 exists to correct -- see the "WHAT v6 IS" section at the top of this file
//     for the full account of what that argument got right and what it got wrong. What survives
//     from it, unchanged and non-negotiable: NOTHING IS CHOSEN BY A CALLER AT MINT TIME,
//     INCLUDING A NAME. `Claim` takes no arguments; `Settle` takes no name. v4's
//     validNameRune/validNameCharset/hasVisibleNameContent machinery (three audit rounds' worth,
//     per v4's own comment) is carried back into this file WHOLE, not re-derived, because the
//     naming act moved rather than disappeared -- it is now SetName, callable only by the
//     token's current owner, only after the roll has already irrevocably decided what they got.
//   - NO OpenBatch ADMIN SURFACE. MINT.md section 6 floats an owner-callable OpenBatch for
//     adding future batches' rosters; the task this file was built against names a single
//     24-gnome batch (BATCH-ONE.md) and does not ask for a mechanism to open a second one. The
//     batch here is sized once, at deploy, by the batchCap/numNamedEditions constants below. A
//     FUTURE VERSION is the natural place for OpenBatch if a second batch is ever wanted, the
//     same way every other irreversible-shape decision in this project has gotten its own
//     version rather than a retrofit. (v5 said "a garden/v6 is the natural place"; v6 exists
//     now and deliberately did NOT take that opportunity -- it is two fixes and nothing else.)
//
// A REAL FLAW FOUND AND FIXED WHILE DESIGNING Settle, RECORDED HERE RATHER THAN QUIETLY FIXED
// AND FORGOTTEN -- the same discipline MINT.md section 10 models for its own single-transaction
// finding. An earlier version of this design picked the three named one-of-ones by drawing
// "without replacement" from a shrinking pool: remainingTotal = batchCap - settledCount,
// remainingNamed = 3 - namedAssignedCount, and a claimant's pick = seed % remainingTotal. THAT
// IS PEEKABLE AND GAMEABLE, even though the seed itself is honestly drand-derived and
// unforgeable: because remainingTotal only ever shrinks as OTHER claimants settle, and Settle is
// permissionless and callable at any later time, a claimant whose seed is already fixed (the
// moment their pinned round publishes) can simply precompute, for every possible remainingTotal
// from 1 to batchCap, whether that value would win them a named edition -- and then wait,
// costing nothing, until the rest of the batch happens to settle into a state that does. The fix
// below removes every dependency on shrinking, observable, time-varying state from the decision:
// a claimant's own named-edition pick is `seed % batchCap`, against a modulus that is a
// COMPILE-TIME CONSTANT, not a moving count, so there is nothing left to wait for -- the only
// residual order-dependence is which of possibly several colliding claimants (bad luck, not
// strategy: nobody can change their own pick by choosing when to settle) gets a named edition
// that more than one of them rolled, and that is resolved by whichever Settle call lands on
// chain first.
//
// A SECOND AUDIT PASS NAMED THIS PRECISELY: "settling promptly", said above and in an earlier
// version of Settle's own comment, OVERSTATES what the residual actually rewards. It is not
// "whoever claimed first" or "whoever cared most" -- pendingClaim.claimedAt is never consulted
// by the tie-break, and Settle is permissionless, so a bystander (a searcher, a bribed relayer,
// a claimant's own bot) can win a collision for whichever side pays for transaction-ordering
// priority, regardless of who rolled or claimed first. Considered and rejected: tie-breaking on
// claimedAt instead. It sounds like the honest fix, but it is not reachable without a worse
// trade-off -- Settle finalizes irrevocably (it mints a real token to a real owner, who may
// already have acted on it), so honoring an earlier claimedAt would mean either refusing to
// finalize ANY collision candidate until every possible earlier claimant's round has published
// and settled (reintroducing exactly the wait-and-see window section 10 and this fix exist to
// close, now around a deadline instead of a pool size) or reaching back to UNDO an already-
// settled mint (which nothing in this realm, or any grc721-based realm in this project, has ever
// claimed to be able to do, and which would be a strictly worse property than the one being
// fixed). What actually holds, stated precisely rather than aspirationally: nobody can improve
// THEIR OWN odds by choosing when to settle (the property section 10 is about, and the property
// this fix actually guarantees); the residual is an ordinary transaction-ordering race over a
// LOW-PROBABILITY, LOW-STAKES event (three slots in a batch of 24, decided among whichever
// handful of claimants happen to collide), the same shape of race every permissionless action on
// every chain is already subject to, not a new hole this design opened. See Settle's own comment
// for the arithmetic.
//
// SETTLE CAN NOW PAY FOR ITS OWN BEACON RELAY, OWNER-APPROVED 2026-10-15, THE DAY AFTER THIS FILE
// WAS FIRST WRITTEN. The two-phase roll above depends on beacon/v2 actually having the pinned
// round's drand signature by the time Settle runs, and until this change that was somebody
// else's problem: a relay has to happen, by a human or a bot, running outside this realm and
// outside this project's control, or a claimant who has already spent their one-and-only roll is
// stuck mid-mint through no fault of their own -- found live, not hypothetically, while building
// this file: the project's own beacon was observed ~2 days stale. The fix the owner asked for
// ("can we have the mint transaction pay the beacon though") is `SettleWithSignature` below: the
// player's own app fetches the pinned round's signature from drand's public API (the same
// `https://api.drand.sh/<chain>/public/<round>` this file's own test fixtures are fetched from)
// and passes it straight through; Settle relays it itself, in the same transaction, before
// computing the result. One transaction, and the player pays its gas -- TO THE NETWORK, same as
// any other transaction's gas, NOT to this project, so it never touches the free-mint promise
// (MINT.md section 14: "gas is still a payment, just not to us... the operator takes no stake").
// Three things this buys, in the owner's own order of importance:
//
//   - IT COSTS THE PROJECT NOTHING. The alternative to a player-paid relay is an operator-run one
//     -- a cron job or a bot calling beacon.Publish on a schedule, which is real recurring GNOT
//     spend with no revenue to offset it (MINT.md section 14 forecloses an unlock fee, batch one
//     is free end to end). This change deletes that cost rather than budgeting for it.
//   - A PLAYER CAN NEVER BE BLOCKED BY THIS PROJECT'S OWN HOUSEKEEPING. The stuck-mid-mint state
//     above is now unreachable for anyone willing to fetch their own round's signature: their own
//     Settle call makes the round available, with no dependency on this project, a third-party
//     relay, or anyone else's goodwill.
//   - THE BEACON GETS FRESHER AS A SIDE EFFECT, FOR EVERYONE ELSE USING IT. beacon/v2 is a shared,
//     permissionless, on-demand record (see its own package doc) -- a round this realm's own
//     claimants cause to be published is published for every other consumer of that beacon too,
//     not just for this realm.
//
// THREE THINGS WORKED OUT BY QUERYING THE LIVE CHAIN, NOT ASSUMED, because this is new
// cross-realm write surface and this project's own history (the SPLASH beacon migration,
// MEMORY.md) is built from exactly the kind of interrealm detail that gets guessed wrong:
//
//  1. WHAT beacon.Publish DOES ON AN ALREADY-PUBLISHED ROUND. Fetched byte-for-byte from the live
//     deployed realm itself (gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/beacon/v2) via
//     the public onyx-1 RPC's `vm/qfile` query, 2026-10-15, and diffed identical against this
//     project's own vendored copy at realms/_vendor/beacon/v2/beacon.gno -- it PANICS, it does not
//     no-op: `func Publish(cur realm, round int64, sigHex string) { if Published(round) { panic
//     ("beacon: round already published") } ... }`. SettleWithSignature therefore checks
//     `beacon.Published` itself BEFORE ever calling Publish, exactly once, and never calls Publish
//     at all if the round is already there -- calling it unconditionally would make this function
//     fail every time a relay (another claimant's own SettleWithSignature, or anyone else) beat it
//     to the punch, which given Settle's own permissionless, callable-by-anyone design is an
//     ordinary and expected race, not an edge case.
//  2. THAT Publish IS REACHABLE CROSS-REALM AS `beacon.Publish(cross(cur), round, sigHex)`, and
//     that it carries no caller-identity check at all for this function to trip over. Confirmed
//     two ways: the live source pulled in point 1 shows Publish's body never reads `cur` or calls
//     `cur.Previous()` -- it is permissionless by whoever relays, not merely by whichever address
//     -- and this exact call shape is already proven working, not merely plausible, by this
//     file's OWN test harness: garden_test.gno's `publishAs` helper has called
//     `beacon.Publish(cross(cur), round, sigHex)` from this package since the day this file was
//     written, and every test that calls it passes. SettleWithSignature's own call is the
//     identical shape with `cur` being Settle's own realm parameter instead of a test helper's.
//     (`cur.Previous()` inside beacon.Publish would resolve to THIS realm, garden/v5, when called
//     this way rather than to the human wallet that called Settle -- a real interrealm fact worth
//     recording even though Publish does not currently branch on it: if beacon/v2 ever grows a
//     caller-identity check, re-read this paragraph before assuming Settle's relay still works.)
//  3. GAS. Measured on this toolchain with r/splash/beacon/zz_gas_test.gno's own method
//     (`gno test -run TestZZGas -print-runtime-metrics=true -v`, net of this package's own fixed
//     per-test-call overhead): a bare Settle today costs ~6.2M gas; beacon.Publish alone costs
//     ~18.5M gas on THIS realm's measurement (the same order of magnitude as beacon/v2's own
//     documented 16,970,375, re-measured rather than quoted because toolchain and realm storage
//     both shift it). SettleWithSignature's worst case -- the round not yet published at all --
//     is therefore on the order of ~25M gas total, call it 1% of the 3e9 block gas limit and a
//     few hundredths of a GNOT at this chain's gas price. Reasonable: it is roughly four times a
//     bare Settle, not an order of magnitude more, it still leaves room for well over a hundred
//     such settlements in a single block, and it replaces a cost this project would otherwise have
//     paid itself, recurringly, forever, to keep the beacon fresh by some other means.
//
// THE SHAPE: TWO ENTRY POINTS, ONE SHARED CORE, NOT ONE FUNCTION WITH AN OPTIONAL SIGNATURE.
// `Settle(cur realm, claimant address)` is UNCHANGED in behaviour and UNCHANGED in signature --
// every existing test and every existing caller that already knows (or does not care) whether the
// round is published keeps working exactly as before, at exactly its old gas cost, with no
// signature to fetch or supply. `SettleWithSignature(cur realm, claimant address, sigHex string)`
// is new, and is for a caller that HAS a signature and wants its transaction to publish the round
// if nobody else already has. A Gno realm's exported functions take a fixed argument list -- there
// is no overloading, and an optional/variadic last argument would still force every caller,
// including every test and the app's own simpler "it's already published" path, to pass an empty
// string they have no use for, for a case (publishing) that is the EXCEPTION, not the rule, since
// most settlements land after some earlier claimant or relay has already published the shared
// round. Two named entry points make the exception visible in the function name instead of buried
// in an argument, and cost nothing extra: both share one unexported `settleCore`, so there is
// exactly one copy of the draw-and-mint logic, not two drifting in parallel. And it is SAFE for
// either one to be called in either actual on-chain state: Settle still refuses cleanly, with its
// original message, if the round genuinely is not published yet; SettleWithSignature still
// succeeds, with its supplied signature simply going unused, if the round turns out to already be
// published by the time it runs (point 1's race) -- neither caller has to know in advance which
// state they are in, they only have to know whether they personally HAVE a signature to offer.
package garden

import (
	"strconv"
	"strings"
	"time"
	"unicode"      // v6 fix 1: v4's name charset allowlist, carried back whole. See validNameRune.
	"unicode/utf8" // v6 fix 1: rune counting, never len(). See validNameLength.

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	beacon "gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/beacon/v2"
)

// ============================================================================
// THE THREE SALE CONSTANTS. CARRIED OVER, UNCHANGED, FROM garden/v4's 2026-10-11 DECISION, AS
// PLACEHOLDERS FOR THIS NEW REALM. Nobody has asked the owner to re-confirm these specifically
// for v5 -- re-decide or re-confirm them before ever deploying this file; see gnomod.toml's own
// checklist item 0. init() below still gates them exactly as v4's assertFeeConfig does, so an
// edit to a value that cannot work fails at deploy rather than succeeding silently forever.
// ============================================================================
const (
	saleFeeRecipient  = "g1ylpe9juk8cafgf9rt09wzuz85ug2lyfk5metyv" // gnotchi-opponent, v4's choice
	saleFeeRateBps    = int64(500)                                 // 5% of the declared price
	saleFeeFloorUgnot = int64(1_000_000)                           // 1 GNOT flat minimum per sale
)

// ============================================================================
// Constants that are NOT tunable, and never will be: see the package doc's "out of scope"
// section for why v5 has no SetRule surface at all.
// ============================================================================

const (
	collectionName   = "Gnotchi gnomes"
	collectionSymbol = "GNOME"

	// adminAddress is the only address AdminAllow/AdminDisallow will accept. Compiled in, with
	// no transfer function, for the same reason v4 has none: an admin-transfer path is a second
	// authority path, and a lost admin key merely freezes the allowlist, which is recoverable by
	// redeploying a v6 -- not a disaster.
	//
	// THIS IS THE ONYX TESTNET DEPLOY KEY `gnotchi-deploy`, which is also the namespace this
	// realm deploys under (see gnomod.toml) and the only key on this host with enough GNOT to
	// pay for the admin calls -- AdminAllow and Settle both cost fees, and v4's old key
	// (g1r4aw43..., the retired splash-deploy) is down to dust, so compiling that address in
	// here would have produced an admin that could not afford to act. Correct for onyx, wrong
	// for anywhere real. Change it before deploying anywhere that matters; see gnomod.toml.
	adminAddress = "g1nq99m3h9ed7vqve6ajpr3qwy2ls252m8jnundm"

	// numEyes / numNoses / the hat and coat catalogues: THE SAME FOUR-DIMENSIONAL FACE SPACE
	// garden/v4 uses (SPRITES.md's Phase 1: 10 eyes x 8 noses x 4 hats x 4 coats = 1,280 looks).
	// Nothing here is a new catalogue; eyesWeights/noseWeights below are a weighted DRAW over
	// the same ids v4 already validates, per ECONOMY.md section 3 and MINT.md section 13's
	// counted-rarity decision ("no tiers... rarity becomes population frequency counted on
	// chain"). hat and coat are drawn UNIFORMLY (25% each): ECONOMY.md section 3 only specifies
	// weights for the "permanent pair" (eyes, nose), and BATCH-ONE.md section 4a says so
	// explicitly -- "assigning the section 3 percentages to hat and coat as well... is real work
	// this document does not do... flagged here as the next thing to specify". A uniform draw is
	// the honest placeholder until that work happens, not a guess dressed up as one.
	numEyes  = int64(10)
	numNoses = int64(8)

	// hourSeconds/daySeconds: unchanged from v4.
	hourSeconds = int64(3600)
	daySeconds  = int64(86400)

	// ---- care-mechanic constants, fixed at v4's own deploy DEFAULTS (v4's ruleBands table).
	// See the package doc: v5 deliberately carries no tunable-rules admin surface.
	numPlots        = 3        // acorns.plots
	plantCost       = int64(1) // acorns.plantCost
	feedCost        = int64(1) // acorns.feedCost
	acornsStart     = int64(10)
	meterMax        = int64(10)
	patCheer        = int64(3)
	hungryAtOrBelow = int64(2)

	growHours           = int64(24)
	patCooldownHours    = int64(12)
	tinkerCost          = int64(5)
	levelBase           = int64(50)
	levelStep           = int64(25)
	sulkyPenaltyPct     = int64(10)
	harvestPerPlot      = int64(3)
	feedBelly           = int64(4)
	bellyDropEveryHours = int64(3)
	cheerDropEveryHours = int64(6)
	dailyCareCap        = int64(60)

	// acornReserve: v4's fix for the acorn softlock (AUDIT-DEPLOYED.md G9), carried over
	// unchanged. See v4's own constant for the full argument; the short version is that a
	// SaveDay batch that spends acorns may never end with fewer than this and nothing planted.
	acornReserve = plantCost + feedCost

	happyBonusPct    = int64(10)
	happyWindowHours = int64(2)
	sulkyAfterHours  = int64(72)
	maxLevel         = int64(20)
	typeAtLevel      = int64(5)

	xpPat            = int64(5)
	xpFeed           = int64(5)
	xpHarvestPerPlot = int64(10)
	xpTinkerTask     = int64(15)

	maxActionsPerCall = 32
	maxBackfillHours  = int64(48)
	caredWindowDays   = uint(64)

	maxGnomesPageSize   = 100
	maxListingsPageSize = 100

	// ---- the sale. Shape constants, unchanged from v4.
	ugnotDenom     = "ugnot"
	maxPriceUgnot  = int64(1_000_000_000_000_000)
	maxFeeRateBps  = int64(10_000)
	maxListingDays = int64(30)

	moodHungry  = "hungry"
	moodSulky   = "sulky"
	moodHappy   = "happy"
	moodContent = "content"

	actionPat     = "pat"
	actionFeed    = "feed"
	actionPlant   = "plant"
	actionHarvest = "harvest"
	actionTinker  = "tinker"

	typeGardener = "gardener"
	typeExplorer = "explorer"
	typeTinkerer = "tinkerer"

	// ============================================================================
	// THE MINT: allowlist, one roll per wallet, the batch, the lock, the drand pin. Every
	// number below is a single named constant, each trivially changeable, per the brief's own
	// instruction for the lock specifically and applied here to the pin offset too.
	// ============================================================================

	// batchCap: BATCH-ONE.md's own roster -- 24 gnomes, total, forever, this batch. 21 ordinary
	// plus three named one-of-ones (numNamedEditions below). Closed the instant mintedCount
	// reaches this; nothing in this file can ever raise it (no OpenBatch -- see the package
	// doc's "out of scope" section).
	batchCap = int64(24)

	// numNamedEditions: Hob, Thistle and Wick (namedEditionOrder below), cap ONE EACH. "Cap 1" is
	// not a different mechanism from any other cap, MINT.md section 3's own point -- it is the
	// same characterOwner.Has check any other population cap would use, just at the number one.
	numNamedEditions = 3

	// lockCaredDays: MINT.md section 12/13's RECOMMENDATION, explicitly not yet confirmed by the
	// owner ("Option A... this is a recommendation, not a decision"). The three named one-of-ones
	// cannot be listed until they have this many cared days; every ordinary gnome trades from
	// day one. One named constant, nothing else in this file assumes 30 specifically.
	lockCaredDays = int64(30)

	// ============================================================================
	// v6 FIX 1: THE NAME. maxNameLen is v4's own constant at v4's own value, kept in step with
	// app/js/config.js's NAME_MAX_LEN (24) by hand, because Gno has no way to read that file at
	// build time -- the same hand-maintained pairing v4 documented and v6 inherits. The app's
	// NAME_RULE.MAX_LEN must equal this number; TestMaxNameLenMatchesTheAppsRule pins the value
	// so a change here fails a test rather than silently diverging from the one rule the app
	// shows a player before they pay gas.
	// ============================================================================
	maxNameLen = 24

	// pinOffsetSeconds / pinOffsetRounds: how far into drand's future Claim pins a round, sized
	// AS SECONDS, from drand evmnet's own period (beacon.PeriodSeconds, re-exported from this
	// project's own bls254 package, not restated here), per MINT.md section 10.5's explicit
	// instruction -- never as a round count checked only against a block count, which is the
	// exact dimensional trap this project's own history (the SPLASH raffle shipping with a 100x
	// wrong round/block ratio, MEMORY.md) says cost real time once already. 60 seconds is twenty
	// drand rounds at the 3-second period CurrentRound() at Claim time is comfortably able to
	// pin as "not yet signed by anyone, including drand itself" -- see Claim's own comment for
	// why the margin matters even though CurrentRound() is pure arithmetic over block time, not
	// a relay-dependent estimate.
	pinOffsetSeconds = int64(60)
)

// pinOffsetRounds is a const expression over an imported const (beacon.PeriodSeconds), which Gno
// permits across package boundaries exactly as it would within one; TestPinOffsetIsTwentyRounds
// pins the arithmetic rather than trusting the comment above.
const pinOffsetRounds = pinOffsetSeconds / beacon.PeriodSeconds

// kindEnd-style ratchet machinery: deliberately absent. See the package doc.

// hatOptions / coatOptions: v4's validHats/validCoats catalogue, as an ORDERED array rather than
// a set, because Settle needs to draw a POSITION, not merely validate one. Order is frozen the
// moment this realm deploys, exactly as v4's own numEyes/numNoses ordering is frozen -- a part
// may be redrawn; it may never be reordered, removed or renumbered (v4's own comment on this).
var hatOptions = [4]string{"red", "purple", "green", "navy"}
var coatOptions = [4]string{"blue", "teal", "orange", "brown"}

// eyesWeights: ECONOMY.md section 3, verbatim -- "eyes across 4 colours at 15%, 3 at 9%, 2 at
// 5%, 1 at 3%" -- 4+3+2+1 = 10 entries = numEyes, and 4*15+3*9+2*5+1*3 = 100.
// TestWeightTablesSumToOneHundred pins the sum rather than trusting the arithmetic in this
// comment; drawWeighted's own fallback additionally makes a drift here fail safe, not silently.
var eyesWeights = [10]int64{15, 15, 15, 15, 9, 9, 9, 5, 5, 3}

// noseWeights: ECONOMY.md section 3 says only "nose similar across 8 shapes" and gives no exact
// percentages -- BATCH-ONE.md section 4a names this directly as real work nobody has done yet.
// This is a SHAPE-FAITHFUL INTERPRETATION, not a transcription: four tiers of two shapes each,
// 20/20/15/15/10/10/5/5, the same big-gap-then-smaller-gaps shape eyesWeights has, scaled to 8
// entries and summing to 100. Flagged here, not quietly presented as sourced, so the owner or a
// future author can replace it with real numbers the moment ECONOMY.md section 3 gets them.
var noseWeights = [8]int64{20, 20, 15, 15, 10, 10, 5, 5}

// namedEditionOrder: BATCH-ONE.md section 7's three names, in the fixed order Settle's
// namedPick indexes into. The order carries no meaning -- it is not a ranking -- it only has to
// be fixed, which it is, forever, the moment this realm deploys.
var namedEditionOrder = [numNamedEditions]string{"hob", "thistle", "wick"}

// namedEditionDisplayNames: BATCH-ONE.md section 7's three names AS THEY ARE WRITTEN -- "Hob,
// Thistle, Wick", the form this file's own documentation uses throughout -- paired by index with
// namedEditionOrder above.
//
// WHY A SECOND ARRAY RATHER THAN JUST CAPITALISING namedEditionOrder, which is the change a
// reviewer will reach for first: namedEditionOrder's values are not labels, they are KEYS.
// settleCore writes characterOwner.Set(character, ...) and tests characterOwner.Has(candidate)
// with those exact strings, and the public CharacterOwner(name) reader does a raw tree Get with
// no case folding at all -- so CharacterOwner("hob") resolving is a chain fact that an
// off-chain caller already depends on, and init() registers the genesis gnome under the matching
// lowercase key "genesis". Capitalising namedEditionOrder would move those keys to "Hob" while
// leaving "genesis" lowercase, break CharacterOwner("hob") for every existing caller, and it is
// unfixable after deploy. The keys stay canonical.
//
// This array exists ONLY to supply the gnome's `name`, which is a DISPLAY STRING and has always
// been a different thing from its canonical key -- see canonicalNameKey's own comment on why the
// stored form and the uniqueness key are deliberately two strings. nameOwner is still keyed by
// canonicalNameKey(name), which folds "Hob" to "hob", so reservedNameKeys and the uniqueness
// index are untouched by this: no new mechanism, just the display side of a separation that was
// already here. TestNamedEditionDisplayNamesPairWithTheirCanonicalKeys pins the pairing in both
// directions, so an edit to either array that breaks it fails a test rather than shipping a
// one-of-one whose display name canonicalises to somebody else's key.
var namedEditionDisplayNames = [numNamedEditions]string{"Hob", "Thistle", "Wick"}

// namedEditionDisplayName maps a named edition's canonical character key to its display name.
// Used by settleCore's mint and mirrored by the test fabricator, so there is exactly one copy of
// the mapping. Returns the input unchanged for anything that is not one of the three editions --
// which is unreachable from settleCore (it only ever passes a namedEditionOrder entry) and is a
// pass-through rather than a panic because this is a label lookup, not a security boundary.
func namedEditionDisplayName(character string) string {
	for i, canonical := range namedEditionOrder {
		if canonical == character {
			return namedEditionDisplayNames[i]
		}
	}
	return character
}

// genesisGnomeName: DECISIONS.md 2026-10-15 settles the MECHANISM (minted to this realm's own
// address, non-transferable, never listable, separate from the batch) but never settles a NAME
// anywhere in this project's documents. Placeholder, named as one; change it freely before
// deploying.
//
// CHANGED FROM v5 IN ONE RESPECT, deliberately: v5's comment ended "it is read by nothing else
// in this file", which was true there and is NOT true here. v6 fix 1 writes this string into the
// genesis gnome's own `name` field at init() and registers its canonical key in nameOwner, so
// changing it also changes which name is taken. It must still canonicalise to one of
// reservedNameKeys below, or an ordinary gnome could be named "Genesis" and pose as it --
// TestGenesisNameIsReserved pins exactly that, so an edit here that breaks the pairing fails a
// test rather than shipping.
const genesisGnomeName = "Genesis"

// reservedNameKeys: the canonical name keys NO ORDINARY GNOME MAY EVER TAKE -- the three named
// one-of-ones (BATCH-ONE.md section 7's roster, re-read rather than assumed: Hob, Thistle, Wick)
// plus the genesis gnome. Checked by SetName; see assertNameAssignable.
//
// WHY THIS EXISTS SEPARATELY FROM THE nameOwner UNIQUENESS INDEX, which is the subtle part and
// the reason a reviewer should not "simplify" one of the two away: the uniqueness index only
// protects a name that is ALREADY TAKEN BY A LIVING TOKEN. Hob's cap-one edition may not have
// been minted yet -- its namedPick is a pure function of a drand round nobody has rolled -- and
// for the whole window before it mints, nameOwner has no "hob" key at all. Without this list,
// the FIRST ordinary claimant could name their gnome "Hob", take the key, and the real Hob would
// then mint into a collection where its own name already belongs to an impostor. Reservation
// covers the pre-mint window; uniqueness covers the post-mint one. Both are needed, and together
// they are the "two locks on a door" discipline this file already uses for the genesis gnome.
//
// Every entry is already in canonical form (lowercase, single-spaced, trimmed), and
// TestReservedNameKeysAreCanonical pins that -- a non-canonical entry here would be a key
// canonicalNameKey could never produce, i.e. a reservation that silently protects nothing.
var reservedNameKeys = [numNamedEditions + 1]string{"hob", "thistle", "wick", "genesis"}

// ============================================================================
// Storage
// ============================================================================

// plot: unchanged from v4. plantedAt == 0 is the empty state; readyAt is stored, not computed,
// so a future change to growHours (there is none possible in this file, but the shape is kept
// for the day a v6 adds tuning back) could never reach backwards into an already-planted plot.
type plot struct {
	plantedAt int64
	readyAt   int64
}

// gnome is the whole persisted pet. EVERY FIELD HERE HAS AN EXPORTED READER -- v4's own rule,
// carried over verbatim: a realm cannot grow a second chance at this after deploy.
//
// NOT HERE, DELIBERATELY: a hat/coat the OWNER chose (nothing is chosen at mint any more;
// hat/coat are ROLLED exactly as eyes/nose are, and are exactly as permanent as eyes/nose always
// were in v4 -- there has never been a function anywhere in this family of realms that changes a
// gnome's hat or coat after mint). v5's own comment also listed "a name" here; v6 fix 1 is
// precisely the correction of that, and `name` is below.
//
// character is "" for every ordinary gnome and one of namedEditionOrder's three strings for a
// named one-of-one. eyes/nose/hat/coat are the sentinel -1/-1/""/"" for a named edition: its
// look is NOT a point in the ordinary 1,280-look space, it is BATCH-ONE.md section 6's own new
// art (Hob's crown and gold coat, Thistle's helmet and axe, Wick's lantern), which this contract
// does not need to know the pixels of -- only that Character(tokenID) names it, so the app can
// render the right thing. A named edition's parts are therefore never counted in
// eyesCounts/noseCounts/hatCounts/coatCounts: it is already as rare as a thing can be, at cap
// one, counted instead through characterOwner.
type gnome struct {
	hat       string
	coat      string
	eyes      int64
	nose      int64
	character string

	// name: v6 FIX 1. The gnome's own name, as its owner typed it, byte-for-byte -- this realm
	// NEVER rewrites it (see canonicalNameKey's own comment on why the stored form and the
	// uniqueness key are deliberately two different strings).
	//
	// "" means UNNAMED, which is the state EVERY ordinary gnome is minted in and stays in until
	// its owner calls SetName. That is not an oversight to be fixed by defaulting it to
	// something: a gnome with no name yet is honestly nameless, and inventing "Gnome #7" on
	// chain would make a fabricated string indistinguishable from a chosen one forever.
	//
	// For the THREE NAMED ONE-OF-ONES and for the GENESIS GNOME this is set ONCE, at mint, to
	// their own character name, and SetName refuses them permanently (their identity is the
	// whole point of them -- see SetName's own guard). So `name != ""` does not imply "an owner
	// chose this"; `character == ""` is the test for that.
	name string

	// settledRound: v6 FIX 2. The drand round whose published signature produced this gnome's
	// parts -- the single number that makes "provably unrigged" (ECONOMY.md section 1) checkable
	// by a holder in one state read instead of a transaction-log search. Written once, in
	// settleCore, from the pendingClaim's own pinned round; never written again by anything.
	//
	// 0 means "not produced by a roll at all", which is true of exactly one token for the whole
	// life of this realm: the genesis gnome, minted directly in init() and never rolled for. A
	// caller can tell the two apart without ambiguity because round 0 is not a real drand round
	// and never will be.
	settledRound int64

	level     int64
	gnomeType string
	adoptedAt int64 // unix seconds; the moment Settle minted this gnome, or init() for genesis

	belly   int64
	bellyAt int64
	cheer   int64
	cheerAt int64

	lastPatAt        int64
	lastHappyEventAt int64

	totalXp int64

	xpGarden     int64
	xpTinker     int64
	harvestCount int64

	dailyCareXp  int64
	dailyCareDay int64

	plots [numPlots]plot

	lastTinkerAt int64

	// Cared days. v4's own shape, unchanged: the chain stores FACTS (which UTC days were
	// cared for), never the STREAK RULE, which stays in app/js/rules.js's streakFrom. See
	// v4's gnome struct comment for the full argument; it applies here without edit.
	caredDayCount int64
	lastCaredDay  int64
	caredMask     uint64

	lastActionAt int64

	// lastWokenAt: unix seconds, the moment THIS token last became somebody's active gnome --
	// set at mint (settleCore), at purchase (Buy), and at every explicit Wake, always to "now" at
	// that moment, never anything earlier. SaveDay's backfill floor is max(lastActionAt,
	// lastWokenAt, now-48h): a token cannot be credited for any period before it was actually the
	// active one, closing the gap ATTACK-REVIEW.md goal 7 found -- v4 never needed this field
	// because v4 enforced one gnome per address, so there was no second token to backfill against
	// while this one slept. See SaveDay's own comment for the full argument.
	lastWokenAt int64

	acquiredAt int64
	saleCount  int64
}

// listing: unchanged in shape from v4, now simply one of possibly SEVERAL a single owner may
// have standing at once (mint one, hold many) -- listings is still keyed by tokenID, which was
// always the right key for this and needed no change.
type listing struct {
	seller     address
	priceUgnot int64
	buyer      address
	listedAt   int64
	expiresAt  int64
}

// feeConfig: unchanged from v4.
type feeConfig struct {
	recipient  address
	rateBps    int64
	floorUgnot int64
}

// pendingClaim is the record Claim writes and Settle consumes: the permanent, irrevocable fact
// that this address spent its one roll, and the future drand round it is waiting on.
type pendingClaim struct {
	round     int64
	claimedAt int64
}

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger

	nextID seqid.ID

	gnomes = avl.NewTree() // tokenID -> *gnome

	// ownerTokens: owner address -> *[]string, every tokenID that address currently holds.
	// MINT.md section 2a's "hold many": v4 never needed this because v4 never let an address
	// hold more than one. See addOwnerToken/removeOwnerToken.
	ownerTokens = avl.NewTree()

	// activeToken: owner address -> tokenID string, the ONE gnome that is awake for that
	// address right now. Absent means "nothing awake" -- reachable only for an address that has
	// never settled a claim or bought a gnome, or that has sold its only awake gnome and not yet
	// woken another (Buy deliberately does not auto-promote a replacement; see Buy's comment).
	activeToken = avl.NewTree()

	// lastWakeDay: owner address -> int64 UTC day number, the once-per-day gate on Wake.
	lastWakeDay = avl.NewTree()

	// lastCaredDayForOwner: owner address -> int64 UTC day number, the most recent calendar day
	// on which ANY ONE of this owner's tokens has already banked a cared day. The package doc is
	// explicit and unconditional: "exactly one is ever AWAKE... and only the awake one can ever
	// gain... a cared day" (see this file's own doc comment). lastWokenAt (see the gnome struct)
	// closes the BACKFILL half of ATTACK-REVIEW.md goal 7 -- a token cannot backfill a day it
	// spent asleep. This tree closes the LIVE half: without it, an owner could Wake(B) partway
	// through a UTC day already spent genuinely caring for A, then genuinely care for B too,
	// using only real-time, non-backfilled timestamps, and bank the SAME calendar day on BOTH --
	// no backfill panic ever fires, because neither action is backfilled, each is simply real
	// care given to whichever gnome was actually awake at the time. That still doubles the one
	// property this bookkeeping exists to measure (lockCaredDays' 30-day resale lock, and the
	// public cared-days streak), for one wallet, once per day, for as many tokens as the owner is
	// willing to switch through -- the exact harm goal 7 names, reached by a second, undiscovered
	// mechanism. recordCaredDay only ever runs, and this tree only ever advances, when the day
	// being recorded is NEWLY banked for this OWNER, not merely newly banked for this TOKEN.
	lastCaredDayForOwner = avl.NewTree()

	balances = avl.NewTree() // owner address -> int64 acorns, per PLAYER, exactly as v4

	listings = avl.NewTree() // tokenID -> *listing

	// allowlist: owner address -> true. Admin-managed (AdminAllow/AdminDisallow), gates Claim
	// only -- MINT.md section 11: "gate issuance, never the secondary market". Buying and
	// selling need no entry here at all.
	allowlist = avl.NewTree()

	// hasRolled: owner address -> true, PERMANENT, never removed by anything in this file. "One
	// roll per wallet, forever" (MINT.md section 1a/2.3), independent of whether the resulting
	// gnome is still held, independent of whether the address is later removed from the
	// allowlist. Disallowing an address after it has rolled does not and cannot un-roll it.
	hasRolled = avl.NewTree()

	// pendingClaims: owner address -> *pendingClaim. Written by Claim, removed by Settle. At
	// most one per address, because hasRolled already refuses a second Claim from the same one.
	pendingClaims = avl.NewTree()

	// eyesCounts / noseCounts / hatCounts / coatCounts: counted rarity (MINT.md section 13).
	// Keyed by the part's own id/name, value is a lifetime population count, incremented only by
	// an ORDINARY Settle (never by a named one-of-one, which is counted separately below, and
	// never decremented: there is no burn, and a sale moves a part without minting one).
	eyesCounts = avl.NewTree()
	noseCounts = avl.NewTree()
	hatCounts  = avl.NewTree()
	coatCounts = avl.NewTree()

	// nameOwner: v6 FIX 1, the uniqueness index. canonicalNameKey(name) -> tokenID. A key is
	// present if and only if exactly one living token currently carries a name that canonicalises
	// to it, which is what makes "names are unique across the collection" a chain fact rather
	// than an app convention.
	//
	// IT IS KEYED ON THE CANONICAL FORM, NOT THE TYPED FORM, and that is the whole point: with a
	// raw-string key, "Hob", "hob", "HOB" and "Hob " are four different keys, so uniqueness would
	// be worth nothing and the one-of-one reservation below could be walked straight around by
	// changing one letter's case. See canonicalNameKey.
	//
	// RENAMING FREES THE OLD KEY, and that is REQUIRED, not a convenience. If SetName only ever
	// added keys, a single token could lock up an unbounded number of names by renaming over and
	// over -- one gnome, one transaction each, every good name in the collection permanently
	// unavailable to everybody else. Freeing on rename bounds what any wallet can hold hostage to
	// exactly one name per token it owns, and since no address can ever hold more than batchCap
	// tokens, the worst case for the entire realm is 24 names held at once by the 24 tokens that
	// exist. See SetName's commit block, which removes before it sets.
	nameOwner = avl.NewTree()

	// characterOwner: one of namedEditionOrder's three names -> tokenID, present only once that
	// edition has actually been minted. Has(name) is both "has this cap-one edition been taken"
	// (Settle's own fallback check) and "does it exist yet" (CharacterOwner's reader) -- the same
	// single tree answers both questions, which is why there is no separate counter for it.
	characterOwner = avl.NewTree()

	mintedCount  int64 // reservations made by Claim, gates batchCap; never decremented
	settledCount int64 // completions made by Settle; informational only, see BatchStatus

	genesisTokenID string // set exactly once, in init()

	rulesFrozen = true // always true: there are no rules to freeze or unfreeze in v5. See AdminState.

	fee feeConfig

	transferGate string
)

func init(cur realm) {
	if !address(adminAddress).IsValid() {
		panic("garden: adminAddress is not a valid address; fix the constant before deploying")
	}

	cfg := feeConfig{
		recipient:  address(saleFeeRecipient),
		rateBps:    saleFeeRateBps,
		floorUgnot: saleFeeFloorUgnot,
	}
	assertFeeConfig(cfg, cur.Address())
	fee = cfg

	token, ledger = grc721.NewToken(collectionName, collectionSymbol, 0, cur)
	ledger.RegisterExtension(&saleGateExtension{})

	// THE GENESIS GNOME. Minted here, directly, to this realm's own address -- never through
	// Claim, never counted against batchCap, never allowlist-gated, because it is not a roll and
	// not part of the batch (DECISIONS.md 2026-10-15). No wallet holds this realm's private key,
	// so no transaction can ever be signed as its owner: List, Buy and Wake all additionally
	// refuse genesisTokenID by name as a second, redundant lock, and saleGateExtension's
	// OnTransfer refuses it unconditionally as a third -- the same "two locks on a door that
	// already has one" discipline v4's own sale gate uses, because the claim "belongs to
	// nobody" is only as strong as the weakest reachable path around it.
	id := nextID.Next()
	genesisTokenID = id.String()
	me := cur.Address()
	if err := ledger.Mint(me, grc721.TokenID(genesisTokenID)); err != nil {
		panic(err)
	}
	now := time.Now().Unix()
	gnomes.Set(genesisTokenID, &gnome{
		character: "genesis",
		// v6 FIX 1: the genesis gnome carries its own name from the instant this realm exists.
		// It is the one token whose name was never chosen by an owner and never can be -- no
		// wallet holds this realm's key, and SetName refuses any token with a character anyway.
		name:         genesisGnomeName,
		eyes:         -1,
		nose:         -1,
		level:        1,
		adoptedAt:    now,
		belly:        meterMax,
		bellyAt:      now,
		cheer:        meterMax,
		cheerAt:      now,
		lastActionAt: now,
		acquiredAt:   now,
		// settledRound stays 0: the genesis gnome was never rolled for. See the field's comment.
	})
	addOwnerToken(me, genesisTokenID)

	// v6 FIX 1: register the genesis name in the uniqueness index, so NameOwner resolves it and
	// no ordinary gnome can take it. reservedNameKeys already refuses it independently of this
	// write (same two-locks discipline as the genesis transfer refusals above) -- this one makes
	// the index COMPLETE, so "every name a living token carries is in nameOwner" holds without an
	// exception a future reader would have to know about.
	nameOwner.Set(canonicalNameKey(genesisGnomeName), genesisTokenID)

	// Registered under its own name, "genesis", in the SAME tree the three named one-of-ones
	// use -- not because it competes with their cap (BatchStatus's namedMinted count iterates
	// namedEditionOrder only, which "genesis" is never a member of, so this cannot affect the
	// batch), but so CharacterOwner("genesis") resolves instead of silently reporting not-found
	// for the one named character that is neither ordinary nor one of the three. Second-audit-
	// pass finding (G7): fixed here, not left as a reader inconsistency.
	characterOwner.Set("genesis", genesisTokenID)

	chain.Emit("Genesis", "tokenId", genesisTokenID, "name", genesisGnomeName)
}

// assertFeeConfig: unchanged from v4's own gate.
func assertFeeConfig(cfg feeConfig, realmAddr address) {
	if !cfg.recipient.IsValid() {
		panic("garden: DEPLOY GATE: saleFeeRecipient is not a valid address; fix the constant at the top of garden.gno before deploying")
	}
	if cfg.recipient == realmAddr {
		panic("garden: DEPLOY GATE: saleFeeRecipient is this realm's own address, and coins sent there are burned because there is no withdrawal path")
	}
	if cfg.recipient == address(adminAddress) {
		panic("garden: DEPLOY GATE: saleFeeRecipient is the admin/deploy key; the fee recipient must be an address chosen for that purpose, not the key that happens to deploy")
	}
	if cfg.rateBps < 1 || cfg.rateBps > maxFeeRateBps {
		panic("garden: DEPLOY GATE: saleFeeRateBps must be between 1 and " + strconv.FormatInt(maxFeeRateBps, 10) + " basis points; fix the constant at the top of garden.gno before deploying")
	}
	if cfg.floorUgnot < 1 || cfg.floorUgnot > maxPriceUgnot {
		panic("garden: DEPLOY GATE: saleFeeFloorUgnot must be between 1 and " + strconv.FormatInt(maxPriceUgnot, 10) + " ugnot; fix the constant at the top of garden.gno before deploying")
	}
}

// saleGateExtension: v4's shape, plus the genesis refusal. Panics on every transfer except the
// one Buy is performing right now, and ALWAYS panics for genesisTokenID regardless of
// transferGate -- there is no path, including a future bug in Buy, by which the genesis gnome
// should ever be transferable, so this checks it first and unconditionally.
type saleGateExtension struct{}

func (saleGateExtension) ExtensionKind() string { return "sale-gate" }

func (saleGateExtension) OnMint(to address, tid grc721.TokenID) {}

func (saleGateExtension) OnTransfer(from, to address, tid grc721.TokenID) {
	if tid.String() == genesisTokenID {
		panic("garden: the genesis gnome belongs to nobody and can never change hands")
	}
	if transferGate == "" || transferGate != tid.String() {
		panic("garden: a gnome can only change hands through Buy; every other transfer is permanently disabled")
	}
}

func (saleGateExtension) OnBurn(tid grc721.TokenID) {
	panic("garden: gnomes cannot be burned")
}

// ============================================================================
// Admin: the allowlist. The only admin-reachable state in this whole realm -- there is no
// SetRule, no FreezeRules, no fee steward, no treasury reach, nothing else at all.
// ============================================================================

// AdminAllow adds addr to the allowlist, so it may call Claim. Adding an address a second time
// is a harmless no-op. Adding an address that has already rolled changes nothing -- hasRolled is
// checked independently and is permanent regardless of allowlist state.
func AdminAllow(cur realm, addr address) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: admin calls accept no coins")
	}
	caller := cur.Previous().Address()
	if caller != address(adminAddress) {
		panic("garden: only the admin may manage the allowlist")
	}
	if !addr.IsValid() {
		panic("garden: not a valid address")
	}
	allowlist.Set(addr.String(), true)
	chain.Emit("AdminAllow", "admin", caller.String(), "address", addr.String())
}

// AdminDisallow removes addr from the allowlist. It does NOT, and cannot, undo a roll already
// spent: hasRolled is a separate, permanent record, and this function never touches it. Removing
// an address that was never allowed, or that has already claimed, is a harmless no-op.
func AdminDisallow(cur realm, addr address) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: admin calls accept no coins")
	}
	caller := cur.Previous().Address()
	if caller != address(adminAddress) {
		panic("garden: only the admin may manage the allowlist")
	}
	allowlist.Remove(addr.String())
	chain.Emit("AdminDisallow", "admin", caller.String(), "address", addr.String())
}

// ============================================================================
// Claim: the one roll. Phase one of two. MINT.md section 10.5 step 1.
// ============================================================================

// Claim spends the caller's one-and-only roll on this realm and pins a drand round that does
// not exist yet. It mints NOTHING -- Settle does that, once the pinned round is actually
// published -- because the whole point of this split is that the result must not be computable,
// by anyone, including this transaction's own caller, at the moment the roll becomes irrevocable
// (MINT.md section 10.2: gno.land has no on-chain entropy at all, so anything decidable inside
// one transaction is decidable by the caller before broadcasting it).
//
// WALLET-ONLY, the same reasoning as v4's Adopt: a gnome minted to a realm's address could never
// be recovered, so a batching, sponsor or multicall realm must never be able to spend a roll on
// anyone's behalf. The `gnokey maketx run` shape is refused by the identical gate, for the
// identical reason (IsUserCall is false for both).
func Claim(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("garden: claim must be called directly by a wallet, not through another realm; the one roll this spends could never be returned to an address that could not hold the resulting gnome")
	}
	if !unsafe.OriginSend().IsZero() {
		panic("garden: claim accepts no coins; the mint is free, exactly as garden/v4's adopt already refuses coins, and nothing here can return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: claim requires a valid caller address")
	}

	if !allowlist.Has(caller.String()) {
		panic("garden: this address is not on the allowlist; ask the owner to add it before claiming")
	}

	if hasRolled.Has(caller.String()) {
		panic("garden: this address has already rolled on this realm; one roll per wallet, forever, whether or not the resulting gnome is still held")
	}

	if mintedCount >= batchCap {
		panic("garden: batch one is closed; all " + strconv.FormatInt(batchCap, 10) + " editions have already been claimed")
	}

	// CurrentRound() is pure arithmetic over THIS call's own block time (RoundAt(time.Now())),
	// not an extrapolation from however recently somebody last relayed -- see MINT.md section
	// 10.4's own live measurement of EstimatedLatestRound() erroring under a stale relay while
	// CurrentRound() kept working regardless. Pinning pinOffsetRounds past it is therefore safe
	// against relay staleness; the margin exists only for ordinary block-time/wall-clock skew.
	round := beacon.CurrentRound() + pinOffsetRounds

	// ---- commit. Nothing below this line can fail. ----
	hasRolled.Set(caller.String(), true)
	mintedCount++
	pendingClaims.Set(caller.String(), &pendingClaim{round: round, claimedAt: time.Now().Unix()})

	chain.Emit("Claim", "claimant", caller.String(), "round", strconv.FormatInt(round, 10))
}

// ============================================================================
// Settle: permissionless. Phase two of two. MINT.md section 10.5 step 2. Two entry points, one
// shared core -- see the package doc's "SETTLE CAN NOW PAY FOR ITS OWN BEACON RELAY" section for
// the full account of why, what it costs, and the two live-chain facts (beacon.Publish panics
// rather than no-ops on an already-published round; beacon.Publish is reachable cross-realm as
// beacon.Publish(cross(cur), round, sigHex), already proven by this package's own test harness)
// that shape of both functions below depends on.
// ============================================================================

// pendingClaimFor looks up claimant's pending roll, shared by both Settle and
// SettleWithSignature so the "no pending claim" message and lookup logic exist exactly once.
func pendingClaimFor(claimant address) *pendingClaim {
	pcv := pendingClaims.Get(claimant.String())
	pc, ok := pcv.(*pendingClaim)
	if !ok || pc == nil {
		panic("garden: no pending claim for this address; it must Claim first, or this claim has already been settled")
	}
	return pc
}

// Settle computes and permanently mints the result of claimant's pending roll, once the round
// Claim pinned has actually been published to the beacon by SOMEBODY -- another claimant's own
// SettleWithSignature, a relay, anyone. It does not publish anything itself; call
// SettleWithSignature instead if the round is not published yet and the caller has its
// signature to offer. ANYONE may call this -- the claimant themself, the project's own relayer, a
// stranger -- because by the time it can succeed at all, nothing is left to decide: the drand
// signature for the pinned round either exists publicly or it does not, and the parts this mints
// are a pure function of (that signature, the claimant's own address), fixed the instant the
// round is published, not the instant Settle happens to be called. Simulating this call before
// calling it for real previews a fact, not a choice -- exactly the property MINT.md section 10.5
// names as the whole fix: "reading the result afterward is a free query, same as any other realm
// read."
//
// Refuses coins for the same reason every other non-paying function here does: there is no
// banker to return them, and this is a free, permissionless computation, never a payment.
func Settle(cur realm, claimant address) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: settle accepts no coins; it is a free, permissionless computation, not a payment")
	}
	if !claimant.IsValid() {
		panic("garden: settle requires a valid claimant address")
	}

	pc := pendingClaimFor(claimant)

	if !beacon.Published(pc.round) {
		panic("garden: drand round " + strconv.FormatInt(pc.round, 10) + " has not been relayed to the beacon yet; call Settle again once it has, or call SettleWithSignature with the round's drand signature (fetched from drand's own public API) to relay it yourself in this same transaction -- relaying is permissionless, and so is settling")
	}

	settleCore(claimant, pc)
}

// SettleWithSignature is Settle, plus: if claimant's pinned round has not been published yet,
// this function publishes it ITSELF first, in this same transaction, using sigHex -- the round's
// drand signature, which the caller's own app fetches read-only from drand's public API
// (https://api.drand.sh/<chain>/public/<round> or any mirror) and passes straight through
// unmodified. This is the function a player's app should call once it has fetched a signature;
// Settle (above) remains for a caller with no signature to offer, or that already knows (or does
// not care) that somebody else has published the round.
//
// SAFE EITHER WAY THE ROUND TURNS OUT TO BE, which is the one property this function exists to
// guarantee and the live chain fact its shape is built around (see the package doc): beacon/v2's
// own Publish PANICS, not no-ops, when the round is already published, so this function checks
// beacon.Published first and only calls Publish if that check says no. If the round was published
// by someone else (another claimant's own SettleWithSignature, a relay, anyone) between the
// moment the caller fetched sigHex and the moment this transaction lands, sigHex is simply never
// used -- this function still succeeds, exactly as Settle would have. A bad sigHex, by contrast,
// is a real failure: beacon.Publish rejects it with its own "beacon: invalid signature" panic,
// which aborts this whole call (and the claim stays pending, to be retried with a correct
// signature or left for Settle once someone else relays it).
//
// Refuses coins for the same reason Settle does and every non-paying function here does: there
// is no banker to return them, and this is a free, permissionless computation -- the only payment
// anywhere in this call is the ordinary GNOT gas the caller's own transaction spends, to the
// network, never to this project (MINT.md section 14).
func SettleWithSignature(cur realm, claimant address, sigHex string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: settle accepts no coins; it is a free, permissionless computation, not a payment")
	}
	if !claimant.IsValid() {
		panic("garden: settle requires a valid claimant address")
	}

	pc := pendingClaimFor(claimant)

	if !beacon.Published(pc.round) {
		// Permissionless and carries no caller-identity check (verified against the live
		// deployed beacon/v2 source -- see the package doc): this realm relaying on a player's
		// behalf is exactly as valid as the player relaying directly, or anyone else doing so.
		beacon.Publish(cross(cur), pc.round, sigHex)
	}

	settleCore(claimant, pc)
}

// settleCore is Settle's and SettleWithSignature's shared tail: the draw, the mint, and every
// write that follows, once the caller above has already confirmed the pinned round is published.
// Takes no `cur realm` because it makes no cross-realm call of its own -- beacon.Randomness and
// beacon.Published below are plain reads, not crossing functions, exactly as they always were
// before this change.
func settleCore(claimant address, pc *pendingClaim) {
	randomnessHex := beacon.Randomness(pc.round)

	if mintedCount < settledCount+1 {
		// Unreachable: Claim never lets mintedCount fall behind settledCount+1 for a claim that
		// is about to settle, because mintedCount is incremented before any pendingClaim this
		// function could ever read exists. Named so this function is correct on its own terms,
		// the same discipline v4's Buy uses for its own unreachable checks.
		panic("garden: batch accounting is inconsistent; refusing to mint")
	}

	// THE NAMED-EDITION PICK. seed % batchCap, against the COMPILE-TIME CONSTANT batchCap, never
	// against a shrinking count of what remains -- see the package doc's "flaw found and fixed"
	// section for why that distinction is the whole safety property here. namedPick is fixed the
	// instant randomnessHex exists (i.e. the instant the pinned round is signed by drand, which
	// nobody controls), and WHEN Settle happens to be called after that changes nothing about it.
	namedPick := seedFor(randomnessHex, claimant, "slot") % uint64(batchCap)

	// The ordinary draw is always computed, unconditionally, whether or not namedPick lands in
	// the named range -- so a claimant whose pick collides with an edition someone else already
	// settled first has a ready, equally valid fallback rather than needing a second derivation.
	eyesSeed := seedFor(randomnessHex, claimant, "eyes")
	noseSeed := seedFor(randomnessHex, claimant, "nose")
	hatCoatSeed := seedFor(randomnessHex, claimant, "hatcoat")
	drawnEyes := int64(drawWeighted(eyesWeights[:], 100, eyesSeed))
	drawnNose := int64(drawWeighted(noseWeights[:], 100, noseSeed))
	drawnHat := hatOptions[hatCoatSeed%uint64(len(hatOptions))]
	drawnCoat := coatOptions[(hatCoatSeed/uint64(len(hatOptions)))%uint64(len(coatOptions))]

	character := ""
	eyes, nose := drawnEyes, drawnNose
	hat, coat := drawnHat, drawnCoat
	if namedPick < uint64(numNamedEditions) {
		candidate := namedEditionOrder[namedPick]
		if !characterOwner.Has(candidate) {
			// Whichever Settle call lands on chain first among possibly several colliding
			// claimants gets this edition; a later one finds characterOwner already holds it and
			// falls through to its own ordinary draw instead. This is a transaction-ordering
			// race, not a strategy any claimant can win by choosing WHEN to settle their OWN
			// claim -- their own pick is already fixed and cannot change -- see the package doc's
			// "a real flaw found and fixed" section for why claimedAt-based tie-breaking was
			// considered and rejected, and for the precise property this guarantees instead.
			character = candidate
			eyes, nose = -1, -1
			hat, coat = "", ""
		}
	}

	settledCount++

	id := nextID.Next()
	tid := grc721.TokenID(id.String())
	if err := ledger.Mint(claimant, tid); err != nil {
		panic(err)
	}

	// v6 FIX 1: a named one-of-one is born with its own name; an ordinary gnome is born NAMELESS
	// and stays that way until its owner calls SetName. Nothing is chosen at mint time, including
	// a name -- `character` here is a pure function of the drand round, not of anything the
	// claimant asked for, so assigning the name that goes with it is not a choice either.
	//
	// The name written here is the DISPLAY form -- "Hob", not the canonical key "hob" that
	// `character` is and that characterOwner is keyed by. See namedEditionDisplayNames for why
	// those are two strings and why collapsing them into one would break CharacterOwner.
	name := ""
	if character != "" {
		name = namedEditionDisplayName(character)
	}

	now := time.Now().Unix()
	gnomes.Set(tid.String(), &gnome{
		hat:       hat,
		coat:      coat,
		eyes:      eyes,
		nose:      nose,
		character: character,
		name:      name,
		// v6 FIX 2: the drand round that produced this gnome, stored rather than only emitted.
		// pc.round is the round Claim pinned and the one beacon.Randomness was just read at, so
		// this is the exact number a holder needs to re-derive their own parts from drand's own
		// public API and check this realm did not rig them.
		settledRound: pc.round,
		level:        1,
		adoptedAt:    now,
		belly:        meterMax,
		bellyAt:      now,
		cheer:        meterMax,
		cheerAt:      now,
		lastActionAt: now,
		lastWokenAt:  now,
		acquiredAt:   now,
	})

	addOwnerToken(claimant, tid.String())
	if character != "" {
		characterOwner.Set(character, tid.String())
		// v6 FIX 1: a named edition's name is taken the instant it mints. reservedNameKeys
		// already refused it to everyone else before this moment (that is the pre-mint half of
		// the protection -- see its own comment); this write is the post-mint half, so the
		// nameOwner index is complete for every living token without exception.
		nameOwner.Set(canonicalNameKey(name), tid.String())
	} else {
		eyesCounts.Set(strconv.FormatInt(eyes, 10), eyesCount(eyes)+1)
		noseCounts.Set(strconv.FormatInt(nose, 10), noseCount(nose)+1)
		hatCounts.Set(hat, hatCount(hat)+1)
		coatCounts.Set(coat, coatCount(coat)+1)
	}

	grantStartingPurseIfNew(claimant)

	// Auto-wake only if this claimant currently has nothing awake at all (never settled or
	// bought a gnome before, or sold their only one). Never otherwise: a claimant who already
	// has an awake gnome gets this one asleep in their stash, exactly as a purchase would (Buy's
	// own comment explains why switching must always be a deliberate Wake, never a side effect).
	if !activeToken.Has(claimant.String()) {
		activeToken.Set(claimant.String(), tid.String())
	}

	pendingClaims.Remove(claimant.String())

	chain.Emit(
		"Settle",
		"claimant", claimant.String(),
		"tokenId", tid.String(),
		"round", strconv.FormatInt(pc.round, 10),
		"character", character,
		"eyes", strconv.FormatInt(eyes, 10),
		"nose", strconv.FormatInt(nose, 10),
		"hat", hat,
		"coat", coat,
	)
}

// fnv64a is a plain, non-cryptographic 64-bit FNV-1a hash. IT IS NOT THE SOURCE OF
// UNPREDICTABILITY HERE -- drand's signature for a not-yet-existent round is, exactly as MINT.md
// section 10.5 designs. This exists only to DECORRELATE independent draws (two different
// claimants sharing a pinned round, or one claimant's own eyes-draw from their own nose-draw)
// from a single public drand value, the same category of use math/rand's PCG(0,0) would be fine
// for once combined with a secure external seed -- see MINT.md section 10.5's own list of unsafe
// constructions for why math/rand ALONE is not used, and note this is never alone: every call
// site below mixes in beacon.Randomness(pc.round), which is the only thing doing real work.
func fnv64a(s string) uint64 {
	const offset64 = uint64(14695981039346656037)
	const prime64 = uint64(1099511628211)
	h := offset64
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= prime64
	}
	return h
}

// seedFor derives one independent-looking 64-bit value from the published drand randomness, the
// claimant's own address, and a purpose string -- so a single drand round can safely drive
// several unrelated draws (which named edition, which eyes, which nose, which hat/coat) for
// several different simultaneous claimants without any of them correlating with each other.
func seedFor(randomnessHex string, claimant address, purpose string) uint64 {
	return fnv64a(randomnessHex + "|" + claimant.String() + "|" + purpose)
}

// drawWeighted picks an index into weights (which TestWeightTablesSumToOneHundred pins as
// summing to totalWeight) using seed as the source of randomness -- a plain cumulative-sum
// bucket walk, MINT.md section 10.5's own recommendation for what Settle should do ("a simple,
// bounded index... easy to audit"), applied to a weight table instead of a published array,
// which is the same shape of arithmetic.
func drawWeighted(weights []int64, totalWeight int64, seed uint64) int {
	if totalWeight <= 0 {
		panic("garden: drawWeighted: totalWeight must be positive")
	}
	x := int64(seed % uint64(totalWeight))
	var cum int64
	for i, w := range weights {
		cum += w
		if x < cum {
			return i
		}
	}
	// Unreachable if weights sums to exactly totalWeight, which the test above pins. Returning
	// the last index rather than panicking keeps Settle from ever aborting a claimant's one and
	// only roll over an arithmetic slip elsewhere in this file.
	return len(weights) - 1
}

// ============================================================================
// Wake: switching which gnome is awake. MINT.md section 2a.
// ============================================================================

// Wake makes tokenID the caller's awake gnome. Free, and limited to once per UTC day -- the same
// day-boundary discipline SaveDay's own dailyCareDay already uses, chosen over a GNOT fee for the
// reason MINT.md section 2a gives: "a cost that cannot be bought, only lived".
func Wake(cur realm, tokenID string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: wake accepts no coins; switching which gnome is awake is free, once per UTC day")
	}

	if tokenID == genesisTokenID {
		panic("garden: the genesis gnome belongs to nobody and can never be woken")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: wake requires a valid caller address")
	}

	owner, ok := ownerOfToken(tokenID)
	if !ok || owner != caller {
		panic("garden: you do not own that gnome")
	}

	if active, hasActive := activeToken.Get(caller.String()).(string); hasActive && active == tokenID {
		panic("garden: that gnome is already awake")
	}

	now := time.Now().Unix()
	today := dayNumber(now)
	if last, isInt := lastWakeDay.Get(caller.String()).(int64); isInt && last == today {
		panic("garden: switching which gnome is awake is limited to once per UTC day; try again tomorrow")
	}

	// g must exist: ownerOfToken above already confirmed tokenID is a real, owned token.
	// Recording lastWokenAt HERE, on the token actually being woken, is the other half of the
	// fix for ATTACK-REVIEW.md goal 7 -- see the gnome struct's own comment on the field. The
	// token being put to sleep (whichever was active(caller) a moment ago, if any) needs no
	// symmetrical write: its own lastActionAt/caredDayCount are already frozen facts the instant
	// it stops being the active one (SaveDay can only ever act on activeGnomeForAddr's result),
	// and the next time anything reactivates IT, that reactivation (another Wake, a later Buy by
	// a new owner, etc.) will set its lastWokenAt correctly at that time, exactly as this call is
	// doing now.
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		panic("garden: that gnome does not exist")
	}
	g.lastWokenAt = now
	gnomes.Set(tokenID, g)

	activeToken.Set(caller.String(), tokenID)
	lastWakeDay.Set(caller.String(), today)

	chain.Emit("Wake", "owner", caller.String(), "tokenId", tokenID)
}

// ============================================================================
// SaveDay: v4's shape, exactly, resolved through the caller's ACTIVE gnome rather than "the"
// gnome for that address -- because after mint one/hold many/play one, there no longer is one.
// A sleeping gnome is simply never found here: activeGnomeForAddr only ever returns the awake
// token, so care applied to "my gnome" always means the one gnome actually allowed to earn
// anything (MINT.md section 2a: "a sleeping gnome earns zero -- no cared days, no streak, no
// level, no XP").
// ============================================================================

type saveAction struct {
	kind string
	at   int64
	plot int
}

func SaveDay(cur realm, actionsRaw string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: save day accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: save day requires a valid caller address")
	}

	tid, g, ok := activeGnomeForAddr(caller)
	if !ok {
		panic("garden: no gnome is awake for this address; claim or buy one, or Wake one of your own")
	}

	now := time.Now().Unix()
	actions := parseActions(actionsRaw)

	if len(actions) == 0 {
		chain.Emit("SaveDay", "owner", caller.String(), "tokenId", tid, "actions", "0", "xpApplied", "0")
		return
	}

	earliestAllowed := now - maxBackfillHours*hourSeconds

	// awakeSince: the moment THIS token last became the active one (set by settleCore, Buy, and
	// Wake -- see the gnome struct's own comment). ATTACK-REVIEW.md goal 7: without this, a
	// token's own earliestAllowed was bounded only by its own lastActionAt and the 48-hour
	// horizon, with nothing checking that the backfilled window actually fell inside a period
	// this specific token was awake. A token that just became active (whether by a brand-new
	// Claim/Settle, a Buy, or an explicit Wake switching away from a sibling in the same stable)
	// cannot backfill anything from before that moment -- it was asleep then, and MINT.md /
	// DECISIONS.md are both explicit that a sleeping gnome earns zero, full stop, not "zero
	// unless a sibling token happens to cover the gap."
	awakeSince := g.lastWokenAt
	if awakeSince > earliestAllowed {
		earliestAllowed = awakeSince
	}

	firstDay := dayNumber(actions[0].at)
	prevAt := g.lastActionAt
	if prevAt < earliestAllowed {
		prevAt = earliestAllowed
	}
	for _, a := range actions {
		if a.at <= earliestAllowed {
			if a.at <= awakeSince {
				panic("garden: this action predates the last time this gnome was woken; a sleeping gnome earns nothing for the time it was asleep")
			}
			panic("garden: this action is more than " + strconv.FormatInt(maxBackfillHours, 10) + " hours old; care can only be backfilled for the last " + strconv.FormatInt(maxBackfillHours, 10) + " hours, not longer absences")
		}
		if a.at <= prevAt {
			panic("garden: action timestamp must be strictly after the last saved action")
		}
		if a.at > now {
			panic("garden: action timestamp cannot be in the future")
		}
		if dayNumber(a.at) != firstDay {
			panic("garden: every action in one SaveDay call must fall on the same UTC day")
		}
		prevAt = a.at
	}

	work := *g
	acorns := balanceOf(caller)
	spentThisCall := false

	gateWaived := acorns < acornReserve && !anyPlotPlanted(g)
	rawCareXp := int64(0)
	tinkeredThisCall := false

	for _, a := range actions {
		switch a.kind {
		case actionPat:
			if !canPat(work.lastPatAt, a.at, patCooldownHours) {
				panic("garden: pat must be at least " + strconv.FormatInt(patCooldownHours, 10) + " hours after the last one")
			}
			work.lastPatAt = a.at
			work.lastHappyEventAt = a.at
			work.cheer = clampMeter(meterNow(work.cheer, work.cheerAt, a.at, cheerDropEveryHours) + patCheer)
			work.cheerAt = a.at
			rawCareXp += xpPat

		case actionFeed:
			if acorns < feedCost {
				panic("garden: not enough acorns to feed")
			}
			acorns -= feedCost
			spentThisCall = true
			work.belly = clampMeter(meterNow(work.belly, work.bellyAt, a.at, bellyDropEveryHours) + feedBelly)
			work.bellyAt = a.at
			work.lastHappyEventAt = a.at
			rawCareXp += xpFeed

		case actionPlant:
			waived := gateWaived && acorns < acornReserve
			if !waived && meterNow(work.belly, work.bellyAt, a.at, bellyDropEveryHours) <= hungryAtOrBelow {
				panic("garden: too hungry to garden; feed first")
			}
			p := &work.plots[a.plot]
			if p.plantedAt != 0 {
				panic("garden: that plot is already planted")
			}
			if acorns < plantCost {
				panic("garden: not enough acorns to plant")
			}
			acorns -= plantCost
			spentThisCall = true
			p.plantedAt = a.at
			p.readyAt = a.at + growHours*hourSeconds

		case actionHarvest:
			p := &work.plots[a.plot]
			if p.plantedAt == 0 {
				panic("garden: that plot has nothing to harvest")
			}
			if a.at < p.readyAt {
				panic("garden: that plot is not ready to harvest yet")
			}
			p.plantedAt = 0
			p.readyAt = 0
			acorns += harvestPerPlot
			work.xpGarden += xpHarvestPerPlot
			work.harvestCount++
			rawCareXp += xpHarvestPerPlot

		case actionTinker:
			if tinkeredThisCall {
				panic("garden: only one tinker task per day")
			}
			if work.lastTinkerAt != 0 && dayNumber(work.lastTinkerAt) == dayNumber(a.at) {
				panic("garden: already did a tinker task today")
			}
			if acorns < tinkerCost {
				panic("garden: not enough acorns to tinker")
			}
			acorns -= tinkerCost
			spentThisCall = true
			work.xpTinker += xpTinkerTask
			work.lastTinkerAt = a.at
			tinkeredThisCall = true
			rawCareXp += xpTinkerTask

		default:
			panic("garden: unknown action kind")
		}
	}

	if spentThisCall && acorns < acornReserve && !anyPlotPlanted(&work) {
		panic("garden: that would leave fewer than " + strconv.FormatInt(acornReserve, 10) + " acorns with nothing planted, and a gnome with no acorns and no garden can never earn another; plant first, or keep " + strconv.FormatInt(acornReserve, 10) + " back")
	}

	latestActionAt := actions[len(actions)-1].at
	bellyAtEnd := meterNow(work.belly, work.bellyAt, latestActionAt, bellyDropEveryHours)
	mood := moodNow(bellyAtEnd, work.lastPatAt, work.lastHappyEventAt, work.adoptedAt, latestActionAt, hungryAtOrBelow)

	adjustedXp := rawCareXp
	switch mood {
	case moodHappy:
		adjustedXp = adjustedXp * (100 + happyBonusPct) / 100
	case moodSulky:
		adjustedXp = adjustedXp * (100 - sulkyPenaltyPct) / 100
	}

	if work.dailyCareDay != firstDay {
		work.dailyCareDay = firstDay
		work.dailyCareXp = 0
	}
	remainingToday := dailyCareCap - work.dailyCareXp
	if remainingToday < 0 {
		remainingToday = 0
	}
	if adjustedXp > remainingToday {
		adjustedXp = remainingToday
	}
	work.dailyCareXp += adjustedXp

	work.totalXp += adjustedXp
	work.level = levelFromXp(work.totalXp)

	// At most ONE of this owner's tokens may ever bank a given UTC day as cared-for -- see
	// lastCaredDayForOwner's own comment. Without this, Wake (once per day, but still once)
	// lets an owner genuinely care for A earlier today, switch to B, and genuinely care for B
	// too, banking the SAME calendar day on both from nothing but real, non-backfilled
	// timestamps -- the live-switch half of ATTACK-REVIEW.md goal 7 that lastWokenAt's backfill
	// floor does not by itself prevent. XP, acorns, feeding, planting and harvesting are
	// deliberately NOT gated here: those are this token's own resource mechanics (already
	// bounded per-gnome by dailyCareCap) and giving B real care today is still real care: only
	// the CARED-DAY LEDGER -- the thing lockCaredDays and the public streak actually count -- is
	// restricted to one credit per owner per day.
	if lastOwnerDay, ok := lastCaredDayForOwner.Get(caller.String()).(int64); !ok || lastOwnerDay != firstDay {
		if recordCaredDay(&work, firstDay) {
			lastCaredDayForOwner.Set(caller.String(), firstDay)
		}
	}
	work.lastActionAt = latestActionAt

	setBalance(caller, acorns)
	*g = work
	gnomes.Set(tid, g)

	chain.Emit(
		"SaveDay",
		"owner", caller.String(),
		"tokenId", tid,
		"actions", strconv.Itoa(len(actions)),
		"xpApplied", strconv.FormatInt(adjustedXp, 10),
		"mood", mood,
	)
}

// ============================================================================
// ChooseType: v4's shape, resolved through the active gnome.
// ============================================================================

func ChooseType(cur realm, kind string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: choose type accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: choose type requires a valid caller address")
	}

	tid, g, ok := activeGnomeForAddr(caller)
	if !ok {
		panic("garden: no gnome is awake for this address")
	}

	if g.gnomeType != "" {
		panic("garden: this gnome's calling is already chosen and cannot be changed")
	}

	level := levelFromXp(g.totalXp)
	if level < typeAtLevel {
		panic("garden: a calling can only be chosen at level " + strconv.FormatInt(typeAtLevel, 10) + " or above")
	}

	if kind != typeGardener && kind != typeExplorer && kind != typeTinkerer {
		panic("garden: a calling is one of \"" + typeGardener + "\", \"" + typeExplorer + "\" or \"" + typeTinkerer + "\"")
	}

	work := *g
	work.gnomeType = kind
	work.level = level
	*g = work
	gnomes.Set(tid, g)

	chain.Emit("ChooseType", "owner", caller.String(), "tokenId", tid, "type", kind)
}

// ============================================================================
// v6 FIX 1: SetName. THE ONLY NEW WRITE SURFACE IN THIS WHOLE FILE RELATIVE TO v5.
//
// WHY IT IS A SEPARATE FUNCTION AND NOT A PARAMETER ON Claim OR Settle, which is the first
// thing a reader will wonder and the one design question here that is already settled: the mint
// is a ROLL, and the whole safety property of the two-phase roll (MINT.md section 10.5, and this
// file's own package doc at length) is that the claimant does not and cannot choose what comes
// out of it. A name parameter on Claim would not technically break that -- a name does not
// influence the draw -- but it would blur the one sentence the product has to be able to say
// without an asterisk ("you do not choose what you get"), and it would mean a claimant has to
// have decided on a name at the exact moment they are least able to: before they have any idea
// what they are naming. Naming what you GOT is a different act from getting it, so it is a
// different function, called later, by the owner, as many times as they like.
//
// ONLY THE CURRENT OWNER. Not the original claimant -- the CURRENT owner. A gnome that has been
// sold belongs to its buyer, and so does its name; the seller loses the ability to rename it at
// the same instant they lose the token, through the same ownerOfToken check every other
// owner-gated function in this file uses (Wake, List). There is no admin override: this realm's
// admin can gate issuance and nothing else (see AdminAllow's own comment), and a name is not
// issuance.
// ============================================================================

// SetName names tokenID, which the caller must currently own, or RENAMES it. Free, unlimited,
// and refused for the three named one-of-ones and the genesis gnome.
//
// RENAMING IS ALLOWED, NOT ONE-SHOT, and this is a deliberate decision with a named trade-off
// rather than an oversight. On an immutable realm a one-shot name means a typo is forever, and
// "my gnome is called Fenncik" is a worse permanent outcome than "somebody changed their mind".
// Aavegotchi, the closest prior art this project has looked at, allows renaming. What it costs:
// a name is not a stable identifier over time, so nothing anywhere -- in this realm, in the
// adventure realm, or in the app -- may ever key anything on a name. tokenID is the identifier;
// the name is a label. (The nameOwner index is keyed BY name only to answer "is this taken",
// never to identify a gnome; every function here looks tokens up by tokenID.)
//
// Refuses coins for the same reason every other non-paying function here does: there is no
// banker to return them, and naming your own gnome is free (MINT.md section 14 -- batch one is
// free end to end, and this is not a new place to charge).
func SetName(cur realm, tokenID string, name string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: set name accepts no coins; naming your own gnome is free, and nothing here can return them")
	}

	// Checked FIRST and by name, before the ownership lookup that would also refuse it: the
	// genesis gnome belongs to nobody, so there is no caller for whom the owner check could ever
	// pass, but saying so explicitly is this file's established discipline for it (List, Buy and
	// Wake all do the same) and it gives a reader of the panic the real reason rather than a
	// misleading "you do not own that gnome".
	if tokenID == genesisTokenID {
		panic("garden: the genesis gnome belongs to nobody and can never be renamed")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: set name requires a valid caller address")
	}

	owner, ok := ownerOfToken(tokenID)
	if !ok || owner != caller {
		panic("garden: you do not own that gnome")
	}

	g, isGnome := gnomeByTokenID(tokenID)
	if !isGnome {
		panic("garden: that tokenID does not exist")
	}

	// THE THREE NAMED ONE-OF-ONES KEEP THEIR CHARACTER NAME, PERMANENTLY. Hob is Hob; that is
	// the entire point of a cap-one edition, and an owner who could rename Hob to "xXx" would be
	// destroying the thing they were lucky enough to roll, irreversibly, for everyone who comes
	// after them. This also closes the obvious way around the reservation: if a named edition
	// could be renamed, its own canonical key would be freed by the rename (SetName's commit
	// block frees the old key by design -- see nameOwner's comment) and "hob" would become
	// takeable by an ordinary gnome even though reservedNameKeys still lists it, because
	// reservation is checked against the NEW name, never the freed one. Refusing the rename
	// outright is what keeps those two mechanisms from interacting.
	if g.character != "" {
		panic("garden: " + g.character + " is a named one-of-one and keeps its own name permanently; only ordinary gnomes can be named")
	}

	// A LISTED GNOME CANNOT BE RENAMED, because the seller still owns it right up until the
	// instant Buy lands and every guard above would therefore pass. THE ATTACK: Alice names
	// token A "Pebble" and lists it. Bob reads the name, broadcasts Buy(A) with the full price.
	// Before Bob's transaction lands, Alice calls SetName(A, "Junk") -- she is still the owner,
	// so nothing refuses her -- and then SetName(B, "Pebble") on a second token she keeps, which
	// the rename just freed the canonical key for (see the commit block below: the old key is
	// released by design). Bob's Buy still succeeds, at the agreed price, for a gnome now called
	// "Junk", and "Pebble" is permanently out of his reach because names are unique and
	// first-come. Buy cannot defend itself here: it never reads g.name and takes no expected-name
	// argument, so there is nothing for it to compare. Refusing the rename while a listing stands
	// is what makes the name a buyer reads part of what they are actually buying.
	//
	// The test is listingFor, the SAME predicate Cancel uses for "is this gnome for sale" -- not
	// a second notion of "listed" that could drift out of step with the marketplace's own. It is
	// deliberately presence-based rather than presence-plus-unexpired: an expired listing is
	// unbuyable (Buy refuses it) so renaming under one is harmless, but copying Buy's inline
	// expiry comparison here would be a second copy of a liveness rule that could later drift,
	// and refusing slightly too much costs the owner one Cancel call while refusing slightly too
	// little reopens the hole on an immutable realm.
	if _, isListed := listingFor(tokenID); isListed {
		panic("garden: that gnome is listed for sale and cannot be renamed while a buyer may already have a purchase in flight; cancel the listing first, then rename it")
	}

	// All validation and every refusal happens in here, before any write below.
	assertNameAssignable(name, tokenID)

	// ---- commit. Nothing below this line can fail. ----

	// FREE THE OLD KEY BEFORE TAKING THE NEW ONE. Required, not tidiness -- see nameOwner's own
	// comment: without this, one token could hoard every name in the collection by renaming
	// repeatedly. Order matters for one specific case: renaming a gnome to a different
	// capitalisation of the name it already has ("fennick" -> "Fennick") canonicalises to the
	// SAME key, so removing first and setting second is the only order that does not either
	// delete the key it just wrote or refuse a legal, harmless re-capitalisation.
	if g.name != "" {
		nameOwner.Remove(canonicalNameKey(g.name))
	}
	nameOwner.Set(canonicalNameKey(name), tokenID)

	previous := g.name
	g.name = name
	gnomes.Set(tokenID, g)

	chain.Emit(
		"SetName",
		"owner", caller.String(),
		"tokenId", tokenID,
		"name", name,
		"previousName", previous,
	)
}

// assertNameAssignable is SetName's refusal gate: it panics with nameAssignabilityProblem's
// message, or returns normally if name may be assigned to tokenID. The rules themselves are in
// nameAssignabilityProblem, not here, so the free NameAvailability query and this enforcing path
// can never disagree about what is allowed -- there is exactly one copy.
func assertNameAssignable(name string, tokenID string) {
	if problem := nameAssignabilityProblem(name, tokenID); problem != "" {
		panic(problem)
	}
}

// nameAssignabilityProblem is THE one copy of the naming rules. It returns "" if name may be
// assigned to tokenID, or the exact player-meaningful message explaining which rule refused it.
//
// IT RETURNS ITS REFUSAL RATHER THAN PANICKING IT so that NameAvailability can offer the same
// answer as a free read without any recover() -- see NameAvailability's own note on why recover
// is avoided on this toolchain.
//
// ORDER IS DELIBERATE AND MATCHES app/js/config.js's nameError, which mirrors v4's realm order:
// length, then charset, then visible content, then (new in v6) reservation, then uniqueness. A
// name that fails several rules reports the first, so the app's own message and the realm's
// refusal always name the SAME rule for the same input rather than disagreeing about which
// problem is the problem.
func nameAssignabilityProblem(name string, tokenID string) string {
	if !validNameLength(name) {
		return "garden: name must be 1-" + strconv.Itoa(maxNameLen) + " characters"
	}

	// Checked before the general charset refusal purely so the message is useful: iOS "smart
	// punctuation" is ON BY DEFAULT and silently rewrites a straight apostrophe to U+2018/U+2019
	// and a hyphen to U+2013/U+2014 (app/js/config.js's third audit round, finding Y8). A player
	// who typed "O'Hare" on an iPhone did not type anything strange, and telling them their name
	// "contains a character that is not an allowed letter" would be true but useless.
	//
	// THIS IS A REFUSAL, NOT A TRANSFORM, AND THAT IS THE POINT. config.js's normalizeName folds
	// those four code points back to ASCII in the BROWSER, before submitting -- a narrowing
	// transform whose own comment notes "the realm remains the sole authority". This realm
	// deliberately does NOT fold them itself: a name is now a reserved, unique, first-come
	// resource, so silently rewriting what somebody signed for would mean the key they got is not
	// the key they asked for, and two players could race for a name neither of them typed.
	// Refusing and naming the reason keeps the realm's accepted set exactly as narrow as v4's
	// while still telling an iPhone player what happened.
	if hasSmartPunctuation(name) {
		return "garden: name contains curly quotes or dashes, which a phone keyboard may have substituted for a plain apostrophe or hyphen; retype it with a straight ' or -"
	}

	if !validNameCharset(name) {
		return "garden: name contains a character that is not an allowed letter, digit, space, hyphen or apostrophe"
	}

	if !hasVisibleNameContent(name) {
		return "garden: name must contain at least one visible character"
	}

	key := canonicalNameKey(name)

	// RESERVATION. An ordinary gnome may not be named after a cap-one edition or the genesis
	// gnome, whether or not that edition has minted yet -- see reservedNameKeys' own comment for
	// why this is not already covered by the uniqueness check below.
	for _, reserved := range reservedNameKeys {
		if key == reserved {
			return "garden: \"" + name + "\" is reserved for a named one-of-one and cannot be taken by an ordinary gnome"
		}
	}

	// UNIQUENESS. Checked against the CANONICAL key, so case and spacing variants of a taken name
	// are refused too -- the cheapest impersonation attempt there is.
	//
	// The `holder != tokenID` test is what makes a HARMLESS self-rename legal: re-capitalising
	// your own gnome's own name ("fennick" -> "Fennick") canonicalises to a key you already hold,
	// and refusing that as "already taken" would be refusing you your own name. Callers who want
	// the general "is this free for anybody" question pass tokenID "" (NameAvailability's own
	// documented shape), which can never equal a real tokenID, so nothing is accidentally
	// exempted by it.
	if holder, taken := nameOwnerOf(key); taken && holder != tokenID {
		return "garden: the name \"" + name + "\" is already taken by gnome " + holder + "; names are unique across the collection"
	}

	return ""
}

// ============================================================================
// SALE: List/Cancel/Buy. v4's shape, DESIGN.md section 9's reasoning unchanged, minus the
// one-gnome-per-address refusal in Buy (MINT.md section 2a: removed from Buy, never from Claim)
// and plus a tokenID parameter on List/Cancel, because an owner may now have more than one
// gnome to choose among, and plus the lockCaredDays check on the three named one-of-ones.
// ============================================================================

// List offers tokenID, which the caller must own, for sale. The lock: a named one-of-one
// (character != "") cannot be listed until it has lockCaredDays cared days; an ordinary gnome
// has no such restriction, trading from the moment it is minted (MINT.md section 12/13).
func List(cur realm, tokenID string, priceUgnot int64, buyer address, days int64) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: list accepts no coins; only Buy takes payment")
	}

	if tokenID == genesisTokenID {
		panic("garden: the genesis gnome belongs to nobody and can never be listed")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: list requires a valid caller address")
	}

	owner, ok := ownerOfToken(tokenID)
	if !ok || owner != caller {
		panic("garden: you do not own that gnome")
	}

	gv := gnomes.Get(tokenID)
	g, isGnome := gv.(*gnome)
	if !isGnome || g == nil {
		panic("garden: that tokenID does not exist")
	}

	if g.character != "" && g.caredDayCount < lockCaredDays {
		panic("garden: " + g.character + " is one of the three named one-of-ones and cannot be listed until it has " +
			strconv.FormatInt(lockCaredDays, 10) + " cared days; it has " + strconv.FormatInt(g.caredDayCount, 10))
	}

	if priceUgnot < 0 {
		panic("garden: a price cannot be negative")
	}
	if priceUgnot > maxPriceUgnot {
		panic("garden: price exceeds the maximum of " + strconv.FormatInt(maxPriceUgnot, 10) + " ugnot")
	}
	if days < 1 || days > maxListingDays {
		panic("garden: a listing lasts between 1 and " + strconv.FormatInt(maxListingDays, 10) + " days")
	}

	buyer = address(lowerASCII(string(buyer)))
	if buyer != address("") {
		if !buyer.IsValid() {
			panic("garden: reserved buyer is not a valid address; pass an empty address to let anyone buy")
		}
		if buyer == caller {
			panic("garden: you cannot reserve your own gnome for yourself")
		}
	}

	now := time.Now().Unix()
	listings.Set(tokenID, &listing{
		seller:     caller,
		priceUgnot: priceUgnot,
		buyer:      buyer,
		listedAt:   now,
		expiresAt:  now + days*daySeconds,
	})

	feeUgnot := feeFor(priceUgnot)
	chain.Emit(
		"List",
		"seller", caller.String(),
		"tokenId", tokenID,
		"priceUgnot", strconv.FormatInt(priceUgnot, 10),
		"feeUgnot", strconv.FormatInt(feeUgnot, 10),
		"totalUgnot", strconv.FormatInt(priceUgnot+feeUgnot, 10),
		"buyer", buyer.String(),
		"expiresAt", strconv.FormatInt(now+days*daySeconds, 10),
	)
}

// Cancel withdraws the caller's own listing on tokenID. Only the seller who created it may.
func Cancel(cur realm, tokenID string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: cancel accepts no coins; only Buy takes payment")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: cancel requires a valid caller address")
	}

	l, ok := listingFor(tokenID)
	if !ok {
		panic("garden: that gnome is not for sale")
	}
	if l.seller != caller {
		panic("garden: only the seller can cancel their own listing")
	}

	listings.Remove(tokenID)
	chain.Emit("Cancel", "seller", caller.String(), "tokenId", tokenID)
}

// Buy purchases the listed gnome tokenID. v4's validate-then-commit shape, unchanged, MINUS the
// one-gnome-per-address refusal: MINT.md section 2a removes the hold cap from Buy specifically,
// and only from Buy -- Claim's hasRolled gate is the cap that still matters, and this function
// never touches it.
func Buy(cur realm, tokenID string) {
	if !cur.Previous().IsUserCall() {
		panic("garden: buy must be called directly by a wallet, not through another realm; the coins attached to a transaction belong to the realm the wallet called")
	}
	buyer := cur.Previous().Address()
	if !buyer.IsValid() {
		panic("garden: buy requires a valid caller address")
	}

	if tokenID == genesisTokenID {
		panic("garden: the genesis gnome belongs to nobody and can never be bought")
	}

	l, ok := listingFor(tokenID)
	if !ok {
		panic("garden: that gnome is not for sale")
	}

	now := time.Now().Unix()
	if now > l.expiresAt {
		panic("garden: that listing has expired; the seller must list again")
	}
	if l.seller == buyer {
		panic("garden: you cannot buy your own gnome")
	}
	if l.buyer != address("") && l.buyer != buyer {
		panic("garden: that gnome is reserved for a different buyer")
	}

	tid := grc721.TokenID(tokenID)
	owner, err := token.OwnerOf(tid)
	if err != nil || owner != l.seller {
		panic("garden: that listing is stale; the seller no longer owns that gnome")
	}
	gv := gnomes.Get(tokenID)
	g, isGnome := gv.(*gnome)
	if !isGnome || g == nil {
		panic("garden: that listing names a gnome this realm does not hold")
	}

	feeUgnot := feeFor(l.priceUgnot)
	total := l.priceUgnot + feeUgnot
	send := unsafe.OriginSend()
	if !exactUgnot(send, total) {
		panic("garden: buy requires exactly " + strconv.FormatInt(total, 10) + ugnotDenom +
			" attached (" + strconv.FormatInt(l.priceUgnot, 10) + " price + " +
			strconv.FormatInt(feeUgnot, 10) + " fee); got " + coinsString(send))
	}

	// ---- commit. Nothing below this line can fail on chain. ----

	transferGate = tokenID
	if err := ledger.TransferFrom(l.seller, l.seller, buyer, tid); err != nil {
		panic(err)
	}
	transferGate = ""

	removeOwnerToken(l.seller, tokenID)
	addOwnerToken(buyer, tokenID)
	listings.Remove(tokenID)

	// Active-token bookkeeping (mint one, hold many, play one). If this was the seller's awake
	// gnome, they fall asleep entirely rather than another of their gnomes quietly becoming
	// active -- switching is always a deliberate Wake, never a side effect of a sale. If the
	// buyer currently has nothing awake at all, this purchase becomes their active gnome
	// automatically, so a first-time buyer is never left with nothing playable.
	if av, isActive := activeToken.Get(l.seller.String()).(string); isActive && av == tokenID {
		activeToken.Remove(l.seller.String())
	}
	if !activeToken.Has(buyer.String()) {
		activeToken.Set(buyer.String(), tokenID)
	}

	settled := int64(0)
	for i := 0; i < numPlots; i++ {
		p := &g.plots[i]
		if p.plantedAt == 0 {
			continue
		}
		if now >= p.readyAt {
			settled += harvestPerPlot
		} else {
			settled += plantCost
		}
		p.plantedAt = 0
		p.readyAt = 0
	}
	if settled > 0 {
		setBalance(l.seller, balanceOf(l.seller)+settled)
	}

	g.acquiredAt = now
	g.saleCount++
	g.lastActionAt = now
	// lastWokenAt resets here too, same as lastActionAt, whether or not this purchase becomes
	// the buyer's active gnome below -- if it does not (buyer already has something awake), this
	// value is simply overwritten by the eventual explicit Wake that does activate it. Either
	// way, nothing the SELLER (or anyone else) did with this token before the sale can be
	// backfilled by the BUYER afterward: SaveDay's floor cannot reach earlier than this moment.
	g.lastWokenAt = now
	gnomes.Set(tokenID, g)

	grantStartingPurseIfNew(buyer)

	bank := banker.NewBanker(banker.BankerTypeOriginSend, cur)
	me := cur.Address()
	if l.priceUgnot > 0 {
		bank.SendCoins(me, l.seller, chain.Coins{{Denom: ugnotDenom, Amount: l.priceUgnot}})
	}
	bank.SendCoins(me, fee.recipient, chain.Coins{{Denom: ugnotDenom, Amount: feeUgnot}})

	chain.Emit(
		"Sale",
		"tokenId", tokenID,
		"seller", l.seller.String(),
		"buyer", buyer.String(),
		"priceUgnot", strconv.FormatInt(l.priceUgnot, 10),
		"feeUgnot", strconv.FormatInt(feeUgnot, 10),
		"feeRecipient", fee.recipient.String(),
		"settledAcorns", strconv.FormatInt(settled, 10),
	)
}

// ============================================================================
// Readers
// ============================================================================

func Listing(tokenID string) (seller address, priceUgnot int64, buyer address, listedAtUnix, expiresAtUnix, feeUgnot, totalUgnot int64, found bool) {
	l, ok := listingFor(tokenID)
	if !ok {
		return address(""), 0, address(""), 0, 0, 0, 0, false
	}
	fee := feeFor(l.priceUgnot)
	return l.seller, l.priceUgnot, l.buyer, l.listedAt, l.expiresAt, fee, l.priceUgnot + fee, true
}

func TotalListings() int64 {
	return int64(listings.Size())
}

func ListingsPage(offset, limit int) []string {
	if offset < 0 {
		panic("garden: offset must not be negative")
	}
	if limit <= 0 {
		panic("garden: limit must be positive")
	}
	if limit > maxListingsPageSize {
		limit = maxListingsPageSize
	}
	tokenIDs := make([]string, 0, limit)
	listings.IterateByOffset(offset, limit, func(key string, value any) bool {
		tokenIDs = append(tokenIDs, key)
		return false
	})
	return tokenIDs
}

func QuoteFee(priceUgnot int64) (feeUgnot, totalUgnot int64) {
	f := feeFor(priceUgnot)
	return f, priceUgnot + f
}

func FeeRules() string {
	return "saleFeeRateBps=" + strconv.FormatInt(fee.rateBps, 10) +
		";saleFeeFloorUgnot=" + strconv.FormatInt(fee.floorUgnot, 10) +
		";saleFeeRecipient=" + fee.recipient.String()
}

func Provenance(tokenID string) (adoptedAtUnix, acquiredAtUnix, saleCount int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, false
	}
	return g.adoptedAt, g.acquiredAt, g.saleCount, true
}

// ---- v6's new readers. FIVE additions, every one of them read-only. The existing readers'
// SIGNATURES ARE ALL UNCHANGED FROM v5 ON PURPOSE, including Provenance's and GnomeByToken's,
// even though the round and the name would both have fitted naturally into them: the app already
// reads v5's shapes, and widening a tuple return breaks every existing caller for no gain that a
// dedicated reader does not already give. Reads are free and unmetered, so "one more query" costs
// a caller nothing; a changed signature costs them a rewrite.

// Name returns tokenID's name, or found=false if there is no such token.
//
// A name of "" is a REAL, EXPECTED ANSWER, not an error: it means this gnome has not been named
// yet, which is the state every ordinary gnome mints in. found reports whether the TOKEN exists,
// never whether it has a name -- check the string for that.
func Name(tokenID string) (name string, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return "", false
	}
	return g.name, true
}

// NameOwner resolves a name to the tokenID currently carrying it, matching the same way SetName
// refuses duplicates: on the canonical form, so any capitalisation or spacing of a taken name
// finds it. This is the uniqueness index read back, and the honest answer to "who is Fennick".
func NameOwner(name string) (tokenID string, found bool) {
	return nameOwnerOf(canonicalNameKey(name))
}

// NameAvailability answers "would SetName accept this name, and if not why" WITHOUT a transaction
// -- a free query against the same assertNameAssignable the write path uses, so the realm itself
// is the authority the app checks against instead of a second copy of the rules that can drift
// from it. reason is "" when ok is true, and the realm's own refusal message otherwise.
//
// The tokenID argument matters for exactly one case: a name is available TO THE TOKEN THAT
// ALREADY HOLDS IT (re-capitalising your own gnome's name). Pass "" to ask the general question
// "is this name free for somebody new", which is what an app naming a fresh gnome wants.
//
// THIS IS A CONVENIENCE, NOT THE AUTHORITY, and the distinction is load-bearing: a true answer
// here can be made false by somebody else's transaction landing first. SetName re-checks
// everything itself, always -- this function cannot be used to skip a check, only to avoid
// wasting a player's gas on a refusal that was already knowable.
//
// NOTE ON SHAPE, because the obvious implementation is a trap on this toolchain: this does NOT
// call SetName's validator and recover() from its panic. `recover()` does not reliably catch a
// panic across a realm boundary in Gno (MEMORY.md records this costing this project real time),
// and a reader should not have to reason about whether a same-realm call is the exception. So the
// rules live in nameAssignabilityProblem, which RETURNS its refusal instead of panicking it, and
// both this reader and assertNameAssignable call that one copy. No recover anywhere.
func NameAvailability(name string, tokenID string) (ok bool, reason string) {
	reason = nameAssignabilityProblem(name, tokenID)
	return reason == "", reason
}

// SettledRound returns the drand round whose published signature produced tokenID's parts --
// v6 FIX 2, and the one query that makes this project's "provably unrigged" claim (ECONOMY.md
// section 1) checkable by a holder rather than merely asserted at them. Fetch
// https://api.drand.sh/<chain>/public/<round>, hash its signature, and re-derive the parts with
// this file's own seedFor/drawWeighted against your own address: a round signed by drand before
// anybody knew who would pin it cannot have been chosen to produce a particular gnome.
//
// round == 0 means this token was never produced by a roll, which is true of exactly one token
// ever: the genesis gnome. found reports whether the token exists.
func SettledRound(tokenID string) (round int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, false
	}
	return g.settledRound, true
}

// MaxNameLen is maxNameLen read back, so the app can show the limit it will be held to instead of
// hardcoding a second copy of the number (app/js/config.js's NAME_MAX_LEN is the other copy, and
// the two are kept equal by hand and by TestMaxNameLenMatchesTheAppsRule).
func MaxNameLen() int64 { return int64(maxNameLen) }

// GnomeByToken: the basic facts for one token -- hat, coat, eyes, nose, character (empty for an
// ordinary gnome), level, calling and the moment it was minted. SIGNATURE UNCHANGED FROM v5 --
// the name is Name(tokenID) and the round is SettledRound(tokenID); see the note above.
func GnomeByToken(tokenID string) (hat, coat string, eyes, nose int64, character string, level int64, gnomeType string, adoptedAtUnix int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return "", "", 0, 0, "", 0, "", 0, false
	}
	return g.hat, g.coat, g.eyes, g.nose, g.character, g.level, g.gnomeType, g.adoptedAt, true
}

// ActiveGnome returns the tokenID that is awake for addr right now, or found=false if nothing
// is (never claimed or bought a gnome, or sold the only one and has not Woken another since).
func ActiveGnome(addr address) (tokenID string, found bool) {
	tid, isStr := activeToken.Get(addr.String()).(string)
	if !isStr || tid == "" {
		return "", false
	}
	return tid, true
}

// OwnerTokens returns every tokenID addr currently holds, in no particular order. Unbounded and
// unpaginated deliberately: batchCap is 24 and the genesis gnome is permanently unreachable to
// any wallet, so no address can ever hold more than batchCap tokens, which is a small, fixed
// upper bound this call is always safely within.
func OwnerTokens(addr address) []string {
	v := ownerTokens.Get(addr.String())
	list, ok := v.(*[]string)
	if !ok || list == nil {
		return []string{}
	}
	out := make([]string, len(*list))
	copy(out, *list)
	return out
}

// TokensPage: the global token enumerator, hollowmere/v1's own pattern (TotalClaimants/
// ClaimantsPage) applied here, because v4's own missing-enumerator lesson (DECISIONS.md:780-791,
// arena/v1 shipping with no challenge inbox and no way to ever add one) is unavailable to fix
// after deploy and twenty lines now is cheaper than "unavailable forever" later.
func TokensPage(offset, limit int) []string {
	if offset < 0 {
		panic("garden: offset must not be negative")
	}
	if limit <= 0 {
		panic("garden: limit must be positive")
	}
	if limit > maxGnomesPageSize {
		limit = maxGnomesPageSize
	}
	ids := make([]string, 0, limit)
	gnomes.IterateByOffset(offset, limit, func(key string, value any) bool {
		ids = append(ids, key)
		return false
	})
	return ids
}

func GardenState(tokenID string) (plantedAtCsv, readyAtCsv string, readyCount int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return "", "", 0, false
	}
	now := time.Now().Unix()
	planted := make([]string, 0, numPlots)
	ready := make([]string, 0, numPlots)
	for i := 0; i < numPlots; i++ {
		p := g.plots[i]
		planted = append(planted, strconv.FormatInt(p.plantedAt, 10))
		ready = append(ready, strconv.FormatInt(p.readyAt, 10))
		if p.plantedAt != 0 && now >= p.readyAt {
			readyCount++
		}
	}
	return strings.Join(planted, ","), strings.Join(ready, ","), readyCount, true
}

func CareState(tokenID string) (belly, cheer, acorns, totalXp, lastPatAtUnix, lastHappyEventAtUnix, lastActionAtUnix int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, 0, 0, 0, 0, false
	}
	owner, hasOwner := ownerOfToken(tokenID)
	acornBalance := int64(0)
	if hasOwner {
		acornBalance = balanceOf(owner)
	}
	now := time.Now().Unix()
	return meterNow(g.belly, g.bellyAt, now, bellyDropEveryHours),
		meterNow(g.cheer, g.cheerAt, now, cheerDropEveryHours),
		acornBalance, g.totalXp, g.lastPatAt, g.lastHappyEventAt, g.lastActionAt, true
}

func MeterState(tokenID string) (belly, bellyAtUnix, cheer, cheerAtUnix int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, 0, false
	}
	return g.belly, g.bellyAt, g.cheer, g.cheerAt, true
}

func Progress(tokenID string) (xpGarden, xpTinker, harvestCount, lastTinkerAtUnix, caredDayCount, dailyCareXpSpent, dailyCareDay int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, 0, 0, 0, 0, false
	}
	return g.xpGarden, g.xpTinker, g.harvestCount, g.lastTinkerAt,
		g.caredDayCount, g.dailyCareXp, g.dailyCareDay, true
}

func CaredDays(tokenID string) (daysCsv string, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return "", false
	}
	return caredDaysCsv(g), true
}

func Mood(tokenID string) (mood string, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return "", false
	}
	now := time.Now().Unix()
	belly := meterNow(g.belly, g.bellyAt, now, bellyDropEveryHours)
	return moodNow(belly, g.lastPatAt, g.lastHappyEventAt, g.adoptedAt, now, hungryAtOrBelow), true
}

// IsLocked reports whether tokenID is currently refused by List's lockCaredDays check -- true
// only for a named one-of-one with fewer than lockCaredDays cared days; false for every ordinary
// gnome, always, and false for a named one-of-one once it has enough cared days.
func IsLocked(tokenID string) (locked bool, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return false, false
	}
	return g.character != "" && g.caredDayCount < lockCaredDays, true
}

func CollectionInfo() (name, symbol string) {
	return collectionName, collectionSymbol
}

func TotalSupply() int64 {
	return token.TotalSupply()
}

func BalanceOf(addr address) int64 {
	n, err := token.BalanceOf(addr)
	if err != nil {
		return 0
	}
	return n
}

func OwnerOfToken(tokenID string) (owner address, found bool) {
	return ownerOfToken(tokenID)
}

func TotalGnomes() int64 {
	return token.TotalSupply()
}

func Acorns(addr address) (acorns int64, found bool) {
	if !balances.Has(addr.String()) {
		return 0, false
	}
	return balanceOf(addr), true
}

// ---- counted rarity readers (MINT.md section 13): "nine gnomes in the world have this nose"
// has to be a chain fact. These four, plus CharacterOwner below, are that fact.

func EyesCount(id int64) int64    { return eyesCount(id) }
func NoseCount(id int64) int64    { return noseCount(id) }
func HatCount(hat string) int64   { return hatCount(hat) }
func CoatCount(coat string) int64 { return coatCount(coat) }

// CharacterOwner resolves one of the three named one-of-ones, or the genesis gnome under its
// own name "genesis", to its tokenID, once minted. (Second-audit-pass nitpick: an earlier
// version of this comment said only "one of the three named one-of-ones", which stopped being
// true the moment init() registered "genesis" here too -- see init()'s own comment for why that
// registration is safe and never touches the three editions' cap.)
func CharacterOwner(name string) (tokenID string, found bool) {
	v := characterOwner.Get(name)
	s, ok := v.(string)
	if !ok {
		return "", false
	}
	return s, true
}

// ---- the mint's own state, read back.

func IsAllowlisted(addr address) bool {
	return allowlist.Has(addr.String())
}

func HasRolled(addr address) bool {
	return hasRolled.Has(addr.String())
}

func PendingClaim(addr address) (round, claimedAtUnix int64, found bool) {
	v := pendingClaims.Get(addr.String())
	pc, ok := v.(*pendingClaim)
	if !ok || pc == nil {
		return 0, 0, false
	}
	return pc.round, pc.claimedAt, true
}

// BatchStatus: mintedCount is reservations made by Claim (gates batchCap); settledCount is
// completions made by Settle (always <= mintedCount, the gap being pending, unsettled claims);
// namedMinted is how many of the three named one-of-ones have actually been minted so far --
// read live off characterOwner rather than a separate counter, so there is only ever one source
// of truth for "has this edition been taken".
func BatchStatus() (mintedSoFar, settledSoFar, batchCapOut, namedMinted, namedCapOut int64) {
	// NAMED RETURNS DELIBERATELY DO NOT SHARE A NAME WITH THE PACKAGE-LEVEL mintedCount/
	// settledCount VARS. An earlier version of this function used mintedCount/settledCount as
	// its own named returns, which SHADOWED the package vars for the whole function body, so
	// `return mintedCount, settledCount, ...` returned the zero-valued local named returns
	// instead of the real package state -- this function always reported a fresh batch,
	// silently, with no error, which TestBatchClosesAtCapAndRefusesFurtherClaims caught by
	// actually driving claims until the realm said the batch was full and finding it never did.
	// Found and fixed before audit; recorded here rather than silently corrected, the same
	// discipline this file's own package doc uses for the Settle timing flaw.
	nm := int64(0)
	for _, name := range namedEditionOrder {
		if characterOwner.Has(name) {
			nm++
		}
	}
	return mintedCount, settledCount, batchCap, nm, numNamedEditions
}

func GenesisTokenID() string {
	return genesisTokenID
}

func AdminState() (admin address, frozen bool) {
	return address(adminAddress), rulesFrozen
}

func LastWakeDay(addr address) (day int64, found bool) {
	v, ok := lastWakeDay.Get(addr.String()).(int64)
	return v, ok
}

// ============================================================================
// Render
// ============================================================================

// Render DELIBERATELY ECHOES NO PLAYER-SUPPLIED STRING, and v6 keeps it that way even though it
// now has gnome names it could print. THIS IS THE DEFENCE AGAINST ABUSIVE NAMES ON A PUBLIC PAGE,
// and it is structural rather than a filter: gnoweb renders this output as markdown, so a page
// that listed names would be a markdown sink fed by arbitrary player input, and the project would
// then own a moderation problem on an immutable realm with no moderation surface. v5's own
// adversarial review (ATTACK-REVIEW.md, "Render sanitisation") recorded "no injection surface" as
// a property of this function; adding a name here would have been the one change in this file
// that falsified an audited claim.
//
// Belt and braces, because "nothing echoes names today" is only one edit away from being false:
// the name charset allowlist (letters, digits, space, hyphen, apostrophe -- see validNameRune)
// excludes every markdown metacharacter there is. No '[', ']', '(', ')', '<', '>', '*', '_',
// backtick, pipe or newline can appear in a name, so even a future Render that DID print one
// could not be made to inject link syntax, a raw HTML tag or a table break. An abusive name is
// therefore limited to being rude in words, visible only to someone who queries that specific
// token, never on a page this project publishes.
func Render(path string) string {
	if path != "" {
		return "garden/v6: unknown path"
	}
	minted, settled, cap_, namedMinted, namedCap := BatchStatus()
	out := "# Gnotchi gnomes -- garden/v6\n\n"
	out += "Batch One: " + strconv.FormatInt(minted, 10) + " claimed, " +
		strconv.FormatInt(settled, 10) + " settled, of " + strconv.FormatInt(cap_, 10) + " ever.\n\n"
	out += "Named one-of-ones minted: " + strconv.FormatInt(namedMinted, 10) + " of " + strconv.FormatInt(namedCap, 10) + ".\n\n"
	out += "Total supply (including the genesis gnome): " + strconv.FormatInt(TotalSupply(), 10) + "\n\n"
	out += "Free to claim, if your address is on the allowlist. One roll per wallet, ever. " +
		"Claim pins a future drand round; Settle, callable by anyone once that round is " +
		"published, mints the result.\n"
	return out
}

// ============================================================================
// Internal helpers
// ============================================================================

func gnomeByTokenID(tokenID string) (*gnome, bool) {
	v := gnomes.Get(tokenID)
	g, ok := v.(*gnome)
	if !ok || g == nil {
		return nil, false
	}
	return g, true
}

// activeGnomeForAddr resolves addr's AWAKE gnome, if any. This is the one and only lookup
// SaveDay and ChooseType use -- there is deliberately no "the gnome for this address" any more.
func activeGnomeForAddr(addr address) (tid string, g *gnome, found bool) {
	tidStr, ok := activeToken.Get(addr.String()).(string)
	if !ok || tidStr == "" {
		return "", nil, false
	}
	gg, ok := gnomeByTokenID(tidStr)
	if !ok {
		return "", nil, false
	}
	return tidStr, gg, true
}

func ownerOfToken(tokenID string) (owner address, found bool) {
	if !gnomes.Has(tokenID) {
		return address(""), false
	}
	o, err := token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		return address(""), false
	}
	return o, true
}

// addOwnerToken / removeOwnerToken: the hold-many index. ownerTokens stores a *[]string per
// owner so repeated appends mutate one allocation rather than replacing the tree entry every
// time; removal does a linear scan, which is fine at this realm's permanent, tiny upper bound
// (batchCap = 24 tokens that will ever exist, minus the one permanently unreachable genesis
// gnome, so no owner's slice is ever longer than 24 entries for the whole life of this realm).
func addOwnerToken(addr address, tokenID string) {
	v := ownerTokens.Get(addr.String())
	list, ok := v.(*[]string)
	if !ok || list == nil {
		fresh := []string{tokenID}
		ownerTokens.Set(addr.String(), &fresh)
		return
	}
	*list = append(*list, tokenID)
}

func removeOwnerToken(addr address, tokenID string) {
	v := ownerTokens.Get(addr.String())
	list, ok := v.(*[]string)
	if !ok || list == nil {
		return
	}
	out := make([]string, 0, len(*list))
	for _, id := range *list {
		if id != tokenID {
			out = append(out, id)
		}
	}
	*list = out
}

func balanceOf(addr address) int64 {
	v := balances.Get(addr.String())
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func setBalance(addr address, v int64) {
	if v < 0 {
		panic("garden: acorn balance cannot go negative")
	}
	balances.Set(addr.String(), v)
}

func grantStartingPurseIfNew(addr address) {
	if !balances.Has(addr.String()) {
		balances.Set(addr.String(), acornsStart)
	}
}

func feeFor(priceUgnot int64) int64 {
	return fee.floorUgnot + priceUgnot*fee.rateBps/10000
}

func exactUgnot(send chain.Coins, want int64) bool {
	if len(send) != 1 {
		return false
	}
	return send[0].Denom == ugnotDenom && send[0].Amount == want
}

func coinsString(c chain.Coins) string {
	if len(c) == 0 {
		return "nothing"
	}
	out := ""
	for i, coin := range c {
		if i > 0 {
			out += ","
		}
		out += strconv.FormatInt(coin.Amount, 10) + coin.Denom
	}
	return out
}

func listingFor(tokenID string) (*listing, bool) {
	v := listings.Get(tokenID)
	l, ok := v.(*listing)
	if !ok || l == nil {
		return nil, false
	}
	if l.priceUgnot < 0 {
		return nil, false
	}
	return l, true
}

// ============================================================================
// v6 FIX 1: name validation and canonicalisation. validNameLength/validNameCharset/
// hasVisibleNameContent/validNameRune/invisibleLetterRunes are v4's OWN IMPLEMENTATIONS, carried
// back byte-for-byte -- three audit rounds' worth of work (v4's own comment), including v2's
// audit fix F3 (\uXXXX escapes rather than literal invisible glyphs, so the denylist is readable
// in an editor and cannot be silently emptied by a formatter that strips default-ignorable
// characters). They are NOT re-derived here and must not be "tidied": every line of that
// allowlist was argued for once already.
//
// THE DENYLIST IS THE PART THAT MATTERS AND THE PART THAT LOOKS REDUNDANT. All four entries are
// genuinely LETTERS by Unicode's own classification, so unicode.IsLetter accepts every one of
// them -- and all four render as NOTHING AT ALL. They exist in fonts purely as filler. Without
// this list, "Hob" and "Hob<U+3164>" are different names that look identical in every UI either
// will ever be shown in, which is impersonation with no defence available to the person being
// impersonated. app/js/config.js's NAME_INVISIBLE_LETTERS is the same four code points, exposed
// there for the app's own tests; TestEveryInvisibleLetterIsRefused table-drives this map directly
// so neither side's coverage can silently fall behind the other (config.js's finding Y3: before
// that change every test on both sides of the stack only ever exercised U+3164).
//
// CARRIED FORWARD UNCHANGED, AND STILL AN OPEN PRODUCT QUESTION, NOT A SETTLED ONE: this
// allowlist excludes every COMBINING MARK (chiefly Unicode category Mn), which makes zalgo names
// structurally impossible -- and also makes NFD Latin, Devanagari, Thai, vocalised Hebrew and
// Arabic unspellable. realms/garden/NOTES.md records that trade-off in full as the owner's to
// revisit (v4's third audit round, finding Y7). v6 carries it forward rather than silently
// re-deciding it, exactly as v4 carried it forward from v1/v2. Precomposed letters (é as a single
// code point) are accepted fine; the exclusion is specifically and only about combining marks.
// ============================================================================

func validNameLength(name string) bool {
	// RuneCountInString, never len(): len() counts BYTES, so a 24-character name in any
	// non-ASCII script would be refused for being "too long" while an ASCII one of the same
	// visible length passed.
	n := utf8.RuneCountInString(name)
	return n > 0 && n <= maxNameLen
}

func validNameCharset(name string) bool {
	for _, r := range name {
		if !validNameRune(r) {
			return false
		}
	}
	return true
}

func hasVisibleNameContent(name string) bool {
	for _, r := range name {
		if r != ' ' {
			return true
		}
	}
	return false
}

// invisibleLetterRunes: the four code points that are Unicode LETTERS and render as nothing. See
// the section comment above for why a letter allowlist alone cannot catch these. Written as
// \uXXXX escapes (v2's audit fix F3) so they survive an editor or formatter that strips
// default-ignorable characters -- a denylist that can be silently emptied protects nothing.
//
// v3 through v5 carried this comment while the entries themselves were literal invisible glyphs,
// so the comment was false about its own code for three versions and the protection it describes
// was not actually in place. Restored here, with the escapes BACK IN THE SOURCE this time.
//
// The escapes alone are only half of F3. TestEveryInvisibleLetterIsRefused table-drives this map,
// which means it tests whatever the map happens to contain -- swap one entry for an ordinary
// letter and that test still passes while the realm ships banning the letter and accepting the
// invisible one. TestInvisibleLetterRunesIsExactlyFourPinnedCodepoints is the other half: it
// pins all four code points BY ESCAPE, independently of this map's contents, so that
// substitution fails loudly.
var invisibleLetterRunes = map[rune]bool{
	'\u115f': true, // HANGUL CHOSEONG FILLER
	'\u1160': true, // HANGUL JUNGSEONG FILLER
	'\u3164': true, // HANGUL FILLER
	'\uffa0': true, // HALFWIDTH HANGUL FILLER
}

func validNameRune(r rune) bool {
	switch r {
	case ' ', '-', '\'':
		return true
	}
	if invisibleLetterRunes[r] {
		return false
	}
	return unicode.IsLetter(r) || unicode.IsDigit(r)
}

// smartPunctuationRunes: the four code points iOS substitutes by default for a straight
// apostrophe or hyphen. NONE of them is accepted by validNameRune -- this map exists only so the
// refusal can SAY SO instead of reporting a generic charset failure to a player who typed an
// ordinary apostrophe on an ordinary phone. See nameAssignabilityProblem's own comment on why
// this realm refuses rather than folds them.
var smartPunctuationRunes = map[rune]bool{
	'‘': true, // LEFT SINGLE QUOTATION MARK
	'’': true, // RIGHT SINGLE QUOTATION MARK
	'–': true, // EN DASH
	'—': true, // EM DASH
}

func hasSmartPunctuation(name string) bool {
	for _, r := range name {
		if smartPunctuationRunes[r] {
			return true
		}
	}
	return false
}

// canonicalNameKey folds a name to the key nameOwner and reservedNameKeys compare on: lowercase
// ASCII, runs of spaces collapsed to one, leading and trailing spaces removed.
//
// THE STORED NAME AND THE KEY ARE DELIBERATELY TWO DIFFERENT STRINGS. The gnome keeps the name
// its owner typed, exactly as typed, because that is what a person chose and the app should show
// it back to them unaltered. The KEY exists only to answer "is this the same name as that one"
// for uniqueness and reservation, and for THAT question "Hob", "hob", "HOB" and "Hob" with two
// spaces in it are all plainly the same name. Keying on the raw string instead would make
// uniqueness worthless and would let anyone walk around the one-of-one reservation by changing
// one letter's case.
//
// WHAT IT DELIBERATELY DOES NOT DO, stated plainly rather than left for a reader to discover:
// it does not close cross-script HOMOGLYPHS. Cyrillic "А", Greek "Ο" and fullwidth "Ａ" are all
// Unicode letters, all accepted, and all visually confusable with their Latin counterparts, so
// "Нob" with a Cyrillic Н is a different key from "Hob" and will be allowed. This is the SAME
// accepted residual app/js/config.js's NAME_CHARSET_RE documents in its own comment, carried
// forward knowingly: closing it properly needs a confusables table (thousands of mappings,
// versioned by Unicode, compiled into an immutable realm) and the honest cost/benefit at a
// 24-gnome collection does not justify it. The defence that IS in place for the case that
// actually matters -- the three cap-one editions -- is that their names are reserved and
// unrenameable, so a homoglyph impostor can exist but can never hold the real key, and
// CharacterOwner (not a name lookup) is what resolves the genuine Hob.
//
// ASCII-only lowercasing, following lowerASCII's own v4 reasoning: strings.ToLower would apply
// locale-independent Unicode case folding whose behaviour is a toolchain-version detail on an
// immutable realm, and the keys that MUST match exactly (reservedNameKeys) are all ASCII.
func canonicalNameKey(name string) string {
	lowered := lowerASCII(name)

	out := make([]byte, 0, len(lowered))
	prevSpace := true // true at the start, so leading spaces are dropped by the same test
	for i := 0; i < len(lowered); i++ {
		c := lowered[i]
		if c == ' ' {
			if prevSpace {
				continue
			}
			prevSpace = true
			out = append(out, c)
			continue
		}
		prevSpace = false
		out = append(out, c)
	}
	// One trailing space may survive the loop above (a name ending in a space emits it before the
	// loop ends); drop it.
	if len(out) > 0 && out[len(out)-1] == ' ' {
		out = out[:len(out)-1]
	}
	return string(out)
}

func nameOwnerOf(key string) (tokenID string, found bool) {
	v := nameOwner.Get(key)
	s, ok := v.(string)
	if !ok || s == "" {
		return "", false
	}
	return s, true
}

// lowerASCII: v4's own helper, unchanged -- ASCII-only on purpose (see v4's own comment on why
// not strings.ToLower).
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

func anyPlotPlanted(g *gnome) bool {
	for i := 0; i < numPlots; i++ {
		if g.plots[i].plantedAt != 0 {
			return true
		}
	}
	return false
}

func eyesCount(id int64) int64 {
	v := eyesCounts.Get(strconv.FormatInt(id, 10))
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func noseCount(id int64) int64 {
	v := noseCounts.Get(strconv.FormatInt(id, 10))
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func hatCount(hat string) int64 {
	v := hatCounts.Get(hat)
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func coatCount(coat string) int64 {
	v := coatCounts.Get(coat)
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

// ---- parsing, meters, mood, level: v4's own proven implementations, byte-for-byte, with
// rule() lookups replaced by this file's fixed constants (see the package doc: no SetRule here).

func parseActions(raw string) []saveAction {
	if raw == "" {
		return nil
	}

	count := 1
	for i := 0; i < len(raw); i++ {
		if raw[i] == ';' {
			count++
		}
	}
	if count > maxActionsPerCall {
		panic("garden: too many actions in one call; the limit is " + strconv.Itoa(maxActionsPerCall))
	}

	parts := strings.Split(raw, ";")
	actions := make([]saveAction, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			panic("garden: empty action entry")
		}
		fields := strings.Split(part, ":")
		switch fields[0] {
		case actionPat, actionFeed, actionTinker:
			if len(fields) != 2 {
				panic("garden: malformed action: " + quoteAction(part))
			}
			actions = append(actions, saveAction{kind: fields[0], at: parseUnixField(fields[1], part)})
		case actionPlant, actionHarvest:
			if len(fields) != 3 {
				panic("garden: malformed action: " + quoteAction(part))
			}
			actions = append(actions, saveAction{
				kind: fields[0],
				plot: parsePlotField(fields[1], part),
				at:   parseUnixField(fields[2], part),
			})
		default:
			panic("garden: unknown action kind: " + quoteAction(part))
		}
	}
	return actions
}

func quoteAction(part string) string {
	return "\"" + part + "\""
}

func parseUnixField(s, part string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 {
		panic("garden: malformed timestamp in action: " + quoteAction(part))
	}
	return n
}

func parsePlotField(s, part string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 || n >= numPlots {
		panic("garden: malformed plot index in action: " + quoteAction(part))
	}
	return n
}

func dayNumber(unixSeconds int64) int64 { return unixSeconds / daySeconds }

// recordCaredDay reports, via banked, whether it actually incremented g.caredDayCount -- false
// on the no-op branch (day == g.lastCaredDay already, e.g. a second SaveDay call the same UTC
// day, or a token bought mid-day that the SELLER had already banked that exact day for before
// the sale). SaveDay's own caller-scoped gate (lastCaredDayForOwner) depends on this: it must
// only spend the owner's one-bank-per-day allowance on a call that actually banked something,
// never on a no-op -- a gno-auditor re-audit found that an unconditional advance let a buyer's
// SaveDay on a token the seller had already banked that day silently consume the buyer's own
// allowance for the rest of that day, denying an otherwise fully legitimate cared day on a
// DIFFERENT, genuinely active token later the same day. See the call site in SaveDay.
func recordCaredDay(g *gnome, day int64) (banked bool) {
	if g.lastCaredDay == 0 {
		g.lastCaredDay = day
		g.caredMask = 1
		g.caredDayCount = 1
		return true
	}
	if day == g.lastCaredDay {
		return false
	}
	shift := uint(day - g.lastCaredDay)
	if shift >= caredWindowDays {
		g.caredMask = 1
	} else {
		g.caredMask = (g.caredMask << shift) | 1
	}
	g.lastCaredDay = day
	g.caredDayCount++
	return true
}

func caredDaysCsv(g *gnome) string {
	if g.lastCaredDay == 0 {
		return ""
	}
	days := make([]string, 0, caredWindowDays)
	for i := uint(0); i < caredWindowDays; i++ {
		if g.caredMask&(1<<i) != 0 {
			days = append(days, strconv.FormatInt(g.lastCaredDay-int64(i), 10))
		}
	}
	return strings.Join(days, ",")
}

func meterNow(value, setAt, now, dropEveryHours int64) int64 {
	if dropEveryHours <= 0 {
		return value
	}
	elapsedHours := (now - setAt) / hourSeconds
	if elapsedHours <= 0 {
		return clampMeter(value)
	}
	drops := elapsedHours / dropEveryHours
	return clampMeter(value - drops)
}

func clampMeter(v int64) int64 {
	if v < 0 {
		return 0
	}
	if v > meterMax {
		return meterMax
	}
	return v
}

func canPat(lastPatAt, now, cooldownHours int64) bool {
	if lastPatAt == 0 {
		return true
	}
	return now-lastPatAt >= cooldownHours*hourSeconds
}

func moodNow(belly, lastPatAt, lastHappyEventAt, adoptedAt, now, hungryThreshold int64) string {
	if belly <= hungryThreshold {
		return moodHungry
	}
	if lastHappyEventAt == 0 {
		if now-adoptedAt <= happyWindowHours*hourSeconds {
			return moodContent
		}
		return moodSulky
	}
	if now-lastHappyEventAt <= happyWindowHours*hourSeconds {
		return moodHappy
	}
	if now-lastHappyEventAt >= sulkyAfterHours*hourSeconds {
		return moodSulky
	}
	return moodContent
}

func xpToNext(level int64) int64 { return levelBase + levelStep*level }

func totalXpForLevel(level int64) int64 {
	if level <= 1 {
		return 0
	}
	total := int64(0)
	for l := int64(1); l < level; l++ {
		total += xpToNext(l)
	}
	return total
}

func levelFromXp(totalXp int64) int64 {
	level := int64(1)
	for level < maxLevel {
		need := totalXpForLevel(level + 1)
		if totalXp < need {
			break
		}
		level++
	}
	return level
}
