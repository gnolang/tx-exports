package fund

import (
	"chain"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// MaxInstruments keeps the NAV marks within one call (review m1).
const MaxInstruments = 10

func onlyDeployerInSetup(cur realm) {
	assertMasterKey()
	if cur.Previous().Address() != deployer {
		panic("deployer only")
	}
	requireState(stateSetup)
}

// Configure names the five role holders. Deployer only, before Launch.
func Configure(cur realm, mgr, admin, rev, off, aud address) {
	onlyDeployerInSetup(cur)
	all := []address{mgr, admin, rev, off, aud}
	for i, a := range all {
		if !a.IsValid() {
			panic("invalid address")
		}
		if a == deployer {
			panic("a role holder cannot be the deployer")
		}
		if isFundAccount(a) {
			panic("a role holder cannot be one of the fund's own accounts")
		}
		for j := 0; j < i; j++ {
			if all[j] == a {
				panic("each role needs its own address")
			}
		}
	}
	manager, administrator, reviewer, officer, auditor = mgr, admin, rev, off, aud
}

// AddProvider lists a service provider the fund may pay: ADMIN and BANK
// receive the scheduled fees; others (AUDIT, LEGAL, ...) receive expenses
// approved with two signatures. Deployer only, before Launch.
func AddProvider(cur realm, name string, payTo address) {
	onlyDeployerInSetup(cur)
	if len(providerOrd) >= MaxInstruments {
		panic(ufmt.Sprintf("at most %d service providers", MaxInstruments))
	}
	if len(name) == 0 || len(name) > 16 {
		panic("provider name: 1-16 characters")
	}
	for _, r := range name {
		if !(r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
			panic("provider name: A-Z, 0-9 and - only")
		}
	}
	if !payTo.IsValid() {
		panic("invalid address")
	}
	if providers.Has(name) {
		panic("provider already listed")
	}
	providers.Set(name, payTo)
	providerOrd = append(providerOrd, name)
}

// AddInstrument lists an instrument the manager may invest in, with the
// address that receives investment payments. Deployer only, before Launch.
func AddInstrument(cur realm, name, label string, payTo address) {
	onlyDeployerInSetup(cur)
	if len(instrOrder) >= MaxInstruments {
		panic(ufmt.Sprintf("at most %d instruments", MaxInstruments))
	}
	if len(name) == 0 || len(name) > 16 || len(label) == 0 || len(label) > 80 {
		panic("name 1-16 and label 1-80 characters")
	}
	if name == "OTHER" {
		panic("OTHER is reserved")
	}
	for _, r := range name {
		if !(r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
			panic("instrument name: A-Z, 0-9 and - only")
		}
	}
	if strings.ContainsAny(label, "\n\r|") {
		panic("label must be one line without |")
	}
	if !payTo.IsValid() {
		panic("invalid address")
	}
	if instruments.Has(name) {
		panic("instrument already listed")
	}
	instruments.Set(name, &instrument{name: name, label: label, payTo: payTo})
	instrOrder = append(instrOrder, name)
}

// RegisterNominee names the nominee realm, which must be a sub-realm of this
// fund so that the screening agent's one session covers it. Deployer only,
// before Launch. Optional: without it the fund offers direct registration
// only.
func RegisterNominee(cur realm, path string) {
	onlyDeployerInSetup(cur)
	if !strings.HasPrefix(path, selfPath+"/") || len(path) > 128 {
		panic("the nominee must be a sub-realm of this fund")
	}
	nomineePath = path
	nomineeAddr = chain.PackageAddress(path)
	nomineeConfirmed = false
}

// nomineeConfirmed: the nominee realm has called ConfirmNominee from its own
// code, which proves its code is deployed at the registered path before
// Launch (packages cannot be changed afterwards; review 2, m7).
var nomineeConfirmed bool

// ConfirmNominee is called by the registered nominee realm itself, before
// Launch.
func ConfirmNominee(cur realm) {
	assertMasterKey()
	requireState(stateSetup)
	if nomineePath == "" || cur.Previous().PkgPath() != nomineePath {
		panic("the registered nominee realm only")
	}
	nomineeConfirmed = true
}

// SetCrystalliseMinDays sets the fewest days between two crystallisations of
// the performance fee (0 to 366; default 182). Deployer only, before Launch;
// shown on the terms page.
func SetCrystalliseMinDays(cur realm, days int64) {
	onlyDeployerInSetup(cur)
	if days < 0 || days > 366 {
		panic("days must be 0 to 366")
	}
	crystalliseMinDays = days
}

// Launch checks the configuration, fixes the roles and opens dealing period
// 1. Deployer only. After this the deployer has no powers.
func Launch(cur realm) {
	onlyDeployerInSetup(cur)
	if !manager.IsValid() {
		panic("roles not configured")
	}
	if len(instrOrder) == 0 {
		panic("no instruments listed")
	}
	for _, a := range []address{manager, administrator, reviewer, officer, auditor} {
		if isFundAccount(a) {
			panic("a role holder cannot be one of the fund's own accounts")
		}
	}
	for _, n := range instrOrder {
		p := getInstrument(n).payTo
		if isFundAccount(p) || isRole(p) {
			panic("instrument " + n + ": payment address cannot be a fund account or a role holder")
		}
	}
	if !providers.Has("ADMIN") || !providers.Has("BANK") {
		panic("providers ADMIN and BANK must be listed")
	}
	if nomineePath != "" && !nomineeConfirmed {
		panic("the nominee realm has not confirmed itself")
	}
	for _, n := range providerOrd {
		p := getProvider(n)
		if isFundAccount(p) || p == manager || p == reviewer || p == deployer {
			panic("provider " + n + ": payment address cannot be a fund account, the manager, the reviewer or the deployer")
		}
		// A role holder may be paid only its own fee (review 2, m6).
		if p == officer || (p == administrator && n != "ADMIN") || (p == auditor && n != "AUDIT") {
			panic("provider " + n + ": a role holder may be paid only its own fee")
		}
	}
	launched = true
	launchTime = now()
	lastCrystTime = launchTime
	cur0 = period{n: 1, state: stateOpen, openedAt: now()}
	addTrail("deployer", ufmt.Sprintf("Fund launched. Memorandum v%s, SHA-256 %s. Period 1 open.", MemoVersion, memorandumHash()))
}

// RegisterAgentSession records the session key of the screening agent and
// the latest expiry it may have (unix seconds, within 60 days). The compliance officer creates the
// session with gnokey, limited to this realm, and registers it here with
// the officer's master key.
func RegisterAgentSession(cur realm, session address, expiresAt int64) {
	onlyRole(cur, officer, "compliance officer")
	if !session.IsValid() {
		panic("invalid address")
	}
	if expiresAt <= now() || expiresAt > now()+AgentSessionMaxDays*86400 {
		panic("session expiry must be in the future and within 60 days")
	}
	agentSession, agentExpiry = session, expiresAt
	addTrail("compliance", "Screening agent session key registered: "+session.String())
}

// assertAgent accepts only the registered agent session: signed by a session
// key of the compliance officer, limited to this realm (which covers its
// nominee sub-realm), expiring no later than the registered expiry.
func assertAgent(cur realm) { CheckAgent(cur.Previous().Address()) }
