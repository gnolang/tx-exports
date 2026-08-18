package lineage

// Status of a vault version. Old versions stay frozen and keep their funds.
const (
	StatusLive   = "live"
	StatusLegacy = "legacy"
	StatusSunset = "sunset"
)

// Version is a catalog row. Stored as a value, never as a realm handle.
// Gno cannot overwrite a deployed vault, so each upgrade is a new path
// plus a pointer to the previous one.
type Version struct {
	ID        string
	Name      string
	PkgPath   string
	Predecessor string
	Successor string
	Status    string
}

// ValidStatus reports whether s is a known status.
func ValidStatus(s string) bool {
	return s == StatusLive || s == StatusLegacy || s == StatusSunset
}

// Validate checks required fields. Does not talk to the chain.
func Validate(v Version) {
	if v.ID == "" || v.Name == "" || v.PkgPath == "" {
		panic("incomplete version")
	}
	if !ValidStatus(v.Status) {
		panic("invalid status")
	}
}

// IsFrozen is true when the vault must not be mutated by an upgrade.
func IsFrozen(v Version) bool {
	return v.Status == StatusLegacy || v.Status == StatusSunset
}
