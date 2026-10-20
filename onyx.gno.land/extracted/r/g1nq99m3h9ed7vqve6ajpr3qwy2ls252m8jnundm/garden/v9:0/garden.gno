// Package garden is Gnotchi's pet realm, v7: the free, allowlisted, drand-rolled, hold-many
// realm MINT.md designs end to end, now carrying Batch One's personality, the kinship web and a
// batch of sixty. It inherits garden/v4's machinery -- the SaveDay shape, meters, garden plots,
// levels, and the List/Buy/Cancel trading surface -- but NOT v4's invariants (MINT.md section 6).
// garden/v4 is live, immutable and untouched by this file; its two gnomes stay exactly where
// they are forever (MINT.md section 6, BATCH-ONE.md section 0), and so does garden/v5's one.
//
// ============================================================================================
// WHAT v7 IS: v6 PLUS EXACTLY TEN CHANGES. READ THIS, THEN "WHAT v6 IS" BELOW IT.
// ============================================================================================
//
// v7's specification is realms/garden/v7/DESIGN.md (1,974 lines, written 2026-10-17 and
// reviewed before any of this was typed). This block is the summary; that document is the
// argument, and where this file disagreed with it the disagreement is marked in the source at
// the place it happens.
//
// THE RULE THIS FILE IS WRITTEN UNDER, which is v6's own rule quoted back at its successor:
// "Every line of v5 that is not one of the two fixes below is carried forward byte-for-byte...
// v5 survived a security audit; every unrelated change made here would be a change that has not
// been audited, so none was made." v7 is the version that was reserved for changing things, so
// the door is open -- but THE AUDIT ARGUMENT DOES NOT EVAPORATE BECAUSE THE DOOR IS OPEN.
// Everything v6 carries forward is carried forward here too, byte-for-byte, unless it appears in
// the list below. The list is complete. If a change is not in it, it is not authorised, and the
// three defects mutation testing found in v5, along with every comment recording why something
// is shaped as it is, are all still here on purpose.
//
// CHANGE 1 -- batchCap 24 -> 60. DECISIONS.md 2026-10-17, "Batch One becomes 60", superseding
// "Batch One stays 24" from earlier the same day. ONE CONSTANT.
//
// CHANGE 2 -- FIVE ROLLED TRAIT AXES plus born-under, stored on the gnome. TRAITS.md sections 1
// and 7.
//
// CHANGE 3 -- THE DOMINANCE ORDER, stored as five explicit slots rather than a 7-bit Lehmer
// index. The reason is in the gnome struct's own comment: a factorial-base index needs a codec
// on both sides of the wire, which is two things that must agree forever over a convention
// nobody has written down, in the one function MINT.md section 9 names as needing its own audit
// pass above all others.
//
// CHANGE 4 -- THE FOUR STATS on a shared budget, drawn from a 546-row legal set ENUMERATED AT
// init() FROM THE RULE rather than transcribed, because a transcription error in a 546-row table
// is undetectable by eye and the rule it transcribes is four comparisons. TRAITS.md section 4.2.
//
// CHANGE 5 -- A SECRET ID, with the first-seventeen-distinct constraint. TRAITS.md section
// 3.2.2: without it, 36.9% of batches could not spell the acrostic of section 3.2.1.
//
// CHANGE 6 -- A ROLLED CARE THRESHOLD, stored, WITH NO GETTER. The one declared exception to
// GAMES.md:38, and the only write-only field in the realm.
//
// CHANGE 7 -- THE 84 KINSHIP EDGES on chain, STRUCTURE ONLY, keyed by batch index. LINEAGE.md
// section 6's OVERRULED box: "store the structure, keep the wording off chain where it can still
// be improved."
//
// CHANGE 8 -- seedFor MOVES FROM FNV-1a TO SHA-256. NOT A FEATURE -- a defect DESIGN.md found
// while working out change 3. FNV-1a's low bits are provably a parity of the input bytes' low
// bits; v5 and v6 take % 100, % 60 and % 4 and mostly get away with it, and v7 takes % 2, % 3,
// % 5 and % 16 for the one field TRAITS.md's whole duplicate-vector argument rests on. THIS IS
// THE ONE TO READ FIRST IN REVIEW: it rewrites a line an audited realm carries. Proof at
// seedFor.
//
// CHANGE 9 -- THE NAMED-EDITION ODDS ARE DECOUPLED FROM THE BATCH SIZE AND RAISED TEN-FOLD.
// 2026-10-18, the owner: "make the last few have them. The rates have to come out during a mint."
// ONE CONSTANT AND ONE LINE: namedPick's modulus was uint64(batchCap), so each of Hob, Thistle and
// Wick was a 1-in-60 shot per claimant and there was a 74.37% chance at least one of the three
// never existed. It is now uint64(namedPickRange), its own constant at 10 -- a 1-in-10 shot each,
// leaving 0.54% of full batches missing one. NOTHING ELSE ABOUT THE NAMED-EDITION PATH MOVES: the
// `namedPick < numNamedEditions` branch, the characterOwner.Has check and the
// transaction-ordering-race comment inside it are v6's byte-for-byte. THIS IS NOT A GUARANTEE and
// is not a replacement for the removed one; it is a probability, it fires nowhere new, and it reads
// nothing new. The arithmetic for all three rates, why the modulus is NOT batchCap (that coupling
// was accidental -- it made the rarest-asset odds a side effect of a batch size changed for
// unrelated reasons), why raising a rate is safe where the removed guarantee was not, and the
// honest cost (collisions become common; first settle wins) are at namedPickRange's declaration.
//
// CHANGE 10 -- THE NAMED ONE-OF-ONES GO FROM THREE TO EIGHT. 2026-10-18, the owner: "If we are
// doing 60 there should be more specials than 3." He is right, and the reason is arithmetic that
// change 1 produced silently: three of 24 was 12.5% of a batch, and moving the batch to 60 without
// touching the roster quietly cut it to 5%. EIGHT OF 60 IS 13.3%, which restores the proportion the
// collection was designed at. ONE CONSTANT (numNamedEditions 3 -> 8) AND THREE TABLES IN STEP
// (namedEditionOrder, namedEditionDisplayNames, reservedNameKeys) -- plus List's lock message,
// which says the count out loud and is therefore a FOURTH place the roster's size appears; see
// numNamedEditions for the full list of what must move together.
//
// THE FIVE NEW NAMES ARE BATCH-ONE.md section 7's, EXTENDED IN THAT SECTION'S OWN REGISTER AND
// JUSTIFIED THERE, NOT HERE: Tally, Glim, Vigil, Spruce, Yonder. They are EXISTING, ALREADY
// VALIDATED ART, renamed exactly the way Hob (the gilded gnome) and Thistle (the Viking) were --
// trowel-hand, emberwing, nightwatch, gentleman and pirate from pack/04-pixel-art/characters.json,
// every one of them "works"/"confirmed at true 2x" in ARCHETYPES.md section 3 and section 6. NO NEW
// ART WAS DRAWN OR MODIFIED FOR THIS CHANGE and this realm does not know what any of them look
// like: `character` is a string, the look lives in the art pack, and that separation is unchanged.
//
// namedPickRange STAYS AT 10, DELIBERATELY, AT THE OWNER'S APPROVED ODDS -- a specific edition is
// still a 1-in-10 shot per claimant and nothing about the pick, the branch or the race moves. What
// DOES move is what the odds compose to, and the new figures replace the old ones everywhere they
// are written down: (9/10)^60 = 0.18% per edition is unchanged, but P(at least one of EIGHT
// missing) = 1 - (1-0.0017971)^8 = 1.43%, up from 0.54% at three. A half-filled batch of 30 is
// 29.3%. The cost side moves much further: 48 of 60 claimants now hold a named-pointing pick
// (60 * 8/10) for eight slots, so about 40 of them lose the race and fall through to an ordinary
// draw. Full arithmetic, all four rows, at namedPickRange. NOTE THE HEADROOM: 10 >= 8 still holds,
// but only just -- at eight editions the modulus is two residues from the point where an edition
// becomes unreachable, so numNamedEditions may not grow again without raising namedPickRange, and
// TestNamedEditionOddsAreOneInTen is the test that fails if it does.
//
// NOT A GUARANTEE, AGAIN AND FOR THE SAME REASONS: this adds five entries to three tables and no
// mechanism. No forcing, no namedEditionToForce, nothing keyed on a shrinking observable (AUDIT-01
// RED-1). "TALLY WAS NEVER BORN" is now a 0.18% permanent fact per edition exactly as "HOB WAS
// NEVER BORN" is, and the chance that SOME edition is missing went UP, not down, because there are
// more editions to miss. That is the accepted price of the proportion the owner asked for.
//
// NOT A CHANGE -- THE NAMED-EDITION GUARANTEE, WRITTEN 2026-10-17 AND REMOVED 2026-10-18. It was
// briefly a change of its own: "when the number of unsettled slots remaining equals the number of
// named editions still unclaimed, the remaining settles take them." AUDIT-01 RED-1 found that
// rule positionable -- its trigger was computable from two public readers and a wallet that never
// claimed until 57 were settled took an edition with certainty -- and the owner chose REMOVAL over
// any replacement, so the named-edition path here is v6's byte-for-byte apart from change 9's one
// modulus, and NO END-OF-BATCH FORCING AND NO namedEditionToForce EXISTS OR MAY BE RE-ADDED. The
// residual chance that at least one edition is never minted is KNOWN AND ACCEPTED: 74.4% when
// it was accepted, 0.54% after change 9, 1.43% after change 10 raised the roster from three to
// eight (more editions, more chances for one of them to be missed), never zero. The full record of
// the decision is in settleCore, next to the pick it would have overridden; do not re-add a
// guarantee without reading it, and note that changes 9 and 10 are deliberately NOT one -- between
// them they move two numbers and five table entries, not a mechanism.
//
// WHAT v7 MUST NEVER DO, and these are named so that leaving them out is a decision on the
// record rather than an omission. From TRAITS.md section 7: no rarityScore(), no TraitCensus(),
// no traitCount(axis, id), no sort-by-stat, no trait-gated entrypoint anywhere in any realm,
// nothing that returns a distribution. From LINEAGE.md section 6.5: no KinOf(tokenID), no
// IsKin(a, b), no LineOf(tokenID), no LineCount(line), no KinCount and nothing that returns a
// degree, no sort/filter/gate of any kind on a line, a relation or a relative, and NO ENTRYPOINT
// ANYWHERE IN ANY REALM THAT BEHAVES DIFFERENTLY FOR TWO RELATED GNOMES THAN FOR TWO STRANGERS.
// Added by v7, because it is the first realm where they become reachable: no CareThreshold /
// CareScore / Band / PointsToThreshold or any fraction of them; no SecretCount / SecretCensus /
// HoldersOfSecret / IsFirstSeventeen and nothing exposing secretsDrawnMask; no Label / Archetype;
// no TraitsMatching or any filter or predicate; no unique-in-batch marker; AND NO READER,
// ANYWHERE, THAT TAKES TWO TOKEN IDS -- that last one is the structural form of all of it,
// because a function of two gnomes is the shape every kin-bonus, related-pair and shared-quest
// feature needs. See the shape rule stated once above the trait readers.
//
// THE INVARIANT THOSE PROTECT, STATED ONCE: NO FUNCTION IN v7 BRANCHES ON A TRAIT, A STAT, A
// LINEAGE EDGE OR A SECRET. Not in a guard, not in a loop condition, not in a fee calculation,
// not in an eligibility check. Trait data is read by this realm's own code in exactly two
// places, and both are inside the draw writing itself down: drawRoll/assertRoll, and
// secretWeightsFor's one comparison of boast/fear against the secret target table, which
// produces a secret id and nothing else. TestTwoGnomesWithOppositeTraitsAreTreatedIdentically is
// that invariant as a test a CI run can check rather than a promise a reviewer has to take.
//
// THE MIGRATION QUESTION, ANSWERED ONCE SO NOBODY RE-OPENS IT: v5's one gnome STAYS ON v5 and
// v4's two stay on v4. No migration, ever -- the identical answer BATCH-ONE.md section 0 gave
// one version earlier, for the identical reason: v5 is immutable, has no transfer-in path, and
// nothing in v7 can reach it. BATCH ONE IS THE SIXTY GNOMES ON THIS REALM AND NOTHING ELSE; the
// 60 is sixty, not fifty-nine plus the one already minted. v5's gnome holds no axis, no
// dominance order, no stat line, no secret, no sign, no threshold, no batch index and no kinship
// edge -- not because anything was withheld but because V5 HAS NO SUCH FIELDS, so it cannot be a
// member of a batch whose defining properties did not exist when it was minted. Nothing in this
// file knows v5 exists: not a field, not an import. No cross-realm per-wallet cap (MINT.md
// section 6 already settles it -- "a single wallet may hold a v4 gnome and any number of v5
// gnomes at once" -- and importing v5 would make v7 undeployable anywhere v5 is not live), no
// batch-index offset, no legacy-holder benefit (if the owner wants the v5 holder on the v7
// allowlist, that is one AdminAllow call and a curation decision), no cross-realm name
// uniqueness (impossible, and already true between v4 and v5), no cumulative TotalSupply, and no
// deprecation pointer in v5 (it is immutable). THE ONLY THING v7 INHERITS THAT IS NOT SOURCE
// CODE IS THE NAMESPACE.
//
// AND ONE FACT THAT CHANGES THE SHAPE OF THIS VERSION: v7 SUPERSEDES A REALM THAT NEVER CAME UP.
// garden/v6 is written, audited, passing its tests and NOT ON CHAIN -- vm/qpkgmeta_json answers
// "status":"inert", three paid addpkg attempts produced nothing retrievable, and a five-line
// probe realm with no imports failed identically, which is what proves it is the chain and not
// the code (TESTNET.md:530-582). So v6's two fixes have never been live for anybody: SetName and
// SettledRound arrive for the first time here, and section 1.1's "byte-for-byte" is a claim about
// SOURCE, not about continuity of service. Before attempting to deploy this larger realm, re-run
// the five-line probe first -- and remember the lesson that file draws: "OK! from gnokey,
// success:true in the block, and a debited balance are together still not evidence that a deploy
// happened. Only reading the package back is."
//
// ============================================================================================
// WHAT v6 IS: v5 PLUS EXACTLY TWO FIXES, AND NOTHING ELSE. READ THIS SECOND, AND READ IT WHOLE.
// IT IS THE RECORD OF THE AUDITED BASE THIS FILE IS A COPY OF, AND EVERY WORD OF IT STILL
// APPLIES EXCEPT WHERE THE TEN CHANGES ABOVE SAY OTHERWISE.
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
//     named one-of-ones (Hob, Thistle, Wick, Tally, Glim, Vigil, Spruce, Yonder -- BATCH-ONE.md
//     section 7; three until v7 change 10 made it eight) capped at one each.
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
//   - THE LOCK: the eight named one-of-ones cannot be listed until they have lockCaredDays
//     cared days; every ordinary gnome trades from day one (MINT.md section 12/13, "Option A" --
//     lock only the named one-of-ones). SETTLED 2026-10-19 AT 14, down from that section's
//     unconfirmed recommendation of 30; reasoning at lockCaredDays itself. It is still one named
//     constant and nothing else in this file assumes its value -- verified by AUDIT-03, which
//     also confirms maxListingDays' own 30 was never coupled to it.
//     A gnome's own caredDayCount never decreases and is not reset by Buy, so once
//     a named gnome unlocks it stays unlocked through every future sale.
//   - A GENESIS GNOME, minted to this realm's own address at deploy, non-transferable, never
//     listable, separate from the 60-gnome batch (DECISIONS.md 2026-10-15: "the genesis gnome
//     belongs to nobody, permanently, on purpose"). ITS NAME IS SPRIG, settled 2026-10-19 --
//     see genesisGnomeName below for why, and note it is load-bearing in FOUR places, not one:
//     the constant, reservedNameKeys, the gnome's own `character` slug, and characterOwner.
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
//     60-gnome batch (BATCH-ONE.md, at DECISIONS.md 2026-10-17's size) and does not ask for a
//     mechanism to open a second one. The
//     batch here is sized once, at deploy, by the batchCap/numNamedEditions constants below. A
//     FUTURE VERSION is the natural place for OpenBatch if a second batch is ever wanted, the
//     same way every other irreversible-shape decision in this project has gotten its own
//     version rather than a retrofit. (v5 said "a garden/v6 is the natural place"; v6 exists
//     now and deliberately did NOT take that opportunity -- it is two fixes and nothing else.)
//
// A REAL FLAW FOUND AND FIXED WHILE DESIGNING Settle, RECORDED HERE RATHER THAN QUIETLY FIXED
// AND FORGOTTEN -- the same discipline MINT.md section 10 models for its own single-transaction
// finding. An earlier version of this design picked the named one-of-ones by drawing
// "without replacement" from a shrinking pool: remainingTotal = batchCap - settledCount,
// remainingNamed = 3 - namedAssignedCount, and a claimant's pick = seed % remainingTotal. THAT
// IS PEEKABLE AND GAMEABLE, even though the seed itself is honestly drand-derived and
// unforgeable: because remainingTotal only ever shrinks as OTHER claimants settle, and Settle is
// permissionless and callable at any later time, a claimant whose seed is already fixed (the
// moment their pinned round publishes) can simply precompute, for every possible remainingTotal
// from 1 to batchCap, whether that value would win them a named edition -- and then wait,
// costing nothing, until the rest of the batch happens to settle into a state that does. The fix
// below removes every dependency on shrinking, observable, time-varying state from the decision:
// a claimant's own named-edition pick is `seed % namedPickRange` (`seed % batchCap` until v7
// change 9 moved the modulus off the batch size on 2026-10-18 -- a different constant, the same
// and only load-bearing property), against a modulus that is a
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
// handful of claimants happen to collide -- WRITTEN BEFORE CHANGES 1, 9 AND 10, and "low
// probability" and "a handful" are the two words that stopped being true; see the paragraph
// below), the same shape of race every permissionless action on
// every chain is already subject to, not a new hole this design opened. See Settle's own comment
// for the arithmetic. v7 CHANGES 9 AND 10 (both 2026-10-18) MAKE THAT RACE MORE FREQUENT AND SAY
// SO: at namedPickRange = 10 roughly 18 of 60 claimants held a named-pointing pick for three slots,
// and at change 10's eight slots it is 48 of 60 (60 * 8/10) chasing eight, so collisions are now
// the NORMAL CASE rather than an unlucky one -- about 40 claimants draw a named pick and fall
// through to an ordinary draw. The race is unchanged in SHAPE -- first settle takes it, nobody can
// move his own pick -- and it rewards promptness, not lateness. The honest statement of that cost,
// and the reason the rate was raised anyway, are at namedPickRange.
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
	"crypto/sha256" // v7 change 8: seedFor's hash. See seedFor and the "WHY FNV-1a HAD TO GO" block.
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

	// maxKinEdgesPageSize: v7, the same shape and the same number as the two above, for
	// KinEdgesPage. The whole table is 84 rows, so one page of 100 returns all of it -- the
	// cap exists to keep the enumerator's shape identical to its two siblings rather than
	// because 84 needs bounding.
	maxKinEdgesPageSize = 100

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

	// batchCap: BATCH-ONE.md's own roster, AT THE SIZE DECISIONS.md SETTLED ON 2026-10-17
	// ("Batch One becomes 60", superseding "Batch One stays 24" from earlier the same day) --
	// 60 gnomes, total, forever, this batch. 52 ordinary plus eight named one-of-ones
	// (numNamedEditions below -- three until v7 change 10, which is also the change that
	// explains why the split is worth writing out: three of 24 was 12.5% of a batch and three of
	// 60 was 5%, so change 1 moved this number and silently moved a rarity nobody was discussing.
	// Eight of 60 is 13.3%). Closed the instant mintedCount reaches this; nothing in this file
	// can ever raise it (no OpenBatch -- see the package doc's "out of scope" section).
	//
	// THIS IS v7 CHANGE 1 AND IT IS ONE CONSTANT. Everything that reads it -- Claim's cap gate,
	// BatchStatus's third return, the kinship table's 1..60 key space and OwnerTokens' unpaginated
	// bound -- reads it from here and nothing in this file hardcodes 24 or 60 beside it. THE
	// NAMED-EDITION PICK NO LONGER READS IT (v7 change 9, 2026-10-18): its modulus is
	// namedPickRange, so changing the batch size no longer silently changes the odds on any
	// edition. See namedPickRange for why that coupling was accidental and had to go. THE ROSTER
	// SIZE IS STILL NOT INDEPENDENT OF THIS NUMBER AS A DESIGN QUESTION, though -- change 10 is
	// the record of batchCap moving and numNamedEditions needing to follow it by hand, which is a
	// judgement about what fraction of a batch should be special, not a coupling in the code.
	batchCap = int64(60)

	// numNamedEditions: THE SIZE OF THE NAMED ROSTER, AND v7 CHANGE 10 (2026-10-18). Hob, Thistle,
	// Wick, Tally, Glim, Vigil, Spruce and Yonder (namedEditionOrder below), cap ONE EACH. "Cap 1"
	// is not a different mechanism from any other cap, MINT.md section 3's own point -- it is the
	// same characterOwner.Has check any other population cap would use, just at the number one.
	//
	// THREE UNTIL 2026-10-18, when the owner said "If we are doing 60 there should be more
	// specials than 3." The arithmetic behind him: three of 24 was 12.5% of the batch, and v7
	// change 1 took the batch to 60 without touching the roster, which cut it to 5% as a side
	// effect of a decision about batch size. Eight of 60 is 13.3% -- the proportion restored, not
	// a new one invented. The five new entries are EXISTING, ALREADY VALIDATED ART renamed, exactly
	// as Hob (the gilded gnome) and Thistle (the Viking) were; BATCH-ONE.md section 7 names each
	// one, says which character it is and justifies the name. No art was drawn for change 10.
	//
	// EDITING THIS NUMBER IS FOUR EDITS, NOT ONE, AND THE FOURTH IS THE ONE A REVIEWER MISSES.
	// Three are the tables that must stay the same length and in the same order:
	// namedEditionOrder, namedEditionDisplayNames and reservedNameKeys (which is
	// [numNamedEditions + 1] -- the extra slot is the genesis gnome). The FOURTH IS PROSE THAT
	// SAYS THE COUNT OUT LOUD IN A PANIC MESSAGE: List refuses an early sale with "... is one of
	// the eight named one-of-ones and cannot be listed until ...", and the test suite's lockedMsg
	// helper mirrors that string byte-for-byte, so the count appears in two more places than the
	// tables. gnomod.toml item (4) names the roster as well and is a build input, not source.
	// TestReservedNamesCoverEveryNamedEdition and TestNamedEditionDisplayNamesPairWithTheirCanonicalKeys
	// pin the tables against each other and against BATCH-ONE.md's own spelling.
	//
	// AND THIS NUMBER MAY NOT GROW AGAIN WITHOUT RAISING namedPickRange: the pick is
	// `seed % namedPickRange` and an edition at an index >= namedPickRange can never be drawn at
	// all. 10 >= 8 holds with two residues of headroom; at eleven editions an edition would be
	// unmintable and the realm immutable. TestNamedEditionOddsAreOneInTen asserts the inequality
	// directly so that mistake fails a test rather than shipping.
	numNamedEditions = 8

	// namedPickRange: THE MODULUS OF THE NAMED-EDITION PICK, AND v7 CHANGE 9 (2026-10-18).
	// settleCore draws namedPick = seedFor(round, claimant, "slot") % namedPickRange and takes the
	// edition at that index when the result is under numNamedEditions -- so every claimant has a
	// 1-in-10 shot at each specific one of the eight editions. The owner's instruction, in his
	// words: "make the last few have them. The rates have to come out during a mint." He wants all
	// of them to actually exist.
	//
	// THIS CONSTANT DID NOT MOVE IN v7 CHANGE 10 AND MUST NOT: change 10 raised the ROSTER from
	// three to eight at these same owner-approved odds. A specific edition is a 1-in-10 shot now
	// exactly as it was at three, because the odds on a specific edition are what this constant
	// controls and the roster size is what numNamedEditions controls. What the two compose to did
	// move, and the table below is recomputed for eight rather than edited in place.
	//
	// THE ARITHMETIC, REPRODUCED RATHER THAN QUOTED, because this constant exists for nothing
	// except what it does to these numbers. Each claimant draws independently, so for one specific
	// edition P(never drawn by n claimants) = (1 - 1/namedPickRange)^n, and P(at least one of the
	// k editions absent) = 1 - (1 - that)^k, at k = numNamedEditions = 8:
	//
	//                                   miss one specific       at least one of eight missing
	//   1-in-60 (v5/v6), 60 claimants   (59/60)^60 = 36.48%     1 - (1-0.36479)^8 = 97.35%
	//   1-in-10,         60 claimants   (9/10)^60  =  0.18%     1 - (1-0.0017971)^8 =  1.43%
	//   1-in-10,         35 claimants   (9/10)^35  =  2.50%     1 - (1-0.0250316)^8 = 18.36%
	//   1-in-10,         30 claimants   (9/10)^30  =  4.24%     1 - (1-0.0423911)^8 = 29.29%
	//
	// AT THREE EDITIONS THE SAME TWO MIDDLE ROWS WERE 0.54% AND 7.32%; the per-edition column is
	// identical and only the composition changed, which is the whole shape of change 10. Expected
	// number of the eight that actually mint in a full batch is 8 * (1 - (9/10)^60) = 7.986.
	//
	// The last two rows are there because a batch that does not sell out is the realistic bad case,
	// and the fourth row is the one to quote at anybody planning the allowlist: A BATCH THAT ONLY
	// HALF FILLS (30 of 60 claimed) LOSES AN EDITION ALMOST THREE TIMES IN TEN. That is the price
	// of eight rather than three and it is not small. It is still better than a FULL batch was at
	// 1-in-60 under either roster size. TestNamedEditionOddsAreOneInTen pins the rate against the
	// realm's own seedFor, and TestNamedEditionsAtSixtyAreNotGuaranteed pins the residual 1.43%.
	//
	// WHY THIS IS NOT batchCap, which is what the modulus was until 2026-10-18 and the only reason
	// the odds were ever 1-in-60. THAT COUPLING WAS ACCIDENTAL: batchCap was reached for because it
	// was the handy compile-time constant to hand, and it made the rarest-asset rate a side effect
	// of a batch size decided for entirely unrelated reasons -- 24, then 60 (DECISIONS.md
	// 2026-10-17), each change silently moving odds nobody was discussing. The two numbers answer
	// different questions: batchCap is HOW MANY GNOMES EXIST, namedPickRange is HOW LIKELY A NAMED
	// EDITION IS, and numNamedEditions is HOW MANY THERE ARE TO BE LUCKY ABOUT. A future batch of
	// 200 must not quietly make Hob a 1-in-200 shot, so the modulus is its own constant and moving
	// any one of the three leaves the others alone -- v7 change 10 is the proof that this
	// separation was worth having: the roster tripled in size and this line did not move. What was
	// load-bearing about batchCap -- and the only thing this must inherit from it -- is that the
	// modulus is a COMPILE-TIME CONSTANT and not a count of what remains; see the package doc's "a
	// real flaw found and fixed" section for why that distinction is the whole safety property. Any
	// value here must be >= numNamedEditions or an edition becomes unreachable (10 >= 8, which was
	// 10 >= 3 before change 10 and now has only two residues of slack -- a NINTH edition would be
	// fine, an ELEVENTH would be permanently unmintable), and TestNamedEditionOddsAreOneInTen
	// checks that too.
	//
	// WHY RAISING THE RATE IS SAFE WHERE THE REMOVED GUARANTEE WAS NOT, which is the reason this
	// change is a constant rather than a mechanism. A claimant's namedPick is a PURE FUNCTION of
	// the pinned drand round and his own address -- fixed before he can act and unchangeable by
	// anything he does. WAITING DOES NOT HELP, RUSHING DOES NOT HELP, WATCHING THE COUNTERS DOES
	// NOT HELP: THERE IS NOTHING TO POSITION FOR. The forcing rule removed by AUDIT-01 RED-1 fired
	// on a SHRINKING PUBLIC OBSERVABLE (slotsLeft = batchCap - settledCount, computable from
	// BatchStatus and CharacterOwner), and that is exactly what made it positionable -- a wallet
	// that simply never claimed until 57 were settled took an edition with certainty. This keys on
	// nothing observable at all: 60 -> 10 changes a probability and introduces no new input, no new
	// state, no new branch and no new reader.
	//
	// AND THE COST, STATED HONESTLY BECAUSE IT IS REAL, AND CHANGE 10 MAKES IT MUCH BIGGER. At
	// 1-in-10 with three editions, roughly 18 of 60 claimants (60 * 3/10) held a pick pointing at a
	// named edition and only three could have one. AT EIGHT EDITIONS IT IS 48 OF 60 (60 * 8/10) --
	// four claimants in five draw a named-pointing pick, eight of them can keep it, and ABOUT FORTY
	// LOSE THE RACE and fall through to an ordinary draw. Among claimants whose picks collide,
	// WHOEVER SETTLES FIRST TAKES IT: v5's and v6's already-documented transaction-ordering race,
	// in the same place and under the same comment, byte-for-byte unchanged -- but it is now the
	// NORMAL EXPERIENCE OF A CLAIMANT rather than an unlucky edge case. It rewards PROMPTNESS
	// rather than lateness, which is the healthy direction and the exact opposite of what the
	// removed rule did. And because the draw is public arithmetic over public inputs, a claimant
	// CAN WORK OUT AFTER THE FACT that he was in line for Hob and lost the race -- and after change
	// 10, forty claimants per batch can. Accepted twice, with eyes open: the alternative on offer
	// at change 9 was a 74% chance that one of three pieces of commissioned art was never minted at
	// all, and the alternative at change 10 was leaving five finished, validated characters
	// (ARCHETYPES.md section 3's own Legendary line) unminted while the batch grew around them.
	//
	// THIS IS STILL NOT A GUARANTEE, and the source must not start reading as though it were.
	// ~1.43% of full batches, ~18.4% of 35-gnome batches and ~29.3% of half-filled 30-gnome
	// batches miss at least one of the eight.
	namedPickRange = 10

	// lockCaredDays: the eight named one-of-ones cannot be listed until they have this many cared
	// days; every ordinary gnome trades from day one. One named constant, and nothing else in this
	// file assumes any particular value.
	//
	// SETTLED 2026-10-19 AT 14, DOWN FROM 30. MINT.md section 12/13's thirty was explicitly a
	// RECOMMENDATION -- "Option A... this is a recommendation, not a decision" -- and sat unconfirmed
	// through v5, v6 and most of v7. The owner delegated it ("ok whatever you think") after being
	// asked three times.
	//
	// WHY 14 AND NOT 30. The lock exists so a one-of-one cannot be flipped the hour it is minted;
	// it does not exist to make the holder prove devotion. Thirty DISTINCT cared days before an
	// asset becomes usable is a month of attendance, and the realistic outcome of that is not a
	// more committed holder but an abandoned gnome and a dead listing -- the care ledger already
	// measures attention, and the resale lock is a speed bump, not a second measure of it.
	//
	// SAID PRECISELY, because the first draft of this comment said "unbroken attendance" and that
	// is a mechanism this realm does not have (AUDIT-03 GREEN-4): the lock counts TOTAL distinct
	// cared days, not consecutive ones, so no streak has to be unbroken and a missed day costs a
	// day rather than a restart. The floor is still 14 calendar days, because recordCaredDay banks
	// at most one distinct UTC day at a time -- and lastCaredDayForOwner means an owner holding
	// several gnomes must spend each of those days on THIS one.
	// Fourteen is still long enough that flipping is not a strategy and short enough that somebody
	// who wants out can get out inside a fortnight.
	//
	// NOT ZERO, and not "let the market decide": the eight are the scarcest things in the realm and
	// a mint-and-flip on day one is exactly the behaviour BATCH-ONE.md's hand-read waitlist exists
	// to keep out.
	//
	// TestTheSellLockIsFourteenCaredDays pins the number itself, because the two behavioural tests
	// around List are both written relative to this constant and therefore pass at ANY value --
	// verified by mutation on 2026-10-19: setting it to 99 broke nothing.
	lockCaredDays = int64(14)

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

