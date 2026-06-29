package chunk

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

const (
	SetWorldCreatePoliciesEvent = "SetWorldCreatePolicies"
	SetWorldUpdatePoliciesEvent = "SetWorldUpdatePolicies"

	worldPropertyMaxPairs = 64
)

var (
	worldCreateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("biome", validate.StringPlain, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 0, true, false),
			validate.NewStringPolicy("slug", validate.StringPlain, validate.StringStandard, 0, true, false),
			validate.NewStringPolicy("seed", validate.StringInt, validate.StringShort, 0, true, false),
		},
		[]string{"id", "createdAt", "updatedAt"},
		worldPropertyMaxPairs,
		true,
	)

	worldUpdateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("biome", validate.StringPlain, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, 0, false, false),
			validate.NewStringPolicy("slug", validate.StringPlain, validate.StringStandard, 0, false, false),
		},
		[]string{"id", "seed", "createdAt", "updatedAt"},
		worldPropertyMaxPairs,
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

func GetWorldCreatePolicies() validate.Validator {
	return worldCreateValidator.Clone()
}

func GetWorldUpdatePolicies() validate.Validator {
	return worldUpdateValidator.Clone()
}
