package strongbox

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// A vault can only spend its own balance, even when the realm holds more
// coins from other vaults.
func TestVaultsAreIsolated(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	poor := CreateVault(cross(cur), "Poor", "", 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	rich := CreateVault(cross(cur), "Rich", "", 1)
	fund(cur, alice, poor, 1_000_000)
	fund(cur, bob, rich, 50_000_000)

	before := balanceOf(payee)
	testing.SetRealm(testing.NewUserRealm(alice))
	pid := Propose(cross(cur), poor, payee, 5_000_000, "more than Poor has")
	uassert.Equal(t, before, balanceOf(payee), "nothing may be paid from another vault's funds")
	uassert.Equal(t, "pending", getProposal(mustVault(poor), pid).Status.String())
	uassert.AbortsWithMessage(t, cur, "vault balance too low: has 1 GNOT, needs 5 GNOT", func() {
		Execute(cross(cur), poor, pid)
	})
	uassert.Equal(t, int64(50_000_000), VaultBalance(rich))

	// Bob signs Rich, not Poor: he cannot approve or execute in Poor.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "only signers of this vault can do this", func() {
		Approve(cross(cur), poor, pid)
	})
	uassert.AbortsWithMessage(t, cur, "only signers of this vault can do this", func() {
		Execute(cross(cur), poor, pid)
	})
}

// Another realm sitting between the user and Deposit could call it several
// times in one transaction and count the same coins more than once.
func TestDepositThroughAnotherRealmIsRejected(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "MITM target", "", 1)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/mitm"))
	testing.SetOriginSend(chain.Coins{{Denom, 1_000_000}})
	uassert.AbortsWithMessage(t, cur, "Deposit must be called directly with gnokey maketx call -send", func() {
		Deposit(cross(cur), id)
	})
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(0), VaultBalance(id))
}

// A DAO or another realm can be a signer: it approves through its own code.
func TestRealmCanBeSigner(cur realm, t *testing.T) {
	daoPath := "gno.land/r/team/dao"
	dao := chain.PackageAddress(daoPath)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "DAO co-signed", dao.String(), 2)
	fund(cur, alice, id, 3_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	pid := Propose(cross(cur), id, payee, 1_000_000, "")

	before := balanceOf(payee)
	testing.SetRealm(testing.NewCodeRealm(daoPath))
	Approve(cross(cur), id, pid)
	uassert.Equal(t, before+1_000_000, balanceOf(payee))
}

func TestNoDoublePayout(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Once", signers(bob), 2)
	fund(cur, alice, id, 5_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	pid := Propose(cross(cur), id, payee, 2_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid)

	uassert.AbortsWithMessage(t, cur, "proposal is already paid", func() { Execute(cross(cur), id, pid) })
	uassert.AbortsWithMessage(t, cur, "proposal is already paid", func() { Revoke(cross(cur), id, pid) })
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "proposal is already paid", func() { Cancel(cross(cur), id, pid) })
	uassert.Equal(t, int64(3_000_000), VaultBalance(id))
}

// After a revoke the proposal needs a fresh approval before it pays.
func TestRevokeThenReapprove(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Flip-flop", signers(bob, carol), 3)
	fund(cur, alice, id, 5_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	pid := Propose(cross(cur), id, payee, 1_000_000, "")
	before := balanceOf(payee)

	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid)
	Revoke(cross(cur), id, pid)
	testing.SetRealm(testing.NewUserRealm(carol))
	Approve(cross(cur), id, pid) // 2/3: alice + carol
	uassert.Equal(t, before, balanceOf(payee))
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid) // 3/3
	uassert.Equal(t, before+1_000_000, balanceOf(payee))
}

func TestInputLimits(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))

	// Up to 20 signers, the caller included.
	many := []address{}
	for i := 0; i < 19; i++ {
		many = append(many, testutils.TestAddress("signer"+strconv.Itoa(i)))
	}
	id := CreateVault(cross(cur), "Twenty", signers(many...), 20)
	uassert.Equal(t, 20, len(mustVault(id).Signers))
	many = append(many, testutils.TestAddress("one too many"))
	uassert.AbortsWithMessage(t, cur, "too many signers (max 20)", func() {
		CreateVault(cross(cur), "Twenty-one", signers(many...), 2)
	})

	uassert.AbortsWithMessage(t, cur, "name is too long (max 64 bytes)", func() {
		CreateVault(cross(cur), strings.Repeat("n", 65), "", 1)
	})

	id = CreateVault(cross(cur), "Limits", "", 1)
	uassert.AbortsWithMessage(t, cur, "amount must be positive", func() {
		Propose(cross(cur), id, payee, 0, "")
	})
	uassert.AbortsWithMessage(t, cur, "amount must be positive", func() {
		Propose(cross(cur), id, payee, -5, "")
	})
	uassert.AbortsWithMessage(t, cur, "invalid recipient address", func() {
		Propose(cross(cur), id, address("g1notanaddress"), 1, "")
	})
	uassert.AbortsWithMessage(t, cur, "cannot pay out to the Strongbox realm itself", func() {
		Propose(cross(cur), id, chain.PackageAddress("gno.land/r/g1sjzvhjx4u4cnd92yk5g0jv68j3j302f4fwzd0z/strongbox/v1"), 1, "")
	})
	uassert.AbortsWithMessage(t, cur, "memo is too long (max 280 bytes)", func() {
		Propose(cross(cur), id, payee, 1, strings.Repeat("m", 281))
	})
	uassert.AbortsWithMessage(t, cur, "proposal 0 not found", func() { Approve(cross(cur), id, 0) })
	uassert.AbortsWithMessage(t, cur, "proposal 7 not found", func() { Approve(cross(cur), id, 7) })
	uassert.AbortsWithMessage(t, cur, "vault 0 not found", func() { Approve(cross(cur), 0, 1) })
}

