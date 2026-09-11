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
// boring one there is. That is this file: an ownership ledger, the
// approval bookkeeping GRC-721 requires, and nothing else. No prices, no
// expiry, no profiles, no policy — none of the things that will
// certainly need changing.
//
// Everything with an opinion in it stays in the registry, which becomes
// replaceable BECAUSE ownership no longer lives there. A migration then
// moves records, not tokens: nobody's holdings are stranded and no
// listing anywhere goes stale, because the token contract never moved.
//
// THIS REALM HAS ITS OWN ADMIN, AND THAT IS THE POINT.
//
// It would be shorter to ask nsdata who the admin is. It would also
// re-couple this realm to the exact thing it exists to let us replace —
// nsnft would then depend on nsdata/v1 forever and we would have moved
// the problem rather than solved it. So the trust list here is local,
// and nsdata is not imported.
//
// WHAT MAY BE CHANGED LATER AND WHAT MAY NOT.
//
// May: which registries are trusted, the admin, the token URI base, and —
// through a trusted registry only — the hold bits on a token.
// May not: anything else. If this realm ever needs a new function, the
// design has failed and the honest answer is that it was not small
// enough to freeze.
package nsnft

import (
	"chain"
	"chain/runtime/unsafe" // OriginSend only; this realm never moves coins

	"gno.land/p/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/grc721"
)

var (
	// Constructed in init, not here: NewBasicNFT wants a realm, and the
	// only place one exists is a function that receives it.
	nft *grc721.BasicNFT

	// Set once at deploy to whoever deployed it, then transferable. Not
	// read from anywhere else, deliberately — see the note above.
	admin address

	// The registries permitted to mint and burn. A set rather than a
	// single value so a migration can have the old and the new registry
	// both live for the window in which records are moving.
	trusted = map[string]bool{}

	/* THE SAME SET, IN A FORM THAT CAN BE READ BACK.
	   A map answers "is X trusted" and cannot answer "who is trusted",
	   so auditing it would mean already knowing the address to suspect.
	   In a realm that can never gain a function later, that is not a
	   gap worth leaving: whoever can mint names is the most important
	   fact about this contract and it must be legible without an
	   indexer. Kept in step with the map by Trust and Untrust. */
	trustedList []string

	// Prepended to a token id to make a URI. Points at a swappable view
	// realm so the art can change without touching this one.
	uriBase string

	/* HOLDS, set by a trusted registry and never interpreted here.

	   A small bitmask per token. While any bit is set the token cannot be
	   approved or transferred — by its owner, by an operator, by any
	   marketplace — through any path in this realm.

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
	locks = map[string]int{}

	/* THE OWNERSHIP EPOCH. Moves on every mint and every transfer.

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
	   a previous life. */
	epochs  = map[string]int64{}
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

func bump(tid string) {
	lastSeq++
	epochs[tid] = lastSeq
}

func init(cur realm) {
	nft = grc721.NewBasicNFT(0, cur, "Meme Name Service", "MNS")
	admin = cur.Previous().Address()
	/* THE DEPLOYER IS TRUSTED AT BIRTH, AND ONLY IF IT IS REAL.

	   Trusted so the first registry can be wired up without a second
	   transaction. Guarded because an invalid or empty deployer address
	   would otherwise put "" into the trust set — and assertTrusted
	   looks up by string, so a caller whose address stringified to
	   nothing would pass. That cannot happen in a real deployment and
	   costs one line to make impossible anyway, in a realm where the
	   line can never be added later.

	   IT MUST BE UNTRUSTED once a registry is wired. Nothing here does
	   that automatically: an admin who forgets leaves a wallet key able
	   to mint any name, including ones the registry's block list
	   refuses. Trusted() exists so that is visible rather than
	   archaeological. */
	if admin.IsValid() {
		trusted[admin.String()] = true
		trustedList = append(trustedList, admin.String())
	}
}

// ---------------------------------------------------------------------
// governance — small on purpose
// ---------------------------------------------------------------------

/*
COINS SENT HERE ARE DESTROYED, SO REFUSE THEM.

This realm has no banker, no withdrawal and no sweep, and it can never
gain one — that is the whole premise of freezing it. Anything attached to
a call would sit at its address until the chain ends. Every other realm
in this project guards its entry points for exactly this reason; the one
that cannot be patched had no guard at all, which is precisely backwards.

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

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("nsnft: admin only")
	}
}

/*
assertTrusted is the whole security model for minting.

A caller that can mint can invent a name, and a name is the product. So
this is checked against the REALM address of the caller rather than an
address it hands us — a registry proves what it is by being it.
*/
func assertTrusted(cur realm) {
	if !trusted[cur.Previous().Address().String()] {
		panic("nsnft: only a trusted registry may do that")
	}
}

func Admin() address { return admin }

/*
ADMIN CHANGES IN TWO STEPS, BECAUSE THIS REALM HAS NO SECOND CHANCE.

The vault has a timelock, a recovery key and a guardian. This realm has
none of that by design — it is meant to be small. But single-step
transfer to a raw address is the one place where "small" becomes
"one typo from permanently bricked": a valid-but-wrong address ends the
ability to trust a new registry, and trusting a registry is how names get
minted. Registration would stop, forever, with no way back.

So the successor must CLAIM it. An address that cannot sign a
transaction cannot accept, and the transfer simply never completes —
the mistake costs nothing and is corrected by proposing again.

This is not a timelock and does not pretend to be. It defends against
the wrong address, not against a stolen key. A stolen admin key here can
mint and burn regardless, and no arrangement this realm can hold would
change that; the answer to that risk is a multisig as admin, which this
supports because it does not care what kind of address it is talking to.
*/
var pendingAdmin address

func ProposeAdmin(cur realm, next address) {
	assertNoSend(cur)
	assertAdmin(cur)
	if !next.IsValid() {
		panic("nsnft: invalid address")
	}
	pendingAdmin = next
	chain.Emit("AdminProposed", "to", next.String())
}

// CancelAdminProposal withdraws an outstanding proposal. Available to the
// sitting admin only — the proposed address declining is just never
// calling AcceptAdmin.
func CancelAdminProposal(cur realm) {
	assertNoSend(cur)
	assertAdmin(cur)
	pendingAdmin = ""
	chain.Emit("AdminProposalCancelled")
}

// AcceptAdmin completes the handover. Called BY the incoming admin, which
// is the whole point: it proves the address exists and can sign.
func AcceptAdmin(cur realm) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("nsnft: no proposal for you to accept")
	}
	prev := admin
	admin = caller
	pendingAdmin = ""
	chain.Emit("AdminTransferred", "from", prev.String(), "to", admin.String())
}

