package monownable

var Value string

func SetValue(v string) {
	Value = v
}

func GetValue() string {
	return Value
}
