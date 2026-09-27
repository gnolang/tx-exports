package upgrade_registry

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// In production the registrant is usually a realm; user addresses give
// the same self-registration semantics in tests (Register binds the
// entry to the CALLER's address either way).
var (
	v1       = testutils.TestAddress("contract_v1")
	v2       = testutils.TestAddress("contract_v2")
	v3       = testutils.TestAddress("contract_v3")
	teamEOA  = testutils.TestAddress("team")
	attacker = testutils.TestAddress("attacker")
)

// resetState resets all package-level state between tests.
func resetState() {
	entries = make(map[address]*ContractEntry)
	entryAddrs = []address{}
	ownerContracts = make(map[address][]address)
}

// register self-registers addr under name; when owner is non-empty the
// nominee accepts, completing the two-step handover.
func register(cur realm, addr address, name string, owner address) {
	testing.SetRealm(testing.NewUserRealm(addr))
	Register(cross(cur), name, owner)
	if owner != "" && owner != addr {
		testing.SetRealm(testing.NewUserRealm(owner))
		AcceptOwnership(cross(cur), addr)
	}
}

// ---------- Register (proof of control) ----------

func TestRegister_BindsToCallerAddress(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)

	e := entries[v1]
	uassert.Equal(t, string(v1), string(e.Address))
	uassert.Equal(t, string(teamEOA), string(e.Owner))
	uassert.Equal(t, "vault", e.Name)

	// the audit's P1: there is no way to register an address you do not
	// control — the entry address is ALWAYS the caller's own. An
	// attacker registering gets an entry for themselves, not the victim.
	testing.SetRealm(testing.NewUserRealm(attacker))
	Register(cross(cur), "fake_vault", "")
	uassert.Equal(t, string(attacker), string(entries[attacker].Address))
	_, hijacked := entries[v2]
	uassert.False(t, hijacked, "no entry may exist for an address that never registered itself")
}

func TestRegister_OwnerDefaultsToContract(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", "")

	uassert.Equal(t, string(v1), string(entries[v1].Owner))
}

func TestRegister_DuplicateRejected(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", "")

	testing.SetRealm(testing.NewUserRealm(v1))
	uassert.AbortsWithMessage(t, cur,
		"contract already registered: "+string(v1),
		func() { Register(cross(cur), "vault_again", "") },
	)
}

func TestRegister_NameValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(v1))

	for _, bad := range []string{"", "Vault", "has space", "tick`name", strings.Repeat("a", MaxNameLen+1)} {
		uassert.AbortsContains(t, cur,
			"name must be",
			func() { Register(cross(cur), bad, "") },
		)
	}
}

func TestRegister_InvalidOwnerRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(v1))

	uassert.AbortsWithMessage(t, cur,
		"invalid owner address: junk",
		func() { Register(cross(cur), "vault", address("junk")) },
	)
}

// ---------- Deprecate ----------

func TestDeprecate_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)
	register(cur, v2, "vault_v2", teamEOA)

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can deprecate this contract",
		func() { Deprecate(cross(cur), v1, v2) },
	)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	Deprecate(cross(cur), v1, v2)
	uassert.Equal(t, string(v2), string(GetLatest(v1)))
}

func TestDeprecate_SuccessorMustBeRegistered(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)

	// the audit's dangling-successor + front-running route: pointing at
	// an unregistered address is refused outright, and a successor entry
	// can only ever be created by the successor contract itself
	testing.SetRealm(testing.NewUserRealm(teamEOA))
	uassert.AbortsWithMessage(t, cur,
		"successor is not a registered contract: "+string(v2),
		func() { Deprecate(cross(cur), v1, v2) },
	)
}

func TestDeprecate_SelfAndDoubleRejected(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)
	register(cur, v2, "vault_v2", teamEOA)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	uassert.AbortsWithMessage(t, cur,
		"successor cannot be the contract itself",
		func() { Deprecate(cross(cur), v1, v1) },
	)
	Deprecate(cross(cur), v1, v2)
	uassert.AbortsWithMessage(t, cur,
		"contract is already deprecated",
		func() { Deprecate(cross(cur), v1, v2) },
	)
}

