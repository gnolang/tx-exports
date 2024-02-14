
​package hello
​
import "testing"
​
func Test(t *testing.T) {
	{
		got := Hello()
		expected := "Hello() called"
		if got != expected {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}
​
	{
		got := Render("")
		expected := "Render(path string) called with\n# "
		if got != expected {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}
​
	{
		got := Render("n3wbie")
		expected := "Render(path string) called with\n# n3wbie"
		if got != expected {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}
}