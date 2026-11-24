package rulecalc

import "testing"

func apps2() []App {
	return []App{
		{Title: "Alpha", PkgPath: "gno.land/r/x/alpha", Payout: address("g1alpha")},
		{Title: "Beta", PkgPath: "gno.land/r/x/beta", Payout: address("g1beta")},
	}
}

func TestAppsDigestStable(t *testing.T) {
	a := AppsDigest(apps2(), "salt")
	b := AppsDigest(apps2(), "salt")
	if a != b {
		t.Fatal("same input, different digest")
	}
	if len(a) != 64 {
		t.Fatalf("want 64 hex chars, got %d", len(a))
	}
}

func TestAppsDigestKnownVector(t *testing.T) {
	// sha256("Alpha|gno.land/r/x/alpha|g1alpha\nBeta|gno.land/r/x/beta|g1beta\nsalt")
	// computed independently: printf 'Alpha|...\nBeta|...\nsalt' | sha256sum
	want := "451fc91dfae0103fc7f9a91c168aa15c290f0bbe7217e9acfc900c32ababe09a"
	if got := AppsDigest(apps2(), "salt"); got != want {
		t.Fatalf("digest mismatch: got %s", got)
	}
}

func TestAppsDigestSensitive(t *testing.T) {
	base := AppsDigest(apps2(), "salt")

	swapped := apps2()
	swapped[0], swapped[1] = swapped[1], swapped[0]
	if AppsDigest(swapped, "salt") == base {
		t.Error("order change not detected")
	}

	payout := apps2()
	payout[1].Payout = address("g1other")
	if AppsDigest(payout, "salt") == base {
		t.Error("payout change not detected")
	}

	if AppsDigest(apps2(), "pepper") == base {
		t.Error("salt change not detected")
	}
}

func TestAppsDigestRejectsSeparators(t *testing.T) {
	bad := [][]App{
		{{Title: "A|B", PkgPath: "p", Payout: address("g1")}},
		{{Title: "A", PkgPath: "p\nq", Payout: address("g1")}},
		{{Title: "A", PkgPath: "p", Payout: address("g1|x")}},
	}
	for i, apps := range bad {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("case %d: expected panic", i)
				}
			}()
			AppsDigest(apps, "salt")
		}()
	}
}

// A salt holding application lines would let the same digest open to a shorter
// list: [A, B]+salt and [A]+"B|...\nsalt" hash the same bytes.
func TestAppsDigestRejectsSaltHidingApps(t *testing.T) {
	full := AppsDigest(apps2(), "salt")
	defer func() {
		if recover() == nil {
			t.Error("expected panic for a salt with a newline")
		}
	}()
	got := AppsDigest(apps2()[:1], "Beta|gno.land/r/x/beta|g1beta\nsalt")
	if got == full {
		t.Error("the same digest opens to a shorter application list")
	}
}
