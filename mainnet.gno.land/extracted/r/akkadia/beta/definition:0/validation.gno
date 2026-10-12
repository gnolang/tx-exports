package definition

import (
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

func assertIdentifier(value, name string, limit int) {
	if strings.TrimSpace(value) == "" {
		panic(name + " is required")
	}
	if len(value) > limit {
		panic(name + " bytes exceeds " + strconv.Itoa(limit))
	}
	if !utf8.ValidString(value) {
		panic("invalid " + name)
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			panic("invalid " + name)
		}
	}
}

func assertFields(fields []Field) int {
	if len(fields) < 1 || len(fields) > 32 {
		panic("field count must be between 1 and 32")
	}
	size := 0
	for i, field := range fields {
		assertIdentifier(field.Key, "field key", 128)
		if !utf8.ValidString(field.Value) {
			panic("invalid field value")
		}
		for j := 0; j < i; j++ {
			if fields[j].Key == field.Key {
				panic("duplicate field key")
			}
		}
		size += len(field.Key) + len(field.Value)
		if size > 16384 {
			panic("entry bytes exceeds 16384")
		}
	}
	return size
}

func assertBatchCount(count int) {
	if count < 1 || count > 100 {
		panic("batch count must be between 1 and 100")
	}
}

func assertPage(page, count int) {
	if page < 1 {
		panic("page must be positive")
	}
	if count < 1 || count > 50 {
		panic("count must be between 1 and 50")
	}
}
