package memba_appstore_v3

import (
	"strings"

	"gno.land/p/nt/avl/v0"
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

// jsonEscape escapes a string for embedding in a JSON string literal — every listing text field
// is attacker-supplied, so this is the only thing between a malicious name/tagline/reason/CID and
// a broken/injected JSON payload on the read path.
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

// screenshotsJSON renders a CID slice as a JSON string array body (each element escaped).
func screenshotsJSON(cids []string) string {
	var sb strings.Builder
	for i, c := range cids {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"`)
		sb.WriteString(jsonEscape(c))
		sb.WriteString(`"`)
	}
	return sb.String()
}

// listingJSON renders one listing. `full` adds the (large) description + the screenshot gallery —
// omitted from list windows so a bounded page stays small. rejectReason is short and always
// included (the My-Submissions view needs it in list windows).
func listingJSON(l *Listing, full bool) string {
	extra := ""
	if full {
		extra = ufmt.Sprintf(`,"descr":"%s","screenshotCIDs":[%s]`,
			jsonEscape(l.Descr), screenshotsJSON(l.ScreenshotCIDs))
	}
	return ufmt.Sprintf(
		`{"id":%d,"pkgPath":"%s","name":"%s","tagline":"%s","category":"%s","iconCID":"%s","appURL":"%s","publisher":"%s","status":"%s","rejectReason":"%s","paidResubmitCredit":%t,"resubmitCount":%d,"flagCount":%d,"createdAt":%d%s}`,
		l.Id,
		jsonEscape(l.PkgPath),
		jsonEscape(l.Name),
		jsonEscape(l.Tagline),
		jsonEscape(l.Category),
		jsonEscape(l.IconCID),
		jsonEscape(l.AppURL),
		l.Publisher.String(),
		l.Status,
		jsonEscape(l.RejectReason),
		l.PaidResubmitCredit,
		l.ResubmitCount,
		l.FlagCount,
		l.CreatedAt,
		extra,
	)
}

// windowByPrefix iterates a composite-key index (statusIndex or publisherIndex) over the prefix
// range [prefix+"\x00", prefix+"\x01") — a true O(offset+limit) window ordered by zero-padded id.
// When flagFilter is set, flag-hidden listings are excluded (the public live/pending lists).
func windowByPrefix(index *avl.Tree, prefix string, offset, limit int, flagFilter bool) string {
	limit = clampLimit(limit)
	if offset < 0 {
		offset = 0
	}
	var sb strings.Builder
	sb.WriteString("[")
	skipped, taken := 0, 0
	first := true
	index.Iterate(prefix+"\x00", prefix+"\x01", func(_ string, v any) bool {
		lv, ok := listings.Get(v.(string))
		if !ok {
			return false
		}
		l := lv.(*Listing)
		if flagFilter && l.FlagCount >= FlagHideThreshold {
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

// ListLiveJSON returns a bounded JSON array of the visible (live, un-flag-hidden) listings —
// the Verified tab. Bounded by scanning only the "live" index slice.
func ListLiveJSON(offset, limit int) string {
	return windowByPrefix(statusIndex, StatusLive, offset, limit, true)
}

// ListByStatusJSON returns a bounded window of listings in `status`. Public tabs (live, pending)
// exclude flag-hidden listings; rejected/delisted are returned raw (used by curator/owner views).
// An unknown status returns an empty array — the client passes a fixed enum, never free text.
func ListByStatusJSON(status string, offset, limit int) string {
	if !validStatus(status) {
		return "[]"
	}
	flagFilter := status == StatusLive || status == StatusPending
	return windowByPrefix(statusIndex, status, offset, limit, flagFilter)
}

// ListByPublisherJSON returns a bounded window of a publisher's listings across ALL statuses
// (the My-Submissions view) — no flag filter, since a publisher sees their own flagged/rejected.
func ListByPublisherJSON(publisher string, offset, limit int) string {
	return windowByPrefix(publisherIndex, publisher, offset, limit, false)
}

// GetListingJSON returns a single listing (any status) with its full detail (descr + screenshots),
// or the JSON literal `null` if the package path is not registered.
func GetListingJSON(pkgPath string) string {
	v, ok := listings.Get(pkgPath)
	if !ok {
		return "null"
	}
	return listingJSON(v.(*Listing), true)
}
