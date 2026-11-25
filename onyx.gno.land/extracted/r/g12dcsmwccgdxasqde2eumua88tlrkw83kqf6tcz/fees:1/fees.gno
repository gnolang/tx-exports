// Package fees is the entry-fee rate each account pays on Mimir's pool and VS
// markets (the gno.land port of contracts/MimirFees.sol).
//
// Everyone pays BaseBps (0.5%) of what they put in. A lower rate needs a fee
// ticket signed by the signer: "this account is tier T until `expires`". The
// account submits it with ApplyTicket, normally in the same transaction as its
// stake. Mimir's server signs no tickets.
//
// Signatures are ed25519 over TicketMessage(account, tier, expires), which
// binds the chain id and this realm's path, so a ticket cannot be replayed on
// another network or another deployment.
//
// Trust: the signer can only lower an account's rate (BaseBps is the most
// anyone pays), so a stolen signer key costs the protocol revenue, never a user
// money. The owner revokes it at once (RevokeSigner); a new signer waits
// SignerTimelock, so a stolen owner key cannot install one quietly. Both retire
// every ticket the old signer issued (each ticket carries the signer epoch it
// was applied under).
package fees

import (
	"chain"
	"chain/runtime"
	"crypto/ed25519"
	"encoding/hex"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Deployer is the initial owner, the address that deploys these realms.
const Deployer = address("g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz")

const (
	BaseBps   = int64(50) // 0.5%
	HolderBps = int64(25) // 0.25%: tier 1 ticket
	WhaleBps  = int64(10) // 0.1%: tier 2 ticket

	// A ticket may not outlive this, so a discount ends within two days.
	MaxTicketSeconds         = int64(2 * 24 * 60 * 60)
	OwnershipTimelockSeconds = int64(2 * 24 * 60 * 60)
	SignerTimelockSeconds    = int64(2 * 24 * 60 * 60)
)

type Ticket struct {
	Tier    int
	Expires int64
	Epoch   int64
}

var (
	tickets avl.Tree // address -> *Ticket

	signer          []byte // ed25519 public key; nil when revoked or unset
	owner           address
	pendingOwner    address
	pendingOwnerEta int64
	// Bumped on every signer change or revoke: tickets applied under an earlier epoch pay BaseBps.
	signerEpoch      int64
	pendingSigner    []byte
	pendingSignerEta int64
	signerEverSet    bool
	selfPath         string
)

func init(cur realm) {
	owner = Deployer
	selfPath = cur.PkgPath()
	chain.Emit("OwnershipTransferred", "previous", "", "next", owner.String())
}

func now() int64 { return time.Now().Unix() }

func assertOwner(cur realm) {
	if cur.Previous().Address() != owner {
		panic("NotOwner")
	}
}

func decodeKey(pubHex string) []byte {
	k, err := hex.DecodeString(pubHex)
	if err != nil || len(k) != 32 {
		panic("BadSignerKey")
	}
	return k
}

// SetInitialSigner installs the first signer, once, as the Solidity
// constructor did. Every later change goes through the timelock.
func SetInitialSigner(cur realm, pubHex string) {
	assertOwner(cur)
	if signerEverSet {
		panic("SignerAlreadySet")
	}
	signer = decodeKey(pubHex)
	signerEverSet = true
	chain.Emit("SignerChanged", "previous", "", "next", pubHex)
}

// RevokeSigner is the emergency stop: no ticket verifies any more, and the
// ones applied stop counting.
func RevokeSigner(cur realm) {
	assertOwner(cur)
	chain.Emit("SignerChanged", "previous", hex.EncodeToString(signer), "next", "")
	signer = nil
	signerEverSet = true
	signerEpoch++
}

func QueueSigner(cur realm, pubHex string) {
	assertOwner(cur)
	pendingSigner = decodeKey(pubHex)
	pendingSignerEta = now() + SignerTimelockSeconds
	chain.Emit("SignerQueued", "next", pubHex, "eta", strconv.FormatInt(pendingSignerEta, 10))
}

// ExecuteSigner is permissionless once due, like the market realms' queued changes.
func ExecuteSigner(cur realm) {
	if pendingSignerEta == 0 {
		panic("NothingQueued")
	}
	if now() < pendingSignerEta {
		panic("Timelocked")
	}
	chain.Emit("SignerChanged", "previous", hex.EncodeToString(signer), "next", hex.EncodeToString(pendingSigner))
	signer = pendingSigner
	signerEverSet = true
	signerEpoch++
	pendingSigner = nil
	pendingSignerEta = 0
}

func TransferOwnership(cur realm, next address) {
	assertOwner(cur)
	if !next.IsValid() {
		panic("ZeroAddress")
	}
	pendingOwner = next
	pendingOwnerEta = now() + OwnershipTimelockSeconds
	chain.Emit("OwnershipTransferStarted", "previous", owner.String(), "next", next.String(),
		"eta", strconv.FormatInt(pendingOwnerEta, 10))
}

func CancelOwnershipTransfer(cur realm) {
	assertOwner(cur)
	if pendingOwner == "" {
		panic("NotPendingOwner")
	}
	chain.Emit("OwnershipTransferCancelled", "pending", pendingOwner.String())
	pendingOwner = ""
	pendingOwnerEta = 0
}

func AcceptOwnership(cur realm) {
	caller := cur.Previous().Address()
	if pendingOwner == "" || caller != pendingOwner {
		panic("NotPendingOwner")
	}
	if now() < pendingOwnerEta {
		panic("Timelocked")
	}
	chain.Emit("OwnershipTransferred", "previous", owner.String(), "next", caller.String())
	owner = caller
	pendingOwner = ""
	pendingOwnerEta = 0
}

// TicketMessage is the exact byte string the signer signs for (account, tier, expires).
func TicketMessage(account address, tier int, expires int64) string {
	return ufmt.Sprintf("Mimir Fees v1|%s|%s|%s|%d|%d",
		runtime.ChainID(), selfPath, account.String(), tier, expires)
}

// ApplyTicket stores a signed tier for the caller: a ticket is bound to the
// account it was signed for.
func ApplyTicket(cur realm, tier int, expires int64, sigHex string) {
	account := cur.Previous().Address()
	if tier < 0 || tier > 2 {
		panic("BadTier")
	}
	if expires <= now() || expires > now()+MaxTicketSeconds {
		panic("BadExpiry")
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != 64 || signer == nil {
		panic("BadSignature")
	}
	if !ed25519.Verify(signer, []byte(TicketMessage(account, tier, expires)), sig) {
		panic("BadSignature")
	}
	tickets.Set(account.String(), &Ticket{Tier: tier, Expires: expires, Epoch: signerEpoch})
	chain.Emit("TicketApplied", "account", account.String(), "tier", strconv.Itoa(tier),
		"expires", strconv.FormatInt(expires, 10))
}

// EntryBps is the account's entry fee in basis points right now.
func EntryBps(account address) int64 {
	v := tickets.Get(account.String())
	if v == nil {
		return BaseBps
	}
	t := v.(*Ticket)
	if t.Expires <= now() || t.Epoch != signerEpoch {
		return BaseBps
	}
	switch t.Tier {
	case 2:
		return WhaleBps
	case 1:
		return HolderBps
	}
	return BaseBps
}

func Owner() address        { return owner }
func PendingOwner() address { return pendingOwner }
func SignerEpoch() int64    { return signerEpoch }
func Signer() string        { return hex.EncodeToString(signer) }

func Render(path string) string {
	if path != "" {
		return ufmt.Sprintf("Entry fee for %s: %d bps\n", path, EntryBps(address(path)))
	}
	return ufmt.Sprintf("# Mimir fees\n\nBase entry fee: %d bps (0.5%%). Tier 1: %d bps. Tier 2: %d bps.\n\n"+
		"Owner: %s\n\nSigner epoch: %d\n\nLook up an account: `:<address>`\n",
		BaseBps, HolderBps, WhaleBps, owner.String(), signerEpoch)
}
