package verification

import "testing"

func TestRegistry(t *testing.T) {
    if Count() != 0 {
        t.Fatal("expected empty registry")
    }
    hash := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    index := RegisterEvidence(hash)
    if index != 1 || Count() != 1 || !HasEvidence(hash) {
        t.Fatal("failed to register evidence")
    }
}
