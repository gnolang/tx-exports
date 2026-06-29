package chunk

func parseKeyValue(arr []string) map[string]string {
	m := make(map[string]string)
	for i := 0; i < len(arr)-1; i += 2 {
		m[arr[i]] = arr[i+1]
	}
	return m
}

func copyStringMap(source map[string]string) map[string]string {
	result := make(map[string]string)
	for key, value := range source {
		result[key] = value
	}
	return result
}
