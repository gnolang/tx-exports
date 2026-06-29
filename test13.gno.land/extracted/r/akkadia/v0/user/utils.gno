package user

func copyStringMap(source map[string]string) map[string]string {
	result := map[string]string{}
	for k, v := range source {
		result[k] = v
	}
	return result
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