// ============================================================================
// v7 CHANGES 2, 3, 4, 5 AND 6: THE TRAIT TABLES. TRAITS.md sections 1, 2.2, 3.2, 3.3, 4.2, 5.1.
// Ids on chain, NAMES OFF CHAIN -- the precedent v6 already set for parts (EyesCount(4) returns
// a number; nothing on chain says what eye type 4 looks like), applied to all of this. The
// thirty-two public names, the seventeen secret names, the eight signs and the two label-word
// columns all stay in TRAITS.md where FUNNY.md can still revise them weekly. A realm cannot be
// edited, and revisable wording is the one thing that must never go on one.
// ============================================================================

const (
	// numAxes: the FIVE rolled axes, in the order the dominance permutation indexes them --
	// 0 temperament, 1 obsession, 2 bond, 3 fear, 4 boast. Born-under is NOT one of them
	// (TRAITS.md section 1.6: "not in the trait vector, not in the dominance order, not in the
	// label rule"), which is why bornUnder has no slot in `dominance` and can therefore never be
	// loud, never be latent, and never appear in the label -- by construction, not by discipline.
	numAxes = 5

	// axisTotalWeight: all six weight tables below sum to exactly this. TRAITS.md section 1's
	// whole point and the direct answer to BATCH-ONE.md:120 -- a 64-wide cumulative table has NO
	// REMAINDER TO GET WRONG, and 64 divides 2^64 so the draw carries exactly zero modulo bias.
	// TestEveryAxisTableSumsToSixtyFour pins all six, the way v6's own
	// TestWeightTablesSumToOneHundred pins its two.
	axisTotalWeight = int64(64)

	// numSecrets: TRAITS.md section 3.2's pool, after the owner's 2026-10-17 cut to seventeen.
	// SEVENTEEN IS NOT A TUNING PARAMETER; IT IS A PRECONDITION of the first-seventeen probe in
	// secretFor -- 17 is PRIME, so every stride in 1..16 is coprime to it and the probe walk
	// visits all seventeen ids exactly once. An eighteen-secret pool would let a stride share a
	// factor with the modulus, so the walk could cycle without reaching a free id, turning an
	// unreachable panic into a reachable one that aborts a claimant's one and only roll.
	// TestSecretPoolSizeIsPrime says exactly that.
	numSecrets = 17

	// firstDistinctCount: TRAITS.md section 3.2.2, agreed by the owner 2026-10-17. "The first
	// seventeen mints draw seventeen distinct secrets... From token 18 onward the draw is the
	// full seventeen with duplicates free." It is load-bearing and not a nicety: on a pure draw,
	// P(at least one secret missing from a batch of 60) = 36.9%, so more than one batch in three
	// could not spell the acrostic of section 3.2.1 -- the thing nobody is allowed to break.
	firstDistinctCount = int64(17)

	// careThresholdFloor / careThresholdSpan: TRAITS.md section 5.1's roll, threshold = 14 + u
	// with u a uniform 0-31 draw, range 14-45 inclusive and flat. v7 STORES u, NOT THE
	// THRESHOLD: they are the same five bits either way, and storing the draw keeps the +14 floor
	// in one named place instead of baked into sixty stored numbers, so a future batch's realm can
	// use a different floor without Batch One's stored values meaning something different.
	// 32 divides 256 and 2^64, so there is no modulo bias.
	careThresholdFloor = int64(14)
	careThresholdSpan  = int64(32)

	// The four Top Trumps stats, TRAITS.md section 4.2's budget: 22 points across four stats,
	// each 1-10, with at least one >= 8 and at least one <= 3. 670 four-tuples sum to 22; 546 of
	// them satisfy both constraints. See legalStatLines and init().
	numStats        = 4
	statPointTotal  = int64(22)
	statMin         = int64(1)
	statMax         = int64(10)
	statHighAtLeast = int64(8)
	statLowAtMost   = int64(3)

	// numBornUnder: TRAITS.md section 1.6's eight signs. Rolled, not derived -- section 1.6's own
	// recommendation and the only option open to this realm, because a derived sign is a function
	// of the adoption week and sixty gnomes settling inside one window would all derive the SAME
	// sign, which is not a clan system. The question stays live for Batch Two, where minting may
	// be spread across a year; deferring costs nothing, because a future batch's realm can derive
	// while Batch One's stays rolled and nobody's sign changes.
	numBornUnder = 8
)

