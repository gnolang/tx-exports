package profile

import (
	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	fields = avl.NewTree()
	router = mux.NewRouter()
)

// Standard fields
const (
	DisplayName        = "DisplayName"
	Homepage           = "Homepage"
	Bio                = "Bio"
	Age                = "Age"
	Location           = "Location"
	Avatar             = "Avatar"
	GravatarEmail      = "GravatarEmail"
	AvailableForHiring = "AvailableForHiring"
	InvalidField       = "InvalidField"
)

// Events
const (
	ProfileFieldCreated = "ProfileFieldCreated"
	ProfileFieldUpdated = "ProfileFieldUpdated"
)

// Field types used when emitting event
const FieldType = "FieldType"

const (
	BoolField   = "BoolField"
	StringField = "StringField"
	IntField    = "IntField"
)

func init() {
	router.HandleFunc("", homeHandler)
	router.HandleFunc("u/{addr}", profileHandler)
	router.HandleFunc("f/{addr}/{field}", fieldHandler)
}

// List of supported string fields
var stringFields = map[string]bool{
	DisplayName:   true,
	Homepage:      true,
	Bio:           true,
	Location:      true,
	Avatar:        true,
	GravatarEmail: true,
}

// List of support int fields
var intFields = map[string]bool{
	Age: true,
}

// List of support bool fields
var boolFields = map[string]bool{
	AvailableForHiring: true,
}

// Setters
//
// Security properties (AAA-1 B5 — guard the vendored setters):
//
//  1. Address safety (caller-keyed): every key is `PreviousRealm().Address() + ":" + field`,
//     i.e. the immediate caller's own address — the address is NEVER a parameter.
//     So a caller (user OR another realm) can only ever write its OWN profile;
//     cross-address forgery is structurally impossible. This is why the upstream
//     demo is safe to vendor: a DAO calling these writes the DAO's profile, not a
//     member's, and no realm can impersonate another address.
//
//  2. Field allowlist (now ENFORCED): the stringFields/intFields/boolFields maps
//     existed but were never checked, so any caller could write arbitrary field
//     names into the shared tree (state-bloat / unexpected-field injection on its
//     own profile). Each setter now rejects unknown fields. basedao only ever sets
//     DisplayName/Bio/Avatar (all allowlisted), so this does not break the DAO path.

func SetStringField(cur realm, field, value string) bool {
	if !stringFields[field] {
		panic("unknown string profile field: " + field)
	}
	addr := cur.Previous().Address()
	key := addr.String() + ":" + field
	updated := fields.Set(key, value)

	event := ProfileFieldCreated
	if updated {
		event = ProfileFieldUpdated
	}

	chain.Emit(event, FieldType, StringField, field, value)

	return updated
}

func SetIntField(cur realm, field string, value int) bool {
	if !intFields[field] {
		panic("unknown int profile field: " + field)
	}
	addr := cur.Previous().Address()
	key := addr.String() + ":" + field
	updated := fields.Set(key, value)

	event := ProfileFieldCreated
	if updated {
		event = ProfileFieldUpdated
	}

	// ufmt.Sprintf("%d", …): string(int) would coerce the value to a single rune
	// (e.g. 65 → "A"), corrupting the event payload.
	chain.Emit(event, FieldType, IntField, field, ufmt.Sprintf("%d", value))

	return updated
}

func SetBoolField(cur realm, field string, value bool) bool {
	if !boolFields[field] {
		panic("unknown bool profile field: " + field)
	}
	addr := cur.Previous().Address()
	key := addr.String() + ":" + field
	updated := fields.Set(key, value)

	event := ProfileFieldCreated
	if updated {
		event = ProfileFieldUpdated
	}

	chain.Emit(event, FieldType, BoolField, field, ufmt.Sprintf("%t", value))

	return updated
}

// Getters

func GetStringField(addr address, field, def string) string {
	key := addr.String() + ":" + field
	if value, ok := fields.Get(key); ok {
		return value.(string)
	}

	return def
}

func GetBoolField(addr address, field string, def bool) bool {
	key := addr.String() + ":" + field
	if value, ok := fields.Get(key); ok {
		return value.(bool)
	}

	return def
}

func GetIntField(addr address, field string, def int) int {
	key := addr.String() + ":" + field
	if value, ok := fields.Get(key); ok {
		return value.(int)
	}

	return def
}
