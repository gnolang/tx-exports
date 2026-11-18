package halt

import (
	"chain"

	"gno.land/p/gnoswap/utils/v1"
	"gno.land/p/onbloc/json/v0"

	"gno.land/r/gnoswap/access/v1"
)

var (
	// targets lists the registered targets, in registration order.
	targets = []string{TargetDCA, TargetLimit}

	// halted holds the switches that are on, keyed by "<target>:<operation>".
	halted = map[string]bool{}
)

// AddTarget registers a target, e.g. for a new order realm.
// Admin or governance only.
//
// A target is 1 to 32 characters of lowercase letters, digits, '_', or '-',
// and cannot be TargetAll.
func AddTarget(cur realm, target string) {
	caller := cur.Previous()
	access.AssertIsAdminOrGovernance(caller.Address())

	if err := validateTargetName(target); err != nil {
		panic(err.Error())
	}

	if isTarget(target) {
		panic(makeErrorWithDetails(errTargetExists, "target("+target+")").Error())
	}

	targets = append(targets, target)

	chain.Emit(
		"OrderHaltTargetAdded",
		"prevAddr", caller.Address().String(),
		"prevRealm", caller.PkgPath(),
		"target", target,
	)
}

// SetHalted halts or resumes operation for target. Admin or governance only.
//
// Parameters:
//   - target: a registered target, or TargetAll for every target.
//   - operation: OperationExecute or OperationWithdraw.
func SetHalted(cur realm, target string, operation string, isHalted bool) {
	caller := cur.Previous()
	access.AssertIsAdminOrGovernance(caller.Address())

	if err := validate(target, operation); err != nil {
		panic(err.Error())
	}

	key := switchKey(target, operation)

	prevValue := halted[key]
	if isHalted {
		halted[key] = true
	} else {
		delete(halted, key)
	}

	chain.Emit(
		"OrderHaltUpdated",
		"prevAddr", caller.Address().String(),
		"prevRealm", caller.PkgPath(),
		"target", target,
		"operation", operation,
		"prevValue", utils.FormatBool(prevValue),
		"newValue", utils.FormatBool(isHalted),
	)
}

// IsHalted reports whether operation is halted for target,
// by its own switch or by the TargetAll switch.
// It panics on an unknown target or operation.
func IsHalted(target string, operation string) bool {
	if err := validate(target, operation); err != nil {
		panic(err.Error())
	}

	return halted[switchKey(TargetAll, operation)] || halted[switchKey(target, operation)]
}

// GetTargets returns the registered targets, in registration order.
func GetTargets() []string {
	out := make([]string, len(targets))
	copy(out, targets)

	return out
}

// GetOperations returns the operations that can be halted.
func GetOperations() []string {
	out := make([]string, len(operations))
	copy(out, operations)

	return out
}

// GetHaltedJSON returns, as JSON, whether each operation is halted for
// target, including the TargetAll switches.
func GetHaltedJSON(target string) string {
	if err := validateTarget(target); err != nil {
		panic(err.Error())
	}

	nodes := make(map[string]*json.Node, len(operations))
	for _, operation := range operations {
		nodes[operation] = json.BoolNode("", IsHalted(target, operation))
	}

	encoded, err := json.Marshal(json.ObjectNode("", nodes))
	if err != nil {
		panic(err.Error())
	}

	return string(encoded)
}

func validate(target string, operation string) error {
	if err := validateTarget(target); err != nil {
		return err
	}

	if !contains(operations, operation) {
		return makeErrorWithDetails(errInvalidOperation, "operation("+operation+")")
	}

	return nil
}

func validateTarget(target string) error {
	if target != TargetAll && !isTarget(target) {
		return makeErrorWithDetails(errInvalidTarget, "target("+target+") is not registered")
	}

	return nil
}

func validateTargetName(target string) error {
	if target == "" || len(target) > maxTargetLength || target == TargetAll {
		return makeErrorWithDetails(errInvalidTarget, "target("+target+")")
	}

	for _, c := range target {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return makeErrorWithDetails(errInvalidTarget, "target("+target+") has an invalid character")
		}
	}

	return nil
}

func isTarget(target string) bool {
	return contains(targets, target)
}

func switchKey(target string, operation string) string {
	return target + ":" + operation
}

func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}

	return false
}
