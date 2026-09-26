package service_registry

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner    = testutils.TestAddress("owner")
	attacker = testutils.TestAddress("attacker")
	newOwner = testutils.TestAddress("newowner")
	third    = testutils.TestAddress("third")
)

const goodPath = "gno.land/r/demo/oracle"

// resetState resets all package-level state between tests.
func resetState() {
	services = make(map[string]*Service)
	names = []string{}
	retired = make(map[string]*Reservation)
	ownerServices = make(map[address]int)
	pendingOwners = make(map[string]address)
}

func register(cur realm, name string) {
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), name, goodPath, "a price oracle", "oracle", "")
}

// fillFor registers n services for one address under a name prefix.
//
// NOTE: testing.SetRealm is FRAME-scoped — the caller realm set here does
// not survive the return, so a caller that needs a specific identity
// afterwards must set it again itself.
func fillFor(cur realm, who address, prefix string, n int) {
	testing.SetRealm(testing.NewUserRealm(who))
	for i := 0; i < n; i++ {
		RegisterService(cross(cur), prefix+strconv.Itoa(i), goodPath, "d", "oracle", "")
	}
}

// handOff runs a COMPLETE two-step ownership transfer: the sitting owner
// nominates, the nominee consents. Ownership does not move until the
// second call (pearl audit Y4).
func handOff(cur realm, from, to address, name string) {
	testing.SetRealm(testing.NewUserRealm(from))
	TransferOwnership(cross(cur), name, to)
	testing.SetRealm(testing.NewUserRealm(to))
	AcceptOwnership(cross(cur), name)
}

func quotaMsg() string {
	return "address already holds the maximum of " +
		strconv.Itoa(MaxServicesPerOwner) + " services"
}

// ---------- RegisterService ----------

func TestRegister_Basic(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	svc := services["price_oracle"]
	uassert.Equal(t, string(owner), string(svc.Owner))
	uassert.Equal(t, goodPath, svc.PkgPath)
	uassert.Equal(t, "oracle", svc.ServiceType)
}

func TestRegister_DuplicateRejected(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"service already registered: price_oracle",
		func() { RegisterService(cross(cur), "price_oracle", goodPath, "mine now", "oracle", "") },
	)
}

func TestRegister_NameValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	for _, bad := range []string{"", "Upper", "has space", "semi;colon", strings.Repeat("a", MaxNameLen+1)} {
		uassert.AbortsContains(t, cur,
			"name must be",
			func() { RegisterService(cross(cur), bad, goodPath, "d", "oracle", "") },
		)
	}
}

func TestRegister_PkgPathValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur, "pkgpath must not be empty",
		func() { RegisterService(cross(cur), "svc", "", "d", "oracle", "") })
	uassert.AbortsContains(t, cur, "pkgpath must start with",
		func() { RegisterService(cross(cur), "svc", "example.com/r/x", "d", "oracle", "") })
	uassert.AbortsContains(t, cur, "pkgpath must be gno.land/r/",
		func() { RegisterService(cross(cur), "svc", "gno.land/", "d", "oracle", "") })
	uassert.AbortsContains(t, cur, "invalid pkgpath element",
		func() { RegisterService(cross(cur), "svc", "gno.land/r/x|y", "d", "oracle", "") })
	uassert.AbortsContains(t, cur, "pkgpath exceeds",
		func() {
			RegisterService(cross(cur), "svc", "gno.land/r/"+strings.Repeat("a", MaxPkgPathLen), "d", "oracle", "")
		})
}

func TestRegister_FieldValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur, "description must not be empty",
		func() { RegisterService(cross(cur), "svc", goodPath, "", "oracle", "") })
	uassert.AbortsContains(t, cur, "description exceeds",
		func() {
			RegisterService(cross(cur), "svc", goodPath, strings.Repeat("d", MaxDescriptionLen+1), "oracle", "")
		})
	uassert.AbortsWithMessage(t, cur, "service type must not be empty",
		func() { RegisterService(cross(cur), "svc", goodPath, "d", "", "") })
	uassert.AbortsContains(t, cur, "service type must be",
		func() { RegisterService(cross(cur), "svc", goodPath, "d", "Bad|Type", "") })
	uassert.AbortsContains(t, cur, "metadata exceeds",
		func() {
			RegisterService(cross(cur), "svc", goodPath, "d", "oracle", strings.Repeat("m", MaxMetadataLen+1))
		})
}

