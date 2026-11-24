package bouncer

import (
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	adminAddr = testutils.TestAddress("admin")
	botAddr   = testutils.TestAddress("bot")
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
)

// reset gives each test fresh state with a known admin.
func reset() {
	admin = adminAddr
	attesters = avl.NewTree()
	attesters.Set(string(adminAddr), true)
	requests = avl.NewTree()
	openByRequester = avl.NewTree()
	openRequests = avl.NewTree()
	records = avl.NewTree()
	byAuthor = avl.NewTree()
	disputes = avl.NewTree()
	recent = nil
	totalFindings, totalProven = 0, 0
}

// testing.SetRealm applies to the frame that calls it, so it is called
// inline right before each crossing call, never from a helper.

func hash(c string) string { return strings.Repeat(c, 64) }

// attest posts an attestation as the bot (which must be an attester).
func attest(cur realm, pkgpath, report, findings string, unverified int) {
	testing.SetRealm(testing.NewUserRealm(botAddr))
	Attest(cross(cur), pkgpath, hash("a"), "0.1.0", hash("b"), "master.1+f0f9c70", report, "ipfs://bafyexample", findings, 0, 0, unverified)
}

func addBot(cur realm) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	AddAttester(cross(cur), botAddr)
}

func TestScoreFormula(t *testing.T) {
	f := func(rule, sev, label string) Finding {
		return Finding{Rule: rule, Severity: sev, Label: label, File: "a.gno", Line: 1}
	}
	cases := []struct {
		name    string
		fs      []Finding
		deps    Deps
		score   int
		grade   string
		verdict string
	}{
		{"clean", nil, Deps{}, 100, "A", VerdictClear},
		{"proven critical", []Finding{f("B05", SeverityCritical, LabelProven)}, Deps{}, 60, "C", VerdictNotRecommended},
		{"proven high", []Finding{f("B01", SeverityHigh, LabelProven)}, Deps{}, 75, "B", VerdictNotRecommended},
		{"high warning", []Finding{f("B01", SeverityHigh, LabelNotReproduced)}, Deps{}, 90, "A", VerdictReview},
		{"critical static warning", []Finding{f("B03", SeverityCritical, LabelStaticWarning)}, Deps{}, 85, "B", VerdictReview},
		{"medium only", []Finding{f("B04", SeverityMedium, LabelStaticWarning)}, Deps{}, 95, "A", VerdictClear},
		{"mixed with deps", []Finding{
			f("B05", SeverityCritical, LabelProven),      // 40
			f("B01", SeverityHigh, LabelNotReproduced),   // 10
			f("B04", SeverityMedium, LabelStaticWarning), // 5
		}, Deps{DirectAtRisk: 1, IndirectAtRisk: 1, Unverified: 1}, 28, "F", VerdictNotRecommended}, // 100-55-10-5-2
		{"unverified capped at 10", nil, Deps{Unverified: 7}, 90, "A", VerdictClear},
		{"floor at zero", []Finding{
			f("B05", SeverityCritical, LabelProven),
			f("B05", SeverityCritical, LabelProven),
			f("B05", SeverityCritical, LabelProven),
		}, Deps{}, 0, "F", VerdictNotRecommended},
		{"grade D", []Finding{f("B01", SeverityHigh, LabelProven), f("B01", SeverityHigh, LabelProven), f("B04", SeverityMedium, LabelStaticWarning)}, Deps{}, 45, "D", VerdictNotRecommended},
	}
	for _, c := range cases {
		score, grade, verdict := ScoreFor(c.fs, c.deps)
		if score != c.score || grade != c.grade || verdict != c.verdict {
			t.Errorf("%s: got %d %s %s, want %d %s %s", c.name, score, grade, verdict, c.score, c.grade, c.verdict)
		}
	}
}

