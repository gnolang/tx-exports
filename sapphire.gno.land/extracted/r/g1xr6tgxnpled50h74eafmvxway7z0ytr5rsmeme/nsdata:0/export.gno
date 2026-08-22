package nsdata

import (
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Snapshot support: the other half of the contingency plan.
//
// Governance protects against a stolen or lost key. This file protects
// against the case no key can fix — a VM-level corruption, a chain
// migration, a defect in this realm discovered too late — where the only
// way out is to reconstruct the registry somewhere else. That is
// possible only if the whole state can be read out reliably and
// repeatably, which needs pagination: an unpaginated listing of a
// registry with tens of thousands of names is one query that is too
// large to ever return, and a snapshot you cannot take is not a backup.
//
// Recovery shape, should it ever be needed:
//   1. Pause() — freeze the registry so it cannot drift from the snapshot.
//   2. Page through the exports here to reconstruct state off-chain.
//   3. Deploy a successor, import the snapshot.
//   4. SetSuccessor() on this realm so readers can follow the move.
//
// The exports are also just useful: an operator who takes a snapshot
// every week has an off-chain record independent of any single chain.

const maxPage = 200

// pageKeys walks a key span and returns up to `limit` keys after the
// `after` cursor, plus the cursor to pass next (empty when exhausted).
func pageKeys(t *avl.Tree, start, end, after string, limit int) (csv, next string) {
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	from := start
	if after != "" && after > from {
		from = after
	}
	var b strings.Builder
	n := 0
	hasMore := false
	last := ""
	t.Iterate(from, end, func(key string, v any) bool {
		if after != "" && key <= after {
			return false
		}
		if n >= limit {
			hasMore = true
			return true
		}
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(key)
		last = key
		n++
		return false
	})
	if !hasMore {
		last = ""
	}
	return b.String(), last
}

// ExportDomains pages through every domain label.
func ExportDomains(after string, limit int) (labels, next string) {
	return pageKeys(&domains, "", "", after, limit)
}

// ExportNames pages through every name in the registry, as raw storage
// keys (`domain*label`). Pass an empty domainLabel to walk the whole
// tree, or a domain to walk just that domain's span.
func ExportNames(domainLabel, after string, limit int) (keys, next string) {
	if domainLabel == "" {
		return pageKeys(&names, "", "", after, limit)
	}
	start, end := domainRange(domainLabel)
	return pageKeys(&names, start, end, after, limit)
}

// ExportPrimary pages through the reverse-resolution table as owner
// addresses; pair with GetPrimary to read each value.
func ExportPrimary(after string, limit int) (owners, next string) {
	return pageKeys(&primary, "", "", after, limit)
}

// ExportGlobalKeys lists the package-level extension slot's keys; pair
// with GetGlobal for values.
func ExportGlobalKeys(after string, limit int) (keys, next string) {
	return pageKeys(&globals, "", "", after, limit)
}

// ExportDomainExtraKeys / ExportNameExtraKeys list a record's extension
// keys so a snapshot can capture data this realm has no schema for.
// Keys are comma-free by construction (see assertExtraKey), so a CSV
// listing is unambiguous.
func ExportDomainExtraKeys(label, after string, limit int) (keys, next string) {
	d := mustGetDomain(label)
	return pageKeys(&d.extra, "", "", after, limit)
}

func ExportNameExtraKeys(label, domainLabel, after string, limit int) (keys, next string) {
	n := mustGetName(label, domainLabel)
	return pageKeys(&n.extra, "", "", after, limit)
}

// KNOWN SNAPSHOT GAP, recorded rather than left to be discovered during
// an actual recovery: GRC-721 OPERATOR APPROVALS (RawSetApprovalForAll)
// live inside the grc721 package's own state and are not enumerable
// through any read this realm exposes. Every other piece of state is
// reachable — record fields via GetDomainInfo/GetNameInfo, extension keys
// via the Export*ExtraKeys pagers, reverse resolution via ExportPrimary,
// globals via ExportGlobalKeys — but operator approvals are not, so a
// reconstructed registry will silently lack them and holders would need
// to re-grant. Treated as acceptable (an approval is a revocable
// convenience, not ownership) but it must not be assumed complete.

// Sizes let an operator verify a snapshot is complete rather than
// trusting that pagination terminated correctly.
func Sizes() (domainCount, nameCount, primaryCount, globalCount int) {
	return domains.Size(), names.Size(), primary.Size(), globals.Size()
}
