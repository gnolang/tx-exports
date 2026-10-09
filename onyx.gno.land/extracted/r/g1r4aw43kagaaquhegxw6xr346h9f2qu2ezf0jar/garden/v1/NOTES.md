# Notes against the audit — realms/garden

Things the audit surfaced that are product decisions, not engineering ones. Written here
per the owner's own rule (NOTES.md at repo root): checked facts and open trade-offs that
the pack/audit doesn't resolve go in a NOTES.md, not silently into code.

## Open question: a realm can permanently own a gnome on behalf of no one (2026-10-09)

**Status: unresolved. Needs the owner's decision before this realm goes near a chain.**

`Adopt` derives the caller as `cur.Previous().Address()` (`garden.gno:230`, doc at
`garden.gno:188-195`) — "the account that crossed into this realm", matching
`examples/gno.land/r/demo/foo721`'s own idiom for caller identity. That address is not
restricted to an externally-owned account (a human holding a key). **Any realm** can call
`Adopt` the same way a human would, and `cur.Previous().Address()` then resolves to that
calling realm's own address, not to any human behind it.

Combine that with two things this realm does deliberately, by design, per the brief's
"what it needs, and nothing more":

- **No transfer.** `soulboundExtension.OnTransfer` panics unconditionally (rule 6, "every
  transfer fails"). This is load-bearing and correct — it's the whole soulbound guarantee
  the brief asks for.
- **No burn, no admin, no rename.** There is no path, for anyone, to undo an `Adopt` once
  it lands.

Put together: if a realm (not a human) ever calls `Adopt` — whether on purpose, by a bug
in that realm, or because some future UI flow proxies a user's call through an
intermediate realm without meaning to — **that realm's own address becomes the permanent,
unrecoverable owner of a gnome.** No human can ever claim it. No key held by any person
unlocks it. It is not stuck in a recoverable sense (the audit found no reentrancy, no
capability leak, no exposed transfer that would make it *worse*); it is correctly,
permanently inaccessible to the person who might have expected to own it. The audit
flagged this as **unfixable within this realm's current design** — there is no check this
code can add that distinguishes "a human's wallet called this" from "a realm called this
and the human never sees the result" without also restricting legitimate future
composition (another realm adopting *on behalf of* a verified human, a batching/sponsor
flow, etc.).

### The trade-off, stated plainly

- **Restrict `Adopt` to human (EOA) callers only** — e.g. require some check along the
  lines of "this frame is a plain `maketx call`, not a realm-to-realm crossing call"
  before minting. `cur.Previous().IsUserCall()` is the name used for this in
  `pack/01-build-brief/gnogotchi-build-brief.md` and `pack/08-research/01-gno-land-platform.md`,
  but this engineering pass has not independently verified, against this repo's actual
  Gno toolchain, that a method of that name exists on `realm`/`cur.Previous()` — it is
  recorded here as the pack's own suggested name, not as a confirmed API this realm could
  call today. Verify it against the real SDK/runtime before relying on it. This closes the
  custody trap
  completely: a gnome can only ever be minted directly into a human wallet. The cost is
  that it forecloses, permanently and by construction, any future flow where a realm
  calls `Adopt` on a human's behalf — a sponsor/gift flow, a batching contract, a future
  wrapper realm the owner might want to build in a later phase. Re-opening that door later
  would need a new, deliberately-designed path (e.g. an explicit "adopt for" argument with
  its own trust model), not just deleting the restriction, because by then real gnomes may
  already exist that were minted the old way.
- **Leave it open, as today.** Preserves maximum flexibility for whatever Phase 2+ wants
  to build on top of `Adopt`. The cost is that the custody trap stays live for as long as
  this code ships as-is: the first realm that calls `Adopt` — malicious, buggy, or just
  built by someone who didn't read this note — mints a gnome nobody can ever claim, and
  there is no admin, burn or migration path in this realm to undo it after the fact.

This is not a question the engineering brief answers, and it is not safe to guess: closing
it is a one-way, backward-compatible-looking change that quietly forecloses a product
surface; leaving it open is a one-way, invisible-until-it-happens risk. **The owner should
decide before this realm is deployed anywhere real funds or real users can reach it.**

### Same open question, a second angle: a sponsor realm and the `OriginSend` guard (2026-10-09)

`Adopt`'s `unsafe.OriginSend().IsZero()` check (`garden.gno`, inside `Adopt`) refuses the
call if the transaction's *origin* attached any coins at all. Re-checked this round: that
check is origin-scoped, not frame-scoped, so it inspects the whole transaction's send
regardless of how many realms it crossed through to reach `Adopt`. A "restrict to human
callers" fix for the custody question above does not make this interaction go away, and
may make it worse in one specific shape worth recording here rather than only in code:

A future **sponsor realm** — one that takes a small fee for itself and then crosses into
`Adopt` on the human's behalf, remainder or nothing attached — would still be rejected by
today's `OriginSend` check, because that check sees the *origin's* original send, not what
actually reaches `Adopt`'s own frame. Nothing would be stranded in that flow (the sponsor
realm's own fee logic handles its own coins; `Adopt` itself receives nothing), but the
guard cannot tell "nothing reaches me" from "nothing reaches me because the origin sent
zero in the first place" apart from "something was sent upstream and I can't prove it
didn't end up here." It would reject a perfectly safe call.

This is the same unresolved shape as the custody question above, from the other
direction: both are consequences of `Adopt` being reachable by something other than a
direct human `maketx call`, and both need the same owner decision — should `Adopt` ever be
callable by, or through, another realm at all, and if so, under what trust model — before
either the custody restriction or a sponsor-aware coin check is designed. Do not special-
case the `OriginSend` guard for "known sponsor realms" ad hoc; it would be solving half of
the same problem the custody note above already asks the owner to resolve in full.

## Open question: the name allowlist excludes every combining mark, so whole writing systems are unnameable (2026-10-09, third audit round, finding Y7)

**Status: this is a defensible, already-shipped trade-off, not a bug. Recorded here because
which writing systems the game supports is a product decision, not an engineering one —
same rule as the custody question above.**

`validNameRune` (`garden.gno`) admits only individual Unicode letters (`unicode.IsLetter`),
digits (`unicode.IsDigit`), space, hyphen and apostrophe — each check applied one rune at a
time, with no notion of a rune combining with the one before or after it. Unicode's
combining-mark categories (chiefly Mn, "nonspacing mark") are entirely outside that
allowlist: no combining mark of any kind can ever pass `validNameRune`, today or after any
future Unicode version, since the exclusion is by general category, not a specific list
that could go stale.

**What this actually forecloses**, stated plainly because "a name allowlist" undersells it:
a large number of ordinary, everyday spellings are only representable with at least one
base letter plus one or more combining marks, not as a sequence of precomposed
letter-only code points. Concretely, and non-exhaustively:

- **NFD-normalised Latin.** Some input methods and some Apple keyboards produce "é" as
  the two-code-point sequence `e` + U+0301 COMBINING ACUTE ACCENT (NFD) rather than the
  single precomposed U+00E9 (NFC). A name typed or pasted in NFD form — "José" being the
  canonical example — is rejected today even though the visually-identical NFC spelling of
  the same name is accepted.
- **Devanagari, as ordinarily written.** Vowel signs (mātrā) are combining marks; ordinary
  Devanagari text is not just base consonants.
- **Thai, as ordinarily written.** Vowel and tone marks are combining marks positioned
  above/below the preceding consonant.
- **Hebrew with niqqud** (vowel points) and **Arabic with harakat** (vowel diacritics) —
  both are combining marks layered on consonant letters; the unvocalised consonant-only
  spelling of a name may pass where the fully-vocalised, more traditional spelling would
  not.

None of this is specific to "foreign" scripts as a category — `TestAdoptAcceptsCrossScriptHomoglyphs`
already proves single-code-point non-Latin letters (Cyrillic, Greek, fullwidth, etc.) are
accepted just fine. The exclusion is specifically and only about *combining* marks, which
happen to be load-bearing for several scripts' ordinary orthography and merely decorative
for Latin's.

**The benefit this trade buys, stated equally plainly:** combining marks are exactly the
mechanism "zalgo text" (stacking dozens of combining marks on a single base letter to
produce the glitchy, vertically-exploding look) depends on. Excluding every combining mark
makes zalgo-stacked names structurally impossible in this realm, not merely discouraged —
there is no finite deny-list to maintain and no risk of a renderer-breaking name getting
through because some zalgo-capable combining mark wasn't on it. This is a real, concrete
security/quality property, not a hypothetical one: Render already embeds the name directly
into a markdown heading with no further escaping (see `validNameRune`'s own comment), and a
sufficiently mark-stacked name is exactly the kind of input that has broken renderers and
UI layouts elsewhere on the web.

**Why shipping strict is the safe order, not just the easy one:** relaxing this later
(admitting combining marks, most plausibly gated to "must immediately follow a base
letter/digit" so a name still can't *start* with a stray mark or stack unboundedly) is
backward-compatible — every name accepted today stays accepted, and the newly-expanded set
of acceptable names doesn't retroactively break anything already minted. Tightening a
currently-open rule later is not backward-compatible in the same way: with no rename, no
burn and no admin anywhere in this realm, any name already minted under a looser rule is on
chain forever regardless of what a later, stricter rule would say about it — so a mistake
in the direction of "too permissive" cannot be undone, while a mistake in the direction of
"too strict" (this realm's current choice) costs only a future relaxation, not a migration.

**The decision this note asks the owner to make:** whether Phase 1+ should relax
`validNameRune` to admit combining marks (and if so, under what shape of gate) so players
whose names are ordinarily written with them can spell them as intended, accepting the
reintroduced zalgo-stacking risk and designing a mitigation for it (e.g. a cap on
consecutive combining marks per base character) — or whether excluding them permanently,
as today, is the intended answer for this game. This is not a question the engineering
brief or the audit resolves, and it is not safe to guess which way the owner wants it.
