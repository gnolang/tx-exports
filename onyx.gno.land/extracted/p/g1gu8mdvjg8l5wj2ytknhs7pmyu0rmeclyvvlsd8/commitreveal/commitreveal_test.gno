package commitreveal

import "testing"

// Known vector, computed off-chain with:
//
//	printf 's3cret:hello world' | sha256sum
const (
	testPayload    = "hello world"
	testSalt       = "s3cret"
	testCommitment = "b5165d20616e37ff3b4c84c2ba2914ced11bf2df7755a8876f2b22d30fb2409a"
)

func TestCommitKnownVector(t *testing.T) {
	got := Commit(testPayload, testSalt)
	if got != testCommitment {
		t.Fatalf("Commit(%q, %q) = %q, want %q", testPayload, testSalt, got, testCommitment)
	}
}

func TestCommitFormat(t *testing.T) {
	if !IsCommitment(Commit("anything", "else")) {
		t.Fatal("Commit output must satisfy IsCommitment")
	}
	if !IsCommitment(testCommitment) {
		t.Fatal("known vector must satisfy IsCommitment")
	}
}

func TestVerifyHappyPath(t *testing.T) {
	if !Verify(testCommitment, testPayload, testSalt) {
		t.Fatal("Verify must accept the correct payload and salt")
	}
	c := Commit("a secret message", "random-salt-123")
	if !Verify(c, "a secret message", "random-salt-123") {
		t.Fatal("Verify must accept a freshly computed commitment")
	}
}

func TestVerifyWrongPayload(t *testing.T) {
	if Verify(testCommitment, "hello worle", testSalt) {
		t.Fatal("Verify must reject a wrong payload")
	}
	if Verify(testCommitment, "", testSalt) {
		t.Fatal("Verify must reject an empty payload")
	}
}

func TestVerifyWrongSalt(t *testing.T) {
	if Verify(testCommitment, testPayload, "s3creT") {
		t.Fatal("Verify must reject a wrong salt")
	}
	if Verify(testCommitment, testPayload, "") {
		t.Fatal("Verify must reject an empty salt")
	}
}

func TestMalformedCommitments(t *testing.T) {
	bad := []string{
		"",                                                                 // empty
		"b5165d20616e37ff3b4c84c2ba2914ced11bf2df7755a8876f2b22d30fb2409",   // 63 chars
		"b5165d20616e37ff3b4c84c2ba2914ced11bf2df7755a8876f2b22d30fb2409aa", // 65 chars
		"B5165D20616E37FF3B4C84C2BA2914CED11BF2DF7755A8876F2B22D30FB2409A", // uppercase
		"g5165d20616e37ff3b4c84c2ba2914ced11bf2df7755a8876f2b22d30fb2409a", // non-hex char
		" b5165d20616e37ff3b4c84c2ba2914ced11bf2df7755a8876f2b22d30fb2409a", // leading space
	}
	for _, s := range bad {
		if IsCommitment(s) {
			t.Fatalf("IsCommitment(%q) = true, want false", s)
		}
		if Verify(s, testPayload, testSalt) {
			t.Fatalf("Verify(%q, ...) = true, want false", s)
		}
	}
}