// ---------- Deregister + squat protection ----------

func TestDeregister_NameStaysReservedForOwner(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(owner))
	Deregister(cross(cur), "price_oracle")
	uassert.PanicsWithMessage(t, cur,
		"service not found: price_oracle",
		func() { Resolve("price_oracle") },
	)

	// the squat the audit found: attacker re-registers the freed name
	// and inherits every integrator still resolving it — must be blocked
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"name is reserved for its former owner: price_oracle",
		func() {
			RegisterService(cross(cur), "price_oracle", "gno.land/r/evil/oracle", "trust me", "oracle", "")
		},
	)

	// the former owner can re-register it
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), "price_oracle", goodPath, "back again", "oracle", "")
	uassert.Equal(t, goodPath, Resolve("price_oracle"))
}

func TestDeregister_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can deregister",
		func() { Deregister(cross(cur), "price_oracle") },
	)
}

// ---------- UpdateService / TransferOwnership ----------

func TestUpdate_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can update this service",
		func() { UpdateService(cross(cur), "price_oracle", "gno.land/r/evil/oracle", "hijacked", "oracle", "") },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	UpdateService(cross(cur), "price_oracle", "gno.land/r/demo/oracle_v2", "v2", "oracle", "k=v")
	uassert.Equal(t, "gno.land/r/demo/oracle_v2", Resolve("price_oracle"))
}

func TestTransferOwnership(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can transfer ownership",
		func() { TransferOwnership(cross(cur), "price_oracle", attacker) },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur,
		"invalid new owner address: junk",
		func() { TransferOwnership(cross(cur), "price_oracle", address("junk")) },
	)
	uassert.AbortsWithMessage(t, cur,
		"new owner is already the owner",
		func() { TransferOwnership(cross(cur), "price_oracle", owner) },
	)

	handOff(cur, owner, newOwner, "price_oracle")
	uassert.Equal(t, string(newOwner), string(GetOwner("price_oracle")))

	// the new owner controls the entry now
	testing.SetRealm(testing.NewUserRealm(newOwner))
	UpdateService(cross(cur), "price_oracle", goodPath, "under new management", "oracle", "")
}

// ---------- queries ----------

func TestResolve_UnknownPanics(cur realm, t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t, cur,
		"service not found: ghost",
		func() { Resolve("ghost") },
	)
}

func TestListServices_And_ByType(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), "alpha", goodPath, "d", "oracle", "")
	RegisterService(cross(cur), "beta", goodPath, "d", "dex", "")
	RegisterService(cross(cur), "gamma", goodPath, "d", "oracle", "")

	uassert.Equal(t, "alpha, beta, gamma", ListServices())
	uassert.Equal(t, "alpha, gamma", ListByType("oracle"))
	uassert.Equal(t, "none", ListByType("bridge"))
}

func TestGetService_Summary(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	out := GetService("price_oracle")
	uassert.True(t, strings.Contains(out, "PkgPath: "+goodPath), "summary must include pkgpath")
	uassert.True(t, strings.Contains(out, string(owner)), "summary must include owner")
}

// ---------- render ----------

func TestRender_EmptyState(cur realm, t *testing.T) {
	resetState()
	uassert.Equal(t, "# Service Registry\n\nNo services registered.\n", Render(""))
}

func TestRender_SanitizesInjection(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), "sneaky", goodPath,
		"desc` | fake | row\ninjected", "oracle", "")

	out := Render("")
	uassert.False(t, strings.Contains(out, "desc`"), "backticks must be sanitized")
	uassert.False(t, strings.Contains(out, "| fake |"), "pipes must be sanitized")
	uassert.False(t, strings.Contains(out, "\ninjected"), "newlines must be sanitized")
}

func TestRender_ListsEntries(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	out := Render("")
	uassert.True(t, strings.Contains(out, "price_oracle"), "render must list the service")
	uassert.True(t, strings.Contains(out, goodPath), "render must show the pkgpath")
	uassert.False(t, strings.Contains(out, "Showing"),
		"a short registry must not carry a truncation notice")
}

