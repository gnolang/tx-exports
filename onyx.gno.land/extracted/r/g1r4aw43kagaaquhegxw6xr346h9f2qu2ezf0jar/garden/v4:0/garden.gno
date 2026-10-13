// Package garden is Gnotchi's pet realm, v4: garden/v3 plus a permanent face.
//
// WHY THIS EXISTS, in one paragraph, because a realm cannot be edited and the reason has to
// travel with the code. garden/v2 accepts `plant:0:<ts>` and `harvest:0:<ts>`, enforces the
// grow timer, moves the acorns -- and exposes no way to read a plot back. Its whole garden
// is write-only on chain. The app therefore hides the garden from any player who connects a
// wallet (app/js/home.js gates the garden card on `!gnome.chainProof`), and since harvesting
// is the only acorn income, a connected player's acorns can only ever go down. The live site
// now apologises for this in six places (app/js/config.js's WALLET_TRADEOFF_SENTENCE). There
// is no fix that is not a new realm. GardenState below is that fix; everything else here is
// either the same correction applied to eight more unreadable fields, or deliberately
// unchanged from v2.
//
// Full design, including every v2 limitation with line numbers, the migration argument, and
// the list of things deliberately left out: realms/garden/v3/DESIGN.md, which this realm
// inherits whole, and realms/garden/v4/DESIGN.md, which records only what v4 changes and why.
// Read both before changing anything here.
//
// v4 IS v3 PLUS A PERMANENT FACE, AND THREE SMALL REPAIRS. garden/v3 was deployed to onyx at
// block 336496 on 2026-10-11 and nobody adopted on it -- TotalGnomes() read 0 on 2026-10-12 --
// so replacing it costs the deploy gas and nothing else: no migration, no gnome to move. What
// changes: every gnome carries two more PERMANENT appearance ids, eyes and nose, each a small
// integer validated against a compiled-in range and written exactly once, at Adopt. That is
// SPRITES.md's "Phase 1 -- faces" (ten eyes, eight noses: sixteen looks become 1,280), which
// v3's DESIGN.md section 7.3 had argued away by applying a correct argument against OPEN-ENDED
// appearance to a closed list nobody had asked to be open. The realm records what it is given
// and validates it; whether a face is CHOSEN by the player or ROLLED by the app is deliberately
// not decided here, because a realm cannot be edited and that decision should not be frozen in
// one (DESIGN.md v4 section 3). The repairs, each cheap only while nobody has adopted: the
// acorn softlock AUDIT-DEPLOYED.md calls G9 is made unreachable by an acorn reserve in SaveDay;
// a reserved buyer typed in upper case no longer creates a listing nobody can buy; and the
// test-only fee override is gone from production code. Everything else -- the SetRule ratchet,
// the garden-settles-to-seller rule, the IsUserCall gates on Adopt and Buy, the sale, the wire
// format, every read -- is v3's, unchanged, with v3's reasoning kept in place below.
//
// GNOMES ARE TRADEABLE HERE, AND THE SALE COUNTER IS THE ONLY DOOR. TRADING-RULES.md records
// the owner's ruling of 2026-10-10 -- "gnomes AND items are tradeable, and a cut on every
// trade of both is a must" -- and MARKETPLACE-V1.md records the structural fact that decides
// the shape: a royalty implemented as a transfer hook sees transfers, not payments, so the
// only way to make the cut unavoidable is for the contract holding the asset to refuse every
// transfer path except its own sale function. That is what this realm does. There is no
// Approve, no TransferFrom, no gift, no burn, no withdrawal; a registered extension panics on
// every ledger movement unless Buy below is moving exactly that token right now. See the
// SALE section and DESIGN.md section 9. The fee and its recipient are the three SALE
// CONSTANTS at the very top of this file, decided by the owner on 2026-10-11 for the onyx
// testnet; init still gates them and refuses a value that could not work.
//
// DEPLOY STATUS IS DELIBERATELY NOT RECORDED IN THIS FILE, and neither is a claim about
// whether anyone has decided to deploy it. This comment ships on chain exactly as written
// and cannot be edited afterwards, so any status asserted here is frozen at authoring time
// and becomes a lie the moment it changes. garden/v2/gnomod.toml said "NOT deployed" in just
// such a line, was deployed hours later, and now carries that false claim on chain
// permanently. Live status lives in the repo root's STATUS.md and DECISIONS.md, which can
// still be corrected; the authority above both is the chain itself (`vm/qfile` on this path).
//
// ============================================================================
// THE ONE RULE THAT REPLACES v2's MISTAKE
// ============================================================================
//
// v2's bug class is not "a getter was forgotten". It is that a field was added to persisted
// state without a reader, on a contract that can never grow one. So:
//
//	EVERY PERSISTED FIELD HAS AN EXPORTED READER, AT DEPLOY TIME. THERE IS NO SECOND CHANCE.
//
// Anyone adding a field to `gnome` below must add it to a reader in the same change.
// TestEveryStoredFieldIsReadable pins the current field list against the current readers,
// value by value, so the failure is at least loud and local. Gno has no reflection to assert
// over, so that test cannot *detect* a new field -- the rule is still a discipline and this
// comment is not pretending otherwise.
//
// The corollary, which is why this file has no "extensible" blob getter: EXTENSIBILITY IS A
// FICTION ON AN IMMUTABLE CONTRACT. A versioned self-describing string cannot carry a field
// that did not exist at deploy time any more than a positional tuple can. This surface is
// designed for completeness now, not for growth later, because there is no later.
//
// ============================================================================
// SECURITY: NO recover(), EVER. Carried over from v1/v2/hollowmere/arena verbatim in intent.
// ============================================================================
//
// No code in this realm, now or later, may recover() around a call into ledger or token
// (grc721's PrivateLedger/Token). The sale-gate guarantee below is real, but it is NOT that
// the ledger write never happens -- it does, before the panic -- it is that an *uncaught*
// panic aborts the whole enclosing transaction, so that write (and everything else the
// transaction did) is discarded and never committed on chain. p/nt/grc721/v0/types.gno says
// this outright about extension hooks like saleGateExtension below: "Hooks run after the
// ledger write so they observe the post-movement state; only a caller that recovers from the
// panic keeps that write." A recover() anywhere between a ledger call and the transaction
// boundary -- even one added for an unrelated reason, even several call-frames away -- would
// silently convert every refused transfer into a permanent, successful one.
//
// This is not limited to code textually inside this file: a pure `p/` package this realm
// calls runs in garden's own call frame too, so a helper as innocuous as
// `Try(func(){ ledger.TransferFrom(...) })` imported from some future `p/` dependency would
// break the same guarantee just as surely as a recover() written here directly.
//
// The same rule applies to SaveDay's, ChooseType's and Buy's validate-then-commit pattern
// below: none recovers from its own internal panics, by design. Every check runs against a
// local value copy and nothing is written back until the whole call has validated; a panic
// before the commit leaves persisted state completely untouched, with no partial effect to
// undo. Buy extends the rule to money: the ledger write, the index writes and the two coin
// sends all happen after the last check that can fail, so a sale either happens whole or not
// at all -- there is no reachable state in which the gnome moved and the coins did not, or
// the reverse.
package garden

