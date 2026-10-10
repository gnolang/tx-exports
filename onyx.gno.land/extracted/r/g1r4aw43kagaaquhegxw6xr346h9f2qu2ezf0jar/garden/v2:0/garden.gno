// Package garden is Gnotchi's Phase 1 on-chain slice, v2: everything v1's garden realm
// does (Adopt, GnomeByAddress, Render, soulbound, one gnome per address, the validated
// name/hat/coat rules, the OriginSend refusal -- every fix from v1's three audit rounds,
// carried over rather than rewritten from memory, see below for exactly which lines are
// unchanged from realms/garden/garden.gno) plus the new thing Phase 1 actually needs:
// SaveDay, the "one signature saves the whole day" call the brief's section 5.2 and the
// build brief's own paragraph 2 promise and that the deployed v1 realm does not have.
//
// v1 (realms/garden/garden.gno) is deployed to the onyx testnet at
// gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/garden/v1 and, per DECISIONS.md,
// cannot be edited -- this file is deliberately a sibling, not a modification. v1 is left
// completely untouched as the deployed record.
//
// THIS FILE IS NOT DEPLOYED. Authored and tested locally only, per this assignment's own
// brief: no gnokey, no key material, no deploy.
//
// Everything below this comment that is unchanged from v1 (the soulboundExtension, Adopt's
// validation chain, the name-charset allowlist/denylist, Render's path validation,
// GnomeByAddress) is carried over with its original comments intact, because those
// comments are the audit trail for *why* each check exists -- deleting them to make this
// file shorter would silently discard that trail. New material (the care-state fields on
// gnome, SaveDay and its helpers, CareState) is clearly marked "v2:" in its own comments.
//
// SECURITY: the same warning v1 carries applies here unchanged and is reprinted in full,
// because it is load-bearing and not something a reader should have to go find in a
// different file to understand this one: no code in this realm, now or later, may ever
// recover() around a call into ledger or token (grc721's PrivateLedger/Token). The
// soulbound guarantee below is real, but it is NOT that the ledger write never happens --
// it does, before the panic -- it is that an *uncaught* panic aborts the whole enclosing
// transaction, so that write (and everything else the transaction did) is discarded and
// never committed on chain. p/nt/grc721/v0/types.gno says this outright, about extension
// hooks like soulboundExtension below: "Hooks run after the ledger write so they observe
// the post-movement state; only a caller that recovers from the panic keeps that write." A
// recover() anywhere between a ledger call and the transaction boundary -- even one added
// for an unrelated reason, even one several call-frames away -- would silently convert
// every refused transfer into a permanent, successful one. Don't add one. This is not
// limited to code textually inside this file: a pure `p/` package this realm calls runs in
// garden's own call frame too, so a helper as innocuous as
// `Try(func(){ ledger.TransferFrom(...) })` imported from some future `p/` dependency would
// break the same guarantee just as surely as a recover() written here directly. The same
// rule now also applies to SaveDay's own validate-then-commit pattern below: SaveDay never
// recovers from its own internal panics either, by design -- see that function's comment.
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
	"chain/runtime/unsafe"
)

