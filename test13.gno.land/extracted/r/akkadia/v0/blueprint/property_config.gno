package blueprint

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/validate"
	"gno.land/r/akkadia/v0/admin"
)

var (
	blueprintCreateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("biome", validate.StringPlain, validate.StringShort, 0, true, true),
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 0, true, true),
			validate.NewStringPolicy("description", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("state", validate.StringPlain, validate.StringShort, 0, true, true),
			validate.NewStringPolicy("size", validate.StringInt, validate.StringShort, 0, true, false),
		},
		[]string{"id", "owner", "createdAt", "updatedAt"},
		32,
		true,
	)

	blueprintUpdateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 0, false, true),
			validate.NewStringPolicy("description", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("state", validate.StringPlain, validate.StringShort, 0, false, true),
		},
		[]string{"id", "owner", "biome", "size", "createdAt", "updatedAt"},
		32,
		true,
	)
)

func SetBlueprintCreatePolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	valid, message := next.Valid()
	if !valid {
		panic(message)
	}
	blueprintCreateValidator = next

	chain.Emit("SetBlueprintCreatePolicies")
}

func SetBlueprintUpdatePolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	valid, message := next.Valid()
	if !valid {
		panic(message)
	}
	blueprintUpdateValidator = next

	chain.Emit("SetBlueprintUpdatePolicies")
}

func GetBlueprintCreatePolicies() validate.Validator {
	return blueprintCreateValidator.Clone()
}

func GetBlueprintUpdatePolicies() validate.Validator {
	return blueprintUpdateValidator.Clone()
}
