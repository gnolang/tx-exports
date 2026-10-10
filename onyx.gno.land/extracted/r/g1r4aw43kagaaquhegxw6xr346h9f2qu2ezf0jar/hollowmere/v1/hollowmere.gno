// Package hollowmere is the on-chain slice of Book One, "The Three Ember Seeds" -- the
// adventure's own chain record, separate from garden/v2's pet-care record, per the
// owner's ask: "the adventure game needs chain features."
//
// Authored and tested without gnokey or any key material, per this assignment's own
// brief. Whether and when this package has actually been deployed is deliberately not
// asserted here: this comment ships on chain exactly as written the moment it is
// deployed, and a realm cannot be edited afterwards, so a "not deployed yet" sentence
// here would go permanently stale at the exact moment it stopped being true -- see
// garden/v2/gnomod.toml's own history for why this is a real failure mode, not a
// hypothetical one. Deploy status belongs in DECISIONS.md and STATUS.md, which can still
// be edited after the fact.
//
// ============================================================================
// THE HONESTY PROBLEM THIS PACKAGE EXISTS INSIDE -- READ THIS FIRST
// ============================================================================
//
// The adventure's levels run in the browser. This chain cannot watch a player solve the
// rune-rhyme puzzle, bonk the Great Mothkin three times, or do anything else Book One's
// plan describes -- it can only watch a wallet sign a transaction that ASSERTS those
// things happened. The plan itself says this plainly: "the levels run in the browser, so
// a determined cheat can poke at them" (pack-update/01-adventure-plan/book-one-plan.md,
// "Risks and decisions for Seán").
//
// So this package is commented, named and worded throughout to make that limit impossible
// to miss -- carried by the comments, the event name, the type names and Render's own
// wording, not by any single exported function's name in isolation (a player signing
// ClearChapter(1, 1) in a wallet sees that call and nothing else; the honesty framing has
// to already live in the surrounding names and docs, because there is no comment attached
// to a signing prompt):
//
//   - ClearChapter does not "verify" or "check" a clear. It records a CLAIM: this address
//     says it cleared this chapter, and the chain stamps that claim with the block's own
//     timestamp. Nothing here replays a puzzle, checks an input log, or asks the browser
//     for proof of anything. The function's own comment says so; the bare function name a
//     wallet shows does not carry this by itself.
//   - bookOneClaim, the storage type, and claims, the tree that holds it, are named for
//     what they are: a ledger of claims, not a record of verified outcomes.
//   - The emitted event is named ChapterClaimed, not ChapterCleared or ChapterVerified.
//   - Render's own wording repeats this to the one audience who will actually read it: a
//     player looking at their own public page.
//
// What this DOES genuinely give the game, worth having even though it is not refereed:
// the record is public, permanent, timestamped by the chain rather than the client,
// tied to a wallet rather than a browser's local storage, and readable by anyone without
// trusting gnotchi.com's server to tell the truth. For a cosy single-player adventure
// with nothing to win from another player's loss, that is a sound trade. See NOTES.md for
// the full writeup of why the owner's narrower ask (chapter purchase, the daily burrow,
// players' notes) is deliberately NOT built here, rather than half-built to look more
// complete than it is.
//
// ============================================================================
// SCOPE -- what this package is, and deliberately is not
// ============================================================================
//
// Built: chapter-completion claims (ClearChapter), Ember Seeds derived from those claims
// (never accepted as an input), a per-address progress read (BookOneClaim), and a public
// Render page.
//
// NOT built, on purpose, not half-built: chapter purchase (nothing is for sale here; this
// package handles no money at all, enforced the same way garden/v2 does, below), the daily
// burrow and its leaderboard (needs a dungeon generator that doesn't exist yet), and
// players' notes (stored free text on a permanent public page re-opens the hostile-name
// problem garden/garden.gno's own NOTES.md already has open, and deserves its own design
// pass rather than a rushed one here). See NOTES.md for the full reasoning on each.
//
// ============================================================================
// WHY THIS NEVER CALLS recover()
// ============================================================================
//
// This package calls no grc721 ledger, mints nothing, and has no transfer hook to protect
// -- the specific recover()-undoes-a-soulbound-guarantee trap garden/garden.gno's own
// SECURITY note documents does not literally apply here, because there is no ledger write
// to re-expose. But the underlying reason not to recover() is the same one stated above in
// different words: this package's entire credibility is "the chain only ever records a
// claim that fully passed every check in ClearChapter below." Every mutating path in this
// file validates completely BEFORE touching any stored claim (see ClearChapter's own
// comment for the exact validate-then-commit sequence), so an uncaught panic already
// guarantees the Gno/Cosmos SDK transaction boundary discards the whole failed call with
// no partial claim ever written. A recover() anywhere in this file -- even one added later
// for an unrelated reason -- could let a claim that failed a check halfway through land
// anyway, which is exactly the "the chain checked something it didn't" impression this
// package's own doc above insists it must never give. Don't add one.
package hollowmere

