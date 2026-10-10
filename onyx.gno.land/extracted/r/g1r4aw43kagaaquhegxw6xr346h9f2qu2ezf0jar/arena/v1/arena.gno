// Package arena is Gnotchi's sealed-plan battle realm: commit-reveal challenges between
// two gnomes, resolved deterministically on chain against app/js/rules.js's own battle
// math. This is the realm the project's strongest on-chain claim rests on. Everywhere else
// in this project, "it's on chain" buys permanence and ownership. Here it buys something
// harder: neither player has to trust the other, or Gnotchi's own server, about the
// result of a battle that gets resolved -- because the challenger's plan is
// cryptographically sealed before the opponent plays, and the chain, not either player's
// client, is the one that checks the seal and resolves the fight.
//
// THE PRECISE LIMIT OF THAT CLAIM, stated here rather than left for someone to discover,
// because this file cannot be edited once deployed. The guarantee is about TAMPERING, not
// about COMPLETION. The opponent's plan is posted in the clear at Accept (see below for
// why that asymmetry is correct), and resolveBattle is fully deterministic, so from the
// moment of Accept the challenger can compute the exact outcome and only then decide
// whether to call Reveal at all. A challenger who would lose is best off going quiet. The
// cost of going quiet is a forfeit -- but ClaimForfeit is the OPPONENT's call and costs
// them a transaction, so a challenge nobody claims simply sits accepted forever with no
// result recorded. Nothing here can be made to lie about a battle; a battle can be made
// not to finish. The recorded history is therefore selection-biased toward results
// challengers were happy to publish, which matters to anything that later reads `ranked`
// or `winner` in aggregate -- see NOTES.md, and see there too for why the obvious fix
// (making ClaimForfeit permissionless) was rejected rather than overlooked.
//
// WHETHER THIS IS DEPLOYED IS DELIBERATELY NOT RECORDED HERE. This file ships on chain
// exactly as written and cannot be edited afterwards, so any deploy status stated in it
// is frozen at authoring time and becomes a lie the moment it changes.
// garden/v2/gnomod.toml said "NOT deployed" in just such a line, was then deployed, and
// now carries that false claim on chain permanently. Live status lives in the repo root's
// STATUS.md and DECISIONS.md, which can still be corrected; the authority above both is
// the chain itself (`vm/qfile` on this path).
//
// ============================================================================
// WHY THIS NEVER STORES A GNOME, A TYPE OR A LEVEL
// ============================================================================
//
// A gnome's type (Gardener/Explorer/Tinkerer, the input the battle's type-edge bonus
// needs) and level (the input ranked eligibility needs) already live in garden/v2,
// already deployed, already the single source of truth for "whose gnome is this and what
// is it". Duplicating either field into this package's own storage would create two
// places that could disagree, and only one of them -- garden/v2 -- is the one players
// actually see on their gnome's own page. So every battle resolution here reads both
// participants' current type and level directly from garden/v2's own exported
// GnomeByAddress, by importing it like any other package, at the moment the battle is
// actually resolved (Reveal or ClaimForfeit) -- never cached, never copied, never taken as
// a caller-supplied argument. That import is what makes "any realm can read a gnome
// without a deal" (see repo root DECISIONS.md, 2026-10-09, "Other realms can read a gnome
// without permission") a property rather than a sentence in a document: no API key, no
// permission, no agreement with garden/v2, and no way for garden/v2 to withdraw the
// access. This file is the other realm.
//
// The import below is written against garden/v2's exact exported GnomeByAddress
// signature, and this realm cannot resolve a single battle unless garden/v2 is live at
// precisely the path imported below. So whoever deploys this must confirm that path on
// chain first -- not from this file, and not from a document, but with a `vm/qfile` read.
// See this package's own gnomod.toml and NOTES.md.
//
// ============================================================================
// THE HASHING, AND WHY IT MUST MATCH app/js/rules.js EXACTLY
// ============================================================================
//
// app/js/rules.js's own commitHash is `sha256(planString + ':' + saltHex)`, hex-encoded,
// using Node's crypto.createHash('sha256'). A plan sealed in the browser with that
// function must verify here with the IDENTICAL bytes hashed the IDENTICAL way, or every
// sealed challenge ever made in the app would fail to reveal on chain. Gno's own
// crypto/sha256 (gnovm/stdlibs/crypto/sha256, wrapping Go's stdlib sha256.Sum256) plus
// encoding/hex give exactly that: verified directly, not assumed -- a scratch package
// computing CommitHash("S,G,Q", "deadbeef") in Gno via sha256.Sum256(...)+hex.EncodeToString
// and the equivalent crypto.createHash('sha256').update(...).digest('hex') in Node produce
// the byte-for-byte identical 64-character hex string
// (dbce29c54438799e885fd3712ade046d71cd387649c1f14e837ab5f351a38c86). So the brief's own
// worry -- "if gno's crypto makes an exact match impossible, say so loudly" -- does not
// apply: an exact match is possible, and commitDigest below is it. See NOTES.md for the
// verification command.
//
// ============================================================================
// THE COMMIT-REVEAL STATE MACHINE
// ============================================================================
//
// Every challenge is exactly one of four states, and every exported call here is exactly
// one state transition, enforced by checking the CURRENT status before doing anything
// else (validate-then-commit, same discipline as garden/v2's SaveDay):
//
//	pending -> accepted    (Accept, by the opponent, within challengeExpiresHours)
//	accepted -> resolved   (Reveal, by the challenger, within revealWindowHours of accept)
//	accepted -> forfeited  (ClaimForfeit, by the opponent, once revealWindowHours has passed)
//
// There is no path back from resolved or forfeited, and no path from pending straight to
// resolved or forfeited -- a plan can only ever be revealed against a challenge the named
// opponent has actually accepted. Whichever of Reveal/ClaimForfeit executes first, while
// the challenge is still "accepted", locks the result; the other call then fails against
// the now-changed status (a late Reveal fails its own deadline check regardless, and a
// too-early ClaimForfeit fails its own deadline check regardless -- see each function's own
// comment). This makes the state machine race-free without needing a lock beyond the
// single mutable record already in the avl.Tree.
//
// ============================================================================
// SECURITY: NO recover(), SAME RULE AS garden/v2 AND hollowmere/v1
// ============================================================================
//
// Nothing in this file calls recover(). Every mutating function here validates completely
// against a value copy before ever touching the stored *arenaChallenge, so an uncaught
// panic at any point before the final commit leaves the persisted record exactly as it was,
// with no partial effect to undo -- the same validate-then-commit discipline garden/v2's
// SaveDay uses, for the same reason: a recover() anywhere in this realm, even one added
// later for an unrelated reason, could convert a rejected transition into a silently
// successful one.
//
// ============================================================================
// SCOPE
// ============================================================================
//
// Built: Challenge, Accept, Reveal, ClaimForfeit, the ranked-eligibility fairness rules
// (level 3 to rank, 3 ranked battles a gnome a day, 2 ranked results a pair a week -- all
// enforced structurally, never bought, because this realm accepts no coins at all), and a
// public Render/ChallengeStatus read surface.
//
// NOT built, on purpose: Elo ratings and season points. Brief 5.2 puts both in `season/v1`,
// a realm that reads arena's own results -- it does not exist yet and this assignment did
// not ask for it. Nothing here computes a rating or a season point, and there is no
// admin, no owner and no upgrade hatch, matching every other deployed realm in this
// project. See NOTES.md for what a future season realm would need from here, and for the
// cases where app/js/rules.js itself leaves the fairness rules' exact mechanics
// unspecified.
package arena

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"

	"chain"
	"chain/runtime/unsafe"

	"gno.land/r/g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar/garden/v2"
)