import (
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// ============================================================================
// THE THREE SALE CONSTANTS. THE OWNER DECIDED THESE ON 2026-10-11 ("Go, yes proceed"), FOR THE
// ONYX TESTNET. NOTHING ELSE IN THIS FILE IS A NUMBER THE OWNER HAS NOT ALREADY SEEN.
// ============================================================================
//
// These were committed as placeholders that could not work until the owner chose them; they
// are now his values and they are the ones this realm deploys with. init() below still gates
// them -- assertFeeConfig refuses an invalid recipient, this realm's own address, the
// admin/deploy key, a rate outside 1..10000 and a floor outside 1..maxPriceUgnot -- so a
// future edit to a value that could not work still fails at deploy rather than succeeding
// with the wrong fee forever. TestDeployGateStillRefusesBadFeeValues proves the gate, and
// TestCommittedFeeConstantsAreTheOwnersDecision pins the values below to the decision.
//
// A realm cannot be edited after deploy, so these are permanent for THIS realm's life. They
// are testnet values: mainnet would be a fresh deploy with fresh numbers decided then (DESIGN.md
// section 7.5), and DECISIONS.md already requires a different key than the deploy key for
// anything real.
//
//	saleFeeRecipient  -- the bech32 address every sale's fee is sent to. Units: an address.
//	                     The owner chose the project's `gnotchi-opponent` key, which is NOT the
//	                     deploy/admin key (init refuses that one). It must not be this realm's
//	                     own address either: coins sent there are burned, because there is no
//	                     withdrawal path.
//	saleFeeRateBps    -- the proportional cut, in BASIS POINTS of the declared price
//	                     (100 bps = 1%). 500 is 5%, the figure ECONOMY.md:231 floated. Legal
//	                     range 1..10000.
//	saleFeeFloorUgnot -- the flat floor every sale pays regardless of price, in UGNOT
//	                     (1 GNOT = 1,000,000 ugnot). 1 GNOT. Legal range 1..maxPriceUgnot. This
//	                     is the whole defence against "list at 0, settle off-chain": a sale at a
//	                     declared price of zero still pays this much. Zero is refused because
//	                     the owner's ruling is a cut on EVERY trade.
//
// The buyer pays price + floor + price*rate; the seller receives exactly price.
//
// WHY THREE CONSTANTS AND NOT TWO: the brief for this work spoke of "the fee and the recipient
// address". A fee that is a percentage alone is dodged completely by listing at a price of 0,
// so a percentage cannot be "the fee" on its own; the floor is the part that makes the cut
// unavoidable and ECONOMY.md already describes the fee as floor plus percentage. Splitting the
// fee into its two numbers is the honest shape, not an extra decision.
const (
	saleFeeRecipient  = "g1ylpe9juk8cafgf9rt09wzuz85ug2lyfk5metyv" // gnotchi-opponent, owner's choice
	saleFeeRateBps    = int64(500)                                 // 5% of the declared price
	saleFeeFloorUgnot = int64(1_000_000)                           // 1 GNOT flat minimum per sale
)

// ============================================================================
// Constants that are NOT tunable. See the ruleBands table below for the ones that are, and
// DESIGN.md section 5.3 for why the tunable/fixed split falls exactly here.
// ============================================================================

const (
	collectionName   = "Gnotchi gnomes"
	collectionSymbol = "GNOME"

	// adminAddress is the only address SetRule and FreezeRules will accept. Compiled in,
	// with no transfer function, deliberately -- an admin-transfer path is a second
	// authority path, and a lost admin key merely freezes the config, which is v2's status
	// quo and not a disaster.
	//
	// THIS IS THE DISPOSABLE ONYX TESTNET DEPLOY KEY (DECISIONS.md: "Never a mainnet key.").
	// It is correct for onyx and wrong for anywhere real. WHOEVER DEPLOYS THIS SOMEWHERE
	// THAT MATTERS MUST CHANGE THIS ONE CONSTANT FIRST; it cannot be changed afterwards.
	// See DESIGN.md section 5.6.
	adminAddress = "g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar"

	// maxNameLen: unchanged from v1/v2 -- kept in step with app/js/config.js's NAME_MAX_LEN
	// by hand, because Gno has no way to read that file at build time.
	maxNameLen = 24

	// numEyes / numNoses: THE TWO PERMANENT FACE TRAITS, new in v4. A gnome's eyes id is an
	// integer in [0, numEyes) and its nose id an integer in [0, numNoses), both supplied to Adopt,
	// validated there, written once, and never written again by any function in this file.
	//
	// WHY IDS AND NOT NAMES OR PIXELS. The realm needs to know only WHICH face a gnome has, not
	// what it looks like: art never touches the chain (SPRITES.md). An integer is the smallest
	// thing that says "which", it needs no allowlist of spellings that could drift from the art's
	// own names, and the art side (the generated app/js/parts.js catalogue, built from
	// pack/04-pixel-art/grids/) indexes its parts by position anyway. The contract between the
	// two halves is therefore: eyes id i is the i-th eye part in catalogue order, nose id j the
	// j-th nose part, 0-based, and THAT ORDER IS FROZEN THE MOMENT THIS REALM DEPLOYS. A part
	// may be redrawn; it may never be reordered, removed or renumbered.
	//
	// WHY EXACTLY TEN AND EIGHT, WITH NO HEADROOM. These are SPRITES.md's Phase 1 numbers,
	// chosen before this realm for the economy (ECONOMY.md: a weighted table over discrete parts
	// so that rarity is population frequency counted on chain). Headroom -- accepting, say, 0..15
	// so art could grow -- would let a raw caller mint a face no catalogue entry exists for, which
	// the app would then have to draw as SOMETHING, forever, for a gnome that could be sold on
	// the strength of being the only one. An unknown id refused at Adopt is the only way the realm
	// can guarantee every gnome it has ever minted is drawable. The price is that an eleventh eye
	// is a v5, exactly as a fifth hat always was. Rules() publishes both counts so a client can
	// read the range off the chain instead of holding a copy.
	numEyes  = int64(10)
	numNoses = int64(8)

	// acornReserve is the fix for the acorn softlock (AUDIT-DEPLOYED.md G9, found against v2 and
	// present in v3 too, worse: v3's once-per-address purse means selling and re-adopting cannot
	// refill it either). The only way acorns ever increase after adoption is a harvest; a harvest
	// needs a planted plot; planting costs plantCost and needs belly above the hunger gate; feeding
	// costs feedCost. So a gnome with NOTHING planted and FEWER than plantCost+feedCost acorns can
	// be one decayed belly away from a state no sequence of calls ever leaves: pats only, 10 XP a
	// day, forever, on a realm whose own rule 9 says the gnome never loses progress.
	//
	// SaveDay therefore refuses any batch that SPENDS acorns and ends with nothing planted and
	// fewer than acornReserve in the purse. It is a gate, not a grant: no acorn is ever created,
	// nothing becomes purchasable, and the number is derived from two the owner has already seen
	// rather than invented. The one residual, a purse carried across a sale at exactly one acorn,
	// is closed by the hunger-gate waiver in SaveDay's plant branch; see there. Rules() publishes
	// it, because like the hunger gate this exists only on chain and a client that does not
	// pre-check it loses gas (LOOP.md:26-29 records that happening once already).
	acornReserve = plantCost + feedCost

	hourSeconds = int64(3600)
	daySeconds  = int64(86400)

	// ---- values that must agree with app/js/rules.config.json and are NOT tunable. Each is
	// cited against the exact key it mirrors. Published by Rules() so a drift check against
	// rules.config.json is possible at all -- which it is not against v2, where nothing on
	// chain can be asked what any of these are. See DESIGN.md section 4.
	numPlots    = 3         // acorns.plots -- see DESIGN.md 4.4 for why this can never be tunable
	plantCost   = int64(1)  // acorns.plantCost
	feedCost    = int64(1)  // acorns.feedCost
	acornsStart = int64(10) // acorns.start
	meterMax    = int64(10) // meters.max
	patCheer    = int64(3)  // meters.patCheer

	// hungryAtOrBelow is NOT tunable, and it is the one key I removed from the band table
	// after finding my own counterexample to the table's safety claim. It gates two different
	// things: planting (lower is kinder -- fewer refusals) and the `hungry` branch of moodNow
	// (where lower is NOT kinder). Because moodNow is first-match-wins with hungry checked
	// before sulky, and because hungry carries no XP modifier while sulky carries a penalty,
	// BEING HUNGRY CURRENTLY SHIELDS A NEGLECTED GNOME FROM THE SULKY PENALTY. Lowering this
	// threshold from 2 to 0 therefore moves a gnome with belly 1-2 and no pat for 72h out of
	// hungry and into sulky, costing it 10% of that day's care XP. LOOP.md does not ask for
	// this number to change, so removal costs nothing and shrinks the permanent admin surface.
	hungryAtOrBelow = int64(2) // meters.hungryAtOrBelow

	// happyBonusPct is NOT tunable either, and the ratchet in SetRule is why. Its default (10)
	// is already its kindest value, so the only direction available to it was harsher --
	// removing a bonus. Under the ratchet it could therefore never move at all, and an
	// immovable "tunable" is pure audit surface. LOOP.md does want this at 0; that is a change
	// which takes something from a player, so it needs a v4 rather than an admin call. Stated
	// here rather than quietly dropped.
	happyBonusPct    = int64(10) // xp.happyBonus * 100
	happyWindowHours = int64(2)  // time.happyWindowHours
	sulkyAfterHours  = int64(72) // time.sulkyAfterHours
	maxLevel         = int64(20) // xp.maxLevel
	typeAtLevel      = int64(5)  // xp.typeAtLevel -- when ChooseType unlocks

	xpPat            = int64(5)  // xp.pat
	xpFeed           = int64(5)  // xp.feed
	xpHarvestPerPlot = int64(10) // xp.harvestPerPlot
	xpTinkerTask     = int64(15) // xp.tinker

	// maxActionsPerCall / maxBackfillHours: this realm's own choices, carried over from v2
	// unchanged, including v2's reasoning. maxBackfillHours was an explicit owner ruling --
	// "a player who ignores the game for a year can't just come back and claim it all in one
	// go" (DECISIONS.md) -- and v2 shipped on the back of it. Not tunable: widening it later
	// only ever grants more, but it also widens how far back a cared day (and so a streak)
	// can be claimed, and that is a game-rule decision rather than a balance dial.
	maxActionsPerCall = 32
	maxBackfillHours  = int64(48)

	// caredWindowDays is the width of the cared-day bitmask. 64 days, 8 bytes, newest-first.
	// See DESIGN.md section 2.3 for why the chain stores cared DAYS and never computes the
	// STREAK: rules.js's streakFrom stays the single tested implementation of that rule.
	caredWindowDays = uint(64)

	// maxGnomesPageSize bounds one GnomesPage call's own cost, the same way hollowmere/v1's
	// maxClaimantsPageSize does, so a caller cannot make one call scale with the whole realm.
	maxGnomesPageSize = 100

	// ---- the sale. These are SHAPE constants, not economic ones: none of them is a price,
	// a rate or a destination, and none of them is a number the owner has been asked for.
	//
	// ugnotDenom is the only coin a sale is priced or settled in. ECONOMY.md and
	// MARKETPLACE-V1.md section 3: GNOT only, acorns never touch the market.
	ugnotDenom = "ugnot"

	// maxPriceUgnot caps a declared price at 10^15 ugnot (a billion GNOT, more than exists).
	// It exists so that feeFor's arithmetic provably cannot overflow int64 for any legal
	// price at any legal rate, not to express an opinion about what a gnome is worth.
	maxPriceUgnot = int64(1_000_000_000_000_000)

	// maxFeeRateBps: a share of a price cannot exceed the price. The upper bound the deploy
	// gate enforces on saleFeeRateBps, nothing more.
	maxFeeRateBps = int64(10_000)

	// maxListingDays bounds how long a listing stands before Buy refuses it. A seller chooses
	// 1..30 days per listing. The hazard this bounds is irreversible: an immutable realm with
	// perpetual offers would let a gnome cared for another year sell at a price its owner set
	// and forgot. Relisting is one call; a sale at a forgotten price cannot be undone.
	maxListingDays = int64(30)

	// maxListingsPageSize bounds one ListingsPage call, as maxGnomesPageSize does.
	maxListingsPageSize = 100

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

	// ---- tunable rule keys. String keys, not Go identifiers, because SetRule takes one from
	// a transaction and the band table has to be a single list rather than a switch repeated
	// in three places. Names match rules.config.json's own names so a drift diff is mechanical.
	keyGrowHours       = "growHours"
	keyHarvestPerPlot  = "harvestPerPlot"
	keyFeedBelly       = "feedBelly"
	keyBellyDrop       = "bellyDropEveryHours"
	keyCheerDrop       = "cheerDropEveryHours"
	keyPatCooldown     = "patCooldownHours"
	keyTinkerCost      = "tinkerCost"
	keyDailyCareCap    = "dailyCareCap"
	keyLevelBase       = "levelBase"
	keyLevelStep       = "levelStep"
	keySulkyPenaltyPct = "sulkyPenaltyPct"

	// kindEnd values for ruleBand below: which end of a band is KINDER to the player. This is
	// load-bearing in two places -- it fixes where the default must sit, AND it fixes which way
	// SetRule's ratchet will let the value travel. There is deliberately no "none": a band with
	// no kind direction has no safe ratchet, and SetRule rejects one rather than letting it
	// through unratcheted.
	kindMin = "min" // lower is kinder, so the default sits at max and may only fall
	kindMax = "max" // higher is kinder, so the default sits at min and may only rise
)

// validHats/validCoats: unchanged from v1/v2. v3's DESIGN.md section 7.3 records why appearance
// is not the "open-ended list of parts" ECONOMY.md asks for: on an immutable realm an open-ended
// list is either validated against a compiled-in allowlist (exactly as closed as this) or it
// accepts arbitrary strings, which would undo validNameRune's three audit rounds one field over,
// since Render echoes into markdown. That argument is correct and v4 keeps it. What v3 got wrong
// was the conclusion drawn from it -- "so keep hat and coat" -- because a face chosen from ten
// eyes and eight noses is not open-ended; it is two more fields of exactly this kind, and v4
// adds them as integer ranges (numEyes/numNoses above) rather than as a third and fourth map.
var validHats = map[string]bool{
	"red":    true,
	"purple": true,
	"green":  true,
	"navy":   true,
}

var validCoats = map[string]bool{
	"blue":   true,
	"teal":   true,
	"orange": true,
	"brown":  true,
}

// validTypes: the three callings ChooseType accepts. All three are reachable in this realm,
// which is the point -- v2's assignType was called with explorer XP hard-coded to 0
// (garden/v2/garden.gno:823), so Explorer was permanently unreachable there, and for a
// connected player who never saw a garden or a tinker bench none of the three was. See
// DESIGN.md section 3.4.
var validTypes = map[string]bool{
	typeGardener: true,
	typeExplorer: true,
	typeTinkerer: true,
}

// ============================================================================
// The tunable rules, their bands, and the one property that makes an admin defensible
// ============================================================================

// ruleBand is one tunable number: its key, its deploy default, and the closed interval
// SetRule will accept. kindEnd records which end of that interval is kinder to the player,
// and is what TestEveryBandIsPlayerSafe checks the default against.
type ruleBand struct {
	key     string
	def     int64
	min     int64
	max     int64
	kindEnd string
}

// ruleBands is the whole tunable surface of this realm. Nothing outside this table can be
// changed after deployment, by anyone, ever.
//
// WHY THIS TABLE EXISTS AT ALL, since no other realm in this project has one.
// DECISIONS.md records that the build brief gave garden and arena a Pause(), that an AI
// instruction overrode it, that consequently "no realm has an admin, a pause or a settable
// parameter, and every number is a frozen constant", and that "whether the next realms get
// an owner-settable config is an open decision for the owner, and it is cheap today".
// Meanwhile LOOP.md:89-92 already specifies NINE of the numbers below changing after the
// first ten testers answer, and LOOP.md:127-130 says to deploy nothing before they do. A v3
// that froze them would be obsolete on the day it shipped: that rebalance would cost a v4
// plus a second migration. So the numbers LOOP.md names are tunable, inside bands, in one
// direction only, and FreezeRules below makes the frozen outcome reachable too.
//
// WHY THE RISK IS SMALL, RESTATED NOW THAT GNOMES HAVE A PRICE. An earlier version of this
// paragraph said "this realm holds nothing of value"; with a sale function that is no longer
// the whole truth, so here is the exact truth instead. The realm holds no coins between
// transactions: Buy's banker is BankerTypeOriginSend, which can move at most the coins the
// buyer attached to that one call and dies with the call, and there is no RealmSend banker
// anywhere in this file. Gnomes DO now have a price, and the admin reaches none of them: no
// function here lets adminAddress list, cancel, buy, move, burn or re-price a gnome, change
// the fee, change the recipient, or pause sales. The only state the admin can reach is
// ruleValues, through SetRule, inside the bands, one way. There is still no theft available
// to a compromised admin; what it can do is rebalance the game toward the player.
//
// THE SAFETY PROPERTY, STATED EXACTLY, BECAUSE AN EARLIER AND LOOSER VERSION OF THIS COMMENT
// WAS FALSE AND SHIPPED NOWHERE ONLY BECAUSE AN AUDIT CAUGHT IT. Two parts, and the second
// part is the one that was missing:
//
//  1. Every band is one-directional: kindEnd records which end is kinder to the player, and
//     each default sits at the HOSTILE end, so the only place a value can go is toward the
//     player. TestEveryBandIsPlayerSafe pins that, per key.
//  2. SetRule RATCHETS: it rejects any value less kind than the CURRENT one, not merely any
//     value outside the band. Without this, a band being a closed interval meant it was
//     freely re-enterable from either side -- levelBase 50 -> 30 -> 50 was permitted, and
//     because levelFromXp is recomputed and written back on every SaveDay, that last call
//     made STORED LEVELS DROP on gnomes that already existed. See SetRule's own comment for
//     why that specific power was the one thing a redeploy could never grant, and for the
//     price the ratchet charges (there are no take-backs).
//
// Together: for this realm's whole life, a level can never go down, a meter can never drain
// faster, income can never fall, a cost can never rise and a gate can never tighten. That is
// an auditable property of this table plus that check, not a promise about anybody's
// intentions. TestTuningIsAOneWayRatchetTowardThePlayer exercises both directions of every
// key, which is the test the earlier version of this comment did not have.
//
// THE ONE RESIDUAL, NAMED RATHER THAN CLAIMED AWAY. moodNow is first-match-wins (hungry,
// sulky, happy, content) and only happy and sulky carry an XP modifier, so BEING HUNGRY
// SHIELDS A NEGLECTED GNOME FROM THE SULKY PENALTY. feedBelly and bellyDropEveryHours both
// raise effective belly, so either can lift a gnome with belly 1-2, unpatted for 72h, out of
// hungry and into sulky -- costing it sulkyPenaltyPct of that one day's capped care XP. It is
// bounded at 10% of at most 60 XP, it only touches a gnome already being neglected for three
// days, and TestRaisingFeedBellyCanCostANeglectedGnomeTenPercent demonstrates it rather than
// denying it. Both keys stay tunable because they are the core of LOOP.md's rebalance and the
// kindest changes available; hungryAtOrBelow, which was the largest contributor and is on
// nobody's list, was removed from this table instead. THE OWNER CAN CLOSE THE RESIDUAL
// ENTIRELY IN ONE CALL: SetRule(sulkyPenaltyPct, 0) is permitted by the ratchet and makes the
// flip cost exactly nothing. The perverse incentive underneath it (a gnome at belly 2 out-
// earning the same gnome at belly 3) exists at the DEFAULT config too and is a faithful port
// of app/js/rules.js's own ladder -- correcting it here would create precisely the
// chain/browser mood divergence this realm exists to stop, so it is ported, not fixed.
var ruleBands = []ruleBand{
	// Lower is kinder: default sits at the top of the band and may only fall.
	{keyGrowHours, 24, 12, 24, kindMin},      // acorns.growHours; LOOP.md wants 20
	{keyPatCooldown, 12, 6, 12, kindMin},     // time.patCooldownHours; LOOP.md wants 8
	{keyTinkerCost, 5, 1, 5, kindMin},        // acorns.tinkerCost; LOOP.md wants 3
	{keyLevelBase, 50, 30, 50, kindMin},      // xp.levelBase; LOOP.md wants 40
	{keyLevelStep, 25, 15, 25, kindMin},      // xp.levelStep
	{keySulkyPenaltyPct, 10, 0, 10, kindMin}, // xp.sulkyPenalty * 100; LOOP.md wants 0

	// Higher is kinder: default sits at the bottom of the band and may only rise.
	{keyHarvestPerPlot, 3, 3, 6, kindMax},   // acorns.harvestPerPlot; LOOP.md wants 4
	{keyFeedBelly, 4, 4, 8, kindMax},        // meters.feedBelly; LOOP.md wants 6
	{keyBellyDrop, 3, 3, 8, kindMax},        // meters.bellyDropEveryHours; LOOP.md wants 4
	{keyCheerDrop, 6, 6, 12, kindMax},       // meters.cheerDropEveryHours; LOOP.md wants 8
	{keyDailyCareCap, 60, 60, 120, kindMax}, // xp.dailyCareCap
}

// ============================================================================
// Storage
// ============================================================================

// plot is one of this gnome's numPlots garden plots.
//
// TWO DELIBERATE DIFFERENCES FROM v2's plotState (garden/v2/garden.gno:164-167):
//
//  1. No `growing bool`. plantedAt == 0 IS the empty state. v2 carried both and had to keep
//     them consistent by hand in four places; one field cannot disagree with itself.
//  2. readyAt is STORED, not computed. This is the only derived value persisted anywhere in
//     this realm and it is deliberate: growHours is tunable, so a readiness check against
//     TODAY's growHours would silently change the ready time of a plot already in the
//     ground. Freezing it at plant time means a rule change can never reach backwards into
//     a plant a player has already made. 8 bytes per plot to make a tunable parameter safe.
type plot struct {
	plantedAt int64 // unix seconds; 0 means empty
	readyAt   int64 // plantedAt + growHours*hourSeconds, fixed AT PLANT TIME; 0 when empty
}

// gnome is the whole persisted pet. EVERY FIELD HERE HAS AN EXPORTED READER -- see the
// package doc's one rule, and the table in DESIGN.md section 2.4 mapping field to reader.
//
// NOT here, on purpose: acorns. They live in `balances`, keyed by owner address, because
// ECONOMY.md:65-67 records the owner finding that hole himself -- "Acorns never travel with
// a gnome when it is sold. They belong to the player. Without this, money buys a gnome and
// inherits its acorns ... it is the kind of thing that is unfixable after deployment." Gnomes
// sell here, so this is no longer a theoretical distinction: Buy moves the gnome and no acorn
// moves to the buyer, because the purse was never on the gnome to begin with. The one acorn
// write Buy makes is TO THE SELLER -- it settles the garden's planted plots into the seller's
// own purse, because a planted plot is a claim on acorns and would otherwise have travelled.
//
// Meters are stored as (last-known value, the unix second it was set) per the brief, and
// meterNow works the current value out from elapsed time whenever anything reads it. Nothing
// ticks on this realm's clock, there is no scheduled job, and nothing here is written by
// anything other than a call the owning address itself signed.
type gnome struct {
	name string
	hat  string
	coat string

	// eyes and nose are THE PERMANENT PAIR. Written by Adopt, validated against numEyes and
	// numNoses there, and never written by any other function in this file: SaveDay copies them
	// unchanged through `work := *g`, ChooseType and Buy touch other fields only, and there is no
	// setter. SPRITES.md takes from its Aavegotchi research that two permanently unchangeable
	// traits are what make an individual gnome worth owning; a face that could be changed would
	// be a hat. Readable through Face() and FaceOfToken(). A sale moves them with the gnome,
	// because they are the gnome's.
	eyes int64
	nose int64

	level     int64
	gnomeType string // "" until ChooseType; never derived from XP -- see DESIGN.md 3.4
	adoptedAt int64  // unix seconds

	belly   int64
	bellyAt int64
	cheer   int64
	cheerAt int64

	// lastPatAt == 0 means "never patted". 0 is an unambiguous sentinel here (unlike in
	// rules.js, where timestamps are milliseconds and a test fixture can legitimately hold
	// 0): these are only ever written from a real chain's time.Now().Unix(), which is never
	// 0 on any chain that has left genesis.
	lastPatAt        int64
	lastHappyEventAt int64 // last pat or feed; the mood input v2 stored and never exposed

	totalXp int64 // mood-adjusted, capped per UTC day; the only input to levelFromXp

	// xpGarden/xpTinker/harvestCount are lifetime, UNCAPPED, mood-UNADJUSTED counters. In v2
	// the first two decided the type; here they decide nothing (ChooseType does) and exist
	// purely to be read. That is not waste: GARDEN-V3.md:95-98 argues that "earned marks" --
	// a muddy coat from gardening, a patched coat from long care -- are the appearance
	// feature actually worth having, and that if the underlying counters are exposed they
	// need no contract work at all, becoming a browser rendering decision over chain data.
	// So this realm ships counters and no appearance machinery.
	xpGarden     int64
	xpTinker     int64
	harvestCount int64

	// dailyCareXp/dailyCareDay: the per-UTC-day accumulator dailyCareCap actually bounds,
	// carried over from v2's audit fix F1. Note this is STRICTER than app/js/rules.js, whose
	// careXpForDay caps a single call with no memory of what an earlier call the same day
	// already spent. v2's reading is the correct one and v3 keeps it; Progress() exposes the
	// spend so a client can subtract it instead of promising XP the chain then refuses.
	dailyCareXp  int64
	dailyCareDay int64

	plots [numPlots]plot

	lastTinkerAt int64 // unix seconds of the last completed tinker task; 0 = never

	// Cared days. See DESIGN.md section 2.3 for the whole argument; the short version is that
	// the chain stores FACTS (which UTC days this address saved care on) and never the STREAK
	// RULE, which stays in app/js/rules.js's streakFrom -- the one implementation its own
	// tests already pin. Porting that rule here would mean reimplementing ISO-week rest-day
	// attribution permanently, and getting it subtly wrong would make the chain and the
	// browser disagree about the streak forever, which is the exact failure this realm exists
	// to stop.
	//
	// caredDayCount is the lifetime total and is what app/js/home.js's "Day N" means (it
	// increments per distinct day cared, not per day since adoption -- app/js/live.js:384-386).
	// lastCaredDay is a UTC day number; 0 means "never cared" and is unambiguous because unix
	// day 0 is 1970-01-01. caredMask bit i means "cared on day (lastCaredDay - i)".
	caredDayCount int64
	lastCaredDay  int64
	caredMask     uint64

	// lastActionAt is the replay/ordering frontier: the unix second of the most recent action
	// any successful SaveDay call has ever applied. Initialised to adoptedAt at Adopt time,
	// so "every action strictly after lastActionAt" also means "no action at or before
	// adoption" for free. RESET TO THE SALE TIME BY Buy, for the same reason: a buyer must not
	// be able to backfill care dated before they owned the gnome, which would otherwise let
	// them claim the seller's last 48 hours. See SaveDay's own threat model.
	lastActionAt int64

	// Provenance. acquiredAt is when the CURRENT owner got this gnome -- adoptedAt at Adopt,
	// the sale time after each Buy. saleCount is how many times it has changed hands. Both
	// are readable through Provenance(). Everything else on this struct travels with the
	// gnome when it sells, deliberately and whole -- except the contents of `plots`, which Buy
	// settles to the seller in acorns because a planted plot is a claim on acorns and acorns
	// never travel. See Buy's own comment for what the buyer inherits and why.
	acquiredAt int64
	saleCount  int64
}

// listing is one gnome offered for sale. Keyed by tokenID in `listings`; at most one per
// gnome, and List replaces rather than stacks.
//
// buyer is the zero address for "anyone may buy", or one named address. A named buyer is the
// ONLY gift-shaped path in this realm, and it still pays the floor: see Buy.
type listing struct {
	seller     address
	priceUgnot int64
	buyer      address
	listedAt   int64
	expiresAt  int64
}

// feeConfig is the three sale constants, as init captured them. See the top of the file.
type feeConfig struct {
	recipient  address
	rateBps    int64
	floorUgnot int64
}

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger

	nextID seqid.ID

	gnomes     = avl.NewTree() // tokenID -> *gnome
	ownerIndex = avl.NewTree() // owner address -> tokenID
	balances   = avl.NewTree() // owner address -> int64 acorns (per PLAYER, not per gnome)
	ruleValues = avl.NewTree() // rule key -> int64
	listings   = avl.NewTree() // tokenID -> *listing

	// faceCounts: "eyes:nose" -> int64, how many gnomes have ever been minted with that face.
	// Written only by Adopt (incremented), never decremented: there is no burn, and a sale moves
	// a face without minting one. At most numEyes*numNoses keys. ECONOMY.md's whole rarity
	// argument is that "rarity becomes population frequency counted on chain -- the chain itself
	// proves how few share a part"; this is that count, and FaceCount/FaceCensus are its readers
	// (every persisted field has a reader). A client could rebuild it by paging GnomesPage and
	// calling Face on each owner, at a cost that grows with the population; this costs one tree
	// write per adoption and one read per question.
	faceCounts = avl.NewTree()

	rulesFrozen bool

	// fee is the three sale constants as init captured them. WRITTEN EXACTLY ONCE, IN init,
	// AND NOWHERE ELSE IN THIS FILE. There is no setter, no steward, no band and no freeze for
	// it because it is frozen from the first block: DESIGN.md section 9.6 argues why a fee is
	// not the kind of number the ratchet in SetRule is for.
	fee feeConfig

	// v3 had a `testFeeOverride *feeConfig` here: a package-level variable in production code
	// whose only writer was a test file, left over from when the three sale constants were
	// placeholders that init refused. v3's own DESIGN.md section 9.7 named it as residue and
	// said removing it was "a clean follow-up if the reviewer prefers the suite to run on exactly
	// the deployed config". v4 is that follow-up: there is no override, init reads the three
	// constants and nothing else, and the sale tests assert fee balances on the real recipient
	// address -- which is only an address in the harness, not a key anyone holds there.

	// transferGate names the ONE token the grc721 extension will let move, and only while Buy
	// is moving it. It is "" at every transaction boundary: Buy sets it immediately before the
	// ledger call and clears it immediately after, and any panic in between aborts the
	// transaction and discards the set. It is therefore not persisted state in any meaningful
	// sense and has no reader; TestTransferGateIsClosedBetweenCalls pins that it is empty
	// after every sale.
	transferGate string
)

