// Package ring verifies closed trade rings for Kylix.
//
// A ring is a list of legs in order. Leg i gives its asset to the owner of
// leg i+1, and the last leg gives to the first. Verify checks that every hop
// satisfies what the receiving leg wants, using nothing but integer
// comparison: a leg gives its whole amount and the receiver must want at most
// that much. There is no pricing maths and no partial fill.
//
// The package is pure. It holds no state, calls no realm and imports no
// crypto, so the same checks can run on chain, in a solver, and in tests.
package ring

import (
	"strconv"
	"strings"
)

// Kind tells a fungible token from a single item.
type Kind uint8

const (
	// Fungible is a GRC20 token, named by its grc20reg key.
	Fungible Kind = 1
	// Item is one item of a registered collection, named by collection key
	// and item id.
	Item Kind = 2
)

const (
	MinLegs = 2
	MaxLegs = 6
	// NoBridge is the bridgedHop value for a ring where every hop is direct.
	NoBridge = -1
	// MaxBridgedHops bounds swaps per ring; one swap already costs more gas
	// than the rest of a six-leg ring.
	MaxBridgedHops = 1

	// MaxLegs ids of up to 20 digits, with separators and some spaces.
	maxIDListLen = 160
)

// String returns the wire name of the kind: "fungible" or "item".
func (k Kind) String() string {
	switch k {
	case Fungible:
		return "fungible"
	case Item:
		return "item"
	}
	return "invalid"
}

// ParseKind is the inverse of Kind.String.
func ParseKind(s string) (Kind, bool) {
	switch s {
	case "fungible":
		return Fungible, true
	case "item":
		return Item, true
	}
	return 0, false
}

// Asset names what a leg gives or wants.
//
// For a fungible asset Key is the grc20reg key, ID is empty and Amount is
// positive: in Give it is the exact amount, in Want the minimum accepted.
// For an item Key is the collection key, ID the item id and Amount is zero.
type Asset struct {
	Kind   Kind
	Key    string
	ID     string
	Amount int64
}

// Validate checks the shape of one asset. It does not look anything up.
func (a Asset) Validate() string {
	switch a.Kind {
	case Fungible:
		if a.Key == "" {
			return "fungible asset without a token key"
		}
		if a.ID != "" {
			return "fungible asset with an item id"
		}
		if a.Amount <= 0 {
			return "fungible amount must be positive"
		}
	case Item:
		if a.Key == "" {
			return "item without a collection key"
		}
		if a.ID == "" {
			return "item without an id"
		}
		if a.Amount != 0 {
			return "item with an amount"
		}
	default:
		return "unknown asset kind"
	}
	return ""
}

// SameAs reports whether a and b name the same token or the same item,
// ignoring the amount.
func (a Asset) SameAs(b Asset) bool {
	return a.Kind == b.Kind && a.Key == b.Key && a.ID == b.ID
}

// String is a short human form, e.g. "100 gno.land/r/x.FOO" or
// "gno.land/r/x#relic-7". It is not escaped for any output format.
func (a Asset) String() string {
	if a.Kind == Item {
		return a.Key + "#" + a.ID
	}
	return strconv.FormatInt(a.Amount, 10) + " " + a.Key
}

// Leg is one offer taking part in a ring.
type Leg struct {
	Offer uint64 // offer id, used only to reject an offer used twice
	Owner address
	Give  Asset
	Want  Asset
}

// Hop is one transfer of a verified ring: Asset leaves legs[From].Owner and
// arrives at legs[To].Owner, who wants Want.
//
// When Bridged is true, Asset and Want are different tokens and the amount
// that reaches legs[To] is only known after the swap that converts one into
// the other. The settler must then check received >= Want.Amount itself;
// Verify has only checked that the hop is shaped like a swap.
type Hop struct {
	From    int
	To      int
	Asset   Asset
	Want    Asset
	Bridged bool
}

// Error explains why a ring was refused. Leg is the index (in ring order) of
// the leg at fault, or -1 when the ring as a whole is wrong. For a hop that
// does not match, Leg is the giving leg.
type Error struct {
	Leg    int
	Offer  uint64
	Reason string
}

func (e *Error) Error() string {
	if e.Leg < 0 {
		return "ring: " + e.Reason
	}
	return "ring: leg " + strconv.Itoa(e.Leg) + " (offer " + strconv.FormatUint(e.Offer, 10) + "): " + e.Reason
}

func ringErr(reason string) *Error { return &Error{Leg: -1, Reason: reason} }

func legErr(legs []Leg, i int, reason string) *Error {
	return &Error{Leg: i, Offer: legs[i].Offer, Reason: reason}
}

// Verify checks a ring in which every hop is direct. See VerifyBridged.
func Verify(legs []Leg) ([]Hop, error) {
	return VerifyBridged(legs, NoBridge)
}

// VerifyWithBridge checks a ring in which a hop that gives one fungible
// token where the receiver wants a different fungible token is bridged by a
// swap. A ring may contain at most MaxBridgedHops such hops; every other hop
// must be direct. See VerifyBridged.
func VerifyWithBridge(legs []Leg) ([]Hop, error) {
	if err := validateLegs(legs); err != nil {
		return nil, err
	}
	n := len(legs)
	bridged := NoBridge
	for i := 0; i < n; i++ {
		if !needsBridge(legs[i].Give, legs[(i+1)%n].Want) {
			continue
		}
		if bridged != NoBridge {
			return nil, legErr(legs, i, "a ring can bridge at most "+strconv.Itoa(MaxBridgedHops)+
				" hop, and the hop from leg "+strconv.Itoa(bridged)+" is already bridged")
		}
		bridged = i
	}
	return VerifyBridged(legs, bridged)
}