const (
	collectionName   = "Gnotchi gnomes"
	collectionSymbol = "GNOME"

	// maxNameLen: unchanged from v1 -- see that file's own comment for why this number is
	// kept in step with app/js/config.js's NAME_MAX_LEN by hand rather than generated.
	maxNameLen = 24

	// ---- v2: game-rule constants, ported from app/js/rules.config.json by hand so the
	// realm gives the same answers rules.js does for the same inputs (this assignment's own
	// instruction: "that file is the answer key and the realm must agree with it"). Kept as
	// named Gno constants, not re-read from the JSON file at build time (Gno has no way to
	// read a JSON file at compile time and no file access at run time), so -- exactly like
	// maxNameLen above and app/js/config.js's NAME_MAX_LEN -- these must be updated by hand
	// if rules.config.json ever changes. Every value below is cited against the exact
	// rules.config.json key it mirrors.
	hourSeconds = int64(3600) // rules.config.json time.hourMs / 1000

	patCooldownHours = int64(12) // time.patCooldownHours
	happyWindowHours = int64(2)  // time.happyWindowHours
	sulkyAfterHours  = int64(72) // time.sulkyAfterHours

	meterMax            = int64(10) // meters.max
	bellyDropEveryHours = int64(3)  // meters.bellyDropEveryHours
	cheerDropEveryHours = int64(6)  // meters.cheerDropEveryHours
	feedBelly           = int64(4)  // meters.feedBelly
	patCheer            = int64(3)  // meters.patCheer
	hungryAtOrBelow     = int64(2)  // meters.hungryAtOrBelow

	acornsStart    = int64(10) // acorns.start
	plantCost      = int64(1)  // acorns.plantCost
	harvestPerPlot = int64(3)  // acorns.harvestPerPlot
	numPlots       = 3         // acorns.plots
	growHours      = int64(24) // acorns.growHours
	feedCost       = int64(1)  // acorns.feedCost
	tinkerCost     = int64(5)  // acorns.tinkerCost

	xpPat            = int64(5)  // xp.pat
	xpFeed           = int64(5)  // xp.feed
	xpHarvestPerPlot = int64(10) // xp.harvestPerPlot
	xpTinker         = int64(15) // xp.tinker
	dailyCareCap     = int64(60) // xp.dailyCareCap

	levelBase   = int64(50) // xp.levelBase
	levelStep   = int64(25) // xp.levelStep
	maxLevel    = int64(20) // xp.maxLevel
	typeAtLevel = int64(5)  // xp.typeAtLevel

	// maxActionsPerCall is this realm's own choice, not a rules.config.json value -- the
	// brief gives no explicit cap on a SaveDay action list's length. Set well above
	// anything one real UTC day can legitimately produce (at most 2 pats 12h apart, 3
	// plots, 1 tinker task, and feeds/plants bounded by the acorn economy itself -- see
	// SaveDay's own comment) and far below anything that would let a hostile caller's list
	// cost meaningful, unbounded gas to merely parse and reject. See this directory's own
	// NOTES.md (realms/garden/v2/NOTES.md, not the repo root's), where this and every other
	// "see NOTES.md" below point.
	maxActionsPerCall = 32

	// maxBackfillHours: v2, audit fix F2, an owner decision (see NOTES.md) -- not a
	// rules.config.json value, there is no such key. Before this fix, an action's
	// timestamp was bounded below only by the gnome's own lastActionAt, with no bound
	// relative to real wall-clock "now", so a player dormant for a year could submit a
	// year of backfilled daily care in one sitting. 48 hours forgives the ordinary
	// "played last night, forgot to press Save before bed" case without forgiving a week
	// off, let alone a year -- the owner's own words were that a player who ignores the
	// game for a year "can't just come back and claim it all in one go." Widening this
	// number later is safe (it only ever grants more than today, never retroactively
	// revokes anything already saved); narrowing it later is not (a player who has
	// structured their play around today's number could lose care they'd have been able
	// to save a moment earlier) -- so this starts tight by design. See SaveDay's own
	// comment for exactly how this bound is enforced.
	maxBackfillHours = int64(48)

	moodHungry  = "hungry"
	moodSulky   = "sulky"
	moodHappy   = "happy"
	moodContent = "content"

	actionPat     = "pat"
	actionFeed    = "feed"
	actionPlant   = "plant"
	actionHarvest = "harvest"
	actionTinker  = "tinker"
)

// validHats/validCoats: unchanged from v1.
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

// plotState: v2. One of this gnome's numPlots garden plots. growing=false means empty
// (plantable); growing=true means occupied since plantedAt, harvestable once growHours
// have passed.
type plotState struct {
	growing   bool
	plantedAt int64 // unix seconds; meaningless when growing is false
}

// gnome: v1's fields (name, hat, coat, level, gnomeType, adoptedAt) are unchanged in
// meaning and position; v2 adds the care-state fields SaveDay reads and writes. Per the
// brief ("Store meters as timestamps, not as decaying numbers") belly/cheer are stored as
// a last-known value plus the unix second it was set at, and meterNow below works out the
// current value from elapsed time whenever anything reads it -- nothing ticks on this
// realm's own clock, there is no scheduled job, and nothing here is updated by anything
// other than a SaveDay call the owning address itself signed.
type gnome struct {
	name      string
	hat       string
	coat      string
	level     int64
	gnomeType string // empty until level typeAtLevel assigns one, or forever on a tie -- see assignType
	adoptedAt int64  // unix seconds

	// v2: meters, stored as (last-set value, the unix second it was set), per the brief.
	belly   int64
	bellyAt int64
	cheer   int64
	cheerAt int64

	// v2: attention tracking for moodNow. lastPatAt == 0 means "never patted" -- see
	// canPat's comment for why 0 is a safe sentinel here (unlike rules.js's canPat, which
	// warns against treating 0 as falsy because JS timestamps are milliseconds-since-1970
	// and 0 is reachable in a test fixture; a Gno gnome's lastPatAt is only ever written
	// from a real chain's time.Now().Unix(), which is never 0 on any chain that has left
	// genesis, so 0 is unambiguously "hasn't happened" here).
	lastPatAt        int64
	lastHappyEventAt int64 // last pat/feed/(win/visit, not in this version) timestamp

	// v2: acorns. Rule 3's "earned-only... can't be bought, sold or sent" is enforced
	// structurally, not by convention: this field is never exported, nothing in this
	// package's exported surface (Adopt, GnomeByAddress, Render, SaveDay, CareState) takes
	// an acorn amount or a second address as an argument anywhere, and every mutation of
	// this field below (-plantCost, -feedCost, -tinkerCost, +harvestPerPlot, the
	// acornsStart at Adopt) only ever touches the calling address's own gnome. There is no
	// function signature in this file that could accept "move N acorns from X to Y" even
	// if someone wanted to add one by mistake, short of writing a wholly new exported
	// function -- which TestAcornsCannotBeTransferred below exists to keep visible if that
	// ever changes.
	acorns int64

	// v2: XP. totalXp is mood-adjusted and capped per calendar day (see SaveDay) and is
	// the only thing levelFromXp reads. xpGarden/xpTinker are lifetime, UNCAPPED,
	// mood-UNADJUSTED tallies of raw harvest/tinker XP, used only to break the level-5 type
	// tie per assignType -- see that function's comment for why these two counters are
	// deliberately not the same number as what feeds totalXp. There is no xpExplorer field
	// because this version has no Visit call (out of scope per this assignment's brief);
	// assignType is always called with explorerXp hard-coded to 0 until a future version
	// adds visits.
	totalXp  int64
	xpGarden int64
	xpTinker int64

	// v2, audit fix F1: dailyCareXp/dailyCareDay are the per-calendar-day accumulator
	// dailyCareCap must actually bound. Earlier code clamped only the current SaveDay call's
	// own adjusted XP to dailyCareCap and added it straight to totalXp -- with no record of
	// how much of that day's allowance a PREVIOUS call already spent, a second call later the
	// same UTC day passed every replay/ordering/same-day check (its timestamps are strictly
	// after the first call's lastActionAt) and was granted its own independent 60-XP
	// allowance: two calls, 60 each, 120 against a cap of 60. dailyCareDay is the UTC day
	// number (dayNumber) the accumulator currently covers; dailyCareXp is reset to 0 whenever
	// a SaveDay call's own day differs from it. See SaveDay's own comment for the clamp.
	dailyCareXp  int64
	dailyCareDay int64

	plots [numPlots]plotState

	lastTinkerAt int64 // unix seconds of the last completed tinker task; 0 = never

	// lastActionAt is the replay/ordering frontier: the unix second of the most recent
	// action any successful SaveDay call has ever applied to this gnome. Initialised to
	// adoptedAt at Adopt time (so no action can ever be dated at-or-before adoption) and
	// advanced to the last action's timestamp at the end of every successful SaveDay call.
	// See SaveDay's comment for the whole threat model this one field closes.
	lastActionAt int64
}

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger

	nextID seqid.ID

	gnomes     = avl.NewTree()
	ownerIndex = avl.NewTree()
)

