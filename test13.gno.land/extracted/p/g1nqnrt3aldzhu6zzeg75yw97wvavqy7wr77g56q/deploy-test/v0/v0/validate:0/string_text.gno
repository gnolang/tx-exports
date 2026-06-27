package validate

import (
	"strings"
	"unicode/utf8"
)

// AssertStringTextLen validates a plain text value against the text hard cap.
func AssertStringTextLen(value string, allowEmpty bool, panicMessagePrefix string) {
	if !allowEmpty && strings.TrimSpace(value) == "" {
		panic(panicMessagePrefix + " is required")
	}

	valid, message := StringPlain.Validate(value)
	if !valid {
		panic(message)
	}

	if utf8.RuneCountInString(value) > StringText.Max() {
		panic(panicMessagePrefix + " exceeds max runes")
	}
}
