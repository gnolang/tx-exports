package rfburn

import "strconv"

// Render loops path-many times to probe the gas limit of a render query.
func Render(path string) string {
	n, _ := strconv.Atoi(path)
	s := 0
	for i := 0; i < n; i++ {
		s += i % 7
	}
	return "loops " + path + " sum " + strconv.Itoa(s)
}