func TestDeprecate_CircularChainRejected(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)
	register(cur, v2, "vault_v2", teamEOA)
	register(cur, v3, "vault_v3", teamEOA)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	Deprecate(cross(cur), v1, v2)
	Deprecate(cross(cur), v2, v3)

	// closing the loop from the tail must abort
	uassert.AbortsWithMessage(t, cur,
		"deprecating "+string(v3)+" to "+string(v1)+" would create a circular migration chain",
		func() { Deprecate(cross(cur), v3, v1) },
	)
}

// ---------- chain queries ----------

func TestGetLatest_WalksChain(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)
	register(cur, v2, "vault_v2", teamEOA)
	register(cur, v3, "vault_v3", teamEOA)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	Deprecate(cross(cur), v1, v2)
	Deprecate(cross(cur), v2, v3)

	uassert.Equal(t, string(v3), string(GetLatest(v1)))
	uassert.Equal(t, string(v3), string(GetLatest(v2)))
	uassert.Equal(t, string(v3), string(GetLatest(v3)))
	// unknown addresses come back unchanged
	uassert.Equal(t, string(attacker), string(GetLatest(attacker)))
}

func TestGetMigrationChain(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)
	register(cur, v2, "vault_v2", teamEOA)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	Deprecate(cross(cur), v1, v2)

	out := GetMigrationChain(v1)
	uassert.True(t, strings.Contains(out, "vault_v1"), "chain must name v1")
	uassert.True(t, strings.Contains(out, "[deprecated]"), "chain must tag deprecation")
	uassert.True(t, strings.Contains(out, "vault_v2"), "chain must name v2")
	uassert.Equal(t, "not found: "+string(attacker), GetMigrationChain(attacker))
}

// ---------- TransferOwnership ----------

func TestTransferOwnership(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)
	newOwner := testutils.TestAddress("newowner")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can transfer ownership",
		func() { TransferOwnership(cross(cur), v1, attacker) },
	)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	uassert.AbortsWithMessage(t, cur,
		"invalid new owner address: junk",
		func() { TransferOwnership(cross(cur), v1, address("junk")) },
	)
	TransferOwnership(cross(cur), v1, newOwner)
	// nomination alone changes nothing (two-step)
	uassert.Equal(t, string(teamEOA), string(entries[v1].Owner))
	uassert.Equal(t, string(v1), GetOwnerContracts(teamEOA))

	testing.SetRealm(testing.NewUserRealm(newOwner))
	AcceptOwnership(cross(cur), v1)
	uassert.Equal(t, string(newOwner), string(entries[v1].Owner))
	uassert.Equal(t, "none", GetOwnerContracts(teamEOA))
	uassert.Equal(t, string(v1), GetOwnerContracts(newOwner))
}

// ---------- render ----------

func TestRender_EmptyState(cur realm, t *testing.T) {
	resetState()
	out := Render("")
	uassert.True(t, strings.HasPrefix(out, "# Upgrade Registry\n\n"), "heading first")
	uassert.True(t, strings.HasSuffix(out, "No contracts registered.\n"),
		"empty state must still say the registry is empty")
	// round-4 audit: the scope disclosure is not conditional on there being
	// entries — an empty page must not read as an endorsement-free zone.
	uassert.True(t, strings.Contains(out, "**Names are not.**"),
		"the name-scope disclosure must appear even in the empty state")
}

