package garden

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"

	"chain"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carl  = testutils.TestAddress("carl")
	dave  = testutils.TestAddress("dave")
)

// adoptAs sets the test harness's caller identity to addr (the pattern
// p/nt/grc721/v0's own tellers_test.gno uses: testing.SetRealm +
// testing.NewUserRealm) and then crosses into Adopt as that address, the
// same way a real Adena-signed MsgCall would arrive as Adopt's caller.
func adoptAs(cur realm, addr address, name, hat, coat string) {
	testing.SetRealm(testing.NewUserRealm(addr))
	Adopt(cross(cur), name, hat, coat)
}

func TestAdoptMintsSoulboundGnome(cur realm, t *testing.T) {
	adoptAs(cur, alice, "Bramble", "red", "blue")

	tid, name, hat, coat, level, gnomeType, adoptedAt, found := GnomeByAddress(alice)
	uassert.True(t, found, "alice should have a gnome after Adopt")
	uassert.True(t, tid != "", "token id should not be empty")
	uassert.Equal(t, "Bramble", name)
	uassert.Equal(t, "red", hat)
	uassert.Equal(t, "blue", coat)
	uassert.Equal(t, int64(1), level)
	uassert.Equal(t, "", gnomeType, "type is unset until a later phase, matching live.js's adopt() stub")
	uassert.True(t, adoptedAt > 0, "adoptedAt should be a real unix timestamp")

	owner, err := token.OwnerOf(grc721.TokenID(tid))
	uassert.NoError(t, err)
	uassert.Equal(t, alice, owner, "grc721 ledger and this realm's own index must agree on the owner")

	page := Render(string(alice))
	uassert.True(t, strings.Contains(page, "Bramble"), "Render should show the gnome's name")
	uassert.True(t, strings.Contains(page, "Level"), "Render should show the gnome's level")
	uassert.True(t, strings.Contains(page, "red hat"), "Render should show the gnome's look")
}

func TestRenderUnknownAddressDoesNotPanic(t *testing.T) {
	// Its own address, not bob: this used to assert bob had no gnome, and that only held
	// because Go runs top-level test functions in declaration order and this realm's
	// package-level state (ownerIndex/gnomes) persists across test functions within one
	// `gno test` run -- TestAdoptRejectsSecondAdoptSameAddress below adopts bob later in the
	// same file. That made this test true by file-ordering accident, not by anything it
	// actually asserts; a dedicated, never-adopted address can't regress that way if the
	// tests above are ever reordered or a new one is inserted earlier in the file.
	addr := testutils.TestAddress("render-unknown")
	page := Render(string(addr))
	uassert.True(t, strings.Contains(page, "No gnome adopted yet"), "an address with no gnome should get an honest message, not a panic")
}

func TestAdoptRejectsSecondAdoptSameAddress(cur realm, t *testing.T) {
	adoptAs(cur, bob, "First", "red", "blue")

	uassert.AbortsWithMessage(t, cur, "garden: this address has already adopted a gnome", func() {
		adoptAs(cur, bob, "Second", "green", "teal")
	})

	// The rejected second attempt must not have replaced the first gnome.
	_, name, _, _, _, _, _, found := GnomeByAddress(bob)
	uassert.True(t, found)
	uassert.Equal(t, "First", name)
}

func TestAdoptRejectsEveryInvalidHat(cur realm, t *testing.T) {
	invalidHats := []string{"pink", "RED", "", "blue" /* a valid coat, not a valid hat */}
	for i, hat := range invalidHats {
		hat := hat
		addr := testutils.TestAddress("hat-" + strconv.Itoa(i))
		t.Run(hat, func(t *testing.T) {
			uassert.AbortsWithMessage(t, cur, "garden: invalid hat colour", func() {
				adoptAs(cur, addr, "Pip", hat, "blue")
			})
			_, _, _, _, _, _, _, found := GnomeByAddress(addr)
			uassert.False(t, found, "a rejected adopt must not mint anything")
		})
	}
}

func TestAdoptRejectsEveryInvalidCoat(cur realm, t *testing.T) {
	invalidCoats := []string{"black", "BLUE", "", "red" /* a valid hat, not a valid coat */}
	for i, coat := range invalidCoats {
		coat := coat
		addr := testutils.TestAddress("coat-" + strconv.Itoa(i))
		t.Run(coat, func(t *testing.T) {
			uassert.AbortsWithMessage(t, cur, "garden: invalid coat colour", func() {
				adoptAs(cur, addr, "Pip", "red", coat)
			})
			_, _, _, _, _, _, _, found := GnomeByAddress(addr)
			uassert.False(t, found, "a rejected adopt must not mint anything")
		})
	}
}

