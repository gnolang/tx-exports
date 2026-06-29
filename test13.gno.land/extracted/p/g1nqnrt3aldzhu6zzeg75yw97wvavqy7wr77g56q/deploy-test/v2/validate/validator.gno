package validate

const (
	HardPairMax    = 128
	DefaultPairMax = 32
)

// Validator is a read-only validation policy set after construction.
//
// Build validators with NewValidator and replace the whole Validator when a
// package needs a different policy. Setter methods are intentionally omitted so
// each published Validator pointer keeps stable behavior for every caller that
// shares it. NewValidator copies caller-owned slices and stores policies by
// value in its own map, so later caller-side changes to the inputs cannot
// change validation behavior.
//
// Validator methods use pointer receivers to avoid copying the internal
// map/slice headers and to keep the private validity sentinel in one place.
// The pointer receiver is not an invitation to mutate the policy. In normal
// use the only state transition after construction is Validate repairing the
// private isValid sentinel if package-local test code or future internal code
// invalidates it before validation.
//
// Accessors expose value snapshots instead of mutable internals: Policies
// returns a fresh slice of StringPolicy values, DenyKeys returns a copied
// string slice, and the scalar fields are returned by value.
type Validator struct {
	defaultPolicy DefaultStringPolicy
	policies      map[string]StringPolicy
	pairMax       int
	allowUnknown  bool
	denyKeys      []string
	isValid       bool
}

func NewValidator(
	defaultPolicy DefaultStringPolicy,
	policies []StringPolicy,
	denyKeys []string,
	pairMax int,
	allowUnknown bool,
) *Validator {
	valid, message := defaultPolicy.Validate()
	if !valid {
		panic(message)
	}
	if pairMax <= 0 {
		panic("pair max must be positive")
	}
	if pairMax > HardPairMax {
		panic("pair max exceeds hard pair max")
	}
	valid, message = validateDenyKeys(denyKeys)
	if !valid {
		panic(message)
	}

	validator := &Validator{
		defaultPolicy: defaultPolicy,
		policies:      map[string]StringPolicy{},
		pairMax:       pairMax,
		allowUnknown:  allowUnknown,
		denyKeys:      copyStringSlice(denyKeys),
	}
	if len(policies) > pairMax {
		panic("policies count exceeds pair max")
	}
	valid, message = validator.validatePolicies(policies)
	if !valid {
		panic(message)
	}
	for _, policy := range policies {
		validator.policies[policy.StringKey()] = policy
	}
	validator.isValid = true
	return validator
}

func (m *Validator) DefaultStringPolicy() DefaultStringPolicy {
	return m.defaultPolicy
}

func (m *Validator) Policies() []StringPolicy {
	policies := []StringPolicy{}
	for _, policy := range m.policies {
		policies = append(policies, policy)
	}
	return policies
}

func (m *Validator) PairMax() int {
	return m.pairMax
}

func (m *Validator) AllowUnknown() bool {
	return m.allowUnknown
}

func (m *Validator) DenyKeys() []string {
	return copyStringSlice(m.denyKeys)
}

func (m *Validator) Clone() Validator {
	return *NewValidator(m.DefaultStringPolicy(), m.Policies(), m.DenyKeys(), m.PairMax(), m.AllowUnknown())
}

func (m *Validator) Valid() (bool, string) {
	valid, message := m.defaultPolicy.Validate()
	if !valid {
		return false, message
	}
	if m.pairMax <= 0 {
		return false, "pair max must be positive"
	}
	if m.pairMax > HardPairMax {
		return false, "pair max exceeds hard pair max"
	}
	valid, message = validateDenyKeys(m.denyKeys)
	if !valid {
		return false, message
	}
	if len(m.policies) > m.pairMax {
		return false, "policies count exceeds pair max"
	}

	return m.validatePolicies(m.Policies())
}

func (m *Validator) getPolicy(key string) StringPolicy {
	if policy, found := m.policies[key]; found {
		return policy
	}
	return m.defaultPolicy.StringPolicy(key)
}

func (m *Validator) MustValid() {
	valid, message := m.Valid()
	if !valid {
		panic(message)
	}
}

func (m *Validator) validatePolicies(policies []StringPolicy) (bool, string) {
	seen := map[string]bool{}
	result := ""
	for _, policy := range policies {
		key := policy.StringKey()
		if seen[key] {
			if result != "" {
				result += "\n"
			}
			result += "duplicated policy key: " + key
		}
		if m.isDenyKey(key) {
			if result != "" {
				result += "\n"
			}
			result += "policy key denied: " + key
		}
		valid, message := policy.Valid()
		if !valid {
			if result != "" {
				result += "\n"
			}
			result += "policy " + key + ": " + message
		}
		seen[key] = true
	}
	if result != "" {
		return false, result
	}
	return true, ""
}

func validateDenyKeys(keys []string) (bool, string) {
	seen := map[string]bool{}
	result := ""
	for _, key := range keys {
		if key == "" {
			if result != "" {
				result += "\n"
			}
			result += "denied key must be not empty"
			continue
		}
		if seen[key] {
			if result != "" {
				result += "\n"
			}
			result += "duplicated denied key: " + key
		}
		seen[key] = true
	}
	if result != "" {
		return false, result
	}
	return true, ""
}

func (m *Validator) Validate(input map[string]string) (bool, string) {
	if !m.isValid {
		m.MustValid()
		m.isValid = true
	}

	if len(input) > m.pairMax {
		return false, "map has too many entries"
	}

	seen := map[string]bool{}
	result := ""

	for key, policy := range m.policies {
		val, found := input[key]
		valid, message := policy.Validate(val, found)
		if !valid {
			if result != "" {
				result += "\n"
			}
			result += "policy " + key + ": " + message
		}
		seen[key] = true
	}

	for key, val := range input {
		if m.isDenyKey(key) {
			if result != "" {
				result += "\n"
			}
			result += "denied key: " + key
			continue
		}
		if !m.allowUnknown && !seen[key] {
			if result != "" {
				result += "\n"
			}
			result += "unknown key: " + key
			continue
		}
		if seen[key] {
			continue
		}

		policy := m.getPolicy(key)
		valid, message := policy.Validate(val, true)
		if !valid {
			if result != "" {
				result += "\n"
			}
			result += "policy " + key + ": " + message
		}
	}

	if result != "" {
		return false, result
	}
	return true, ""
}

func (m *Validator) MustValidate(input map[string]string) {
	valid, message := m.Validate(input)
	if !valid {
		panic(message)
	}
}

func (m *Validator) isDenyKey(key string) bool {
	for _, k := range m.denyKeys {
		if k == key {
			return true
		}
	}
	return false
}

func copyStringSlice(source []string) []string {
	if source == nil {
		return nil
	}
	result := make([]string, len(source))
	copy(result, source)
	return result
}
