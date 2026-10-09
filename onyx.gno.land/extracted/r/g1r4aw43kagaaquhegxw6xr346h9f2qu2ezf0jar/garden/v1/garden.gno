// Package garden is Gnotchi's Phase 1 on-chain slice: the one signature the
// owner wants (CLAUDE.md / the build brief's Phase 1 note, "adoption is the
// one signature"). Adopt mints a soulbound GRC721 gnome for the caller; a
// read and a Render page let anyone, including the gnoweb UI, see what that
// signature produced.
//
// Grounded in gno.land/p/nt/grc721/v0's own reference consumer,
// examples/gno.land/r/demo/foo721 (NewToken/CallerTeller/wrapper shape), not
// written from memory -- the GRC721 API here (NewToken(name, symbol, id,
// rlm), RegisterExtension, the (_ int, rlm realm) Teller methods) is newer
// than the pre-crossing-call grc721 some training data remembers.
//
// What this realm deliberately does NOT have: Approve, SetApprovalForAll, a
// public TransferFrom, Mint/Burn admin endpoints, or any notion of more than
// one gnome per address. The brief's Part 1 says "what it needs, and nothing
// more" -- a soulbound pet has no legitimate caller for any of those, so
// exposing them would only be surface to audit for no gameplay reason.
// Transfer is still provable: it is exercised directly against the ledger
// in garden_test.gno, which is honest because the extension hook that
// refuses it (soulboundExtension.OnTransfer) runs inside grc721's transfer
// path itself, not inside a wrapper this realm would otherwise own.
//
// SECURITY: no code in this realm, now or later, may ever recover() around
// a call into ledger or token (grc721's PrivateLedger/Token). The soulbound
// guarantee below is real, but it is NOT that the ledger write never
// happens -- it does, before the panic -- it is that an *uncaught* panic
// aborts the whole enclosing transaction, so that write (and everything
// else the transaction did) is discarded and never committed on chain.
// p/nt/grc721/v0/types.gno says this outright, about extension hooks like
// soulboundExtension below: "Hooks run after the ledger write so they
// observe the post-movement state; only a caller that recovers from the
// panic keeps that write." A recover() anywhere between a ledger call and
// the transaction boundary -- even one added for an unrelated reason, even
// one several call-frames away -- would silently convert every refused
// transfer into a permanent, successful one. Don't add one. This is not
// limited to code textually inside this file: a pure `p/` package this realm
// calls runs in garden's own call frame too, so a helper as innocuous as
// `Try(func(){ ledger.TransferFrom(...) })` imported from some future `p/`
// dependency would break the same guarantee just as surely as a recover()
// written here directly.
package garden

import (
	"strconv"
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

	// maxNameLen is this realm's own choice, but it is no longer the only 24 in this
	// codebase: app/js/config.js's NAME_MAX_LEN and, through it, app/js/adopt.js's name
	// field both already hard-code the same limit (the client-side pre-flight check, so a
	// player finds out before paying gas rather than after -- see config.js's own
	// comment). These two 24s are kept in step by hand, not generated from one another, so
	// if this number ever changes, app/js/config.js's NAME_MAX_LEN must change with it or
	// the client and the realm will silently disagree about what a valid name is. 24 runes
	// comfortably fits every pixel-art name card in pack/03-screens while keeping stored
	// state small.
	maxNameLen = 24
)

// validHats/validCoats match app/js/sprite.js's HAT_COLOURS/COAT_COLOURS
// exactly (brief Part 1: "see app/js/config.js" -- the four-and-four list
// itself lives in sprite.js, which config.js's own comments point to).
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

// gnome is this realm's own per-token record. grc721's ledger already owns
// identity, ownership and the soulbound guarantee; this just carries the
// pet's display fields that grc721 has no concept of.
type gnome struct {
	name      string
	hat       string
	coat      string
	level     int64
	gnomeType string // empty until a later phase assigns one; mirrors app/js/live.js's adopt() stub ("type: null")
	adoptedAt int64  // unix seconds, time.Now().Unix() at Adopt
}

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger

	nextID seqid.ID

	// gnomes: TokenID string -> *gnome. The grc721 ledger already refuses a
	// duplicate TokenID, so this is purely this realm's metadata store.
	gnomes = avl.NewTree()

	// ownerIndex: address string -> TokenID string. grc721/v0 has no
	// "tokens by owner" enumeration built in (that is the separate
	// enumerable extension, not used here), and the brief asks for "a read
	// for one address's gnome", so this realm keeps the one index it needs.
	ownerIndex = avl.NewTree()
)