func init(cur realm) {
	// Fail at deploy, loudly, rather than silently and forever. adminAddress is a compiled-in
	// string that this package's own gnomod.toml tells a deployer in capitals to edit before
	// deploying anywhere real. A typo fails CLOSED -- no caller can ever equal an invalid
	// address -- which is the safe direction but also the silent one: SetRule and FreezeRules
	// would be permanently unreachable while AdminState() published the broken value and
	// rulesFrozen stayed false forever, so the realm would advertise a live admin it did not
	// have. There is no way to notice that after deployment and no way to fix it. One line.
	if !address(adminAddress).IsValid() {
		panic("garden: adminAddress is not a valid address; fix the constant before deploying")
	}

	// THE DEPLOY GATE. The three sale constants at the top of this file are checked against
	// the ranges and refusals in assertFeeConfig, so a deploy with a value that cannot work is
	// impossible rather than unlikely. The test suite runs on exactly these constants too; v3's
	// harness override is gone (see the `fee` comment above).
	cfg := feeConfig{
		recipient:  address(saleFeeRecipient),
		rateBps:    saleFeeRateBps,
		floorUgnot: saleFeeFloorUgnot,
	}
	assertFeeConfig(cfg, cur.Address())
	fee = cfg

	token, ledger = grc721.NewToken(collectionName, collectionSymbol, 0, cur)
	ledger.RegisterExtension(&saleGateExtension{})

	for _, b := range ruleBands {
		ruleValues.Set(b.key, b.def)
	}
}