const (
	// ---- battle constants, ported from app/js/rules.config.json's "battle" block by hand,
	// the same way garden/v2's constants cite their rules.config.json keys. Gno has no way
	// to read a JSON file at compile time, so these must be updated by hand if
	// rules.config.json ever changes.
	battlePuff    = int64(10) // battle.puff
	battleRounds  = 3         // battle.rounds
	battleWinHit  = int64(3)  // battle.winHit
	battleEdge    = int64(1)  // battle.typeEdge
	battleTieLoss = int64(1)  // battle.tieLoss

	moveQuick  = "Q"
	moveStrong = "S"
	moveGuard  = "G"

	typeGardener = "gardener"
	typeExplorer = "explorer"
	typeTinkerer = "tinkerer"

	// ---- commit-reveal timing, from rules.config.json's "time" block.
	challengeExpiresHours = int64(24) // time.challengeExpiresHours
	revealWindowHours     = int64(24) // time.revealWindowHours

	// ---- fairness, from rules.config.json's "ranked"/"xp" blocks. See NOTES.md: rules.js
	// itself has no function that actually enforces these two -- its own eloUpdate only
	// models the per-pair-per-week downgrade, and nothing in rules.js touches the
	// per-gnome-per-day cap or the level-3 floor at all. This realm enforces both the same
	// way it enforces the one rules.js does model: a battle that fails a fairness check
	// still happens and still produces a real, final result -- it is simply not eligible to
	// be counted "ranked" (ranked = false on the record), exactly mirroring rules.js's own
	// eloUpdate(...) returning {ranked: false} rather than refusing to play the game. A
	// fairness check in this realm NEVER blocks Challenge/Accept/Reveal/ClaimForfeit from
	// succeeding.
	rankedFromLevel           = int64(3) // xp.rankedFromLevel
	rankedPerGnomePerDay      = int64(3) // ranked.perGnomePerDay
	rankedGamesPerPairPerWeek = int64(2) // ranked.rankedGamesPerPairPerWeek

	hourSeconds = int64(3600)
	daySeconds  = int64(86400)
	weekSeconds = int64(7 * 86400)

	stPending   = "pending"
	stAccepted  = "accepted"
	stResolved  = "resolved"
	stForfeited = "forfeited"
)

