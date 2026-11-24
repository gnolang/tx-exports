package shiplog

import "testing"

func TestParseSemver(t *testing.T) {
	valid := []string{
		"0.0.1", "1.2.3", "10.20.30", "1.0.0-alpha", "1.0.0-alpha.1",
		"1.0.0-0.3.7", "1.0.0-x.7.z.92", "1.0.0+20130313144700",
		"1.0.0-beta+exp.sha.5114f85",
	}
	for _, s := range valid {
		if _, err := parseSemver(s); err != nil {
			t.Fatalf("parseSemver(%q) unexpected error: %v", s, err)
		}
	}
	invalid := []string{
		"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03",
		"1.2.3-", "1.2.3-01", "1.2.3+", "1.2.3-a..b",
		"v1.2.3", "1.2.-3", "1.2.3-alpha_beta", " 1.2.3",
	}
	for _, s := range invalid {
		if Valid(s) {
			t.Fatalf("Valid(%q) = true, want false", s)
		}
	}
}

func TestPrecedenceChain(t *testing.T) {
	// The ordering example from semver.org §11, ascending.
	chain := []string{
		"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
		"1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
	}
	for i := 0; i < len(chain)-1; i++ {
		a, err := parseSemver(chain[i])
		if err != nil {
			t.Fatalf("parse %q: %v", chain[i], err)
		}
		b, err := parseSemver(chain[i+1])
		if err != nil {
			t.Fatalf("parse %q: %v", chain[i+1], err)
		}
		if !(svCompare(b, a) > 0) {
			t.Fatalf("expected %q > %q", chain[i+1], chain[i])
		}
		if svCompare(a, b) > 0 {
			t.Fatalf("expected NOT %q > %q", chain[i], chain[i+1])
		}
	}
}

func TestBuildMetadataIgnored(t *testing.T) {
	a, _ := parseSemver("1.0.0+build.1")
	b, _ := parseSemver("1.0.0+build.2")
	if svCompare(a, b) != 0 {
		t.Fatalf("build metadata must not affect precedence")
	}
}

func TestBumpClass(t *testing.T) {
	cases := []struct{ from, to, want string }{
		{"", "0.1.0", "genesis"},
		{"1.0.0", "2.0.0", "major"},
		{"1.0.0", "1.1.0", "minor"},
		{"1.0.0", "1.0.1", "patch"},
		{"1.0.0", "1.0.0", ""},
		{"1.2.0", "1.1.9", ""},
		{"1.0.0-rc.1", "1.0.0", "patch"},
		{"1.0.0", "1.0.0-rc.1", ""},
	}
	for _, c := range cases {
		if got := BumpClass(c.from, c.to); got != c.want {
			t.Fatalf("BumpClass(%q,%q) = %q, want %q", c.from, c.to, got, c.want)
		}
	}
}

// TestLedgerLifecycle drives the state machine end to end: genesis, three
// bumps, then the two rejection paths that make the ledger trustworthy.
func TestLedgerLifecycle(cur realm, t *testing.T) {
	const me = "g1e73sfpdr5ulzcuv6e4wv973de2huhuyhx65rxy"
	testing.SetRealm(testing.NewUserRealm(me))

	Register(cross(cur), "tavern-kit")
	if got := Count("tavern-kit"); got != 0 {
		t.Fatalf("fresh project has %d releases, want 0", got)
	}

	r := Ship(cross(cur), "tavern-kit", "", "0.1.0", "first public cut")
	if r.Bump != "genesis" || r.Seq != 1 {
		t.Fatalf("genesis record = %+v", r)
	}
	if r.Author != me {
		t.Fatalf("author = %q, want caller %q", r.Author, me)
	}

	if r := Ship(cross(cur), "tavern-kit", "0.1.0", "0.2.0", "ledger render"); r.Bump != "minor" {
		t.Fatalf("0.1.0->0.2.0 classified %q", r.Bump)
	}
	if r := Ship(cross(cur), "tavern-kit", "0.2.0", "0.2.1", "escaping fix"); r.Bump != "patch" {
		t.Fatalf("0.2.0->0.2.1 classified %q", r.Bump)
	}
	if r := Ship(cross(cur), "tavern-kit", "0.2.1", "1.0.0", "stable API"); r.Bump != "major" {
		t.Fatalf("0.2.1->1.0.0 classified %q", r.Bump)
	}

	if got := Count("tavern-kit"); got != 4 {
		t.Fatalf("count = %d, want 4", got)
	}
	if got, _ := Total(); got < 4 {
		t.Fatalf("total releases = %d, want >= 4", got)
	}
	last, ok := Latest("tavern-kit")
	if !ok || last.ToVersion != "1.0.0" {
		t.Fatalf("latest = %+v ok=%v", last, ok)
	}
}

// TestRejectsBrokenChain covers the property that makes this a chain rather
// than a bag of claims: `from` must be the version actually shipped last.
func TestRejectsBrokenChain(cur realm, t *testing.T) {
	const me = "g1e73sfpdr5ulzcuv6e4wv973de2huhuyhx65rxy"
	testing.SetRealm(testing.NewUserRealm(me))
	Register(cross(cur), "chain-test")
	Ship(cross(cur), "chain-test", "", "1.0.0", "start")

	if rec := revive(func() { Ship(cross(cur), "chain-test", "0.9.0", "1.0.1", "wrong from") }); rec == nil {
		t.Fatalf("expected panic when from does not match last shipped version")
	}
	if rec := revive(func() { Ship(cross(cur), "chain-test", "1.0.0", "1.0.0", "no increase") }); rec == nil {
		t.Fatalf("expected panic when version does not increase")
	}
	if rec := revive(func() { Ship(cross(cur), "chain-test", "1.0.0", "1.0.0-rc.1", "downgrade") }); rec == nil {
		t.Fatalf("expected panic on downgrade to prerelease")
	}
	if rec := revive(func() { Register(cross(cur), "chain-test") }); rec == nil {
		t.Fatalf("expected panic on duplicate registration")
	}
	if got := Count("chain-test"); got != 1 {
		t.Fatalf("rejected records mutated the ledger: count = %d, want 1", got)
	}
}

// TestOnlyOwnerWrites proves authorship is enforced, not self-declared.
func TestOnlyOwnerWrites(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm("g1e73sfpdr5ulzcuv6e4wv973de2huhuyhx65rxy"))
	Register(cross(cur), "owned-test")
	Ship(cross(cur), "owned-test", "", "0.1.0", "mine")

	testing.SetRealm(testing.NewUserRealm("g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"))
	if rec := revive(func() { Ship(cross(cur), "owned-test", "0.1.0", "0.1.1", "not mine") }); rec == nil {
		t.Fatalf("expected panic when a non-owner writes")
	}
}

// TestRenderEscapesPathPerProject covers the injection surface: path text is
// caller-controlled and must not break out of the code span.
func TestRenderEscapesPathPerProject(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm("g1e73sfpdr5ulzcuv6e4wv973de2huhuyhx65rxy"))
	Register(cross(cur), "render-test")
	Ship(cross(cur), "render-test", "", "2.0.0", "ship it")

	out := Render("")
	if !contains(out, "render-test") || !contains(out, "2.0.0") {
		t.Fatalf("render lost the project: %s", out)
	}
	bad := Render("no-such-`project`")
	if contains(bad, "no-such-`project`") {
		t.Fatalf("path backtick was not neutralised: %s", bad)
	}
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
