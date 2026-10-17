// Package nsnft is the token, and only the token.
//
// WHY THIS REALM EXISTS AT ALL.
//
// A name here is a GRC-721. An external marketplace that wants to list
// one has to hard-code an address, and whatever address that is becomes
// the thing we can never move. Until now the interface was split: the
// READS lived on nsdata, which is permanent, and the WRITES — Approve,
// SetApprovalForAll, TransferFrom — lived on nslogic, which changed
// address three times in a single day. So the half an integrator needs
// in order to settle a sale was the half that kept moving, and the reads
// kept answering while it did, which is the worst way for it to break.
//
// The fix is to pick ONE realm to freeze and make it the smallest, most
// boring one there is. That is this realm: an ownership ledger, the
// approval bookkeeping GRC-721 requires, the governance that decides who
// may mint, and nothing else. No prices, no expiry, no profiles, no
// policy — none of the things that will certainly need changing.
//
// Everything with an opinion in it stays in the registry, which becomes
// replaceable BECAUSE ownership no longer lives there. A migration then
// moves records, not tokens: nobody's holdings are stranded and no
// listing anywhere goes stale, because the token contract never moved.
//
// THE LEDGER IS THE CHAIN'S OWN gno.land/p/nt/grc721/v0, NOT A COPY.
//
// chain.Emit stamps the package whose code emits, and wallets and
// indexers (Adena, the Onbloc indexer) accept only Transfer and NewToken
// events stamped gno.land/p/nt/grc721/v0. The first version of this realm
// minted on a vendored GRC-721 deployed under our own p/ path, so every
// event it would ever have emitted carried OUR path, and no wallet would
// ever have listed a single name — permanently, because events cannot be
// re-emitted and this realm cannot be replaced. The ledger object lives
// here, created once in init; only this realm holds its PrivateLedger,
// and no Teller is ever handed out (see the note on holds below).
//
// THIS REALM HAS ITS OWN GOVERNANCE, AND THAT IS THE POINT.
//
// It would be shorter to ask nsdata who the admin is. It would also
// re-couple this realm to the exact thing it exists to let us replace —
// nsnft would then depend on one nsdata forever and we would have moved
// the problem rather than solved it. So roles, trust and the timelock are
// local (governance.gno), and nsdata is not imported.
//
// WHAT MAY BE CHANGED LATER AND WHAT MAY NOT.
//
// May, slowly: which registries are trusted, the roles, the timelock,
// and which view realm draws the art. May, instantly: withdrawing a
// registry's trust or the art, which only ever removes a power. Through a
// trusted registry only: the hold bits on a token. May not: anything
// else. If this realm ever needs a new function, the design has failed
// and the honest answer is that it was not small enough to freeze.
package nsnft

import (
	"chain"
	"chain/runtime/unsafe" // OriginSend only; this realm never moves coins
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	collectionName   = "Meme Name Service"
	collectionSymbol = "MNS"

	/* THE REGISTRY AND THE VIEW THIS LEDGER IS BORN WITH.

	   Placeholders, exactly like an import path: the deploy tooling
	   (tools/deploy-gen.sh, tools/bundle-sources.py) rewrites every
	   quoted gno.land/r/demo/<realm> string to the generation's real path,
	   so the ledger is born trusting the one registry that is deployed
	   beside it — and no wallet is ever trusted, not even for the first
	   wiring. The previous version trusted the deployer's key at birth and
	   relied on somebody remembering to untrust it.

	   Fail-safe if the rewrite is ever skipped: nobody can deploy under
	   gno.land/r/demo on a public chain, so an unrewritten placeholder
	   trusts an address no transaction can come from. */
	genesisRegistry = "gno.land/r/nym-mnsrehearsal001/nsdata/v2"
	genesisView     = "gno.land/r/nym-mnsrehearsal001/nsview/v2"
)