// assertFeeConfig is init's gate on the three sale constants, split out so a test can prove
// what it refuses, and prove that the committed constants pass it, without a failing init
// taking the whole test package down. Every message names the constant to edit. realmAddr is
// this realm's own address: fees sent there would be burned, because nothing here can ever
// withdraw them.
func assertFeeConfig(cfg feeConfig, realmAddr address) {
	if !cfg.recipient.IsValid() {
		panic("garden: DEPLOY GATE: saleFeeRecipient is not a valid address; fix the constant at the top of garden.gno before deploying")
	}
	if cfg.recipient == realmAddr {
		panic("garden: DEPLOY GATE: saleFeeRecipient is this realm's own address, and coins sent there are burned because there is no withdrawal path")
	}
	// The admin address is the deploy key, and the deploy key is the one address that would end
	// up here by default rather than by decision. The whole point of the gate is that the
	// recipient is chosen; MARKETPLACE-V1.md section 4.3 asks for exactly this assertion. Audit
	// finding Y-1/G-4 of 2026-10-11.
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

// saleGateExtension replaces v1/v2's soulboundExtension. v2 panicked on EVERY transfer; this
// panics on every transfer EXCEPT the one Buy is performing right now, identified by
// transferGate holding that exact token id. The grc721 PrivateLedger is never exported and
// no Approve, SetApprovalForAll or TransferFrom is exposed by this realm, so Buy is the only
// code that can reach the ledger at all -- the gate is the second lock on a door that already
// has one, and it is the lock whose claim ships on chain where anyone can read it.
//
// See the package doc for why this relies on the transaction boundary rather than on hook
// ordering: the hook fires AFTER the ledger write, so a refused transfer's write is discarded
// only because the uncaught panic aborts the whole transaction. No recover(), ever.
type saleGateExtension struct{}

func (saleGateExtension) ExtensionKind() string { return "sale-gate" }

func (saleGateExtension) OnMint(to address, tid grc721.TokenID) {}

func (saleGateExtension) OnTransfer(from, to address, tid grc721.TokenID) {
	if transferGate == "" || transferGate != tid.String() {
		panic("garden: a gnome can only change hands through Buy; every other transfer is permanently disabled")
	}
}

func (saleGateExtension) OnBurn(tid grc721.TokenID) {
	panic("garden: gnomes cannot be burned")
}

// ============================================================================
// Adopt
// ============================================================================

// Adopt mints one gnome to the caller. Every validation v1 and v2 performed is carried over
// in the same order with the same messages -- the name charset allowlist, the invisible-letter
// denylist, the one-gnome-per-address rule, the OriginSend refusal -- because those checks
// are the output of three audit rounds and re-deriving them from memory is how they get lost.
//
// TWO THINGS CHANGE BECAUSE GNOMES CAN NOW BE SOLD. First, an address that has sold its gnome
// has no gnome, so it may adopt again -- "one gnome per address" is a statement about the
// present, not a lifetime count, and adoption is free for a fresh address anyway, so refusing
// it to a seller would punish only the honest. Second, the starting purse is granted ONCE PER
// ADDRESS, EVER: only if this address has never held acorns. A seller keeps their purse
// (acorns belong to the player, ECONOMY.md:65-67), so a re-adopting seller must not be
// topped back up to acornsStart, and a buyer who already has a purse from an earlier gnome
// keeps that one. Without this, sell-and-readopt would refill acorns for free.
//
// THE CUSTODY QUESTION IS CLOSED: ONLY A WALLET MAY ADOPT. realms/garden/NOTES.md recorded it
// in full and reserved it for the owner: cur.Previous().Address() is not restricted to a human
// wallet, so a realm that called Adopt would become the permanent, unrecoverable owner of a
// gnome, with no burn, admin or transfer to undo it. v1 and v2 left that open. On 2026-10-11
// the owner chose the accident case over the sponsor case -- an orphaned gnome permanently
// owned by some batching or multicall realm is a real person's lost gnome, and it can never
// be undone -- so Adopt now refuses any caller that is not a direct wallet call, with the same
// IsUserCall gate Buy already uses (DESIGN.md section 7.5).
//
// What the gate is, exactly, read from this toolchain's chain/runtime: IsUserCall() is
// "pkgPath == """, true for a `gnokey maketx call` (or a wallet's MsgCall) straight from a
// user and false for every code realm, INCLUDING the ephemeral realm a `gnokey maketx run`
// script executes in (that one is IsUserRun, not IsUserCall). So a sponsor realm, a batching
// realm and a run script are all refused, and none of them can ever be let back in on this
// realm: a v4 with an explicit "adopt for" path is how that door would reopen. The refusal
// comes first, before anything is read or written, so a refused caller gets this reason and
// not a later one.
//
// A consequence worth stating: since Buy is also wallet-only, NO REALM CAN EVER OWN A GNOME
// here, by construction. The audit's G-2 worry -- a realm owning and listing a gnome so that
// Buy pays a price to an address with no banker, where it is burned -- has no remaining path.
//
// NEW IN v4: eyes AND nose. Two integers, eyes in [0, numEyes) and nose in [0, numNoses),
// checked after the hat and coat so a caller with several mistakes hears them in the order the
// arguments are written. An id outside its range aborts the whole call and mints nothing -- an
// unknown face is refused, never defaulted, because a default would silently give every
// mistyped adoption the same face and a face is permanent. THE REALM DOES NOT CARE HOW THE
// NUMBERS WERE ARRIVED AT. A client may offer the player a choice, or roll on a weighted table
// and submit the result, or anything in between; this function records what it is given and
// validates it, and nothing on chain can tell the two apart. That neutrality is deliberate and
// argued in realms/garden/v4/DESIGN.md section 3: a realm cannot be edited, so the choice-versus-
// rarity decision must not be frozen in one. Its honest consequence is stated there too -- rarity
// on this realm is a property of client discipline, not of the contract, and a raw gnokey caller
// can always ask for the rarest face. The signature change breaks every existing Adopt caller
// (the app's live.js builds [name, hat, coat]); v4 DESIGN.md section 4 lists them.
func Adopt(cur realm, name, hat, coat string, eyes, nose int64) {
	if !cur.Previous().IsUserCall() {
		panic("garden: adopt must be called directly by a wallet, not through another realm; a gnome minted to a realm's address could never be recovered")
	}

	// Refuse attached coins outright rather than strand them: Buy is the only function here
	// that takes payment, and nothing else has a way to return a coin. Two honest limits, both
	// carried from v1: the check is origin-scoped, not frame-scoped, so a transaction that
	// attaches coins to some OTHER realm in the same call chain makes this panic even though
	// garden received nothing; and it cannot prevent a direct bank send to garden's address
	// with no call at all.
	//
	// Said exactly, so nobody later mistakes it for recoverable: coins that reach this realm's
	// address by a direct bank send are BURNED, not stuck. Buy's banker is BankerTypeOriginSend,
	// which can move only the coins attached to that one Buy; there is no RealmSend banker, no
	// withdrawal path, no admin reach over coins, and none of those can be added. Do not send
	// GNOT here except as a Buy's exact total.
	if !unsafe.OriginSend().IsZero() {
		panic("garden: adopt accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: adopt requires a valid caller address")
	}

	if alreadyAdopted(caller) {
		panic("garden: this address has already adopted a gnome")
	}

	if !validNameLength(name) {
		panic("garden: name must be 1-" + strconv.Itoa(maxNameLen) + " characters")
	}

	if !validNameCharset(name) {
		panic("garden: name contains a character that is not an allowed letter, digit, space, hyphen or apostrophe")
	}

	if !hasVisibleNameContent(name) {
		panic("garden: name must contain at least one visible character")
	}

	if !validHats[hat] {
		panic("garden: invalid hat colour")
	}

	if !validCoats[coat] {
		panic("garden: invalid coat colour")
	}

	if !validEyes(eyes) {
		panic("garden: invalid eyes id; must be 0 to " + strconv.FormatInt(numEyes-1, 10))
	}

	if !validNose(nose) {
		panic("garden: invalid nose id; must be 0 to " + strconv.FormatInt(numNoses-1, 10))
	}

	id := nextID.Next()
	tid := grc721.TokenID(id.String())

	if err := ledger.Mint(caller, tid); err != nil {
		panic(err)
	}

	now := time.Now().Unix()

	// A freshly-adopted gnome starts with full meters. The brief specifies decay rates and
	// the starting acorn count but never a starting meter value; v2 chose full and nothing
	// since has argued against it. lastPatAt/lastHappyEventAt/lastTinkerAt/lastCaredDay all
	// start at 0 ("never"). lastActionAt starts at adoptedAt, which is what makes the replay
	// rule also forbid pre-adoption actions with no separate check.
	gnomes.Set(tid.String(), &gnome{
		name:         name,
		hat:          hat,
		coat:         coat,
		eyes:         eyes,
		nose:         nose,
		level:        1,
		gnomeType:    "",
		adoptedAt:    now,
		belly:        meterMax,
		bellyAt:      now,
		cheer:        meterMax,
		cheerAt:      now,
		lastActionAt: now,
		acquiredAt:   now,
	})
	ownerIndex.Set(caller.String(), tid.String())
	grantStartingPurseIfNew(caller)
	faceCounts.Set(faceKey(eyes, nose), faceCount(eyes, nose)+1)

	chain.Emit(
		"Adopt",
		"owner", caller.String(),
		"tokenId", tid.String(),
		"name", name,
		"hat", hat,
		"coat", coat,
		"eyes", strconv.FormatInt(eyes, 10),
		"nose", strconv.FormatInt(nose, 10),
	)
}

// faceKey / faceCount: the census tree's key and its zero-default read.
func faceKey(eyes, nose int64) string {
	return strconv.FormatInt(eyes, 10) + ":" + strconv.FormatInt(nose, 10)
}

func faceCount(eyes, nose int64) int64 {
	v := faceCounts.Get(faceKey(eyes, nose))
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

// validEyes / validNose: the whole face allowlist. A range check rather than a map because the
// ids are positions in a catalogue (see numEyes), and a range cannot have a hole in it.
func validEyes(id int64) bool { return id >= 0 && id < numEyes }
func validNose(id int64) bool { return id >= 0 && id < numNoses }

// alreadyAdopted: unchanged from v1/v2, and now also Buy's "one gnome per address" check.
// Both ownerIndex and token.BalanceOf are consulted, not either alone, so a disagreement
// between this realm's own index and the grc721 ledger can never be used to mint or buy a
// second gnome to one address IN THIS REALM. Buy keeps the two in step by writing ownerIndex
// in the same call as the ledger move.
//
// "ONE GNOME PER ADDRESS" IS TRUE PER REALM AND FALSE GLOBALLY, AND THAT IS PERMANENT. This
// paragraph is here rather than only in DESIGN.md because DESIGN.md is a repo file: editable,
// not deployed, and not available to whoever reads this realm's source off chain with
// `vm/qfile`. The caveat that most needs to reach a future realm's author was otherwise
// written in the one place that does not ship.
//
// garden/v2 is deployed and immutable at
// gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/garden/v2. It keeps its OWN ownerIndex
// and its OWN grc721 ledger, neither of which this function can see, and it stays fully
// callable forever -- there is no pause and no admin anywhere in it. garden/v3 (block 336496) is
// deployed and immutable in the same way, with the one difference that nobody ever adopted on
// it, so it stands empty but callable. So one address can hold a v2 gnome AND a v3 gnome AND a
// v4 gnome simultaneously, with different names, faces, levels, callings and acorn balances,
// and each realm's own SaveDay keeps accruing on its own gnome indefinitely. Nothing on chain
// reconciles them and nothing ever can.
//
// The consequence that matters most to a future author: the deployed arena/v1 imports
// garden/v2 by absolute path, immutably, and reads GnomeByAddress live at battle-resolution
// time. For a dual adopter it therefore authoritatively reads the V2 gnome -- the state the
// app has stopped showing and this realm can never update. ChooseType here cannot touch it.
// ANY FUTURE REALM THAT ASSUMES A GLOBAL ONE-GNOME-PER-ADDRESS INVARIANT IS BUILDING ON A
// FALSE PREMISE. An arena/v2 written against v3 must pick one realm as the identity of record
// and say which.
//
// v3 deliberately does not import v2 to close this. See DESIGN.md section 6.3 for the full
// argument; the part of it that does not expire is that a hard import would pin this realm to
// one path on one chain and make it undeployable anywhere v2 is not -- the exact coupling
// arena/v1's own gnomod.toml has to warn its deployers about.
func alreadyAdopted(addr address) bool {
	if ownerIndex.Has(addr.String()) {
		return true
	}

	balance, err := token.BalanceOf(addr)
	if err != nil {
		panic(err)
	}
	return balance > 0
}

// ============================================================================
// SaveDay
// ============================================================================

// saveAction is one parsed entry from a SaveDay call's action list.
type saveAction struct {
	kind string
	at   int64 // unix seconds, as claimed by the caller
	plot int   // only meaningful for actionPlant/actionHarvest
}

// SaveDay is the brief's "one daily save": the day's pats, feeds, plants, harvests and tinker
// task submitted as a single list in one signed call.
//
// THE WIRE FORMAT IS UNCHANGED FROM v2, deliberately. It is proven on chain (TESTNET.md:51-60,
// heights 310579/310601/310681) and app/js/live.js already builds it, so changing it would
// cost app work and buy nothing. Semicolon-separated entries, each colon-separated:
//
//	"pat:<unixSeconds>"
//	"feed:<unixSeconds>"
//	"tinker:<unixSeconds>"
//	"plant:<plotIndex>:<unixSeconds>"
//	"harvest:<plotIndex>:<unixSeconds>"
//
// e.g. "pat:1791600000;feed:1791601000;plant:0:1791602000". An empty string is a legal no-op.
// A list, rather than a []Action parameter, because gno.land's own call-argument decoder
// (gno.land/pkg/sdk/vm/convert.go, convertArgToGno) can only build primitive scalars and
// []byte from a transaction -- there is no case there for a slice of structs, and no Gno-side
// type cleverness changes what the wire format can carry. No gnomeID parameter either: one
// gnome per address, no delegation, so there is no second gnome a caller could mean and no
// path by which this could legitimately act on anyone else's. A sale changes which address
// that is, and nothing else here: the seller's next SaveDay finds no gnome, and the buyer's
// must date every action after the sale (Buy resets lastActionAt).
//
// TIMESTAMPS ARE BLOCK TIME, NOT WALL CLOCK, AND A CLIENT THAT FORGETS THAT FAILS EVERY TIME.
// DECISIONS.md:500-515: the first on-chain SaveDay failed with "action timestamp cannot be in
// the future" because the client sent `date -u +%s` while block time ran ~3 seconds behind
// wall clock, measured not assumed, and "a browser sending Date.now() will therefore fail
// essentially always". The fix is client-side -- read the chain's own latest block time and
// subtract a small margin. This realm deliberately does NOT add a future tolerance: DECISIONS'
// own warning is that a tolerance near midnight would let a caller claim the next UTC day's
// XP allowance early.
//
// THREAT MODEL. actionsRaw is client-supplied and this realm is the only authority over it.
// Carried over from v2 whole, including both of its audit fixes:
//
//   - Replay, in whole or in part: every timestamp must be strictly greater than
//     lastActionAt, the gnome's own high-water mark. A replayed batch's first action is by
//     definition <= that mark.
//   - Duplicate actions inside one call: the same strict-increase rule applies action to
//     action, so two actions sharing a timestamp are rejected whatever kinds they are.
//   - Future-dated actions: every timestamp must be <= this call's own block time.
//   - Actions at or before adoption: subsumed by the replay check, since lastActionAt starts
//     at adoptedAt.
//   - Unlimited backfill after a long dormancy (v2's audit fix F2, an owner ruling):
//     maxBackfillHours closes this twice over. Any action older than the window is rejected
//     outright with a message a player can understand, AND the floor the replay check
//     enforces is itself clamped forward to now-maxBackfillHours before the loop runs, so the
//     bound does not rest on a single comparison a future edit could weaken.
//   - Inflated action counts: pat spacing bounds pats per day arithmetically regardless of
//     what the list claims (two a day at the default 12-hour cooldown, four if the owner
//     ratchets it to the band floor of 6 -- v2's version of this note said "more than two a
//     day is impossible", which was true of v2's fixed constant and is not true here), and
//     feed/plant/tinker are each gated by the caller's own acorn balance, which this exact set
//     of rules is the only thing that can increase. The economy is the rate limit. Even the
//     floor case is far under dailyCareCap, so nothing here is a way around the cap.
//   - A thousand actions in one list: rejected on the delimiter COUNT, before strings.Split
//     allocates anything proportional to the input (v2's audit fix F5).
//   - XP inflation via the daily cap (v2's audit fix F1): the whole call's raw care XP is
//     mood-adjusted, then clamped to whatever remains of dailyCareCap FOR THE UTC CALENDAR
//     DAY, tracked by the gnome's own accumulator rather than anything scoped to one call.
//   - The acorn softlock (new in v4, AUDIT-DEPLOYED.md G9): a batch that spends acorns may not
//     end with nothing planted and fewer than acornReserve left. Checked once, after the apply
//     pass, against the batch's END state, so "feed then plant" in one call is fine and the
//     refusal names the whole batch rather than one action. See acornReserve.
//
// ATOMICITY: every check runs against local copies -- `work` for the gnome, `acorns` for the
// balance -- taken at the top. Nothing is written back until the whole list has validated and
// applied cleanly, so any panic before the final commit leaves persisted state completely
// untouched. A plain value copy, not a recover()-and-rollback; see the package SECURITY note.
func SaveDay(cur realm, actionsRaw string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: save day accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: save day requires a valid caller address")
	}

	tid, g, ok := gnomeForAddr(caller)
	if !ok {
		panic("garden: no gnome adopted for this address")
	}

	now := time.Now().Unix()
	actions := parseActions(actionsRaw)

	if len(actions) == 0 {
		chain.Emit("SaveDay", "owner", caller.String(), "tokenId", tid, "actions", "0", "xpApplied", "0")
		return
	}

	// Whole-batch ordering/bounds/same-day validation, before any mutation. firstDay anchors
	// the "one calendar day per call" rule: a call spanning more than one UTC day is rejected
	// outright rather than guessed at how to split. earliestAllowed is the backfill floor, used
	// twice on purpose -- see the threat model above.
	earliestAllowed := now - maxBackfillHours*hourSeconds

	firstDay := dayNumber(actions[0].at)
	prevAt := g.lastActionAt
	if prevAt < earliestAllowed {
		prevAt = earliestAllowed
	}
	for _, a := range actions {
		if a.at <= earliestAllowed {
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

	// Every rule this function's own body needs is read ONCE here, before the apply pass,
	// rather than per action: one tree lookup each instead of one per action, on a loop that
	// can legitimately carry 32 entries.
	//
	// Precisely, because an earlier version of this comment overclaimed twice. It said "rule
	// values are read once" full stop, which is not true of the whole call -- levelFromXp
	// below reads levelBase and levelStep itself (once each, not per iteration). And it
	// justified the caching as protection against "a SetRule landing concurrently", which is a
	// threat that does not exist: a transaction does not interleave with another, so nothing
	// can land inside one SaveDay. The real and sufficient benefit is gas.
	bellyDrop := rule(keyBellyDrop)
	cheerDrop := rule(keyCheerDrop)
	feedBelly := rule(keyFeedBelly)
	patCooldown := rule(keyPatCooldown)
	growHours := rule(keyGrowHours)
	harvestPerPlot := rule(keyHarvestPerPlot)
	tinkerCost := rule(keyTinkerCost)
	sulkyPenalty := rule(keySulkyPenaltyPct)
	dailyCap := rule(keyDailyCareCap)

	// Apply pass: mutate local copies only. work.plots is a fixed-size array (a value type),
	// so `work := *g` copies it in full and mutating work.plots[i] never touches g.plots[i]
	// until the explicit commit at the end. Acorns are a separate tree, so they get their own
	// local and their own single write-back.
	work := *g
	acorns := balanceOf(caller)
	spentThisCall := false // set by feed, plant and tinker; the reserve rule applies only then

	// gateWaived: the hunger-gate waiver (see the plant branch), decided ONCE from the state the
	// batch STARTED in -- purse below the reserve AND nothing planted -- and not from the running
	// balance. Audit pass 1 of v4 showed that judging it on the running balance let an ordinary
	// player reach it: tinker from six acorns down to one inside the batch, then plant while
	// hungry; or hold one acorn with a plot already growing and plant a second. Neither is the
	// carried-purse state the waiver exists for, and the first dodged a pack rule for anyone
	// holding tinkerCost+1 acorns. The start state is the only one the waiver was ever about.
	gateWaived := acorns < acornReserve && !anyPlotPlanted(g)
	rawCareXp := int64(0)
	tinkeredThisCall := false

	for _, a := range actions {
		switch a.kind {
		case actionPat:
			if !canPat(work.lastPatAt, a.at, patCooldown) {
				panic("garden: pat must be at least " + strconv.FormatInt(patCooldown, 10) + " hours after the last one")
			}
			work.lastPatAt = a.at
			work.lastHappyEventAt = a.at
			work.cheer = clampMeter(meterNow(work.cheer, work.cheerAt, a.at, cheerDrop) + patCheer)
			work.cheerAt = a.at
			rawCareXp += xpPat

		case actionFeed:
			if acorns < feedCost {
				panic("garden: not enough acorns to feed")
			}
			acorns -= feedCost
			spentThisCall = true
			work.belly = clampMeter(meterNow(work.belly, work.bellyAt, a.at, bellyDrop) + feedBelly)
			work.bellyAt = a.at
			work.lastHappyEventAt = a.at
			rawCareXp += xpFeed

		case actionPlant:
			// Table 3.3: "Hungry: can't garden until fed." Carried over from v2 as blocking
			// new PLANTING only, never harvesting -- rule 9 says the gnome never loses
			// progress, and a ready harvest should not be strandable behind a hunger gate.
			// This gate exists only on chain; app/js/rules.js has no equivalent, which is why
			// hungryAtOrBelow is published by Rules() and why LOOP.md:26-29 records a live bug
			// where the client did not check and a whole day's save was rejected with gas paid.
			//
			// THE WAIVER (v4): the gate does not apply when the batch STARTED with the purse
			// below acornReserve and nothing planted (gateWaived, computed once above the loop).
			// With the reserve rule below, no SaveDay ever leaves an ordinary player in that
			// state, so for them this clause is unreachable and the gate behaves exactly as in
			// v3. It exists for the one state the reserve cannot police because no SaveDay
			// produced it: a purse carried across a sale -- a seller at zero acorns whose growing
			// plot refunded plantCost, who then adopts again (or buys) and holds exactly one acorn
			// with an empty garden. Without this clause that player, once hungry, could neither
			// feed (the reserve refuses spending the last acorn with nothing planted) nor plant
			// (this gate), and the softlock was back by a side door. "Feed first" is only a
			// reasonable instruction to someone who can afford to feed AND plant; when they
			// cannot, planting the last acorn is the one move that leads anywhere, and the gate
			// yields to it. AND ONLY WHILE THE PLAYER STILL CANNOT AFFORD TO FEED: the waiver also
			// requires the RUNNING purse to be below the reserve, so if a harvest earlier in the
			// same batch has lifted it (reachable in one UTC day once growHours is tuned below 24),
			// the next plant is gated normally again. Audit pass 2 of v4 found that shape; without
			// this second clause a batch that started waived stayed waived through every plant in
			// it. TestTheHungerGateStillHoldsAtTheReserve pins that it yields in that state only.
			waived := gateWaived && acorns < acornReserve
			if !waived && meterNow(work.belly, work.bellyAt, a.at, bellyDrop) <= hungryAtOrBelow {
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
			// Against the plot's OWN stored readyAt, never against today's growHours. See
			// plot's doc comment: this is what makes growHours safe to tune.
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
			// Unreachable: parseActions rejects any kind outside this set before we get here.
			panic("garden: unknown action kind")
		}
	}

	// THE ACORN RESERVE (v4). Judged on the batch's end state, once, so a player can feed and
	// plant in one call and only the net result is held to the rule. Only a batch that SPENT
	// acorns is held to it: a pure pat batch on a gnome that arrived below the reserve (see the
	// waiver in the plant branch for how that can happen) must not be refused for a state it did
	// not cause. "Spent" means a feed, plant or tinker RAN, not that the balance went down: an
	// earlier draft compared the end balance to the start balance, and a batch that harvested a
	// plot (+harvestPerPlot) and then fed the same number of times netted zero, counted as no
	// spend, and could end at zero acorns with nothing planted -- the exact state this rule
	// exists to make unreachable. Found on the author's own re-read before the audit;
	// TestAHarvestCannotMaskAnOverspendInTheSameBatch pins it. See acornReserve for why this
	// exists and why it is a gate rather than a grant.
	if spentThisCall && acorns < acornReserve && !anyPlotPlanted(&work) {
		panic("garden: that would leave fewer than " + strconv.FormatInt(acornReserve, 10) + " acorns with nothing planted, and a gnome with no acorns and no garden can never earn another; plant first, or keep " + strconv.FormatInt(acornReserve, 10) + " back")
	}

	// One mood snapshot for the whole call's raw care XP, matching app/js/rules.js's
	// careXpForDay, which also takes one mood for an entire day's total rather than
	// re-deriving it per action. The "now" for that snapshot is the LAST action's own
	// timestamp, against the state exactly as this call leaves it.
	latestActionAt := actions[len(actions)-1].at
	bellyAtEnd := meterNow(work.belly, work.bellyAt, latestActionAt, bellyDrop)
	mood := moodNow(bellyAtEnd, work.lastPatAt, work.lastHappyEventAt, work.adoptedAt, latestActionAt, hungryAtOrBelow)

	adjustedXp := rawCareXp
	switch mood {
	case moodHappy:
		adjustedXp = adjustedXp * (100 + happyBonusPct) / 100
	case moodSulky:
		adjustedXp = adjustedXp * (100 - sulkyPenalty) / 100
	}

	// dailyCareCap bounds a UTC CALENDAR DAY's total care XP, not one call's (v2's audit fix
	// F1: before it, two calls the same day got 60 each against a cap of 60). Reset the
	// accumulator the moment this call's own day differs from whatever day it covers, clamp to
	// what is actually left, and top it up by exactly that much -- never by the pre-clamp
	// amount.
	if work.dailyCareDay != firstDay {
		work.dailyCareDay = firstDay
		work.dailyCareXp = 0
	}
	remainingToday := dailyCap - work.dailyCareXp
	if remainingToday < 0 {
		remainingToday = 0
	}
	if adjustedXp > remainingToday {
		adjustedXp = remainingToday
	}
	work.dailyCareXp += adjustedXp

	work.totalXp += adjustedXp
	work.level = levelFromXp(work.totalXp)

	// No assignType. v2 derived the type from xpGarden/xpTinker with explorer hard-coded to
	// 0, which made Explorer unreachable and -- per DECISIONS.md:643-646 -- made the other two
	// unbalanced by construction, so "nearly everyone becomes a Gardener". ChooseType replaces
	// it. See DESIGN.md section 3.4.

	recordCaredDay(&work, firstDay)
	work.lastActionAt = latestActionAt

	// Commit. Both writes are in one transaction, so either both land or neither does -- an
	// uncaught panic between them discards the whole transaction's state diff, which is why
	// this realm never needs (and must never have) a recover().
	//
	// The balance goes FIRST on purpose: setBalance is the only write here that can refuse
	// (its negative-balance guard), so running it before `*g = work` means the refusal
	// happens before any in-place mutation of the stored gnome, rather than relying solely
	// on the transaction boundary to undo one.
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
// ChooseType
// ============================================================================

// ChooseType sets this gnome's calling, once, permanently, at level typeAtLevel or above.
//
// THIS REPLACES v2's DERIVED TYPE, AND IT IS THE WHOLE FIX FOR "ADVERTISES SOMETHING
// UNREACHABLE". v2 called assignType(xpGarden, 0, xpTinker) -- a literal 0 for explorer,
// because it had no Visit call -- so Explorer could never be assigned to any gnome, ever; and
// because the app hides the garden and the tinker bench from a connected player, such a
// player reached level 5 with 0 and 0, tied three ways, and got "" instead. Four independent
// sources already said the answer is a chooser rather than a tally:
//
//   - app/js/rules.js's own assignType returns {choose: tied} on a tie, documented "Ties:
//     player chooses".
//   - garden/v2/garden.gno's own comment: "the brief says 'the player chooses', and this
//     version has no chooser endpoint".
//   - LOOP.md:99-101: "at level 5 the player CHOOSES the calling rather than having it
//     derived from tallies that can only ever say Gardener."
//   - DECISIONS.md:643-646: the tallies are unbalanced by construction, because gardening
//     funds the gnome's food and tinkering does not, so the derivation was never a choice.
//
// WHAT IT COSTS, stated rather than glossed: the type stops being evidence of what a player
// did and becomes evidence of what they picked. arena/v1's type edge then reflects a choice
// rather than a history -- strictly better than reflecting a history that could only ever
// have one answer, but a different claim, and anyone reading that edge should know it changed.
//
// One choice, no retrain. rules.config.json has a retrainDays key; this realm implements
// nothing for it (DESIGN.md section 7.4).
func ChooseType(cur realm, kind string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: choose type accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: choose type requires a valid caller address")
	}

	tid, g, ok := gnomeForAddr(caller)
	if !ok {
		panic("garden: no gnome adopted for this address")
	}

	// Order matters for the message a player sees: "already chosen" before the level check,
	// so a level-5 gnome that has already chosen is told the true reason rather than being
	// re-offered a choice it cannot make.
	if g.gnomeType != "" {
		panic("garden: this gnome's calling is already chosen and cannot be changed")
	}

	// Recomputed from totalXp against the CURRENT curve, not read from g.level. g.level is
	// only refreshed on a SaveDay, so after a levelBase/levelStep tune a gnome can be eligible
	// by today's curve while its stored level still says otherwise -- and the bands only ever
	// move the curve in the player's favour, so the stored value is the one that can be unfairly
	// low. The recomputed level is written back here too, so GnomeByAddress (which arena reads)
	// stops disagreeing with the curve from this moment rather than from the next save.
	level := levelFromXp(g.totalXp)
	if level < typeAtLevel {
		panic("garden: a calling can only be chosen at level " + strconv.FormatInt(typeAtLevel, 10) + " or above")
	}

	if !validTypes[kind] {
		panic("garden: a calling is one of \"" + typeGardener + "\", \"" + typeExplorer + "\" or \"" + typeTinkerer + "\"")
	}

	work := *g
	work.gnomeType = kind
	work.level = level
	*g = work
	gnomes.Set(tid, g)

	chain.Emit(
		"ChooseType",
		"owner", caller.String(),
		"tokenId", tid,
		"type", kind,
	)
}

// ============================================================================
// SALE. The only way a gnome ever changes hands. DESIGN.md section 9.
// ============================================================================
//
// THE SHAPE IN ONE PARAGRAPH. The owner lists their gnome at a price in ugnot, for a number of
// days, optionally reserved for one named buyer. Anyone eligible calls Buy with EXACTLY
// price + fee attached, where fee = saleFeeFloorUgnot + price * saleFeeRateBps / 10000. In
// that one call the gnome moves to the buyer, the price goes to the seller, and the fee goes
// to saleFeeRecipient. The realm holds nothing afterwards that it did not hold before. There
// are no bids, no auctions, no escrow, no approvals, no gifts outside a reserved listing, no
// burn, no withdrawal, and no admin reach into any of it.
//
// WHY THE CUT CANNOT BE DODGED ON CHAIN -- AND EXACTLY HOW FAR THAT CLAIM GOES. A royalty as a
// transfer hook sees transfers, not payments: list at 0, settle off-chain, royalty is zero.
// Here (1) the fee is computed on a price the realm itself RECEIVES in coins in the same call,
// never on a declared number; (2) no other transfer path exists, so there is no venue to
// settle through; and (3) the floor is charged even at a declared price of 0, so declaring a
// low price and settling the rest off-chain saves the seller the PERCENTAGE but never the
// FLOOR. That last point is the honest limit: an off-chain side payment is invisible to any
// contract, and the floor is the entire defence against it. So "unavoidable" means: every
// change of hands pays at least the floor, in this realm, with no exception reachable by any
// caller. Selling the wallet's private key dodges everything, as it does for every asset on
// every chain, and no contract can see it.
//
// WHY IsUserCall ON Buy, AND WHAT IT COSTS FOREVER. Coins attached to a transaction belong to
// the realm the wallet called, so a realm in the middle could not pay the seller with them.
// chain/banker makes this structural: a BankerTypeOriginSend banker can only be constructed
// when cur.Previous().IsUserCall() is true. The price is permanent and recorded here rather
// than discovered later: no realm can ever buy a gnome. No auction realm settling on a
// player's behalf, no gas-sponsored purchase, no bundle -- and no `gnokey maketx run` script
// either, since an ephemeral run realm is IsUser() but not IsUserCall(). A wallet calls Buy
// directly, or nobody does. It is this, or a dodgeable cut.
//
// WHAT THE BUYER INHERITS. Everything except the garden's contents and the replay frontier.
// Name, hat, coat, level, totalXp, calling, the lifetime counters, the cared-day history, the
// raw meters and their timestamps, the pat/tinker cooldowns and this UTC day's care-XP spend
// all travel. The owner accepted "money can buy strength from another player" as the cost of
// the ruling (TRADING-RULES.md:161-165), and a levelled gnome's level IS the thing being
// bought. The history stays with the gnome because it is the gnome's history -- provenance,
// not the seller's property -- and because every alternative is worse: resetting the daily cap
// would let sell-and-rebuy double a day's XP; resetting cooldowns would let a buyer pat at
// once. Two things change hands differently. lastActionAt is set to the sale time, so the
// buyer cannot submit care dated before they owned the gnome. And the GARDEN IS SETTLED TO THE
// SELLER, not inherited: a planted plot is a claim on acorns, acorns belong to the player and
// never travel (ECONOMY.md:65-67, "hole 2"), and an audit showed that plots travelling WAS an
// acorn-transfer channel. See the settlement block in Buy. The three empty plots travel.
//
// ONE GNOME PER ADDRESS, AND A BUYER WHO ALREADY HAS ONE. Refused, before anything moves:
// "sell it first". Two players therefore cannot swap directly -- each must sell, and each sale
// pays the fee -- which is the rule working as intended rather than a gap in it. A seller is
// free to adopt again afterwards and keeps their acorn purse (see Adopt).

// List offers the caller's own gnome for sale.
//
// priceUgnot may be 0: that is the gift shape, and the buyer still pays the floor. buyer is
// the zero address ("") for anyone, or one named address other than the seller. days is
// 1..maxListingDays. Listing again replaces the standing listing; it is how a price is
// changed, and because Buy demands the exact total of the listing it finds, a buyer who
// prepared coins for the old price is refused rather than charged the new one.
//
// Listing locks nothing. The seller keeps caring for the gnome; care only ever adds to what
// the buyer gets, and a listed gnome that goes hungry is the seller's own problem to price.
func List(cur realm, priceUgnot int64, buyer address, days int64) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: list accepts no coins; only Buy takes payment")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: list requires a valid caller address")
	}

	tid, _, ok := gnomeForAddr(caller)
	if !ok {
		panic("garden: no gnome adopted for this address")
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
	// Normalise the reserved buyer's case before anything is checked or stored (v4). bech32 is
	// case-insensitive by specification (ASCII letters only, which is why lowerASCII and not
	// strings.ToLower: a Unicode fold could map a non-ASCII letter such as the Kelvin sign onto
	// a bech32 character, which is a wider claim than the spec makes and than this comment
	// wants to make). address.IsValid() accepts an all-upper-case string (measured against this
	// toolchain, not assumed), but Buy compares the stored buyer to the caller's own address,
	// which a wallet always presents in lower case -- so in v3 a seller who typed "G1..."
	// created a listing that validated, rendered, and could never be bought until they
	// relisted. v3's DESIGN.md section 9.11 left this as an open question; the answer was "yes,
	// it happens", and one line closes it. A mixed-case spelling, which the raw validator
	// rejects, is accepted after folding: the checksum still decides whether the folded string
	// is an address at all. Nothing else here compares addresses that a caller typed: the seller
	// and the buyer are always cur.Previous().
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
	listings.Set(tid, &listing{
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
		"tokenId", tid,
		"priceUgnot", strconv.FormatInt(priceUgnot, 10),
		"feeUgnot", strconv.FormatInt(feeUgnot, 10),
		"totalUgnot", strconv.FormatInt(priceUgnot+feeUgnot, 10),
		"buyer", buyer.String(),
		"expiresAt", strconv.FormatInt(now+days*daySeconds, 10),
	)
}

// Cancel withdraws the caller's own listing. Only the seller can; nobody else -- not the
// admin, not a reserved buyer -- can cancel or alter anyone's listing.
func Cancel(cur realm) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: cancel accepts no coins; only Buy takes payment")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("garden: cancel requires a valid caller address")
	}

	tid, _, ok := gnomeForAddr(caller)
	if !ok {
		panic("garden: no gnome adopted for this address")
	}
	if !listings.Has(tid) {
		panic("garden: your gnome is not for sale")
	}

	listings.Remove(tid)
	chain.Emit("Cancel", "seller", caller.String(), "tokenId", tid)
}

// Buy purchases the listed gnome tokenID, paying its seller and the fee recipient in the same
// call. The caller must be a wallet, must not own a gnome, must be the reserved buyer if there
// is one, and must attach EXACTLY the listing's price + fee in ugnot and nothing else.
//
// VALIDATE, THEN COMMIT -- AND THE COMMIT PHASE CANNOT FAIL. Every refusal below happens
// before the first write. After the "commit" line nothing remains that can panic on chain:
// the ledger move is to an owner we have just verified with a gate we have just opened; the
// two coin sends are for amounts we have just checked equal the envelope (so the
// BankerTypeOriginSend cap cannot refuse them), from this realm's own address (which the
// envelope has credited before this code runs), to addresses validated at List time and at
// init. Payment is therefore atomic with transfer by construction, and not only because an
// uncaught panic would abort the transaction -- though it would, and that is the second lock.
//
// NO REENTRANCY IS POSSIBLE AND THIS IS WHY, STATED SO IT CAN BE CHECKED RATHER THAN
// TRUSTED: the only calls Buy makes outside this file are grc721's TransferFrom (a /p/
// package running in this realm's own frame, whose only hook is saleGateExtension above) and
// banker.SendCoins (a native that credits a bank balance and runs no code at the recipient).
// Neither can call back into this realm. State is nonetheless fully written before the sends,
// so even if a future chain gave coin recipients a hook, re-entering Buy for this token would
// find no listing and a different owner.
//
// EXACTLY, NOT AT LEAST. Accepting more than the total would make this realm a bank for the
// difference, with no withdrawal path; accepting a different denomination would strand it.
// The abort returns the whole envelope to the buyer, so a wrong amount costs gas and nothing
// else. Listing() publishes the exact total a wallet must attach.
func Buy(cur realm, tokenID string) {
	// Direct wallet call only. chain/banker would refuse the OriginSend banker further down
	// anyway; checking here first gives the caller the real reason instead of a banker error.
	if !cur.Previous().IsUserCall() {
		panic("garden: buy must be called directly by a wallet, not through another realm; the coins attached to a transaction belong to the realm the wallet called")
	}
	buyer := cur.Previous().Address()
	if !buyer.IsValid() {
		panic("garden: buy requires a valid caller address")
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
	if alreadyAdopted(buyer) {
		panic("garden: this address already has a gnome; one gnome per address, so sell it before buying another")
	}

	// Total function: the listing's seller must still be the ledger's owner and the gnome must
	// exist. Both are invariants every path in this file maintains (nothing but Buy moves a
	// gnome, and Buy deletes the listing), so these are unreachable today; they are here so
	// this function is correct on its own terms rather than correct because of code elsewhere.
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
	// Read here, above the commit line, so the commit phase below contains no tree lookup that
	// could (even unreachably) panic on a missing key: rule() panics on absence by design.
	harvestPerPlot := rule(keyHarvestPerPlot)
	send := unsafe.OriginSend()
	if !exactUgnot(send, total) {
		panic("garden: buy requires exactly " + strconv.FormatInt(total, 10) + ugnotDenom +
			" attached (" + strconv.FormatInt(l.priceUgnot, 10) + " price + " +
			strconv.FormatInt(feeUgnot, 10) + " fee); got " + coinsString(send))
	}

	// ---- commit. Nothing below this line can fail on chain. See the function comment. ----

	transferGate = tokenID
	if err := ledger.TransferFrom(l.seller, l.seller, buyer, tid); err != nil {
		panic(err)
	}
	transferGate = ""

	ownerIndex.Remove(l.seller.String())
	ownerIndex.Set(buyer.String(), tokenID)
	listings.Remove(tokenID)

	// Settle the garden to the SELLER as the gnome changes hands (same transaction; the ledger
	// move above and this block commit or abort together). Audit finding Y-2 of 2026-10-11: a
	// planted plot is a bearer claim on acorns, so if plots travelled, a fresh address could
	// plant three, list at 0 to a confederate who pays only the floor, and hand over 9-18
	// acorns -- an acorn-transfer channel in a realm whose on-chain rule is that acorns never
	// travel. So: a ready plot pays the seller harvestPerPlot (the harvest they grew, judged
	// against the plot's own readyAt exactly as SaveDay's harvest is), a growing plot refunds
	// the seller plantCost (the acorn they planted), and the buyer receives an empty garden.
	// Nothing is destroyed and nothing moves between players. This is a settlement, not play:
	// no XP, no harvestCount, no cared day -- strictly worse for a seller than harvesting first,
	// so nobody is paid to prefer it. The seller always has a purse (Adopt and Buy both grant one
	// on acquisition), both summands are non-negative, and harvestPerPlot was read above the
	// commit line, so nothing here can fail. The Sale event carries settledAcorns.
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

// Listing is one gnome's standing offer, including the EXACT total a wallet must attach to
// Buy. found is false when the gnome is not listed. An expired listing is still returned,
// with its expiresAt, so a client can tell "expired" from "never listed"; Buy refuses it.
func Listing(tokenID string) (seller address, priceUgnot int64, buyer address, listedAtUnix, expiresAtUnix, feeUgnot, totalUgnot int64, found bool) {
	l, ok := listingFor(tokenID)
	if !ok {
		return address(""), 0, address(""), 0, 0, 0, 0, false
	}
	f := feeFor(l.priceUgnot)
	return l.seller, l.priceUgnot, l.buyer, l.listedAt, l.expiresAt, f, l.priceUgnot + f, true
}

// TotalListings / ListingsPage: the board. Same shape and same reasoning as TotalGnomes /
// GnomesPage -- this project has paid for a missing enumerator once already. The page is
// tokenIDs, oldest key first; resolve each with Listing() and OwnerOfToken(). Expired
// listings are included until their seller lists again or cancels.
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

	ids := make([]string, 0, limit)
	listings.IterateByOffset(offset, limit, func(key string, value any) bool {
		ids = append(ids, key)
		return false
	})
	return ids
}

// QuoteFee is what a sale at priceUgnot costs the buyer, before anyone lists anything.
func QuoteFee(priceUgnot int64) (feeUgnot, totalUgnot int64) {
	if priceUgnot < 0 || priceUgnot > maxPriceUgnot {
		panic("garden: price must be between 0 and " + strconv.FormatInt(maxPriceUgnot, 10) + " ugnot")
	}
	f := feeFor(priceUgnot)
	return f, priceUgnot + f
}

// FeeRules publishes the fee exactly as this realm will charge it, for the same reason Rules()
// publishes the game numbers: the chain's own value is the one that applies, and a client that
// can read it has no reason to hold a copy. Everything here is frozen for the realm's life.
func FeeRules() string {
	return "feeRateBps=" + strconv.FormatInt(fee.rateBps, 10) +
		";feeFloorUgnot=" + strconv.FormatInt(fee.floorUgnot, 10) +
		";feeRecipient=" + fee.recipient.String() +
		";maxPriceUgnot=" + strconv.FormatInt(maxPriceUgnot, 10) +
		";maxListingDays=" + strconv.FormatInt(maxListingDays, 10)
}

// Provenance is the reader for the two fields a sale adds to the gnome.
func Provenance(addr address) (adoptedAtUnix, acquiredAtUnix, saleCount int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return 0, 0, 0, false
	}
	return g.adoptedAt, g.acquiredAt, g.saleCount, true
}

// Face is the reader for the two permanent traits v4 adds, by owner address -- the shape every
// other per-gnome read here has, so a client that already resolves an address keeps doing so.
// GnomeByAddress is NOT extended to carry them: its signature is byte-identical to v2's so that
// arena/v1's call and the app's positional tuple parser repoint with an import change, and a
// face is not something a battle or a village roster needs. found is false for an address with
// no gnome; eyes and nose are then 0, which is also a legal face, so check found.
func Face(addr address) (eyes, nose int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return 0, 0, false
	}
	return g.eyes, g.nose, true
}

