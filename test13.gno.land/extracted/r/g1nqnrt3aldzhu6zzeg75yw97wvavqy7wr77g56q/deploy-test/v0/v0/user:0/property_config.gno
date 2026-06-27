package user

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	SetCreatePoliciesEvent = "SetCreatePolicies"
	SetUpdatePoliciesEvent = "SetUpdatePolicies"

	maxPairs = 64
)

var (
	createValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("nickname", validate.StringPlain, validate.StringShort, 20, true, false),
		},
		nil,
		maxPairs,
		true,
	)

	updateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("nickname", validate.StringPlain, validate.StringShort, 20, false, false),
		},
		nil,
		maxPairs,
		true,
	)
)

func SetCreatePolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	createValidator = next

	chain.Emit(SetCreatePoliciesEvent)
}

func SetUpdatePolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	updateValidator = next

	chain.Emit(SetUpdatePoliciesEvent)
}

func validateCreateProperties(props map[string]string) {
	valid, message := createValidator.Validate(props)
	if !valid {
		panic("properties: " + message)
	}
	assertValidNickname(props["nickname"])
}

func validateUpdateProperties(props map[string]string) {
	valid, message := updateValidator.Validate(props)
	if !valid {
		panic("properties: " + message)
	}
	if nickname, found := props["nickname"]; found {
		assertValidNickname(nickname)
	}
}
