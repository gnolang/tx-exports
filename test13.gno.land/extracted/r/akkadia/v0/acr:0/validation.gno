package acr

import "strings"

const (
	maxHofCategoryNameLength = 128
	maxHofEntriesBytes       = 256 * 1024
	maxHofEntriesRows        = 100
	maxHofColumns            = 32
)

// Validation helpers in this file are for value-level checks at public API boundaries.
//
// Keep store-owned existence, duplicate, and index consistency checks close to
// the store methods that own those state transitions.
func assertListPageCount(page int, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > listLimit {
		panic("count exceeds listLimit")
	}
}

func validateHofCategoryName(name string) {
	if name == "" {
		panic("invalid name: ")
	}
	if len(name) > maxHofCategoryNameLength {
		panic("category name exceeds maxHofCategoryNameLength")
	}
}

func validateHofEntries(csvRows string) string {
	csvRows = strings.TrimRight(csvRows, "\n")
	if csvRows == "" {
		return ""
	}
	if len(csvRows) > maxHofEntriesBytes {
		panic("hof entries exceeds maxHofEntriesBytes")
	}

	rows := strings.Split(csvRows, "\n")
	if len(rows) > maxHofEntriesRows {
		panic("hof entries rows exceeds maxHofEntriesRows")
	}

	headers := strings.Split(rows[0], ",")
	validateHofColumns(headers, true)

	for i := 1; i < len(rows); i++ {
		if rows[i] == "" {
			panic("invalid hof csv: empty row")
		}
		cols := strings.Split(rows[i], ",")
		validateHofColumns(cols, false)
		if len(cols) != len(headers) {
			panic("invalid hof csv: inconsistent column count")
		}
	}

	return csvRows
}

func validateHofColumns(cols []string, header bool) {
	if len(cols) > maxHofColumns {
		panic("hof entries columns exceeds maxHofColumns")
	}
	if !header {
		return
	}
	for _, col := range cols {
		if strings.TrimSpace(col) == "" {
			panic("invalid hof csv: empty header")
		}
	}
}