// FaceCount is how many gnomes have ever been minted with this exact face -- the population
// frequency ECONOMY.md's rarity argument rests on, read off the chain rather than rebuilt by a
// client. Out-of-range ids are refused rather than answered 0, because 0 would be a true
// statement about a face that cannot exist and a client could mistake it for "rarest".
func FaceCount(eyes, nose int64) int64 {
	if !validEyes(eyes) || !validNose(nose) {
		panic("garden: face count asked for an id outside the catalogue; eyes are 0 to " + strconv.FormatInt(numEyes-1, 10) + " and noses 0 to " + strconv.FormatInt(numNoses-1, 10))
	}
	return faceCount(eyes, nose)
}

// FaceCensus is every face's count in one read: "eyes:nose=count;..." for every face with at
// least one gnome, eyes-major, noses-minor, so a client can draw the whole rarity table from one
// qeval. Empty while nobody has adopted. At most numEyes*numNoses entries, so the cost is
// bounded by the catalogue and not by the population.
func FaceCensus() string {
	pairs := make([]string, 0, int(numEyes*numNoses))
	for e := int64(0); e < numEyes; e++ {
		for n := int64(0); n < numNoses; n++ {
			c := faceCount(e, n)
			if c == 0 {
				continue
			}
			pairs = append(pairs, faceKey(e, n)+"="+strconv.FormatInt(c, 10))
		}
	}
	return strings.Join(pairs, ";")
}