var (
	// Created once, in init, by the chain's own GRC-721. token is the
	// read side; ledger is the write side and never leaves this realm.
	token  *grc721.Token
	ledger *grc721.PrivateLedger

	/* THE REGISTRIES PERMITTED TO MINT AND BURN: registry address -> the
	   package path it was trusted as. A set rather than a single value so
	   a migration can have the old and the new registry both live for the
	   window in which records are moving. An avl.Tree, so it is both a
	   lookup and an enumeration — whoever can mint names is the most
	   important fact about this contract, and it must be legible without
	   an indexer — and so a write touches one node rather than the whole
	   set. */
	trusted avl.Tree

	/* HOLDS, set by a trusted registry and never interpreted here.

	   A small bitmask per token (tid -> int). While any bit is set the
	   token cannot be approved or transferred — by its owner, by an
	   operator, by any marketplace — through any path in this realm.

	   WHY THE FROZEN REALM NEEDED THIS. The registry has two reasons to
	   hold a token in place: a free-tier name that has not been paid for
	   must not be sellable, and a name frozen by an admin during a
	   dispute must not be moved. Both used to be enforced in nslogic's
	   transfer wrappers — which only worked while nslogic was the only
	   way to transfer. The point of this realm is that it is NOT: any
	   GRC-721 marketplace calls TransferFrom here directly. A rule that
	   lives anywhere else is a rule an external marketplace skips.

	   WHY BITS AND NOT NAMED REASONS. What a bit MEANS is policy, and
	   policy changes; this realm cannot. So it stores numbers and the
	   registry owns the vocabulary. Separate bits, not one flag, so that
	   unfreezing a free-tier name cannot accidentally make it sellable.

	   Absent key = no hold. Burn clears it. */
	locks avl.Tree

	/* THE OWNERSHIP EPOCH (tid -> int64). Moves on every mint and every
	   transfer.

	   The registry stamps a name's profile data with the epoch it was
	   written in, and treats data from any other epoch as belonging to a
	   previous holder. That is how a sale that settles HERE — on a
	   marketplace the registry never hears from — still stops the
	   seller's payment addresses from answering for the buyer's name.

	   AN EPOCH, NOT AN OWNER ADDRESS, because a name can go A to B and
	   back to A. Compared by address, A's data from before the sale would
	   come back to life — including a pay address A may have abandoned.

	   Drawn from one global counter rather than counted per token, so a
	   token burned and minted again can never repeat an epoch it had in
	   a previous life.

	   avl.Tree and not a map: a Go map is persisted as ONE object, so
	   every mint and transfer re-wrote every token's epoch — measured at
	   ~784 gas per existing token per write, growing forever, in the one
	   realm that could never be fixed. A tree write touches a path. */
	epochs  avl.Tree
	lastSeq int64
)

// Bits a lock value may use. Eight is plenty for a registry and keeps a
// caller from storing arbitrary integers in a realm that cannot be
// patched to reject them later.
const maxLockBit = 7

// validLockBits is the range check, alone, so it can be tested directly.
func validLockBits(b int) bool { return b >= 0 && b < 1<<(maxLockBit+1) }

// validLockBit checks a bit INDEX, for SetLock. Separate from
// validLockBits, which checks a whole mask, because confusing the two is
// exactly the bug SetLock shipped with for one commit.
func validLockBit(bit int) bool { return bit >= 0 && bit <= maxLockBit }

func lockBitsOf(tid string) int {
	if v := locks.Get(tid); v != nil {
		return v.(int)
	}
	return 0
}

func bump(tid string) {
	lastSeq++
	epochs.Set(tid, lastSeq)
}

/*
THE HOLDS AND THE EPOCH LIVE IN THE LEDGER'S OWN HOOKS.

grc721/v0 calls an issuer-registered extension on every mint, transfer
and burn, after the ledger write and before the event, and a panic in a
hook aborts the movement. So the two rules this realm exists to keep are
enforced at the one place EVERY movement passes through — not in the
wrappers below, which merely repeat the hold check to give a clearer
error first.

Why that matters in a realm that never hands out a Teller: it makes the
rules a property of the ledger rather than of whichever entry point a
future reader adds or a marketplace finds. A transfer that reaches the
ledger by any route moves the epoch, and a held token does not move.
Approvals do not pass through a hook, so Approve checks the hold itself.

The type is unexported and the only instance is attached to the private
ledger, so no other realm can reach these methods.
*/
type holds struct{}

func (holds) ExtensionKind() string { return "nsnft/holds" }

func (holds) OnMint(to address, tid grc721.TokenID) {
	// A fresh token starts unheld; Mint applies the bits it was asked for
	// straight after. Burn already cleared any old hold, so this is the
	// belt to that brace.
	locks.Remove(string(tid))
	bump(string(tid))
}

func (holds) OnTransfer(from, to address, tid grc721.TokenID) {
	assertUnlocked(string(tid))
	bump(string(tid))
}

func (holds) OnBurn(tid grc721.TokenID) {
	// A hold on a token that no longer exists would silently apply to the
	// NEXT token minted with this id — a reclaimed name arriving frozen.
	locks.Remove(string(tid))
	// The epoch goes too. The next mint draws a fresh one from lastSeq,
	// which can never equal anything this token had before.
	epochs.Remove(string(tid))
}