func init(cur realm) {
	token, ledger = grc721.NewToken(collectionName, collectionSymbol, 0, cur)
	ledger.RegisterExtension(&soulboundExtension{})
}

// soulboundExtension: unchanged from v1. Rule 6 ("every transfer fails") made structural.
// See the package doc above and v1's own long comment (realms/garden/garden.gno) for the
// full writeup of why this relies on the transaction boundary rather than hook ordering,
// and why TransferFrom being a plain method (not a crossing call) is exactly why the
// package-level SECURITY note applies to it.
type soulboundExtension struct{}

func (soulboundExtension) ExtensionKind() string { return "soulbound" }

func (soulboundExtension) OnMint(to address, tid grc721.TokenID) {}

func (soulboundExtension) OnTransfer(from, to address, tid grc721.TokenID) {
	panic("garden: gnomes are soulbound; transfer is permanently disabled")
}

func (soulboundExtension) OnBurn(tid grc721.TokenID) {}

// Adopt: unchanged from v1 in every validation it performs (same order, same messages, same
// OriginSend refusal, same caller derivation). v2 only adds initialising the new care-state
// fields at the bottom, where v1 only set level/gnomeType/adoptedAt.
func Adopt(cur realm, name, hat, coat string) {
	// Unchanged from v1: no banker, no withdrawal path, refuse any attached coins outright
	// rather than strand them. See v1's own comment for the two honest limits on what this
	// guard actually buys (origin-scoped, not frame-scoped; does not prevent a direct bank
	// send to garden's address with no call to Adopt at all).
	if !unsafe.OriginSend().IsZero() {
		panic("garden: adopt accepts no coins; this realm has no banker and cannot return them")
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

	id := nextID.Next()
	tid := grc721.TokenID(id.String())

	if err := ledger.Mint(caller, tid); err != nil {
		panic(err)
	}

	now := time.Now().Unix()

	// v2: a freshly-adopted gnome starts with full belly and cheer (the brief specifies
	// decay rates and the starting acorn count, acorns.start = 10, but never states a
	// starting meter value -- see NOTES.md). lastPatAt/lastHappyEventAt/lastTinkerAt all
	// start at 0 ("never"). lastActionAt starts at adoptedAt itself, which is what makes
	// "every SaveDay action must be strictly after lastActionAt" also mean "no action can
	// be dated at or before adoption" for free, with no separate check needed.
	gnomes.Set(tid.String(), &gnome{
		name:         name,
		hat:          hat,
		coat:         coat,
		level:        1,
		gnomeType:    "",
		adoptedAt:    now,
		belly:        meterMax,
		bellyAt:      now,
		cheer:        meterMax,
		cheerAt:      now,
		acorns:       acornsStart,
		lastActionAt: now,
	})
	ownerIndex.Set(caller.String(), tid.String())

	chain.Emit(
		"Adopt",
		"owner", caller.String(),
		"tokenId", tid.String(),
		"name", name,
		"hat", hat,
		"coat", coat,
	)
}

// alreadyAdopted: unchanged from v1. See that file's comment for why both ownerIndex and
// token.BalanceOf are consulted, not either alone.
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

// validNameLength: unchanged from v1.
func validNameLength(name string) bool {
	n := utf8.RuneCountInString(name)
	return n > 0 && n <= maxNameLen
}

// validNameCharset: unchanged from v1.
func validNameCharset(name string) bool {
	for _, r := range name {
		if !validNameRune(r) {
			return false
		}
	}
	return true
}

// hasVisibleNameContent: unchanged from v1.
func hasVisibleNameContent(name string) bool {
	for _, r := range name {
		if r != ' ' {
			return true
		}
	}
	return false
}

// invisibleLetterRunes: unchanged from v1 in content -- same four codepoints -- but audit
// fix F3 restores v1's own \uXXXX escape form instead of the literal invisible glyphs this
// file had drifted to. The content was still correct (verified by codepoint grep at audit
// time), but a map keyed on literal default-ignorable characters is by definition unreadable
// in an editor or a diff, and any formatter or copy/paste step that strips default-ignorable
// characters could silently empty this denylist with no failing test to catch it. \uXXXX
// escapes are plain ASCII source, so that failure mode no longer exists, and
// TestInvisibleLetterRunesIsExactlyFourPinnedCodepoints below pins both the count and every
// individual codepoint so a truncated map fails loudly instead of silently. See v1's own
// comment for the exhaustive scan that proves this list complete against the Unicode version
// this toolchain ships today, and for what would make it worth re-running.
var invisibleLetterRunes = map[rune]bool{
	'\u115f': true, // HANGUL CHOSEONG FILLER
	'\u1160': true, // HANGUL JUNGSEONG FILLER
	'\u3164': true, // HANGUL FILLER
	'\uffa0': true, // HALFWIDTH HANGUL FILLER
}

// validNameRune: unchanged from v1. See that file's comment for the full rationale
// (allowlist not denylist, what it guarantees, what it deliberately does not -- the
// combining-mark exclusion recorded as an open product question in NOTES.md, and the
// cross-script-homoglyph residual that is accepted, not closed).
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

// gnomeForAddr: unchanged from v1.
func gnomeForAddr(addr address) (tid string, g *gnome, found bool) {
	v := ownerIndex.Get(addr.String())
	if v == nil {
		return "", nil, false
	}
	tid = v.(string)
	gv := gnomes.Get(tid)
	if gv == nil {
		return "", nil, false
	}
	return tid, gv.(*gnome), true
}

// GnomeByAddress: unchanged from v1 -- same signature, same fields, same meaning. v2's new
// care-state fields are deliberately NOT added to this tuple, so that nothing about what
// v1 already promised here changes; see CareState below for the new read.
func GnomeByAddress(addr address) (tokenID, name, hat, coat string, level int64, gnomeType string, adoptedAtUnix int64, found bool) {
	tid, g, ok := gnomeForAddr(addr)
	if !ok {
		return "", "", "", "", 0, "", 0, false
	}
	return tid, g.name, g.hat, g.coat, g.level, g.gnomeType, g.adoptedAt, true
}

// CareState is v2's new read: the SaveDay-relevant state GnomeByAddress deliberately
// doesn't carry. belly/cheer are returned already decayed to time.Now() (per the brief,
// "work out meter values from stored timestamps when they're read" applies to every
// reader, not just SaveDay's own internal bookkeeping) -- a caller never sees a stale
// stored value and has to re-derive the decay itself.
func CareState(addr address) (belly, cheer, acorns, totalXp, lastPatAtUnix, lastActionAtUnix int64, found bool) {
	_, g, ok := gnomeForAddr(addr)
	if !ok {
		return 0, 0, 0, 0, 0, 0, false
	}
	now := time.Now().Unix()
	return meterNow(g.belly, g.bellyAt, now, bellyDropEveryHours),
		meterNow(g.cheer, g.cheerAt, now, cheerDropEveryHours),
		g.acorns, g.totalXp, g.lastPatAt, g.lastActionAt, true
}

// Render: unchanged from v1 except one new bullet (Acorns) -- see this function's own
// history in v1 for the full writeup of why path is bech32-validated before anything
// derived from it is ever echoed back into the page. v2 deliberately does not also render
// belly/cheer/garden-plot state here: CareState above is the read for that, and growing
// gnoweb's single markdown page to show every care-state field is a product decision for a
// later pass, not an engineering requirement this assignment's brief asks for.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf(
			"# %s\n\nSoulbound gnome collection. Every gnome is non-transferable: see rule 6.\n\n* **Total adopted**: %d\n",
			collectionName, token.TotalSupply(),
		)
	}

	addr := address(path)
	if !addr.IsValid() {
		return ufmt.Sprintf("# %s\n\nNo gnome adopted for an invalid address.\n", collectionName)
	}

	tid, g, ok := gnomeForAddr(addr)
	if !ok {
		return ufmt.Sprintf("# %s\n\nNo gnome adopted yet for `%s`.\n", collectionName, addr.String())
	}

	gnomeType := g.gnomeType
	if gnomeType == "" {
		gnomeType = "(not yet set)"
	}

	str := ufmt.Sprintf("# %s\n\n", g.name)
	str += ufmt.Sprintf("* **Owner**: %s\n", addr.String())
	str += ufmt.Sprintf("* **Token ID**: %s\n", tid)
	str += ufmt.Sprintf("* **Level**: %d\n", g.level)
	str += ufmt.Sprintf("* **Type**: %s\n", gnomeType)
	str += ufmt.Sprintf("* **Look**: %s hat, %s coat\n", g.hat, g.coat)
	str += ufmt.Sprintf("* **Acorns**: %d\n", g.acorns)

	return str
}