func PendingAdmin() address { return pendingAdmin }

func Trust(cur realm, registry address) {
	assertNoSend(cur)
	assertAdmin(cur)
	if !registry.IsValid() {
		panic("nsnft: invalid address")
	}
	if !trusted[registry.String()] {
		trusted[registry.String()] = true
		trustedList = append(trustedList, registry.String())
	}
	chain.Emit("RegistryTrusted", "addr", registry.String())
}

// Untrust is deliberately unguarded by any timelock: removing a power is
// the safe direction, and a registry that has gone wrong should be
// stoppable in one transaction rather than after a waiting period.
func Untrust(cur realm, registry address) {
	assertNoSend(cur)
	assertAdmin(cur)
	delete(trusted, registry.String())
	out := []string{}
	for _, a := range trustedList {
		if a != registry.String() {
			out = append(out, a)
		}
	}
	trustedList = out
	chain.Emit("RegistryUntrusted", "addr", registry.String())
}

func IsTrusted(registry address) bool { return trusted[registry.String()] }

// Trusted lists every address that may mint or burn. See trustedList.
func Trusted() string {
	out := ""
	for i, a := range trustedList {
		if i > 0 {
			out += ","
		}
		out += a
	}
	return out
}

func SetURIBase(cur realm, base string) {
	assertNoSend(cur)
	assertAdmin(cur)
	uriBase = base
}

func URIBase() string { return uriBase }

// ---------------------------------------------------------------------
// mint and burn — registry only
// ---------------------------------------------------------------------

