package user

import "net/url"

// parsePropertiesCSV accepts comma-separated keys and comma-separated values.
// Each value must be URL-encoded so commas and other separators can be carried
// safely; this parser URL-decodes values before returning the map.
//
// Empty key lists and empty keys are rejected because keys define the map
// shape. Empty values are policy-dependent, so the parser preserves them for
// the create/update validator.
//
// Valid examples:
//
//	keys="nickname,introduction" values="Alice,hello%2C%20world"
//	keys="nickname,introduction" values="Alice,"                 # introduction is preserved as an empty value.
//	keys="nickname,introduction" values=","                      # both values are preserved as empty values.
//
// Invalid examples:
//
//	keys="" values=""
//	keys="nickname," values="Alice,"
//	keys="nickname,introduction" values="Alice"
//	keys="nickname,introduction" values=""          # key/value count mismatch.
//	keys="nickname,introduction" values="Alice,%zz"
func parsePropertiesCSV(keys, values string) map[string]string {
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
