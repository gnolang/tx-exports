package bountyboard

import "testing"

// Unit tests for board helpers that do not require live bank state.
// Full coin-path E2E is verified on Test13 via gnokey (see deploy/DEPLOYED.md).

func TestEnsureIdempotent(t *testing.T) {
	// reset package-level state is not possible; only exercise ensure shape
	ensure()
	if roleSet == nil {
		t.Fatal("roleSet")
	}
	if deals == nil {
		t.Fatal("deals")
	}
}

func TestDefaultTimeoutConstant(t *testing.T) {
	if DefaultTimeoutSecs <= 0 {
		t.Fatal("default timeout must be positive for fund safety")
	}
}