func TestAdoptRejectsEmptyAndOverLongName(cur realm, t *testing.T) {
	overLong := strings.Repeat("a", maxNameLen+1)
	wantMsg := "garden: name must be 1-" + strconv.Itoa(maxNameLen) + " characters"

	tests := []struct {
		name string
		id   string
	}{
		{"", "empty-name"},
		{overLong, "overlong-name"},
	}
	for _, tc := range tests {
		tc := tc
		addr := testutils.TestAddress(tc.id)
		t.Run(tc.id, func(t *testing.T) {
			uassert.AbortsWithMessage(t, cur, wantMsg, func() {
				adoptAs(cur, addr, tc.name, "red", "blue")
			})
			_, _, _, _, _, _, _, found := GnomeByAddress(addr)
			uassert.False(t, found, "a rejected adopt must not mint anything")
		})
	}
}

func TestAdoptAcceptsNameAtMaxLength(cur realm, t *testing.T) {
	// Boundary check alongside the over-long rejection above: exactly
	// maxNameLen must still succeed.
	maxName := strings.Repeat("z", maxNameLen)
	addr := testutils.TestAddress("maxname")
	adoptAs(cur, addr, maxName, "navy", "orange")

	_, name, _, _, _, _, _, found := GnomeByAddress(addr)
	uassert.True(t, found)
	uassert.Equal(t, maxName, name)
}

// TestTransferAlwaysFails is rule 6's guarantee ("every transfer fails"),
// proven rather than assumed: a real transfer is attempted through
// grc721's own ledger -- the same PrivateLedger.transfer path any
// TransferFrom wrapper would ultimately call -- and it must panic with the
// soulbound extension's message. This realm deliberately exposes no public
// Transfer/TransferFrom wrapper at all (see garden.gno's package doc), so
// the raw ledger call is the actual mechanism, not a stand-in for one.
//
// uassert.PanicsWithMessage, not AbortsWithMessage: ledger.TransferFrom is a
// plain method call, not a crossing call (it is not reached via a
// `cross(...)`-invoked function), so this is a same-realm local panic per
// that function's own doc ("Use PanicsWithMessage for asserting local
// panics within the same realm").
//
// What this test does NOT assert, on purpose: that grc721's own ledger
// (token.OwnerOf) is untouched after the refused attempt. Checked
// empirically against this harness, it is not -- PrivateLedger.transfer()
// (p/nt/grc721/v0) writes owners/balances *before* running extension hooks,
// and recovering a local panic with PanicsWithMessage does not undo writes
// made earlier in the same call. On a live chain that half-written state is
// never observed by anyone, because the whole enclosing transaction aborts
// atomically at the node's transaction-processing layer -- but `gno test`
// does not model that layer at all (realm state is documented to persist
// *between* whole test functions precisely because there is no such
// rollback). Asserting token.OwnerOf here would therefore be testing a
// property of `gno test` itself, not of this realm's code. What this realm
// actually promises its callers -- GnomeByAddress and Render, its own
// authoritative read path -- is asserted below, and that one holds:
// ownerIndex/gnomes are written only by Adopt, never by grc721's internal
// transfer(), so a refused attempt cannot change what they report.
func TestTransferAlwaysFails(cur realm, t *testing.T) {
	wantMsg := "garden: gnomes are soulbound; transfer is permanently disabled"

	adoptAs(cur, carl, "Fern", "navy", "brown")
	tid, _, _, _, _, _, _, found := GnomeByAddress(carl)
	uassert.True(t, found)

	uassert.PanicsWithMessage(t, cur, wantMsg, func() {
		if err := ledger.TransferFrom(carl, carl, dave, grc721.TokenID(tid)); err != nil {
			panic(err)
		}
	})

	_, name, _, _, _, _, _, found := GnomeByAddress(carl)
	uassert.True(t, found)
	uassert.Equal(t, "Fern", name, "this realm's own read must still show the refused transfer's owner")

	_, _, _, _, _, _, _, found = GnomeByAddress(dave)
	uassert.False(t, found, "dave adopted nothing and must not appear to have received a gnome through the refused transfer")
}