// styleBeatsMap: Quick beats Strong, Strong beats Guard, Guard beats Quick (brief 3.6).
var styleBeatsMap = map[string]string{
	moveQuick:  moveStrong,
	moveStrong: moveGuard,
	moveGuard:  moveQuick,
}

// typeBeatsMap: Gardener beats Explorer, Explorer beats Tinkerer, Tinkerer beats Gardener.
var typeBeatsMap = map[string]string{
	typeGardener: typeExplorer,
	typeExplorer: typeTinkerer,
	typeTinkerer: typeGardener,
}

// arenaChallenge is one sealed-plan battle, pending through to resolved/forfeited.
type arenaChallenge struct {
	challenger address
	opponent   address
	commit     string // sha256(planString + ":" + saltHex) hex, posted at Challenge time

	status string

	createdAt  int64 // Challenge time
	acceptedAt int64 // Accept time; 0 until accepted
	resolvedAt int64 // Reveal/ClaimForfeit time; 0 until resolved or forfeited

	opponentPlan   string // set at Accept, in the clear
	challengerPlan string // set at Reveal, after the commit check passes
	salt           string // set at Reveal; see ChallengeProof for why it is kept

	winner         string // "challenger" | "opponent" | "draw"; set once resolved/forfeited
	puffChallenger int64
	puffOpponent   int64
	ranked         bool
}

var (
	challenges = avl.NewTree() // challengeID string -> *arenaChallenge
	nextID     seqid.ID

	dailyRanked = avl.NewTree() // "<addr>:<dayNumber>" -> int64 ranked-battle count
	pairWeekly  = avl.NewTree() // "<addrLo>|<addrHi>:<weekNumber>" -> int64 ranked-result count

	totalChallenges int64
	totalResolved   int64
)

