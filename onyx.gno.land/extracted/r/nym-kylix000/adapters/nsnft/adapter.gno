// Package nsnft is the Kylix adapter for MNS name NFTs
// (gno.land/r/nym-mnsrehearsal001/nsnft/v2), which knows nothing of Kylix.
// Item ids are MNS token ids, "<label>*<domain>", e.g. "alice*gnoland".
//
// Move crosses into nsnft as this realm's sub-identity k/<slot address>, so
// an owner's approval to SpenderFor(slot) serves exactly one offer.
//
// What an item id fixes. An MNS token is a lease on a name: the ledger
// (nsnft) holds ownership and nothing else, and the lease lives in the
// registry (nsdata/v2). nsnft.TransferFrom deliberately does not check the
// lease, so a lapsed name still moves, and a buyer would receive a name
// nobody can resolve and anyone may soon reclaim. So, like MNS's own
// marketplace, this adapter asks the registry, and refuses a name, in both
// Approved and Move, unless all of these hold:
//   - the id is "<label>*<domain>" with both parts present;
//   - nsdata/v2 is still a registry nsnft trusts, and it has a record for
//     the name;
//   - the name is not frozen and carries no registry hold (a free-tier name
//     is held until it is paid for);
//   - the lease is valid now and has at least MinLeaseLeft (31 days) to run,
//     which is longer than any Kylix offer can stay open, so a name that
//     passes when the offer is posted cannot lapse before the offer expires;
//   - the owner approved this offer's address for this one name: an
//     approval for all names is not used, because the move does not consume
//     it (see notSingle).
//
// No function here panics on an unknown or malformed id: OwnerOf answers
// the empty address and Approved false.
package nsnft

import (
	"chain"
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/r/nym-kylix000/kylix"
	"gno.land/r/nym-mnsrehearsal001/nsdata/v2"
	"gno.land/r/nym-mnsrehearsal001/nsnft/v2"
)

const (
	target   = "gno.land/r/nym-mnsrehearsal001/nsnft/v2"
	registry = "gno.land/r/nym-mnsrehearsal001/nsdata/v2"

	// MinLeaseLeft is the lease, in seconds, a name must have left to be
	// offered or moved: one day more than the longest an offer can stay
	// open (kylix.MaxExpiryBlocks at five-second blocks). A name with less
	// than this left is refused; one with exactly this much passes.
	MinLeaseLeft = (kylix.MaxExpiryBlocks/kylix.BlocksPerDay + 1) * 24 * 60 * 60
)

var selfPath string

func init(cur realm) {
	selfPath = cur.PkgPath()
	kylix.RegisterAdapter(cross(cur), target, "MNS Names (v2)", Move, OwnerOf)
	kylix.RegisterApprovalCheck(cross(cur), Approved)
}

// SpenderFor is the address an owner approves in nsnft for the offer whose
// Kylix slot is slot: nsnft.Approve(SpenderFor(slot), "<label>*<domain>").
func SpenderFor(slot address) address {
	return chain.DerivePkgSubAddr(selfPath, "k/"+slot.String())
}

// Move is the Kylix MoveFn. It refuses what Approved refuses, so the rule
// holds even for a caller that skipped Kylix's checks.
func Move(cur realm, from, to address, itemID string) error {
	if why := Unmovable(itemID); why != "" {
		return errors.New("mns adapter: " + why)
	}
	if !singleApproval(itemID, SpenderFor(cur.Previous().Address())) {
		return errors.New("mns adapter: " + notSingle)
	}
	sub := cur.Sub("k/" + cur.Previous().Address().String())
	nsnft.TransferFrom(cross(sub), from, to, itemID)
	return nil
}

// OwnerOf is the Kylix OwnerFn: the ledger's owner, or the empty address.
func OwnerOf(id kylix.ItemID) address { return nsnft.OwnerOf(string(id)) }

// Approved is the Kylix ApprovedFn: spender is approved for this one name
// (an approval for all is not used; see notSingle), and its lease will
// outlast the offer.
func Approved(id kylix.ItemID, spender address) bool {
	name := string(id)
	return Unmovable(name) == "" && singleApproval(name, spender)
}

// notSingle explains why an approval for all names is refused: the transfer
// clears a single-name approval, whose deposit is then refunded to the
// settler, but leaves an approval for all in place, while the settler still
// pays for the receiver's new entries.
const notSingle = "approve this offer's address for the name itself; an approval for all names is not used, because the move does not consume it"

func singleApproval(name string, spender address) bool {
	a := nsnft.GetApproved(name)
	return a != "" && a == spender
}

// Unmovable returns why the name cannot be offered or moved now, or "".
func Unmovable(tid string) string {
	label, domain, ok := splitTokenID(tid)
	if !ok {
		return "an MNS item id is <label>*<domain>"
	}
	if nsnft.IsLocked(tid) {
		return "the registry holds " + tid + " (frozen, or a free-tier name not yet paid for)"
	}
	if !nsnft.IsTrusted(chain.PackageAddress(registry)) {
		return "the MNS registry this adapter reads is no longer trusted by the ledger"
	}
	exists := nsdata.NameExists(label, domain)
	var frozen, valid bool
	var expires int64
	if exists {
		_, _, expires, _, frozen, _ = nsdata.GetNameInfo(label, domain)
		valid = nsdata.IsNameValid(label, domain)
	}
	return leaseProblem(tid, exists, frozen, valid, expires, time.Now().Unix())
}

// leaseProblem is the lease decision, given the registry's answers for tid:
// whether it has a record, whether the name is frozen, whether the
// registry calls the lease valid now, and when it ends (unix seconds).
func leaseProblem(tid string, exists, frozen, valid bool, expires, now int64) string {
	switch {
	case !exists:
		return "the registry has no record of " + tid
	case frozen:
		return tid + " is frozen"
	case !valid:
		return "the lease on " + tid + " has expired"
	case expires-now < MinLeaseLeft:
		return "the lease on " + tid + " has less than " + strconv.Itoa(MinLeaseLeft/86400) +
			" days left, so it could end before an offer expires; renew it first"
	}
	return ""
}

// splitTokenID splits "<label>*<domain>": exactly one '*', both parts
// present.
func splitTokenID(tid string) (label, domain string, ok bool) {
	i := strings.IndexByte(tid, '*')
	if i <= 0 || i >= len(tid)-1 || strings.IndexByte(tid[i+1:], '*') >= 0 {
		return "", "", false
	}
	return tid[:i], tid[i+1:], true
}
