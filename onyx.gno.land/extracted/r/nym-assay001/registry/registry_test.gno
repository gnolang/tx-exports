package registry

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	author    = testutils.TestAddress("author")
	user      = testutils.TestAddress("user")
	intruder  = testutils.TestAddress("intruder")
	testAdmin = testutils.TestAddress("admin")
	realmAddr = chain.PackageAddress("gno.land/r/nym-assay001/registry")
)

// testing.SetRealm applies to the calling frame only, so every test sets the
// acting user inline rather than through a helper. It also sets OriginCaller.

const (
	vaultPath = "gno.land/p/nym-assay001/vault_math"
	trapPath  = "gno.land/p/nym-assay001/malicious_helper"
	vaultSrc  = "package vault_math\n\nfunc SimpleYield(p, bps, n int64) int64 { return p * bps * n / 10000 }\n"
)

// deposit simulates coins attached to a MsgCall: the chain moves them into
// the realm before the call and exposes them through OriginSend.
func deposit(amount int64) {
	coins := chain.Coins{{"ugnot", amount}}
	testing.IssueCoins(realmAddr, coins)
	testing.SetOriginSend(coins)
}

// useTestAdmin installs a known admin. On chain, init() makes the deployer
// the admin, but OriginCaller is empty while a unit test's init runs.
func useTestAdmin() {
	admin = testAdmin
	auditors.Set(testAdmin.String(), true)
}

func ugnot(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf("ugnot")
}

func meta(t *testing.T, path string) *PackageMeta {
	m, ok := packages.Get(path).(*PackageMeta)
	urequire.True(t, ok, "package should be registered: "+path)
	return m
}

func TestRegisterPackage(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(author))
	RegisterPackage(cross(cur), vaultPath, "Fixed-point yield math", vaultSrc, 1000)

	m := meta(t, vaultPath)
	uassert.Equal(t, author.String(), m.Author.String())
	uassert.Equal(t, int64(1000), m.FeePerCall)
	uassert.Equal(t, vaultSrc, m.SourceCode)
	uassert.False(t, m.Verified, "new packages start unverified")
	uassert.Equal(t, uint64(0), m.TotalCalls)

	// Someone else cannot take over the listing.
	testing.SetRealm(testing.NewUserRealm(intruder))
	uassert.AbortsContains(t, cur, "package is owned by", func() {
		RegisterPackage(cross(cur), vaultPath, "hijack", "package x", 1)
	})

	// Input validation.
	uassert.AbortsContains(t, cur, "must start with gno.land/p/", func() {
		RegisterPackage(cross(cur), "github.com/evil/pkg", "", "", 1)
	})
	uassert.AbortsContains(t, cur, "fee must be between", func() {
		RegisterPackage(cross(cur), "gno.land/p/intruder/neg", "", "", -5)
	})
	uassert.AbortsContains(t, cur, "invalid character", func() {
		RegisterPackage(cross(cur), "gno.land/p/Bad Path", "", "", 1)
	})
}

func TestReRegisterClearsVerification(cur realm, t *testing.T) {
	useTestAdmin()
	path := "gno.land/p/nym-assay001/reaudit"
	testing.SetRealm(testing.NewUserRealm(author))
	RegisterPackage(cross(cur), path, "v1", "package reaudit", 10)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetVerified(cross(cur), path, true, "ok")
	uassert.True(t, meta(t, path).Verified)

	testing.SetRealm(testing.NewUserRealm(author))
	RegisterPackage(cross(cur), path, "v2", "package reaudit // changed", 20)
	m := meta(t, path)
	uassert.False(t, m.Verified, "updated source must be re-audited")
	uassert.Equal(t, int64(20), m.FeePerCall)
}

func TestOnlyAuditorsCanVerify(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(intruder))
	uassert.AbortsContains(t, cur, "not an auditor", func() {
		SetVerified(cross(cur), vaultPath, true, "trust me")
	})
	uassert.False(t, meta(t, vaultPath).Verified)

	uassert.AbortsContains(t, cur, "not the admin", func() {
		AddAuditor(cross(cur), intruder)
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetVerified(cross(cur), vaultPath, true, "static audit passed")
	uassert.True(t, meta(t, vaultPath).Verified)
	uassert.True(t, IsAuditor(testAdmin))
	uassert.Equal(t, testAdmin.String(), Admin().String())
	uassert.False(t, IsAuditor(intruder))
}

func TestExecuteRefusesUnverifiedPackage(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(intruder))
	RegisterPackage(cross(cur), trapPath, "Fee rounding helper", "package malicious_helper", 250)

	before := ugnot(intruder)
	testing.SetRealm(testing.NewUserRealm(user))
	deposit(250)
	uassert.AbortsContains(t, cur, "not audit-verified", func() {
		ExecuteAndPay(cross(cur), trapPath, "req-1")
	})
	uassert.Equal(t, before, ugnot(intruder), "trap author must not be paid")
	uassert.Equal(t, uint64(0), meta(t, trapPath).TotalCalls)
}