// The six 64-wide weight tables, transcribed from TRAITS.md sections 1.1-1.6, each summing to
// exactly axisTotalWeight. Entry order is FROZEN the moment this realm deploys, exactly as
// numEyes/numNoses ordering already is -- an entry may be reweighted for a future batch; it may
// never be reordered, removed or renumbered, because the stored id is what pins each gnome to
// what he actually rolled.
var temperamentWeights = [6]int64{13, 11, 12, 10, 10, 8}  // section 1.1: Blithe, Grudgeful, Fretful, Insufferable, Theatrical, Stony
var obsessionWeights = [8]int64{12, 10, 9, 9, 7, 6, 6, 5} // section 1.2: Cheese, Fence, Book, Hat, Spade, Lantern, Carrot Row, Moss
var bondWeights = [6]int64{13, 12, 11, 10, 10, 8}         // section 1.3: Pibbs, Stone, Fennick, Middle Plot, Gran, Tin
var fearWeights = [6]int64{14, 12, 11, 10, 10, 7}         // section 1.4: Beetles, Being Forgotten, The Dark, Being Laughed At, Slugs, Shine
var boastWeights = [6]int64{12, 11, 11, 11, 10, 9}        // section 1.5: Badger, Oak, Wheel, Frost, Row, Mend
var bornUnderWeights = [8]int64{12, 10, 9, 9, 8, 6, 5, 5} // section 1.6: Carrot, Bramble, Acorn, Nettle, Clover, Toadflax, Ember, Thistle

// secretTargetKind / secretTargetID: TRAITS.md section 3.2's "Undercuts" column, AS IDS ONLY --
// the name and the line itself live off chain, where the register is still being revised
// (FUNNY.md). kind 0 means the secret undercuts a BOAST, 1 means a FEAR; the id is the axis id
// within that axis. Paired by index: secret i undercuts (secretTargetKind[i], secretTargetID[i]).
//
// TestSecretTargetsMatchTheAllocation pins the three facts section 3.2 states about this table
// and that LINEAGE.md section 3.3's arithmetic depends on: twelve secrets target a boast and
// five target a fear; EVERY ONE of the six boasts is the target of exactly two; and the fears
// are Beetles 2, Being Forgotten 1, Being Laughed At 1, Slugs 1, The Dark 0 and Shine 0. A
// transcription slip in either array would move LINEAGE.md section 3.3's per-edge 0.0489 and
// TRAITS.md section 3.3's population 61.7% without changing anything observable, which is
// exactly the kind of error that needs a test rather than an eye --
// TestSecretWeightingHitsSixtyOnePercent is the second, behavioural lock on the same door.
//
// A DECLARED CONSEQUENCE OF PUTTING THIS TABLE ON CHAIN, recorded here so the first person to
// notice finds the reasoning rather than reporting it: the two arrays publish, in this realm's
// own public source, which boast or fear each secret id undercuts, so an off-chain observer
// combining Secret/Boast/Fear can determine that a given gnome's secret targets his own boast.
// That is not a name, not a definition and not a rarity count, so it is inside TRAITS.md section
// 0 rule 2 -- and v6 already settles the precedent in the same direction, because eyesWeights is
// both "internal" per ECONOMY.md section 3 and published verbatim in v5's deployed source.
// "Internal" means NOT PRINTED ON A CARD, not absent from the source.
var secretTargetKind = [numSecrets]int64{1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1}
var secretTargetID = [numSecrets]int64{0, 0, 1, 2, 0, 5, 3, 1, 4, 2, 5, 3, 3, 1, 0, 4, 4}

const (
	// secretTargetKindBoast / secretTargetKindFear: the two values secretTargetKind holds, named
	// rather than written as 0 and 1 at the comparison site in secretWeightsFor.
	secretTargetKindBoast = int64(0)
	secretTargetKindFear  = int64(1)

	// secretMatchMultiplier: TRAITS.md section 3.3, "base weight 1 for all seventeen, multiply by
	// 8 if the secret's target matches the gnome's rolled boast or rolled fear". One multiplier,
	// one comparison, no second table. The dial was recomputed at seventeen secrets and x8 stayed
	// the recommendation: it puts 61.7% of gnomes on a secret that undercuts something they say
	// out loud, where x4 gives 44.9% and x16 gives 76.0%. The reason not to go higher is that a
	// system which ALWAYS punctures the boast is a system whose output you can predict from the
	// card.
	secretMatchMultiplier = int64(8)

	// secretBaseWeight: the other half of the same rule.
	secretBaseWeight = int64(1)
)

// legalStatLines: TRAITS.md section 4.2's 546 legal stat lines, ENUMERATED AT init() FROM THE
// RULE rather than transcribed as a literal table, and packed four stats to an int64. See
// buildLegalStatLines and init().
//
// WHY ENUMERATED AND NOT A 546-ROW LITERAL -- auditability, not bytes: a transcription error in a
// 546-row table is undetectable by eye, and the rule it transcribes is four comparisons.
// TestLegalStatLinesIsExactly546 pins the count, TestEveryLegalStatLineSumsToTwentyTwoAndIsSpiky
// pins the property of every row, and TestLegalStatLineOrderIsStable pins that the enumeration
// order is the one this realm deployed with -- because the draw indexes into it, so the order is
// frozen the moment v7 deploys, exactly as numEyes/numNoses ordering already is.
//
// WHY AT init() AND NOT INSIDE settleCore: 10,000 iterations once, at deploy, instead of on every
// claimant's one transaction. The named risk, recorded rather than hidden: v5's own deploy used
// 131.9M gas of a 160M --gas-wanted, which is not a comfortable margin, so MEASURE THIS BEFORE
// DEPLOYING (DESIGN.md section 3.6). If it does not fit, the cheap fallback is to build the table
// lazily on the first Settle, paid once by whoever settles first; that is not the default because
// it makes one arbitrary claimant pay for everybody and puts a conditional in settleCore.
var legalStatLines []int64

// namedEditionOrder: BATCH-ONE.md section 7's eight names, in the fixed order Settle's
// namedPick indexes into. The order carries no meaning -- it is not a ranking -- it only has to
// be fixed, which it is, forever, the moment this realm deploys.
//
// THE FIRST THREE ARE v5's AND v6's, IN v5's ORDER, AND THE FIVE ADDED BY v7 CHANGE 10 ARE
// APPENDED RATHER THAN INTERLEAVED. That is deliberate and it is the only thing about this
// ordering that is a decision: appending leaves hob/thistle/wick at indexes 0/1/2, so every
// worked example in this file's comments, in DESIGN.md and in the test suite that says "pick 0 is
// Hob" is still true, and the diff against v6 stays readable. Nothing reads this array by index
// except settleCore's own `namedEditionOrder[namedPick]`, which does not care.
var namedEditionOrder = [numNamedEditions]string{
	"hob", "thistle", "wick",
	"tally", "glim", "vigil", "spruce", "yonder",
}

// namedEditionDisplayNames: BATCH-ONE.md section 7's eight names AS THEY ARE WRITTEN -- "Hob,
// Thistle, Wick, Tally, Glim, Vigil, Spruce, Yonder", the form this file's own documentation uses
// throughout -- paired by index with namedEditionOrder above.
//
// WHY A SECOND ARRAY RATHER THAN JUST CAPITALISING namedEditionOrder, which is the change a
// reviewer will reach for first: namedEditionOrder's values are not labels, they are KEYS.
// settleCore writes characterOwner.Set(character, ...) and tests characterOwner.Has(candidate)
// with those exact strings, and the public CharacterOwner(name) reader does a raw tree Get with
// no case folding at all -- so CharacterOwner("hob") resolving is a chain fact that an
// off-chain caller already depends on, and init() registers the genesis gnome under the matching
// lowercase key "gaffer". Capitalising namedEditionOrder would move those keys to "Hob" while
// leaving "gaffer" lowercase, break CharacterOwner("hob") for every existing caller, and it is
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
var namedEditionDisplayNames = [numNamedEditions]string{
	"Hob", "Thistle", "Wick",
	"Tally", "Glim", "Vigil", "Spruce", "Yonder",
}

// namedEditionDisplayName maps a named edition's canonical character key to its display name.
// Used by settleCore's mint and mirrored by the test fabricator, so there is exactly one copy of
// the mapping. Returns the input unchanged for anything that is not one of the eight editions --
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
// address, non-transferable, never listable, separate from the batch) and until 2026-10-19 never
// settled a NAME anywhere in this project's documents -- "Genesis" was a placeholder that had
// been read as a decision for four days.
//
// SETTLED 2026-10-19 as SPRIG, and **RE-SETTLED 2026-10-20 as GAFFER**, which is what v8 is for.
//
// v7's argument for Sprig still reads well and was wrong on one axis it never checked: "it does
// not collide with any of the eight reserved names, any born-under sign, or any noun in LORE.md's
// fauna or flora." Every one of those tests is INTERNAL. None of them asks what the word already
// means to somebody outside this repository -- and `Sprig` is a funded product-research SaaS
// (formerly UserLeap), so to the startup and product audience this project is pitched at, the
// software reading arrives first. The owner caught it: *"I don't really care too much about the
// minted guys because obviously it's random. But I do care about the main guy."* He is right that
// the asymmetry matters. The sixty are drawn by a beacon and belong to whoever mints them; a name
// collision there is a private matter. THIS gnome fronts everything -- the group, the page, the
// reply to a stranger -- so his name is the only one that has to survive contact with the world.
//
// WHY GAFFER, and the test it passes that Sprig failed: eight candidates were searched on
// 2026-10-20 and all eight were already somebody's app (NAMES.md 3b). "Find an unused word" is
// not achievable, so the test is not "is it taken" but **"which meaning arrives first for our
// reader"**. For a British or Irish reader "the gaffer" is the old boy in charge, instantly, and
// the only software of that name is studio-niche VFX lighting. It also DESCRIBES him: the one
// gnome outside the batch, owned by nobody, who is the village rather than a villager. Runner-up
// was Pogle, whose sole namesake is Pogles' Wood (BBC, 1965) -- a clash so in-register it is
// closer to an ancestor. Sprig's own runner-up, Pip, was dropped for reading as a diminutive of
// somebody, and that reasoning still holds: this gnome is nobody's.
//
// NOT CHANGED, deliberately: `Spruce`, which collides with a decentralised-identity company that
// won an Ethereum Foundation grant and is therefore the only clash INSIDE this industry. It is one
// of the sixty, the owner said he does not care about those, and a realm is not a place to act on
// an unasked-for opinion. Recorded here because the next reader will wonder.
//
// CHANGED FROM v5 IN ONE RESPECT, deliberately: v5's comment ended "it is read by nothing else
// in this file", which was true there and is NOT true here. v6 fix 1 writes this string into the
// genesis gnome's own `name` field at init() and registers its canonical key in nameOwner, so
// changing it also changes which name is taken. It must still canonicalise to one of
// reservedNameKeys below, or an ordinary gnome could be named "Gaffer" and pose as it --
// TestGenesisNameIsReserved pins exactly that, so an edit here that breaks the pairing fails a
// test rather than shipping.
const genesisGnomeName = "Gaffer"

// reservedNameKeys: the canonical name keys NO ORDINARY GNOME MAY EVER TAKE -- the eight named
// one-of-ones (BATCH-ONE.md section 7's roster, re-read rather than assumed: Hob, Thistle, Wick,
// and v7 change 10's Tally, Glim, Vigil, Spruce, Yonder) plus the genesis gnome. Checked by
// SetName; see assertNameAssignable.
//
// THE ARRAY LENGTH IS [numNamedEditions + 1] AND THAT "+ 1" IS THE GENESIS GNOME, so adding a
// roster entry without adding its key here is a COMPILE ERROR rather than a silent hole -- which
// is the one piece of luck in change 10's four-places-in-step problem and the reason this file
// states the length arithmetically instead of writing 9.
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
var reservedNameKeys = [numNamedEditions + 1]string{
	"hob", "thistle", "wick",
	"tally", "glim", "vigil", "spruce", "yonder",
	"gaffer",
}

// ============================================================================
// v7 CHANGE 7: THE KINSHIP WEB, STRUCTURE ONLY. LINEAGE.md section 2.4 and section 6's
// OVERRULED box.
// ============================================================================
//
// The owner's own words, and the document's own correction: "what rarity and bloodline is good,
// stop trying to nerf everything, as long as we don't charge people money, what difference does
// it make, we haven't sold anything." -- and: "The corrected position: store the web on chain...
// The one argument that survives, and it is about timing, not safety: a realm cannot be edited,
// and the 84 relation sentences in section 2 are hours old while the comic register is still
// being revised weekly. Store the STRUCTURE -- who is related to whom, which is settled -- and
// keep the WORDING off chain where it can still be improved."
//
// SO: the 84 (from, to, type) rows, as ids. NOT the 84 label sentences, NOT the thirteen lots,
// NOT their members, NOT the grandparents' one-liners, NOT the card's line-name field.
//
// THE LOTS STAY OFF CHAIN DELIBERATELY, and this is the one place the OVERRULED box has to be
// read narrowly rather than generously. It names "the 84 relation sentences" as the wording and
// "who is related to whom" as the structure; it does not extend to lot membership. And section
// 6.5 -- which the box says explicitly SURVIVES and "is the part that was doing the real work
// all along" -- forbids LineOf(tokenID) and LineCount(line) BY NAME. A realm that stored the
// thirteen lots would be a realm that could answer both, so v7 does not store them. The line a
// card prints ("Out of Pell's lot") is derived by the client from LINEAGE.md section 1.1's
// published table joined on BatchIndex, which is the same ids-on-chain/names-off-chain split as
// everything else here.
//
// AND THE "SECOND CODE PATH" -- LINEAGE.md section 6.2's third named cost -- DOES NOT EXIST.
// This table is deploy-time-constant state. No function writes it. No function in settleCore,
// SaveDay, Buy, List, Wake or SetName reads it. The only code that touches it is the two
// enumerators and the verification tests. There is nothing to drift, nothing to gate, and
// nothing that could accidentally branch on it, because no code path that does anything
// consequential can see it.
//
// WHY THIS IS ALSO LINEAGE.md section 6.4's COMMITMENT, satisfied better than the repo hash it
// recommends: section 6.4 wanted sha256 of the section 2.4 block published in the repo, dated,
// before the batch opens, and noted the recommendation "got slightly less comfortable at 60"
// because "a stranger who mints #47 has no relationship with the repo and no reason to trust an
// mtime". THE DEPLOYED REALM IS THE COMMITMENT: dated by a block height, signed by a known key,
// immutable, and readable by that stranger without anybody telling him where to look. The
// sequence section 6.4 insists on ("take the hash before the mint opens") is satisfied
// automatically, because this realm must deploy before AdminAllow can let anybody claim.

// The nine kinship type ids, FROZEN ALPHABETICALLY rather than in LINEAGE.md's own frequency
// order (cousin 39, neighbour 11, sibling 10, rival 9, not-speaking 5, in-law 4, disputed 3,
// latent-kin 2, taken-in 1), because the frequency order is a property of THIS batch and would
// change for Batch Two, whereas alphabetical is stable and self-checking. LINEAGE.md section 2.4
// declares the vocabulary closed -- "the nine type values are the complete vocabulary; section 5
// adds no tenth, and the rebuild at 60 added no tenth either" -- so the ids are safe to freeze.
// TestKinTypeNamesAreAlphabeticalAndNine pins both facts.
const (
	kinCousin      = int64(0)
	kinDisputed    = int64(1)
	kinInLaw       = int64(2)
	kinLatentKin   = int64(3)
	kinNeighbour   = int64(4)
	kinNotSpeaking = int64(5)
	kinRival       = int64(6)
	kinSibling     = int64(7)
	kinTakenIn     = int64(8)

	numKinTypes = 9
	numKinEdges = 84
)