// FaceOfToken is the same read keyed by tokenID, because the one place a face is looked up
// without an owner in hand is the market: ListingsPage returns tokenIDs, and a buyer deciding
// between two listings should not need OwnerOfToken first. The face is the gnome's, not the
// owner's, so the tokenID is in fact the more honest key.
func FaceOfToken(tokenID string) (eyes, nose int64, found bool) {
	gv := gnomes.Get(tokenID)
	g, ok := gv.(*gnome)
	if !ok || g == nil {
		return 0, 0, false
	}
	return g.eyes, g.nose, true
}

// ============================================================================
// Reads. One per cluster of stored state, and between them they cover every persisted field
// -- see the package doc's one rule and DESIGN.md section 2.4.
// ============================================================================

// GnomeByAddress has the BYTE-IDENTICAL signature to garden/v2's, on purpose: anything
// already written against v2 -- arena/v1's own GnomeByAddress call, app/js/adventure-
// villagers.js, app/js/live.js's qeval tuple parser, which reads these eight values
// positionally -- repoints at this realm with a one-line import change and no rewrite.
//
// That matters because arena/v1 is deployed and imports garden/v2 immutably, so a gnome
// adopted here cannot use arena/v1 at all and battle needs an arena/v2. Keeping this
// signature stable is the one thing this realm can do to make that a one-line change rather
// than a port. See DESIGN.md section 6.3.
func GnomeByAddress(addr address) (tokenID, name, hat, coat string, level int64, gnomeType string, adoptedAtUnix int64, found bool) {
	tid, g, ok := gnomeForAddr(addr)
	if !ok {
		return "", "", "", "", 0, "", 0, false
	}
	return tid, g.name, g.hat, g.coat, g.level, g.gnomeType, g.adoptedAt, true
}

// GardenState is the read garden/v2 does not have, and the reason this realm exists.
//
// plantedAtCsv and readyAtCsv are each numPlots comma-separated unix seconds in plot order,
// with 0 for an empty plot -- e.g. "1791600000,0,0" / "1791686400,0,0". Two parallel
// fixed-width lists rather than one encoded blob, because the app's qeval reader already
// splits plain strings and because a reader that has to parse a schema is a reader that can
// parse it wrongly.
//
// readyCount is how many plots are harvestable AT THIS MOMENT, computed by the realm against
// each plot's own stored readyAt. The caller could derive it, but only by also knowing the
// chain's current block time, which is exactly the thing a browser gets wrong (see SaveDay's
// comment on DECISIONS.md:500-515). So the chain answers it.
func GardenState(addr address) (plantedAtCsv, readyAtCsv string, readyCount int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
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

// CareState is v2's CareState plus the two things it left out: lastHappyEventAt (the mood
// input v2 stored at its own line 197 and exposed nowhere, so the app substituted
// lastActionAt, which is a different number -- a harvest-only day advances lastActionAt and
// not lastHappyEventAt), and acorns now read from the player's balance rather than the gnome.
//
// belly and cheer are returned already decayed to time.Now(), as v2's were. MeterState below
// returns the raw stored pair for a caller that wants to run app/js/rules.js's own meterNow
// against this realm's state and check the two agree.
//
// The signature is NOT positionally compatible with v2's CareState, unlike GnomeByAddress
// above. Nothing cross-realm reads CareState -- only the app does -- and inserting
// lastHappyEventAt where it belongs was worth more than preserving a tuple shape for a single
// caller that has to change anyway.
func CareState(addr address) (belly, cheer, acorns, totalXp, lastPatAtUnix, lastHappyEventAtUnix, lastActionAtUnix int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return 0, 0, 0, 0, 0, 0, 0, false
	}
	now := time.Now().Unix()
	return meterNow(g.belly, g.bellyAt, now, rule(keyBellyDrop)),
		meterNow(g.cheer, g.cheerAt, now, rule(keyCheerDrop)),
		balanceOf(addr), g.totalXp, g.lastPatAt, g.lastHappyEventAt, g.lastActionAt, true
}

// MeterState returns the RAW stored meter pairs, undecayed. v2 exposed only the decayed
// values, which is lossy in a way that matters here: a caller cannot check the chain's decay
// against app/js/rules.js's meterNow if it is only ever handed the chain's answer. With this,
// the browser can run its own formula over the chain's own inputs -- which is how a repeat of
// the mood divergence in DESIGN.md section 1.5 gets caught in a day instead of in a year.
func MeterState(addr address) (belly, bellyAtUnix, cheer, cheerAtUnix int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return 0, 0, 0, 0, false
	}
	return g.belly, g.bellyAt, g.cheer, g.cheerAt, true
}

// Progress is the rest of the stored state: the lifetime counters, the tinker clock and this
// UTC day's care-XP spend. Every one of these is a field garden/v2 writes and cannot read
// back.
//
// dailyCareXpSpent is the one a client most needs and v2 most lacked: the chain caps care XP
// per UTC DAY and app/js/rules.js caps it per CALL, so a browser that does not subtract this
// will promise XP the chain then refuses. dailyCareDay says which UTC day that spend belongs
// to, so a client can tell "60 spent today" from "60 spent on a day that has since rolled over".
func Progress(addr address) (xpGarden, xpTinker, harvestCount, lastTinkerAtUnix, caredDayCount, dailyCareXpSpent, dailyCareDay int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return 0, 0, 0, 0, 0, 0, 0, false
	}
	return g.xpGarden, g.xpTinker, g.harvestCount, g.lastTinkerAt,
		g.caredDayCount, g.dailyCareXp, g.dailyCareDay, true
}

// CaredDays returns the UTC day numbers this address saved care on, newest first, comma
// separated -- e.g. "20371,20370,20368". At most caredWindowDays of them; empty if never.
//
// THE STREAK RULE IS DELIBERATELY NOT HERE. app/js/rules.js's streakFrom is the single tested
// implementation of it and takes exactly this list (as "YYYY-MM-DD", one line of JS from a day
// number -- rules.js:233 already does that conversion). Porting its ISO-week rest-day
// attribution onto an immutable contract would mean two implementations of one rule, and
// getting it subtly wrong would make the chain and the browser disagree about the streak
// forever. The chain stores facts; the browser owns the rule. DESIGN.md section 2.3.
//
// The encoding (a uint64 mask relative to lastCaredDay) is internal and no caller needs to
// know it; TestCaredMaskRoundTrips pins it.
func CaredDays(addr address) (daysCsv string, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return "", false
	}
	return caredDaysCsv(g), true
}

// Mood returns the realm's OWN mood for this gnome, right now.
//
// This exists because the chain's mood is what applies the XP modifier, and because v2 proves
// a divergence here is not hypothetical: v2 ported rules.js's mood faithfully, rules.js was
// then fixed so a never-patted gnome is "new" rather than "neglected", and the deployed realm
// and the shipped browser have returned different moods for the same gnome ever since, with
// no way to notice from outside. v3 matches the current rules.js (see moodNow) and publishes
// its answer so the next divergence is observable.
func Mood(addr address) (mood string, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return "", false
	}
	now := time.Now().Unix()
	belly := meterNow(g.belly, g.bellyAt, now, rule(keyBellyDrop))
	return moodNow(belly, g.lastPatAt, g.lastHappyEventAt, g.adoptedAt, now, hungryAtOrBelow), true
}

// CollectionInfo / TotalSupply / BalanceOf / OwnerOfToken: the GRC721 read surface.
//
// THESE EXIST BECAUSE AN AUDIT FOUND THE ONE PLACE THIS REALM'S OWN RULE DID NOT HOLD. Every
// field of the gnome struct has a reader; `token` and `ledger` did not. They are persisted
// realm state (the token is created inside garden's own storage, so there is no separate
// grc721 realm an indexer could query instead), and before these four functions the only read
// of any of it was token.TotalSupply() interpolated into Render's markdown, where no caller
// can consume it as a typed value.
//
// What that cost, permanently, if it had shipped: no wallet could list the gnome, no indexer
// could enumerate holders, no other realm could verify ownership except through garden's own
// GnomeByAddress, and -- the sharpest one -- there was NO tokenID-to-owner reader at all,
// because ownerIndex is owner-to-tokenID only. A tokenID observed in an Adopt event could not
// be resolved back to an owner without brute-forcing GnomesPage. garden/v2 has the identical
// gap and can never close it.
//
// nextID is the one piece of persisted state with no direct reader, and that is deliberate
// rather than missed: it is a seqid counter equal to the number of adoptions (there is no
// burn, and a sale moves a token without minting one), so TotalSupply() below is the same
// number by construction. Recorded so the next reader does not have to work that out.
func CollectionInfo() (name, symbol string) {
	return collectionName, collectionSymbol
}

func TotalSupply() int64 {
	return token.TotalSupply()
}

// BalanceOf is 0 or 1 for every address, forever: one gnome per address, no burn, and Buy
// refuses a buyer who already holds one. Exposed anyway rather than replaced by a bool,
// because a GRC721 consumer expects this shape.
//
// An invalid address owns nothing, so 0 is the CORRECT answer here and not an error signal --
// this function deliberately cannot distinguish "invalid address" from "owns none", because
// there is nothing to distinguish. Acorns(addr) below is the reader that does draw a
// distinction (absent versus zero), and it draws it about something where the difference is
// real. An earlier version of this comment claimed the opposite of the line underneath it;
// corrected here, before it could ship and say that permanently.
func BalanceOf(addr address) int64 {
	n, err := token.BalanceOf(addr)
	if err != nil {
		return 0
	}
	return n
}

// OwnerOfToken resolves a tokenID back to its owner -- the lookup that was impossible without
// it. found is false for a tokenID this realm never minted.
func OwnerOfToken(tokenID string) (owner address, found bool) {
	if !gnomes.Has(tokenID) {
		return address(""), false
	}
	o, err := token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		return address(""), false
	}
	return o, true
}

// TotalGnomes / GnomesPage: the enumerator garden/v2 has no equivalent of.
//
// This project has already paid for a missing enumerator once. DECISIONS.md:780-791 records
// that arena/v1 "exposes no way to list challenges -- confirmed with vm/qfuncs against the
// deployed realm, not assumed from the source -- and a realm cannot be edited", so there is no
// challenge inbox and there cannot be one; "if an inbox is ever wanted, it is an arena/v2
// plus a migration". hollowmere/v1 learned that and shipped TotalClaimants/ClaimantsPage.
// garden/v2 did not, so no leaderboard, no village roster and no "who is playing" query is
// possible against it at all. Twenty lines, unavailable forever if omitted.
func TotalGnomes() int64 {
	return int64(ownerIndex.Size())
}

// GnomesPage returns up to limit owner addresses in ownerIndex's own stable key order,
// starting at offset. limit is CLAMPED to maxGnomesPageSize rather than rejected, so a caller
// asking for too much still gets a gas-bounded page instead of an aborted call; a negative
// offset or a non-positive limit are caller mistakes with no sane page to return.
//
// Paging with offset 0, then offset+len(page), until a page shorter than its requested limit
// comes back, covers every owner exactly once with no gaps and no duplicates for any snapshot
// where the tree does not grow between calls. TestGnomesPagePagesEveryOwnerExactlyOnce proves
// that directly rather than assuming it from avl.Tree's doc comment.
func GnomesPage(offset, limit int) []string {
	if offset < 0 {
		panic("garden: offset must not be negative")
	}
	if limit <= 0 {
		panic("garden: limit must be positive")
	}
	if limit > maxGnomesPageSize {
		limit = maxGnomesPageSize
	}

	owners := make([]string, 0, limit)
	ownerIndex.IterateByOffset(offset, limit, func(key string, value any) bool {
		owners = append(owners, key)
		return false
	})
	return owners
}

