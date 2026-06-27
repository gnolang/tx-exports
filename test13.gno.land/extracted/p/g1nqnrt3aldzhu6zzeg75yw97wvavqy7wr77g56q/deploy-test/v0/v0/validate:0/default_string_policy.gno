package validate

type DefaultStringPolicy struct {
	LenKind    StringLenKind
	AllowEmpty bool
}

func (policy DefaultStringPolicy) Validate() (bool, string) {
	valid, message := policy.LenKind.Valid()
	if !valid {
		return false, message
	}
	return true, ""
}

func (policy DefaultStringPolicy) MustValid() {
	valid, message := policy.Validate()
	if !valid {
		panic(message)
	}
}

func (policy DefaultStringPolicy) StringPolicy(key string) StringPolicy {
	return StringPolicy{
		key:        StringPolicyKey(key),
		kind:       StringPlain,
		lenKind:    policy.LenKind,
		required:   false,
		allowEmpty: policy.AllowEmpty,
	}
}