// kinTypeNames: the nine words, paired by index with the ids above. THIS IS A JUDGEMENT CALL
// AGAINST THE STRICTEST READING OF "WORDING OFF CHAIN", declared rather than slipped in, and the
// argument for it is three-part: the nine words are a CLOSED vocabulary LINEAGE.md declares
// complete and that the rebuild at 60 did not extend; they are one word each, carrying none of
// the comic register FUNNY.md revises weekly (the thing being revised is the 84 sentences, and
// not one of those is here); and without them the table is 84 triples of integers that no client
// can render into anything a human reads -- "#14 is a 7 of #6" is not a family.
//
// IF THE OWNER DISAGREES, THE CHANGE IS ONE FUNCTION. Drop KinTypeName and TotalKinTypes and the
// nine words live in LINEAGE.md keyed by id exactly as the thirty-two axis names do. The table
// and its enumerators are unaffected and nothing else moves.
var kinTypeNames = [numKinTypes]string{
	"cousin", "disputed", "in-law", "latent-kin", "neighbour",
	"not-speaking", "rival", "sibling", "taken-in",
}

// kinEdge: one row of LINEAGE.md section 2.4, structure only. `from` is always the LOWER batch
// index; every edge is undirected except the three `disputed` rows, where `from` is the gnome
// doing the claiming -- and the claimer is the lower index in all three, which is that
// document's own constraint on how a dispute may be written rather than a coincidence.
type kinEdge struct {
	from int64 // 1..60, a batchIndex (NOT a token id -- see batchIndex's own comment)
	to   int64 // 1..60, a batchIndex
	typ  int64 // 0..8, one of the nine ids above
}