// TestRender_CarriesNameScopeDisclosure is the regression guard for the
// round-4 audit finding that all three review passes raised: the rendered
// page gives a self-asserted NAME the most visual weight while only the
// ADDRESS is actually proven. Names are deliberately never made unique
// (first-come uniqueness on an immutable permissionless registry would let
// an attacker burn every valuable name forever), so disclosing the scope in
// the output is the entire mitigation. It cannot be added after deploy.
//
// Each assertion below names a distinct claim, so deleting or softening any
// one of them fails this test rather than silently degrading the warning.
func TestRender_CarriesNameScopeDisclosure(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)

	// The impersonation this disclosure exists for: a second, unrelated
	// address registering the SAME name is permitted and renders equally.
	register(cur, attacker, "vault_v1", "")

	out := Render("")
	for _, claim := range []string{
		"> [!NOTE]",
		"Addresses are self-registered and therefore verified",
		"**Names are not.**",
		"NOT unique",
		"may impersonate another project",
		"address, never by name.",
	} {
		uassert.True(t, strings.Contains(out, claim),
			"rendered disclosure must carry the claim: "+claim)
	}

	// Both duplicate-named entries really are present — the disclosure is
	// describing a live condition, not a hypothetical one.
	uassert.Equal(t, 2, strings.Count(out, "**vault_v1**"),
		"duplicate names are permitted and both must render")
}

func TestRender_Sections(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault_v1", teamEOA)
	register(cur, v2, "vault_v2", teamEOA)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	Deprecate(cross(cur), v1, v2)

	out := Render("")
	uassert.True(t, strings.Contains(out, "## Active"), "active section")
	uassert.True(t, strings.Contains(out, "## Deprecated"), "deprecated section")
	uassert.True(t, strings.Contains(out, "DEPRECATED"), "deprecation flag")
	uassert.True(t, strings.Contains(out, string(v2)), "successor shown")
}

// ---------- re-audit regressions (2026-09-02) ----------

func TestOwnerNomination_RequiresConsent(cur realm, t *testing.T) {
	resetState()

	// re-audit P2: registering with someone else's address as owner must
	// NOT attach them — no pollution of GetOwnerContracts, no GetInfo
	// showing them as owner, until they accept
	victim := teamEOA
	testing.SetRealm(testing.NewUserRealm(attacker))
	Register(cross(cur), "gnoswap_router", victim)

	uassert.Equal(t, string(attacker), string(entries[attacker].Owner))
	uassert.Equal(t, "none", GetOwnerContracts(victim))
	uassert.True(t, strings.Contains(GetInfo(attacker), string(attacker)),
		"info must show the contract itself as owner pre-acceptance")

	// only the nominee can accept; a bystander cannot
	testing.SetRealm(testing.NewUserRealm(newOwnerAddr()))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner of "+string(attacker),
		func() { AcceptOwnership(cross(cur), attacker) },
	)
}

func newOwnerAddr() address {
	return testutils.TestAddress("bystander")
}

func TestDeprecate_SuccessorConsentRequired(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)

	// re-audit P2: an attacker chains their entry INTO a legit contract,
	// forging predecessor provenance — refused unless the caller owns
	// the successor entry too
	testing.SetRealm(testing.NewUserRealm(attacker))
	Register(cross(cur), "vault_v1_old", "")
	uassert.AbortsWithMessage(t, cur,
		"successor entry is not owned by the caller: "+string(v1),
		func() { Deprecate(cross(cur), attacker, v1) },
	)
}

func TestMigrationChain_MarksTruncation(cur realm, t *testing.T) {
	resetState()
	// build a chain longer than MaxChainLen entirely under one owner
	prev := address("")
	addrs := make([]address, MaxChainLen+5)
	for i := range addrs {
		addrs[i] = testutils.TestAddress("link_" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(addrs[i]))
		Register(cross(cur), "link", teamEOA)
		testing.SetRealm(testing.NewUserRealm(teamEOA))
		AcceptOwnership(cross(cur), addrs[i])
		if prev != "" {
			Deprecate(cross(cur), prev, addrs[i])
		}
		prev = addrs[i]
	}

	out := GetMigrationChain(addrs[0])
	uassert.True(t, strings.Contains(out, "truncated"),
		"over-length chains must carry an explicit truncation marker")
	// GetLatest still resolves the true endpoint
	uassert.Equal(t, string(addrs[len(addrs)-1]), string(GetLatest(addrs[0])))
}

