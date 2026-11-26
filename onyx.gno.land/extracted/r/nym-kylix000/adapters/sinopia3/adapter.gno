// Package sinopia3 is the Kylix adapter for Sinopia3 art
// (gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core), which
// knows nothing of Kylix. Item ids are "<collection id>/<token id>", both
// positive decimal numbers without leading zeros.
//
// Move crosses into the core as this realm's sub-identity k/<slot address>,
// so an owner's approval to SpenderFor(slot) serves exactly one offer.
//
// What an item id fixes. Once a collection is Final its art is a pure
// function of the collection's engine, its parameters and the token's seed,
// none of which the owner can change. Two cases are refused, because the
// value could change between posting and settlement while the id stays the
// same, so Approved answers false and Kylix reports the item as not ready:
//   - a collection that is not Final yet: its tokens are unrevealed, and its
//     lock hook vetoes every move anyway;
//   - a collection whose engine is "living": its art depends on the token's
//     transfer history, which the owner can reset by moving the token away
//     and back before settlement;
//   - a collection whose engine nobody has checked: an engine is code in its
//     own realm, and a realm with state could change what it draws even when
//     its manifest says it is not living. Accepted are engines that the
//     Sinopia3 admin has marked "reviewed", and the engines listed in
//     statelessEngines, whose realms Kylix has read: they keep no state and
//     draw only from an immutable p/ package and the token's seed.
//
// No function here panics on an unknown or malformed id: OwnerOf answers
// the empty address and Approved false, so such an offer is simply never
// ready, never blocks a batch query, and expires like any other.
package sinopia3

import (
	"chain"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/types/v1"
	"gno.land/p/nt/grc721/v0"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
	"gno.land/r/nym-kylix000/kylix"
)

const target = "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"

// statelessEngines are engines Kylix has reviewed itself (see the package
// comment). Genesis: the realm holds one constant and delegates Render and
// Traits to gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/art/genesis/v1,
// which reads only the seed and params, never the token's moves or heights.
var statelessEngines = []string{
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/engines/genesis",
}

var selfPath string

func init(cur realm) {
	selfPath = cur.PkgPath()
	kylix.RegisterAdapter(cross(cur), target, "Sinopia3 Art", Move, OwnerOf)
	kylix.RegisterApprovalCheck(cross(cur), Approved)
}

// SpenderFor is the address an owner approves in the core for the offer
// whose Kylix slot is slot: core.Approve(cid, tid, SpenderFor(slot)).
func SpenderFor(slot address) address {
	return chain.DerivePkgSubAddr(selfPath, "k/"+slot.String())
}

// Move is the Kylix MoveFn. It refuses what Approved refuses, so the rule
// holds even for a caller that skipped Kylix's checks.
func Move(cur realm, from, to address, itemID string) error {
	cid, tid, ok := parseID(itemID)
	if !ok {
		return errors.New("sinopia3 adapter: item id must be <collection id>/<token id>")
	}
	if why := unmovable(cid, tid); why != "" {
		return errors.New("sinopia3 adapter: " + why)
	}
	if !singleApproval(cid, tid, SpenderFor(cur.Previous().Address())) {
		return errors.New("sinopia3 adapter: " + notSingle)
	}
	sub := cur.Sub("k/" + cur.Previous().Address().String())
	core.TransferFrom(cross(sub), cid, tid, from, to)
	return nil
}

// notSingle explains why an approval for all of a collection is refused: the
// transfer clears a single-token approval, whose deposit is then refunded to
// the settler, but leaves an approval for all in place, while the settler
// still pays for the receiver's new entries.
const notSingle = "approve this offer's address for the token itself; an approval for all tokens is not used, because the move does not consume it"

// singleApproval reports whether spender is approved for exactly this token.
func singleApproval(cid, tid string, spender address) bool {
	a, err := core.Token(cid).GetApproved(grc721.TokenID(tid))
	return err == nil && a != "" && a == spender
}

// OwnerOf is the Kylix OwnerFn: the owner, or the empty address for an
// unknown or malformed id.
func OwnerOf(id kylix.ItemID) address {
	cid, tid, ok := parseID(string(id))
	if !ok {
		return ""
	}
	owner, err := core.OwnerOf(cid, tid)
	if err != nil {
		return ""
	}
	return owner
}

// Approved is the Kylix ApprovedFn: spender is approved for this one token
// (an approval for all is not used; see notSingle), and the token's value is
// fixed (see the package comment).
func Approved(id kylix.ItemID, spender address) bool {
	cid, tid, ok := parseID(string(id))
	return ok && unmovable(cid, tid) == "" && singleApproval(cid, tid, spender)
}

// unmovable returns why the token cannot be offered now, or "". cid must
// already be a known collection (parseID checks it).
func unmovable(cid, tid string) string {
	info := core.Info(cid)
	if info.State != types.StateFinal || core.TokenSeed(cid, tid) == "" {
		return "the collection is not final yet, so its art is unrevealed and its tokens cannot move"
	}
	if core.EngineManifest(info.EngineID).Living {
		return "the art of a living engine changes with its transfer history, which the owner can reset before settlement"
	}
	if !engineReviewed(info.EngineID) {
		return "the collection's engine is not reviewed (status " + core.EngineStatus(info.EngineID) +
			"), so its art could change before settlement"
	}
	return ""
}

func engineReviewed(id string) bool {
	for _, e := range statelessEngines {
		if e == id {
			return true
		}
	}
	return core.EngineStatus(id) == "reviewed"
}

// parseID splits "<cid>/<tid>" and accepts it only if both parts are
// canonical positive numbers and the collection exists, so that no core
// function this adapter calls can panic on it.
func parseID(itemID string) (cid, tid string, ok bool) {
	i := strings.IndexByte(itemID, '/')
	if i <= 0 || i >= len(itemID)-1 {
		return "", "", false
	}
	cid, tid = itemID[:i], itemID[i+1:]
	n, ok := canonicalID(cid)
	if !ok || n > core.CollectionCount() {
		return "", "", false
	}
	if _, ok := canonicalID(tid); !ok {
		return "", "", false
	}
	return cid, tid, true
}

// canonicalID accepts 1 to 18 digits with no leading zero, the format the
// core's own parser accepts without panicking.
func canonicalID(s string) (int64, bool) {
	if len(s) == 0 || len(s) > 18 || s[0] == '0' {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}