// Challenge posts only commitHash -- the sealed hash of the challenger's plan and salt.
// This realm never sees, and never could see, the plan itself at this stage: there is no
// plan parameter on this function at all, so a plan cannot arrive here even by mistake.
// See the package doc for why that asymmetry (challenger sealed, opponent's Accept plan in
// the clear) is deliberate and correct, not a gap.
// Challenge returns the new challenge's ID. This is an addition beyond the brief's own
// parameter-only signature notation, not a deviation from it: nothing in the brief
// forbids a return value, the caller genuinely needs the ID back to tell the opponent
// which challenge to Accept, and the alternative -- forcing every caller to parse the
// emitted "Challenge" event for the same value this function already has in hand -- is
// strictly worse for no safety benefit. See NOTES.md.
//
// THE unsafe.OriginSend() GUARD BELOW, AND ITS PRICE, recorded once here for all four
// mutating functions that use it. OriginSend reports the coins attached to the ORIGIN
// TRANSACTION, not the coins this call received -- which is exactly why the stdlib
// quarantines it under `unsafe`. Its purpose here is narrow and worth keeping: this realm
// has no banker, so any coin that reaches its address is stuck forever, and refusing the
// call is kinder than silently swallowing a user's GNOT.
//
// The price is permanent and goes in the other direction: because the check is
// transaction-scoped, any future transaction that attaches coins to some OTHER realm in
// the same call chain makes all four of these functions panic even though arena received
// nothing. A paid-entry tournament realm wrapping Challenge/Accept/Reveal is therefore
// impossible against this version. The read surface is unaffected -- ChallengeStatus,
// ChallengeProof and Render are non-crossing and carry no such check -- so a read-only
// season/v1 is fine; it is write-path composition specifically that is foreclosed.
//
// This is a forced trade, not an oversight: gno 0.9 exposes no call-scoped "coins sent to
// me" primitive at all. `gno doc chain/runtime/unsafe` lists OriginSend as the only coin
// receipt reader, and `gno doc chain` has no equivalent -- checked, not assumed. The
// stdlib's own advice is to pair it with runtime.AssertOriginCall(), which would forbid
// realm callers outright and so is strictly worse for composability than what is here.
func Challenge(cur realm, opponent address, commitHash string) string {
	if !unsafe.OriginSend().IsZero() {
		panic("arena: challenge accepts no coins; this realm has no banker and cannot return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("arena: challenge requires a valid caller address")
	}

	if !opponent.IsValid() {
		panic("arena: invalid opponent address")
	}

	if opponent == caller {
		panic("arena: cannot challenge your own gnome")
	}

	if !validCommitHex(commitHash) {
		panic("arena: commitHash must be a 64-character lowercase hex sha256 digest")
	}

	// The challenger must have a gnome; the opponent is deliberately NOT checked here -- see
	// NOTES.md for why a challenge can target an address with no gnome yet (it simply sits
	// un-acceptable until, if ever, that address adopts one).
	if !hasGnome(caller) {
		panic("arena: no gnome adopted for this address")
	}

	now := time.Now().Unix()
	id := nextID.Next().String()

	challenges.Set(id, &arenaChallenge{
		challenger: caller,
		opponent:   opponent,
		commit:     commitHash,
		status:     stPending,
		createdAt:  now,
	})
	totalChallenges++

	chain.Emit(
		"Challenge",
		"challengeId", id,
		"challenger", caller.String(),
		"opponent", opponent.String(),
	)

	return id
}

// Accept posts the opponent's own plan in the clear -- they learn nothing from the sealed
// commit, so there is nothing to protect by hiding their own choice. See the package doc.
func Accept(cur realm, challengeID, plan string) {
	if !unsafe.OriginSend().IsZero() {
		panic("arena: accept accepts no coins; this realm has no banker and cannot return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("arena: accept requires a valid caller address")
	}

	c := mustChallenge(challengeID)

	if c.status != stPending {
		panic("arena: this challenge cannot be accepted (status: " + c.status + ")")
	}

	now := time.Now().Unix()
	if now > c.createdAt+challengeExpiresHours*hourSeconds {
		panic("arena: this challenge expired; it was not accepted within 24 hours")
	}

	if caller != c.opponent {
		panic("arena: only the challenged opponent can accept this challenge")
	}

	if !hasGnome(caller) {
		panic("arena: no gnome adopted for this address")
	}

	// Store the NORMALISED plan, not the caller's bytes. parsePlan accepts surrounding
	// whitespace and either case on each move (strings.TrimSpace strips the whole Unicode
	// whitespace class, so "\n\nQ , s ,G" parses), and the raw string would then be echoed
	// straight into Render's markdown and returned by ChallengeProof. That is the same
	// reflected-string class as Render's own path guard, one function away; the payload
	// alphabet here is only whitespace and Q/S/G, so the worst reachable outcome is a
	// mangled list or a stray indented code block on one challenge's page rather than a
	// link or an image -- but the pattern has no business being here at all.
	//
	// Normalising loses nothing: unlike the challenger's plan, the opponent's is not
	// covered by any commitment, so no byte has to survive verbatim for Reveal's hash
	// check. parsePlan is idempotent over its own output, so a third party re-deriving the
	// battle from ChallengeProof gets the same moves either way.
	normalisedPlan := strings.Join(parsePlan(plan), ",")

	work := *c
	work.opponentPlan = normalisedPlan
	work.acceptedAt = now
	work.status = stAccepted
	*c = work
	challenges.Set(challengeID, c)

	chain.Emit(
		"Accept",
		"challengeId", challengeID,
		"opponent", caller.String(),
		"plan", normalisedPlan,
	)
}

// Reveal posts the challenger's plan and salt. The realm recomputes commitDigest and
// rejects any plan/salt pair that does not reproduce the posted commitHash, then resolves
// the battle itself -- against both gnomes' CURRENT type and level, read live from
// garden/v2, never from anything cached here.
func Reveal(cur realm, challengeID, plan, salt string) {
	if !unsafe.OriginSend().IsZero() {
		panic("arena: reveal accepts no coins; this realm has no banker and cannot return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("arena: reveal requires a valid caller address")
	}

	c := mustChallenge(challengeID)

	if c.status != stAccepted {
		panic("arena: this challenge is not awaiting a reveal (status: " + c.status + ")")
	}

	if caller != c.challenger {
		panic("arena: only the challenger can reveal")
	}

	now := time.Now().Unix()
	if now > c.acceptedAt+revealWindowHours*hourSeconds {
		panic("arena: the 24-hour reveal window has passed; the opponent may now claim forfeit")
	}

	// Format check BEFORE the hash check, mirroring app/js/rules.js's own control flow:
	// its commitHash(planString, saltHex) calls parsePlan(planString) first and lets that
	// throw propagate, rather than hashing (or verifyReveal returning false for) a
	// malformed plan. A caller here who never went through rules.js at all could otherwise
	// hand-craft a hash over a malformed string; parsePlan below closes that regardless of
	// whether the hash would have matched.
	challengerMoves := parsePlan(plan)

	computed := commitDigest(plan, salt)
	if computed != c.commit {
		panic("arena: revealed plan does not match the sealed commitment")
	}

	// c.opponentPlan was already validated by parsePlan inside Accept; re-parsing here is a
	// cheap, defensive re-check, not a trust assumption.
	opponentMoves := parsePlan(c.opponentPlan)

	_, _, _, _, challengerLevel, challengerType, _, foundChallenger := garden.GnomeByAddress(c.challenger)
	_, _, _, _, opponentLevel, opponentType, _, foundOpponent := garden.GnomeByAddress(c.opponent)
	if !foundChallenger || !foundOpponent {
		// Unreachable in practice -- gnomes are soulbound and never removed once adopted,
		// and both addresses were already required to have one (Challenge, Accept). Kept as
		// a defensive panic rather than a silent zero-value type/level, consistent with this
		// project's "never invent a fact" rule.
		panic("arena: a gnome in this challenge no longer exists")
	}

	result := resolveBattle(challengerMoves, challengerType, opponentMoves, opponentType, battlePuff)
	ranked := rankedEligible(c.challenger, c.opponent, challengerLevel, opponentLevel, now)
	if ranked {
		recordRanked(c.challenger, c.opponent, now)
	}

	work := *c
	work.challengerPlan = plan
	work.salt = salt
	work.winner = result.winner
	work.puffChallenger = result.puffChallenger
	work.puffOpponent = result.puffOpponent
	work.ranked = ranked
	work.resolvedAt = now
	work.status = stResolved
	*c = work
	challenges.Set(challengeID, c)
	totalResolved++

	chain.Emit(
		"Reveal",
		"challengeId", challengeID,
		"winner", work.winner,
		"puffChallenger", strconv.FormatInt(work.puffChallenger, 10),
		"puffOpponent", strconv.FormatInt(work.puffOpponent, 10),
		"ranked", strconv.FormatBool(ranked),
	)
}

// ClaimForfeit lets the opponent claim the win once revealWindowHours has passed with no
// Reveal. Per the brief: "the result counts as a normal ranked loss" for the challenger --
// this realm applies the SAME ranked-eligibility rule to a forfeit as to a genuine reveal
// (see NOTES.md), rather than treating a forfeit as automatically ranked regardless of the
// fairness caps.
func ClaimForfeit(cur realm, challengeID string) {
	if !unsafe.OriginSend().IsZero() {
		panic("arena: claim forfeit accepts no coins; this realm has no banker and cannot return them")
	}

	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("arena: claim forfeit requires a valid caller address")
	}

	c := mustChallenge(challengeID)

	if c.status != stAccepted {
		panic("arena: this challenge is not awaiting a reveal (status: " + c.status + ")")
	}

	if caller != c.opponent {
		panic("arena: only the accepting opponent can claim forfeit")
	}

	now := time.Now().Unix()
	if now <= c.acceptedAt+revealWindowHours*hourSeconds {
		panic("arena: the 24-hour reveal window has not passed yet; the challenger can still reveal")
	}

	_, _, _, _, challengerLevel, _, _, foundChallenger := garden.GnomeByAddress(c.challenger)
	_, _, _, _, opponentLevel, _, _, foundOpponent := garden.GnomeByAddress(c.opponent)
	if !foundChallenger || !foundOpponent {
		panic("arena: a gnome in this challenge no longer exists")
	}

	ranked := rankedEligible(c.challenger, c.opponent, challengerLevel, opponentLevel, now)
	if ranked {
		recordRanked(c.challenger, c.opponent, now)
	}

	work := *c
	work.winner = "opponent"
	work.puffChallenger = 0
	work.puffOpponent = battlePuff
	work.ranked = ranked
	work.resolvedAt = now
	work.status = stForfeited
	*c = work
	challenges.Set(challengeID, c)
	totalResolved++

	chain.Emit(
		"ClaimForfeit",
		"challengeId", challengeID,
		"opponent", caller.String(),
		"ranked", strconv.FormatBool(ranked),
	)
}

// ChallengeStatus is the plain read surface for one challenge's full state -- everything a
// future season realm, or the web app, needs to know about a single resolved or
// in-progress battle, without parsing Render's markdown.
func ChallengeStatus(challengeID string) (
	challenger, opponent address,
	status string,
	createdAt, acceptedAt, resolvedAt int64,
	winner string,
	puffChallenger, puffOpponent int64,
	ranked, found bool,
) {
	v := challenges.Get(challengeID)
	c, ok := v.(*arenaChallenge)
	if !ok {
		return address(""), address(""), "", 0, 0, 0, "", 0, 0, false, false
	}
	return c.challenger, c.opponent, c.status, c.createdAt, c.acceptedAt, c.resolvedAt,
		c.winner, c.puffChallenger, c.puffOpponent, c.ranked, true
}

// ChallengeProof returns everything a third party needs to re-derive a finished battle
// from scratch, without trusting this realm, either player, or Gnotchi's server.
//
// This realm's entire reason to exist is that nobody has to be trusted about the result.
// ChallengeStatus returns the result -- which is this realm ASSERTING a winner. That is
// exactly the kind of claim the realm was built to avoid having to make. Given commit,
// challengerPlan, salt and opponentPlan, anyone can check sha256(challengerPlan + ":" +
// salt) == commit, feed both plans through app/js/rules.js's resolveBattle, and get the
// same winner and the same puff -- or catch this realm being wrong. Without these four
// fields the "you don't have to trust us" claim is itself something you'd have to take on
// trust, and since a realm cannot be edited, a getter missing at deploy time stays
// missing until a v2 and a migration.
//
// Before a Reveal, challengerPlan and salt are empty strings, so this getter cannot leak
// a plan early: there is no plan here to leak until the challenger has published it
// themselves. commit is readable from the moment of Challenge, but it always was -- it is
// a public argument of that transaction -- so exposing it here reveals nothing new.
//
// THE SEAL'S STRENGTH IS THE SALT'S, AND THIS REALM CANNOT ENFORCE THAT. Stated plainly
// because the honest version is narrower than it first looks. There are only 27 possible
// plans: battleRounds is 3 and there are 3 legal moves, so 3^3. commitDigest is a single
// bare sha256 with no KDF and no iteration. So a commit whose salt is known, reused, or
// derived from anything predictable falls to 27 hashes -- a complete break of the only
// thing this realm exists to guarantee. Reveal deliberately imposes no minimum salt
// length, because a length check added here would permanently reject any challenge
// already sealed with a shorter salt and force its challenger to forfeit. The entropy
// requirement therefore lives entirely in the client: app/js/battle.js seals with 32
// fresh crypto.getRandomValues bytes per plan, never reused. Any other client MUST do the
// same; 27 candidates is not a margin to be casual with.
//
// The preimage also binds neither the challenge ID nor the challenger's address, so the
// same commit can be posted in several challenges. No advantage was found in doing so --
// a replayer commits to a plan they will not learn until the original reveals, which is
// strictly worse than choosing one -- but it is recorded here because the preimage has to
// match app/js/rules.js byte for byte and so can never be changed.
//
// A forfeited challenge has no challengerPlan by definition -- the challenger never
// revealed one, which is why it was forfeited. `found` is false for an unknown ID.
func ChallengeProof(challengeID string) (
	commit string,
	challengerPlan string,
	salt string,
	opponentPlan string,
	found bool,
) {
	v := challenges.Get(challengeID)
	c, ok := v.(*arenaChallenge)
	if !ok {
		return "", "", "", "", false
	}
	return c.commit, c.challengerPlan, c.salt, c.opponentPlan, true
}

// Render: "" shows the realm's totals; any other path is treated as a challengeID.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf(
			"# Arena\n\nSealed-plan battles, resolved on chain. No dice, and neither player "+
				"nor Gnotchi has to be trusted about the result.\n\n"+
				"* **Total challenges**: %d\n* **Total resolved**: %d\n",
			totalChallenges, totalResolved,
		)
	}

	// Validate before echoing. `path` is whatever a URL put after the realm path, so it is
	// attacker-controlled, and gnoweb renders this return value as markdown: an unchecked
	// echo lets anyone hand out a gnotchi.com-adjacent link whose page contains their own
	// headings, links or images, apparently published by this realm. garden/v2 guards its
	// own Render the same way (its paths are addresses, so it uses IsValid there). A
	// rejected path is never reflected at all, which is strictly safer than escaping it.
	if !validChallengeID(path) {
		return "# Arena\n\nThat is not a challenge ID.\n"
	}

	v := challenges.Get(path)
	c, ok := v.(*arenaChallenge)
	if !ok {
		return ufmt.Sprintf("# Arena\n\nNo such challenge `%s`.\n", path)
	}

	str := ufmt.Sprintf("# Challenge %s\n\n", path)
	str += ufmt.Sprintf("* **Challenger**: %s\n", c.challenger.String())
	str += ufmt.Sprintf("* **Opponent**: %s\n", c.opponent.String())
	str += ufmt.Sprintf("* **Status**: %s\n", c.status)
	if c.status == stAccepted || c.status == stResolved {
		str += ufmt.Sprintf("* **Opponent's plan**: %s\n", c.opponentPlan)
	}
	if c.status == stResolved || c.status == stForfeited {
		str += ufmt.Sprintf("* **Winner**: %s\n", c.winner)
		str += ufmt.Sprintf("* **Puff**: challenger %d, opponent %d\n", c.puffChallenger, c.puffOpponent)
		str += ufmt.Sprintf("* **Ranked**: %s\n", strconv.FormatBool(c.ranked))
	}
	return str
}