func TestExecuteRejectsInsufficientFee(cur realm, t *testing.T) {
	before := ugnot(author)
	calls := meta(t, vaultPath).TotalCalls

	testing.SetRealm(testing.NewUserRealm(user))
	deposit(999)
	uassert.AbortsContains(t, cur, "insufficient fee: sent 999ugnot, required 1000ugnot", func() {
		ExecuteAndPay(cross(cur), vaultPath, "req-2")
	})
	uassert.Equal(t, before, ugnot(author), "author must not be paid on a rejected call")
	uassert.Equal(t, calls, meta(t, vaultPath).TotalCalls)

	uassert.AbortsContains(t, cur, "package not registered", func() {
		ExecuteAndPay(cross(cur), "gno.land/p/nobody/missing", "req-3")
	})
}

func TestExecuteAndPaySettlesAtomically(cur realm, t *testing.T) {
	authorBefore := ugnot(author)
	userBefore := ugnot(user)
	realmBefore := ugnot(realmAddr)
	receiptsBefore := ReceiptCount()

	testing.SetRealm(testing.NewUserRealm(user))
	deposit(1500) // 1000 fee + 500 over-payment
	id := ExecuteAndPay(cross(cur), vaultPath, "req-4")

	uassert.Equal(t, receiptsBefore+1, id)
	uassert.Equal(t, authorBefore+1000, ugnot(author), "author receives exactly the fee")
	uassert.Equal(t, userBefore+500, ugnot(user), "caller is refunded the excess")
	uassert.Equal(t, realmBefore+1500-1500, ugnot(realmAddr), "escrow keeps nothing")

	m := meta(t, vaultPath)
	uassert.Equal(t, uint64(1), m.TotalCalls)
	uassert.Equal(t, int64(1000), m.TotalEarned)

	r, ok := receipts.Get(receiptKey(id)).(*Receipt)
	urequire.True(t, ok, "receipt should be stored")
	uassert.Equal(t, vaultPath, r.PkgPath)
	uassert.Equal(t, user.String(), r.Caller.String())
	uassert.Equal(t, author.String(), r.Author.String())
	uassert.Equal(t, int64(1000), r.Fee)
	uassert.Equal(t, int64(500), r.Refund)

	// Exact payment: no refund leg.
	deposit(1000)
	id2 := ExecuteAndPay(cross(cur), vaultPath, "req-5")
	uassert.Equal(t, id+1, id2)
	uassert.Equal(t, authorBefore+2000, ugnot(author))
	uassert.Equal(t, int64(2000), meta(t, vaultPath).TotalEarned)
}

// An intermediary frame between the signer and the realm must not be able to
// spend the signer's deposit, even for a fully valid, paid call.
func TestRejectsNonOriginCall(cur realm, t *testing.T) {
	before := ugnot(author)
	calls := meta(t, vaultPath).TotalCalls
	testing.SetRealm(testing.NewUserRealm(user))
	deposit(1000)
	uassert.AbortsContains(t, cur, "invalid non-origin call", func() {
		ExecuteAndPay(cross(cur), vaultPath, "req-6")
	})
	uassert.Equal(t, before, ugnot(author))
	uassert.Equal(t, calls, meta(t, vaultPath).TotalCalls)
}

// Retrying a settled request must not charge twice. The refusal reverts the
// transaction, so on chain the second deposit goes back to the caller.
func TestDuplicateRequestIsRefused(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(user))
	deposit(1000)
	first := ExecuteAndPay(cross(cur), vaultPath, "retry-me")
	uassert.Equal(t, first, ReceiptFor(user, "retry-me"))

	authorAfterFirst := ugnot(author)
	calls := meta(t, vaultPath).TotalCalls
	deposit(1000)
	uassert.AbortsContains(t, cur, "duplicate request; already settled as receipt #"+strconv.FormatUint(first, 10), func() {
		ExecuteAndPay(cross(cur), vaultPath, "retry-me")
	})
	uassert.Equal(t, authorAfterFirst, ugnot(author), "author is not paid twice")
	uassert.Equal(t, calls, meta(t, vaultPath).TotalCalls)

	// The same id from a different caller is a different request.
	testing.SetRealm(testing.NewUserRealm(intruder))
	deposit(1000)
	other := ExecuteAndPay(cross(cur), vaultPath, "retry-me")
	uassert.Equal(t, first+1, other)
	uassert.Equal(t, uint64(0), ReceiptFor(author, "retry-me"))
}