import (
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"chain"
	"chain/runtime/unsafe"
)

const (
	// bookOne is the only book number ClearChapter accepts today. Book One, "The Three
	// Ember Seeds", is the only book this plan has designed chapters for
	// (pack-update/01-adventure-plan/book-one-plan.md); Book Two is named only as a hook
	// ("something is drinking the moonlight, and nobody knows what yet") with no chapters,
	// tools, puzzles or prices written down anywhere this package could build against.
	bookOne = int64(1)

	// maxBook bounds ClearChapter's own book argument. Only bookOne exists today, so
	// maxBook == bookOne -- and unlike garden/v2's maxBackfillHours, this is not a
	// constant that could later be widened in place: this realm is immutable once
	// deployed, so maxBook is fixed at 1 here forever. A real Book Two would not widen
	// this constant in this file; it would be a wholly separate realm, with its own
	// gnomod.toml, its own empty claims tree, and its own bound to set -- it could not
	// read this package's unexported state even if it wanted to widen anything here. See
	// NOTES.md.
	maxBook = bookOne

	// numChaptersBookOne: Book One has exactly four chapters (The Mossy Burrow, The Sunken
	// Greenhouse, The Cogwork Mill, The Long Night) per the plan's own chapter list. Left
	// untyped so it doubles as claimedAt's array length below without a conversion.
	numChaptersBookOne = 4

	// numEmberSeedChapters: only chapters 1-3 each win back one Ember Seed. The plan's own
	// words: "Each chapter wins one back, and the last chapter brings them home" -- chapter
	// 4 (The Long Night) is the finale that reunites the three seeds already won, not a
	// fourth seed. See emberSeedsFor's own comment for how this is derived, never accepted
	// as a parameter.
	numEmberSeedChapters = 3
)

// bookOneClaim is one address's claimed progress through Book One. Named claim, not
// progress or record, on purpose: every field here is what an address SAID, timestamped
// by the chain when it said it, never something this package checked against the actual
// game. See the package doc above.
type bookOneClaim struct {
	// highestChapterClaimed is 0 until the first successful ClearChapter call for this
	// address, then the highest chapter number it has claimed -- chapters claim strictly in
	// order (see ClearChapter), so "highest" and "count of chapters claimed" are always the
	// same number for as long as this field exists.
	highestChapterClaimed int64

	// claimedAt[i] is the unix-second block timestamp (time.Now().Unix() at the moment
	// ClearChapter accepted chapter i+1's claim for this address), or 0 if chapter i+1 has
	// not been claimed yet. This is block time, the same chain-trustworthy clock
	// garden/v2's own SaveDay reads -- never a timestamp the caller supplies, because
	// unlike SaveDay (which batches a day's worth of actions and genuinely needs a
	// backfill window for a player who forgot to press Save), ClearChapter records one
	// single, discrete claim at the moment the wallet signs it. There is nothing to
	// backfill and nothing a client-supplied timestamp would buy a player that the chain's
	// own clock doesn't already give them for free.
	claimedAt [numChaptersBookOne]int64
}

var (
	// claims is this package's entire state: a ledger of claims, keyed by
	// claimKey(address, book), never by address alone. Book One is the only book accepted
	// today (see maxBook), and -- because this realm is immutable once deployed -- no
	// migration question from widening maxBook can ever arise here: a real Book Two would
	// be a different realm entirely, with its own empty tree, unable to read this
	// package's unexported state at all. Keying by (address, book) anyway costs nothing
	// (one string-concatenation helper, claimKey) and is simply tidier than keying by
	// address alone. See NOTES.md.
	claims = avl.NewTree()

	// totalClaimants: addresses with at least one accepted claim in Book One. Incremented
	// exactly once per address, the first time ClearChapter accepts any chapter for it --
	// see ClearChapter's own isNewClaimant handling.
	totalClaimants int64
)

// claimKey is the tree key for one (address, book) pair's claim.
func claimKey(addr address, book int64) string {
	return addr.String() + ":" + strconv.FormatInt(book, 10)
}

