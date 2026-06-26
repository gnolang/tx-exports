package blueprint

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

func assertBlueprintName(name string) {
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

func assertBiomeName(biomeName string) {
	if biomeName == "" {
		panic("biome name cannot be empty")
	}
}

func assertBlueprintSize(size string) {
	if size != "1" && size != "3" {
		panic("invalid blueprint size")
	}
}

func assertChunkKey(chunkKey string) {
	if chunkKey == "" {
		panic("chunkKey must not be empty")
	}
	if utf8.RuneCountInString(chunkKey) > 256 {
		panic("chunkKey too long (max 256)")
	}
	for _, ch := range chunkKey {
		if ch < 0x20 {
			panic("chunkKey cannot contain control characters")
		}
	}
}

func assertCreationCost(cost int64) {
	if cost < 0 {
		panic("creationCost must be non-negative")
	}
}

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

func assertExactPayment(expected int64, actual int64) {
	if actual != expected {
		panic("exact payment required: expected " + strconv.FormatInt(expected, 10) + ", got " + strconv.FormatInt(actual, 10))
	}
}
