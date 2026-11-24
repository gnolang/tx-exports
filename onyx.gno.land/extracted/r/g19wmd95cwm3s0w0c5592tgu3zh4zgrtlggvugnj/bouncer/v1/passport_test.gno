package bouncer

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const (
	snippet = "func Ledger() *avl.Tree {\n\treturn ledger\n}"
	exploit = "package attacker\n\nfunc main(cur realm) {\n\tvictim.Ledger().Set(\"bouncer-probe\", int64(0))\n}"
)

func TestFindingFunc(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	attest(cur, "gno.land/r/demo/fv", hash("c"), "B01,high,PROVEN,vault.gno,69,Ledger;B05,critical,STATIC WARNING,vault.gno,9,Store.Pay", 0)
	a, _ := Latest("gno.land/r/demo/fv")
	uassert.Equal(t, "Ledger", a.Findings[0].Func)
	uassert.Equal(t, "Store.Pay", a.Findings[1].Func)
	for _, bad := range []string{"1x", "a b", "a..b", "a-b", ""} {
		testing.SetRealm(testing.NewUserRealm(botAddr))
		uassert.AbortsWithMessage(t, cur, "invalid function name: "+bad, func() {
			Attest(cross(cur), "gno.land/r/demo/fv", hash("a"), "0.1.0", hash("b"), "x", hash("c"), "ipfs://bafy", "B01,high,PROVEN,vault.gno,69,"+bad, 0, 0, 0)
		})
	}
}