// ClearChapter records that the calling address CLAIMS to have cleared this chapter of
// this book. See the package doc above for what this is and is not: a timestamped,
// public, permanent claim, never a verified outcome.
//
// Accepts no coins (this package handles no money at all; see NOTES.md for why chapter
// purchase is out of scope entirely, not half-built). Chapters must clear in strict order,
// starting from 1, and each chapter may be claimed at most once per address -- both
// enforced by the single comparison below against highestChapterClaimed, the same way
// garden/v2 favours one invariant that closes several hostile cases over several separate
// ad hoc checks (see that file's SaveDay comment). Ember Seeds are never a parameter here
// or anywhere in this package: see emberSeedsFor for how they are derived instead.
//
// ATOMICITY: every check below runs to completion before anything is written. work is a
// plain value copy of this address's existing claim (or the zero value, if this is its
// first), taken after every validation has already passed; the only thing that happens to
// it is the two-field update at the bottom, so a panic anywhere above that point leaves
// the persisted claim -- if any -- completely untouched. This mirrors garden/v2's SaveDay
// pattern deliberately: a plain value copy, not a recover()-and-rollback. See the package
// doc for why recover() is never the right tool here either.
func ClearChapter(cur realm, book, chapter int64) {
	if !unsafe.OriginSend().IsZero() {
		panic("hollowmere: clearing a chapter accepts no coins; this realm has no banker and cannot return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("hollowmere: clearing a chapter requires a valid caller address")
	}

	if book < 1 || book > maxBook {
		panic("hollowmere: book " + strconv.FormatInt(book, 10) + " does not exist; only Book One is playable today")
	}
	if chapter < 1 || chapter > int64(numChaptersBookOne) {
		panic("hollowmere: chapter " + strconv.FormatInt(chapter, 10) + " does not exist in Book One; chapters run 1-4")
	}

	key := claimKey(caller, book)
	v := claims.Get(key)

	var existing bookOneClaim
	isNewClaimant := v == nil
	if !isNewClaimant {
		existing = *(v.(*bookOneClaim))
	}

	if chapter <= existing.highestChapterClaimed {
		panic("hollowmere: chapter " + strconv.FormatInt(chapter, 10) + " was already claimed cleared for this address")
	}
	if chapter > existing.highestChapterClaimed+1 {
		panic("hollowmere: chapters claim in order; claim chapter " +
			strconv.FormatInt(existing.highestChapterClaimed+1, 10) +
			" before claiming chapter " + strconv.FormatInt(chapter, 10))
	}

	now := time.Now().Unix()

	work := existing
	work.claimedAt[chapter-1] = now
	work.highestChapterClaimed = chapter

	claims.Set(key, &work)
	if isNewClaimant {
		totalClaimants++
	}

	chain.Emit(
		"ChapterClaimed",
		"address", caller.String(),
		"book", strconv.FormatInt(book, 10),
		"chapter", strconv.FormatInt(chapter, 10),
		"claimedAt", strconv.FormatInt(now, 10),
		"emberSeeds", strconv.FormatInt(emberSeedsFor(&work), 10),
	)
}

// emberSeedsFor derives the number of Ember Seeds this claim implies: one per chapter 1-3
// claimed cleared (chapter 4 is the finale that brings the three home, not a fourth seed --
// see numEmberSeedChapters's own comment). This is the ONLY place Ember Seeds are computed
// anywhere in this package. There is no exported function, field, or parameter anywhere in
// this file that lets a caller set, add, or otherwise assert an Ember Seed count directly
// -- it is always read off highestChapterClaimed, never written. A client cannot claim
// seeds it did not (claim to have) earned, because there is no spelling of a call into
// this package that takes a seed count as input at all.
//
// Reads highestChapterClaimed, never claimedAt: ClearChapter only ever advances both
// fields together (see its own comment), so the two cannot disagree today -- but
// highestChapterClaimed is the simpler source of truth. claimedAt uses 0 as its own
// "not yet claimed" sentinel while also being written from real block time, a dual
// representation of the same fact with a sentinel to keep straight; highestChapterClaimed
// needs neither. Capped at numEmberSeedChapters so chapter 4 (the finale, not a fourth
// seed-winning chapter) never adds a 4th.
func emberSeedsFor(c *bookOneClaim) int64 {
	n := c.highestChapterClaimed
	if n > numEmberSeedChapters {
		n = numEmberSeedChapters
	}
	return n
}

// BookOneClaim is the progress read for one address: what it has claimed in Book One, and
// the Ember Seed count derived from those claims. found is false if this address has never
// had a ClearChapter call accepted for Book One at all.
func BookOneClaim(addr address) (highestChapterClaimed, chapter1ClaimedAt, chapter2ClaimedAt, chapter3ClaimedAt, chapter4ClaimedAt, emberSeeds int64, found bool) {
	v := claims.Get(claimKey(addr, bookOne))
	if v == nil {
		return 0, 0, 0, 0, 0, 0, false
	}
	c := v.(*bookOneClaim)
	return c.highestChapterClaimed, c.claimedAt[0], c.claimedAt[1], c.claimedAt[2], c.claimedAt[3], emberSeedsFor(c), true
}

// TotalClaimants returns the number of addresses with at least one accepted chapter claim
// in Book One. Everything claims holds is already public via Render (there is no privacy
// cost to exposing it), but before this function the only way to reach this exact number
// was BookOneClaim(someKnownAddress) for one address at a time, or string-parsing the
// overview page Render("") returns. Neither lets another realm -- a future Book Two, a
// shop, a leaderboard -- enumerate or even count claimants, which is a real limitation for
// a ledger whose entire stated purpose is being publicly readable. See ClaimantsPage below
// for the enumerator this same gap needed.
func TotalClaimants() int64 {
	return totalClaimants
}

// maxClaimantsPageSize bounds a single ClaimantsPage call's own limit, so that call stays
// gas-bounded no matter how large claims grows over this realm's lifetime -- a caller
// cannot make one call's own cost scale with the whole ledger's size just by asking for a
// bigger page. Picked well above anything a real paging UI needs per page (a leaderboard
// or an admin view rendering a few dozen rows at a time) and far below a size that would
// make one call's own tree traversal unbounded.
const maxClaimantsPageSize = 100

// ClaimantsPage is the paginated enumerator claims needed to be genuinely publicly
// readable, not just publicly readable one known address at a time. It returns up to
// limit claim keys (each claimKey(address, book), i.e. "<address>:<book>") in the claims
// tree's own stable order, starting at offset -- the same (key, value) order
// claims.IterateByOffset itself walks, which never changes for a fixed tree.
//
// limit is CLAMPED to maxClaimantsPageSize rather than rejected outright, so a caller that
// asks for too much still gets a gas-bounded page back instead of an aborted call; offset
// and limit are otherwise rejected if non-positive/negative, since those are caller
// mistakes with no sane page to return.
//
// Paging with offset 0, then offset+len(returned page), ... until a page shorter than its
// own requested limit comes back, covers every claimant exactly once, in this stable
// order, with no duplicates and no gaps, for any snapshot where claims does not grow
// between calls -- see hollowmere_test.gno's own paging test, which proves this directly
// rather than assuming it from the underlying avl.Tree's own doc comment.
func ClaimantsPage(offset, limit int) []string {
	if offset < 0 {
		panic("hollowmere: offset must not be negative")
	}
	if limit <= 0 {
		panic("hollowmere: limit must be positive")
	}
	if limit > maxClaimantsPageSize {
		limit = maxClaimantsPageSize
	}

	keys := make([]string, 0, limit)
	claims.IterateByOffset(offset, limit, func(key string, value any) bool {
		keys = append(keys, key)
		return false
	})
	return keys
}

// Render gives each player a public page on gno.land. Path validated with
// address(path).IsValid() before anything derived from it is echoed back -- the same
// guard garden/v2's own Render uses, and for the same reason: an invalid path must get a
// generic refusal, never a page built out of attacker-controlled text.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf(
			"# Hollowmere: Book One claims ledger\n\n"+
				"This page records what players **claim** to have cleared, timestamped by the "+
				"chain when they claimed it -- not what gno.land has verified. The chapters run "+
				"in the browser, so this realm has no way to check that any chapter was actually "+
				"played; see the package doc for why that is an honest trade, not an oversight.\n\n"+
				"* **Addresses with at least one chapter claimed**: %d\n",
			totalClaimants,
		)
	}

	addr := address(path)
	if !addr.IsValid() {
		return "# Hollowmere: Book One claims ledger\n\nNo claim for an invalid address.\n"
	}

	highest, c1, c2, c3, c4, seeds, found := BookOneClaim(addr)
	if !found {
		return ufmt.Sprintf("# Hollowmere: Book One claims ledger\n\nNo chapter claimed cleared yet for `%s`.\n", addr.String())
	}

	str := ufmt.Sprintf("# Hollowmere: Book One -- %s's claimed progress\n\n", addr.String())
	str += "This is a **claim**, timestamped by the chain when this wallet signed it -- not a verified record of play. See the package doc.\n\n"
	str += ufmt.Sprintf("* **Chapters claimed cleared**: %d of %d\n", highest, numChaptersBookOne)
	str += chapterLine(1, c1)
	str += chapterLine(2, c2)
	str += chapterLine(3, c3)
	str += chapterLine(4, c4)
	str += ufmt.Sprintf("* **Ember Seeds** (derived from chapters 1-3 claimed cleared; never claimable directly): %d\n", seeds)
	return str
}

func chapterLine(chapter, claimedAt int64) string {
	if claimedAt == 0 {
		return ufmt.Sprintf("* **Chapter %d**: not yet claimed\n", chapter)
	}
	return ufmt.Sprintf("* **Chapter %d**: claimed cleared at %d\n", chapter, claimedAt)
}