func init(cur realm) {
	// Emits NewToken from gno.land/p/nt/grc721/v0; the collection id is
	// "<this realm's path>.MNS.0000000", the shape wallets parse.
	token, ledger = grc721.NewToken(collectionName, collectionSymbol, seqid.ID(0), cur)
	ledger.RegisterExtension(holds{})

	/* BOTH ROLES START ON THE DEPLOYER, AND ONLY IF IT IS REAL.

	   The deployer hands recovery to a cold key and admin to a multisig
	   as part of the deploy (tools/deploy-gen.sh), while the timelock is
	   still zero; then the timelock goes up. An invalid deployer cannot
	   happen on chain, and under `gno test` (which has none) it leaves
	   both roles empty — and every role check below refuses an empty
	   role, so nobody, not even a caller whose address stringifies to
	   nothing, can act as an absent admin. */
	if d := cur.Previous().Address(); d.IsValid() {
		admin = d
		recovery = d
	}

	reg := chain.PackageAddress(genesisRegistry)
	trusted.Set(reg.String(), genesisRegistry)
	chain.Emit("RegistryTrusted", "addr", reg.String(), "path", genesisRegistry)
	rendererPath = genesisView
	chain.Emit("RendererApproved", "path", genesisView)
}

/*
COINS SENT HERE ARE DESTROYED, SO REFUSE THEM.

This realm has no banker, no withdrawal and no sweep, and it can never
gain one — that is the whole premise of freezing it. Anything attached to
a call would sit at its address until the chain ends.

Checked only for a direct user call: when another realm calls in, any
coins the user attached went to THAT realm, not to this one, and
refusing them here would break legitimate registry calls.
*/
func assertNoSend(cur realm) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if !unsafe.OriginSend().IsZero() {
		panic("nsnft: this realm takes no payment and cannot return it; do not attach coins")
	}
}

/*
assertTrusted is the whole security model for minting.

A caller that can mint can invent a name, and a name is the product. So
this is checked against the REALM address of the caller rather than an
address it hands us — a registry proves what it is by being it. Only
package paths can be trusted (governance.gno), so a wallet can never be
in this set.
*/
func assertTrusted(caller address) {
	if !caller.IsValid() || !trusted.Has(caller.String()) {
		panic("nsnft: only a trusted registry may do that")
	}
}

// ---------------------------------------------------------------------
// mint and burn — registry only
// ---------------------------------------------------------------------

/*
Mint creates a token, optionally already held in place.

`lockBits` is the hold it starts with — a free-tier name is minted locked
so there is never an instant in which it could be approved and sold
before the registry got round to locking it (nothing runs between the
ledger write and the line that sets the bits). Zero for an ordinary
paid name.
*/
func Mint(cur realm, to address, tid string, lockBits int) {
	assertNoSend(cur)
	assertTrusted(cur.Previous().Address())
	if !to.IsValid() {
		panic("nsnft: invalid recipient")
	}
	if tid == "" {
		panic("nsnft: empty token id")
	}
	if !validLockBits(lockBits) {
		panic("nsnft: lock bits out of range")
	}
	if err := ledger.Mint(to, grc721.TokenID(tid)); err != nil {
		panic("nsnft: " + err.Error())
	}
	if lockBits != 0 {
		locks.Set(tid, lockBits)
		chain.Emit("Locked", "tid", tid, "bits", itoa(int64(lockBits)))
	}
}

/*
Burn destroys a token. Reachable only by a trusted registry, which calls
it when a name lapses past its grace period and is reclaimed.

NOT reachable by the holder. A GRC-721 that lets an owner burn is
correct for collectibles and wrong here: the token is a lease on a name,
and destroying it would leave the registry holding a record for a name
whose token no longer exists. Letting go of a name is letting it expire.

The hold and the epoch are cleared by the burn hook (holds.OnBurn), the
per-token approval by the ledger itself.
*/
func Burn(cur realm, tid string) {
	assertNoSend(cur)
	assertTrusted(cur.Previous().Address())
	if err := ledger.Burn(grc721.TokenID(tid)); err != nil {
		panic("nsnft: " + err.Error())
	}
}