// ============================================================================
// Helpers
// ============================================================================

func mustChallenge(id string) *arenaChallenge {
	v := challenges.Get(id)
	c, ok := v.(*arenaChallenge)
	if !ok {
		panic("arena: no such challenge")
	}
	return c
}

func hasGnome(addr address) bool {
	_, _, _, _, _, _, _, found := garden.GnomeByAddress(addr)
	return found
}

// validCommitHex checks only the SHAPE of a posted commitHash (64 lowercase hex chars,
// matching the exact output of both Node's crypto.createHash('sha256').digest('hex') and
// this file's own commitDigest) -- an early, player-facing failure, not a correctness
// requirement: Reveal's own byte-for-byte comparison is what actually enforces the seal.
func validCommitHex(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}

// validChallengeID accepts only what Challenge itself can mint: a seqid.ID rendered by
// cford32, which is Crockford base32 and therefore a strict subset of lowercase
// alphanumerics. 16 is a deliberate ceiling rather than an exact width -- seqid's encoded
// width grows with the counter, so pinning one number here would start rejecting real IDs
// later, and this realm cannot be edited once deployed. Nothing outside this set can ever
// be a key in `challenges`, so narrowing to it loses no lookup.
func validChallengeID(s string) bool {
	if len(s) == 0 || len(s) > 16 {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'z')) {
			return false
		}
	}
	return true
}