// kinEdges: LINEAGE.md section 2.4's fenced block, transcribed row by row IN ITS OWN ORDER,
// labels omitted. Frozen at deploy; NOTHING IN THIS FILE WRITES TO IT, EVER.
//
// WRITTEN AS 84 ONE-LINE STRUCT LITERALS WITH NAMED TYPE CONSTANTS, NOT AS PACKED INTEGERS. A
// row would squeeze into 16 bits (from 6, to 6, typ 4) and all 84 into eleven int64s, a tenth of
// the bytes. It is not worth it: the whole value of this table is that a reviewer can diff it
// against LINEAGE.md section 2.4 line by line, and {1, 9, kinSibling} does that where 0x0409
// does not. Transcribing 84 rows is the single highest-risk clerical act in building v7, and the
// mitigation is that the source looks like the document PLUS TestKinEdgesMatchTheDocument and
// TestAllThirtyTwoOriginalEdgesSurvive -- not that the source is small.
var kinEdges = [numKinEdges]kinEdge{
	{1, 9, kinSibling},
	{1, 10, kinNeighbour},
	{1, 25, kinCousin},
	{2, 19, kinInLaw},
	{2, 21, kinRival},
	{2, 51, kinNeighbour},
	{2, 57, kinRival},
	{3, 12, kinDisputed},
	{3, 15, kinCousin},
	{3, 30, kinCousin},
	{4, 7, kinRival},
	{4, 11, kinSibling},
	{4, 19, kinCousin},
	{4, 28, kinCousin},
	{5, 12, kinCousin},
	{5, 16, kinNeighbour},
	{5, 18, kinTakenIn},
	{5, 33, kinCousin},
	{6, 13, kinRival},
	{6, 14, kinSibling},
	{6, 31, kinCousin},
	{6, 60, kinRival},
	{7, 15, kinCousin},
	{7, 23, kinLatentKin},
	{7, 43, kinNeighbour},
	{8, 17, kinCousin},
	{8, 22, kinNeighbour},
	{8, 24, kinCousin},
	{8, 45, kinInLaw},
	{9, 14, kinNotSpeaking},
	{9, 16, kinCousin},
	{9, 50, kinNeighbour},
	{10, 21, kinSibling},
	{10, 37, kinCousin},
	{10, 38, kinNeighbour},
	{11, 12, kinDisputed},
	{11, 13, kinCousin},
	{12, 18, kinCousin},
	{13, 20, kinInLaw},
	{13, 44, kinDisputed},
	{14, 22, kinCousin},
	{14, 53, kinNeighbour},
	{15, 17, kinNotSpeaking},
	{15, 23, kinCousin},
	{16, 20, kinCousin},
	{16, 25, kinCousin},
	{17, 35, kinCousin},
	{18, 23, kinNeighbour},
	{18, 34, kinCousin},
	{19, 27, kinCousin},
	{20, 26, kinCousin},
	{20, 39, kinNeighbour},
	{21, 24, kinRival},
	{21, 37, kinCousin},
	{22, 32, kinCousin},
	{23, 29, kinCousin},
	{24, 36, kinCousin},
	{24, 48, kinNotSpeaking},
	{25, 26, kinSibling},
	{27, 28, kinCousin},
	{29, 30, kinRival},
	{31, 32, kinCousin},
	{33, 34, kinNeighbour},
	{35, 36, kinRival},
	{37, 38, kinCousin},
	{39, 40, kinSibling},
	{40, 41, kinCousin},
	{41, 42, kinCousin},
	{42, 43, kinNotSpeaking},
	{42, 49, kinNotSpeaking},
	{44, 45, kinSibling},
	{45, 46, kinCousin},
	{46, 47, kinCousin},
	{47, 48, kinInLaw},
	{49, 50, kinSibling},
	{50, 51, kinCousin},
	{51, 52, kinRival},
	{52, 56, kinLatentKin},
	{53, 54, kinSibling},
	{54, 55, kinCousin},
	{55, 56, kinCousin},
	{57, 58, kinSibling},
	{58, 59, kinCousin},
	{59, 60, kinCousin},
}

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
// character is "" for every ordinary gnome and one of namedEditionOrder's eight strings for a
// named one-of-one. eyes/nose/hat/coat are the sentinel -1/-1/""/"" for a named edition: its
// look is NOT a point in the ordinary 1,280-look space, it is the art pack's own character art
// (Hob's crown and gold coat, Thistle's helmet and axe, Wick's lantern, and v7 change 10's five:
// Tally's trowel, Glim's halo, Vigil's slate-and-ink coat, Spruce's top hat and moustache,
// Yonder's bandana and parrot), which this contract
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

	// ------------------------------------------------------------------------------------
	// v7: THE PERSONALITY. Fourteen fields, every one of them written ONCE, in settleCore's
	// commit block, from the pure drawRoll's output, and never written again by anything.
	// Every one has an exported reader EXCEPT careThreshold -- v4's own "every field has a
	// reader" rule, carried by v5 and v6, honoured here with one declared exception (see that
	// field's own comment and DESIGN.md section 2.6).
	//
	// FOR THE GENESIS GNOME EVERY ONE OF THESE IS 0, including batchIndex, which is the same
	// "never produced by a roll" sentinel settledRound = 0 already is and is true of exactly
	// one token for the life of this realm. batchIndex = 0 is therefore unambiguous: the batch
	// is 1-indexed and there is no gnome #0.
	//
	// STORED AS EIGHTEEN EXPLICIT int64 FIELDS, NOT PACKED INTO ONE uint64, which is what
	// TRAITS.md section 7 literally says ("51 bits, in one uint64"). Three reasons, in order
	// of weight: (1) fourteen shifts and fourteen masks is fourteen chances at a silent
	// off-by-one, and a wrong mask returns a PLAUSIBLE number -- temperament 2 instead of 6 --
	// with nothing failing, which is precisely the failure mode BATCH-ONE.md:120 warns about,
	// introduced into the one function the warning is about, to save 136 bytes a gnome; (2) a
	// bit layout is the most load-bearing thing you can ship, load-bearing in exactly the way
	// section 7 itself rejects for stored seeds and stored table indexes -- once temperament
	// lives at bits 0-2, it lives there forever and every client, indexer and future realm has
	// to agree; (3) v6's whole discipline is explicit named fields with explicit readers.
	// Section 7's "in one uint64" was making the argument that THE WHOLE PERSONALITY IS SMALL,
	// which is true and is still true: it is 65 bits of information (section 7's 51 plus 8 for
	// five explicit dominance slots instead of a Lehmer code, plus 6 for batchIndex) and it
	// still fits in one machine word. The ENCODING is eighteen fields.
	//
	// The five rolled axis ids. TRAITS.md sections 1.1-1.5, each drawn from its own 64-wide
	// weight table. Axis order here is axis order everywhere: 0 temperament, 1 obsession,
	// 2 bond, 3 fear, 4 boast -- which is what `dominance` below indexes.
	temperament int64 // 0-5, TRAITS.md section 1.1
	obsession   int64 // 0-7, section 1.2
	bond        int64 // 0-5, section 1.3
	fear        int64 // 0-5, section 1.4
	boast       int64 // 0-5, section 1.5

	// dominance: the whole permutation of the five axis indexes, loudest first. TRAITS.md
	// section 2.2 stores the WHOLE ORDER and not the state labels, and that is the decision
	// this realm is making permanently: WHERE THE LOUD/LATENT BOUNDARY FALLS IS AN OFF-CHAIN
	// READING of this number. Two states versus three is therefore a constant in the writing
	// layer, fully reversible after deploy in either direction, for free -- BUT ONLY IF ALL
	// FIVE SLOTS ARE STORED. A realm that stored just "loudest, second-loudest" (5 x 4 = 20
	// values, 5 bits, which is what a reviewer optimising for bytes reaches for) would be
	// storing the two-state design itself, and the third state would be UNRECOVERABLE
	// FOREVER: there would be no stored fact about the other three axes' order for a future
	// stimulus engine to re-split. "Two states now is reversible; a third state now is a spec
	// nobody can honour" is only true of a realm that keeps all five slots.
	//
	// The cost of five explicit slots, stated honestly: they can represent invalid states
	// ([0,0,0,0,0]) where a 0-119 Lehmer index could not -- so assertRoll checks the
	// permutation before anything is committed. The reason to pay that cost rather than spend
	// 7 bits on a factorial-base index is that the index needs A CODEC ON BOTH SIDES OF THE
	// WIRE, two codecs that must agree forever over a convention nobody has written down, in
	// the one function MINT.md section 9 names as needing its own audit pass above all others.
	// Five explicit slots have no codec at all: settleCore stores exactly what it computed,
	// Dominance returns exactly what is stored, and there is nothing in between for an
	// off-by-one to live in.
	dominance [numAxes]int64 // a permutation of 0..4; slot 0 is the loudest

	// secret: 0-16, TRAITS.md section 3.2. The id only -- the NAME and the LINE live off chain.
	// Drawn by secretFor, which is weighted toward the secrets that undercut this gnome's own
	// rolled boast or fear, and constrained to be distinct for the first seventeen settles.
	secret int64

	// The four Top Trumps stats, TRAITS.md section 4.1. Stored as four explicit values and
	// NEVER as the index into legalStatLines -- section 7's own reason, twice over: a stored
	// index makes the 546-row order permanent, so the table could never be re-derived or
	// re-ordered for Batch Two without re-deriving every Batch One gnome.
	//
	// NOTHING IN ANY REALM COMPARES TWO GNOMES' STATS. There is no Top Trumps game on chain:
	// section 4.5's tie rule is social, and v7 ships no reader that takes two token ids.
	pluck    int64 // 1-10
	nous     int64 // 1-10
	grumble  int64 // 1-10
	appetite int64 // 1-10

	// careThreshold: the 0-31 DRAW, not the threshold. threshold = careThresholdFloor + this.
	//
	// THE ONE FIELD IN THIS REALM WITH NO EXPORTED READER, AND THE ONLY WRITE-ONLY FIELD IN
	// IT. Not read by Settle after it is written, not by SaveDay, not by any reader, not by
	// Render. That is unusual enough that a reviewer will try to delete it as dead code --
	// hence this paragraph, and hence TestCareThresholdIsStoredAndInRange, which reads it
	// directly from the same package because that is how a write-only field is verified.
	//
	// WHY NO GETTER. Not because it hides the number: a realm's persisted object graph is
	// written into every node's store and nothing in Gno encrypts it, so this field is OBSCURE
	// RATHER THAN SECRET and this file does not rest on the optimistic reading. The reasons
	// are (1) GAMES.md:38's converse -- "a missing enumerator cannot be added later" has a
	// mirror image, A SHIPPED GETTER CAN NEVER BE REMOVED, and a getter is what the first
	// third-party UI finds in an hour and builds a progress bar on within a week, where a
	// serialized object graph is what nobody will bother with: the asymmetry in EFFORT is the
	// whole mechanism and it is real even though it is not a guarantee; and (2) the actual
	// protection is elsewhere and v7 has to honour it IN STORAGE rather than in omission --
	// TRAITS.md section 5.1 point 2: the promptness bonus is a Mood reading taken at the
	// moment of care and NEVER STORED, so nobody can tell whether a given care-day scored 1 or
	// 2, so nobody can pin a gnome's score closer than a factor of two. Which makes a HARD
	// CONSTRAINT on this realm, stated here because it is easy to violate by being helpful:
	//
	//	v7 STORES NO CARE SCORE, AND STORES NOTHING THAT DISTINGUISHES A 1-POINT CARE-DAY
	//	FROM A 2-POINT ONE. recordCaredDay is carried from v6 unchanged -- it records WHICH
	//	UTC DAYS were cared for (caredMask, caredDayCount, lastCaredDay) and nothing about
	//	the mood at the time. No promptMask, no promptDayCount, no per-day mood log, no
	//	"arrived before the mood turned" counter. Any of them would collapse the
	//	factor-of-two interval to zero and hand over the countdown that the no-getter rule
	//	is only the SECOND line of defence against.
	//
	// WHY STORE IT AT ALL, given nothing reads it: TRAITS.md section 7 -- derive it from a
	// hash and the salt becomes load-bearing forever, and a gnome's threshold must never
	// change under him. Stored, it is pinned to the roll that produced it, verifiable by the
	// holder against SettledRound and drand's own public API, and independent of any off-chain
	// scorer's configuration. One byte per gnome buys all of that.
	careThreshold int64 // 0-31, the draw; the threshold is careThresholdFloor + this

	// bornUnder: 0-7, TRAITS.md section 1.6. Rolled, stored and read back by BornUnder exactly
	// like any other field. WHAT MAKES IT CARD-ONLY IS THAT IT IS NOT IN `dominance` -- the
	// permutation is over the five axes, indexed 0-4, and born-under has no index, so it can
	// never be loud, never be latent and never appear in the label, by construction. Whether
	// the runtime is handed it is an OFF-CHAIN discipline and nothing this realm can enforce;
	// this is the half the realm can guarantee, and it does.
	bornUnder int64

	// batchIndex: 1-60, this gnome's position in Batch One, assigned as settledCount+1 in
	// settleCore. 0 for the genesis gnome and for nothing else.
	//
	// IT EXISTS BECAUSE LINEAGE.md NUMBERS ITS GNOMES #1 TO #60 AND THOSE ARE NOT THIS REALM'S
	// TOKEN IDS. init() spends the first seqid on the genesis gnome, so the first CLAIMED
	// gnome is token "0000002" -- confirmed on the live v5 chain, not inferred. Without a
	// stored join, every client that wants to render a holder's cousins has to know (a) that a
	// genesis gnome exists, (b) that it consumed id 1, and (c) that seqid renders as seven
	// zero-padded digits: three pieces of internal realm trivia, on a realm that cannot be
	// edited, standing between a holder and his own family. Six bits removes all three.
	//
	// SETTLE ORDER, NOT CLAIM ORDER, and for the same reason the first-seventeen secret rule
	// uses settle order: token ids are assigned in settleCore, so batchIndex and the token id
	// advance together and never disagree. A client can cross-check (batchIndex should equal
	// the token's numeric id minus one) but is never required to.
	//
	// LINEAGE.md section 1.3 already licenses the consequence for Hob, Thistle and Wick: it
	// nominally places them at #1, #12 and #24 and says in the same breath that "no edge in
	// section 2 depends on it -- if the roster assigns the three one-of-ones to different ids,
	// swap the ids and the web is unchanged". The web attaches to batch indexes; the named
	// editions attach to whichever gnomes drew them. Nothing reconciles the two and
	// nothing needs to.
	//
	// THAT ARGUMENT CARRIES v7 CHANGE 10's FIVE NEW EDITIONS UNCHANGED, which is worth saying
	// because LINEAGE.md section 1.3 was written when the roster was three and still says three.
	// Its nominal #1/#12/#24 placement was already decorative ("no edge depends on it"), and the
	// 84 edges are keyed by batch index 1..60 with no reference to a character at all, so a
	// roster of eight needs no edge to move, no index to be reserved, and no edit to LINEAGE.md
	// for this file to be correct. The stale count there is a documentation lag, not a
	// disagreement with the chain.
	batchIndex int64

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
	// property this bookkeeping exists to measure (lockCaredDays' resale lock, and the
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
	// tokens, the worst case for the entire realm is 60 names held at once by the 60 tokens that
	// exist. See SetName's commit block, which removes before it sets.
	nameOwner = avl.NewTree()

	// characterOwner: one of namedEditionOrder's eight names -> tokenID, present only once that
	// edition has actually been minted. Has(name) is both "has this cap-one edition been taken"
	// (Settle's own fallback check) and "does it exist yet" (CharacterOwner's reader) -- the same
	// single tree answers both questions, which is why there is no separate counter for it.
	characterOwner = avl.NewTree()

	// batchIndexToToken: int64 batchIndex (as decimal) -> tokenID string. v7's join between
	// LINEAGE.md's #1-#60 numbering and this realm's token ids, in the direction a client cannot
	// compute for itself. Written once per settle, in settleCore, beside the gnome's own
	// batchIndex field; never removed, never rewritten -- a sale moves a token, it does not move
	// a batch position. See TokenByBatchIndex.
	batchIndexToToken = avl.NewTree()

	// secretsDrawnMask: bit i is set once secret i has been drawn by one of the first
	// firstDistinctCount mints. Written only while settledCount < firstDistinctCount, read only
	// while batchIndex <= firstDistinctCount, NEVER CLEARED by anything -- not by a sale, not by
	// a rename, not by anything.
	//
	// Never-cleared is load-bearing for the monotonicity property in secretFor's own comment.
	//
	// THIS MASK IS DERIVABLE BY ANYONE, AND THAT IS ACCEPTED. AUDIT-01 YELLOW-2 corrected an
	// earlier version of this comment which claimed the mask was "exposed by nothing". It is
	// not. TraitsCsv returns `secret` AND `batchIndex` in the same call and TokensPage
	// enumerates every token, so one pass over the collection reconstructs this word EXACTLY:
	// { Secret(t) : BatchIndex(t) <= firstDistinctCount }. There is no getter for the mask and
	// there is no SecretCount, SecretCensus, HoldersOfSecret or IsFirstSeventeen -- but shipping
	// no getter does not make the value private, it only keeps it off the path of least
	// resistance.
	//
	// Removing Secret or BatchIndex from the readers is NOT on the table and would be the wrong
	// trade: the acrostic is found by READING THE SECRET NAMES, and BatchIndex is what closes
	// the join to LINEAGE.md's #1-#60 numbering. DESIGN.md section 5.3 already makes exactly
	// this argument for the kinship table -- "a third party can of course build KinOf on top of
	// 84 public rows; the concern was never that the data is derivable" -- and the same answer
	// applies here.
	//
	// SO, STATED PLAINLY BECAUSE IT HAS AN OPERATIONAL CONSEQUENCE THE KINSHIP TABLE DOES NOT:
	// this mask is a live input to an UNSETTLED draw (secretFor's `taken`), so it is a KNOWN
	// INPUT TO ANYONE CHOOSING WHEN TO SETTLE. Nobody should reason about the draw on the
	// assumption that a pending claimant cannot see it; he can, from two public readers, at any
	// moment. TRAITS.md section 3.2.2 note 3 -- an owner who can see which secrets are taken can
	// deduce other gnomes' secrets by elimination -- is therefore a product rule about the UI
	// and the marketing, not a technical guarantee, and never was one: v7's SOURCE is public too
	// (vm/qfile returns it verbatim), so anyone who looks finds firstDistinctCount = 17 and this
	// field.
	secretsDrawnMask uint32

	mintedCount int64 // reservations made by Claim, gates batchCap; never decremented

	// settledCount: completions made by Settle. INHERITED COMMENT CORRECTED, AUDIT-01 YELLOW-2 --
	// it read "informational only, see BatchStatus", which was true in v6 and is FALSE IN V7.
	// Here it drives batchIndex (settledCount+1, the kinship join's key) and the first-seventeen
	// secret window (batchIndex <= firstDistinctCount). With mintedCount it is one of the two
	// most load-bearing numbers in the realm; nothing here is informational.
	//
	// It briefly drove a third thing -- slotsLeft (batchCap - settledCount), the trigger of the
	// named-edition guarantee written 2026-10-17. That guarantee was removed on 2026-10-18 (see
	// settleCore and AUDIT-01 RED-1) precisely because this counter is public through
	// BatchStatus, which made the trigger watchable off chain.
	settledCount int64

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

	// v7 change 4: TRAITS.md section 4.2's legal stat set, enumerated once from the rule. See
	// legalStatLines and buildLegalStatLines. Done here rather than in settleCore so no
	// claimant pays for it; done from the rule rather than from a 546-row literal so a
	// transcription error is not possible.
	legalStatLines = buildLegalStatLines()
	if len(legalStatLines) != numLegalStatLines {
		// Unreachable: the enumeration is deterministic and TestLegalStatLinesIsExactly546 pins
		// the count. Named so init() is correct on its own terms -- the same discipline v4's Buy
		// uses for its own unreachable checks, and the stakes here are a DEPLOY that silently
		// ships a different draw space from the one the tests measured.
		panic("garden: DEPLOY GATE: the legal stat line enumeration did not produce " +
			strconv.Itoa(numLegalStatLines) + " rows; TRAITS.md section 4.2's rule and this code disagree")
	}

	// AUDIT-02 YELLOW-D: THE ONE INVARIANT THE NAMED-EDITION ROSTER CANNOT SURVIVE LOSING, now a
	// gate rather than only prose, an array length and two tests. settleCore draws
	// `namedPick = seedFor(...) % namedPickRange` and takes namedEditionOrder[namedPick] only when
	// namedPick < numNamedEditions -- so if the roster ever grows past the modulus, EVERY EDITION AT
	// AN INDEX >= namedPickRange IS PERMANENTLY UNMINTABLE. See numNamedEditions and namedPickRange,
	// which both say this in words; this is the same statement in a form a DEPLOY cannot ignore.
	//
	// WHY AN OFF-BY-ONE HERE IS WORSE THAN A WRONG ROW COUNT, which is the reason it earns a gate of
	// its own next to the enumeration check above: a miscounted stat enumeration ships a draw space
	// that differs from the measured one -- bad, and the stated reason that gate exists -- but it is
	// a DIFFERENT distribution, which means it is visibly wrong in the traits the first settles
	// produce. AN ELEVENTH EDITION IS NOT WRONG, IT IS SILENT. Claim succeeds, Settle succeeds,
	// assertRoll passes, BatchStatus reports a namedCap that counts it, CharacterOwner answers
	// not-found exactly as it does for an edition nobody has drawn yet, and the roster reads complete
	// in every reader. The only symptom is a one-of-one that never appears -- indistinguishable from
	// the 1-in-550 ordinary bad luck this realm deliberately accepts -- and it is noticed when the
	// batch closes, by which time this realm is immutable and a piece of commissioned art has nowhere
	// to go. A wrong row count is caught by looking at a gnome; this is caught by nothing.
	if numNamedEditions > namedPickRange {
		panic("garden: DEPLOY GATE: numNamedEditions (" + strconv.Itoa(numNamedEditions) +
			") exceeds namedPickRange (" + strconv.Itoa(namedPickRange) +
			"); the named-edition pick is seed % namedPickRange, so every edition at an index >= namedPickRange " +
			"can never be drawn and would be permanently unmintable with no error anywhere -- raise " +
			"namedPickRange (and re-derive the odds at its declaration) or shrink the roster before deploying")
	}

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
		character: "gaffer",
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

	// Registered under its own name, "gaffer", in the SAME tree the eight named one-of-ones
	// use -- not because it competes with their cap (BatchStatus's namedMinted count iterates
	// namedEditionOrder only, which "gaffer" is never a member of, so this cannot affect the
	// batch), but so CharacterOwner("gaffer") resolves instead of silently reporting not-found
	// for the one named character that is neither ordinary nor one of the eight. Second-audit-
	// pass finding (G7): fixed here, not left as a reader inconsistency.
	characterOwner.Set("gaffer", genesisTokenID)

	// The EVENT type stays "Genesis" after the gnome was named (Sprig in v7, Gaffer in v8), and
	// decision rather than a miss: this names the EVENT -- the genesis of the collection, which
	// happens exactly once at deploy -- and not the gnome. The gnome's name travels in the payload,
	// so a reader gets both and neither word is doing the other's job.
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

	// v7: the second unreachable accounting check, same discipline, for the one piece of state
	// the first-seventeen secret rule depends on. popcount(secretsDrawnMask) must equal
	// min(settledCount, firstDistinctCount) at the top of every settle: the mask gains exactly
	// one bit per settle until the window closes and is never cleared by anything. If it ever
	// does not, something has written the mask outside the one place below that may, and the
	// acrostic's distinctness guarantee is no longer true of this realm.
	expectedMaskBits := settledCount
	if expectedMaskBits > firstDistinctCount {
		expectedMaskBits = firstDistinctCount
	}
	if int64(popcount32(secretsDrawnMask)) != expectedMaskBits {
		panic("garden: the first-seventeen secret mask disagrees with the settle count; refusing to mint")
	}

	// batchIndex: SETTLE ORDER, NOT CLAIM ORDER, and getting this backwards would break both the
	// kinship join and the distinctness guarantee. mintedCount counts Claims and gates batchCap;
	// settledCount counts Settles. Because Settle is permissionless and claims may settle in any
	// order at any later time, mintedCount can be 40 while settledCount is 6 -- so keying the
	// first-seventeen rule off claim order would key it off a number already spent before the
	// relevant gnome exists.
	batchIndex := settledCount + 1

	// THE NAMED-EDITION PICK. seed % namedPickRange, against the COMPILE-TIME CONSTANT
	// namedPickRange, never against a shrinking count of what remains -- see the package doc's
	// "flaw found and fixed" section for why that distinction is the whole safety property here.
	// namedPick is fixed the instant randomnessHex exists (i.e. the instant the pinned round is
	// signed by drand, which nobody controls), and WHEN Settle happens to be called after that
	// changes nothing about it.
	//
	// v7 CHANGE 9, 2026-10-18: this modulus was uint64(batchCap), making each edition a 1-in-60
	// shot and leaving a 74.4% chance at least one of the three never existed. It is now its own
	// constant at 10, decoupled from the batch size and ten times the rate. The arithmetic, why it
	// is not batchCap, the safety argument and the cost are all at namedPickRange's declaration.
	//
	// v7 CHANGE 10, the same day, DID NOT TOUCH THIS LINE: it raised numNamedEditions from 3 to 8,
	// which widens the branch below without changing the draw. This expression is identical to
	// v6's apart from change 9's one constant.
	namedPick := seedFor(randomnessHex, claimant, "slot") % uint64(namedPickRange)

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

	// v7 PHASE 1 AND PHASE 2: the fourteen new values, drawn by one pure function and checked
	// before anything is committed. r is carried to the commit block unmodified -- nothing below
	// may change a trait, and nothing below has access to a draw.
	r := drawRoll(randomnessHex, claimant, batchIndex, secretsDrawnMask)
	assertRoll(r, secretsDrawnMask)

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

	// ------------------------------------------------------------------------------------
	// THERE IS NO NAMED-EDITION GUARANTEE, AND THAT IS A DECISION, NOT AN OVERSIGHT.
	// Guarantee written 2026-10-17, audited, REMOVED 2026-10-18 by the owner. The named-edition
	// path above is v6's, byte-for-byte. AUDIT-01.md RED-1 is the finding this answers.
	// ------------------------------------------------------------------------------------
	//
	// THE ARITHMETIC, KEPT BECAUSE IT IS THE THING BEING ACCEPTED, AND RECOMPUTED FOR v7 CHANGE
	// 10's EIGHT EDITIONS RATHER THAN EDITED. The pick above is `seed % namedPickRange`, named if
	// the result is under numNamedEditions = 8, and each of the sixty claimants draws
	// independently. So for a given edition, P(never drawn by 60 claimants) =
	// (9/10)^60 = 0.0017971, and
	// P(at least one of the eight never minted) = 1 - (1-0.0017971)^8 = 1.43%.
	// A HALF-FILLED BATCH OF 30 IS 1 - (1-(9/10)^30)^8 = 29.3%, which is the number to quote at
	// anyone sizing the allowlist. "HOB WAS NEVER BORN" IS STILL A POSSIBLE PERMANENT FACT ABOUT
	// THIS REALM, and so now is "TALLY WAS NEVER BORN" -- there is no guarantee here, only a rate.
	// Per edition it is a one-in-five-hundred-and-fifty fact; across eight editions the chance that
	// SOME ONE OF THEM is missing is 1.43%, UP from 0.54% at three editions, because adding
	// editions adds chances to miss one. That increase was accepted knowingly with change 10.
	//
	// THOSE WERE 1-in-60 AND 74.4% UNTIL 2026-10-18, when the modulus became namedPickRange
	// instead of batchCap (v7 change 9). DESIGN.md section 9.1 is where the 74.4% was first
	// computed and it describes the odds as they were; v5, which is live, and v6, which is not,
	// both still carry 1-in-60. The decision below -- REMOVAL OF THE GUARANTEE -- was taken
	// against the 74.4% and is unaffected by the new rate: raising the odds is not a guarantee and
	// does not reintroduce one. The owner's position, recorded while that figure stood, was that a
	// one-of-one which might never be minted is arguably the better one-of-one; what he asked for
	// afterwards was "the rates have to come out during a mint", which is a probability, not a
	// promise. Full arithmetic, including why the modulus is its own constant, at namedPickRange.
	//
	// KNOWN AND ACCEPTED, THEN: not missed. A guarantee WAS written here, in the owner's
	// approved form -- "when the number of unsettled slots remaining equals the number of named
	// editions still unclaimed, the remaining settles take them" -- as a forced branch at this
	// point plus a helper (namedEditionToForce) comparing slotsLeft = batchCap - settledCount
	// against the editions characterOwner did not yet hold. It was audited and it was removed.
	// NOTHING SHIPPED IN ITS PLACE. The 74.4% is the status quo v5 and v6 already had.
	//
	// WHY IT WAS REMOVED, which is the part a future reader needs because it inverts the
	// argument the removed code made for itself. That code's defence was that it did NOT draw
	// against a shrinking modulus -- it assigned DETERMINISTICALLY -- on the reasoning that a
	// draw against a shrinking, observable modulus is the gameable shape v6 exists to document.
	// THE REASONING RUNS THE OTHER WAY. DETERMINISTIC ASSIGNMENT KEYED ON A SHRINKING PUBLIC
	// OBSERVABLE IS STRICTLY WORSE THAN A DRAW AGAINST ONE: with a draw you are still betting,
	// and with assignment THE OUTCOME IS CERTAIN THE MOMENT THE PREDICATE HOLDS. The predicate
	// was computable off chain by anybody at any moment from two public readers -- BatchStatus
	// returns settledCount, CharacterOwner says which editions are gone -- so a claimant did not
	// have to guess; he could watch the branch come to him.
	//
	// AND THE DEFENCE ADDRESSED THE WRONG WITHHOLDING. It argued that Settle is permissionless
	// and never expires, so nobody can reserve a late slot: anyone can settle a holdout's claim
	// for the price of gas. That is true of a withheld SETTLE and IRRELEVANT TO A WITHHELD
	// CLAIM. Settle requires a pendingClaim to exist (see pendingClaimFor); A CLAIM THAT WAS
	// NEVER MADE CANNOT BE SETTLED BY ANYBODY. And Claim gates only on hasRolled and
	// mintedCount >= batchCap -- it never reads settledCount. So a wallet that simply did not
	// claim until 57 slots were settled took a named edition WITH CERTAINTY instead of the
	// honest draw (~3/60 = 5% at the 1-in-60 odds that stood when this was found; ~27% of picks
	// pointed at an edition after change 9, and ~8/60 = 13% of claimants can actually end up
	// holding one after change 10 -- every one of those numbers changes the GAIN and none of them
	// changes the CERTAINTY, so the finding is unaffected, and it gets WORSE as the roster grows
	// because a wallet holding back for a forced slot would now have had eight to be handed),
	// and eight such wallets took the lot. The one-mint-per-wallet cap did
	// not contain it, because each of those wallets needs exactly one mint.
	//
	// IT ALSO MISFIRED WITH NO ATTACKER AT ALL. BATCH-ONE.md section 2's hand-read rolling
	// allowlist leaves claim slots free late BY CONSTRUCTION, so the rarest assets in the
	// realm would have gone to whoever the admin happened to allowlist last -- an admin-timed
	// allocation of the scarcest things here, unremovable after deploy. The rule existed to
	// avoid TRAITS.md section 1.7's "the devs gave their friends the good ones"; rewarding the
	// latest instead of the quickest hands the owner that lever directly.
	//
	// WHAT ANY FUTURE ATTEMPT MUST SOLVE BEFORE IT IS WORTH WRITING, so that re-adding this is
	// not cheap. It is not enough to pick a cleverer trigger: ANY condition computed from a
	// public monotone counter is watchable, and both settledCount and mintedCount are public
	// and must stay so. The hard part is THE WITHHELD CLAIM, and NOTHING IN THIS REALM CAN
	// COUNTER IT, because AN UNMADE CLAIM IS UNSETTLEABLE -- there is no pendingClaim for a
	// third party to settle, no state to sweep, and nobody who can end the holdout's wait for
	// him. The move that suggests itself, a claim expiry or settle deadline, IS FORBIDDEN here
	// for an unrelated reason: the first-seventeen secret rule's self-healing property depends
	// on abandoned claims staying settleable forever (recorded again at that rule, and in
	// AUDIT-01 YELLOW-4, which notes the two guarantees were coupled and that the file had not
	// noticed). Three alternatives to removal were considered -- a different trigger, moving the
	// allocation off chain to a holding address and allocating by a published process, and
	// leaving the rule as written -- and removal was chosen. Solve the withheld claim first or
	// leave this alone; it is a design problem, not a patch.
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

		// v7 PHASE 3: fourteen field writes taken VERBATIM from the roll. Nothing here computes,
		// adjusts, clamps or re-derives anything -- if a value needed fixing up at this point,
		// the fix would belong in drawRoll where it could be tested without minting, and
		// assertRoll above has already refused anything out of range.
		temperament:   r.temperament,
		obsession:     r.obsession,
		bond:          r.bond,
		fear:          r.fear,
		boast:         r.boast,
		dominance:     r.dominance,
		secret:        r.secret,
		pluck:         r.pluck,
		nous:          r.nous,
		grumble:       r.grumble,
		appetite:      r.appetite,
		careThreshold: r.careThresholdDraw,
		bornUnder:     r.bornUnder,
		batchIndex:    r.batchIndex,

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

	// v7: the kinship join, written beside the gnome's own batchIndex so the two can never
	// disagree, and the first-seventeen mask. The mask is written ONLY here, ONLY inside the
	// window, and never cleared -- the two facts the monotonicity property in secretFor's
	// comment and the popcount check at the top of this function both rest on.
	batchIndexToToken.Set(strconv.FormatInt(r.batchIndex, 10), tid.String())
	if r.batchIndex <= firstDistinctCount {
		secretsDrawnMask |= 1 << uint(r.secret)
	}

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

