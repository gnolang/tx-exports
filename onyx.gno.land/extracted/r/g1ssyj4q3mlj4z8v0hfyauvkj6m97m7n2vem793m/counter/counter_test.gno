package counter

import "testing"

func TestIncrement(cur realm, t *testing.T) {
	before := GetCount()
	val := Increment(cross(cur))
	if val != before+1 {
		t.Fatalf("after Increment: got %d, want %d", val, before+1)
	}
	if got := GetCount(); got != before+1 {
		t.Fatalf("GetCount after Increment: got %d, want %d", got, before+1)
	}
	val = Increment(cross(cur))
	if val != before+2 {
		t.Fatalf("after 2nd Increment: got %d, want %d", val, before+2)
	}
}

func TestRenderShowsCount(t *testing.T) {
	rendered := Render("")
	if rendered == "" {
		t.Fatal("Render returned empty string")
	}
	// Render must contain the current count as text.
	want := "Current count: " + itoa(GetCount())
	if !contains(rendered, want) {
		t.Fatalf("Render() = %q, want it to contain %q", rendered, want)
	}
}

// itoa converts a small non-negative int to decimal without strconv,
// so the test does not depend on the same helper the realm uses.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

func contains(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
