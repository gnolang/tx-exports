package personal_world

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

const (
	SetWorldCreatePoliciesEvent = "SetWorldCreatePolicies"
	SetWorldUpdatePoliciesEvent = "SetWorldUpdatePolicies"
	SetSizeInfoPoliciesEvent    = "SetSizeInfoPolicies"
	SetBiomeInfoPoliciesEvent   = "SetBiomeInfoPolicies"

	worldPropertyMaxPairs = 64
	sizeInfoMaxPairs      = 16
	biomeInfoMaxPairs     = 32
)

var (
	worldCreateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("biome", validate.StringPlain, validate.StringShort, 0, true, true),
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 0, true, true),
			validate.NewStringPolicy("slug", validate.StringPlain, validate.StringStandard, 0, true, true),
			validate.NewStringPolicy("seed", validate.StringInt, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("description", validate.StringPlain, validate.StringText, 0, false, true),
		},
		[]string{"id", "owner", "sizeId", "size", "isVisible", "createdAt", "updatedAt", "totalPaid"},
		worldPropertyMaxPairs,
		true,
	)

	worldUpdateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 0, false, true),
			validate.NewStringPolicy("slug", validate.StringPlain, validate.StringStandard, 0, false, true),
			validate.NewStringPolicy("description", validate.StringPlain, validate.StringText, 0, false, true),
		},
		[]string{"id", "owner", "sizeId", "size", "isVisible", "createdAt", "updatedAt", "totalPaid", "biome", "seed"},
		worldPropertyMaxPairs,
		true,
	)

	sizeInfoValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("id", validate.StringInt, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("size", validate.StringInt, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("cost", validate.StringInt, validate.StringShort, 0, true, false),
		},
		nil,
		sizeInfoMaxPairs,
		true,
	)

	biomeInfoValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("biome", validate.StringPlain, validate.StringShort, 0, true, true),
			validate.NewStringPolicy("cost", validate.StringInt, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("priceMultiplierBPS", validate.StringInt, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 100, false, true),
			validate.NewStringPolicy("description", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("theme", validate.StringPlain, validate.StringText, 0, false, true),
		},
		nil,
		biomeInfoMaxPairs,
		true,
	)
)

func SetWorldCreatePolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	worldCreateValidator = next

	chain.Emit(SetWorldCreatePoliciesEvent)
}

func SetWorldUpdatePolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	worldUpdateValidator = next

	chain.Emit(SetWorldUpdatePoliciesEvent)
}

func SetSizeInfoPolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	sizeInfoValidator = next

	chain.Emit(SetSizeInfoPoliciesEvent)
}

func SetBiomeInfoPolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	biomeInfoValidator = next

	chain.Emit(SetBiomeInfoPoliciesEvent)
}

func GetWorldCreatePolicies() validate.Validator {
	return worldCreateValidator.Clone()
}

func GetWorldUpdatePolicies() validate.Validator {
	return worldUpdateValidator.Clone()
}

func GetSizeInfoPolicies() validate.Validator {
	return sizeInfoValidator.Clone()
}

func GetBiomeInfoPolicies() validate.Validator {
	return biomeInfoValidator.Clone()
}
