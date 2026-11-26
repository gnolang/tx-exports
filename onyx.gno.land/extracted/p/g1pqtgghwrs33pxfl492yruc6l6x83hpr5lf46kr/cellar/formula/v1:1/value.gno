package formula

import "strings"

// Kind tells what a Value holds.
type Kind int

const (
	Empty Kind = iota
	Number
	Text
	Bool
	Error
)

// Error values. They are ordinary values: they can be stored, compared with
// ISERROR and replaced with IFERROR.
const (
	ErrDiv   = "#DIV/0!" // division by zero
	ErrValue = "#VALUE!" // wrong type of operand
	ErrRef   = "#REF!"   // no such sheet or cell
	ErrName  = "#NAME?"  // unknown function
	ErrNum   = "#NUM!"   // result does not fit, or is not defined
	ErrNA    = "#N/A"    // lookup found nothing
	ErrCycle = "#CYCLE!" // the cell depends on itself
	ErrLimit = "#LIMIT!" // too much work or too much text
)

// MaxText is the longest text, in bytes, that a formula may produce.
const MaxText = 512

// Value is the result of evaluating a cell. The zero Value is Empty.
type Value struct {
	kind Kind
	num  Num    // Number; 1 or 0 for Bool
	str  string // Text, or the code of an Error
}

// NewNumber returns a Number.
func NewNumber(n Num) Value { return Value{kind: Number, num: n} }

// NewInt returns a Number, or #NUM! when i does not fit.
func NewInt(i int64) Value {
	n, ok := Int(i)
	if !ok {
		return NewError(ErrNum)
	}
	return NewNumber(n)
}

// NewText returns a Text, or #LIMIT! when s is longer than MaxText.
func NewText(s string) Value {
	if len(s) > MaxText {
		return NewError(ErrLimit)
	}
	return Value{kind: Text, str: s}
}

// NewBool returns a Bool.
func NewBool(b bool) Value {
	if b {
		return Value{kind: Bool, num: 1}
	}
	return Value{kind: Bool}
}

// NewError returns an Error with one of the Err codes.
func NewError(code string) Value { return Value{kind: Error, str: code} }

// Kind returns the kind of v.
func (v Value) Kind() Kind { return v.kind }

// IsError reports whether v is an error value.
func (v Value) IsError() bool { return v.kind == Error }

// Num returns the number held by v, and whether v is a Number.
func (v Value) Num() (Num, bool) { return v.num, v.kind == Number }

// String returns the text shown for v.
func (v Value) String() string {
	switch v.kind {
	case Number:
		return v.num.String()
	case Bool:
		if v.num != 0 {
			return "TRUE"
		}
		return "FALSE"
	case Empty:
		return ""
	}
	return v.str
}

// ParseData reads what a person types into a cell that is not a formula:
// a number, a percentage, TRUE or FALSE, or else text. A leading apostrophe
// forces text.
func ParseData(s string) Value {
	if s == "" {
		return Value{}
	}
	if s[0] == '\'' {
		return NewText(s[1:])
	}
	t := strings.TrimSpace(s)
	if v, ok := parseNumber(t); ok {
		return v
	}
	if len(t) <= len("FALSE") {
		switch strings.ToUpper(t) {
		case "TRUE":
			return NewBool(true)
		case "FALSE":
			return NewBool(false)
		}
	}
	return NewText(s)
}

// parseNumber accepts "12.5" and "12.5%". Text that looks like a number but
// does not fit stays text.
func parseNumber(s string) (Value, bool) {
	if strings.HasSuffix(s, "%") {
		n, ok := ParseNum(s[:len(s)-1])
		if !ok {
			return Value{}, false
		}
		n, _ = Div(n, 100*Unit)
		return NewNumber(n), true
	}
	n, ok := ParseNum(s)
	return NewNumber(n), ok
}

// asNum converts v for arithmetic. On failure the second result is the error
// value to return instead.
func asNum(v Value) (Num, Value) {
	switch v.kind {
	case Number, Bool:
		if v.kind == Bool {
			return v.num * Unit, Value{}
		}
		return v.num, Value{}
	case Empty:
		return 0, Value{}
	case Text:
		if p, ok := parseNumber(strings.TrimSpace(v.str)); ok {
			return p.num, Value{}
		}
		return 0, NewError(ErrValue)
	}
	return 0, v
}

// asBool converts v for logic.
func asBool(v Value) (bool, Value) {
	switch v.kind {
	case Number, Bool:
		return v.num != 0, Value{}
	case Empty:
		return false, Value{}
	case Text:
		switch strings.ToUpper(v.str) {
		case "TRUE":
			return true, Value{}
		case "FALSE":
			return false, Value{}
		}
		return false, NewError(ErrValue)
	}
	return false, v
}

// compare orders two values that are not errors: numbers before text before
// booleans. Text compares without regard to case. An empty cell equals zero,
// the empty text and FALSE.
func compare(a, b Value) int {
	if a.kind == Empty && b.kind == Empty {
		return 0
	}
	if a.kind == Empty {
		a = Value{kind: b.kind}
	}
	if b.kind == Empty {
		b = Value{kind: a.kind}
	}
	if a.kind != b.kind {
		if a.kind < b.kind {
			return -1
		}
		return 1
	}
	if a.kind == Text {
		return strings.Compare(strings.ToUpper(a.str), strings.ToUpper(b.str))
	}
	switch {
	case a.num < b.num:
		return -1
	case a.num > b.num:
		return 1
	}
	return 0
}

// same reports whether a lookup key matches a cell. Unlike compare, an empty
// cell matches nothing.
func same(key, cell Value) bool {
	return key.kind == cell.kind && cell.kind != Empty && cell.kind != Error &&
		compare(key, cell) == 0
}
