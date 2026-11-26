// Package kylix settles trades in a circle. Each person posts an offer, "I
// give X, I want at least Y". When two to six offers form a closed ring,
// anyone can submit the ring and every leg settles in one transaction, or
// nothing moves.
//
// Kylix never holds anyone's assets. Before posting, an owner approves a
// sub-address of this realm that belongs to that one offer (see NextSlot).
// At settlement Kylix acts as that sub-address to move the offer's asset from
// its owner straight to the next owner in the ring.
package kylix

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nym-kylix000/ring/v0"
)

// Offer is one open offer, as decoded from storage (see store.gno). Every
// Offer value is a fresh copy, so nothing outside can alias state.
//
// There is no status field: only open offers are stored. Settling,
// cancelling or pruning an offer deletes it (releasing its storage deposit to
// whoever sent that transaction), and the event emitted says which.
type Offer struct {
	ID    uint64
	Owner address
	Nonce uint64 // per owner; the offer's slot is w/<owner>/<nonce>
	Give  ring.Asset
	Want  ring.Asset
	// Expiry is the last block height at which the offer may settle. Every
	// offer has one (see PostIntent); after it anyone may prune the offer.
	Expiry     int64
	ViaSession bool // posted by a session key
}

const (
	// BlocksPerDay assumes 5 s blocks.
	BlocksPerDay = 17280
	// DefaultExpiryBlocks is the lifetime of an offer posted with expiry 0:
	// about 7 days.
	DefaultExpiryBlocks = 7 * BlocksPerDay
	// MaxExpiryBlocks is the longest lifetime an offer may ask for: about 30
	// days. Every offer expires, so every offer can eventually be pruned.
	MaxExpiryBlocks = 30 * BlocksPerDay

	maxItemIDLen = 64
)

var (
	selfPath string        // this realm's package path, captured in init
	nonces   bptree.BPTree // owner -> uint64, last nonce used by that owner
	lastID   uint64

	// locked is true while SettleRing is moving assets. Every exported
	// function except Render refuses to run while it is set, so foreign code
	// called during a settlement can neither re-enter nor observe the book
	// half settled. A failed transaction rolls it back with everything else.
	locked bool

	// sessionCheck reports whether the transaction was signed by a session
	// key. It is a variable only so that in-package tests can simulate a
	// session signer, which `gno test` cannot produce. Nothing in this
	// package assigns it outside tests.
	sessionCheck = func() bool {
		_, _, _, isSession := runtime.GetSessionInfo()
		return isSession
	}
)

func init(cur realm) {
	selfPath = cur.PkgPath()
}

// NextSlot returns the nonce and the slot address that owner's next offer
// will use. The owner approves the slot for the offered asset, then calls
// PostIntent; both can go in one transaction because the slot is
// deterministic and only the owner can advance their own nonce.
func NextSlot(owner address) (nonce uint64, slot address) {
	if !owner.IsValid() {
		panic("kylix: invalid owner address")
	}
	nonce = lastNonce(owner) + 1
	return nonce, SlotAddress(owner, nonce)
}

// SlotAddress is the sub-address that may move the asset of owner's offer
// with the given nonce. Off chain: chain.DerivePkgSubAddr(<kylix path>,
// "w/<owner>/<nonce>").
func SlotAddress(owner address, nonce uint64) address {
	return chain.DerivePkgSubAddr(selfPath, slotPath(owner, nonce))
}

// PostIntent records an offer: the caller gives giveAmount of a token, or
// one item, and wants at least wantMin of a token, or one item. Kinds are
// "fungible" (key: a grc20reg key, id: empty) and "item" (key: a registered
// collection, id: the item id, amount: 0). expiry is the last block height
// at which the offer may settle: 0 means DefaultExpiryBlocks from now, and it
// may be at most MaxExpiryBlocks from now. It returns the offer id; the
// IntentPosted event carries the expiry it got.
//
// A token offer, or an item offer of an official collection, must be
// deliverable when it is posted: the same check settlement runs first (see
// undeliverable). For a token, the owner holds the amount and has approved
// NextSlot's address for exactly that amount; for an official item, the
// collection says the owner holds it and, if it registered an approval
// check, that ApproveTarget's address may move it. So approve first, then
// post (two messages in one transaction work). Nothing is pulled.
//
// An official collection's functions are Kylix's own code; Kylix holds its
// lock while they run, so they cannot post, cancel or settle, nor read the
// book. An item of a third-party collection is not checked: posting runs no
// third-party code, so a collection cannot bill the poster for storage
// (security review 4, R4-1). Such offers are kept off the home page and are
// checked when someone settles them.
func PostIntent(cur realm, giveKind, giveKey, giveID string, giveAmount int64, wantKind, wantKey, wantID string, wantMin int64, expiry int64) uint64 {
	guard(cur)
	owner := cur.Previous().Address()
	give := mustAsset("give", giveKind, giveKey, giveID, giveAmount)
	want := mustAsset("want", wantKind, wantKey, wantID, wantMin)
	if give.SameAs(want) {
		panic("kylix: an offer cannot give the asset it wants")
	}
	expiry = offerExpiry(expiry, runtime.ChainHeight())

	nonce := lastNonce(owner) + 1
	o := &Offer{
		ID:         lastID + 1,
		Owner:      owner,
		Nonce:      nonce,
		Give:       give,
		Want:       want,
		Expiry:     expiry,
		ViaSession: sessionCheck(),
	}
	why := ""
	if give.Kind == ring.Fungible || IsOfficial(give.Key) {
		locked = true
		why = undeliverable(o)
		locked = false
	}
	if why != "" {
		panic("kylix: give: the offer could not settle now (" + why + "); approve first, then post")
	}
	nonces.Set(owner.String(), nonce)
	lastID++
	storeOffer(o)

	chain.Emit("IntentPosted",
		"id", u64(o.ID),
		"owner", owner.String(),
		"slot", SlotAddress(owner, nonce).String(),
		"give", give.String(),
		"want", want.String(),
		"expiry", strconv.FormatInt(expiry, 10),
	)
	return o.ID
}

