package pad

// PadLeft pads the input string on the left with the specified character to the desired total length.
// If the length of the input string is greater than or equal to the desired total length, the original string is returned.
//
// Parameters:
// - value: The string to be padded.
// - totalLength: The desired total length of the string after padding.
// - padChar: The character to use for padding.
//
// Returns:
// The padded string.
//
// Example:
//
//	result := PadLeft("hello", 10, "*")
//	fmt.Println(result) // *****hello
func PadLeft(value string, totalLength int, padChar string) string {
	if len(value) >= totalLength {
		return value
	}
	padding := totalLength - len(value)
	return repeat(padChar, padding) + value
}

// PadRight pads the input string on the right with the specified character to the desired total length.
// If the length of the input string is greater than or equal to the desired total length, the original string is returned.
//
// Parameters:
// - value: The string to be padded.
// - totalLength: The desired total length of the string after padding.
// - padChar: The character to use for padding.
//
// Returns:
// The padded string.
//
// Example:
//
//	result := PadRight("hello", 10, "*")
//	fmt.Println(result) // hello*****
func PadRight(value string, totalLength int, padChar string) string {
	if len(value) >= totalLength {
		return value
	}
	padding := totalLength - len(value)
	return value + repeat(padChar, padding)
}

// TrimLeft removes the specified character from the left side of the string.
//
// Parameters:
// - value: The string to be trimmed.
// - trimChar: The character to be removed.
//
// Returns:
// The trimmed string.
//
// Example:
//
//	result := TrimLeft("***hello", "*")
//	fmt.Println(result) // hello
func TrimLeft(value string, trimChar string) string {
	i := 0
	for i < len(value) && string(value[i]) == trimChar {
		i++
	}
	return value[i:]
}

// TrimRight removes the specified character from the right side of the string.
//
// Parameters:
// - value: The string to be trimmed.
// - trimChar: The character to be removed.
//
// Returns:
// The trimmed string.
//
// Example:
//
//	result := TrimRight("hello***", "*")
//	fmt.Println(result) // hello
func TrimRight(value string, trimChar string) string {
	i := len(value) - 1
	for i >= 0 && string(value[i]) == trimChar {
		i--
	}
	return value[:i+1]
}

// repeat is a helper function to repeat a string n times.
func repeat(char string, count int) string {
	result := ""
	for i := 0; i < count; i++ {
		result += char
	}
	return result
}
