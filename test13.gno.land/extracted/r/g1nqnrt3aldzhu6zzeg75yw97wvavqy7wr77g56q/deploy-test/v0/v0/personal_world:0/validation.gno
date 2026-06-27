package personal_world

import (
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
)

// Validation helpers in this file are for value-level checks at public API boundaries.
//
// Add helpers here when they validate a parameter or payload value without
// depending on mutable contract state or call flow. Good examples are field
// format, length, numeric range, string-map shape, and page/count limits.
//
// Do not add helpers here when the assertion depends on store contents,
// ownership, permissions, payment, freeze/migration state, uniqueness, or the
// order of a specific operation. Keep those assertions close to the domain flow
// that owns the state transition.
//
// As a rule of thumb: validation.gno owns "is this value shaped correctly?";
// domain files own "is this action allowed right now?".

// World field assertions.
// Used by CreateWorld and UpdateWorld before constructing or mutating world records.
func assertWorldName(name string) {
	if len(name) == 0 {
		panic("name cannot be empty")
	}
	if utf8.RuneCountInString(name) > 100 {
		panic("name too long (max 100)")
	}

	trimmed := strings.TrimSpace(name)
	if len(trimmed) == 0 {
		panic("name cannot be only whitespace")
	}
	if name != trimmed {
		panic("name cannot have leading or trailing whitespace")
	}

	for _, ch := range name {
		if ch < 0x20 {
			panic("name cannot contain control characters")
		}
	}
}

func assertWorldSlug(slug string) {
	if len(slug) == 0 {
		panic("slug cannot be empty")
	}
	if len(slug) > 50 {
		panic("slug too long (max 50)")
	}

	for _, ch := range slug {
		if !((ch >= 'a' && ch <= 'z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '-' || ch == '_') {
			panic("slug contains invalid characters (allowed: a-z, 0-9, -, _)")
		}
	}

	if slug[0] == '-' || slug[len(slug)-1] == '-' {
		panic("slug cannot start or end with hyphen")
	}
}

func mustParseWorldSeed(value string) int {
	seed, err := strconv.Atoi(value)
	if err != nil {
		panic("seed must be int")
	}
	if seed <= 0 {
		panic("seed must be positive")
	}
	return seed
}

// World metadata assertions.
// Metadata is admin-managed opaque text. The realm only bounds resource usage;
// clients and off-chain services own decoding and semantic validation.
func assertWorldMetadata(metadata string) {
	validate.AssertStringTextLen(metadata, true, "world metadata")
}

// Biome input assertions.
// Used by SetBiomeInfo, SetDefaultBiome, GetBiomeInfo, and CreateWorld.
func assertBiomeName(biomeName string) {
	if biomeName == "" {
		panic("biome name cannot be empty")
	}
}

func mustParseBiomeCost(value string) int64 {
	cost, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		panic("cost must be int")
	}
	if cost < 0 {
		panic("cost must be non-negative")
	}
	return cost
}

func mustParseBiomePriceMultiplierBPS(value string) int64 {
	priceMultiplierBPS, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		panic("price multiplier BPS must be int")
	}
	if priceMultiplierBPS <= 0 {
		panic("price multiplier BPS must be positive")
	}
	if priceMultiplierBPS < minPriceMultiplierBPS {
		panic("price multiplier BPS below minimum")
	}
	return priceMultiplierBPS
}

// Size input assertions.
// Used by SetSizeInfo before constructing size info records.
func mustParseSizeID(value string) int {
	sizeID, err := strconv.Atoi(value)
	if err != nil {
		panic("sizeID must be int")
	}
	if sizeID < 0 {
		panic("sizeID must be non-negative")
	}
	return sizeID
}

func mustParseWorldSize(value string) int {
	size, err := strconv.Atoi(value)
	if err != nil {
		panic("size must be int")
	}
	if size < 0 {
		panic("size must be non-negative")
	}
	return size
}

func mustParseSizeCost(value string) int64 {
	cost, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		panic("cost must be int")
	}
	if cost < 0 {
		panic("cost must be non-negative")
	}
	return cost
}

// String-map assertions.
// Used by metadata/property config setters and payload parsers.
func assertCSVMapParams(keys, values string, panicMessagePrefix string) {
	if keys == "" {
		panic(panicMessagePrefix + " keys must be not empty")
	}
}

func assertStringMapAllowedKeys(m map[string]string, allowedKeys []string, panicMessagePrefix string) {
	if len(allowedKeys) == 0 {
		panic(panicMessagePrefix + " allowed keys not configured")
	}
	for key := range m {
		assertAllowedKey(key, allowedKeys)
	}
}

func assertAllowedKey(key string, allowedKeys []string) {
	for _, allowedKey := range allowedKeys {
		if key == allowedKey {
			return
		}
	}
	panic("invalid key: " + key)
}

// Query limit assertions.
// Used by public list and batch query entry points.
func assertListLimit(field string, count int) {
	if count > listLimit {
		panic(field + " exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func assertListPageCount(page int, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	assertListLimit("count", count)
}

func assertBatchLimit(field string, count int) {
	if count > batchLimit {
		panic(field + " exceeds batchLimit (max: " + strconv.Itoa(batchLimit) + ")")
	}
}