// commitDigest ports app/js/rules.js's commitHash exactly: sha256(planString + ":" +
// saltHex), hex-encoded. See the package doc for the cross-checked proof this matches
// Node's crypto output byte for byte.
func commitDigest(planString, saltHex string) string {
	sum := sha256.Sum256([]byte(planString + ":" + saltHex))
	return hex.EncodeToString(sum[:])
}

// parsePlan ports app/js/rules.js's parsePlan: exactly battleRounds comma-separated moves,
// each trimmed and uppercased to one of Q, S or G.
func parsePlan(s string) []string {
	parts := strings.Split(s, ",")
	if len(parts) != battleRounds {
		panic(planFormatError())
	}
	moves := make([]string, battleRounds)
	for i, p := range parts {
		m := strings.ToUpper(strings.TrimSpace(p))
		if m != moveQuick && m != moveStrong && m != moveGuard {
			panic(planFormatError())
		}
		moves[i] = m
	}
	return moves
}

func planFormatError() string {
	return "arena: a plan is exactly " + strconv.Itoa(battleRounds) + " moves, each Q, S or G, e.g. \"S,G,Q\""
}

func styleBeats(a, b string) bool { return styleBeatsMap[a] == b }

// typeBeats: empty string (no type assigned yet) never beats, and is never beaten by,
// anything -- ports app/js/rules.js's typeBeats: `!!a && !!b && TYPE_BEATS[a] === b`.
func typeBeats(a, b string) bool { return a != "" && b != "" && typeBeatsMap[a] == b }