// needsBridge reports whether give reaches want only through a swap.
func needsBridge(give, want Asset) bool {
	return give.Kind == Fungible && want.Kind == Fungible && give.Key != want.Key
}

// VerifyBridged checks that legs form a valid closed ring and returns its
// hops in order. bridgedHop is the index of the one hop (legs[i] to
// legs[i+1]) that a swap will bridge, or NoBridge.
//
// It checks that:
//   - there are MinLegs to MaxLegs legs;
//   - no offer, no owner and no given item appears twice;
//   - every asset is well formed and no leg gives what it wants;
//   - for every direct hop, legs[i].Give is the asset legs[i+1].Want names,
//     and for a fungible asset the amount given is at least the minimum
//     wanted;
//   - the bridged hop, if any, gives one fungible token where the receiver
//     wants a different fungible token.
func VerifyBridged(legs []Leg, bridgedHop int) ([]Hop, error) {
	if err := validateLegs(legs); err != nil {
		return nil, err
	}
	n := len(legs)
	if bridgedHop != NoBridge && (bridgedHop < 0 || bridgedHop >= n) {
		return nil, ringErr("bridged hop " + strconv.Itoa(bridgedHop) + " is out of range")
	}

	hops := make([]Hop, n)
	for i := 0; i < n; i++ {
		to := (i + 1) % n
		give, want := legs[i].Give, legs[to].Want
		h := Hop{From: i, To: to, Asset: give, Want: want}
		if i == bridgedHop {
			if give.Kind != Fungible || want.Kind != Fungible {
				return nil, legErr(legs, i, "only a fungible-to-fungible hop can be bridged")
			}
			if give.Key == want.Key {
				return nil, legErr(legs, i, "hop to leg "+strconv.Itoa(to)+" is direct and needs no bridge")
			}
			h.Bridged = true
		} else if r := satisfies(give, want); r != "" {
			return nil, legErr(legs, i, r+" for leg "+strconv.Itoa(to))
		}
		hops[i] = h
	}
	return hops, nil
}

// validateLegs checks everything about a ring that does not depend on its
// hops: its length, each asset, and that no offer, owner or given item
// appears twice.
func validateLegs(legs []Leg) error {
	n := len(legs)
	if n < MinLegs {
		return ringErr("a ring needs at least " + strconv.Itoa(MinLegs) + " legs, got " + strconv.Itoa(n))
	}
	if n > MaxLegs {
		return ringErr("a ring has at most " + strconv.Itoa(MaxLegs) + " legs, got " + strconv.Itoa(n))
	}
	for i := 0; i < n; i++ {
		l := legs[i]
		if !l.Owner.IsValid() {
			return legErr(legs, i, "invalid owner address")
		}
		if r := l.Give.Validate(); r != "" {
			return legErr(legs, i, "give: "+r)
		}
		if r := l.Want.Validate(); r != "" {
			return legErr(legs, i, "want: "+r)
		}
		if l.Give.SameAs(l.Want) {
			return legErr(legs, i, "gives the asset it wants")
		}
		// n <= MaxLegs, so the quadratic scan is at most 15 comparisons.
		for j := 0; j < i; j++ {
			if legs[j].Offer == l.Offer {
				return legErr(legs, i, "offer already used by leg "+strconv.Itoa(j))
			}
			if legs[j].Owner == l.Owner {
				return legErr(legs, i, "owner already trades in leg "+strconv.Itoa(j))
			}
			if l.Give.Kind == Item && legs[j].Give.SameAs(l.Give) {
				return legErr(legs, i, "item already given by leg "+strconv.Itoa(j))
			}
		}
	}
	return nil
}

// satisfies returns "" when give meets want, otherwise the reason it does not.
func satisfies(give, want Asset) string {
	if give.Kind != want.Kind {
		return "gives " + give.Kind.String() + " but " + want.Kind.String() + " is wanted"
	}
	if give.Key != want.Key {
		return "gives " + give.Key + " but " + want.Key + " is wanted"
	}
	if give.Kind == Item {
		if give.ID != want.ID {
			return "gives item " + give.ID + " but item " + want.ID + " is wanted"
		}
		return ""
	}
	if give.Amount < want.Amount {
		return "gives " + strconv.FormatInt(give.Amount, 10) + " but at least " + strconv.FormatInt(want.Amount, 10) + " is wanted"
	}
	return ""
}

// ParseOfferIDs parses a comma-separated list of offer ids, such as "3,7,12".
// Spaces around ids are allowed. It enforces only syntax and the MaxLegs
// bound (so a caller cannot make it allocate much); Verify does the rest.
func ParseOfferIDs(s string) ([]uint64, error) {
	if strings.TrimSpace(s) == "" {
		return nil, ringErr("no offer ids")
	}
	if len(s) > maxIDListLen {
		return nil, ringErr("offer id list too long")
	}
	parts := strings.Split(s, ",")
	if len(parts) > MaxLegs {
		return nil, ringErr("a ring has at most " + strconv.Itoa(MaxLegs) + " legs, got " + strconv.Itoa(len(parts)))
	}
	ids := make([]uint64, len(parts))
	for i, p := range parts {
		p = strings.TrimSpace(p)
		id, err := strconv.ParseUint(p, 10, 64)
		if err != nil || id == 0 {
			return nil, ringErr("bad offer id " + strconv.Quote(p))
		}
		ids[i] = id
	}
	return ids, nil
}

// FormatOfferIDs is the inverse of ParseOfferIDs.
func FormatOfferIDs(ids []uint64) string {
	var sb strings.Builder
	for i, id := range ids {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(strconv.FormatUint(id, 10))
	}
	return sb.String()
}