// Markdown or HTML in names and memos must not break or hijack the page.
func TestRenderInjection(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "<script>alert(1)</script>", "", 2-1)
	uassert.AbortsWithMessage(t, cur, "memo contains control or invisible characters", func() {
		Propose(cross(cur), id, payee, 1, "line1\n# Fake heading")
	})
	pid := Propose(cross(cur), id, payee, 1, "# Fake heading [click](https://evil.example) | x")
	uassert.Equal(t, 1, pid)

	page := Render("vault/" + strconv.Itoa(id))
	uassert.False(t, strings.Contains(page, "<script>"), "raw HTML must be escaped")
	uassert.False(t, strings.Contains(page, "> # Fake heading"), "memo must not start a heading")
	uassert.False(t, strings.Contains(page, "[click](https://evil.example)"), "memo must not make a live link")
}

// The pages must stay cheap enough to render with many vaults and proposals.
func TestRenderUnderLoad(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	for i := 0; i < 50; i++ {
		CreateVault(cross(cur), "Load "+strconv.Itoa(i), signers(bob), 2)
	}
	id := CreateVault(cross(cur), "Busy", signers(bob, carol), 3)
	n := 0
	for i := 0; i < MaxOpenPerProposer; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		Propose(cross(cur), id, payee, 1_000_000, "invoice "+strconv.Itoa(n))
		n++
		testing.SetRealm(testing.NewUserRealm(bob))
		Propose(cross(cur), id, payee, 1_000_000, "invoice "+strconv.Itoa(n))
		n++
	}
	uassert.True(t, strings.Contains(Render(""), "Load 49"))
	page := Render("vault/" + strconv.Itoa(id))
	uassert.True(t, strings.Contains(page, "invoice 39"), "newest proposal is listed")
	uassert.False(t, strings.Contains(page, "invoice 0\n"), "oldest proposal is not listed")
	uassert.True(t, strings.Contains(page, "…and 15 older pending proposals not shown."))
	uassert.True(t, strings.Contains(Render("signer/"+carol.String()), "25+ waiting for your approval"))
}

// One signer cannot flood a vault with open proposals.
func TestOpenProposalCap(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Capped", signers(bob), 2)
	for i := 0; i < MaxOpenPerProposer; i++ {
		Propose(cross(cur), id, payee, 1, "")
	}
	uassert.AbortsWithMessage(t, cur, "you already have 20 open proposals in this vault; cancel or finish some first", func() {
		Propose(cross(cur), id, payee, 1, "")
	})
	// Bob has his own quota.
	testing.SetRealm(testing.NewUserRealm(bob))
	Propose(cross(cur), id, payee, 1, "")
	// Cancelling frees a slot.
	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id, 1)
	Propose(cross(cur), id, payee, 1, "")
	uassert.Equal(t, MaxOpenPerProposer+1, len(mustVault(id).Pending))
}