// popcount32 counts the set bits in secretsDrawnMask, for settleCore's accounting check. Written
// out rather than imported (math/bits is not used anywhere else in this file) and bounded at 32
// iterations, which is free next to a SHA-256.
func popcount32(v uint32) int {
	n := 0
	for i := 0; i < 32; i++ {
		if v&(1<<uint(i)) != 0 {
			n++
		}
	}
	return n
}

// ============================================================================
// THE SEED DERIVATION. v7 CHANGE 8 -- THE ONE CHANGE ON THIS VERSION'S LIST THAT IS NOT A
// FEATURE, AND THE FIRST THING TO READ IN REVIEW. DESIGN.md section 1.2 item 8, section 4.3.
// ============================================================================
//
// v5 and v6 derive every seed with FNV-1a. v7 does not, and the reason is a provable defect
// rather than a preference -- the argument in full, because this is a change to a line an
// AUDITED realm carries forward and section 0's rule exists to refuse exactly that:
//
//	FNV-1a, 64-bit, is `h = offset`, then for each input byte `h ^= b; h *= 1099511628211`.
//	THE MULTIPLIER IS ODD, so multiplying never touches bit 0, and XOR acts on bit 0
//	independently. Therefore bit0(fnv64a(s)) = 1 XOR bit0(s[0]) XOR ... XOR bit0(s[n-1]) --
//	bit 0 of the hash is a PARITY of bit 0 of every input byte, not a hash of it. The general
//	form: fnv64a(s) mod 2^k depends ONLY on the low k bits of each input byte, because both
//	^ and * are closed on the low k bits. FNV-1a has ZERO diffusion into its low bits -- not
//	weak diffusion, none. TestFnvBitZeroIsAParity in garden_test.gno proves it against a local
//	copy of v6's own implementation, so the reason for this change lives in the suite and not
//	only in this comment.
//
//	WHY v5 AND v6 SURVIVED IT. They take seed % 100, % 100, % 60 and % 4 and nothing else. The
//	three large moduli mix high bits in, so the defect reaches them only through their mod-4
//	component; the fully-affected pair (hat and coat) is a UNIFORM PLACEHOLDER draw in those
//	realms anyway (BATCH-ONE.md section 4a). It is also not exploitable in any of the three
//	realms: the outcome also depends on the parity of a drand randomness that does not exist
//	yet when Claim commits, so a claimant cannot know which address parity to shop for. It is
//	a randomness-QUALITY defect, not a hole, and v5 being immutable with one ordinary gnome on
//	it means there is nothing to do about it there.
//
//	WHY v7 CANNOT SHIP IT. v7 takes seed % 2, % 3, % 5, % 16 and % 32, which v5 and v6 never
//	did, and it takes them for the DOMINANCE PERMUTATION -- the field TRAITS.md section 1.7's
//	whole duplicate-vector argument rests on (8,776 vectors to 1,053,132 WITH the order; the
//	expected fully-identical pairs among sixty from 0.202 to 0.0017). Under FNV-1a the last
//	Fisher-Yates swap would not be a coin flip at all: it would be an XOR of three parities,
//	so two claimants who pinned the SAME round would have their final swap decided entirely by
//	the parity of their own addresses -- the batch splitting into two halves by address parity,
//	every member of a half getting the identical swap. At a 3-second drand period with a
//	20-round pin, claimants claiming within a minute of each other share a round, which on a
//	curated launch day is most of them. That is structure in the batch's dominance orders: one
//	of the two most load-bearing numbers in TRAITS.md, quietly wrong, forever, on an immutable
//	realm. And "provably unrigged" (ECONOMY.md section 1) is this project's headline claim: a
//	holder who re-derives his own gnome and finds that one bit of it is a parity of his own
//	address has found something this project should have found first.
//
// WHAT THIS CHANGE DOES NOT BUY, said plainly because the temptation is to over-claim.
// SHA-256 IS NOT THE SOURCE OF UNPREDICTABILITY HERE EITHER -- drand's signature for a
// not-yet-existent round is, exactly as MINT.md section 10.5 designs, and v6's own comment on
// fnv64a was right about that and is carried forward in spirit. After the pinned round
// publishes, every seed is computable by anybody (that is the design: the commit/reveal split
// exists so the fact is fixed before anyone can see it); before it publishes nobody can
// compute any of them, and the reason is drand's threshold signature alone; and if drand's
// threshold is ever broken, v7 is broken, hash or no hash. v7 does not become more
// unpredictable. IT BECOMES CORRECTLY DECORRELATED, which is the only job seedFor was ever
// doing and the job v6's implementation does not do.
//
// crypto/sha256 is not a new assumption: arena/v1 uses sha256.Sum256 for its commit hashes and
// its own source records cross-checking the output against Node's crypto.createHash('sha256')
// on a fixed input; bls254 and beacon/v2 use it too (beacon.Randomness(round) IS
// sha256(signature)). fnv64a is DELETED rather than kept beside this -- two hashes in one realm
// is an invitation to call the wrong one.

// seedDomain: a version tag, so a seed derived by this realm can never collide with one derived
// by any other realm or any later version from the same round and claimant. It is part of the
// hashed input and therefore frozen the moment v7 deploys.
// seedDomain DELIBERATELY STILL SAYS v7, and this is a decision rather than the oversight it
// looks like. tools/check-realm-version.js exempts it by exact text and says so.
//
// It is a cryptographic domain constant: every gnome's traits are sha256 of it concatenated with
// the round, the claimant and a purpose. Bumping it to "v9" therefore RE-ROLLS EVERY POSSIBLE
// GNOME -- a given (round, claimant) draws something different. v9 exists to rename ONE gnome;
// re-rolling the whole collection is a far larger change than the one that was asked for, and
// doing it as a side effect of tidying a string would be the wrong kind of quiet.
//
// Measured, not assumed: bumping it to v9 made TestNamedEditionCanOnlyEverBeMintedOnce fail,
// because an earlier test's draw began hitting "wick" where it previously had not. Realm state
// persists across test functions, so the suite's fixtures depend on the draw. That failure is
// the warning working -- see gnomod.toml item (14) -- not a test to be adjusted.
//
// Nothing leaks by sharing a domain with v5-v8. The randomness is public drand and the derivation
// is published, so anybody can already compute their own gnome off chain; that is the point of
// TestSeedForMatchesAnOffChainDerivation. Sharing the domain only means the same inputs give the
// same gnome on two realms, one of which is abandoned.
const seedDomain = "gnogotchi/garden/v7/seed/v1"

// purposeStrings: EVERY purpose literal v7 passes to seedFor, declared once so that the
// properties the independence proof rests on are checkable by a test rather than believed.
// DESIGN.md section 4.2. Three things must hold and each has a test:
// TestPurposeStringsAreDistinct (a duplicate would silently weld two draws together -- bond and
// boast sharing a seed would make a gnome's bond a deterministic function of his boast across
// the whole batch, invisible in any single gnome), TestNoPurposeContainsTheSeparator (so the
// hashed input is uniquely decodable and two distinct (claimant, purpose) pairs can never build
// the same string), and TestEveryPurposeLiteralIsInTheDeclaredList (so a nineteenth draw added
// later cannot escape the other tests).
//
// FROZEN AT DEPLOY, ASYMMETRICALLY: adding a purpose later is impossible (the realm is
// immutable) so this list has to be complete now, and CHANGING one is worse than impossible --
// it would re-roll every gnome already minted.
var purposeStrings = [18]string{
	"slot",         // the named-edition pick                      (v6's, unchanged)
	"eyes",         // eyes, weighted over 100                      (v6's, unchanged)
	"nose",         // nose, weighted over 100                      (v6's, unchanged)
	"hatcoat",      // hat and coat, two 2-bit fields               (v6's, unchanged)
	"temperament",  // axis 0, weighted over 64
	"obsession",    // axis 1, weighted over 64
	"bond",         // axis 2, weighted over 64
	"fear",         // axis 3, weighted over 64
	"boast",        // axis 4, weighted over 64
	"bornunder",    // the card-only sign, weighted over 64
	"dom0",         // Fisher-Yates swap for slot 4, mod 5
	"dom1",         // Fisher-Yates swap for slot 3, mod 4
	"dom2",         // Fisher-Yates swap for slot 2, mod 3
	"dom3",         // Fisher-Yates swap for slot 1, mod 2
	"stats",        // index into the 546 legal stat lines
	"secret",       // the weighted first choice over 17
	"secretstride", // the first-seventeen probe stride, mod 16
	"threshold",    // the care-threshold draw, mod 32
}

// seedFor derives one independent-looking 64-bit value from the published drand randomness, the
// claimant's own address, and a purpose string -- so a single drand round can safely drive
// several unrelated draws (which named edition, which eyes, which nose, which hat/coat, and in
// v7 fourteen more) for several different simultaneous claimants without any of them correlating
// with each other. SIGNATURE, SEPARATOR, ARGUMENT ORDER AND PURPOSE MECHANISM ARE v6's,
// UNCHANGED; only the hash moved (see the block above).
//
// The first eight bytes of the digest, big-endian, assembled by hand rather than through
// encoding/binary so the import list grows by exactly one entry and the byte order is visible in
// the source instead of in a package somebody has to go and read.
func seedFor(randomnessHex string, claimant address, purpose string) uint64 {
	sum := sha256.Sum256([]byte(
		seedDomain + "|" + randomnessHex + "|" + claimant.String() + "|" + purpose))
	return uint64(sum[0])<<56 | uint64(sum[1])<<48 | uint64(sum[2])<<40 |
		uint64(sum[3])<<32 | uint64(sum[4])<<24 | uint64(sum[5])<<16 |
		uint64(sum[6])<<8 | uint64(sum[7])
}