// ---------- re-audit regressions (2026-09-02) ----------

// skipSeconds advances chain time (5s per height).
func skipSeconds(sec int64) {
	testing.SkipHeights((sec + 4) / 5)
}

func TestReservation_ExpiresAndFreesTheName(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")
	testing.SetRealm(testing.NewUserRealm(owner))
	Deregister(cross(cur), "price_oracle")

	// re-audit P1: eternal tombstones let an attacker lock the namespace
	// forever; within the window the name stays reserved...
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"name is reserved for its former owner: price_oracle",
		func() { RegisterService(cross(cur), "price_oracle", "gno.land/r/evil/oracle", "d", "oracle", "") },
	)

	// ...but after ReservationPeriod it frees for anyone.
	// SkipHeights resets the whole test context, so the caller realm has
	// to be re-armed after the jump.
	skipSeconds(ReservationPeriod + 10)
	testing.SetRealm(testing.NewUserRealm(attacker))
	RegisterService(cross(cur), "price_oracle", "gno.land/r/other/oracle", "d", "oracle", "")
	uassert.Equal(t, "gno.land/r/other/oracle", Resolve("price_oracle"))

	// a LAPSED reservation confers nothing: the new registrant is stamped
	// as registrant, and the dead tombstone is reclaimed
	uassert.Equal(t, string(attacker), string(services["price_oracle"].Registrant),
		"a lapsed reservation must not preserve the old registrant")
	_, stillRetired := retired["price_oracle"]
	uassert.False(t, stillRetired, "a lapsed tombstone must be reclaimed")
}

func TestReservation_OriginalRegistrantCanReclaim(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	// re-audit P2: hostile transferee deregisters — the ORIGINAL
	// registrant can still reclaim during the reservation window
	handOff(cur, owner, attacker, "price_oracle")
	testing.SetRealm(testing.NewUserRealm(attacker))
	Deregister(cross(cur), "price_oracle")

	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), "price_oracle", goodPath, "reclaimed", "oracle", "")
	uassert.Equal(t, string(owner), string(services["price_oracle"].Owner))
}

func TestPkgPath_StructuralValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	// re-audit P3: traversal, doubled slashes, trailing slash, hyphens,
	// and non-r/p roots must all be refused
	bad := []string{
		"gno.land/r/../../etc/passwd",
		"gno.land//r//demo//oracle",
		"gno.land/r/demo/oracle/",
		"gno.land/r/de-mo/oracle",
		"gno.land/x/demo/oracle",
		"gno.land/.",
	}
	for _, p := range bad {
		uassert.AbortsContains(t, cur, "pkgpath",
			func() { RegisterService(cross(cur), "svc", p, "d", "oracle", "") })
	}
	// legitimate r/ and p/ paths still pass
	RegisterService(cross(cur), "svc_r", "gno.land/r/demo/oracle_v2", "d", "oracle", "")
	RegisterService(cross(cur), "svc_p", "gno.land/p/nt/avl", "d", "oracle", "")
}

func TestTryResolve(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	got, ok := TryResolve("price_oracle")
	uassert.True(t, ok, "known name must resolve")
	uassert.Equal(t, goodPath, got)

	_, ok = TryResolve("ghost")
	uassert.False(t, ok, "unknown name must return ok=false, never panic")
}

// ---------- round-3 audit regressions (2026-09-02) ----------

func TestReservation_RegistrantSurvivesHostileRecycle(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	// round-3 P2: hostile transferee deregisters and INSTANTLY
	// re-registers — the original registrant must survive the recycle
	handOff(cur, owner, attacker, "price_oracle")
	testing.SetRealm(testing.NewUserRealm(attacker))
	Deregister(cross(cur), "price_oracle")
	RegisterService(cross(cur), "price_oracle", "gno.land/r/evil/oracle", "mine", "oracle", "")
	uassert.Equal(t, string(owner), string(services["price_oracle"].Registrant),
		"in-window re-register must preserve the original registrant")

	// so when the attacker abandons again, the original can still reclaim
	Deregister(cross(cur), "price_oracle")
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), "price_oracle", goodPath, "reclaimed", "oracle", "")
	uassert.Equal(t, string(owner), string(services["price_oracle"].Owner))
}