/*
Mint creates a token, optionally already held in place.

`lockBits` is the hold it starts with — a free-tier name is minted locked
so there is never an instant in which it could be approved and sold
before the registry got round to locking it. Zero for an ordinary paid
name.
*/
func Mint(cur realm, to address, tid string, lockBits int) {
	assertNoSend(cur)
	assertTrusted(cur)
	if !to.IsValid() {
		panic("nsnft: invalid recipient")
	}
	if tid == "" {
		panic("nsnft: empty token id")
	}
	if !validLockBits(lockBits) {
		panic("nsnft: lock bits out of range")
	}
	if err := nft.Mint(to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	bump(tid)
	if lockBits != 0 {
		locks[tid] = lockBits
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
*/
func Burn(cur realm, tid string) {
	assertNoSend(cur)
	assertTrusted(cur)
	if err := nft.Burn(grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	// A hold on a token that no longer exists would silently apply to the
	// NEXT token minted with this id — a reclaimed name arriving frozen.
	delete(locks, tid)
	// The epoch goes too. The next mint draws a fresh one from lastSeq,
	// which can never equal anything this token had before.
	delete(epochs, tid)
}

/*
SetLock turns one hold bit on or off. Trusted registry only.

The registry decides what a bit means; this realm only guarantees that
while any bit is set, nothing moves the token.
*/
func SetLock(cur realm, tid string, bit int, on bool) {
	assertNoSend(cur)
	assertTrusted(cur)
	/* THE BIT IS RANGE-CHECKED BEFORE IT IS SHIFTED. The previous check
	   tested 1<<bit, and an audit caught what that does: a bit of 64 or
	   more shifts to zero, passes, and the call quietly changes nothing
	   while still emitting LockChanged — and a negative bit was shifted
	   before it was ever compared. Harmless while every caller passes 0
	   or 1, and unacceptable in the one realm that can never be patched
	   to fix it. */
	if !validLockBit(bit) {
		panic("nsnft: lock bit out of range")
	}
	if OwnerOf(tid) == "" {
		panic("nsnft: no such token")
	}
	v := locks[tid]
	if on {
		v |= 1 << bit
	} else {
		v &^= 1 << bit
	}
	if v == 0 {
		delete(locks, tid)
	} else {
		locks[tid] = v
	}
	/* A NEW HOLD WITHDRAWS THE STANDING APPROVAL. A hold stops an
	   approval being USED, not the approval itself — so a name frozen
	   mid-dispute kept whatever approval it had, and it became live again
	   the moment the name was unfrozen. An audit caught it. The owner can
	   re-approve afterwards; nobody else's pre-dispute permission
	   survives. Operator grants are per owner, not per token, and are the
	   owner's to revoke. */
	if on {
		nft.ClearApproval(grc721.TokenID(tid))
	}
	chain.Emit("LockChanged", "tid", tid, "bits", itoa(int64(v)))
}

/*
RevokeApproval withdraws a token's per-token approval.

GRC-721 has no way to do this: Approve refuses the zero address, so an
approval could only be overwritten by approving somebody else. For a realm
that can never gain a function later, "you cannot take back a permission
you gave" was not an acceptable property to freeze in.

The owner, or an operator acting for the owner — the same two callers
Approve accepts.
*/
func RevokeApproval(cur realm, tid string) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	owner := OwnerOf(tid)
	if owner == "" {
		panic("nsnft: no such token")
	}
	if caller != owner && !nft.IsApprovedForAll(owner, caller) {
		panic("nsnft: only the owner or an operator may revoke an approval")
	}
	nft.ClearApproval(grc721.TokenID(tid))
	chain.Emit("ApprovalRevoked", "tid", tid)
}

func assertUnlocked(tid string) {
	if locks[tid] != 0 {
		panic("nsnft: this token is held by the registry and cannot be approved or moved")
	}
}

// LockBits reports the current hold; 0 means free to move.
func LockBits(tid string) int { return locks[tid] }

func IsLocked(tid string) bool { return locks[tid] != 0 }

// Epoch reports the ownership epoch of a token, or 0 for one that does
// not exist. See epochs.
func Epoch(tid string) int64 { return epochs[tid] }

// ---------------------------------------------------------------------
// GRC-721, public — this is the surface the outside world holds
// ---------------------------------------------------------------------

func Approve(cur realm, to address, tid string) {
	assertNoSend(cur)
	assertUnlocked(tid)
	if err := nft.Approve(cur.Previous().Address(), to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNoSend(cur)
	if err := nft.SetApprovalForAll(cur.Previous().Address(), operator, approved); err != nil {
		panic(err)
	}
}

/*
TransferFrom carries NO expiry check, and that is a deliberate reversal
of what nslogic does today.

nslogic refuses to transfer an expired token, as an anti-scam measure —
it stops somebody selling a name that is about to evaporate. That rule is
right, and it belongs in the REGISTRY, not here: this realm does not know
what expiry is and must not learn, because the moment it holds policy it
stops being the small frozen thing it exists to be.

The registry keeps the rule by refusing to RESOLVE an expired name. A
buyer can still acquire a worthless token from a careless seller, which
is true of every NFT on every chain, and the marketplace disclaimers say
so. What they cannot do is acquire a name that resolves.
*/
func TransferFrom(cur realm, from, to address, tid string) {
	assertNoSend(cur)
	assertUnlocked(tid)
	if err := nft.TransferFrom(cur.Previous().Address(), from, to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	bump(tid)
}

func SafeTransferFrom(cur realm, from, to address, tid string) {
	assertNoSend(cur)
	assertUnlocked(tid)
	if err := nft.SafeTransferFrom(cur.Previous().Address(), from, to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	bump(tid)
}

// ---------------------------------------------------------------------
// reads
// ---------------------------------------------------------------------

/*
OwnerOf answers the zero address for a token that does not exist, rather
than panicking.

The registry calls this on EVERY resolve — that is the whole design, one
truth rather than a cached copy that goes stale the moment a sale settles
somewhere we did not watch. A panic on an unknown id would make every
caller wrap it, and the wrapper that gets forgotten is the one that turns
a missing name into a broken page.
*/
func OwnerOf(tid string) address {
	owner, err := nft.OwnerOf(grc721.TokenID(tid))
	if err != nil {
		return ""
	}
	return owner
}

func Exists(tid string) bool { return OwnerOf(tid) != "" }

func BalanceOf(owner address) int64 {
	n, err := nft.BalanceOf(owner)
	if err != nil {
		return 0
	}
	return n
}

func GetApproved(tid string) address {
	a, err := nft.GetApproved(grc721.TokenID(tid))
	if err != nil {
		return ""
	}
	return a
}

func IsApprovedForAll(owner, operator address) bool {
	return nft.IsApprovedForAll(owner, operator)
}

// TokenURI is built here rather than stored per token: sixty thousand
// names storing their own near-identical URI is sixty thousand times the
// storage for a string that is the base plus the id.
func TokenURI(tid string) string {
	if uriBase == "" {
		return ""
	}
	return uriBase + tid
}

func Name() string      { return nft.Name() }
func Symbol() string    { return nft.Symbol() }
func TokenCount() int64 { return nft.TokenCount() }

/*
Render builds its string by concatenation rather than with ufmt.

NO DEPENDENCIES THIS REALM DOES NOT ABSOLUTELY NEED. It is meant to be
deployed once and never replaced, so every import is a permanent
commitment to somebody else's package — and a formatter, for one page of
text, is not worth that. grc721 is the only import here because it IS the
thing this realm is.
*/
func Render(path string) string {
	return "# Meme Name Service — tokens\n\n" +
		"This realm is the ownership ledger and nothing else. Prices, expiry,\n" +
		"profiles and every rule live in the registry.\n\n" +
		"- tokens: " + itoa(nft.TokenCount()) + "\n" +
		"- admin: " + admin.String() + "\n" +
		"- URI base: " + uriBase + "\n\n" +
		"Integrators: this address is stable. The registry behind it is not,\n" +
		"and is meant not to be.\n"
}

// itoa, because importing a package to print one number would outlast
// every reason we had for wanting it.
func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}