func TestTransferNomination_CanBeCleared(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)

	testing.SetRealm(testing.NewUserRealm(teamEOA))
	TransferOwnership(cross(cur), v1, attacker)
	TransferOwnership(cross(cur), v1, "")

	// round-4 audit L2: clearing again is a pure no-op, and the emitted
	// event is now suppressed for it. The return value and the state are
	// unchanged either way, which is all a unit test can observe here --
	// this toolchain's testing stdlib carries no events accessor. That the
	// second clear emits NOTHING is asserted externally by
	// tools/test_upgrade_registry_events.sh, which counts the events
	// `gno test -print-events` prints for this very suite.
	uassert.Equal(t, "pending ownership nomination cleared",
		TransferOwnership(cross(cur), v1, ""))
	uassert.Equal(t, "", string(mustGet(v1).PendingOwner))

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner of "+string(v1),
		func() { AcceptOwnership(cross(cur), v1) },
	)
}

// ---------- round-3 audit regressions (2026-09-02) ----------

func TestRenderLatest_ExactBudgetChainIsComplete(cur realm, t *testing.T) {
	resetState()
	// exactly RenderLatestHops deprecated hops + terminal endpoint:
	// the walk must be reported COMPLETE (round-3 off-by-one)
	n := RenderLatestHops + 1
	addrs := make([]address, n)
	for i := range addrs {
		addrs[i] = testutils.TestAddress("hop_" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(addrs[i]))
		Register(cross(cur), "hop", teamEOA)
		testing.SetRealm(testing.NewUserRealm(teamEOA))
		AcceptOwnership(cross(cur), addrs[i])
		if i > 0 {
			Deprecate(cross(cur), addrs[i-1], addrs[i])
		}
	}
	latest, complete := renderLatest(addrs[0])
	uassert.True(t, complete, "an exactly-budget chain must be complete")
	uassert.Equal(t, string(addrs[n-1]), string(latest))
}

// ---------- audit gap closures (2026-09-21, apps-pipeline round) ----------

func TestStraySendRejectedEverywhere(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)

	// audit Y2: the realm holds no banker, so attached coins would
	// strand forever — every crossing function must abort them
	msg := "this realm does not accept coins"
	testing.SetRealm(testing.NewUserRealm(teamEOA))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, msg, func() { Register(cross(cur), "paid", "") })
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptOwnership(cross(cur), v1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { TransferOwnership(cross(cur), v1, attacker) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Deprecate(cross(cur), v1, v2) })
	testing.SetOriginSend(nil)
}

func TestDeprecate_BoundedWalkRefusal(cur realm, t *testing.T) {
	resetState()
	// audit Y5.1: the round-3 bounded-walk panic had zero coverage.
	// Build a chain longer than MaxChainLen, then point a fresh entry
	// at its head — the verification walk must refuse, not walk it.
	prev := address("")
	addrs := make([]address, MaxChainLen+5)
	for i := range addrs {
		addrs[i] = testutils.TestAddress("bw_" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(addrs[i]))
		Register(cross(cur), "link", teamEOA)
		testing.SetRealm(testing.NewUserRealm(teamEOA))
		AcceptOwnership(cross(cur), addrs[i])
		if prev != "" {
			Deprecate(cross(cur), prev, addrs[i])
		}
		prev = addrs[i]
	}
	fresh := testutils.TestAddress("bw_fresh")
	testing.SetRealm(testing.NewUserRealm(fresh))
	Register(cross(cur), "fresh", teamEOA)
	testing.SetRealm(testing.NewUserRealm(teamEOA))
	AcceptOwnership(cross(cur), fresh)
	uassert.AbortsWithMessage(t, cur,
		"successor chain too long to verify; cannot deprecate",
		func() { Deprecate(cross(cur), fresh, addrs[0]) },
	)
}

