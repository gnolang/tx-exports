package blueprint

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