/*
SetLock turns one hold bit on or off. Trusted registry only.

The registry decides what a bit means; this realm only guarantees that
while any bit is set, nothing moves the token.
*/
func SetLock(cur realm, tid string, bit int, on bool) {
	assertNoSend(cur)
	assertTrusted(cur.Previous().Address())
	/* THE BIT IS RANGE-CHECKED BEFORE IT IS SHIFTED. An earlier check
	   tested 1<<bit, and an audit caught what that does: a bit of 64 or
	   more shifts to zero, passes, and the call quietly changes nothing
	   while still emitting LockChanged. Unacceptable in the one realm
	   that can never be patched. */
	if !validLockBit(bit) {
		panic("nsnft: lock bit out of range")
	}
	owner := OwnerOf(tid)
	if owner == "" {
		panic("nsnft: no such token")
	}
	v := lockBitsOf(tid)
	if on {
		v |= 1 << bit
	} else {
		v &^= 1 << bit
	}
	if v == 0 {
		locks.Remove(tid)
	} else {
		locks.Set(tid, v)
	}
	/* A NEW HOLD WITHDRAWS THE STANDING APPROVAL. A hold stops an
	   approval being USED, not the approval itself — so a name frozen
	   mid-dispute kept whatever approval it had, and it became live again
	   the moment the name was unfrozen. An audit caught it. The owner can
	   re-approve afterwards; nobody else's pre-dispute permission
	   survives. Operator grants are per owner, not per token, and are the
	   owner's to revoke. Approving the zero address is grc721/v0's
	   revoke, and it emits the standard Approval event. */
	if on && GetApproved(tid) != "" {
		if err := ledger.Approve(owner, "", grc721.TokenID(tid)); err != nil {
			panic("nsnft: " + err.Error())
		}
	}
	chain.Emit("LockChanged", "tid", tid, "bits", itoa(int64(v)))
}

func assertUnlocked(tid string) {
	if lockBitsOf(tid) != 0 {
		panic("nsnft: this token is held by the registry and cannot be approved or moved")
	}
}

// LockBits reports the current hold; 0 means free to move.
func LockBits(tid string) int { return lockBitsOf(tid) }

func IsLocked(tid string) bool { return lockBitsOf(tid) != 0 }

// Epoch reports the ownership epoch of a token, or 0 for one that does
// not exist. See epochs.
func Epoch(tid string) int64 {
	if v := epochs.Get(tid); v != nil {
		return v.(int64)
	}
	return 0
}

// ---------------------------------------------------------------------
// GRC-721, public — this is the surface the outside world holds
// ---------------------------------------------------------------------

// Approve grants (or, to the empty address, withdraws) the per-token
// approval. Refused while the token is held: approvals do not pass
// through a ledger hook, so this is the one place the hold is checked.
func Approve(cur realm, to address, tid string) {
	assertNoSend(cur)
	assertUnlocked(tid)
	if err := ledger.Approve(cur.Previous().Address(), to, grc721.TokenID(tid)); err != nil {
		panic("nsnft: " + err.Error())
	}
}

/*
RevokeApproval withdraws a token's per-token approval.

grc721/v0 revokes by approving the empty address; this keeps the named
entry point the site and tools already call, and allows it while the
token is held — withdrawing a permission is the safe direction. The
owner, or an operator acting for the owner, the same two callers Approve
accepts.
*/
func RevokeApproval(cur realm, tid string) {
	assertNoSend(cur)
	if OwnerOf(tid) == "" {
		panic("nsnft: no such token")
	}
	if err := ledger.Approve(cur.Previous().Address(), "", grc721.TokenID(tid)); err != nil {
		panic("nsnft: only the owner or an operator may revoke an approval: " + err.Error())
	}
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNoSend(cur)
	if err := ledger.SetApprovalForAll(cur.Previous().Address(), operator, approved); err != nil {
		panic("nsnft: " + err.Error())
	}
}

/*
TransferFrom carries NO expiry check, and that is a deliberate reversal
of what nslogic once did.

Refusing to transfer an expired token is an anti-scam measure, and it
belongs in the REGISTRY, not here: this realm does not know what expiry
is and must not learn, because the moment it holds policy it stops being
the small frozen thing it exists to be. The registry keeps the rule by
refusing to RESOLVE an expired name. A buyer can still acquire a
worthless token from a careless seller, which is true of every NFT on
every chain, and the marketplace disclaimers say so.

The hold is checked here for a clear error and again by the ledger hook,
which also moves the epoch.
*/
func TransferFrom(cur realm, from, to address, tid string) {
	assertNoSend(cur)
	assertUnlocked(tid)
	if err := ledger.TransferFrom(cur.Previous().Address(), from, to, grc721.TokenID(tid)); err != nil {
		panic("nsnft: " + err.Error())
	}
}

