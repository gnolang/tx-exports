package block

import "net/url"

// parsePropsCSV accepts comma-separated keys and comma-separated values.
// Values must be URL-encoded so commas and separators can be carried safely.
func parsePropsCSV(keys, values string) map[string]string {
	if keys == "" {
		panic("properties keys must be not empty")
	}

	result := map[string]string{}
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
		if key == "" {
			panic("properties key must be not empty")
		}
		if _, found := result[key]; found {
			panic("properties key duplicated: " + key)
		}

		value, err := url.PathUnescape(values[valStart:valIdx])
		if err != nil {
			panic("properties value URL decode failed: " + key)
		}
		result[key] = value

		keyEnd := keyIdx >= len(keys)
		valEnd := valIdx >= len(values)
		if keyEnd != valEnd {
			panic("properties keys and values count mismatch")
		}
		if keyEnd {
			break
		}

		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}

	return result
}

func parseOptPropsCSV(keys, values string) map[string]string {
	if keys == "" && values == "" {
		return map[string]string{}
	}
	return parsePropsCSV(keys, values)
}
