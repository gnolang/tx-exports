package strongbox

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
	dave  = testutils.TestAddress("dave") // not a signer
	payee = testutils.TestAddress("payee")
)

// fund deposits ugnot into a vault as addr, mirroring a real
// `gnokey maketx call -send`: the coins land in the realm account.
func fund(cur realm, addr address, vaultID int, amount int64) {
	testing.SetRealm(testing.NewUserRealm(addr))
	coins := chain.Coins{{Denom, amount}}
	testing.SetOriginSend(coins)
	testing.IssueCoins(chain.PackageAddress("gno.land/r/g1sjzvhjx4u4cnd92yk5g0jv68j3j302f4fwzd0z/strongbox/v1"), coins)
	Deposit(cross(cur), vaultID)
	testing.SetOriginSend(nil)
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf(Denom)
}

func signers(addrs ...address) string {
	s := []string{}
	for _, a := range addrs {
		s = append(s, a.String())
	}
	return strings.Join(s, ",")
}

func TestCreateVault(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Team Tavern", signers(bob, carol, bob), 2)

	v := mustVault(id)
	uassert.Equal(t, "Team Tavern", v.Name)
	uassert.Equal(t, 3, len(v.Signers)) // alice added, duplicate bob dropped
	uassert.True(t, IsSigner(id, alice))
	uassert.True(t, IsSigner(id, bob))
	uassert.False(t, IsSigner(id, dave))
	uassert.Equal(t, 2, VaultThreshold(id))

	uassert.AbortsWithMessage(t, cur, "threshold (4) is higher than the number of signers (3)", func() {
		CreateVault(cross(cur), "x", signers(bob, carol), 4)
	})
	uassert.AbortsWithMessage(t, cur, "threshold must be at least 1", func() {
		CreateVault(cross(cur), "x", "", 0)
	})
	uassert.AbortsWithMessage(t, cur, "invalid signer address: nope", func() {
		CreateVault(cross(cur), "x", "nope", 1)
	})
	uassert.AbortsWithMessage(t, cur, "name is required", func() {
		CreateVault(cross(cur), "  ", "", 1)
	})
}

func TestTwoOfThreePayout(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Prize pot", signers(bob, carol), 2)
	fund(cur, dave, id, 10_000_000) // anyone can deposit
	uassert.Equal(t, int64(10_000_000), VaultBalance(id))

	// A non-signer cannot propose.
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsWithMessage(t, cur, "only signers of this vault can do this", func() {
		Propose(cross(cur), id, dave, 1, "gimme")
	})

	// Alice proposes: 1/2 approvals, nothing sent yet.
	testing.SetRealm(testing.NewUserRealm(alice))
	pid := Propose(cross(cur), id, payee, 4_000_000, "Design work")
	uassert.Equal(t, 1, pid)
	uassert.Equal(t, int64(0), balanceOf(payee))
	uassert.AbortsWithMessage(t, cur, "you already approved this proposal", func() {
		Approve(cross(cur), id, pid)
	})
	uassert.AbortsWithMessage(t, cur, "not enough approvals: 1/2", func() {
		Execute(cross(cur), id, pid)
	})

	// Bob approves: threshold reached, payout sent automatically.
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid)
	uassert.Equal(t, int64(4_000_000), balanceOf(payee))
	uassert.Equal(t, int64(6_000_000), VaultBalance(id))

	v := mustVault(id)
	uassert.Equal(t, "paid", getProposal(v, 1).Status.String())

	// Closed proposals cannot be approved again.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "proposal is already paid", func() {
		Approve(cross(cur), id, pid)
	})
}