func init(cur realm) {
	token, ledger = grc721.NewToken(collectionName, collectionSymbol, 0, cur)
	ledger.RegisterExtension(&soulboundExtension{})
}

// soulboundExtension is rule 6 ("every transfer fails") made structural
// rather than a convention a future wrapper could forget to enforce: it is
// grc721's own Extension hook, registered once at init.
//
// What actually happens on a refused transfer, read directly from
// p/nt/grc721/v0/token.gno: PrivateLedger.transfer() (308-344) first writes
// setBalance(from), setBalance(to) and owners.Set(tid, to) (328-330), and
// only *after* those writes does it run the registered extensions'
// OnTransfer (333). So this hook's panic does not roll back anything inside
// the transfer path -- by the time it fires, the reassignment has already
// been written. The guarantee this realm actually relies on is the
// transaction boundary, not hook ordering or crossing-call status:
// PrivateLedger.TransferFrom is in fact a plain method, not a crossing call
// -- but not for the reason an earlier pass of this comment cited.
// reference/grc721-v0/tellers.gno:130's "The leading int keeps this a plain
// method" is about fnTeller.guardHome, a different method entirely (it
// guards the frame-relative CallerTeller/RealmTeller wrappers, not the
// ledger). The actual reason is simpler: reference/grc721-v0/token.gno:235
// declares PrivateLedger.TransferFrom(spender, from, to address, tid
// TokenID) error with no realm parameter anywhere in its signature -- and a
// Gno function is only ever reachable as a crossing call (via cross(...))
// when it takes one. No realm parameter, no crossing call, full stop;
// garden_test.gno's own TestTransferAlwaysFails already gets this right (see
// its comment). But the conclusion holds regardless, and unconditionally,
// not because of crossing: an uncaught panic anywhere inside the current
// transaction's call stack -- crossing call or plain method, this frame or
// any callee's -- aborts the *entire enclosing transaction*, and gno.land
// only ever commits a transaction's writes atomically -- if the panic is
// never recovered, the ledger write a few lines earlier is discarded along
// with everything else that transaction did, and nothing is ever observed on
// chain. See this file's package-level SECURITY note: the only way to break
// that guarantee is a recover() upstream of the panic, which is exactly why
// this realm has none.
//
// TransferFrom's plainness is exactly why that SECURITY warning is a live
// concern here rather than a moot one. Were TransferFrom (or anything it
// calls) instead reached across a realm boundary, a panic unwinding back out
// across that boundary would not be something a recover() placed in this
// realm's own frame could ever catch -- there would be nothing upstream of
// the boundary to protect, and the warning would have no real case to guard
// against. Because it is a plain method, the panic instead propagates up
// through this realm's own ordinary, unbroken Go call stack the entire way
// to the transaction boundary -- which is exactly the shape of panic
// recover() *can* catch, from anywhere in that stack, including a
// recover() several frames away that was added for an unrelated reason. That
// is precisely the danger the SECURITY note names, and TransferFrom being
// plain is why it applies here at all.
//
// OnMint is intentionally a no-op: Adopt's own Mint call is how a
// gnome is allowed to come into existence at all, so minting is not
// something this hook should ever veto.
type soulboundExtension struct{}

func (soulboundExtension) ExtensionKind() string { return "soulbound" }

func (soulboundExtension) OnMint(to address, tid grc721.TokenID) {}

func (soulboundExtension) OnTransfer(from, to address, tid grc721.TokenID) {
	panic("garden: gnomes are soulbound; transfer is permanently disabled")
}

func (soulboundExtension) OnBurn(tid grc721.TokenID) {}