// CancelIntent withdraws an open offer. Only its owner may cancel, and not
// through a session key. It calls no foreign code, so nothing can stop an
// owner from cancelling. Cancelling does not revoke the owner's approval of
// the slot; the slot is never used again, but the owner may revoke it at the
// token or collection for tidiness.
func CancelIntent(cur realm, id uint64) {
	guard(cur)
	if sessionCheck() {
		panic("kylix: a session key cannot cancel an offer; sign with the account key")
	}
	o := mustOpen(id)
	if cur.Previous().Address() != o.Owner {
		panic("kylix: only the owner can cancel offer " + u64(id))
	}
	removeOffer(o.ID)
	chain.Emit("IntentCancelled", "id", u64(id), "owner", o.Owner.String())
}

// GetOffer returns an open offer, expired ones included until pruned.
func GetOffer(id uint64) (Offer, bool) {
	assertNotSettling()
	o := loadOffer(id)
	if o == nil {
		return Offer{}, false
	}
	return *o, true
}

// OpenOffers is the number of open offers, expired ones included until they
// are pruned.
func OpenOffers() int {
	assertNotSettling()
	return offers.Size()
}

// guard runs first in every state-changing entry point.
func guard(cur realm) {
	if locked {
		panic("kylix: re-entrant call during settlement")
	}
	// Kylix cannot send coins anywhere, so coins a user sends straight to it
	// would be stuck. Coins attached to a MsgRun or sent to a realm that then
	// calls Kylix went to that caller, not to Kylix, so they are not refused.
	// OriginSend is read only to refuse, never as proof of payment.
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("kylix: do not send coins; trade GNOT as wugnot")
	}
}

// assertNotSettling runs first in every exported read except Render: while
// SettleRing is moving assets the book is already updated but the assets
// are not, so a collection's callback must not be shown that state.
func assertNotSettling() {
	if locked {
		panic("kylix: settlement in progress")
	}
}

// offerExpiry turns PostIntent's expiry argument into a height: 0 means the
// default, a past or current height and one beyond the maximum are refused.
func offerExpiry(expiry, h int64) int64 {
	switch {
	case expiry == 0:
		return h + DefaultExpiryBlocks
	case expiry <= h:
		panic("kylix: expiry must be a future block height, or 0 for the default of " +
			strconv.Itoa(DefaultExpiryBlocks/BlocksPerDay) + " days")
	case expiry > h+MaxExpiryBlocks:
		panic("kylix: expiry may be at most " + strconv.Itoa(MaxExpiryBlocks/BlocksPerDay) +
			" days ahead, height " + strconv.FormatInt(h+MaxExpiryBlocks, 10))
	}
	return expiry
}

func mustOpen(id uint64) *Offer {
	o := loadOffer(id)
	if o == nil {
		panic("kylix: offer " + u64(id) + " is not open (unknown, settled, cancelled or pruned)")
	}
	return o
}

func removeOffer(id uint64) { offers.Remove(offerKey(id)) }

func expired(o *Offer, height int64) bool { return height > o.Expiry }

// mustAsset parses and validates one side of an offer against what is
// registered right now.
func mustAsset(side, kind, key, id string, amount int64) ring.Asset {
	k, ok := ring.ParseKind(kind)
	if !ok {
		panic("kylix: " + side + " kind must be \"fungible\" or \"item\"")
	}
	a := ring.Asset{Kind: k, Key: key, ID: id, Amount: amount}
	if r := a.Validate(); r != "" {
		panic("kylix: " + side + ": " + r)
	}
	switch k {
	case ring.Fungible:
		if tokenOf(key) == nil {
			panic("kylix: " + side + ": token is not in grc20reg")
		}
	case ring.Item:
		if getCollection(key) == nil {
			panic("kylix: " + side + ": collection is not registered with kylix")
		}
		if !validItemID(id) {
			panic("kylix: " + side + ": item id must be 1-64 characters of A-Z a-z 0-9 . _ : / - *")
		}
	}
	return a
}

func validItemID(id string) bool {
	if len(id) == 0 || len(id) > maxItemIDLen {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.', c == '_', c == ':', c == '/', c == '-', c == '*':
		default:
			return false
		}
	}
	return true
}

func lastNonce(owner address) uint64 {
	v := nonces.Get(owner.String())
	if v == nil {
		return 0
	}
	return v.(uint64)
}

func slotPath(owner address, nonce uint64) string {
	return "w/" + owner.String() + "/" + u64(nonce)
}

func u64(n uint64) string { return strconv.FormatUint(n, 10) }