func TestRenderLatest_LongChainMarked(cur realm, t *testing.T) {
	resetState()
	// audit Y5.2: the incomplete branch and Render's long-chain marker
	// were untested. Budget-boundary node must be NON-terminal here.
	n := RenderLatestHops + 3
	addrs := make([]address, n)
	for i := range addrs {
		addrs[i] = testutils.TestAddress("lc_" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(addrs[i]))
		Register(cross(cur), "hop", teamEOA)
		testing.SetRealm(testing.NewUserRealm(teamEOA))
		AcceptOwnership(cross(cur), addrs[i])
		if i > 0 {
			Deprecate(cross(cur), addrs[i-1], addrs[i])
		}
	}
	_, complete := renderLatest(addrs[0])
	uassert.False(t, complete, "an over-budget chain must be reported incomplete")
	uassert.True(t, strings.Contains(Render(""), "(long chain; use GetLatest)"),
		"render must mark over-budget chains instead of mislabeling an endpoint")
}

func TestRender_Pagination(cur realm, t *testing.T) {
	resetState()
	// audit Y5.3: the MaxRenderEntries window was untested
	for i := 0; i < MaxRenderEntries+5; i++ {
		a := testutils.TestAddress("pg_" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(a))
		Register(cross(cur), "entry", "")
	}
	out := Render("")
	uassert.True(t, strings.Contains(out,
		"_Showing the most recent "+strconv.Itoa(MaxRenderEntries)+" entries of "+
			strconv.Itoa(MaxRenderEntries+5)+"."),
		"over-window registries must announce the window AND the true total")
	// round-4 audit: announcing the window is not enough on an immutable
	// realm — the page must also say where the unlisted entries went, since
	// a flood of new entries evicts older ones from this view permanently.
	uassert.True(t, strings.Contains(out, "remain queryable by address via GetInfo"),
		"the eviction notice must point at the accessors that still serve them")
}

func TestRenomination_OverwritesPrior(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)
	a := testutils.TestAddress("nominee_a")
	b := testutils.TestAddress("nominee_b")

	// audit Y5.4: a newer nomination must revoke the older one
	testing.SetRealm(testing.NewUserRealm(teamEOA))
	TransferOwnership(cross(cur), v1, a)
	TransferOwnership(cross(cur), v1, b)
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner of "+string(v1),
		func() { AcceptOwnership(cross(cur), v1) },
	)
	testing.SetRealm(testing.NewUserRealm(b))
	AcceptOwnership(cross(cur), v1)
	uassert.Equal(t, string(b), string(entries[v1].Owner))
}

func TestSelfNominationAcceptKeepsIndexClean(cur realm, t *testing.T) {
	resetState()
	register(cur, v1, "vault", teamEOA)

	// audit Y5.5: owner nominating themselves and accepting must not
	// duplicate or lose the ownerContracts index entry
	testing.SetRealm(testing.NewUserRealm(teamEOA))
	TransferOwnership(cross(cur), v1, teamEOA)
	AcceptOwnership(cross(cur), v1)
	uassert.Equal(t, string(teamEOA), string(entries[v1].Owner))
	uassert.Equal(t, string(v1), GetOwnerContracts(teamEOA))
}

func TestOpsOnUnregisteredAbort(cur realm, t *testing.T) {
	resetState()
	// audit Y5.6: the not-found aborts were never asserted
	ghost := testutils.TestAddress("ghost")
	msg := "contract not found: " + string(ghost)
	testing.SetRealm(testing.NewUserRealm(teamEOA))
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptOwnership(cross(cur), ghost) })
	uassert.AbortsWithMessage(t, cur, msg, func() { TransferOwnership(cross(cur), ghost, teamEOA) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Deprecate(cross(cur), ghost, v1) })
	// GetInfo shares mustGet with the three crossing paths above; its
	// same-realm panic is not catchable by the revive-based Aborts helpers
}

func TestRegister_OwnerEqualsSelfNoPending(cur realm, t *testing.T) {
	resetState()
	// audit Y5.7: registering with your own address as owner must leave
	// no pending nomination (the explicit owner==contractAddr branch)
	testing.SetRealm(testing.NewUserRealm(v1))
	Register(cross(cur), "vault", v1)
	uassert.Equal(t, string(v1), string(entries[v1].Owner))
	uassert.Equal(t, "", string(entries[v1].PendingOwner))
}
