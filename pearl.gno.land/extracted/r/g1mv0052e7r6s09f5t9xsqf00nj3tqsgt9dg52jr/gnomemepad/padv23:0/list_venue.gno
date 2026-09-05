package padv23

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// ListVenue IDs (compile-time switch in tryListVenue). Adding a new DEX
// means a new case + adapter file and a new pad version - Gno cannot
// dynamically import by path string.
const (
	VenueGnoswap = "gnoswap"
)

// listVenueMeta is registry metadata (not a callable adapter).
type listVenueMeta struct {
	ID           string
	Label        string
	Enabled      bool
	FeeAssetHint string // e.g. "GNS" for CreatePool fee UX
}

var (
	listVenues       avl.Tree // id -> *listVenueMeta
	defaultListVenue string
)

func ensureListVenuesSeeded() {
	if listVenues.Size() > 0 {
		return
	}
	registerListVenue(VenueGnoswap, "Gnoswap", true, "GNS")
	if defaultListVenue == "" {
		defaultListVenue = VenueGnoswap
	}
}

func registerListVenue(id, label string, enabled bool, feeHint string) {
	id = strings.TrimSpace(strings.ToLower(id))
	if id == "" {
		return
	}
	label = strings.TrimSpace(label)
	if label == "" {
		label = id
	}
	listVenues.Set(id, &listVenueMeta{
		ID:           id,
		Label:        label,
		Enabled:      enabled,
		FeeAssetHint: strings.TrimSpace(feeHint),
	})
}

func normalizeVenueID(venueId string) string {
	ensureListVenuesSeeded()
	v := strings.TrimSpace(strings.ToLower(venueId))
	if v == "" {
		if defaultListVenue != "" {
			return defaultListVenue
		}
		return VenueGnoswap
	}
	return v
}

func venueEnabled(venueId string) bool {
	ensureListVenuesSeeded()
	id := normalizeVenueID(venueId)
	raw := listVenues.Get(id)
	if raw == nil {
		return false
	}
	m, ok := raw.(*listVenueMeta)
	return ok && m != nil && m.Enabled
}

// DefaultListVenue returns the venue id used when callers pass "".
func DefaultListVenue() string {
	ensureListVenuesSeeded()
	if defaultListVenue == "" {
		return VenueGnoswap
	}
	return defaultListVenue
}

// SetDefaultListVenue sets the default list venue (protocol only).
func SetDefaultListVenue(cur realm, venueId string) {
	requireProtocol(cur)
	ensureListVenuesSeeded()
	id := strings.TrimSpace(strings.ToLower(venueId))
	if id == "" {
		panic("pad: empty venue")
	}
	if listVenues.Get(id) == nil {
		panic("pad: unknown venue")
	}
	defaultListVenue = id
	chain.Emit("SetDefaultListVenue", "venue", id)
}

// SetListVenue registers or updates venue metadata (protocol only).
// Does not add compile-time dispatch - unknown ids stay non-listable until
// tryListVenue gains a case in a future pad version.
func SetListVenue(cur realm, id, label string, enabled bool, feeAssetHint string) {
	requireProtocol(cur)
	ensureListVenuesSeeded()
	id = strings.TrimSpace(strings.ToLower(id))
	if id == "" || len(id) > 32 {
		panic("pad: invalid venue id")
	}
	for _, c := range id {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			panic("pad: venue id charset")
		}
	}
	registerListVenue(id, label, enabled, feeAssetHint)
	chain.Emit("SetListVenue",
		"id", id,
		"label", strings.TrimSpace(label),
		"enabled", strconv.FormatBool(enabled),
		"feeHint", strings.TrimSpace(feeAssetHint),
	)
}

// ListVenues returns newline-separated "id|label|enabled|feeHint" (enabled 0|1).
func ListVenues() string {
	ensureListVenuesSeeded()
	out := ""
	listVenues.Iterate("", "", func(key string, value any) bool {
		m, ok := value.(*listVenueMeta)
		if !ok || m == nil {
			return false
		}
		en := "0"
		if m.Enabled {
			en = "1"
		}
		line := m.ID + "|" + m.Label + "|" + en + "|" + m.FeeAssetHint
		if out != "" {
			out += "\n"
		}
		out += line
		return false
	})
	return out
}

// ListVenueOf returns the venue id used for a successful list (or "").
func ListVenueOf(id string) string {
	return mustLaunch(id).ListVenue
}

// resetListVenuesForTest clears venue registry (unit tests).
func resetListVenuesForTest() {
	listVenues = avl.Tree{}
	defaultListVenue = ""
}

// tryListVenue dispatches to a compile-time adapter. Unknown / disabled
// venues soft-fail with a note (no panic) so UI can show ListNeed guidance.
func tryListVenue(cur realm, l *Launch, venueId string, raisedUgnot, liqTokens int64) bool {
	ensureListVenuesSeeded()
	id := normalizeVenueID(venueId)
	if !venueEnabled(id) {
		if l != nil {
			l.GnoswapNote = "list skip: venue disabled or unknown: " + id
		}
		return false
	}
	switch id {
	case VenueGnoswap:
		ok := listOnGnoswapWithFunding(cur, l, raisedUgnot, liqTokens)
		if ok && l != nil {
			l.ListVenue = VenueGnoswap
		}
		return ok
	default:
		// Registered in metadata but no adapter case yet.
		if l != nil {
			l.GnoswapNote = "list skip: venue adapter not linked in this pad: " + id
		}
		return false
	}
}
