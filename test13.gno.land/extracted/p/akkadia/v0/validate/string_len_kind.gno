package validate

const (
	HardShortMax    = 32
	HardStandardMax = 256
	HardTextMax     = 1024
)

type StringLenKind int

const (
	StringShort StringLenKind = iota + 1
	StringStandard
	StringText
)

func (kind StringLenKind) Valid() (bool, string) {
	if kind != StringShort &&
		kind != StringStandard &&
		kind != StringText {
		return false, "invalid StringLenKind"
	}
	return true, ""
}

func (kind StringLenKind) MustValid() {
	valid, message := kind.Valid()
	if !valid {
		panic(message)
	}
}

func (kind StringLenKind) Max() int {
	if kind == StringShort {
		return HardShortMax
	}
	if kind == StringStandard {
		return HardStandardMax
	}
	if kind == StringText {
		return HardTextMax
	}
	return 0
}