func TestPkgPath_PinnedBehaviors(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	// round-3 pins: top-level realm path accepted; digit-leading element
	// and uppercase prefix rejected
	RegisterService(cross(cur), "toplevel", "gno.land/r/x", "d", "oracle", "")
	uassert.AbortsContains(t, cur, "invalid pkgpath element",
		func() { RegisterService(cross(cur), "digits", "gno.land/r/9abc", "d", "oracle", "") })
	uassert.AbortsContains(t, cur, "pkgpath must start with",
		func() { RegisterService(cross(cur), "upper", "GNO.LAND/r/demo/x", "d", "oracle", "") })
}

// ---------- pearl audit regressions (2026-09-21) ----------

// R1: one funded key could previously claim the ENTIRE namespace, since
// the only bound was the global MaxServices. The per-owner cap makes a
// namespace sweep cost MaxServices/MaxServicesPerOwner distinct funded
// addresses instead of one.
func TestRegister_PerOwnerQuota(cur realm, t *testing.T) {
	resetState()
	fillFor(cur, owner, "svc", MaxServicesPerOwner)
	testing.SetRealm(testing.NewUserRealm(owner)) // fillFor's realm is frame-scoped

	n, limit := OwnerServiceCount(owner)
	uassert.Equal(t, MaxServicesPerOwner, n)
	uassert.Equal(t, MaxServicesPerOwner, limit)

	uassert.AbortsWithMessage(t, cur, quotaMsg(),
		func() { RegisterService(cross(cur), "one_more", goodPath, "d", "oracle", "") })

	// a DIFFERENT address is completely unaffected — the cap is per-owner,
	// not a global freeze
	testing.SetRealm(testing.NewUserRealm(attacker))
	RegisterService(cross(cur), "one_more", goodPath, "d", "oracle", "")
	uassert.Equal(t, goodPath, Resolve("one_more"))

	// freeing a slot restores headroom
	testing.SetRealm(testing.NewUserRealm(owner))
	Deregister(cross(cur), "svc0")
	n, _ = OwnerServiceCount(owner)
	uassert.Equal(t, MaxServicesPerOwner-1, n)
	RegisterService(cross(cur), "fresh_name", goodPath, "d", "oracle", "")
	n, _ = OwnerServiceCount(owner)
	uassert.Equal(t, MaxServicesPerOwner, n)
}

// The quota index must not accumulate dead keys: an owner that drops to
// zero is deleted outright.
func TestQuota_IndexStaysZeroFree(cur realm, t *testing.T) {
	resetState()
	register(cur, "solo")
	uassert.Equal(t, 1, len(ownerServices))

	testing.SetRealm(testing.NewUserRealm(owner))
	Deregister(cross(cur), "solo")
	n, _ := OwnerServiceCount(owner)
	uassert.Equal(t, 0, n)
	uassert.Equal(t, 0, len(ownerServices), "a zeroed owner must leave no key behind")
}

// The global cap still backstops the per-owner cap. Reaching it through
// the public API would take MaxServices/MaxServicesPerOwner distinct
// funded addresses, so the state is staged directly (this test is
// in-package) and only the guard is exercised.
func TestRegister_GlobalCap(cur realm, t *testing.T) {
	resetState()
	for i := 0; i < MaxServices; i++ {
		n := "pad" + strconv.Itoa(i)
		services[n] = &Service{
			Name: n, Owner: attacker, Registrant: attacker,
			PkgPath: goodPath, Description: "d", ServiceType: "oracle",
		}
		names = append(names, n)
	}
	count, limit := ServiceCount()
	uassert.Equal(t, MaxServices, count)
	uassert.Equal(t, MaxServices, limit)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur, "global service limit reached",
		func() { RegisterService(cross(cur), "one_more", goodPath, "d", "oracle", "") })
}