// Adopt mints a soulbound gnome for the caller. One gnome per address: a
// second Adopt from the same address panics rather than minting a second
// token, since grc721 has no per-address cap of its own. The caller is
// cur.Previous().Address() -- the account that crossed into this realm --
// matching examples/gno.land/r/demo/foo721's own admin-check idiom for
// "who actually sent this transaction", not cur.Address() (which would be
// this realm's own address).
func Adopt(cur realm, name, hat, coat string) {
	// Adopt is a public crossing function; nothing stops a direct caller
	// (a plain `maketx call -send` MsgCall) from attaching GNOT to it. This
	// realm has no banker and deliberately no withdrawal path (rule 5: no
	// funds handled, no surface to audit for a non-existent feature), so
	// coins attached that way would be stranded forever with no way for
	// anyone, including the owner, to move them back out. Refuse that case
	// outright rather than silently accepting and stranding the attachment.
	// unsafe.OriginSend() (chain/runtime/unsafe, not a plain chain.*
	// function -- see that package's doc for why it's quarantined there)
	// is the *origin* send: the coins attached to the outermost transaction
	// message, not to this call's own frame. IsZero() is true both for no
	// Coins at all and for a Coins set whose entries are all zero-amount.
	//
	// Two honest limits on what this guard actually buys, found while
	// re-checking it: it is origin-scoped, not frame-scoped, so it reads
	// the whole transaction's send regardless of how many realms it crossed
	// through to get here. A future flow where some other realm (e.g. a
	// sponsor realm) takes its own fee off the top and then crosses into
	// Adopt with the remainder, or with nothing, would still see the
	// origin's full original send and could be rejected even though none of
	// that money would ever reach, or be stranded at, this realm's address.
	// And it does not make stranding impossible in general: nothing about
	// this check stops a plain bank send, or another realm's own
	// `banker.SendCoins`, from depositing coins at garden's address
	// directly, with no call to Adopt (or any other garden function)
	// involved at all -- OriginSend only ever observes money attached to
	// *this* call. The guard below is still worth having for the one case
	// it does close cleanly: a direct `maketx call -send` straight into
	// Adopt. See NOTES.md for how this interacts with the realm-as-caller
	// custody question already recorded there.
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
		// Unreachable in practice: nextID is monotonic and private, so the
		// TokenID this builds has never been minted before. Kept as a
		// checked error rather than ignored, per grc721's own Mint contract.
		panic(err)
	}

	gnomes.Set(tid.String(), &gnome{
		name:      name,
		hat:       hat,
		coat:      coat,
		level:     1,
		gnomeType: "",
		adoptedAt: time.Now().Unix(),
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

// alreadyAdopted consults two sources, not one, and they are not the same
// thing: ownerIndex is this realm's own record, written once by Adopt and
// never deleted (there is no burn), so a hit there is permanent and can
// never regress -- it is the stronger, fail-closed source. token.BalanceOf
// consults grc721's ledger, which today only agrees with ownerIndex because
// this realm's own code keeps them in lockstep (no bypass path exists, per
// the audit's reading of p/nt/grc721/v0 -- Mint/Burn/transfer are the only
// writers and TransferFrom routes through transfer); nothing in grc721
// itself promises that agreement will hold under a future change. Checking
// only the balance, as before, meant a bug or future extension that changed
// grc721's balance bookkeeping without a matching change here could let a
// second Adopt through while ownerIndex still correctly remembered the
// first gnome. Checking both means either source alone is enough to
// refuse.
func alreadyAdopted(addr address) bool {
	if ownerIndex.Has(addr.String()) {
		return true
	}

	balance, err := token.BalanceOf(addr)
	if err != nil {
		// BalanceOf's only documented error (p/nt/grc721/v0/token.gno) is
		// ErrInvalidAddress, and Adopt already panics on an invalid caller
		// before this is ever called -- so reaching here with a non-nil err
		// is not a reachable "someone has no balance yet" case, it is
		// something unexpected. The old `return false` failed *open*: it
		// would let Adopt proceed to Mint for an address the ledger itself
		// just refused to report a balance for. Panicking fails closed
		// instead, matching ownerIndex's own fail-closed property above.
		panic(err)
	}
	return balance > 0
}

// validNameLength is this realm's length rule (1-maxNameLen characters),
// checked and reported on its own: Adopt gives a length failure and a
// charset failure two different messages (see Adopt), because they are two
// different mistakes for a player to have made and "characters" is the
// wrong word for "that character isn't on the list". utf8.RuneCountInString,
// not len/byte length: len(name) counts bytes, so a name full of multi-byte
// runes could pack several times maxNameLen's intended character budget into
// the stored string while still reading as "short" by byte count. This is
// deliberately independent of validNameCharset below -- checking length
// first and separately means a name that is both over-long and full of
// hostile runes still gets the length message, not a charset message that
// would obscure it, and vice versa.
func validNameLength(name string) bool {
	n := utf8.RuneCountInString(name)
	return n > 0 && n <= maxNameLen
}

// validNameCharset reports whether every rune in name passes validNameRune.
// Split out from length (above) and from hasVisibleNameContent (below) so
// each has its own panic message in Adopt -- see that function's comment for
// why conflating them once made
// TestAdoptRejectsNamesWithMarkdownZeroWidthAndBidiCharacters weaker than it
// looked.
func validNameCharset(name string) bool {
	for _, r := range name {
		if !validNameRune(r) {
			return false
		}
	}
	return true
}

// hasVisibleNameContent reports whether name has at least one rune that is
// not a plain space. validNameRune's allowlist admits space so that
// multi-word names ("Mary Jane") and the hyphen/apostrophe punctuation
// pack/03-screens' name cards use are not blocked -- but that same allowance
// means a name of nothing but spaces passes validNameCharset while still
// rendering as nothing at all. There is no rename, no burn and no admin
// anywhere in this realm (see the package doc), so a name that gets past
// Adopt is on chain permanently; a blank one would be permanently blank.
func hasVisibleNameContent(name string) bool {
	for _, r := range name {
		if r != ' ' {
			return true
		}
	}
	return false
}

// invisibleLetterRunes is a denylist layered on top of the allowlist below,
// not a replacement for it: these are specific code points that
// unicode.IsLetter reports true for (Unicode general category Lo, "letter,
// other") despite having no visible glyph at all in any tested renderer.
//
// This list is provably the complete set, not just the four this audit
// happened to find by inspection. An exhaustive scan of every Unicode code
// point, checking "is this both default-ignorable and (a letter or a
// digit)", returns exactly these four and no others:
//
//	U+115F, U+1160, U+3164, U+FFA0 — total: 4
//
// The reason a scan is even conclusive here, rather than just a larger
// sample, is Unicode's own general-category partition: every code point
// belongs to exactly one general category, and the categories that carry
// Unicode's "default ignorable" property -- Cf (format), Mn (nonspacing
// mark), Zs (space separator), and the rest of the ignorable set -- are, by
// that same partition, definitionally disjoint from the letter categories
// (Lu/Ll/Lt/Lm/Lo) and the digit category (Nd) this allowlist admits. A code
// point cannot be in Cf and Lo at once. So the only way a default-ignorable
// code point can also be "a letter or a digit" by this realm's own test is
// to sit in the one sliver where a letter category and the ignorable
// property happen to overlap -- and the scan above is what that sliver
// actually contains: four Lo code points, all Hangul filler characters, and
// nothing else. That is not a sampling result that could have come out
// differently with more code points checked; it is the whole space.
//
// If the toolchain's Unicode/CLDR version ever moves, re-run the scan
// (unicode.IsLetter/IsDigit plus a default-ignorable table, iterated over
// every code point up to unicode.MaxRune) rather than assuming this list is
// still complete -- a future Unicode version could in principle assign the
// default-ignorable property to a new Lo or Nd code point this list does not
// yet know about.
var invisibleLetterRunes = map[rune]bool{
	'\u115f': true, // HANGUL CHOSEONG FILLER
	'\u1160': true, // HANGUL JUNGSEONG FILLER
	'\u3164': true, // HANGUL FILLER
	'\uffa0': true, // HALFWIDTH HANGUL FILLER
}

// validNameRune is an allowlist, not a denylist, of what a single rune in a
// gnome name may be. That choice matters because of what happens to a name
// once Adopt accepts it: there is no admin, no burn and no rename anywhere
// in this realm, so a name that gets past this check is on chain
// permanently and unremovable, and it goes straight into Render's page
// heading as a raw markdown "# " line with no further escaping (garden.gno,
// Render). The old check only rejected ASCII control characters and
// DEL (0x7f), which let through: markdown metacharacters (backtick,
// asterisk, underscore, square/round brackets, '#', '|', '>', '\', '<')
// that can break out of the heading or inject structure into any future
// page that lists several names together (a leaderboard, a neighbour list);
// zero-width characters (e.g. U+200B ZERO WIDTH SPACE) that make two
// visually-identical names byte-distinct; and bidi override/isolate
// controls (e.g. U+202E RIGHT-TO-LEFT OVERRIDE) that can make a rendered
// name display as something other than what it actually stores. All of
// those live in Unicode's "format" (Cf) general category, which this
// allowlist already excludes outright: nothing in Cf is a letter, a digit,
// space, hyphen or apostrophe.
//
// What this allowlist does guarantee: every accepted rune is an
// alphanumeric character (by Unicode's own classification) or one of the
// three punctuation runes named below, and no Cf format/control code point
// of any kind -- known today or standardised tomorrow -- can ever pass.
//
// What it does NOT guarantee, stated here rather than implied away:
// invisibleLetterRunes above is proven complete against the Unicode version
// this toolchain ships today (see that var's own comment for the scan and
// why the general-category partition makes it exhaustive, not just a
// sample) -- but that completeness is tied to today's Unicode version. A
// future Unicode update that assigned a new invisible code point to the
// letter or digit categories would need the scan re-run and the map updated;
// nothing in this realm detects that automatically.
// And, separately and by deliberate choice, this allowlist does nothing at
// all about cross-script homoglyphs -- Cyrillic "А", Greek "Ο", fullwidth
// "Ａ" are ordinary letters by Unicode's own definition and this check lets
// every one of them through. That is accepted, not closed: gnome names are
// not identifiers here (nothing requires one to be unique, nothing uses a
// name as a lookup key), so two visually-confusable names existing side by
// side is a cosmetic curiosity, not a security property this realm relies
// on. A future feature that did start treating names as identifiers would
// need to revisit this.
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

// gnomeForAddr resolves addr's gnome via ownerIndex, or reports found=false.
func gnomeForAddr(addr address) (tid string, g *gnome, found bool) {
	v := ownerIndex.Get(addr.String())
	if v == nil {
		return "", nil, false
	}
	tid = v.(string)
	gv := gnomes.Get(tid)
	if gv == nil {
		// Should not happen: the two trees are only ever written together in
		// Adopt. Treated as "not found" rather than panicking a read.
		return "", nil, false
	}
	return tid, gv.(*gnome), true
}

// GnomeByAddress is the brief's "read for one address's gnome". found=false
// (with every other field zero) when addr has not adopted.
func GnomeByAddress(addr address) (tokenID, name, hat, coat string, level int64, gnomeType string, adoptedAtUnix int64, found bool) {
	tid, g, ok := gnomeForAddr(addr)
	if !ok {
		return "", "", "", "", 0, "", 0, false
	}
	return tid, g.name, g.hat, g.coat, g.level, g.gnomeType, g.adoptedAt, true
}

// Render implements the realm's gnoweb page (brief Part 1: "a public gnoweb
// page: name, level, type, look"). path == "" is the collection overview;
// any other path is read as a bech32 owner address.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf(
			"# %s\n\nSoulbound gnome collection. Every gnome is non-transferable: see rule 6.\n\n* **Total adopted**: %d\n",
			collectionName, token.TotalSupply(),
		)
	}

	// address(path) is an unchecked conversion -- in Gno, any string is a
	// syntactically legal `address` value, so this alone does not confirm
	// path looks anything like a real bech32 address. The code below used
	// to find that out the hard way, via gnomeForAddr/ownerIndex.Get
	// returning nil -- by which point path had already been queued up to be
	// echoed straight into the page inside backticks. A backtick in path
	// (or any other markdown metacharacter) would close that code span and
	// let the rest of path inject arbitrary content into gnoweb's rendered
	// output. Reject before anything derived from path is echoed anywhere:
	// addr.IsValid() bech32-decodes the string for real (same check Adopt
	// already relies on for its caller), so every addr.String() reached
	// below is a real, bech32-shaped address that cannot contain a
	// backtick or any other markdown metacharacter -- path itself is never
	// echoed again past this point.
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

	return str
}