// Acorns is the player's own acorn balance, read directly rather than only through
// CareState, because acorns are a PLAYER's property here and not a gnome's (ECONOMY.md:65-67)
// and the read should say so. An address that has never held a purse gets 0, false -- never
// a bare 0 that a caller could mistake for a real empty purse. A player who has SOLD their
// gnome still has a purse, and this says so: it is keyed on the purse, not on the gnome,
// because the purse outlives the gnome and is what a later Adopt or Buy will find waiting.
func Acorns(addr address) (acorns int64, found bool) {
	if !balances.Has(addr.String()) {
		return 0, false
	}
	return balanceOf(addr), true
}

// ============================================================================
// Rules: publishing them, tuning them inside bands, and freezing them for good
// ============================================================================

// Rules publishes every number this realm actually uses, as "key=value;key=value;...", fixed
// values first in the order of DESIGN.md's agreement table, then the tunables in ruleBands
// order.
//
// THIS IS THE PIECE v2 HAD NO ANSWER TO. v2 kept thirty-odd values hand-copied from
// app/js/rules.config.json with no reader, so no drift check between the chain and the
// browser was possible even in principle -- nothing on chain could be asked what growHours
// was. With this, anyone can: gnoweb, curl, or a node test that compares each key against
// rules.config.json and fails on any mismatch.
//
// AND IT FIXES THE DIRECTION OF CORRECTION, which is the part that matters on an immutable
// contract. v2's two copies could drift and neither was authoritative. Here the chain is
// authoritative and, for a tunable, is the only place a value can change -- so a client should
// READ this and use it, not hold a second copy and hope.
//
// WHAT IS NOT DONE, stated rather than implied: the node-side half of that check does not
// exist. The follow-up is one test comparing this output against rules.config.json, plus
// making app/js/rules-bridge.js prefer these values for a connected player. Neither is
// written. Until they are, this is a capability and not a check.
func Rules() string {
	pairs := []string{
		"plots=" + strconv.Itoa(numPlots),
		"plantCost=" + strconv.FormatInt(plantCost, 10),
		"feedCost=" + strconv.FormatInt(feedCost, 10),
		"acornsStart=" + strconv.FormatInt(acornsStart, 10),
		"meterMax=" + strconv.FormatInt(meterMax, 10),
		"hungryAtOrBelow=" + strconv.FormatInt(hungryAtOrBelow, 10),
		"happyBonusPct=" + strconv.FormatInt(happyBonusPct, 10),
		"patCheer=" + strconv.FormatInt(patCheer, 10),
		"happyWindowHours=" + strconv.FormatInt(happyWindowHours, 10),
		"sulkyAfterHours=" + strconv.FormatInt(sulkyAfterHours, 10),
		"maxLevel=" + strconv.FormatInt(maxLevel, 10),
		"typeAtLevel=" + strconv.FormatInt(typeAtLevel, 10),
		"xpPat=" + strconv.FormatInt(xpPat, 10),
		"xpFeed=" + strconv.FormatInt(xpFeed, 10),
		"xpHarvestPerPlot=" + strconv.FormatInt(xpHarvestPerPlot, 10),
		"xpTinker=" + strconv.FormatInt(xpTinkerTask, 10),
		"maxBackfillHours=" + strconv.FormatInt(maxBackfillHours, 10),
		"maxActionsPerCall=" + strconv.Itoa(maxActionsPerCall),
		"caredWindowDays=" + strconv.FormatInt(int64(caredWindowDays), 10),
		"faceEyes=" + strconv.FormatInt(numEyes, 10),
		"faceNoses=" + strconv.FormatInt(numNoses, 10),
		"acornReserve=" + strconv.FormatInt(acornReserve, 10),
	}
	for _, b := range ruleBands {
		pairs = append(pairs, b.key+"="+strconv.FormatInt(rule(b.key), 10))
	}
	return strings.Join(pairs, ";")
}

// RuleBands publishes the tunable surface itself: "key=min..max" for every band, in the same
// order Rules() uses.
//
// Without this, "the admin can only tune inside bands" is a claim in a document. With it,
// anyone can read the actual limits off the chain and check what this realm will and will not
// accept, without trusting DESIGN.md, this comment, or the owner.
func RuleBands() string {
	pairs := make([]string, 0, len(ruleBands))
	for _, b := range ruleBands {
		pairs = append(pairs, b.key+"="+strconv.FormatInt(b.min, 10)+".."+strconv.FormatInt(b.max, 10))
	}
	return strings.Join(pairs, ";")
}

// AdminState is who may tune, and whether tuning is over. Readable by anyone, deliberately:
// an admin nobody can see is worse than an admin.
func AdminState() (admin address, frozen bool) {
	return address(adminAddress), rulesFrozen
}

// SetRule changes one tunable number, inside its band, if the rules are not frozen.
//
// Only adminAddress. No admin transfer. Nothing here can touch a gnome, a balance, an XP
// total or a level -- the only state this function can reach is ruleValues, and only for a key
// that is in ruleBands, and only to a value inside that key's band. See ruleBands' own comment
// for why this exists at all and why the bands make it defensible; DESIGN.md section 5 for
// the full argument, including the explicit note that this is the one decision in v3 the owner
// should actively approve or veto before deploy, and that vetoing it is a deletion rather than
// a redesign.
func SetRule(cur realm, key string, value int64) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: set rule accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if caller != address(adminAddress) {
		panic("garden: only the admin can change a rule")
	}

	if rulesFrozen {
		panic("garden: the rules are frozen and can never be changed again")
	}

	b, ok := bandFor(key)
	if !ok {
		panic("garden: \"" + key + "\" is not a tunable rule; see RuleBands()")
	}

	if value < b.min || value > b.max {
		panic("garden: " + key + " must be between " + strconv.FormatInt(b.min, 10) + " and " + strconv.FormatInt(b.max, 10))
	}

	before := rule(key)

	// THE RATCHET. This is the check that makes the one-directional claim actually true, and
	// it is here because an audit found that without it the claim was false after the second
	// tune. A band is a CLOSED INTERVAL, freely re-enterable from either side: bounding the
	// interval bounds where a rule may sit, not which way it may travel. So
	// SetRule(levelBase, 30) followed by SetRule(levelBase, 50) was permitted, and since
	// levelFromXp is recomputed from totalXp on every SaveDay and written back, that second
	// call made STORED LEVELS DROP for gnomes that already existed.
	//
	// That is the one capability redeploying could never give the owner -- a v4 is a fresh
	// namespace and cannot reach into v3's stored gnomes -- so it was exactly the power the
	// whole "this realm holds nothing of value, an admin can only rebalance" argument did not
	// cover. FreezeRules made it worse rather than better: an admin could push every key to
	// the harsh end of its band and then freeze there, permanently, with no unfreeze and no
	// SetRule left to undo it.
	//
	// With this check each rule is a monotone one-way ratchet toward the player, for the
	// realm's whole life. The price, stated plainly because it is real: THERE ARE NO
	// TAKE-BACKS. Tune growHours to 20 and 22 is gone forever. That is not a side effect of
	// the fix, it IS the property -- "can only ever move toward the player" and "can be moved
	// back" are the same sentence negated. An owner who wants a harsher number after trying a
	// kinder one needs FreezeRules and a v4, which is the honest path for a change that takes
	// something from a player.
	switch b.kindEnd {
	case kindMin:
		if value > before {
			panic("garden: " + key + " can only be lowered, never raised; it is " + strconv.FormatInt(before, 10) + " and tuning is a one-way ratchet toward the player")
		}
	case kindMax:
		if value < before {
			panic("garden: " + key + " can only be raised, never lowered; it is " + strconv.FormatInt(before, 10) + " and tuning is a one-way ratchet toward the player")
		}
	default:
		// Total rather than defensive: a band with no stated kind direction has no safe
		// ratchet, so it must not be tunable at all. Rejecting here means adding such a band
		// later fails loudly instead of silently escaping the ratchet.
		panic("garden: " + key + " has no safe tuning direction and must not be tunable")
	}
	ruleValues.Set(key, value)

	chain.Emit(
		"SetRule",
		"key", key,
		"from", strconv.FormatInt(before, 10),
		"to", strconv.FormatInt(value, 10),
	)
}

// FreezeRules ends tuning permanently. One admin-only, irreversible call; afterwards SetRule
// panics forever and this realm is exactly as frozen as garden/v2.
//
// This is what makes the whole tunable-config decision safe to defer rather than get right
// before deploy: the owner can deploy tunable, run Check A, apply LOOP.md's numbers and then
// freeze -- or freeze on day one and never tune. Both outcomes are reachable from this realm.
// Only one is reachable from v2.
//
// There is no unfreeze, on purpose. A reversible freeze is not a freeze.
func FreezeRules(cur realm) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: freeze rules accepts no coins; only Buy takes payment, and nothing else here can return them")
	}

	caller := cur.Previous().Address()
	if caller != address(adminAddress) {
		panic("garden: only the admin can freeze the rules")
	}

	if rulesFrozen {
		panic("garden: the rules are already frozen")
	}

	rulesFrozen = true
	chain.Emit("FreezeRules", "rules", Rules())
}

// ============================================================================
// Render
// ============================================================================

// Render is the gnoweb page. Unlike v2's, it shows the garden -- which is the whole point of
// this realm, and a player should be able to see their plots without a client at all.
//
// path is bech32-validated before anything derived from it is echoed back into the page, the
// same guard v1, v2, hollowmere and arena all use, for the same reason: path is whatever a URL
// put after the realm path, so it is attacker-controlled, and gnoweb renders this return value
// as markdown. A rejected path is never reflected at all, which is strictly safer than
// escaping it.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf(
			"# %s\n\nGnome collection. A gnome changes hands only through Buy, and every sale pays the fee below.\n\n"+
				"* **Total adopted**: %d\n* **For sale**: %d\n* **Fee**: `%s`\n* **Rules**: `%s`\n* **Tunable within**: `%s`\n",
			collectionName, token.TotalSupply(), TotalListings(), FeeRules(), Rules(), RuleBands(),
		)
	}

	// Lower-cased for the same reason List lower-cases a reserved buyer: an upper-case bech32
	// string validates, but ownerIndex is keyed by the lower-case form every wallet presents, so
	// without this a correct address typed in capitals read "no gnome adopted yet". The echo
	// below is still of the VALIDATED value, never of the raw path.
	addr := address(lowerASCII(path))
	if !addr.IsValid() {
		return ufmt.Sprintf("# %s\n\nNo gnome adopted for an invalid address.\n", collectionName)
	}

	tid, g, ok := gnomeForAddr(addr)
	if !ok {
		return ufmt.Sprintf("# %s\n\nNo gnome adopted yet for `%s`.\n", collectionName, addr.String())
	}

	gnomeType := g.gnomeType
	if gnomeType == "" {
		gnomeType = "(not yet chosen)"
	}

	now := time.Now().Unix()

	str := ufmt.Sprintf("# %s\n\n", g.name)
	str += ufmt.Sprintf("* **Owner**: %s\n", addr.String())
	str += ufmt.Sprintf("* **Token ID**: %s\n", tid)
	str += ufmt.Sprintf("* **Level**: %d\n", g.level)
	str += ufmt.Sprintf("* **Calling**: %s\n", gnomeType)
	str += ufmt.Sprintf("* **Look**: %s hat, %s coat\n", g.hat, g.coat)
	str += ufmt.Sprintf("* **Face**: eyes %d, nose %d (permanent)\n", g.eyes, g.nose)
	str += ufmt.Sprintf("* **Acorns**: %d\n", balanceOf(addr))
	str += ufmt.Sprintf("* **Belly**: %d/%d\n", meterNow(g.belly, g.bellyAt, now, rule(keyBellyDrop)), meterMax)
	str += ufmt.Sprintf("* **Cheer**: %d/%d\n", meterNow(g.cheer, g.cheerAt, now, rule(keyCheerDrop)), meterMax)
	belly := meterNow(g.belly, g.bellyAt, now, rule(keyBellyDrop))
	str += ufmt.Sprintf("* **Mood**: %s\n", moodNow(belly, g.lastPatAt, g.lastHappyEventAt, g.adoptedAt, now, hungryAtOrBelow))
	str += ufmt.Sprintf("* **Days cared**: %d\n", g.caredDayCount)

	str += "\n## Garden\n\n"
	for i := 0; i < numPlots; i++ {
		p := g.plots[i]
		switch {
		case p.plantedAt == 0:
			str += ufmt.Sprintf("* **Plot %d**: empty\n", i)
		case now >= p.readyAt:
			str += ufmt.Sprintf("* **Plot %d**: ready to harvest\n", i)
		default:
			str += ufmt.Sprintf("* **Plot %d**: growing, ready in %d hours\n", i, (p.readyAt-now+hourSeconds-1)/hourSeconds)
		}
	}

	// The listing, so an owner who forgot they listed sees it here without a client. Every
	// value is this realm's own stored data or an address it validated at List time; nothing
	// from the URL path reaches this section.
	if l, ok := listingFor(tid); ok {
		f := feeFor(l.priceUgnot)
		str += "\n## For sale\n\n"
		if now > l.expiresAt {
			str += "* **Status**: EXPIRED (the owner must list again)\n"
		} else {
			str += "* **Status**: for sale\n"
		}
		str += ufmt.Sprintf("* **Price**: %d ugnot to the seller\n", l.priceUgnot)
		str += ufmt.Sprintf("* **Buyer pays**: %d ugnot (%d price + %d fee)\n", l.priceUgnot+f, l.priceUgnot, f)
		if l.buyer != address("") {
			str += ufmt.Sprintf("* **Reserved for**: %s\n", l.buyer.String())
		} else {
			str += "* **Reserved for**: anyone\n"
		}
		str += "* **Garden**: NOT included -- planted plots are settled to the seller in acorns at the sale; the buyer receives three empty plots\n"
		str += ufmt.Sprintf("* **Expires**: %d (unix seconds)\n", l.expiresAt)
	}

	return str
}

// ============================================================================
// Helpers
// ============================================================================

func gnomeForAddr(addr address) (tid string, g *gnome, found bool) {
	v := ownerIndex.Get(addr.String())
	if v == nil {
		return "", nil, false
	}
	tid, ok := v.(string)
	if !ok {
		return "", nil, false
	}
	gv := gnomes.Get(tid)
	if gv == nil {
		return "", nil, false
	}
	gp, ok := gv.(*gnome)
	if !ok {
		return "", nil, false
	}
	return tid, gp, true
}

// lowerASCII folds A-Z to a-z and leaves every other byte alone. Used on a typed address
// before validation (List's reserved buyer, Render's path): bech32's case-insensitivity is
// an ASCII rule, so this is exactly the fold the specification licenses and no more. A
// non-ASCII byte is left for address.IsValid() to reject.
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

// anyPlotPlanted is the reserve rule's "is income on its way" test: a planted plot, ready or
// growing, is a claim on at least plantCost acorns (Buy's settlement makes that literal), so
// a purse below the reserve is survivable while one exists.
func anyPlotPlanted(g *gnome) bool {
	for i := 0; i < numPlots; i++ {
		if g.plots[i].plantedAt != 0 {
			return true
		}
	}
	return false
}