func TestShortOfFundsThenExecute(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Small pot", signers(bob), 2)
	fund(cur, alice, id, 1_000_000)

	pid := Propose(cross(cur), id, payee, 3_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid) // approved, but vault is short: stays pending
	uassert.Equal(t, "pending", getProposal(mustVault(id), 1).Status.String())
	uassert.AbortsWithMessage(t, cur, "vault balance too low: has 1 GNOT, needs 3 GNOT", func() {
		Execute(cross(cur), id, pid)
	})

	before := balanceOf(payee)
	fund(cur, carol, id, 2_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Execute(cross(cur), id, pid)
	uassert.Equal(t, before+3_000_000, balanceOf(payee))
	uassert.Equal(t, int64(0), VaultBalance(id))
}

func TestRevokeAndCancel(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Ops", signers(bob, carol), 3)
	fund(cur, alice, id, 5_000_000)

	pid := Propose(cross(cur), id, payee, 1_000_000, "servers")
	testing.SetRealm(testing.NewUserRealm(bob))
	Approve(cross(cur), id, pid)
	Revoke(cross(cur), id, pid)
	uassert.Equal(t, 1, len(getProposal(mustVault(id), 1).Approvals))
	uassert.AbortsWithMessage(t, cur, "you have not approved this proposal", func() {
		Revoke(cross(cur), id, pid)
	})
	uassert.AbortsWithMessage(t, cur, "only the proposer can cancel this proposal", func() {
		Cancel(cross(cur), id, pid)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id, pid)
	uassert.Equal(t, "cancelled", getProposal(mustVault(id), 1).Status.String())
	uassert.Equal(t, int64(5_000_000), VaultBalance(id)) // nothing moved
}

func TestDepositRules(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Deposits", "", 1)

	uassert.AbortsWithMessage(t, cur, "send ugnot with the call (-send 1000000ugnot)", func() {
		Deposit(cross(cur), id)
	})

	testing.SetOriginSend(chain.Coins{{"uatom", 5}})
	uassert.AbortsWithMessage(t, cur, "only ugnot can be deposited", func() {
		Deposit(cross(cur), id)
	})
	testing.SetOriginSend(nil)

	uassert.AbortsWithMessage(t, cur, "vault 999 not found", func() {
		Deposit(cross(cur), 999)
	})
}

func TestOneOfOneSendsImmediately(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Solo", "", 1)
	fund(cur, alice, id, 2_000_000)
	before := balanceOf(payee)

	testing.SetRealm(testing.NewUserRealm(alice))
	Propose(cross(cur), id, payee, 500_000, "")
	uassert.Equal(t, before+500_000, balanceOf(payee))
	uassert.Equal(t, int64(1_500_000), VaultBalance(id))
}

func TestRender(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateVault(cross(cur), "Render *me* [x](y)", signers(bob), 2)
	fund(cur, alice, id, 2_500_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Propose(cross(cur), id, payee, 1_000_000, "pay | the bard")

	home := Render("")
	uassert.True(t, strings.Contains(home, "# Strongbox"))
	uassert.True(t, strings.Contains(home, `Render \*me\* \[x\]\(y\)`), "name must be escaped")

	page := Render("vault/" + itoa(id))
	uassert.True(t, strings.Contains(page, "**Balance: 2.5 GNOT**"))
	uassert.True(t, strings.Contains(page, "**2 of 2**"))
	uassert.True(t, strings.Contains(page, "Approvals: **1/2**"))
	uassert.True(t, strings.Contains(page, `pay \| the bard`))

	mine := Render("signer/" + bob.String())
	uassert.True(t, strings.Contains(mine, "1 waiting for your approval"))

	uassert.True(t, strings.Contains(Render("vault/12345"), "There is no vault 12345"))
	uassert.True(t, strings.Contains(Render("nope"), "# Not found"))
}

func TestFormatGNOT(t *testing.T) {
	uassert.Equal(t, "0 GNOT", formatGNOT(0))
	uassert.Equal(t, "1 GNOT", formatGNOT(1_000_000))
	uassert.Equal(t, "1.5 GNOT", formatGNOT(1_500_000))
	uassert.Equal(t, "0.000001 GNOT", formatGNOT(1))
	uassert.Equal(t, "12.03 GNOT", formatGNOT(12_030_000))
}

func itoa(i int) string {
	return strings.TrimLeft(key(i), "0")
}