// Y2: this realm holds no banker and exposes no withdrawal path, so coins
// attached to any entrypoint would strand at the realm address forever.
// Every crossing function must abort, which reverts the transfer.
func TestStraySendRejected(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")
	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross(cur), "price_oracle", newOwner)

	msg := "this realm does not accept coins"
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, msg,
		func() { RegisterService(cross(cur), "paid", goodPath, "d", "oracle", "") })
	uassert.AbortsWithMessage(t, cur, msg,
		func() { UpdateService(cross(cur), "price_oracle", goodPath, "paid", "oracle", "") })
	uassert.AbortsWithMessage(t, cur, msg,
		func() { TransferOwnership(cross(cur), "price_oracle", third) })
	uassert.AbortsWithMessage(t, cur, msg,
		func() { CancelOwnershipTransfer(cross(cur), "price_oracle") })
	uassert.AbortsWithMessage(t, cur, msg,
		func() { Deregister(cross(cur), "price_oracle") })

	testing.SetRealm(testing.NewUserRealm(newOwner))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, msg,
		func() { AcceptOwnership(cross(cur), "price_oracle") })
	testing.SetOriginSend(nil)

	// nothing was mutated by any of the rejected calls
	uassert.Equal(t, string(owner), string(GetOwner("price_oracle")))
	uassert.Equal(t, string(newOwner), GetPendingOwner("price_oracle"))
	uassert.Equal(t, "a price oracle", services["price_oracle"].Description)
	_, ok := TryResolve("paid")
	uassert.False(t, ok, "a rejected registration must not stick")
}

// Y3: Render is reachable by any viewer, so its cost lands on third
// parties rather than on whoever grew the state. It must be bounded and
// must say so.
func TestRender_Bounded(cur realm, t *testing.T) {
	resetState()
	fillFor(cur, owner, "a", MaxServicesPerOwner)
	extra := MaxRenderServices - MaxServicesPerOwner + 1
	fillFor(cur, attacker, "b", extra)

	total := MaxServicesPerOwner + extra
	count, _ := ServiceCount()
	uassert.Equal(t, total, count)

	out := Render("")
	uassert.True(t, strings.Contains(out, "**Total services:** "+strconv.Itoa(total)),
		"the header must report the TRUE total, not the rendered count")
	uassert.Equal(t, MaxRenderServices, strings.Count(out, "`"+goodPath+"`"),
		"exactly MaxRenderServices rows may be emitted")
	uassert.True(t, strings.Contains(out,
		"_Showing "+strconv.Itoa(MaxRenderServices)+" of "+strconv.Itoa(total)+" services."),
		"a truncated render must disclose the truncation")
	uassert.True(t, strings.Contains(out, "Use ListServices, ListByType or GetService"),
		"the notice must name the unbounded queries")
}

// Y5: the hand-rolled sanitizer replaced only backticks and pipes, leaving
// `[`, `]`, `(`, `)` and `!` live — so any registrant could inject a
// working markdown link or image into a table cell and phish every viewer.
func TestRender_RejectsMarkdownLinkInjection(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross(cur), "phish", goodPath,
		"claim [here](https://evil.example/drain)", "oracle", "")
	RegisterService(cross(cur), "tracker", goodPath,
		"![x](https://evil.example/pixel.png)", "oracle", "")

	out := Render("")
	uassert.False(t, strings.Contains(out, "]("),
		"no live markdown link/image syntax may survive into a table cell")
	uassert.False(t, strings.Contains(out, "!["),
		"no live markdown image opener may survive into a table cell")
	// the text itself is still shown — it is neutered, not censored. The
	// sanitizer escapes `.` too, so the raw host never appears verbatim.
	uassert.True(t, strings.Contains(out, "evil"),
		"the payload text must still be visible to the reader")
	uassert.False(t, strings.Contains(out, "evil.example"),
		"even the dot is escaped — no autolinkable host survives")

	// the same class of payload must not survive the single-line summary
	sum := GetService("phish")
	uassert.False(t, strings.Contains(sum, "]("),
		"GetService must escape markdown link syntax too")
}

