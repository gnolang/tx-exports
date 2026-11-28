package bugtavern

import (
	"testing"

	"chain"

	"gno.land/p/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/tavernrules"
)

// evilPayload is the hostile string pushed through every
// caller-supplied slot: a heading, a live link, table-breaking
// pipes, a newline, a setext/horizontal-rule line, and a script tag.
const evilPayload = "# Hacked\n[x](http://evil.example)\n| a | b |\n---\n<script>alert(1)</script>"

// TestEveryCallerSuppliedStringIsEscaped (design §7 T9) pushes the
// hostile payload through every sanitizer and, once Render exists,
// through every Render page that shows a caller-supplied string
// (board, bounty detail, finding detail, hunter profile). No live
// markup may survive: no heading, no link, no table break, no
// script tag, no newline that could smuggle a new block.
func TestEveryCallerSuppliedStringIsEscaped(cur realm, t *testing.T) {
	// Inline slot: newlines folded, brackets/parens/hash/angle
	// escaped — the link and the heading die as literal text.
	inlined := escInline(evilPayload)
	if contains(inlined, "\n") {
		t.Fatalf("escInline kept a newline: %q", inlined)
	}
	if contains(inlined, "[x](http://evil.example)") {
		t.Fatalf("escInline kept a live link: %q", inlined)
	}
	if !contains(inlined, "\\#") || !contains(inlined, "\\[x\\]") {
		t.Fatalf("escInline did not escape heading/link: %q", inlined)
	}
	if !contains(inlined, "\\<script\\>") {
		t.Fatalf("escInline did not escape the script tag: %q", inlined)
	}

	// Table-cell slot: InlineText alone does NOT escape pipes, so a
	// cell must go through escCell — pipes become \| and the row
	// cannot break out of its table.
	celled := escCell(evilPayload)
	if contains(celled, "| a | b |") {
		t.Fatalf("escCell kept live pipes: %q", celled)
	}
	if !contains(celled, "\\| a \\| b \\|") {
		t.Fatalf("escCell did not escape pipes: %q", celled)
	}
	if contains(celled, "\n") || contains(celled, "[x](http://evil.example)") {
		t.Fatalf("escCell kept a newline or live link: %q", celled)
	}

	// Block slot (prose): line-leading heading, rule line and
	// script tag are escaped; the content stays its own paragraph.
	blocked := escBlock(evilPayload)
	if contains(blocked, "\n# ") || contains(blocked, "\n---\n") {
		t.Fatalf("escBlock kept a live heading or rule line: %q", blocked)
	}
	if !contains(blocked, "\\# Hacked") || !contains(blocked, "\\<script>") {
		t.Fatalf("escBlock did not escape heading/script: %q", blocked)
	}

	// URL slot: dangerous schemes are rejected outright (""), so no
	// link is ever built from them; https passes through.
	if got := escURL("javascript:alert(1)"); got != "" {
		t.Fatalf("escURL(javascript:) = %q, want empty", got)
	}
	if got := escURL("data:text/html,<script>"); got != "" {
		t.Fatalf("escURL(data:text/html) = %q, want empty", got)
	}
	if got := escURL("https://example.com/poc"); got != "https://example.com/poc" {
		t.Fatalf("escURL(https) = %q, want the URL unchanged", got)
	}

	// Address slot: a non-bech32 path segment is rejected.
	if got := escAddr("not-an-address"); got != "" {
		t.Fatalf("escAddr(junk) = %q, want empty", got)
	}
	if got := escAddr(testHunterAddr); got != testHunterAddr {
		t.Fatalf("escAddr(valid) = %q, want %q", got, testHunterAddr)
	}

	// Render-level: the same payload stored as a bounty title/scope,
	// a finding title/PoC URL and a verdict reason must show up
	// escaped on every page that displays it — never as live markup.
	// (State is injected directly so the payload bypasses no
	// validation: titles/scopes accept any characters up to their
	// length limits. The finding is revealed through the rules move
	// and rejected through the glue, so its title, PoC and reason
	// all take the real Render path.)
	resetRealmState()
	sponsor := address(testSponsorAddr)
	arbiter := address(testArbiterAddr)
	hunter := address(testHunterAddr)
	evilTitle := "# Hacked [x](http://evil.example)"
	evilScope := "scope | a | b |\n---\n<script>alert(1)</script>"
	evilFinding := "# Pwned [x](http://evil.example)"
	evilPoc := "https://example.com/poc[x](y)"
	evilReason := "nope | a | b |\n---\n<script>alert(1)</script>"
	b := tavernrules.NewBounty(1, sponsor, arbiter, evilTitle, evilScope,
		5000000, 3000000, 1000000, 500000, 1000, 25600)
	bounties.Set(bountyKey(1), b)
	nextBountyID = 2
	hash := tavernrules.MakeCommitment(1, tavernrules.SevCritical, evilFinding, evilPoc, testSalt)
	f := tavernrules.NewFinding(1, 1, hunter, tavernrules.SevCritical, hash, 1001, 25601)
	findings.Set(findingKey(1), f)
	nextFindingID = 2
	f.Reveal(&b, hunter, evilFinding, evilPoc, testSalt, 1002)
	saveFinding(f)
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	testing.SetOriginSend(chain.NewCoins())
	Verdict(cross(cur), 1, uint8(tavernrules.VerdictReject), uint8(tavernrules.SevCritical), evilReason, 0)
	if got := GetFinding(1); got.Status() != tavernrules.FindingRejected {
		t.Fatalf("setup: finding status = %s, want Rejected", got.Status())
	}
	for _, page := range []string{"", "bounty/1", "finding/1", "hunter/" + testHunterAddr, "leaderboard", "ledger"} {
		out := Render(page)
		if contains(out, "[x](http://evil.example)") {
			t.Fatalf("Render(%q) kept a live link", page)
		}
		if contains(out, "<script>alert(1)</script>") {
			t.Fatalf("Render(%q) kept a live script tag", page)
		}
		if contains(out, "\n# Hacked") || contains(out, "\n# Pwned") {
			t.Fatalf("Render(%q) kept a live heading", page)
		}
		if contains(out, "| a | b |") {
			t.Fatalf("Render(%q) kept live table pipes", page)
		}
	}
	// And the escaped form must actually be visible (the test is
	// not vacuous: the payload really reaches the pages).
	if out := Render("bounty/1"); !contains(out, "\\# Hacked") {
		t.Fatalf("Render(bounty/1) does not show the escaped title: %q", out)
	}
	if out := Render("finding/1"); !contains(out, "\\# Pwned") {
		t.Fatalf("Render(finding/1) does not show the escaped finding title: %q", out)
	}
}

func TestFmtGNOT(t *testing.T) {
	for _, c := range []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{500000, "0.5"},
		{1000000, "1"},
		{4500000, "4.5"},
		{5000000, "5"},
		{9500000, "9.5"},
		{1234567, "1.234567"},
		{1000001, "1.000001"},
		{-500000, "-0.5"},
	} {
		if got := fmtGNOT(c.in); got != c.want {
			t.Fatalf("fmtGNOT(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestShortAddr(t *testing.T) {
	if got := shortAddr(address(testHunterAddr)); got != "g1x582…uuq4" {
		t.Fatalf("shortAddr(hunter) = %q, want %q", got, "g1x582…uuq4")
	}
}
