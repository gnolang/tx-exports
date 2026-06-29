package personal_world

import "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"

func copyStringMap(source map[string]string) map[string]string {
	if source == nil {
		return nil
	}
	result := map[string]string{}
	for key, value := range source {
		result[key] = value
	}
	return result
}

func copyStringSlice(source []string) []string {
	if source == nil {
		return nil
	}
	result := make([]string, len(source))
	for i, value := range source {
		result[i] = value
	}
	return result
}

const (
	maxInt64 = int64(9223372036854775807)
)

func assertCanGrantRole(worldID uint32, caller address, roleName string) {
	if admin.IsAdmin(caller) || isOwner(worldID, caller) {
		return
	}
	if HasPermission(worldID, caller, "role:grant") && hasGrantableRole(worldID, caller, roleName) {
		return
	}
	panic("cannot grant role: caller lacks permission to assign role '" + roleName + "'")
}

func assertCanRevokeRole(worldID uint32, caller address, roleName string) {
	if admin.IsAdmin(caller) || isOwner(worldID, caller) {
		return
	}
	if HasPermission(worldID, caller, "role:revoke") && hasRevokableRole(worldID, caller, roleName) {
		return
	}
	panic("cannot revoke role: caller lacks permission to revoke role '" + roleName + "'")
}

func parseCSVMap(keys, values string, panicMessagePrefix string) map[string]string {
	pending := map[string]string{}
	keyStart, valStart := 0, 0
	keyIdx, valIdx := 0, 0
	for {
		for keyIdx < len(keys) && keys[keyIdx] != ',' {
			keyIdx++
		}
		for valIdx < len(values) && values[valIdx] != ',' {
			valIdx++
		}

		key := keys[keyStart:keyIdx]
		val := values[valStart:valIdx]
		pending[key] = val

		keyEnd := keyIdx >= len(keys)
		valEnd := valIdx >= len(values)

		if keyEnd != valEnd {
			panic(panicMessagePrefix + " keys and values count mismatch")
		}
		if keyEnd {
			break
		}

		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}

	return pending
}

func calculateBPSShares(amount int64, bps int64) (int64, int64) {
	if amount <= 0 {
		return 0, 0
	}
	denominator := int64(10000)
	first := (amount/denominator)*bps + ((amount%denominator)*bps)/denominator
	return first, amount - first
}

func multiplyByBPS(amount int64, bps int64, panicMsg string) int64 {
	if amount <= 0 {
		return 0
	}
	if bps < 0 {
		panic(panicMsg)
	}

	denominator := int64(10000)
	wholeAmount := amount / denominator
	remainingAmount := amount % denominator
	first := safeMultiply(wholeAmount, bps, panicMsg)
	second := safeMultiply(remainingAmount, bps, panicMsg) / denominator
	return safeAdd(first, second, panicMsg)
}

func safeMultiply(a int64, b int64, panicMsg string) int64 {
	if a == 0 || b == 0 {
		return 0
	}
	if a < 0 || b < 0 {
		panic(panicMsg)
	}
	if a > maxInt64/b {
		panic(panicMsg)
	}
	return a * b
}

func safeAdd(a int64, b int64, panicMsg string) int64 {
	if a < 0 || b < 0 {
		panic(panicMsg)
	}
	if a > maxInt64-b {
		panic(panicMsg)
	}
	return a + b
}