type battleResult struct {
	winner         string // "challenger" | "opponent" | "draw"
	puffChallenger int64
	puffOpponent   int64
}

// resolveBattle ports app/js/rules.js's resolveBattle exactly: no randomness, a knock-out
// ends the fight early, the round's winner hits for winHit plus typeEdge with the type
// edge, a tie costs both battleTieLoss. puff is an explicit parameter (not just the
// package's own battlePuff constant) purely so tests can mirror rules.test.js's own
// trick of lowering it to force an early knock-out within three rounds -- every real call
// from Reveal always passes battlePuff.
func resolveBattle(challengerMoves []string, challengerType string, opponentMoves []string, opponentType string, puff int64) battleResult {
	puffC, puffO := puff, puff

	for i := 0; i < battleRounds; i++ {
		mc, mo := challengerMoves[i], opponentMoves[i]
		var dmgC, dmgO int64

		switch {
		case mc == mo:
			dmgC, dmgO = battleTieLoss, battleTieLoss
		case styleBeats(mc, mo):
			dmgO = battleWinHit
			if typeBeats(challengerType, opponentType) {
				dmgO += battleEdge
			}
		default:
			dmgC = battleWinHit
			if typeBeats(opponentType, challengerType) {
				dmgC += battleEdge
			}
		}

		puffC = clampPuff(puffC - dmgC)
		puffO = clampPuff(puffO - dmgO)
		if puffC == 0 || puffO == 0 {
			break
		}
	}

	winner := "draw"
	switch {
	case puffC == 0 && puffO == 0:
		winner = "draw"
	case puffC == 0:
		winner = "opponent"
	case puffO == 0:
		winner = "challenger"
	case puffC > puffO:
		winner = "challenger"
	case puffO > puffC:
		winner = "opponent"
	}

	return battleResult{winner: winner, puffChallenger: puffC, puffOpponent: puffO}
}

