package chunk

import "strconv"

// Validation helpers in this file are for value-level checks at public API boundaries.
//
// Add helpers here when they validate a parameter or payload value without
// depending on mutable contract state or call flow. Good examples are world
// field format, numeric range, CSV payload shape, and page/count limits.
//
// Do not add helpers here when the assertion depends on store contents,
// ownership, permissions, freeze/migration state, uniqueness, or the order of a
// specific operation. Keep those assertions close to the domain flow that owns
// the state transition.
//
// As a rule of thumb: validation.gno owns "is this value shaped correctly?";
// domain files and stores own "is this action allowed right now?" and
// store-owned index invariants.

// World field assertions.
// Used by CreateWorld and UpdateWorld before constructing or mutating records.
func assertWorldID(id uint32) {
	if id == 0 {
		panic("world id must be positive")
	}
}

func assertBiomeName(biomeName string) {
	if len(biomeName) == 0 {
		panic("biome name cannot be empty")
	}
}

func assertWorldName(name string) {
	if len(name) == 0 {
		panic("name cannot be empty")
	}
	if len(name) > 100 {
		panic("name too long (max 100)")
	}
}

func assertWorldSlug(slug string) {
	if len(slug) == 0 {
		panic("slug cannot be empty")
	}

	if len(slug) > 50 {
		panic("slug too long (max 50)")
	}

	// Allowed characters: a-z, 0-9, hyphen, underscore
	for _, ch := range slug {
		if !((ch >= 'a' && ch <= 'z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '-' || ch == '_') {
			panic("slug contains invalid characters (allowed: a-z, 0-9, -, _)")
		}
	}

	// Cannot start or end with hyphen
	if slug[0] == '-' || slug[len(slug)-1] == '-' {
		panic("slug cannot start or end with hyphen")
	}
}

func mustParseWorldSeed(value string) int {
	seed, err := strconv.Atoi(value)
	if err != nil {
		panic("invalid seed: " + value)
	}
	assertWorldSeed(seed)
	return seed
}

func assertWorldSeed(seed int) {
	if seed <= 0 {
		panic("seed must be positive")
	}
}

// Query limit assertions.
// Used by public list and batch query entry points.
func assertListLimit(field string, count int) {
	if count > listLimit {
		panic(field + " exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func assertListQueryCount(field string, count int) {
	if count < 1 {
		panic(field + " must be at least 1")
	}
	assertListLimit(field, count)
}

func assertListPageCount(page int, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	assertListQueryCount("count", count)
}

func assertBatchLimit(field string, count int) {
	if count > batchLimit {
		panic(field + " exceeds batchLimit (max: " + strconv.Itoa(batchLimit) + ")")
	}
}

func assertPositiveLimit(limit int) {
	if limit < 1 {
		panic("limit must be at least 1")
	}
}