// Y4: the one-step transfer this replaces was a permanent-brick hazard.
// address.IsValid() only checks bech32 form, so a well-formed but unowned
// destination committed immediately, after which the entry could never be
// updated, transferred or deregistered — and because it could never be
// deregistered it could never enter the reservation window either, so the
// NAME became a permanent hole in a shared global namespace.
func TestTransferOwnership_TwoStep(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	// nomination alone changes NOTHING
	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross(cur), "price_oracle", newOwner)
	uassert.Equal(t, string(owner), string(GetOwner("price_oracle")))
	uassert.Equal(t, string(newOwner), GetPendingOwner("price_oracle"))

	// the sitting owner keeps full control while the handoff is open
	UpdateService(cross(cur), "price_oracle", goodPath, "still mine", "oracle", "")

	// only the nominee may accept
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "only the nominated owner can accept",
		func() { AcceptOwnership(cross(cur), "price_oracle") })

	testing.SetRealm(testing.NewUserRealm(newOwner))
	AcceptOwnership(cross(cur), "price_oracle")
	uassert.Equal(t, string(newOwner), string(GetOwner("price_oracle")))
	uassert.Equal(t, "none", GetPendingOwner("price_oracle"))

	// the quota moved with the entry
	n, _ := OwnerServiceCount(owner)
	uassert.Equal(t, 0, n)
	n, _ = OwnerServiceCount(newOwner)
	uassert.Equal(t, 1, n)

	// the former owner is now an outsider
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur, "only the owner can update this service",
		func() { UpdateService(cross(cur), "price_oracle", goodPath, "back", "oracle", "") })
}

func TestTransferOwnership_Cancel(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur, "no pending ownership transfer for: price_oracle",
		func() { CancelOwnershipTransfer(cross(cur), "price_oracle") })

	TransferOwnership(cross(cur), "price_oracle", newOwner)
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "only the owner can cancel a transfer",
		func() { CancelOwnershipTransfer(cross(cur), "price_oracle") })

	testing.SetRealm(testing.NewUserRealm(owner))
	CancelOwnershipTransfer(cross(cur), "price_oracle")
	uassert.Equal(t, "none", GetPendingOwner("price_oracle"))

	testing.SetRealm(testing.NewUserRealm(newOwner))
	uassert.AbortsWithMessage(t, cur, "no pending ownership transfer for: price_oracle",
		func() { AcceptOwnership(cross(cur), "price_oracle") })

	// re-nominating and then clearing with the empty address is equivalent
	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross(cur), "price_oracle", newOwner)
	TransferOwnership(cross(cur), "price_oracle", address(""))
	uassert.Equal(t, "none", GetPendingOwner("price_oracle"))
}

// The quota is checked at CONSENT, not at nomination, so a nomination can
// never push an account past its cap without that account agreeing.
func TestTransferOwnership_QuotaCheckedAtConsent(cur realm, t *testing.T) {
	resetState()
	fillFor(cur, newOwner, "b", MaxServicesPerOwner)
	register(cur, "extra")

	// nomination succeeds even though the nominee is full...
	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross(cur), "extra", newOwner)
	uassert.Equal(t, string(newOwner), GetPendingOwner("extra"))

	// ...but consent is refused, and the entry stays with its owner
	testing.SetRealm(testing.NewUserRealm(newOwner))
	uassert.AbortsWithMessage(t, cur, quotaMsg(),
		func() { AcceptOwnership(cross(cur), "extra") })
	uassert.Equal(t, string(owner), string(GetOwner("extra")))

	// freeing one slot lets the same handoff complete
	Deregister(cross(cur), "b0")
	AcceptOwnership(cross(cur), "extra")
	uassert.Equal(t, string(newOwner), string(GetOwner("extra")))
	n, _ := OwnerServiceCount(newOwner)
	uassert.Equal(t, MaxServicesPerOwner, n)
}

// A nomination must not outlive the entry it was made against — otherwise
// a stale nominee could seize a name that was deregistered and reclaimed.
func TestTransferOwnership_NominationDiesWithEntry(cur realm, t *testing.T) {
	resetState()
	register(cur, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross(cur), "price_oracle", attacker)
	Deregister(cross(cur), "price_oracle")
	RegisterService(cross(cur), "price_oracle", goodPath, "reclaimed", "oracle", "")
	uassert.Equal(t, "none", GetPendingOwner("price_oracle"))

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "no pending ownership transfer for: price_oracle",
		func() { AcceptOwnership(cross(cur), "price_oracle") })
	uassert.Equal(t, string(owner), string(GetOwner("price_oracle")))
}