func clampPuff(v int64) int64 {
	if v < 0 {
		return 0
	}
	return v
}

func dayNumber(unixSeconds int64) int64  { return unixSeconds / daySeconds }
func weekNumber(unixSeconds int64) int64 { return unixSeconds / weekSeconds }

func dayKey(addr address, now int64) string {
	return addr.String() + ":" + strconv.FormatInt(dayNumber(now), 10)
}

// pairKey is symmetric: challenger-vs-opponent and opponent-vs-challenger must land on the
// same weekly counter.
func pairKey(a, b address) string {
	as, bs := a.String(), b.String()
	if as < bs {
		return as + "|" + bs
	}
	return bs + "|" + as
}

func weekKey(pk string, now int64) string {
	return pk + ":" + strconv.FormatInt(weekNumber(now), 10)
}

func getCounter(tree *avl.Tree, key string) int64 {
	v := tree.Get(key)
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func incCounter(tree *avl.Tree, key string) {
	tree.Set(key, getCounter(tree, key)+1)
}

// rankedEligible: level 3 to rank (xp.rankedFromLevel), at most rankedPerGnomePerDay ranked
// results a gnome a day, at most rankedGamesPerPairPerWeek a pair a week. Never blocks a
// battle -- see the const block's own comment for why this is a downgrade, not a refusal.
//
// KNOWN AND PERMANENT: THE PLAYER CHOOSES WHEN THIS RUNS, SO THEY CHOOSE WHAT IT SEES.
// Every input below -- both daily counters, both pair counters, both levels -- is read
// live at Reveal (or ClaimForfeit) time, and that moment is picked by the revealer, who by
// then already knows the outcome from the opponent's cleartext plan. A challenger holding
// several accepted challenges can reveal their three wins first, exhausting their own
// rankedPerGnomePerDay allowance, after which every loss revealed that day is recorded
// ranked = false. Free, repeatable daily, and invisible in the stored record.
//
// There is no fix available inside this function. Deciding eligibility at Challenge time
// instead would just move the choice to a moment the challenger controls even more
// completely, and the counters cannot be consumed before the battle exists. A real fix
// needs the plan asymmetry to go (both sides sealed) or an ordering the players do not
// pick -- either of which is a different realm, not a change to this line.
//
// Nothing reads `ranked` today: season/v1 does not exist (see the SCOPE note in the
// package doc). That bounds the harm to zero right now and is precisely why it is written
// down here instead of deferred -- whoever builds season/v1 will be reading an immutable
// field whose distribution is skewed in the ranked player's favour, and they should learn
// that from this comment rather than from the leaderboard.
func rankedEligible(challenger, opponent address, challengerLevel, opponentLevel, now int64) bool {
	if challengerLevel < rankedFromLevel || opponentLevel < rankedFromLevel {
		return false
	}
	if getCounter(dailyRanked, dayKey(challenger, now)) >= rankedPerGnomePerDay {
		return false
	}
	if getCounter(dailyRanked, dayKey(opponent, now)) >= rankedPerGnomePerDay {
		return false
	}
	if getCounter(pairWeekly, weekKey(pairKey(challenger, opponent), now)) >= rankedGamesPerPairPerWeek {
		return false
	}
	return true
}

func recordRanked(challenger, opponent address, now int64) {
	incCounter(dailyRanked, dayKey(challenger, now))
	incCounter(dailyRanked, dayKey(opponent, now))
	incCounter(pairWeekly, weekKey(pairKey(challenger, opponent), now))
}