// SafeTransferFrom is kept for the standard signature. grc721/v0 has no
// receiver hook (gno has no contract-receiver registry to check), so it
// is TransferFrom — as the vendored version effectively was, its
// receiver check being a stub that always said yes.
func SafeTransferFrom(cur realm, from, to address, tid string) {
	assertNoSend(cur)
	assertUnlocked(tid)
	if err := ledger.TransferFrom(cur.Previous().Address(), from, to, grc721.TokenID(tid)); err != nil {
		panic("nsnft: " + err.Error())
	}
}

// ---------------------------------------------------------------------
// reads
// ---------------------------------------------------------------------

/*
OwnerOf answers the zero address for a token that does not exist, rather
than panicking or returning an error.

The registry calls this on EVERY resolve — that is the whole design, one
truth rather than a cached copy that goes stale the moment a sale settles
somewhere we did not watch. A panic on an unknown id would make every
caller wrap it, and the wrapper that gets forgotten is the one that turns
a missing name into a broken page. (nsdata and nsmarket are written
against exactly this signature.)
*/
func OwnerOf(tid string) address {
	owner, err := token.OwnerOf(grc721.TokenID(tid))
	if err != nil {
		return ""
	}
	return owner
}

func Exists(tid string) bool { return OwnerOf(tid) != "" }

func BalanceOf(owner address) int64 {
	n, err := token.BalanceOf(owner)
	if err != nil {
		return 0
	}
	return n
}

// GetApproved answers totally: the zero address means nobody is approved
// or there is no such token.
func GetApproved(tid string) address {
	a, err := token.GetApproved(grc721.TokenID(tid))
	if err != nil {
		return ""
	}
	return a
}

func IsApprovedForAll(owner, operator address) bool {
	return token.IsApprovedForAll(owner, operator)
}

func Name() string       { return token.GetName() }
func Symbol() string     { return token.GetSymbol() }
func GetName() string    { return token.GetName() }
func GetSymbol() string  { return token.GetSymbol() }
func TokenCount() int64  { return token.TotalSupply() }
func TotalSupply() int64 { return token.TotalSupply() }

// ID is the collection id wallets and indexers key on:
// "<this realm's path>.MNS.0000000".
func ID() string { return token.ID() }

/*
Render builds its string by concatenation rather than with ufmt.

NO DEPENDENCIES THIS REALM DOES NOT ABSOLUTELY NEED. It is meant to be
deployed once and never replaced, so every import is a permanent
commitment to somebody else's package. grc721/v0 (with avl and seqid,
which it already depends on) is here because it IS the thing this realm
is; a formatter, for one page of text, is not worth that.
*/
func Render(path string) string {
	out := "# Meme Name Service — tokens\n\n" +
		"This realm is the ownership ledger and nothing else. Prices, expiry,\n" +
		"profiles and every rule live in the registry.\n\n" +
		"- collection: `" + token.ID() + "`\n" +
		"- tokens: " + itoa(token.TotalSupply()) + "\n" +
		"- admin: `" + admin.String() + "`\n" +
		"- recovery: `" + recovery.String() + "`\n" +
		"- guardian: `" + guardian.String() + "`\n" +
		"- timelock: " + itoa(timelockDelay) + " s\n" +
		"- renderer: `" + rendererPath + "`"
	if renderer == nil {
		out += " (not registered: wallets see the built-in card)"
	}
	out += "\n\n## Trusted registries\n\n"
	trusted.Iterate("", "", func(a string, v any) bool {
		out += "- `" + v.(string) + "` (`" + a + "`)\n"
		return false
	})
	out += "\n## Pending governance\n\n"
	n := 0
	now := time.Now().Unix()
	pending.Iterate("", "", func(k string, v any) bool {
		op := v.(*pendingOp)
		if now > op.until {
			return false // void: lapsed unexecuted (re-audit 2026-10-16, I-6)
		}
		out += "- " + k + " -> `" + op.target + "`, executable " + itoa(op.at) +
			" to " + itoa(op.until) + ", by `" + op.proposer.String() + "`\n"
		n++
		return false
	})
	if n == 0 {
		out += "none\n"
	}
	out += "\nIntegrators: this address is stable. The registry behind it is not,\n" +
		"and is meant not to be.\n"
	return out
}

// itoa, because importing a package to print one number would outlast
// every reason we had for wanting it.
func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	// Work in uint64 so the most negative int64 does not overflow when
	// its sign is flipped.
	u := uint64(n)
	if neg {
		u = uint64(-(n + 1)) + 1
	}
	var b []byte
	for u > 0 {
		b = append([]byte{byte('0' + u%10)}, b...)
		u /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}
