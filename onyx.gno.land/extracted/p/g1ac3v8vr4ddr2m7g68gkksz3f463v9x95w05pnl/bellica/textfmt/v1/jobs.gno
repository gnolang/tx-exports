package textfmt

func MustAddr(field, s string) address {
	a := address(s)
	if !a.IsValid() {
		panic("invalid " + field + " address")
	}
	return a
}
