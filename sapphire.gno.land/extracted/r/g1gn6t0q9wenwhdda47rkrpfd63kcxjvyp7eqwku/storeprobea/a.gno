// Storage probe A: a realm with code and NO package-level state.
package storeprobea

func Add(a, b int) int { return a + b }

func Render(path string) string { return "probe a" }
