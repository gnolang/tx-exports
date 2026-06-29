package validate

import (
	"strings"
	"unicode/utf8"
)

type StringPolicyKey string

func (key StringPolicyKey) Valid() (bool, string) {
	value := string(key)
	if strings.TrimSpace(value) == "" {
		return false, "key is required"
	}
	if utf8.RuneCountInString(value) > HardShortMax {
		return false, "key exceeds max runes"
	}
	if hasASCIIControlChar(value) {
		return false, "key must not contain control characters"
	}
	return true, ""
}

func (key StringPolicyKey) MustValid() {
	valid, message := key.Valid()
	if !valid {
		panic(message)
	}
}

func hasASCIIControlChar(value string) bool {
	for i := 0; i < len(value); i++ {
		c := value[i]
		if c < 0x20 || c == 0x7f {
			return true
		}
	}
	return false
}

// StringPolicy describes one key and the string value accepted for that key.
//
// Required means the key must appear in the input map. AllowEmpty allows the
// exact empty string. Whitespace-only strings are rejected.
type StringPolicy struct {
	key        StringPolicyKey
	kind       StringKind
	lenKind    StringLenKind
	maxRunes   int
	required   bool
	allowEmpty bool
}

// NewStringPolicy returns a validated string policy.
func NewStringPolicy(
	key string,
	kind StringKind,
	lenKind StringLenKind,
	maxRunes int,
	required bool,
	allowEmpty bool,
) StringPolicy {
	policy := StringPolicy{
		key:        StringPolicyKey(key),
		kind:       kind,
		lenKind:    lenKind,
		maxRunes:   maxRunes,
		required:   required,
		allowEmpty: allowEmpty,
	}
	policy.MustValid()
	return policy
}

func (policy StringPolicy) StringKey() string {
	return string(policy.key)
}

func (policy StringPolicy) MaxRunes() int {
	if policy.maxRunes > 0 && policy.maxRunes <= policy.lenKind.Max() {
		return policy.maxRunes
	}
	return policy.lenKind.Max()
}

func (policy StringPolicy) Valid() (bool, string) {
	valid, message := policy.key.Valid()
	if !valid {
		return false, message
	}

	valid, message = policy.kind.Valid()
	if !valid {
		return false, message
	}

	valid, message = policy.lenKind.Valid()
	if !valid {
		return false, message
	}

	if policy.maxRunes < 0 {
		return false, "max runes must not be negative"
	}

	if policy.maxRunes > policy.lenKind.Max() {
		return false, "max runes exceeds hard cap"
	}
	return true, ""
}

func (policy StringPolicy) MustValid() {
	valid, message := policy.Valid()
	if !valid {
		panic(message)
	}
}

func (policy StringPolicy) Validate(value string, found bool) (bool, string) {
	if policy.required && !found {
		return false, "value must be required"
	}
	if !found {
		return true, ""
	}

	valid, message := policy.key.Valid()
	if !valid {
		return false, message
	}

	if !policy.allowEmpty && value == "" {
		return false, "value must not be empty"
	}
	if strings.TrimSpace(value) == "" && value != "" {
		return false, "value must not be blank"
	}

	valid, message = policy.kind.Validate(value)
	if !valid {
		return false, message
	}

	if utf8.RuneCountInString(value) > policy.MaxRunes() {
		return false, "value must be less than or equal max runes"
	}
	return true, ""
}

func (policy StringPolicy) MustValidate(value string, found bool) {
	valid, message := policy.Validate(value, found)
	if !valid {
		panic(message)
	}
}