func TestRequestScan(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id1 := RequestScan(cross(cur), "gno.land/r/demo/vault")
	uassert.AbortsWithMessage(t, cur, "you already have an open scan request", func() {
		RequestScan(cross(cur), "gno.land/r/demo/other")
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "invalid package path", func() {
		RequestScan(cross(cur), "gno.land/r/Demo/../x")
	})
	id2 := RequestScan(cross(cur), "gno.land/r/demo/token")

	open := OpenRequests(10)
	urequire.Equal(t, 2, len(open))
	uassert.Equal(t, id1, open[0].ID)
	uassert.Equal(t, id2, open[1].ID)
	uassert.Equal(t, alice, open[0].Requester)
	uassert.Equal(t, 1, len(OpenRequests(1)))

	testing.SetRealm(testing.NewUserRealm(alice))
	CancelRequest(cross(cur))
	r, ok := GetRequest(id1)
	uassert.True(t, ok)
	uassert.Equal(t, "cancelled", r.Status)
	RequestScan(cross(cur), "gno.land/r/demo/other") // allowed again
	uassert.Equal(t, 2, len(OpenRequests(10)))
}

func TestAttest(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	reqID := RequestScan(cross(cur), "gno.land/r/demo/vault")

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "attester only", func() {
		Attest(cross(cur), "gno.land/r/demo/vault", hash("a"), "0.1.0", hash("b"), "x", hash("c"), "ipfs://cid", "", 0, 0, 0)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "admin only", func() { AddAttester(cross(cur), bob) })
	addBot(cur)

	attest(cur, "gno.land/r/demo/vault", hash("c"), "B01,high,PROVEN,vault.gno,64;B05,critical,PROVEN,vault.gno,35", 0)
	a, ok := Latest("gno.land/r/demo/vault")
	urequire.True(t, ok)
	uassert.Equal(t, 35, a.Score) // 100 - 25 - 40
	uassert.Equal(t, "F", a.Grade)
	uassert.Equal(t, VerdictNotRecommended, a.Verdict)
	uassert.Equal(t, botAddr, a.Attester)
	urequire.Equal(t, 2, len(a.Findings))
	uassert.Equal(t, 64, a.Findings[0].Line)

	r, _ := GetRequest(reqID)
	uassert.Equal(t, "attested", r.Status)
	uassert.Equal(t, 0, len(OpenRequests(10)))
	uassert.Equal(t, 2, totalFindings)
	uassert.Equal(t, 2, totalProven)

	// A re-scan replaces the totals for that package.
	attest(cur, "gno.land/r/demo/vault", hash("d"), "", 0)
	uassert.Equal(t, 0, totalFindings)
	uassert.Equal(t, 2, len(History("gno.land/r/demo/vault")))
	s, _ := Score("gno.land/r/demo/vault")
	uassert.Equal(t, 100, s)
}

func TestAttestRejectsBadInput(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	bad := []struct {
		msg                                    string
		pkg, src, report, uri, findings, scanv string
	}{
		{"invalid package path", "vault", hash("a"), hash("c"), "ipfs://x", "", "0.1.0"},
		{"hashes must be 64 lowercase hex characters", "gno.land/r/demo/v", "abc", hash("c"), "ipfs://x", "", "0.1.0"},
		{"hashes must be 64 lowercase hex characters", "gno.land/r/demo/v", hash("A"), hash("c"), "ipfs://x", "", "0.1.0"},
		{"report URI must be ipfs://<cid> or an https:// URL", "gno.land/r/demo/v", hash("a"), hash("c"), "javascript:alert(1)", "", "0.1.0"},
		{"report URI must be ipfs://<cid> or an https:// URL", "gno.land/r/demo/v", hash("a"), hash("c"), "https://x.io/a)b", "", "0.1.0"},
		{"invalid label: SAFE", "gno.land/r/demo/v", hash("a"), hash("c"), "ipfs://x", "B01,high,SAFE,a.gno,1", "0.1.0"},
		{"invalid file name: ../a.gno", "gno.land/r/demo/v", hash("a"), hash("c"), "ipfs://x", "B01,high,PROVEN,../a.gno,1", "0.1.0"},
		{"invalid rule id: X1", "gno.land/r/demo/v", hash("a"), hash("c"), "ipfs://x", "X1,high,PROVEN,a.gno,1", "0.1.0"},
		{"invalid line: 0", "gno.land/r/demo/v", hash("a"), hash("c"), "ipfs://x", "B01,high,PROVEN,a.gno,0", "0.1.0"},
		{"invalid scanner or toolchain version", "gno.land/r/demo/v", hash("a"), hash("c"), "ipfs://x", "", "0.1 0"},
	}
	for _, b := range bad {
		testing.SetRealm(testing.NewUserRealm(botAddr))
		uassert.AbortsWithMessage(t, cur, b.msg, func() {
			Attest(cross(cur), b.pkg, b.src, b.scanv, hash("b"), "gno", b.report, b.uri, b.findings, 0, 0, 0)
		})
	}
	uassert.Equal(t, 0, records.Size())
}

func TestReadsReturnCopies(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	attest(cur, "gno.land/r/demo/vault", hash("c"), "B01,high,PROVEN,vault.gno,64", 0)
	a, _ := Latest("gno.land/r/demo/vault")
	a.Findings[0].Rule = "B99"
	a.Score = 100
	h := History("gno.land/r/demo/vault")
	h[0].Findings[0].Line = 1
	again, _ := Latest("gno.land/r/demo/vault")
	uassert.Equal(t, "B01", again.Findings[0].Rule)
	uassert.Equal(t, 64, again.Findings[0].Line)
	uassert.Equal(t, 75, again.Score)
}

func TestDispute(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	pkg := "gno.land/r/demo/clean"
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "no attestation to dispute", func() { Dispute(cross(cur), pkg, hash("e"), "x") })

	attest(cur, pkg, hash("c"), "", 0)
	uassert.True(t, Check(pkg, Strict()))

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "a dispute needs a report that differs from the attested one", func() {
		Dispute(cross(cur), pkg, hash("c"), "same report")
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	id := Dispute(cross(cur), pkg, hash("e"), "my run finds B01 at vault.gno:12")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "you already have an open dispute on this package", func() {
		Dispute(cross(cur), pkg, hash("f"), "again")
	})
	uassert.False(t, Check(pkg, Strict()))  // open dispute
	uassert.True(t, Check(pkg, Standard())) // Standard tolerates disputes

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "admin or attester only", func() { ResolveDispute(cross(cur), id, "no") })
	testing.SetRealm(testing.NewUserRealm(botAddr))
	ResolveDispute(cross(cur), id, "re-ran with 0.1.1: no B01")
	uassert.True(t, Check(pkg, Strict()))
	ds := DisputesFor(pkg)
	urequire.Equal(t, 1, len(ds))
	uassert.True(t, ds[0].Resolved)
}

