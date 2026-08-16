package memba_appstore_v1

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

const (
	DefaultPageSize = 20  // default JSON window
	MaxPageLimit    = 100 // hard cap on any JSON read window (read-DoS guard)
)

func clampLimit(limit int) int {
	if limit <= 0 {
		return DefaultPageSize
	}
	if limit > MaxPageLimit {
		return MaxPageLimit
	}
	return limit
}

// jsonEscape escapes a string for embedding in a JSON string literal — every
// listing text field is attacker-supplied, so this is the only thing between a
// malicious name/tagline and a broken/injected JSON payload on the read path.
func jsonEscape(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		default:
			if r < 0x20 {
				sb.WriteString(ufmt.Sprintf("\\u%04x", r))
			} else {
				sb.WriteString(string(r))
			}
		}
	}
	return sb.String()
}

// listingJSON renders one listing. `full` adds the (large) description — omitted
// from list windows so a bounded page stays small.
func listingJSON(l *Listing, full bool) string {
	descr := ""
	if full {
		descr = ufmt.Sprintf(`,"descr":"%s"`, jsonEscape(l.Descr))
	}
	return ufmt.Sprintf(
		`{"id":%d,"pkgPath":"%s","name":"%s","tagline":"%s","category":"%s","iconCID":"%s","appURL":"%s","publisher":"%s","status":"%s","flagCount":%d,"createdAt":%d%s}`,
		l.Id,
		jsonEscape(l.PkgPath),
		jsonEscape(l.Name),
		jsonEscape(l.Tagline),
		jsonEscape(l.Category),
		jsonEscape(l.IconCID),
		jsonEscape(l.AppURL),
		l.Publisher.String(),
		l.Status,
		l.FlagCount,
		l.CreatedAt,
		descr,
	)
}

// ListLiveJSON returns a bounded JSON array of the visible (live, un-hidden)
// listings: skip `offset`, take up to clamped `limit`. Iteration stops as soon as
// the window is filled, so the scan is bounded by offset+limit regardless of
// catalog size.
func ListLiveJSON(offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	limit = clampLimit(limit)

	var sb strings.Builder
	sb.WriteString("[")
	skipped := 0
	taken := 0
	first := true
	listings.Iterate("", "", func(_ string, v any) bool {
		l := v.(*Listing)
		if !isVisible(l) {
			return false
		}
		if skipped < offset {
			skipped++
			return false
		}
		if taken >= limit {
			return true // window full — stop
		}
		if !first {
			sb.WriteString(",")
		}
		first = false
		sb.WriteString(listingJSON(l, false))
		taken++
		return false
	})
	sb.WriteString("]")
	return sb.String()
}

// GetListingJSON returns a single listing (any status) with its description, or
// the JSON literal `null` if the package path is not registered.
func GetListingJSON(pkgPath string) string {
	v, ok := listings.Get(pkgPath)
	if !ok {
		return "null"
	}
	return listingJSON(v.(*Listing), true)
}
