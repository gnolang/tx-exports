package square_diff_verifier

import "testing"

func TestGeneratedVKInitialized(t *testing.T) {
	if ExpectedPublicInputs() != 3 {
		t.Fatalf("expected 3 public inputs, got %d", ExpectedPublicInputs())
	}
	if len(vk.IC) != 4 {
		t.Fatalf("expected 4 IC points, got %d", len(vk.IC))
	}
}