func TestReply(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	v1 := "gno.land/r/" + alice.String() + "/vault/v1"
	v2 := "gno.land/r/" + alice.String() + "/vault/v2"
	attest(cur, v1, hash("c"), "B01,high,PROVEN,vault.gno,64", 0)
	uassert.Equal(t, 1, len(ByAuthor(alice)))

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "author only", func() { Reply(cross(cur), v1, "not me", "") })
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "the successor must be in the same address namespace", func() {
		Reply(cross(cur), v1, "moved", "gno.land/r/"+bob.String()+"/vault/v2")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	Reply(cross(cur), v1, "Fixed in v2: getters return copies.", v2)
	rs := Replies(v1)
	urequire.Equal(t, 1, len(rs))
	uassert.Equal(t, v2, rs[0].Successor)

	attest(cur, "gno.land/r/demo/shared", hash("c"), "", 0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only address-namespace packages have a verified author", func() {
		Reply(cross(cur), "gno.land/r/demo/shared", "mine", "")
	})
}

func TestCheckPolicies(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	attest(cur, "gno.land/r/demo/clean", hash("c"), "", 0)
	attest(cur, "gno.land/r/demo/warn", hash("c"), "B01,high,NOT REPRODUCED,a.gno,3", 0)
	attest(cur, "gno.land/r/demo/high", hash("c"), "B01,high,PROVEN,a.gno,3", 0)
	attest(cur, "gno.land/r/demo/crit", hash("c"), "B05,critical,PROVEN,a.gno,3", 0)
	attest(cur, "gno.land/r/demo/deps", hash("c"), "", 1)

	cases := []struct {
		pkg              string
		strict, standard bool
	}{
		{"gno.land/r/demo/clean", true, true},
		{"gno.land/r/demo/warn", true, true},  // 90, warnings only
		{"gno.land/r/demo/high", false, true}, // 75, PROVEN High
		{"gno.land/r/demo/crit", false, false},
		{"gno.land/r/demo/deps", false, true}, // unverified dependency
		{"gno.land/r/demo/unknown", false, false},
	}
	for _, c := range cases {
		uassert.Equal(t, c.strict, Check(c.pkg, Strict()), c.pkg+" strict")
		uassert.Equal(t, c.standard, Check(c.pkg, Standard()), c.pkg+" standard")
	}
	custom := Custom(50).WithProvenCritical()
	uassert.True(t, Check("gno.land/r/demo/crit", custom))
	uassert.False(t, Check("gno.land/r/demo/high", custom)) // PROVEN High not allowed
}