// TestAdoptRejectsNamesWithMarkdownZeroWidthAndBidiCharacters is the audit's
// finding 2 (Render sanitisation), proven at the input boundary:
// validNameRune is an allowlist, so every one of these -- markdown
// metacharacters that could break out of Render's "# name" heading or
// inject structure into a future shared page, a zero-width space that would
// make two visually-identical names byte-distinct, and a bidi override that
// could make a rendered name display as something other than what it
// stores -- must be refused at Adopt time, long before Render ever reads
// the name back.
//
// wantMsg asserts the charset message specifically (garden.gno's Adopt now
// gives length and charset failures two different messages -- see the
// second audit round's finding: every name below used to be 9+ runes and
// this test asserted the *length* message, so it would still have passed
// even if validNameRune were deleted outright, since none of these are
// anywhere near maxNameLen). The short two-rune cases at the end of the list
// close that gap: "a`" and "aㅤ" are both well inside the length budget,
// so the only way either can fail is the charset rule actually firing.
func TestAdoptRejectsNamesWithMarkdownZeroWidthAndBidiCharacters(cur realm, t *testing.T) {
	bad := []string{
		"back`tick",
		"star*wars",
		"under_score",
		"brack[ets]",
		"paren(thesis)",
		"pipe|name",
		"hash#tag",
		"angle<brackets>",
		"escape\\name",
		"zero​width",     // U+200B ZERO WIDTH SPACE
		"bidi‮override",  // U+202E RIGHT-TO-LEFT OVERRIDE
		"isolate⁦bidi",   // U+2066 LEFT-TO-RIGHT ISOLATE
		"joiner‍charity", // U+200D ZERO WIDTH JOINER
		"a`",             // 2 runes: short enough that only the charset rule can reject it
		"aㅤ",        // 2 runes: a letter plus a Hangul filler masquerading as one
	}
	wantMsg := "garden: name contains a character that is not an allowed letter, digit, space, hyphen or apostrophe"
	for i, name := range bad {
		name := name
		addr := testutils.TestAddress("badname-" + strconv.Itoa(i))
		t.Run(strconv.Itoa(i), func(t *testing.T) {
			uassert.AbortsWithMessage(t, cur, wantMsg, func() {
				adoptAs(cur, addr, name, "red", "blue")
			})
			_, _, _, _, _, _, _, found := GnomeByAddress(addr)
			uassert.False(t, found, "a name with a markdown/zero-width/bidi character must not mint anything")
		})
	}
}

// TestAdoptRejectsInvisibleLetterOnlyAndSpaceOnlyNames is the second audit
// round's finding 1, proven directly: unicode.IsLetter admits several
// HANGUL FILLER code points (category Lo) that render as nothing, so a name
// made of only one of those was accepted by the old allowlist despite
// validNameRune's own comment claiming nothing outside letters-and-digits
// could get in "full stop". Separately, validName never required any
// visible content at all, so a name of a single space was also accepted --
// and with no rename, no burn and no admin in this realm, permanently.
// Both must now be refused, and refused with their own distinct messages
// (charset vs. visible-content), not the length message.
//
// The letter-filler half is table-driven straight from invisibleLetterRunes
// itself, not a hand-copied list of runes (third audit round, finding Y3):
// before this change, every test here (Go and JS) only ever exercised
// U+3164, so deleting U+115F, U+1160 or U+FFA0 from that map -- or, more
// dangerously, mistyping one of them (e.g. 'ᅟ' as 'ᅡ', which is a
// *visible* Korean vowel, not a filler) -- would still pass every test in
// this repo while quietly breaking the guarantee validNameRune's own comment
// claims. Ranging over the map directly means a change to the map is a
// change to what this test checks, by construction.
func TestAdoptRejectsInvisibleLetterOnlyAndSpaceOnlyNames(cur realm, t *testing.T) {
	wantCharsetMsg := "garden: name contains a character that is not an allowed letter, digit, space, hyphen or apostrophe"
	i := 0
	for r := range invisibleLetterRunes {
		r := r
		idx := i
		i++
		addr := testutils.TestAddress("invisible-letter-" + strconv.Itoa(idx))
		t.Run("U+"+strconv.FormatInt(int64(r), 16), func(t *testing.T) {
			uassert.AbortsWithMessage(t, cur, wantCharsetMsg, func() {
				adoptAs(cur, addr, string(r), "red", "blue")
			})
			_, _, _, _, _, _, _, found := GnomeByAddress(addr)
			uassert.False(t, found, "an invisible-letter-only name must not mint anything")
		})
	}

	spaceOnly := []struct {
		label string
		name  string
	}{
		{"space-only-single", " "},
		{"space-only-multiple", "   "},
	}
	wantSpaceMsg := "garden: name must contain at least one visible character"
	for i, tc := range spaceOnly {
		tc := tc
		addr := testutils.TestAddress("invisible-space-" + strconv.Itoa(i))
		t.Run(tc.label, func(t *testing.T) {
			uassert.AbortsWithMessage(t, cur, wantSpaceMsg, func() {
				adoptAs(cur, addr, tc.name, "red", "blue")
			})
			_, _, _, _, _, _, _, found := GnomeByAddress(addr)
			uassert.False(t, found, "a name with no visible content must not mint anything")
		})
	}
}

