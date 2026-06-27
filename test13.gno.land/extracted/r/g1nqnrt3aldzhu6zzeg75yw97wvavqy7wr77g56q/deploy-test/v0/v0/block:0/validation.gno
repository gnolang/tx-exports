package block

import (
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
)

const maxBlockNameLength = 30

// Validation helpers in this file are for value-level checks at public API boundaries.
//
// Add helpers here when they validate a parameter or payload value without
// depending on mutable contract state or call flow. Store-owned existence,
// duplicate, and index consistency checks stay in the relevant store.
func assertBlockName(name string) {
	if name == "" {
		panic("name cannot be empty")
	}
	if utf8.RuneCountInString(name) > maxBlockNameLength {
		panic("name too long (max 30)")
	}
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		panic("name cannot be only whitespace")
	}
	if name != trimmed {
		panic("name cannot have leading or trailing whitespace")
	}
	for i := 0; i < len(name); i++ {
		switch name[i] {
		case ',', '|', '/', '\\', '<', '>', '[', ']', '(', ')', '{', '}', '#', '*', '`':
			panic("name contains invalid characters")
		}
		if name[i] < 0x20 || name[i] == 0x7f {
			panic("name contains invalid characters")
		}
	}
}

func assertNormalMaxSupply(maxSupply uint32) {
	if maxSupply == 0 {
		panic("max supply must be greater than 0")
	}
}

func assertSystemMaxSupply(maxSupply int64) {
	if maxSupply < -1 {
		panic("max supply must be greater than -2")
	}
}

func assertInstallerBPS(installerBPS uint32) {
	if installerBPS > 10000 {
		panic("installer bps must be between 0 and 10000")
	}
}

func assertMetadata(metadata string) {
	validate.AssertStringTextLen(metadata, true, "block metadata")
}

func assertExactPayment(expected int64, actual int64) {
	if actual != expected {
		panic("exact payment required: expected " + strconv.FormatInt(expected, 10) + ", got " + strconv.FormatInt(actual, 10))
	}
}

func mustParseUint32Field(props map[string]string, key string) uint32 {
	return mustParseUint32(props[key])
}

func mustParseInt64Field(props map[string]string, key string) int64 {
	return mustParseInt64(props[key])
}

func mustParseUint32(val string) uint32 {
	value, err := strconv.ParseUint(val, 10, 32)
	if err != nil {
		panic("invalid uint32: " + err.Error())
	}
	return uint32(value)
}

func mustParseUint8(val string) uint8 {
	value, err := strconv.ParseUint(val, 10, 8)
	if err != nil {
		panic("invalid uint8: " + err.Error())
	}
	return uint8(value)
}

func mustParseInt64(val string) int64 {
	value, err := strconv.ParseInt(val, 10, 64)
	if err != nil {
		panic("invalid int64: " + err.Error())
	}
	return value
}

func mustParseAddress(str string) address {
	addr := address(str)
	if !addr.IsValid() {
		panic("invalid address: " + str)
	}
	return addr
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

func assertListLimit(field string, count int) {
	if count > listLimit {
		panic(field + " exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func parseMintAllowlistCSV(minters string) []address {
	if minters == "" {
		panic("minters must not be empty")
	}

	result := []address{}
	start := 0
	for i := 0; i <= len(minters); i++ {
		if i == len(minters) || minters[i] == ',' {
			addr := strings.TrimSpace(minters[start:i])
			if addr == "" {
				panic("empty address not allowed")
			}
			result = append(result, mustParseAddress(addr))
			start = i + 1
		}
	}
	return result
}