// drawIndex is the one unweighted bounded draw in v7: int64(seed % uint64(n)), and that is all.
// It exists so that every unweighted bounded draw goes through ONE line of arithmetic that one
// person audits once, instead of nine inline % expressions scattered through drawRoll.
//
// ON MODULO BIAS, because this is the line an auditor should stop on. For a uniform 64-bit seed
// and modulus m, the maximum relative deviation of any outcome's probability from 1/m is
// strictly less than m / 2^64. v7's moduli: 2, 4, 16, 32 and 64 divide 2^64 and are therefore
// EXACTLY unbiased; 3 and 5 are under 2.8e-19; 31/38/45 (the secret's weighted total) under
// 2.5e-18; 60 (v6's named pick) under 3.3e-18; 100 (v6's part tables) under 5.4e-18; and 546
// (the stat line), the worst case in the realm, under 3.0e-17 -- about seventeen orders of
// magnitude below the probability that drand's own threshold signature scheme is broken. It is
// not zero and this file does not claim it is.
//
// THIS IS A DECLARED DISAGREEMENT WITH TRAITS.md section 2.2 and section 4.2, both of which
// instruct rejection sampling ("reject a byte >= 256 - 256 mod n", "draw an index 0-545 by
// rejection sampling from ten bits"). Those instructions are right about the draws they were
// written for and the difference is the WIDTH of the draw, not the use of %: from a single BYTE,
// % 5 really does skew one outcome in five by 0.4%, and from TEN BITS against 546 the skew is
// 1.87:1 -- rejection is mandatory in both cases. From a 64-bit draw neither hazard exists at
// any scale anyone can measure. And rejection is not free in the one function that most needs to
// stay simple: it needs a fresh seed per attempt (MORE seed-derivation surface, not less), an
// attempt cap (an unbounded loop in Settle is worse than a 1e-17 bias), and a documented
// deterministic fallback at the cap -- three new things, each with its own failure mode, to
// remove a deviation of one part in 3e16. If a reviewer wants rejection anyway, the change is
// confined to this function and nothing else in the design moves.
func drawIndex(seed uint64, n int64) int64 {
	if n <= 0 {
		panic("garden: drawIndex: n must be positive")
	}
	return int64(seed % uint64(n))
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
// v7: THE DRAW. ONE PURE FUNCTION, THEN v6's COMMIT BLOCK.
// ============================================================================
//
// BATCH-ONE.md:120 names Settle as "the one function MINT.md section 9 names as needing its own
// audit pass above all others", and the row it appears in warns that drawing several weighted
// tables off one random value is "more arithmetic, more surface for an off-by-one or modulo-bias
// bug". THAT WARNING WAS WRITTEN AGAINST FOUR DRAWS. v7 has eighteen, plus a permutation, plus a
// constrained draw. So the shape below is not chosen for elegance; it is chosen so that eighteen
// draws are no harder to audit than four:
//
//	PHASE 1 -- THE DRAW.    drawRoll: one pure function. No tree read, no tree write, no mint,
//	                        no emit, no time.Now(), no cur realm. Everything it needs is an
//	                        argument.
//	PHASE 2 -- THE CHECKS.  assertRoll: every "unreachable" assertion about the result, in one
//	                        block, BEFORE anything is committed.
//	PHASE 3 -- THE COMMIT.  v6's own commit block, plus fourteen field writes taken verbatim
//	                        from the roll. Nothing below that line can fail.
//
// drawRoll BEING PURE IS THE SINGLE MOST VALUABLE PROPERTY IN THIS FILE and it buys four things:
//
//  1. IT IS TESTABLE WITHOUT MINTING ANYTHING. A table-driven test runs it over a large corpus
//     of synthetic randomnessHex values and asserts distributions, with no allowlist, no claim,
//     no beacon fixture and no token. v6 cannot do this: its draw is welded to ledger.Mint, so
//     every distributional test costs a full claim/publish/settle cycle.
//  2. IT IS RE-DERIVABLE OFF CHAIN BY A HOLDER, which is what makes v6 fix 2 (SettledRound)
//     worth anything. Fetch https://api.drand.sh/<chain>/public/<round>, sha256 the signature to
//     get randomnessHex, run the same draws against your own address. If this function is pure,
//     "re-derive it yourself" is a complete instruction. If it read realm state, it would not be.
//  3. AN AUDITOR READS ONE FUNCTION. "Can this realm rig a gnome" is answered by reading
//     drawRoll and checking that settleCore writes the result through unmodified. Nothing in
//     phase 3 can change a trait, because phase 3 has no access to a draw -- only to the roll.
//  4. THE TWO PLACES THAT GENUINELY NEED REALM STATE ARE VISIBLE AS ARGUMENTS, not buried as
//     global reads: batchIndex (settledCount+1) and taken (secretsDrawnMask). THOSE TWO
//     PARAMETERS ARE THE COMPLETE LIST OF ORDER-DEPENDENCE IN v7's DRAW, and being able to see
//     the whole list in a function signature is the point.

// numLegalStatLines: TRAITS.md section 4.2's own count, re-derived from the rule rather than
// quoted -- 670 four-tuples in 1-10 sum to 22, and 546 of those have a stat >= 8 and a stat <= 3.
const numLegalStatLines = 546

// packStatLine / unpackStatLine: four stats, each 1-10, in one int64, one byte each. A packing
// here is safe in the way a packing of the GNOME's fields would not be (see the gnome struct's
// own comment): this word is a deploy-time table entry that no client ever sees and no stored
// gnome ever holds -- settleCore writes the four stats out as four explicit fields.
func packStatLine(a, b, c, d int64) int64 {
	return a<<24 | b<<16 | c<<8 | d
}

func unpackStatLine(packed int64) (a, b, c, d int64) {
	return (packed >> 24) & 0xff, (packed >> 16) & 0xff, (packed >> 8) & 0xff, packed & 0xff
}

// buildLegalStatLines enumerates TRAITS.md section 4.2's legal set ONCE, FROM THE RULE: "22
// points across four stats, each in 1-10, with at least one stat >= 8 and at least one <= 3".
// Four nested loops, four comparisons, 10,000 iterations, at deploy.
//
// TRAITS.md section 4.2's instruction is explicit and this follows it: "enumerate the legal set
// once (it is small and fixed), then draw uniformly from it. Do NOT roll four stats and repair
// them -- a repair loop is a modulo-bias bug and a fairness argument waiting to happen."
//
// THE ENUMERATION ORDER IS FROZEN THE MOMENT THIS REALM DEPLOYS, because drawRoll indexes into
// it. TestLegalStatLineOrderIsStable pins it with a checksum over the whole table.
func buildLegalStatLines() []int64 {
	out := make([]int64, 0, numLegalStatLines)
	for a := statMin; a <= statMax; a++ {
		for b := statMin; b <= statMax; b++ {
			for c := statMin; c <= statMax; c++ {
				for d := statMin; d <= statMax; d++ {
					if a+b+c+d != statPointTotal {
						continue
					}
					hi, lo := a, a
					// Three elements, not numStats: `a` is already seeded into hi and lo
					// above. An array sized numStats here would have a fourth, zero-valued
					// element, which would make `lo` zero for every row and silently drop the
					// "at least one stat <= 3" constraint -- 546 rows would become 586 and
					// nothing would fail except a count. Found by the init() deploy gate while
					// building this file, recorded rather than quietly fixed.
					for _, v := range [3]int64{b, c, d} {
						if v > hi {
							hi = v
						}
						if v < lo {
							lo = v
						}
					}
					// The two extra constraints are what kill 6/5/6/5 -- "a gnome with no
					// strength and no weakness, who is the one card nobody ever plays".
					if hi < statHighAtLeast || lo > statLowAtMost {
						continue
					}
					out = append(out, packStatLine(a, b, c, d))
				}
			}
		}
	}
	return out
}

// roll is everything one claimant's draw produces: one field per stored value, and nothing else.
// It is a plain value with no pointers and no realm state, returned by drawRoll and consumed by
// assertRoll and settleCore's commit block.
type roll struct {
	temperament int64
	obsession   int64
	bond        int64
	fear        int64
	boast       int64

	dominance [numAxes]int64

	secret int64

	pluck    int64
	nous     int64
	grumble  int64
	appetite int64

	careThresholdDraw int64
	bornUnder         int64
	batchIndex        int64
}

// drawRoll is PHASE 1: the whole audit surface for v7's fairness, as a pure function of its four
// arguments. The draws are listed in the order they are computed, which is fixed -- NOTHING
// DEPENDS ON THE ORDER, because every draw has its own purpose string and therefore its own
// seed, so reordering them would change nothing -- but it is fixed anyway, because a fixed order
// is what makes "re-derive it yourself" a checkable instruction.
//
// batchIndex is settledCount+1 and taken is secretsDrawnMask; both are passed in, and they are
// the only order-dependent inputs in the whole draw. Everything else is (randomnessHex,
// claimant), which is fixed the instant the pinned round is signed by drand.
func drawRoll(randomnessHex string, claimant address, batchIndex int64, taken uint32) roll {
	var r roll
	r.batchIndex = batchIndex

	// The five axes and born-under: six weighted draws over six 64-wide tables, each with its
	// own seed. 64 divides 2^64, so each of these carries exactly zero modulo bias.
	r.temperament = int64(drawWeighted(temperamentWeights[:], axisTotalWeight, seedFor(randomnessHex, claimant, "temperament")))
	r.obsession = int64(drawWeighted(obsessionWeights[:], axisTotalWeight, seedFor(randomnessHex, claimant, "obsession")))
	r.bond = int64(drawWeighted(bondWeights[:], axisTotalWeight, seedFor(randomnessHex, claimant, "bond")))
	r.fear = int64(drawWeighted(fearWeights[:], axisTotalWeight, seedFor(randomnessHex, claimant, "fear")))
	r.boast = int64(drawWeighted(boastWeights[:], axisTotalWeight, seedFor(randomnessHex, claimant, "boast")))
	r.bornUnder = int64(drawWeighted(bornUnderWeights[:], axisTotalWeight, seedFor(randomnessHex, claimant, "bornunder")))

	// The dominance permutation: four draws, four distinct seeds, four DESCENDING moduli.
	r.dominance = dominanceFor(randomnessHex, claimant)

	// The stat line: one uniform index into the 546 legal lines, unpacked into four explicit
	// values. The index is never stored (see the gnome struct).
	statIdx := drawIndex(seedFor(randomnessHex, claimant, "stats"), int64(len(legalStatLines)))
	r.pluck, r.nous, r.grumble, r.appetite = unpackStatLine(legalStatLines[statIdx])

	// The secret: weighted toward the ones that undercut this gnome's OWN rolled boast or fear,
	// and distinct from every secret already drawn if this is one of the first seventeen settles.
	// THIS IS THE ONLY DRAW THAT READS ANY REALM STATE, and it reads it as the `taken` argument.
	r.secret = secretFor(randomnessHex, claimant, r.boast, r.fear, batchIndex, taken)

	// The care threshold draw: 0-31, flat, 32 divides 2^64. Stored, read by nothing.
	r.careThresholdDraw = drawIndex(seedFor(randomnessHex, claimant, "threshold"), careThresholdSpan)

	return r
}

// dominanceFor draws the dominance order: Fisher-Yates over {0,1,2,3,4}, descending -- swap slot
// 4 with a slot drawn from 0-4, slot 3 with one from 0-3, slot 2 from 0-2, slot 1 from 0-1. Four
// draws, four distinct seeds, four distinct moduli.
//
// TRAITS.md section 2.2's two prohibitions are both honoured and both are worth restating as the
// things NOT to do:
//
//   - NOT seed % 120. 120 is not a power of two, and more importantly a single index would need
//     the Lehmer codec the gnome struct's own comment rejects.
//   - NOT seed % 5 FIVE TIMES. That maps 5^5 = 3,125 outcomes onto 120 permutations
//     non-uniformly and is the classic naive-shuffle bug. Four descending moduli is the correct
//     Fisher-Yates, and TestDominanceMatchesAnIndependentFisherYates compares this against a
//     reference implementation written separately, which is the only way to catch somebody
//     reintroducing the naive version later.
//
// ALL 120 ORDERS ARE LEGAL, so there is no post-draw constraint, no rejection and no loop. That
// is the realm-side dividend of TRAITS.md section 2.1's two-state recommendation, and it is a
// stronger argument for two states than any of the four section 2.1 gives: under THREE states
// with FUNNY.md section 6.5's fix applied, only 96 of the 120 orders would be legal (every order
// except the twenty-four that put Temperament in the single dormant slot), and an illegal-order
// exclusion is a REJECTION LOOP INSIDE THE DRAW -- Fisher-Yates, then a check, then a redraw --
// with an unbounded worst case and a fallback nobody wants to specify, in the one function
// BATCH-ONE.md:120 is a warning about. Two states make all 120 legal, so the draw has no
// constraint, no check and no loop.
func dominanceFor(randomnessHex string, claimant address) [numAxes]int64 {
	order := [numAxes]int64{0, 1, 2, 3, 4}
	// i counts down over the slots still to be fixed; the modulus descends 5, 4, 3, 2.
	for i := numAxes - 1; i >= 1; i-- {
		j := drawIndex(seedFor(randomnessHex, claimant, "dom"+strconv.Itoa(numAxes-1-i)), int64(i+1))
		order[i], order[j] = order[j], order[i]
	}
	return order
}

// secretWeightsFor builds one gnome's secret weight table from TRAITS.md section 3.3's rule:
// base weight 1 for all seventeen, MULTIPLIED BY 8 if the secret's target matches this gnome's
// rolled boast or rolled fear. One multiplier, one comparison, no second table.
//
// The total it returns is 31 + 7k with k in {0, 1, 2} -- 31, 38 or 45 and NO OTHER VALUE -- which
// is the check that the table is right, because every gnome's boast carries exactly two secrets
// and k is the number aimed at his rolled fear (2 for Beetles, 1 for Being Forgotten / Being
// Laughed At / Slugs, 0 for The Dark and Shine). TestSecretWeightTotalIsAlwaysThirtyOneOrThirtyEightOrFortyFive
// pins exactly that over every (boast, fear) pair, exhaustively.
//
// THIS IS THE ONE PLACE IN v7 WHERE TRAIT DATA IS COMPARED TO ANYTHING, and it is worth being
// precise about what the comparison is and is not: it reads a gnome's own just-drawn boast and
// fear, and it produces a weight table that produces a secret id. It gates nothing, it changes no
// fee, it grants no eligibility, and it never sees another gnome. The invariant stated once:
// NO FUNCTION IN v7 BRANCHES ON A TRAIT, A STAT, A LINEAGE EDGE OR A SECRET -- not in a guard,
// not in a loop condition, not in a fee calculation, not in an eligibility check -- and this
// weighting is the single exception the invariant is written around.
func secretWeightsFor(boast, fear int64) ([numSecrets]int64, int64) {
	var w [numSecrets]int64
	total := int64(0)
	for i := 0; i < numSecrets; i++ {
		weight := secretBaseWeight
		if secretTargetKind[i] == secretTargetKindBoast && secretTargetID[i] == boast {
			weight = secretBaseWeight * secretMatchMultiplier
		}
		if secretTargetKind[i] == secretTargetKindFear && secretTargetID[i] == fear {
			weight = secretBaseWeight * secretMatchMultiplier
		}
		w[i] = weight
		total += weight
	}
	return w, total
}

// secretFor is the one genuinely new mechanism in v7 and the one to read twice.
//
// THE RULE BEING IMPLEMENTED (TRAITS.md section 3.2.2, agreed by the owner 2026-10-17): "The
// first seventeen mints draw seventeen distinct secrets. For tokens 1-17 the weighted draw of
// section 3.3 runs over the not-yet-drawn subset of the pool only. From token 18 onward the draw
// is the full seventeen with duplicates free."
//
// IT IS NOT IMPLEMENTED AS THE LITERAL SUBSET DRAW, and the reason is the flaw v6 exists to
// document. A renormalised weighted draw over the free secrets has a modulus of "the sum of the
// weights of the free secrets" -- A SHRINKING, OBSERVABLE, TIME-VARYING NUMBER, which is v6's
// package doc word for word: "THAT IS PEEKABLE AND GAMEABLE... a claimant whose seed is already
// fixed can simply precompute, for every possible remainingTotal, whether that value would win
// them [the thing they want] -- and then wait, costing nothing." Worse, it is not monotone:
// removing a secret reshuffles which index every seed maps to, so waiting CAN improve the
// outcome. It would also need DIFFERENT ARITHMETIC IN THE TWO PATHS -- a filtered cumulative
// walk for the first seventeen and an unfiltered one for the rest -- which is BATCH-ONE.md:120's
// warning exactly.
//
// Instead: one weighted walk, called IDENTICALLY by the first gnome and the sixtieth, plus a
// probe with a fall-through made of two modulos by compile-time constants. THE PROBE IS NOT A NEW
// INVENTION: it is v6's own audited named-edition pattern generalised -- draw against a constant
// modulus; if what you drew is taken, fall through -- with the fall-through made a full cycle
// instead of one step deep.
//
// SIX PROPERTIES, EACH WITH ITS PROOF, because this is where the audit will live.
//
//	P1 -- IT ALWAYS TERMINATES, AND INSIDE THE WINDOW IT ALWAYS RETURNS A FREE SECRET. The loop
//	is bounded at numSecrets iterations by construction. Inside the window at most
//	batchIndex-1 <= 16 bits of `taken` are set, and by P2 the walk visits all seventeen ids, so
//	at least one is free. The panic below is therefore unreachable; it is named rather than
//	omitted, v6's own discipline.
//
//	P2 -- THE WALK VISITS ALL SEVENTEEN. numSecrets = 17 is PRIME, so gcd(stride, 17) = 1 for
//	every stride in [1, 16], so {first + i*stride mod 17 : i = 0..16} is all of Z/17.
//	TestSecretProbeVisitsAllSeventeen proves it EXHAUSTIVELY over all 17 x 16 = 272 (first,
//	stride) pairs, and TestSecretPoolSizeIsPrime pins the precondition.
//
//	P3 -- THE STRIDE DRAW HAS EXACTLY ZERO MODULO BIAS. 16 divides 2^64.
//
//	P4 -- THE ONLY REALM STATE CONSULTED IS `taken`, AND ONLY INSIDE THE WINDOW. drawRoll takes
//	it as an argument. There is no other global read anywhere in the draw.
//
//	P5 -- MONOTONICITY: WAITING CAN NEVER IMPROVE A CLAIMANT'S OUTCOME. `taken` only ever gains
//	bits. A claimant's probe ORDER is fixed by his own seed the instant the pinned round
//	publishes and cannot change. So if T1 is a subset of T2, the first free id in a given walk
//	under T1 sits at an index less than or equal to its index under T2. THERE IS NO
//	SETTLE-TIMING STRATEGY HERE, which is the exact property v6's package doc identifies as the
//	one that matters ("nobody can improve THEIR OWN odds by choosing when to settle") -- and in
//	the stronger direction, because the incentive actively points at settling promptly rather
//	than merely being indifferent. TestSecretIsMonotoneUnderWaiting is the proof.
//
//	P6 -- THE RESIDUAL, STATED PRECISELY AND NOT ASPIRATIONALLY. A third party can settle OTHER
//	claims before a claimant settles his, pushing him further down his own fixed probe list.
//	That costs the griefer gas and buys him nothing, and the ceiling on the harm is TRAITS.md
//	section 3.2.2 note 1's own already-accepted cost: "his gnome may hold a secret that
//	undercuts nothing he says." All seventeen secrets are one line each and note 2 is explicit
//	that "nobody's secret is better than anybody else's" -- so this is a transaction-ordering
//	race over an outcome with no prize, the same category v6 already analysed and accepted for
//	the named-edition collision, at strictly lower stakes.
//
// WHAT THE DEVIATION FROM THE LITERAL RULE COSTS, measured rather than waved at: the probe and
// the subset draw agree EXACTLY at batchIndex 1 (nothing taken, so both are the plain weighted
// draw) and are FORCED IDENTICALLY at batchIndex 17 (a pool of one). In between they differ only
// in WHICH free secret a claimant lands on, never in how many free secrets there are. TRAITS.md
// section 3.2.2 note 1 has already priced that as "a fractional softening of a soft rule" against
// "a guaranteed solvable acrostic".
func secretFor(randomnessHex string, claimant address, boast, fear, batchIndex int64, taken uint32) int64 {
	// STEP 1. The weighted first choice. IDENTICAL CODE, IDENTICAL TABLE, IDENTICAL MODULUS for
	// the first gnome and the sixtieth.
	w, total := secretWeightsFor(boast, fear)
	first := int64(drawWeighted(w[:], total, seedFor(randomnessHex, claimant, "secret")))

	// STEP 2. Past the forced window, that is the answer. Duplicates free.
	if batchIndex > firstDistinctCount {
		return first
	}

	// STEP 3. Inside it, walk THIS CLAIMANT'S OWN probe sequence to the first free secret.
	stride := 1 + drawIndex(seedFor(randomnessHex, claimant, "secretstride"), int64(numSecrets-1))
	id := first
	for i := 0; i < numSecrets; i++ {
		if taken&(1<<uint(id)) == 0 {
			return id
		}
		id = (id + stride) % numSecrets
	}
	// Unreachable by P1 above. Named rather than omitted so this function is correct on its own
	// terms: if it ever fires, something has written secretsDrawnMask outside the one place that
	// may, and aborting is better than minting a gnome with a duplicate secret inside the window
	// the acrostic depends on.
	panic("garden: the first seventeen secret pool is exhausted; refusing to mint")
}

// assertRoll is PHASE 2: every range assertion about a roll, in one block, before anything is
// committed. EVERY ONE OF THESE IS UNREACHABLE IF drawRoll IS CORRECT -- which is exactly v6's
// own discipline for its batch-accounting check ("named so this function is correct on its own
// terms"), and it means a drawRoll bug produces a LOUD ABORT rather than a silently malformed
// gnome that can never be fixed, on a realm that cannot be edited.
//
// taken is the SAME secretsDrawnMask that was handed to drawRoll, and it is here for the one
// assertion that range-checking cannot express: FREEDOM, not merely range. See the secret check
// below for why this one abort has to happen on the offending mint rather than one settle later.
func assertRoll(r roll, taken uint32) {
	if r.temperament < 0 || r.temperament >= int64(len(temperamentWeights)) {
		panic("garden: roll check: temperament out of range; refusing to mint")
	}
	if r.obsession < 0 || r.obsession >= int64(len(obsessionWeights)) {
		panic("garden: roll check: obsession out of range; refusing to mint")
	}
	if r.bond < 0 || r.bond >= int64(len(bondWeights)) {
		panic("garden: roll check: bond out of range; refusing to mint")
	}
	if r.fear < 0 || r.fear >= int64(len(fearWeights)) {
		panic("garden: roll check: fear out of range; refusing to mint")
	}
	if r.boast < 0 || r.boast >= int64(len(boastWeights)) {
		panic("garden: roll check: boast out of range; refusing to mint")
	}
	if r.bornUnder < 0 || r.bornUnder >= int64(len(bornUnderWeights)) {
		panic("garden: roll check: bornUnder out of range; refusing to mint")
	}

	// The permutation check the five-slot encoding needs and a Lehmer index would not: every
	// axis index 0..4 present exactly once.
	var seen [numAxes]bool
	for _, slot := range r.dominance {
		if slot < 0 || slot >= numAxes {
			panic("garden: roll check: dominance holds a value that is not an axis index; refusing to mint")
		}
		if seen[slot] {
			panic("garden: roll check: dominance is not a permutation; refusing to mint")
		}
		seen[slot] = true
	}

	if r.secret < 0 || r.secret >= numSecrets {
		panic("garden: roll check: secret out of range; refusing to mint")
	}

	// AUDIT-01 YELLOW-3: INSIDE THE WINDOW, THE SECRET MUST ALSO BE FREE. Unreachable if
	// secretFor is correct -- its probe returns the first id with a clear bit in `taken`, or
	// aborts -- but the range check above cannot see a duplicate, and the consequence of not
	// seeing one is not local. settleCore's popcount check fires at the TOP of a settle, so a
	// taken id drawn inside the window would mint SUCCESSFULLY (range ok, `mask |= 1 << secret`
	// a no-op, settledCount++ lands) and then panic EVERY SUBSEQUENT SETTLE forever: there is no
	// admin mint, no migration and no repair path, so one malformed gnome would be a permanent
	// denial of the rest of the mint. Checking it here aborts ONLY the offending mint, which is
	// this function's own stated discipline -- a loud abort rather than a silently malformed
	// gnome. The downstream popcount assertion stays as well; it is cheap, and it is a genuine
	// second line against a write to the mask from somewhere this check cannot see.
	if r.batchIndex <= firstDistinctCount && taken&(1<<uint(r.secret)) != 0 {
		panic("garden: roll check: the drawn secret is already taken inside the first seventeen; refusing to mint")
	}

	// The stats, against the rule rather than against the table they came from -- so a corrupt
	// table entry is caught here too, not merely a corrupt index.
	stats := [numStats]int64{r.pluck, r.nous, r.grumble, r.appetite}
	sum, hi, lo := int64(0), stats[0], stats[0]
	for _, v := range stats {
		if v < statMin || v > statMax {
			panic("garden: roll check: a stat is outside 1-10; refusing to mint")
		}
		sum += v
		if v > hi {
			hi = v
		}
		if v < lo {
			lo = v
		}
	}
	if sum != statPointTotal {
		panic("garden: roll check: the four stats do not sum to 22; refusing to mint")
	}
	if hi < statHighAtLeast || lo > statLowAtMost {
		panic("garden: roll check: the stat line is not spiky (needs one >= 8 and one <= 3); refusing to mint")
	}

	if r.careThresholdDraw < 0 || r.careThresholdDraw >= careThresholdSpan {
		panic("garden: roll check: the care threshold draw is outside 0-31; refusing to mint")
	}
	if r.batchIndex < 1 || r.batchIndex > batchCap {
		panic("garden: roll check: batchIndex is outside 1-" + strconv.FormatInt(batchCap, 10) + "; refusing to mint")
	}
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
// and refused for the eight named one-of-ones and the genesis gnome.
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

	// THE EIGHT NAMED ONE-OF-ONES KEEP THEIR CHARACTER NAME, PERMANENTLY. Hob is Hob; that is
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
// gnome to choose among, and plus the lockCaredDays check on the eight named one-of-ones.
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
		// THIS MESSAGE SAYS THE ROSTER SIZE OUT LOUD, which makes it the FOURTH place v7 change 10
		// had to edit (after namedEditionOrder, namedEditionDisplayNames and reservedNameKeys) and
		// the one the existing comments did not warn about. The test suite's lockedMsg helper
		// mirrors this string byte-for-byte, so a change here that is not made there fails
		// TestNamedOneOfOneCannotBeListedBeforeTheLockClears rather than shipping.
		panic("garden: " + g.character + " is one of the eight named one-of-ones and cannot be listed until it has " +
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
// unpaginated deliberately: batchCap is 60 (v7's own number -- v5 and v6 argued this at 24) and
// the genesis gnome is permanently unreachable to any wallet, so no address can ever hold more
// than batchCap tokens. Sixty token ids in one return is still a small, fixed,
// compile-time-bounded list well inside what a single read returns. THE NUMBER IN THIS COMMENT
// IS PART OF THE DELIVERABLE: a false comment on an immutable realm is permanent.
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

// CharacterOwner resolves one of the eight named one-of-ones, or the genesis gnome under its
// own name "gaffer", to its tokenID, once minted. (Second-audit-pass nitpick: an earlier
// version of this comment said only "one of the three named one-of-ones", which stopped being
// true the moment init() registered "gaffer" here too -- see init()'s own comment for why that
// registration is safe and never touches the editions' cap. The count in it then went stale a
// second way when v7 change 10 took the roster to eight; both are fixed here.)
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
// namedMinted is how many of the eight named one-of-ones have actually been minted so far --
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

// ============================================================================
// v7: THE TRAIT READERS, AND THE SHAPE RULE THEY ALL OBEY.
// ============================================================================
//
// GAMES.md:38 is unambiguous -- "ship enumerators on day one; they cannot be added later
// (arena/v1 lacks them, forever)" -- so this list is complete and this is the only chance to get
// it right. Granular, one axis-group per call, matching GnomeByToken's style: explicit typed
// returns, no parsing, and `found` reporting whether the TOKEN exists and never whether a field
// is interesting. No v6 tuple is widened: "the app already reads v5's shapes, and widening a
// tuple return breaks every existing caller for no gain that a dedicated reader does not already
// give. Reads are free and unmetered, so 'one more query' costs a caller nothing; a changed
// signature costs them a rewrite."
//
// THE SHAPE RULE, STATED ONCE SO IT CAN BE CHECKED. Enumerate-and-read is permitted; QUERY IS
// NOT. Every reader in v7 is one of exactly four shapes:
//
//	1. X(tokenID)                      -- the stored facts about one token the caller named
//	2. TotalX() / XPage(offset, limit) -- a count and a window over a collection, in its own order
//	3. X(someKey)                      -- one index lookup on a key that is NOT a trait: an
//	                                      address, a name, a batch index, a part id
//	4. X()                             -- a realm constant
//
// THERE IS NO FIFTH SHAPE. In particular: no reader that takes a trait, a stat, a secret, a kin
// type or a predicate and returns the gnomes matching it, and NO READER THAT TAKES TWO TOKEN
// IDS. That is what makes TraitCensus, rarityScore, LineCount, IsKin, KinOf, "find me every
// gnome with fear 3" and every kin-bonus/related-pair/shared-quest feature STRUCTURALLY ABSENT
// rather than merely omitted -- they all need a shape this realm does not have.
//
// DELIBERATELY ABSENT, and this is the list to check a future version against: CareThreshold,
// CareScore, Band, PointsToThreshold and anything returning a fraction or remainder of any of
// them (TRAITS.md section 5.1's whole design is that there is nothing to put a countdown on);
// SecretCount, SecretCensus, HoldersOfSecret, IsFirstSeventeen and anything exposing
// secretsDrawnMask (an owner who can see which secrets are taken deduces others' by
// elimination); Label and Archetype (TRAITS.md section 2.3: the label is derived off chain,
// never stored, and a realm function returning it would make the two label-word columns
// unrewritable forever); TraitsMatching and every filter or predicate; any unique-in-batch or
// scarcest-in-batch marker (TRAITS.md section 2.3 recommends against building it at all at
// n = 60, where it fires about once per four hundred cards, and notes the honest alternative is
// "a rarity count wearing a hat"); KinOf, IsKin, LineOf, LineCount, KinCount and anything
// returning a degree; and any name, label or definition for any trait id.

// Traits returns the five rolled axis ids, in AXIS order (0 temperament, 1 obsession, 2 bond,
// 3 fear, 4 boast) and NOT in dominance order. All five are 0 for the genesis gnome, which is
// the one token never produced by a roll.
func Traits(tokenID string) (temperament, obsession, bond, fear, boast int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, 0, 0, false
	}
	return g.temperament, g.obsession, g.bond, g.fear, g.boast, true
}

// Dominance returns the five axis indexes 0..4 in DOMINANCE order: `first` is the loudest.
// Where the loud/latent boundary falls is an OFF-CHAIN reading of this number and is not stored
// (TRAITS.md sections 2.1 and 2.2) -- which is exactly what keeps two-states-versus-three
// reversible after deploy, in either direction, for free.
func Dominance(tokenID string) (first, second, third, fourth, fifth int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, 0, 0, false
	}
	return g.dominance[0], g.dominance[1], g.dominance[2], g.dominance[3], g.dominance[4], true
}

// Stats returns the four Top Trumps stats. They sum to 22, one is >= 8 and one is <= 3.
// NOTHING IN ANY REALM COMPARES TWO GNOMES' STATS: there is no Top Trumps game on chain, no
// reader here takes two token ids, and TRAITS.md section 4.5's tie rule is social.
func Stats(tokenID string) (pluck, nous, grumble, appetite int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, 0, 0, 0, false
	}
	return g.pluck, g.nous, g.grumble, g.appetite, true
}