func TestAdminTransfer(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	TransferAdmin(cross(cur), alice)
	uassert.Equal(t, alice, Admin())
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	uassert.AbortsWithMessage(t, cur, "admin only", func() { AddAttester(cross(cur), bob) })
	testing.SetRealm(testing.NewUserRealm(alice))
	AddAttester(cross(cur), bob)
	uassert.True(t, IsAttester(bob))
	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveAttester(cross(cur), bob)
	uassert.False(t, IsAttester(bob))
}

func TestRender(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	v1 := "gno.land/r/" + alice.String() + "/vault/v1"
	attest(cur, v1, hash("c"), "B01,high,PROVEN,vault.gno,64;B05,critical,PROVEN,vault.gno,35", 0)
	attest(cur, v1, hash("d"), "B05,critical,PROVEN,vault.gno,35", 0)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reply(cross(cur), v1, "fixed [x](javascript:alert(1)) <script>alert(1)</script> | col", "gno.land/r/"+alice.String()+"/vault/v2")

	home := Render("")
	uassert.True(t, strings.Contains(home, `<gno-form exec="RequestScan">`))
	uassert.True(t, strings.Contains(home, Disclaimer))
	uassert.True(t, strings.Contains(home, "/bouncer/v0:realm/"+v1))

	page := Render("realm/" + v1)
	uassert.True(t, strings.Contains(page, "## 60 / 100 · Grade C · 🔴 Not recommended for integration"))
	uassert.True(t, strings.Contains(page, Disclaimer))
	uassert.True(t, strings.Contains(page, "| B05 | critical | **PROVEN** |"))
	uassert.True(t, strings.Contains(page, "B01 resolved"))
	uassert.True(t, strings.Contains(page, "https://ipfs.filebase.io/ipfs/bafyexample"))
	uassert.True(t, strings.Contains(page, "The author points to a newer version"))
	// User text is escaped: no live link, no raw HTML.
	uassert.False(t, strings.Contains(page, "](javascript:"))
	uassert.False(t, strings.Contains(page, "<script>"))

	uassert.True(t, strings.Contains(Render("realm/gno.land/r/demo/none"), "has not attested this package yet"))
	uassert.True(t, strings.Contains(Render("realm/not a path"), "not a valid package path"))
	uassert.True(t, strings.Contains(Render("nope"), "# Not found"))
}
