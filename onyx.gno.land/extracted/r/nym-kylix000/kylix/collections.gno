package kylix

import (
	"chain"
	"strings"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
)

// ItemID names an item when Kylix asks a collection about it.
//
// It is declared here, not as a plain string, so that only realm code can
// implement OwnerFn or ApprovedFn: a /p/ package cannot import this realm,
// so it cannot name this type. That closes the one gap a non-crossing
// callback would otherwise leave open (a top-level /p/ function called from
// here would run with this realm's storage authority; see
// gno-security-guide.md section 3C).
type ItemID string

// MoveFn moves one item from `from` to `to`. Kylix calls it crossing, as the
// offer's slot sub-address: inside it, cur.Previous().Address() is the slot
// that `from` approved for that one offer. It must move the item only if
// that address is approved for it, and return an error (or panic) otherwise.
// Because it is a crossing function, it can only be declared in a realm.
//
// An adapter's MoveFn instead crosses into its target collection as its own
// sub-identity "k/<slot address>" (see RegisterAdapter).
type MoveFn func(cur realm, from, to address, itemID string) error

// OwnerFn reports who owns an item, or the empty address if nobody does.
// Kylix calls it without crossing, so it runs with its collection's storage
// and has no realm value with which to call back into Kylix.
type OwnerFn func(itemID ItemID) address

// ApprovedFn reports whether spender may move the item now. It is optional
// (see RegisterApprovalCheck); like OwnerFn it is called without crossing.
type ApprovedFn func(itemID ItemID, spender address) bool

type collection struct {
	name     string
	move     MoveFn
	ownerOf  OwnerFn
	approved ApprovedFn // optional
	target   string     // adapters only: the collection realm the adapter drives
}

// Collection describes a registered collection. All strings are untrusted
// text; escape them before rendering.
type Collection struct {
	Key           string // the registering realm's package path
	Name          string
	Adapter       bool   // registered with RegisterAdapter
	Target        string // adapters only: the collection realm it drives
	Official      bool   // the key is under Kylix's own namespace
	Label         string // "official collection", "official adapter", "third-party collection" or "third-party adapter"
	ApprovalCheck bool   // an ApprovedFn is registered
}

const (
	maxCollectionNameLen = 64
	maxTargetLen         = 200
	adapterSubPrefix     = "k/"
)

var collections avl.Tree // realm pkgpath -> *collection

// RegisterItem registers the calling realm as a collection whose items can
// be traded. The collection key is the caller's package path, so no realm can
// register under another's name, and a realm registers once: what Kylix
// calls for its items never changes after offers have been posted.
//
// Kylix trusts a collection only about its own items. After every move it
// checks ownerOf(id) == to, so a collection that says it moved an item it
// did not can only hurt people who chose to want that collection's items.
func RegisterItem(cur realm, name string, move MoveFn, ownerOf OwnerFn) {
	guard(cur)
	register(0, cur.Previous(), name, "", move, ownerOf)
}

// RegisterAdapter registers the calling realm as an adapter for an existing
// collection realm, target, that knows nothing of Kylix. The key is still
// the adapter's own package path; target is recorded for display.
//
// The difference is the address an owner approves in the target collection:
// not the offer's slot but the adapter's sub-address
// DerivePkgSubAddr(adapterPath, "k/"+slotAddress), which ApproveTarget
// returns. The adapter's MoveFn crosses into the target as
// cur.Sub("k/"+cur.Previous().Address()), so only that one slot can ever
// produce the identity the owner approved.
//
// An adapter whose path sits under Kylix's own namespace is labelled
// official, any other third-party. The label is information only; nothing
// is blocked on it.
func RegisterAdapter(cur realm, target, name string, move MoveFn, ownerOf OwnerFn) {
	guard(cur)
	if !validTarget(target) {
		panic("kylix: target must be the package path of a realm, e.g. gno.land/r/owner/collection")
	}
	prev := cur.Previous()
	if target == prev.PkgPath() {
		panic("kylix: an adapter cannot target itself; use RegisterItem")
	}
	register(0, prev, name, target, move, ownerOf)
}