// TestAdoptAcceptsCrossScriptHomoglyphs documents and locks in a deliberate,
// accepted residual (see validNameRune's own comment): this allowlist closes
// invisible/structural characters, not cross-script look-alikes. A Cyrillic
// "А" (U+0410) is an ordinary letter by Unicode's own classification, and
// this realm has no reason to reject it -- gnome names are not identifiers,
// nothing requires one to be unique or uses one as a lookup key, so two
// visually-confusable names are a cosmetic curiosity, not a vulnerability.
// This test exists so a future tightening of validNameRune does not silently
// start rejecting ordinary single-code-point non-Latin letters while
// believing it is only closing an invisible-character hole.
//
// What this test does NOT claim, corrected in the third audit round: that
// the current rule accepts "ordinary non-Latin letters" in general. It does
// not. validNameRune admits individual letter/digit code points and nothing
// else, and a large class of ordinary non-Latin spellings are built from a
// base letter plus one or more combining marks (Unicode category Mn) --
// NFD-normalised Latin, the usual spellings of Devanagari, Thai, Hebrew with
// niqqud and Arabic with harakat among them. Every combining mark is
// rejected outright today, so those spellings are not nameable at all, not
// merely confusable with something else. That is a real, deliberate
// exclusion, not a bug this test is guarding -- see NOTES.md for the
// trade-off and why it is a product decision, not an engineering one. This
// test only ever exercises a single-code-point homoglyph (Cyrillic "А" has
// no combining marks involved), so it says nothing about, and must not be
// read as evidence for, the combining-mark case.
func TestAdoptAcceptsCrossScriptHomoglyphs(cur realm, t *testing.T) {
	addr := testutils.TestAddress("homoglyph")
	name := "Аlice" // Cyrillic А + "lice", not the Latin "Alice"
	adoptAs(cur, addr, name, "red", "blue")

	_, gotName, _, _, _, _, _, found := GnomeByAddress(addr)
	uassert.True(t, found)
	uassert.Equal(t, name, gotName)
}

// TestAdoptAcceptsOrdinaryPunctuationInName checks validNameRune's allowlist
// is not so tight it breaks ordinary names: a space, a hyphen and an
// apostrophe are all real characters pack/03-screens' name cards expect to
// be able to show (e.g. a hyphenated or possessive gnome name).
func TestAdoptAcceptsOrdinaryPunctuationInName(cur realm, t *testing.T) {
	addr := testutils.TestAddress("ordinary-punctuation")
	adoptAs(cur, addr, "Mary-Jane O'Hare", "navy", "teal")

	_, name, _, _, _, _, _, found := GnomeByAddress(addr)
	uassert.True(t, found)
	uassert.Equal(t, "Mary-Jane O'Hare", name)
}

// TestAdoptAcceptsMultiByteNameWithinRuneBudget and
// TestAdoptRejectsMultiByteNameOverRuneBudget are the "plain bug" fix:
// validName used to count len(name), which is bytes, while maxNameLen (and
// the spec) mean characters. "é" is 2 UTF-8 bytes per rune, so 24 of them is
// 48 bytes -- over budget under the old byte-counting bug despite being
// exactly 24 characters, which is what the rule was always supposed to
// allow.
func TestAdoptAcceptsMultiByteNameWithinRuneBudget(cur realm, t *testing.T) {
	name := strings.Repeat("é", maxNameLen)
	uassert.True(t, len(name) > maxNameLen, "sanity: this name must be over budget by byte length")
	uassert.Equal(t, maxNameLen, len([]rune(name)), "sanity: this name must be exactly on budget by rune count")

	addr := testutils.TestAddress("multibyte-name")
	adoptAs(cur, addr, name, "red", "blue")

	_, gotName, _, _, _, _, _, found := GnomeByAddress(addr)
	uassert.True(t, found)
	uassert.Equal(t, name, gotName)
}