// Secret returns the gnome's secret id, 0..16. THE NAME AND THE LINE LIVE OFF CHAIN
// (TRAITS.md section 3.2); this realm stores and returns the id and nothing else. There is no
// count of who holds what and no way to ask which secrets are still unheld.
func Secret(tokenID string) (secretID int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, false
	}
	return g.secret, true
}

// BornUnder returns the card-only sign id, 0..7. It is not an axis, has no slot in the dominance
// order, and is never handed to the dialogue layer (TRAITS.md section 1.6) -- the realm
// guarantees the middle clause structurally and the last one is an off-chain discipline.
func BornUnder(tokenID string) (sign int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, false
	}
	return g.bornUnder, true
}

// BatchIndex returns this gnome's 1..60 position in Batch One, which is the key LINEAGE.md
// section 2.4's kinship table is written against. 0 for the genesis gnome, which is outside the
// batch and is the only token for which this is ever 0.
func BatchIndex(tokenID string) (index int64, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return 0, false
	}
	return g.batchIndex, true
}

// TokenByBatchIndex is BatchIndex inverted: the token carrying a batch position, or found=false
// if that position has not been settled yet. Both directions ship because a client rendering a
// holder's cousins has batch indexes from the kinship table and needs token ids, and a client
// rendering one gnome's card has a token id and needs its index.
func TokenByBatchIndex(index int64) (tokenID string, found bool) {
	tid, ok := batchIndexToToken.Get(strconv.FormatInt(index, 10)).(string)
	if !ok || tid == "" {
		return "", false
	}
	return tid, true
}

// TraitsCsv returns all seventeen stored trait numbers in one query, in a fixed, test-pinned
// order, for a client rendering a card -- the same CSV shape GardenState and CaredDays already
// use. It exists because TRAITS.md section 6.2's card renders these fields at once and six round
// trips to draw one card is silly when one would do.
//
// It is a CONVENIENCE OVER THE SAME STORED VALUES, not a second source of truth, and
// TestTraitsCsvAgreesWithEveryGranularReader pins that -- the same discipline NameAvailability
// already follows against SetName.
//
// THE CARE THRESHOLD IS NOT IN IT and has no reader anywhere. Neither is anything derived from
// it, and neither is a name, a label or an archetype.
//
//	temperament,obsession,bond,fear,boast,
//	dom1,dom2,dom3,dom4,dom5,
//	secret,pluck,nous,grumble,appetite,bornUnder,batchIndex
func TraitsCsv(tokenID string) (csv string, found bool) {
	g, ok := gnomeByTokenID(tokenID)
	if !ok {
		return "", false
	}
	fields := []int64{
		g.temperament, g.obsession, g.bond, g.fear, g.boast,
		g.dominance[0], g.dominance[1], g.dominance[2], g.dominance[3], g.dominance[4],
		g.secret, g.pluck, g.nous, g.grumble, g.appetite, g.bornUnder, g.batchIndex,
	}
	parts := make([]string, 0, len(fields))
	for _, v := range fields {
		parts = append(parts, strconv.FormatInt(v, 10))
	}
	return strings.Join(parts, ","), true
}

// ============================================================================
// v7: THE KINSHIP ENUMERATORS, AND THEY ARE THE ONLY WAY IN.
// ============================================================================
//
// LINEAGE.md section 6.2 argues that the day-one enumerator rule is a TRAP here: "Store the web
// and you must ship KinOf(tokenID) on day one; ship KinOf and it exists forever; and the first
// third-party UI to find it will build LineCount() on top of it within a week." The OVERRULED
// box moved the position on storing but left section 6.5's prohibitions standing, so the design
// has to satisfy both -- and it does, by a distinction that is not a dodge:
//
//   - KinOf(tokenID) is an ANSWER ABOUT A GNOME. KinEdgesPage(offset, limit) is THE TABLE. The
//     first is the shape a contract calls. The second is the shape a RENDERER calls: it takes no
//     token, no address and no pair, and it cannot be given one. A client that wants a holder's
//     cousins reads 84 rows once, caches them, and filters locally -- precisely what it already
//     does with the published Markdown today, except now the rows are owned, dated by a block
//     height, and readable by any realm that wants the DATA rather than an answer.
//   - NOTHING IS FORECLOSED THAT WAS NOT ALREADY OPEN. A third party can of course build KinOf
//     on top of 84 rows; they could build it on top of the published document too. Section 6.2's
//     concern was never that the data is derivable, it was that A REALM FUNCTION would exist for
//     a contract to call and a UI to find without looking.
//   - THE LOAD-BEARING LINE STILL HOLDS EXACTLY: "no entrypoint anywhere in any realm that
//     behaves differently for two related gnomes than for two strangers." v7 has none, cannot
//     grow one, and these two functions are not one -- they do not take a gnome.

// TotalKinEdges returns 84. The table is fixed at deploy and this number never changes.
func TotalKinEdges() int64 { return numKinEdges }

// KinEdgesPage returns rows "from,to,typeId" -- batch indexes, not token ids; type ids, not
// words -- in the table's own order (LINEAGE.md section 2.4's own row order), offset/limit
// paginated exactly as TokensPage and ListingsPage already are, with the same refusals.
func KinEdgesPage(offset, limit int) []string {
	if offset < 0 {
		panic("garden: offset must not be negative")
	}
	if limit <= 0 {
		panic("garden: limit must be positive")
	}
	if limit > maxKinEdgesPageSize {
		limit = maxKinEdgesPageSize
	}
	out := make([]string, 0, limit)
	for i := offset; i < len(kinEdges) && len(out) < limit; i++ {
		e := kinEdges[i]
		out = append(out, strconv.FormatInt(e.from, 10)+","+
			strconv.FormatInt(e.to, 10)+","+
			strconv.FormatInt(e.typ, 10))
	}
	return out
}

// TotalKinTypes returns 9, LINEAGE.md section 2.4's closed vocabulary.
func TotalKinTypes() int64 { return numKinTypes }

// KinTypeName maps a type id to its one word. The declared exception to "wording off chain" --
// see kinTypeNames' own comment for the three-part argument and for how to remove it in one
// edit if the owner prefers the strictest reading.
func KinTypeName(typeID int64) (name string, found bool) {
	if typeID < 0 || typeID >= numKinTypes {
		return "", false
	}
	return kinTypeNames[typeID], true
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
// v7 EXTENDS Render WITH ONE PATH -- a token id -- AND THREE CONSTRAINTS, all of which are the
// forbidden list restated for the one function that produces human-facing output:
//
//   - NO THRESHOLD, NO SCORE, NO BAND, NO FRACTION, NO REMAINDER. TRAITS.md section 6.2: "Never
//     on the card, in any version: ... the care score, the care threshold, or anything derived
//     from either."
//   - NO CENSUS, NO DISTRIBUTION, NO COUNT OF ANYTHING TRAIT-SHAPED, and specifically no
//     unique-in-batch or scarcest-in-batch marker.
//   - IDS, NOT NAMES. This function prints the numbers it stores. It does not get a copy of the
//     thirty-two public names, the seventeen secret names or the eight signs, because that would
//     put revisable wording on an immutable realm -- the whole point of the split. Rendering
//     "Thistle" instead of 7 is the app's job, from TRAITS.md's own tables.
//
// AND IT STILL ECHOES NO PLAYER-SUPPLIED STRING: an unknown path returns a fixed message with
// the path omitted, exactly as v6's did, so the markdown sink stays unreachable from player
// input even though this function now takes a path that resolves.
func Render(path string) string {
	if path != "" {
		// A token id, or nothing. The path is never echoed back -- see the comment above.
		if csv, ok := TraitsCsv(path); ok {
			g, _ := gnomeByTokenID(path)
			out := "# Gnotchi gnome\n\n"
			out += "Batch One position: " + strconv.FormatInt(g.batchIndex, 10) + " of " + strconv.FormatInt(batchCap, 10) + "\n\n"
			out += "Settled at drand round: " + strconv.FormatInt(g.settledRound, 10) + "\n\n"
			out += "Axes (temperament, obsession, bond, fear, boast), as ids: " +
				strconv.FormatInt(g.temperament, 10) + ", " + strconv.FormatInt(g.obsession, 10) + ", " +
				strconv.FormatInt(g.bond, 10) + ", " + strconv.FormatInt(g.fear, 10) + ", " +
				strconv.FormatInt(g.boast, 10) + "\n\n"
			out += "Dominance order (axis indexes, loudest first): " +
				strconv.FormatInt(g.dominance[0], 10) + ", " + strconv.FormatInt(g.dominance[1], 10) + ", " +
				strconv.FormatInt(g.dominance[2], 10) + ", " + strconv.FormatInt(g.dominance[3], 10) + ", " +
				strconv.FormatInt(g.dominance[4], 10) + "\n\n"
			out += "Stats (pluck, nous, grumble, appetite): " +
				strconv.FormatInt(g.pluck, 10) + ", " + strconv.FormatInt(g.nous, 10) + ", " +
				strconv.FormatInt(g.grumble, 10) + ", " + strconv.FormatInt(g.appetite, 10) + "\n\n"
			out += "Secret id: " + strconv.FormatInt(g.secret, 10) + "\n\n"
			out += "Born under (sign id): " + strconv.FormatInt(g.bornUnder, 10) + "\n\n"
			out += "All of the above as one CSV: " + csv + "\n\n"
			out += "The names for these ids live in TRAITS.md, off chain and still revisable. " +
				"This realm stores and prints the numbers.\n"
			return out
		}
		return "garden/v9: unknown path"
	}
	minted, settled, cap_, namedMinted, namedCap := BatchStatus()
	out := "# Gnotchi gnomes -- garden/v9\n\n"
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
// (batchCap = 60 tokens that will ever exist, minus the one permanently unreachable genesis
// gnome, so no owner's slice is ever longer than 60 entries for the whole life of this realm --
// v5 and v6 argued the identical point at 24; only the number moved).
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
// 60-gnome collection does not justify it. The defence that IS in place for the case that
// actually matters -- the eight cap-one editions -- is that their names are reserved and
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