func TestRequestIDBounds(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(user))
	deposit(1000)
	uassert.AbortsContains(t, cur, "request id must be 1 to 64 bytes", func() {
		ExecuteAndPay(cross(cur), vaultPath, "")
	})
	uassert.AbortsContains(t, cur, "request id must be 1 to 64 bytes", func() {
		ExecuteAndPay(cross(cur), vaultPath, strings.Repeat("x", 65))
	})
	// Exactly 64 bytes is accepted.
	id := ExecuteAndPay(cross(cur), vaultPath, strings.Repeat("x", 64))
	uassert.True(t, id > 0)
}

// Repeated distinct calls each settle and are accounted separately, and the
// escrow never keeps a coin.
func TestRepeatedCallsAccounting(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(user))
	authorBefore := ugnot(author)
	realmBefore := ugnot(realmAddr)
	calls := meta(t, vaultPath).TotalCalls
	earned := meta(t, vaultPath).TotalEarned
	for i := 0; i < 3; i++ {
		deposit(1000)
		ExecuteAndPay(cross(cur), vaultPath, "loop-"+strconv.Itoa(i))
	}
	uassert.Equal(t, authorBefore+3000, ugnot(author))
	uassert.Equal(t, realmBefore, ugnot(realmAddr), "escrow holds nothing between calls")
	uassert.Equal(t, calls+3, meta(t, vaultPath).TotalCalls)
	uassert.Equal(t, earned+3000, meta(t, vaultPath).TotalEarned)
}

// A free package settles with no payout leg and refunds anything sent.
func TestZeroFeePackage(cur realm, t *testing.T) {
	free := "gno.land/p/nym-assay001/free"
	testing.SetRealm(testing.NewUserRealm(author))
	RegisterPackage(cross(cur), free, "free", "package free", 0)
	useTestAdmin()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetVerified(cross(cur), free, true, "ok")

	testing.SetRealm(testing.NewUserRealm(user))
	userBefore := ugnot(user)
	authorBefore := ugnot(author)
	deposit(300)
	id := ExecuteAndPay(cross(cur), free, "free-1")
	r := receipts.Get(receiptKey(id)).(*Receipt)
	uassert.Equal(t, int64(0), r.Fee)
	uassert.Equal(t, int64(300), r.Refund)
	uassert.Equal(t, userBefore+300, ugnot(user))
	uassert.Equal(t, authorBefore, ugnot(author))
}

func TestRegistrationBoundaries(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(author))
	// Largest allowed fee, description and source are accepted.
	RegisterPackage(cross(cur), "gno.land/p/nym-assay001/edge", strings.Repeat("d", 280), strings.Repeat("s", 64*1024), 1_000_000_000)
	uassert.Equal(t, int64(1_000_000_000), meta(t, "gno.land/p/nym-assay001/edge").FeePerCall)
	// One past each limit is refused.
	uassert.AbortsContains(t, cur, "fee must be between", func() {
		RegisterPackage(cross(cur), "gno.land/p/nym-assay001/edge2", "", "", 1_000_000_001)
	})
	uassert.AbortsContains(t, cur, "description longer than 280 bytes", func() {
		RegisterPackage(cross(cur), "gno.land/p/nym-assay001/edge2", strings.Repeat("d", 281), "", 1)
	})
	uassert.AbortsContains(t, cur, "source longer than 65536 bytes", func() {
		RegisterPackage(cross(cur), "gno.land/p/nym-assay001/edge2", "", strings.Repeat("s", 64*1024+1), 1)
	})
	uassert.AbortsContains(t, cur, "invalid package path length", func() {
		RegisterPackage(cross(cur), "gno.land/p/"+strings.Repeat("a", 250), "", "", 1)
	})
	useTestAdmin()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	uassert.AbortsContains(t, cur, "package not registered", func() {
		SetVerified(cross(cur), "gno.land/p/nobody/missing", true, "")
	})
}