// balanceOf: a missing key is a zero balance, not an error. Only Adopt creates a key, so a
// missing key means "no gnome here", which every caller has already checked.
func balanceOf(addr address) int64 {
	v := balances.Get(addr.String())
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

// setBalance refuses to store a negative balance. Nothing above should ever produce one --
// every spend is guarded by its own "not enough acorns" check -- so this is not a guard that
// is expected to fire; it is a guard that makes a future arithmetic mistake abort the
// transaction instead of silently minting a debt the economy has no concept of.
func setBalance(addr address, v int64) {
	if v < 0 {
		panic("garden: acorn balance can never go negative")
	}
	balances.Set(addr.String(), v)
}

// grantStartingPurseIfNew gives an address acornsStart the FIRST time a gnome arrives in its
// hands, by Adopt or by Buy, and never again. See Adopt's comment: a seller keeps their
// purse, so neither re-adopting nor buying may refill it.
func grantStartingPurseIfNew(addr address) {
	if balances.Has(addr.String()) {
		return
	}
	balances.Set(addr.String(), acornsStart)
}

// feeFor is the whole fee formula: floor + price * rate / 10000, rounded down.
//
// Written as (price/10000)*rate + ((price%10000)*rate)/10000 rather than price*rate/10000.
// The two are identical for every input (write price = 10000q + r; then floor(price*rate/
// 10000) = q*rate + floor(r*rate/10000) because q*rate is an integer), but the first form
// cannot overflow int64 for any legal input: price <= maxPriceUgnot = 10^15 and rate <=
// maxFeeRateBps = 10^4, so (price/10000)*rate <= 10^15 and the remainder term is < 10^4 * 10^4.
// The naive form would overflow at price*rate > 9.2*10^18, i.e. a 10^15 price at any rate
// above 9223 bps. TestFeeArithmeticMatchesTheNaiveFormula pins the identity.
func feeFor(priceUgnot int64) int64 {
	return fee.floorUgnot + (priceUgnot/10_000)*fee.rateBps + ((priceUgnot%10_000)*fee.rateBps)/10_000
}

// exactUgnot is Buy's payment check: one coin, in ugnot, of exactly want. Not "at least".
func exactUgnot(send chain.Coins, want int64) bool {
	return len(send) == 1 && send[0].Denom == ugnotDenom && send[0].Amount == want
}

// coinsString renders an envelope for a refusal message; "nothing" for an empty one.
func coinsString(c chain.Coins) string {
	if len(c) == 0 {
		return "nothing"
	}
	return c.String()
}

func listingFor(tokenID string) (*listing, bool) {
	v := listings.Get(tokenID)
	l, ok := v.(*listing)
	if !ok || l == nil {
		return nil, false
	}
	return l, true
}

// rule reads a tunable. A missing key is a bug in this file, not a runtime condition, so it
// panics rather than returning a silent zero -- a zero growHours or a zero levelBase would be
// a far worse outcome than an aborted call.
func rule(key string) int64 {
	v := ruleValues.Get(key)
	n, ok := v.(int64)
	if !ok {
		panic("garden: missing rule value for \"" + key + "\"")
	}
	return n
}

func bandFor(key string) (ruleBand, bool) {
	for _, b := range ruleBands {
		if b.key == key {
			return b, true
		}
	}
	return ruleBand{}, false
}

// validNameLength/validNameCharset/hasVisibleNameContent/validNameRune/invisibleLetterRunes:
// unchanged from v1 and v2, including v2's audit fix F3 (\uXXXX escapes rather than literal
// invisible glyphs, so the denylist is readable in an editor and cannot be silently emptied by
// a formatter that strips default-ignorable characters). See v1's own comments for the
// exhaustive scan proving the list complete against this toolchain's Unicode version, and
// realms/garden/NOTES.md for the open product question about combining marks -- that allowlist
// excludes every combining mark, which makes zalgo names structurally impossible and also makes
// NFD Latin, Devanagari, Thai, vocalised Hebrew and Arabic unspellable. That trade-off is
// recorded as the owner's to revisit and is carried forward here unchanged rather than
// silently re-decided.
func validNameLength(name string) bool {
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

var invisibleLetterRunes = map[rune]bool{
	'ᅟ': true, // HANGUL CHOSEONG FILLER
	'ᅠ': true, // HANGUL JUNGSEONG FILLER
	'ㅤ': true, // HANGUL FILLER
	'ﾠ': true, // HALFWIDTH HANGUL FILLER
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

// parseActions parses and validates SaveDay's wire format, enforcing maxActionsPerCall on the
// delimiter COUNT before strings.Split ever runs (v2's audit fix F5: Split allocates the full
// result slice before any length check could inspect it, so a megabyte of semicolons allocated
// half a million short-lived strings before being rejected. strings.Count scans the raw bytes
// without allocating a result, so the oversized case now costs nothing proportional to the
// input. The caller always paid their own gas for this, so it was never a cross-user DoS --
// the fix makes the claim true, it does not close a vulnerability).
// quoteAction renders an offending entry for a panic message, TRUNCATED. Without this, the
// four malformed-action panics below interpolated the caller's own bytes at full length, so a
// semicolon-free, colon-free megabyte passed both delimiter guards and then built a
// megabyte-long panic string -- one remaining path that allocated proportional to the input,
// which is precisely what this function's own comment claims cannot happen. Harmless (about
// 2x amplification of data already in the transaction, entirely caller-paid, and a transaction
// abort message is not a markdown sink) but it made the claim false, and the claim ships.
//
// 48 bytes is comfortably longer than any legal entry -- "harvest:2:1791600000" is 20 -- so a
// real player's error message is never truncated and only an abusive one is.
func quoteAction(part string) string {
	const maxQuoted = 48
	if len(part) > maxQuoted {
		return "\"" + part[:maxQuoted] + "...\" (truncated)"
	}
	return "\"" + part + "\""
}

func parseActions(raw string) []saveAction {
	if raw == "" {
		return nil
	}

	if n := strings.Count(raw, ";") + 1; n > maxActionsPerCall {
		panic("garden: too many actions in one call (max " + strconv.Itoa(maxActionsPerCall) + ")")
	}

	// The COLON count, bounded for the same reason and in the same way -- and this half was
	// missing. v2's fix F5 (ported above) guards the ';' count before the outer Split, but the
	// INNER strings.Split(part, ":") below was unguarded: a single semicolon-free entry with a
	// megabyte of colons passes the check above with n == 1, and then allocates one string per
	// colon before len(fields) != 2 can reject it. That is precisely the allocation pattern F5
	// exists to eliminate, which made this function's own claim about allocating nothing
	// proportional to the input false for the inner split.
	//
	// The legal maximum is two colons per entry ("plant:<plot>:<ts>"), so the whole string can
	// never legitimately carry more than 2*maxActionsPerCall of them. Rejected on a byte scan
	// with no allocation, like the check above. As with F5 the caller always paid their own gas
	// for this, so it was never a cross-user DoS -- this makes the comment true rather than
	// closing a vulnerability.
	if strings.Count(raw, ":") > 2*maxActionsPerCall {
		panic("garden: malformed action list (too many fields)")
	}

	parts := strings.Split(raw, ";")

	actions := make([]saveAction, 0, len(parts))
	for _, part := range parts {
		fields := strings.Split(part, ":")
		switch fields[0] {
		case actionPat, actionFeed, actionTinker:
			if len(fields) != 2 {
				panic("garden: malformed action " + quoteAction(part))
			}
			actions = append(actions, saveAction{
				kind: fields[0],
				at:   parseUnixField(fields[1], part),
			})
		case actionPlant, actionHarvest:
			if len(fields) != 3 {
				panic("garden: malformed action " + quoteAction(part))
			}
			actions = append(actions, saveAction{
				kind: fields[0],
				plot: parsePlotField(fields[1], part),
				at:   parseUnixField(fields[2], part),
			})
		default:
			panic("garden: unknown action kind in " + quoteAction(part))
		}
	}
	return actions
}

func parseUnixField(s, part string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		panic("garden: invalid timestamp in action " + quoteAction(part))
	}
	return v
}

func parsePlotField(s, part string) int {
	v, err := strconv.Atoi(s)
	if err != nil || v < 0 || v >= numPlots {
		panic("garden: invalid plot index in action " + quoteAction(part))
	}
	return v
}

// dayNumber is the UTC calendar day index for a unix-second timestamp. Integer division by
// 86400 lands exactly on 00:00 UTC boundaries, matching brief 3.1 with no timezone handling,
// because unix time is UTC by definition.
func dayNumber(unixSeconds int64) int64 { return unixSeconds / daySeconds }

// recordCaredDay folds one cared UTC day into the gnome's lifetime count and its 64-day
// window. See the gnome struct's own comment for the storage shape and DESIGN.md section 2.3
// for why the chain records days and never computes the streak.
//
// This handles a day arriving AT OR BEFORE lastCaredDay even though SaveDay's replay rule
// (every action strictly after lastActionAt) makes that unreachable today. Two extra lines to
// make this function correct on its own terms rather than correct only because of an invariant
// enforced two hundred lines away. On a contract that can never be edited, a total function is
// worth more than the lines it costs -- and a reader of this function alone should not have to
// go and verify SaveDay's ordering rule to know it is sound.
func recordCaredDay(g *gnome, day int64) {
	if g.lastCaredDay == 0 {
		g.lastCaredDay = day
		g.caredMask = 1
		g.caredDayCount = 1
		return
	}

	if day > g.lastCaredDay {
		shift := uint(day - g.lastCaredDay)
		if shift >= caredWindowDays {
			// Everything in the window is now older than the window. Go defines a shift of
			// >= the operand width on an unsigned value as 0, so `g.caredMask <<= shift` would
			// do this anyway -- written out because relying on that is a reader's trap.
			g.caredMask = 0
		} else {
			g.caredMask <<= shift
		}
		g.caredMask |= 1
		g.lastCaredDay = day
		g.caredDayCount++
		return
	}

	// day <= lastCaredDay.
	back := uint(g.lastCaredDay - day)
	if back >= caredWindowDays {
		// Older than the window: it still happened, so it counts toward the lifetime total,
		// but there is no bit left to record it in.
		g.caredDayCount++
		return
	}
	bit := uint64(1) << back
	if g.caredMask&bit != 0 {
		// Already recorded. Two saves on one UTC day are one cared day.
		return
	}
	g.caredMask |= bit
	g.caredDayCount++
}

// caredDaysCsv decodes the window, newest first.
func caredDaysCsv(g *gnome) string {
	if g.lastCaredDay == 0 {
		return ""
	}
	days := make([]string, 0, caredWindowDays)
	for i := uint(0); i < caredWindowDays; i++ {
		if g.caredMask&(uint64(1)<<i) == 0 {
			continue
		}
		days = append(days, strconv.FormatInt(g.lastCaredDay-int64(i), 10))
	}
	return strings.Join(days, ",")
}

// meterNow ports app/js/rules.js's meterNow exactly: work the current value out from a
// last-known value, the unix second it was set, and how many whole dropEveryHours periods have
// elapsed since, clamped to [0, meterMax].
//
// A tunable decay rate re-derives history under the new rate, which is harmless precisely
// because meters saturate: the affected span is bounded in practice by the 48-hour backfill
// window, and a long-dormant gnome's belly is already clamped at 0 under either rate. See
// DESIGN.md section 5.4.
func meterNow(value, setAt, now, dropEveryHours int64) int64 {
	// Total rather than defensive, and held to this file's own stated standard: recordCaredDay
	// argues that "a reader of this function alone should not have to go and verify SaveDay's
	// ordering rule to know it is sound", and this function was the counter-example -- it
	// divided by a parameter whose non-zeroness was guaranteed only by a band table twelve
	// hundred lines away. Unreachable today (both decay bands have non-zero minima and the
	// ratchet only raises them), and a division panic would brick every read and every save at
	// once, so the guard costs three lines and removes a whole-realm failure mode from the
	// set of things a future band edit could cause.
	if dropEveryHours <= 0 {
		panic("garden: a meter decay rate must be positive")
	}
	if now < setAt {
		now = setAt
	}
	drops := (now - setAt) / (dropEveryHours * hourSeconds)
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

// canPat ports app/js/rules.js's canPat. lastPatAt == 0 means never patted; see the gnome
// struct's comment for why 0 is an unambiguous sentinel here and is not in the JS.
func canPat(lastPatAt, now, cooldownHours int64) bool {
	return lastPatAt == 0 || now-lastPatAt >= cooldownHours*hourSeconds
}

// moodNow ports app/js/rules.js's CURRENT moodNow, in brief table 3.3's first-match-wins order:
// hungry, then sulky, then happy, then content. "Asleep" is display-only and has no on-chain
// representation, exactly as in rules.js.
//
// THE adoptedAt FLOOR IS THE FIX FOR A DIVERGENCE v2 CANNOT BE FIXED FOR, and it is the reason
// this function takes a parameter v2's did not. v2 ported rules.js's mood as it then stood,
// where a never-patted gnome's "last attention" fell back to the unix epoch, so "no pat for 72
// hours" was trivially true and every brand-new gnome read as sulky -- v2's own comment flags
// this and notes rules.test.js never exercised it. rules.js:103-119 has since been fixed, for
// a reported bug: "EVERY newly adopted gnome was instantly sulky" and "the very first thing a
// new player read was '<name>'s in a huff'". v2 cannot be edited, so the deployed realm and the
// shipped browser now disagree about the mood of the same gnome, and the chain's answer is the
// one that applies the XP penalty. This matches the fixed version:
//
//	neverPatted -> floor "last attention" at adoptedAt, because a gnome has been cared for, by
//	definition, at the moment somebody chose it.
//
// rules.js also maxes in lastVisitReceivedAt. This realm has no visit mechanic (DESIGN.md
// section 7.1), so that input is permanently absent, and rules.js with lastVisitReceivedAt ===
// null gives the identical answer. The floor applies ONLY to a gnome that has genuinely never
// been patted: rules.js's own comment records that an earlier attempt applied it
// unconditionally and quietly made neglect unreachable, so a gnome last patted 73 hours ago
// still sulks here, as it should.
//
// hungryThreshold is a PARAMETER rather than a package-constant reference inside the body, so
// this function is pure in its arguments and its formula can be checked against rules.js
// without knowing any realm state. It is deliberately NOT named hungryAtOrBelow: that is the
// name of the package constant every caller passes, and shadowing it here would leave a reader
// of this body alone unable to tell whether the threshold is fixed or caller-supplied -- on a
// file whose stated standard is that reading one function should be enough. The older note on
// why the parameter exists at all:
//
// the threshold was once a rule(...) lookup inside the body, so this
// function is pure in its arguments. It used to read the rule itself while SaveDay had already
// cached that same value for the planting gate -- harmless today, but it made the answer depend
// on realm state the signature did not mention, which is exactly the kind of hidden input that
// makes a formula hard to check against rules.js.
func moodNow(belly, lastPatAt, lastHappyEventAt, adoptedAt, now, hungryThreshold int64) string {
	if belly <= hungryThreshold {
		return moodHungry
	}

	lastAttention := lastPatAt
	if lastPatAt == 0 {
		lastAttention = adoptedAt
	}
	if now-lastAttention >= sulkyAfterHours*hourSeconds {
		return moodSulky
	}

	if lastHappyEventAt != 0 && now-lastHappyEventAt <= happyWindowHours*hourSeconds {
		return moodHappy
	}
	return moodContent
}

// xpToNext/totalXpForLevel/levelFromXp port app/js/rules.js's functions of the same name:
// levelBase + levelStep*level to reach the next level, maxLevel the ceiling. levelBase and
// levelStep are tunable, so a level is recomputed from totalXp on every save -- the bands only
// permit them to fall, so a level can rise from a tune and can never drop. arena/v1 reads this
// level for ranked eligibility, so a tune can make a gnome newly eligible and never newly
// ineligible. DESIGN.md section 5.4.
// xpToNextWith/totalXpForLevelWith take the curve's two numbers as ARGUMENTS rather than
// reading them per call, and levelFromXp below reads them exactly once.
//
// This is not style. The obvious shape -- xpToNext() reading rule(keyLevelBase) and
// rule(keyLevelStep) itself -- puts two avl lookups inside a loop that is inside another loop
// bounded by maxLevel, so one SaveDay paid on the order of 800 tree reads to work out a level
// that needs two numbers and some arithmetic. garden/v2 had the numbers as compile-time
// constants and paid nothing; making them tunable must not quietly cost that.
func xpToNextWith(level, base, step int64) int64 { return base + step*level }

func totalXpForLevelWith(level, base, step int64) int64 {
	var t int64
	for l := int64(1); l < level; l++ {
		t += xpToNextWith(l, base, step)
	}
	return t
}

// xpToNext/totalXpForLevel are the single-argument forms the tests and any future reader
// want, kept so the curve can be asked about without threading the two numbers by hand.
func xpToNext(level int64) int64 {
	return xpToNextWith(level, rule(keyLevelBase), rule(keyLevelStep))
}

func totalXpForLevel(level int64) int64 {
	return totalXpForLevelWith(level, rule(keyLevelBase), rule(keyLevelStep))
}

func levelFromXp(totalXp int64) int64 {
	base, step := rule(keyLevelBase), rule(keyLevelStep)
	level := int64(1)
	for level < maxLevel && totalXp >= totalXpForLevelWith(level+1, base, step) {
		level++
	}
	return level
}
