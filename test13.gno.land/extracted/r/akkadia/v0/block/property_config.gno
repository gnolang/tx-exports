package block

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/validate"
	"gno.land/r/akkadia/v0/admin"
)

const (
	SetCreatePoliciesEvent  = "SetCreatePolicies"
	SetUpdatePoliciesEvent  = "SetUpdatePolicies"
	SetInstallPoliciesEvent = "SetInstallPolicies"

	blockPropertyMaxPairs = 64
)

var (
	createValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, maxBlockNameLength, true, false),
			validate.NewStringPolicy("blockType", validate.StringPlain, validate.StringText, 0, true, true),
			validate.NewStringPolicy("layer", validate.StringPlain, validate.StringText, 0, true, true),
			validate.NewStringPolicy("drawType", validate.StringPlain, validate.StringText, 0, true, true),
			validate.NewStringPolicy("textureLayer", validate.StringPlain, validate.StringText, 0, true, true),
			validate.NewStringPolicy("textureURL", validate.StringPlain, validate.StringText, 0, true, true),
			validate.NewStringPolicy("previewURL", validate.StringPlain, validate.StringText, 0, true, true),
			validate.NewStringPolicy("maxSupply", validate.StringInt, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("mintPrice", validate.StringUint, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("usePrice", validate.StringUint, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("installerBps", validate.StringUint, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("shape", validate.StringUint, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("state", validate.StringUint, validate.StringShort, 0, true, false),
			validate.NewStringPolicy("emission", validate.StringUint, validate.StringShort, 0, true, false),
		},
		[]string{"id", "creator"},
		blockPropertyMaxPairs,
		true,
	)

	updateValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("name", validate.StringPlain, validate.StringStandard, maxBlockNameLength, false, false),
			validate.NewStringPolicy("blockType", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("layer", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("drawType", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("textureLayer", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("textureURL", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("previewURL", validate.StringPlain, validate.StringText, 0, false, true),
			validate.NewStringPolicy("maxSupply", validate.StringInt, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("mintPrice", validate.StringUint, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("usePrice", validate.StringUint, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("installerBps", validate.StringUint, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("shape", validate.StringUint, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("state", validate.StringUint, validate.StringShort, 0, false, false),
			validate.NewStringPolicy("emission", validate.StringUint, validate.StringShort, 0, false, false),
		},
		[]string{"id", "creator"},
		blockPropertyMaxPairs,
		true,
	)

	installValidator = validate.NewValidator(
		validate.DefaultStringPolicy{LenKind: validate.StringStandard, AllowEmpty: true},
		[]validate.StringPolicy{
			validate.NewStringPolicy("content", validate.StringPlain, validate.StringText, 0, false, true),
		},
		[]string{"id", "position", "blockId", "installer", "shape", "state"},
		blockPropertyMaxPairs,
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

func SetInstallPolicies(cur realm, defaultPolicy validate.DefaultStringPolicy, newPolicies []validate.StringPolicy, pairMax int, denyKeys []string, allowUnknown bool) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	// NewValidator copies denyKeys and stores policies by value in its own map.
	next := validate.NewValidator(defaultPolicy, newPolicies, denyKeys, pairMax, allowUnknown)
	installValidator = next

	chain.Emit(SetInstallPoliciesEvent)
}

func GetCreatePolicies() validate.Validator {
	return createValidator.Clone()
}

func GetUpdatePolicies() validate.Validator {
	return updateValidator.Clone()
}

func GetInstallPolicies() validate.Validator {
	return installValidator.Clone()
}