// RegisterApprovalCheck adds an ApprovedFn to the calling realm's
// registration, once. SettleRing then refuses, before anything moves and
// naming the leg, an item that is not approved for ApproveTarget(...).
func RegisterApprovalCheck(cur realm, approved ApprovedFn) {
	guard(cur)
	c := getCollection(cur.Previous().PkgPath())
	if c == nil {
		panic("kylix: register the collection first")
	}
	if approved == nil {
		panic("kylix: approved is required")
	}
	if c.approved != nil {
		panic("kylix: approval check already registered")
	}
	c.approved = approved
	chain.Emit("ApprovalCheckRegistered", "key", cur.Previous().PkgPath())
}

func register(_ int, prev realm, name, target string, move MoveFn, ownerOf OwnerFn) {
	key := prev.PkgPath()
	if key == "" {
		panic("kylix: only a realm can register a collection")
	}
	if prev.IsEphemeral() {
		panic("kylix: a MsgRun package cannot register a collection")
	}
	if strings.Contains(key, "#") {
		panic("kylix: register from the realm itself, not from a sub-identity")
	}
	if move == nil || ownerOf == nil {
		panic("kylix: move and ownerOf are both required")
	}
	if !validName(name) {
		panic("kylix: collection name must be 1-64 bytes of printable UTF-8")
	}
	if collections.Has(key) {
		panic("kylix: collection already registered")
	}
	collections.Set(key, &collection{name: name, move: move, ownerOf: ownerOf, target: target})
	chain.Emit("CollectionRegistered", "key", key, "name", name, "target", target)
}

// ApproveTarget returns the exact address an owner must approve for the
// offer with this owner and nonce that gives an asset under key: the slot
// for a token or a native collection, the adapter's derived sub-address for
// an adapter. It reads only Kylix's own state.
func ApproveTarget(owner address, nonce uint64, key string) address {
	slot := SlotAddress(owner, nonce)
	if c := getCollection(key); c != nil && c.target != "" {
		return chain.DerivePkgSubAddr(key, adapterSubPrefix+slot.String())
	}
	return slot
}

// IsCollection reports whether key is a registered collection.
func IsCollection(key string) bool { return collections.Has(key) }

// CollectionName returns the display name a collection registered with.
// It is untrusted text; escape it before rendering.
func CollectionName(key string) string {
	c := getCollection(key)
	if c == nil {
		return ""
	}
	return c.name
}

// GetCollection describes a registered collection.
func GetCollection(key string) (Collection, bool) {
	c := getCollection(key)
	if c == nil {
		return Collection{}, false
	}
	return describe(key, c), true
}

// IsOfficial reports whether key sits under Kylix's own namespace, e.g.
// gno.land/r/<namespace>/... for Kylix at gno.land/r/<namespace>/kylix.
func IsOfficial(key string) bool {
	ns := namespacePrefix()
	return ns != "" && strings.HasPrefix(key, ns)
}

func describe(key string, c *collection) Collection {
	return Collection{
		Key:           key,
		Name:          c.name,
		Adapter:       c.target != "",
		Target:        c.target,
		Official:      IsOfficial(key),
		Label:         collectionKind(key),
		ApprovalCheck: c.approved != nil,
	}
}

// namespacePrefix is the first three segments of Kylix's own path plus a
// slash, e.g. "gno.land/r/nym-kylix000/".
func namespacePrefix() string {
	parts := strings.SplitN(selfPath, "/", 4)
	if len(parts) < 3 {
		return ""
	}
	return parts[0] + "/" + parts[1] + "/" + parts[2] + "/"
}

func getCollection(key string) *collection {
	v := collections.Get(key)
	if v == nil {
		return nil
	}
	return v.(*collection)
}

func validName(s string) bool {
	if len(s) == 0 || len(s) > maxCollectionNameLen || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		switch {
		case r < 0x20, r == 0x7f, r >= 0x80 && r < 0xa0: // control characters
			return false
		case r >= 0x200b && r <= 0x200f, r >= 0x2028 && r <= 0x202e, r >= 0x2066 && r <= 0x2069, r == 0xfeff:
			return false // zero-width, line separators and bidi overrides
		}
	}
	return true
}

// validTarget accepts a realm package path: <domain>/r/<rest>, lowercase
// letters, digits and . _ - / only.
func validTarget(s string) bool {
	if len(s) == 0 || len(s) > maxTargetLen || !strings.Contains(s, "/r/") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '.', c == '_', c == '-', c == '/':
		default:
			return false
		}
	}
	return !strings.Contains(s, "//") && !strings.HasSuffix(s, "/")
}