func TestAdoptRejectsMultiByteNameOverRuneBudget(cur realm, t *testing.T) {
	name := strings.Repeat("é", maxNameLen+1)
	addr := testutils.TestAddress("multibyte-overlong")
	wantMsg := "garden: name must be 1-" + strconv.Itoa(maxNameLen) + " characters"

	uassert.AbortsWithMessage(t, cur, wantMsg, func() {
		adoptAs(cur, addr, name, "red", "blue")
	})
	_, _, _, _, _, _, _, found := GnomeByAddress(addr)
	uassert.False(t, found, "a name one rune over budget must not mint anything, regardless of byte length")
}

// TestRenderRejectsInvalidPathWithoutEchoingIt is the audit's finding 3:
// address(path) is an unchecked conversion, and the old code echoed an
// unvalidated path straight into the page inside backticks on the
// not-found branch. A backtick (or any other markdown metacharacter) in an
// invalid path must never reach the rendered output.
func TestRenderRejectsInvalidPathWithoutEchoingIt(t *testing.T) {
	junk := "not-a-valid-address`*[](){}<script>"
	page := Render(junk)

	uassert.True(t, strings.Contains(page, "invalid address"), "an invalid path should get a clear, generic refusal")
	uassert.False(t, strings.Contains(page, junk), "the raw junk path must never be echoed back into the page")
	uassert.False(t, strings.Contains(page, "`"), "no backtick from caller input should ever reach the page")
}

// TestAlreadyAdoptedChecksOwnerIndexNotJustBalance is the audit's finding 4:
// ownerIndex (this realm's own record, written once by Adopt and never
// deleted) must be consulted, not just grc721's balance. ownerIndex is
// written only by Adopt in real operation; setting it directly here is the
// only way, short of a second ledger implementation, to exercise "ownerIndex
// says adopted, the ledger balance alone would not" and prove the fix
// actually consults both.
//
// This permanently poisons addr's ownerIndex entry (third audit round,
// test-hygiene item): the address below is set to "already adopted" by
// writing straight into ownerIndex, and this realm has no admin, burn or
// rename to ever undo that within a single `gno test` run -- realm state
// persists across test functions, the same property TestRenderUnknownAddressDoesNotPanic's
// own fix above had to account for. Nothing else in this file reuses
// testutils.TestAddress("owner-index-only") today; it must stay that way --
// any future test that adopts as this address would abort on "already
// adopted" for a reason that has nothing to do with whatever it is testing.
func TestAlreadyAdoptedChecksOwnerIndexNotJustBalance(cur realm, t *testing.T) {
	addr := testutils.TestAddress("owner-index-only")
	ownerIndex.Set(addr.String(), "nonexistent-token-id")

	balance, err := token.BalanceOf(addr)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(0), balance, "grc721's own ledger must not have been touched by poking ownerIndex directly")

	uassert.True(t, alreadyAdopted(addr), "ownerIndex alone must be enough to report already-adopted")

	uassert.AbortsWithMessage(t, cur, "garden: this address has already adopted a gnome", func() {
		adoptAs(cur, addr, "ShouldNotMint", "red", "blue")
	})
}

// TestAdoptRejectsAttachedCoins is the audit's finding 5: Adopt is a public
// crossing function, and this realm has no banker and deliberately no
// withdrawal path, so any coins a caller attaches would be stranded
// forever. Adopt must refuse the call outright rather than accept and
// strand them.
func TestAdoptRejectsAttachedCoins(cur realm, t *testing.T) {
	addr := testutils.TestAddress("paid")

	testing.SetRealm(testing.NewUserRealm(addr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1}})
	defer testing.SetOriginSend(chain.Coins{})

	uassert.AbortsWithMessage(t, cur, "garden: adopt accepts no coins; this realm has no banker and cannot return them", func() {
		Adopt(cross(cur), "Payer", "red", "blue")
	})

	_, _, _, _, _, _, _, found := GnomeByAddress(addr)
	uassert.False(t, found, "a rejected adopt must not mint anything, coins or not")
}