// Coins sent with anything but Deposit would be lost: the call is refused,
// which reverts the transaction and returns them.
func TestCoinsOnlyWithDeposit(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "No stray coins", "", 1)
	coins := chain.Coins{{Denom, 1_000_000}}
	msg := "do not send coins with this call; use Deposit to fund a vault"

	testing.SetOriginSend(coins)
	uassert.AbortsWithMessage(t, cur, msg, func() { CreateVault(cross(cur), "x", "", 1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Propose(cross(cur), id, payee, 1, "") })
	uassert.AbortsWithMessage(t, cur, msg, func() { Approve(cross(cur), id, 1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Revoke(cross(cur), id, 1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Execute(cross(cur), id, 1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Cancel(cross(cur), id, 1) })
	testing.SetOriginSend(nil)
}

// Counters behind the pages stay right through payouts and cancels.
func TestCounters(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Counted", signers(bob), 2)
	fund(cur, alice, id, 10_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	p1 := Propose(cross(cur), id, payee, 3_000_000, "")
	p2 := Propose(cross(cur), id, payee, 2_000_000, "")
	Propose(cross(cur), id, payee, 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, p1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id, p2)

	v := mustVault(id)
	uassert.Equal(t, int64(3_000_000), v.PaidTotal)
	uassert.Equal(t, 1, len(v.Pending))
	uassert.Equal(t, 3, v.Pending[0])
	uassert.True(t, strings.Contains(Render(""), "| 2-of-2 | 7 GNOT | 1 | 3 GNOT |"))
}

// The signer page must not echo arbitrary text from the URL.
func TestSignerPageRejectsJunk(cur realm, t *testing.T) {
	page := Render("signer/[Claim airdrop](https:evil.example)")
	uassert.True(t, strings.Contains(page, "That is not a valid address."))
	uassert.False(t, strings.Contains(page, "Claim airdrop"))
}

func TestHugeIdsDoNotCrash(cur realm, t *testing.T) {
	uassert.True(t, strings.Contains(Render("vault/99999999999999"), "There is no vault"))
	uassert.True(t, strings.Contains(Render("vault/-3"), "There is no vault"))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "vault 99999999999999 not found", func() { Approve(cross(cur), 99999999999999, 1) })
}

// Invisible or direction-flipping characters could disguise a name or memo.
func TestRejectsDeceptiveText(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "name contains control or invisible characters", func() {
		CreateVault(cross(cur), "Team\u202Eeman", "", 1)
	})
	uassert.AbortsWithMessage(t, cur, "name contains control or invisible characters", func() {
		CreateVault(cross(cur), "Te\u200Bam", "", 1)
	})
	id := CreateVault(cross(cur), "Équipe 🍺 ok", "", 1) // normal Unicode is fine
	uassert.AbortsWithMessage(t, cur, "memo contains control or invisible characters", func() {
		Propose(cross(cur), id, payee, 1, "pay\x00alice")
	})
}

// The per-proposer open count follows payouts and cancels.
func TestOpenCountReleases(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Recycle", signers(bob), 2)
	fund(cur, alice, id, 100_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	for i := 0; i < MaxOpenPerProposer; i++ {
		Propose(cross(cur), id, payee, 1, "")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, 1) // paid: frees one of alice's slots
	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id, 2) // cancelled: frees another
	Propose(cross(cur), id, payee, 1, "")
	Propose(cross(cur), id, payee, 1, "")
	uassert.AbortsWithMessage(t, cur, "you already have 20 open proposals in this vault; cancel or finish some first", func() {
		Propose(cross(cur), id, payee, 1, "")
	})
}

// Bech32 also accepts all-uppercase addresses. They must count as the same
// signer, or the real owner could never approve.
func TestUppercaseAddresses(cur realm, t *testing.T) {
	up := address(strings.ToUpper(bob.String()))
	uassert.True(t, up.IsValid())

	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Caps", up.String()+","+bob.String(), 2)
	uassert.Equal(t, 2, len(mustVault(id).Signers), "uppercase and lowercase bob are one signer")
	uassert.True(t, IsSigner(id, bob))
	uassert.True(t, IsSigner(id, up), "read helper normalizes too")
	fund(cur, alice, id, 2_000_000)

	before := balanceOf(payee)
	testing.SetRealm(testing.NewUserRealm(alice))
	pid := Propose(cross(cur), id, address(strings.ToUpper(payee.String())), 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid)
	uassert.Equal(t, before+1_000_000, balanceOf(payee))

	uassert.True(t, strings.Contains(Render("signer/"+strings.ToUpper(bob.String())), "Caps"))
}

func TestStaleApprovalWarning(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Stale", signers(bob), 2)
	pid := Propose(cross(cur), id, payee, 5_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid)
	uassert.True(t, strings.Contains(Render("vault/"+strconv.Itoa(id)), "Any signer can [execute]"))
}

func TestRealmCannotBeItsOwnSigner(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	self := chain.PackageAddress("gno.land/r/g1sjzvhjx4u4cnd92yk5g0jv68j3j302f4fwzd0z/strongbox/v1")
	uassert.AbortsWithMessage(t, cur, "the Strongbox realm cannot be a signer", func() {
		CreateVault(cross(cur), "Self", self.String(), 2)
	})
}

// A realm the user calls acts as itself, never as the user: if it calls
// Approve, the approval is checked against the realm's own address.
func TestRealmCannotApproveForUser(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Impersonation", signers(bob), 2)
	pid := Propose(cross(cur), id, payee, 1, "")

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/proxy"))
	uassert.AbortsWithMessage(t, cur, "only signers of this vault can do this", func() {
		Approve(cross(cur), id, pid)
	})
	uassert.Equal(t, 1, len(getProposal(mustVault(id), pid).Approvals))
}