// ============================================================================
// v2: SaveDay and its helpers. Everything below this line is new.
// ============================================================================

// saveAction is one parsed entry from a SaveDay call's action list.
type saveAction struct {
	kind string
	at   int64 // unix seconds, as claimed by the caller
	plot int   // only meaningful for actionPlant/actionHarvest
}

// SaveDay is brief section 5.2's "one daily save": the day's actions -- pats, feeds,
// plants, harvests and a tinker task -- submitted as a single list in one signed call.
//
// ENCODING, and why it looks like this rather than like the brief's own
// "SaveDay(gnomeID, actions)": a public realm function reachable by `maketx call` or
// Adena's DoContract can only take arguments gno.land's own call-argument decoder knows how
// to build -- read directly from this toolchain's gno.land/pkg/sdk/vm/convert.go
// (convertArgToGno): primitive scalars (bool, string, every sized int/uint/float) and
// fixed-size-or-slice []byte (base64). There is no case there for a slice of structs, and
// no amount of Gno-side type cleverness changes what the transaction's wire format can
// carry. So "actions as a list" has to arrive as a single string this function parses
// itself, not as a []Action the chain's own tooling has no way to construct from a
// gnokey/Adena call. actionsRaw is semicolon-separated entries, each colon-separated:
//
//	"pat:<unixSeconds>"
//	"feed:<unixSeconds>"
//	"tinker:<unixSeconds>"
//	"plant:<plotIndex>:<unixSeconds>"
//	"harvest:<plotIndex>:<unixSeconds>"
//
// e.g. "pat:1791600000;feed:1791601000;plant:0:1791602000". An empty string means an empty
// action list (a legal no-op call). See NOTES.md for this decision in full.
//
// Also absent from the brief's own signature: gnomeID. v1 and v2 both enforce one gnome
// per address with no transfer and no delegation of any kind -- there is no second gnome
// an address could ever mean by "gnomeID", and no path by which SaveDay could legitimately
// be asked to act on any gnome but the caller's own. Dropping the parameter removes a
// whole class of "whose gnome is this call actually touching" bug before it can exist,
// rather than adding a check that would only ever have one correct answer anyway. See
// NOTES.md.
//
// THREAT MODEL -- this assignment's own brief asks for this explicitly: actionsRaw is
// client-supplied and this realm is the only authority over it, full stop. Specifically
// defended below, each against a concrete hostile input:
//
//   - Replay (resubmitting an already-applied batch, in whole or in part): every action's
//     timestamp must be strictly greater than lastActionAt, the gnome's own high-water
//     mark of the latest action any past SaveDay call has ever actually applied. A replayed
//     batch's first action is, by definition, <= that mark.
//   - Duplicate actions within one call: the same strict-increase rule applies action to
//     action within the list (actions[i].at < actions[i+1].at required), so two actions
//     sharing one timestamp -- the only way a client could claim two things happened at
//     once -- is rejected regardless of which two kinds they are.
//   - Future-dated actions: every timestamp must be <= time.Now().Unix(), this call's own
//     block time. Nothing claimed to have happened hasn't happened yet.
//   - Past-dated actions, at or before adoption: subsumed by the replay check above --
//     lastActionAt starts at adoptedAt (see Adopt), so no action can ever be dated before
//     adoption either.
//   - Unlimited backfill after a long dormancy (audit fix F2, an owner decision -- see
//     NOTES.md): the two checks above bound an action relative to lastActionAt (below) and
//     to now (above), but say nothing about how far *below* now an action may be, so
//     nothing stopped a player dormant for a year from backfilling a year of daily care in
//     one sitting. maxBackfillHours (48) closes this with two parts, both needed: (1) any
//     action older than the window is rejected outright, with a message a player can
//     understand, and (2) the floor the ordering/replay check above enforces is itself
//     clamped forward to at least now-maxBackfillHours before that loop runs, rather than
//     left at the gnome's raw, possibly year-old lastActionAt -- so even if (1) were ever
//     weakened or removed by a future edit, the floor the replay check already enforces
//     would independently keep the backfillable span bounded. See the validation loop
//     below for both parts and NOTES.md for the owner's reasoning on the 48-hour number.
//   - Inflated action counts (e.g. fifty pats claimed in one day): canPat's 12-hour spacing
//     makes more than two pats a day arithmetically impossible inside one call regardless
//     of what the list claims, and feed/plant/tinker are each gated by this gnome's own
//     acorn balance, which this exact set of rules is the only thing that can ever
//     increase -- there is no action, in this call or any other exported function, that
//     credits acorns without the realm itself having applied the matching cost somewhere
//     upstream. The realm's own economy is the rate limit; no separate per-type daily
//     counter is needed on top of it.
//   - A thousand actions in one list: rejected by maxActionsPerCall before a single entry is
//     even parsed -- parseActions counts the ";" delimiters first and panics on an oversized
//     count before calling strings.Split at all, so an oversized actionsRaw never pays the
//     cost of allocating a huge split result just to be rejected a moment later.
//   - XP inflation via the daily cap: rawCareXp for the whole call is mood-adjusted, then
//     clamped to whatever remains of dailyCareCap for the UTC calendar day this call's own
//     actions fall on -- tracked by the gnome's own dailyCareXp/dailyCareDay accumulator, not
//     by anything scoped to one call. Audit fix F1: earlier code capped only the current
//     call's own XP at dailyCareCap and had no record of what a PREVIOUS call the same day
//     had already spent, so a second same-day call got its own independent 60-XP allowance
//     (two calls, 60 each, 120 against a cap of 60). See the cap/mood block below and the
//     gnome struct's own comment on dailyCareXp/dailyCareDay.
//
// ATOMICITY: every check below runs against a local copy (work) of the caller's own
// gnome, taken by value at the top of this function. Nothing is written back to the
// gnomes tree until every action in the list has validated and applied cleanly against
// that copy; any panic before the final commit leaves the persisted gnome completely
// untouched, with no partial effect to undo. This is deliberately a plain Go/Gno value
// copy, not a recover()-and-rollback: see the package-level SECURITY note for why a
// recover() anywhere in this realm is never the right tool, including here.
func SaveDay(cur realm, actionsRaw string) {
	if !unsafe.OriginSend().IsZero() {
		panic("garden: save day accepts no coins; this realm has no banker and cannot return them")
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
	// the "one calendar day per call" rule: SaveDay is brief 5.2's "one daily save", so a
	// call spanning more than one UTC day is rejected outright rather than guessed at how to
	// split -- see NOTES.md for why this is the simplest sound reading, not the only
	// conceivable one.
	//
	// v2, audit fix F2 (owner's decision -- see NOTES.md): earliestAllowed is the backfill
	// floor, maxBackfillHours before THIS call's own "now". Two independent uses of it below,
	// both required:
	//
	//  1. Every action's own timestamp is checked directly against earliestAllowed inside the
	//     loop and panics with a player-facing message if it is older than the window allows.
	//  2. prevAt -- the floor the pre-existing strictly-increasing/replay check enforces -- is
	//     clamped forward to earliestAllowed here, before the loop starts, instead of being
	//     seeded straight from the gnome's own (possibly year-old) lastActionAt. This is
	//     deliberately not left to check 1 alone: clamping prevAt means the SAME
	//     already-proven strictly-increasing machinery that catches replay and duplicate
	//     timestamps above also independently enforces this exact floor, so the bound does
	//     not rest on a single, separately-written comparison that a future edit could weaken
	//     or delete without anything else noticing. A gnome dormant far longer than the
	//     window still only ever gets prevAt clamped to earliestAllowed, never further back --
	//     see NOTES.md for the test that exercises this distinction directly.
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

	// Apply pass: mutate a local copy only. work.plots is a fixed-size array (a value
	// type), so `work := *g` copies it in full -- mutating work.plots[i] below never
	// touches g.plots[i] until the explicit commit at the end.
	work := *g
	rawCareXp := int64(0)
	tinkeredThisCall := false

	for _, a := range actions {
		switch a.kind {
		case actionPat:
			if !canPat(work.lastPatAt, a.at) {
				panic("garden: pat must be at least 12 hours after the last one")
			}
			work.lastPatAt = a.at
			work.lastHappyEventAt = a.at
			work.cheer = clampMeter(meterNow(work.cheer, work.cheerAt, a.at, cheerDropEveryHours) + patCheer)
			work.cheerAt = a.at
			rawCareXp += xpPat

		case actionFeed:
			if work.acorns < feedCost {
				panic("garden: not enough acorns to feed")
			}
			work.acorns -= feedCost
			work.belly = clampMeter(meterNow(work.belly, work.bellyAt, a.at, bellyDropEveryHours) + feedBelly)
			work.bellyAt = a.at
			work.lastHappyEventAt = a.at
			rawCareXp += xpFeed

		case actionPlant:
			bellyAtAction := meterNow(work.belly, work.bellyAt, a.at, bellyDropEveryHours)
			if bellyAtAction <= hungryAtOrBelow {
				// Table 3.3: "Hungry: can't garden until fed." v2 reads this as blocking
				// new planting only, not harvesting an already-grown plot -- see NOTES.md
				// for why (rule 9: the gnome never loses progress; a ready harvest should
				// never be strandable behind an unrelated hunger gate).
				panic("garden: too hungry to garden; feed first")
			}
			p := &work.plots[a.plot]
			if p.growing {
				panic("garden: that plot is already planted")
			}
			if work.acorns < plantCost {
				panic("garden: not enough acorns to plant")
			}
			work.acorns -= plantCost
			p.growing = true
			p.plantedAt = a.at

		case actionHarvest:
			p := &work.plots[a.plot]
			if !p.growing {
				panic("garden: that plot has nothing to harvest")
			}
			if a.at-p.plantedAt < growHours*hourSeconds {
				panic("garden: that plot is not ready to harvest yet")
			}
			p.growing = false
			p.plantedAt = 0
			work.acorns += harvestPerPlot
			work.xpGarden += xpHarvestPerPlot
			rawCareXp += xpHarvestPerPlot

		case actionTinker:
			if tinkeredThisCall {
				panic("garden: only one tinker task per day")
			}
			if work.lastTinkerAt != 0 && dayNumber(work.lastTinkerAt) == dayNumber(a.at) {
				panic("garden: already did a tinker task today")
			}
			if work.acorns < tinkerCost {
				panic("garden: not enough acorns to tinker")
			}
			work.acorns -= tinkerCost
			work.xpTinker += xpTinker
			work.lastTinkerAt = a.at
			tinkeredThisCall = true
			rawCareXp += xpTinker

		default:
			// Unreachable: parseActions already rejects any kind outside this set.
			panic("garden: unknown action kind")
		}
	}

	// Mood snapshot for the whole call's raw care XP -- matching app/js/rules.js's
	// careXpForDay(rawCareXp, mood), which also takes one mood value for an entire day's
	// total rather than re-deriving mood per action. The "now" used for this mood snapshot is
	// latestActionAt: the LAST action's own timestamp, using the state exactly as this call
	// leaves it, not the state from before any of today's actions.
	//
	// Audit fix F1, naming half: this variable used to be called endOfDay, which reads as
	// "the day is closed" and actually means "the last action this call happened to process"
	// -- a claim about this call's own list, not about the calendar day at all. That gap is
	// plausibly what hid the F1 cap bug (below) from its own author and from the tests: a
	// name that says "the day is over" invites the reader to assume the day's allowance has
	// been fully accounted for here, when nothing before this fix actually tracked that
	// across calls. Renamed to say only what it is.
	latestActionAt := actions[len(actions)-1].at
	bellyAtEnd := meterNow(work.belly, work.bellyAt, latestActionAt, bellyDropEveryHours)
	mood := moodNow(bellyAtEnd, work.lastPatAt, work.lastHappyEventAt, latestActionAt)

	adjustedXp := rawCareXp
	switch mood {
	case moodHappy:
		// xp*11/10, integer division: exactly floor(xp*1.1) for every non-negative xp, with
		// no floating-point representation error -- see NOTES.md for why this is a more
		// precise reimplementation of rules.js's Math.floor(xp*(1+0.1)), not a different
		// rule, and why every case rules.test.js actually exercises agrees with it exactly.
		adjustedXp = adjustedXp * 11 / 10
	case moodSulky:
		adjustedXp = adjustedXp * 9 / 10
	}

	// Audit fix F1, cap half: dailyCareCap must bound a UTC CALENDAR DAY's total care XP,
	// not one call's. work.dailyCareDay/work.dailyCareXp (see the gnome struct's own comment)
	// is the accumulator that makes that true across calls: reset to 0 the moment this call's
	// own day (firstDay, computed and validated against every action above) differs from
	// whatever day the accumulator currently covers, then clamp this call's adjusted XP to
	// whatever is actually left of the cap, and top the accumulator up by exactly that much
	// -- never by the pre-clamp adjustedXp. A second call later the same day now sees a
	// non-zero dailyCareXp left over from the first and gets only the remainder, instead of
	// its own independent 60-point allowance.
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

	// Type assignment at level typeAtLevel: see assignType's own comment for the tie rule.
	if work.gnomeType == "" && work.level >= typeAtLevel {
		work.gnomeType = assignType(work.xpGarden, 0, work.xpTinker)
	}

	work.lastActionAt = latestActionAt

	*g = work
	// Explicit re-Set after the in-place *g = work commit above: g is already the same
	// *gnome pointer the gnomes tree holds (see gnomeForAddr), so this is a zero-cost no-op
	// today, not a behaviour change -- it removes any question about relying on in-place
	// mutation through a stored pointer that could not be settled by reading the code alone,
	// per the audit's own smaller-items list.
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

// parseActions parses and validates the wire format SaveDay's own comment documents, and
// enforces maxActionsPerCall before doing any per-entry work -- a caller who sends a
// thousand ";"-separated entries is rejected on the delimiter COUNT alone, before
// strings.Split ever runs.
//
// Audit fix F5: this used to call strings.Split(raw, ";") first and check len(parts) >
// maxActionsPerCall second -- but Split itself allocates the full []string result (one
// allocation per entry) before that length is ever inspected, so a megabyte of semicolons
// allocated half a million short-lived strings before being rejected. SaveDay's own comment
// claims an oversized list is rejected "before a single entry is even parsed," which was
// true of per-entry parsing but not of this allocation. strings.Count scans the raw bytes
// for the delimiter without allocating a result slice, so the oversized case is now rejected
// without allocating anything proportional to the attacker's input at all. The caller still
// pays their own gas for whatever they send, so this was never a DoS on other users -- this
// fix makes the comment's own claim true, it does not close a cross-user vulnerability.
func parseActions(raw string) []saveAction {
	if raw == "" {
		return nil
	}

	if n := strings.Count(raw, ";") + 1; n > maxActionsPerCall {
		panic("garden: too many actions in one call (max " + strconv.Itoa(maxActionsPerCall) + ")")
	}

	parts := strings.Split(raw, ";")

	actions := make([]saveAction, 0, len(parts))
	for _, part := range parts {
		fields := strings.Split(part, ":")
		switch fields[0] {
		case actionPat, actionFeed, actionTinker:
			if len(fields) != 2 {
				panic("garden: malformed action \"" + part + "\"")
			}
			actions = append(actions, saveAction{
				kind: fields[0],
				at:   parseUnixField(fields[1], part),
			})
		case actionPlant, actionHarvest:
			if len(fields) != 3 {
				panic("garden: malformed action \"" + part + "\"")
			}
			actions = append(actions, saveAction{
				kind: fields[0],
				plot: parsePlotField(fields[1], part),
				at:   parseUnixField(fields[2], part),
			})
		default:
			panic("garden: unknown action kind in \"" + part + "\"")
		}
	}
	return actions
}

func parseUnixField(s, part string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		panic("garden: invalid timestamp in action \"" + part + "\"")
	}
	return v
}

func parsePlotField(s, part string) int {
	v, err := strconv.Atoi(s)
	if err != nil || v < 0 || v >= numPlots {
		panic("garden: invalid plot index in action \"" + part + "\"")
	}
	return v
}

// dayNumber is the UTC calendar day index for a unix-second timestamp -- integer division
// by 86400 lands exactly on 00:00 UTC boundaries, matching brief 3.1 ("a day for daily
// limits runs from 00:00 to 24:00 UTC") without any timezone handling, because unix time
// is UTC by definition.
func dayNumber(unixSeconds int64) int64 { return unixSeconds / 86400 }

// meterNow ports app/js/rules.js's meterNow exactly: work out the current value from a
// last-known value, the unix second it was set, and how many whole dropEveryHours periods
// have elapsed since, clamped to [0, meterMax].
func meterNow(value, setAt, now, dropEveryHours int64) int64 {
	if now < setAt {
		now = setAt
	}
	drops := (now - setAt) / (dropEveryHours * hourSeconds)
	v := value - drops
	return clampMeter(v)
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

// canPat ports app/js/rules.js's canPat: lastPatAt == 0 means never patted (see gnome's own
// comment for why 0 is an unambiguous sentinel here, unlike in the JS version).
func canPat(lastPatAt, now int64) bool {
	return lastPatAt == 0 || now-lastPatAt >= patCooldownHours*hourSeconds
}

// moodNow ports app/js/rules.js's moodNow, in the same first-match-wins order as brief
// table 3.3: hungry, then sulky, then happy, then content. "Asleep" is display-only (brief
// 3.1) and has no on-chain representation at all, exactly as in rules.js.
//
// A gnome that has never been patted (lastPatAt == 0) reads as sulky here, immediately,
// even on the day it was adopted, if that day's batch never includes a pat -- ported
// faithfully from rules.js's own `Math.max(g.lastPatAt || 0, ...)`, which has the identical
// property (a never-patted gnome's "last attention" is treated as unix-epoch-zero, so
// "no pat for 72 hours" is trivially true). rules.test.js never exercises this edge case
// (every mood fixture there sets lastPatAt to a real recent-ish value), so this is a
// faithful port of the answer key's actual formula, not a verified-by-the-answer-key's-own-
// tests behaviour -- flagged here rather than silently relied on. See NOTES.md.
func moodNow(belly, lastPatAt, lastHappyEventAt, now int64) string {
	if belly <= hungryAtOrBelow {
		return moodHungry
	}
	if now-lastPatAt >= sulkyAfterHours*hourSeconds {
		return moodSulky
	}
	if lastHappyEventAt != 0 && now-lastHappyEventAt <= happyWindowHours*hourSeconds {
		return moodHappy
	}
	return moodContent
}

// xpToNext/totalXpForLevel/levelFromXp port app/js/rules.js's functions of the same name,
// line for line in spirit: 50 + 25*level to reach the next level, level 20 the maximum.
func xpToNext(level int64) int64 { return levelBase + levelStep*level }

func totalXpForLevel(level int64) int64 {
	var t int64
	for l := int64(1); l < level; l++ {
		t += xpToNext(l)
	}
	return t
}

func levelFromXp(totalXp int64) int64 {
	level := int64(1)
	for level < maxLevel && totalXp >= totalXpForLevel(level+1) {
		level++
	}
	return level
}

// assignType ports app/js/rules.js's assignType. On a genuine tie (including the trivial
// three-way tie of a gnome that reached level 5 on pats and feeds alone, which count
// towards no type at all) this returns "" rather than guessing: the brief says "the player
// chooses", and this version has no chooser endpoint (StartRetrain/an explicit "choose
// type" call is out of scope here) -- see NOTES.md. This mirrors v1's own existing
// convention that an empty gnomeType is a valid, documented, permanent-until-resolved
// state (Render already prints "(not yet set)" for it).
func assignType(gardenXp, explorerXp, tinkerXp int64) string {
	best := gardenXp
	if explorerXp > best {
		best = explorerXp
	}
	if tinkerXp > best {
		best = tinkerXp
	}

	tiedCount := 0
	if gardenXp == best {
		tiedCount++
	}
	if explorerXp == best {
		tiedCount++
	}
	if tinkerXp == best {
		tiedCount++
	}
	if tiedCount != 1 {
		return ""
	}

	switch {
	case gardenXp == best:
		return "gardener"
	case explorerXp == best:
		return "explorer"
	default:
		return "tinkerer"
	}
}