func TestAddDetail(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	p := "gno.land/r/demo/dv"
	attest(cur, p, hash("c"), "B01,high,PROVEN,vault.gno,69,Ledger;B05,critical,NOT REPRODUCED,vault.gno,35", 0)
	a, _ := Latest(p)

	// Only the attestation's own attester.
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	uassert.AbortsWithMessage(t, cur, "only the attestation's own attester can add details", func() {
		AddDetail(cross(cur), p, a.ID, 0, snippet, "", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "attester only", func() {
		AddDetail(cross(cur), p, a.ID, 0, snippet, "", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "finding index out of range", func() {
		AddDetail(cross(cur), p, a.ID, 2, snippet, "", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "no such attestation for this package", func() {
		AddDetail(cross(cur), p, a.ID+100, 0, snippet, "", "", "", "")
	})
	// No exploit on a finding that is not PROVEN.
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "only PROVEN findings carry an exploit and evidence", func() {
		AddDetail(cross(cur), p, a.ID, 1, snippet, "", exploit, "", "")
	})
	// Text checks.
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "snippet contains a control character", func() {
		AddDetail(cross(cur), p, a.ID, 0, "a\x00b", "", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "attack must be one line", func() {
		AddDetail(cross(cur), p, a.ID, 0, snippet, "a\nb", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "exploit is too long (max 6000 bytes)", func() {
		AddDetail(cross(cur), p, a.ID, 0, snippet, "", strings.Repeat("x", 6001), "", "")
	})

	testing.SetRealm(testing.NewUserRealm(botAddr))
	AddDetail(cross(cur), p, a.ID, 0, snippet, "inserted a ledger entry with Set", exploit, "| alice | 5 |", "| alice | 5 |\n| bouncer-probe | 5 |")
	testing.SetRealm(testing.NewUserRealm(botAddr))
	AddDetail(cross(cur), p, a.ID, 1, "if !caller.IsUser() {", "", "", "", "")

	// Set once.
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "details already added for this finding", func() {
		AddDetail(cross(cur), p, a.ID, 0, "other", "", "", "", "")
	})

	got, _ := Latest(p)
	urequire.True(t, got.Findings[0].Detailed)
	uassert.Equal(t, snippet, got.Findings[0].Snippet)
	uassert.Equal(t, exploit, got.Findings[0].Exploit)
	uassert.Equal(t, "", got.Findings[1].Exploit)
}

func TestAddDetailTotalLimit(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	p := "gno.land/r/demo/big"
	fs := []string{}
	for i := 0; i < 8; i++ {
		fs = append(fs, "B01,high,PROVEN,vault.gno,1")
	}
	attest(cur, p, hash("c"), strings.Join(fs, ";"), 0)
	a, _ := Latest(p)
	big := strings.Repeat("x", 6000)
	for i := 0; i < 5; i++ { // 5 x 6000 = 30000
		testing.SetRealm(testing.NewUserRealm(botAddr))
		AddDetail(cross(cur), p, a.ID, i, "", "", big, "", "")
	}
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "detail limit reached for this attestation; see the full report", func() {
		AddDetail(cross(cur), p, a.ID, 5, "", "", big, "", "")
	})
}

func TestVersions(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	base := "gno.land/r/" + alice.String() + "/vault"
	attest(cur, base+"/v2", hash("d"), "", 0)
	attest(cur, base+"/v1", hash("c"), "B01,high,PROVEN,vault.gno,69,Ledger;B05,critical,STATIC WARNING,vault.gno,35", 0)
	attest(cur, base+"/v10", hash("e"), "B03,critical,STATIC WARNING,vault.gno,3", 0)
	attest(cur, "gno.land/r/demo/other/v1", hash("f"), "", 0)

	vs := Versions(base + "/v2")
	urequire.Equal(t, 3, len(vs))
	uassert.Equal(t, base+"/v1", vs[0])
	uassert.Equal(t, base+"/v2", vs[1])
	uassert.Equal(t, base+"/v10", vs[2])           // numeric, not string, order
	uassert.Equal(t, 3, len(Versions(base+"/v3"))) // same package, not yet attested
	uassert.Equal(t, 1, len(Versions("gno.land/r/demo/other/v1")))

	for _, c := range []struct {
		in   string
		base string
		n    int
		ok   bool
	}{
		{"gno.land/r/demo/vault/v1", "gno.land/r/demo/vault", 1, true},
		{"gno.land/r/demo/vault/v0", "gno.land/r/demo/vault", 0, true},
		{"gno.land/r/demo/vault", "", 0, false},
		{"gno.land/r/demo/vault/v01", "", 0, false},
		{"gno.land/r/demo/vault/vx", "", 0, false},
		{"gno.land/r/v1", "", 0, false},
	} {
		b, n, ok := familyOf(c.in)
		uassert.Equal(t, c.ok, ok, c.in)
		uassert.Equal(t, c.base, b, c.in)
		uassert.Equal(t, c.n, n, c.in)
	}

	page := Render("realm/" + base + "/v2")
	uassert.True(t, strings.Contains(page, "## Versions"))
	uassert.True(t, strings.Contains(page, "B01 resolved, B05 no longer detected"), page)
	uassert.True(t, strings.Contains(page, "B03 new"))
	uassert.True(t, strings.Contains(page, "(this page)"))
	uassert.True(t, strings.Contains(page, "first version scanned"))
}

func TestPassportFindings(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	p := "gno.land/r/demo/pf/v1"
	attest(cur, p, hash("c"), "B01,high,PROVEN,vault.gno,69,Ledger;B05,critical,NOT REPRODUCED,vault.gno,35,Deposit;B09,high,STATIC WARNING,pay.gno,12;B42,medium,STATIC WARNING,x.gno,1", 0)
	a, _ := Latest(p)
	testing.SetRealm(testing.NewUserRealm(botAddr))
	AddDetail(cross(cur), p, a.ID, 0, snippet, "inserted a ledger entry with Set [x](javascript:alert(1))", exploit+"\n```\n# injected", "| alice | 5 |", "| alice | 5 |\n| bouncer-probe | 5 |")

	page := Render("realm/" + p)
	uassert.True(t, strings.Contains(page, "| 1 | B01 | high | **PROVEN** | `vault.gno:69 in Ledger()` |"), page)
	uassert.True(t, strings.Contains(page, "### 1. B01: Getter returns a pointer into state"))
	uassert.True(t, strings.Contains(page, "**What it means.**"))
	uassert.True(t, strings.Contains(page, "**Why it is dangerous.**"))
	uassert.True(t, strings.Contains(page, "```go\n"+snippet+"\n```"))
	uassert.True(t, strings.Contains(page, "**Fix.**"))
	uassert.True(t, strings.Contains(page, "func Balances() []Entry"))
	uassert.True(t, strings.Contains(page, "**Why it works.**"))
	uassert.True(t, strings.Contains(page, "**Proof.** Bouncer wrote an attacker realm"))
	uassert.True(t, strings.Contains(page, "<gno-columns>"))
	uassert.True(t, strings.Contains(page, "<gno-columns-sep />"))
	uassert.True(t, strings.Contains(page, "| bouncer-probe | 5 |"))
	// The exploit cannot break out of its code block.
	uassert.True(t, strings.Contains(page, "````go\n"+exploit+"\n```\n# injected\n````"), page)
	uassert.False(t, strings.Contains(page, "](javascript:"), page)
	// Labels explained without claiming safety.
	uassert.True(t, strings.Contains(page, "**Not reproduced.** Bouncer's generated exploit did not land. This stays a warning: it is not evidence that the code is safe."))
	uassert.True(t, strings.Contains(page, "**Static warning.**"))
	uassert.True(t, strings.Contains(page, "### 4. B42: see the full report"))
	uassert.False(t, strings.Contains(page, "## Versions")) // only one version
}

func TestBadge(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	p := "gno.land/r/demo/bv/v1"
	uassert.True(t, strings.HasPrefix(Badge(p), "[![Bouncer: not scanned](data:image/svg+xml;base64,"))
	uassert.Equal(t, "", Badge("not a path"))

	attest(cur, p, hash("c"), "B01,high,PROVEN,vault.gno,69", 0)
	got := Badge(p)
	uassert.True(t, strings.HasPrefix(got, "[![Bouncer: grade B, score 75, not recommended for integration](data:image/svg+xml;base64,"), got)
	uassert.True(t, strings.HasSuffix(got, ":realm/"+p+")"), got)
	uassert.True(t, strings.Contains(Render("realm/"+p), got), "badge on page")
	uassert.True(t, strings.Contains(Render("realm/"+p), `out += bouncer.Badge("`+p+`")`), "snippet")

	attest(cur, p, hash("d"), "B01,high,NOT REPRODUCED,vault.gno,69", 0)
	uassert.True(t, strings.Contains(Badge(p), "score 90, review before integration"), Badge(p)[:120])
	attest(cur, p, hash("e"), "", 0)
	uassert.True(t, strings.Contains(Badge(p), "score 100, no known Critical or High issues"))
}

func TestBotReads(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	uassert.Equal(t, "", OpenRequestsText(10))
	testing.SetRealm(testing.NewUserRealm(alice))
	RequestScan(cross(cur), "gno.land/r/demo/a")
	testing.SetRealm(testing.NewUserRealm(bob))
	RequestScan(cross(cur), "gno.land/r/demo/b")
	uassert.Equal(t, "1 gno.land/r/demo/a\n2 gno.land/r/demo/b\n", OpenRequestsText(10))
	uassert.Equal(t, "1 gno.land/r/demo/a\n", OpenRequestsText(1))

	uassert.Equal(t, "", LatestHashes("gno.land/r/demo/a"))
	attest(cur, "gno.land/r/demo/a", hash("c"), "B01,high,PROVEN,My-Vault.gno,3", 0)
	uassert.Equal(t, hash("a")+" "+hash("b"), LatestHashes("gno.land/r/demo/a"))
	uassert.Equal(t, "2 gno.land/r/demo/b\n", OpenRequestsText(10)) // attest closed request 1
}
