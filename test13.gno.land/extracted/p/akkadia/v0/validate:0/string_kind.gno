package validate

import (
	"math"
	"strconv"
	"strings"
)

type StringKind int

const (
	StringPlain StringKind = iota + 1
	StringInt
	StringUint
	StringFloat
)

func (kind StringKind) Valid() (bool, string) {
	if kind != StringPlain &&
		kind != StringInt &&
		kind != StringUint &&
		kind != StringFloat {
		return false, "invalid StringKind"
	}
	return true, ""
}

func (kind StringKind) MustValid() {
	valid, message := kind.Valid()
	if !valid {
		panic(message)
	}
}

func (kind StringKind) Validate(value string) (bool, string) {
	if kind == StringPlain {
		return true, ""
	}
	if kind == StringInt {
		if _, err := strconv.ParseInt(value, 10, 64); err != nil {
			return false, "value must be int"
		}
		return true, ""
	}
	if kind == StringUint {
		if strings.HasPrefix(value, "+") || strings.HasPrefix(value, "-") {
			return false, "value must be uint"
		}
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return false, "value must be uint"
		}
		return true, ""
	}
	if kind == StringFloat {
		f, err := strconv.ParseFloat(value, 64)
		if err != nil {
			return false, "value must be float"
		}
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return false, "value must be float"
		}
		return true, ""
	}

	return false, "invalid StringKind"
}

func (kind StringKind) MustValidate(value string) {
	valid, message := kind.Validate(value)
	if !valid {
		panic(message)
	}
}
