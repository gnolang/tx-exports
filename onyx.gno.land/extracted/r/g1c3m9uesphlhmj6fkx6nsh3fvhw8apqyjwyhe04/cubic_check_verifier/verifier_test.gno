package cubic_check_verifier

import "testing"

func TestGeneratedVKInitialized(t *testing.T) {
	if ExpectedPublicInputs() != 1 {
		t.Fatalf("expected 1 public inputs, got %d", ExpectedPublicInputs())
	}
	if len(vk.IC) != 2 {
		t.Fatalf("expected 2 IC points, got %d", len(vk.IC))
	}
}
