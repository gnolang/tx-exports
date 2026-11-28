package idox

import (
	"strconv"
	"strings"
)

// CreateVaultCSV is a CLI and gnoweb $help wrapper around CreateVault.
// Pass pipe-delimited ("|") strings for milestone titles, required badges, and ugnot amounts.
// Example:
//   titlesCSV:      "Tranche 1: Framing & Dry-In|Tranche 2: Rough Electrical"
//   badgesCSV:      "gc_license|electrical_master"
//   allocationsCSV: "30000000|40000000"
func CreateVaultCSV(
	cur realm,
	title string,
	contractor address,
	titlesCSV string,
	badgesCSV string,
	allocationsCSV string,
) uint64 {
	if strings.TrimSpace(titlesCSV) == "" {
		panic("at least one milestone title is required")
	}

	rawTitles := strings.Split(titlesCSV, "|")
	rawBadges := strings.Split(badgesCSV, "|")
	rawAllocs := strings.Split(allocationsCSV, "|")

	n := len(rawTitles)
	if len(rawBadges) != n || len(rawAllocs) != n {
		panic("mismatched pipe-delimited counts across titles, badges, and allocations")
	}

	titles := make([]string, n)
	badges := make([]string, n)
	allocations := make([]int64, n)

	for i := 0; i < n; i++ {
		t := strings.TrimSpace(rawTitles[i])
		if t == "" {
			panic("milestone title cannot be empty")
		}
		titles[i] = t
		badges[i] = strings.TrimSpace(rawBadges[i])

		amtStr := strings.TrimSpace(rawAllocs[i])
		amt, err := strconv.ParseInt(amtStr, 10, 64)
		if err != nil || amt <= 0 {
			panic("invalid milestone allocation: " + amtStr)
		}
		allocations[i] = amt
	}

	// Forward cur directly (no cross) so cur.Previous().IsUserCall() stays true
	// for CreateVault's BankerTypeOriginSend guard.
	return CreateVault(cur, title, contractor, titles, badges, allocations)
}