func TestAdminLifecycle(cur realm, t *testing.T) {
	useTestAdmin()
	newAuditor := testutils.TestAddress("auditor2")
	newAdmin := testutils.TestAddress("admin2")
	path := "gno.land/p/nym-assay001/lifecycle"
	testing.SetRealm(testing.NewUserRealm(author))
	RegisterPackage(cross(cur), path, "", "package lifecycle", 1)

	// Admin grants audit rights; the new auditor can verify.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AddAuditor(cross(cur), newAuditor)
	testing.SetRealm(testing.NewUserRealm(newAuditor))
	SetVerified(cross(cur), path, true, "ok")
	uassert.True(t, meta(t, path).Verified)

	// Revoked auditors lose the right immediately.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	RemoveAuditor(cross(cur), newAuditor)
	testing.SetRealm(testing.NewUserRealm(newAuditor))
	uassert.AbortsContains(t, cur, "not an auditor", func() {
		SetVerified(cross(cur), path, false, "")
	})

	// Admin hand-over: the old admin can no longer manage auditors.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	uassert.AbortsContains(t, cur, "invalid admin address", func() {
		TransferAdmin(cross(cur), address("not-an-address"))
	})
	TransferAdmin(cross(cur), newAdmin)
	uassert.Equal(t, newAdmin.String(), Admin().String())
	uassert.AbortsContains(t, cur, "not the admin", func() {
		AddAuditor(cross(cur), newAuditor)
	})
	testing.SetRealm(testing.NewUserRealm(newAdmin))
	AddAuditor(cross(cur), newAuditor)
	uassert.True(t, IsAuditor(newAuditor))
}

func TestRejectsForeignDenom(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(user))
	coins := chain.Coins{{"foo", 5000}}
	testing.IssueCoins(realmAddr, coins)
	testing.SetOriginSend(coins)
	uassert.AbortsContains(t, cur, "only ugnot is accepted", func() {
		ExecuteAndPay(cross(cur), vaultPath, "req-7")
	})
}

func TestRender(cur realm, t *testing.T) {
	home := Render("")
	uassert.True(t, strings.HasPrefix(home, "# Assay Registry"))
	uassert.True(t, strings.Contains(home, "## Leaderboard"))
	uassert.True(t, strings.Contains(home, "[gno.land/p/nym-assay001/vault_math](/r/nym-assay001/registry:pkg/gno.land/p/nym-assay001/vault_math)"))
	uassert.True(t, strings.Contains(home, "● verified"))
	uassert.True(t, strings.Contains(home, "○ unverified"))
	uassert.True(t, strings.Contains(home, "## Recent receipts"))

	// vault_math has the highest earnings, so it ranks first.
	uassert.True(t, strings.Contains(home, "| 1 | [gno.land/p/nym-assay001/vault_math]"))

	pkg := Render("pkg/" + vaultPath)
	uassert.True(t, strings.Contains(pkg, "- fee per call: 1000 ugnot"))
	uassert.True(t, strings.Contains(pkg, "- calls: "+strconv.FormatUint(meta(t, vaultPath).TotalCalls, 10)))
	uassert.True(t, strings.Contains(pkg, "```go\n"+vaultSrc))

	rc := Render("receipt/1")
	uassert.True(t, strings.HasPrefix(rc, "# Receipt #1"))
	uassert.True(t, strings.Contains(rc, "- refund: 500 ugnot"))

	api := Render("api/packages")
	uassert.True(t, strings.HasPrefix(api, "[{"))
	uassert.True(t, strings.Contains(api, `"path":"gno.land/p/nym-assay001/vault_math"`))
	uassert.True(t, strings.Contains(api, `"verified":true`))
	uassert.False(t, strings.Contains(api, `"sourceCode"`), "list endpoint omits source")

	one := Render("api/package/" + vaultPath)
	uassert.True(t, strings.Contains(one, `"sourceCode":"package vault_math\n\nfunc SimpleYield`))

	uassert.Equal(t, "404", Render("nope"))
	uassert.Equal(t, "404", Render("pkg/gno.land/p/none"))
	uassert.Equal(t, "404", Render("receipt/abc"))
	uassert.Equal(t, "null", Render("api/package/gno.land/p/none"))
}

func TestJSONEscaping(t *testing.T) {
	uassert.Equal(t, `"a\"b\\c\nd\u0001"`, jsonString("a\"b\\c\nd\x01"))
}
