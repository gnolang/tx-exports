package bolo

import (
	"chain"
	"chain/runtime"
)

// Administration (API §3.6). Every write here starts with C11's realm branch, then
// assertSigner: the master key, never a session key, in either branch, and then the
// admin's address — for AcceptAdmin, the proposed admin's. The rules on the values
// live in plain helpers, which unit tests drive directly: a crossing call's panic
// can't be recovered by a test, so the writes' refusals are tested in txtar (plan
// §3.3).

// assertCodeCaller refuses any caller but a deployed realm (API C11). A maketx run
// script is ephemeral and code at once: it is refused here, as is a user.
func assertCodeCaller(cur realm) {
	if p := cur.Previous(); !p.IsCode() || p.IsEphemeral() {
		panic(ErrNotUserCall)
	}
}

// assertSigner runs right after C11's branch: no session key, in either branch
// (C11), then the caller must be who (API §3.6).
func assertSigner(cur realm, who address) {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic(ErrSessionKey)
	}
	if cur.Previous().Address() != who {
		panic(ErrNotAdmin)
	}
}

// ProposeAdmin proposes next as the admin, who takes over by accepting. None of
// Bolo's own addresses can ever accept, so none can be proposed. A second proposal
// replaces the first.
func ProposeAdmin(cur realm, next address) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	checkOutsideBolo(next)
	pendingAdmin = next
	chain.Emit(evAdminProposed, "next", next.String())
}

// AcceptAdmin makes the proposed admin the admin, and ends the proposal.
func AcceptAdmin(cur realm) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, pendingAdmin)
	previous := admin
	admin, pendingAdmin = pendingAdmin, ""
	chain.Emit(evAdminChanged, "admin", admin.String(), "previous", previous.String())
}

// SetParams sets the Params new campaigns get; every live campaign keeps its own
// (INV-5).
func SetParams(cur realm, deposit int64, dormancyDays, exitDelayDays, bondHoldDays int) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	params = checkParams(deposit, dormancyDays, exitDelayDays, bondHoldDays)
	chain.Emit(evParamsChanged,
		"deposit", itoa(params.CreationDeposit),
		"dormancy", itoa(params.DormancyPeriod),
		"exitDelay", itoa(params.ExitDelay),
		"bondHold", itoa(params.BondHold),
	)
}

// SetTipRecipient sets where tips and swept strays go: never one of Bolo's own
// addresses.
func SetTipRecipient(cur realm, addr address) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	checkOutsideBolo(addr)
	tipRecipient = addr
	chain.Emit(evTipRecipientChanged, "to", addr.String())
}

// SetMinDonation sets the smallest gift Donate accepts, in ugnot, for new gifts.
func SetMinDonation(cur realm, amount int64) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	if amount <= 0 {
		panic(ErrSetting)
	}
	minDonation = amount
	chain.Emit(evMinDonationChanged, "amount", itoa(amount))
}

// SetPresets sets the four one-click amounts, in ugnot. Display only.
func SetPresets(cur realm, a, b, c, d int64) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	presets = checkPresets(a, b, c, d)
	chain.Emit(evPresetsChanged, "a", itoa(a), "b", itoa(b), "c", itoa(c), "d", itoa(d))
}

// SetEscrowCap sets the most one campaign's tracked escrow balance may reach; 0
// removes the cap. It gates gifts only, never money going out (INV-4).
func SetEscrowCap(cur realm, max int64) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	if max < 0 {
		panic(ErrSetting)
	}
	escrowCap = max
	chain.Emit(evEscrowCapChanged, "max", itoa(max))
}

// AddCategory adds a category. There is no remove and no rename: every campaign
// keeps a valid category.
func AddCategory(cur realm, code string) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	checkNewCategory(code)
	categories.Set(code, true)
	categoryOrder = append(categoryOrder, code)
	chain.Emit(evCategoryAdded, "code", code)
}

// Sunset stops CreateCampaign for good. It names no successor: where new campaigns
// start is the registry's Current() (API §3.7). A second call changes nothing.
func Sunset(cur realm) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	if sunset {
		return
	}
	sunset = true
	chain.Emit(evSunset)
}

// Pause stops CreateCampaign, Donate and PostBond — money coming in, never money
// going out. Pausing while paused changes nothing.
func Pause(cur realm) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	if paused {
		return
	}
	paused = true
	chain.Emit(evPaused)
}

// Unpause lifts a pause. Unpausing while running changes nothing.
func Unpause(cur realm) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	if !paused {
		return
	}
	paused = false
	chain.Emit(evUnpaused)
}

// checkParams returns the Params for SetParams' arguments, or panics with
// ErrSetting when one is out of bounds (API §3.6). The upper bounds keep the
// conversion to seconds far from overflowing.
func checkParams(deposit int64, dormancyDays, exitDelayDays, bondHoldDays int) Params {
	if deposit <= 0 || !between(dormancyDays, 1, 3650) || !between(exitDelayDays, 7, 3650) || !between(bondHoldDays, 0, 3650) {
		panic(ErrSetting)
	}
	return Params{
		CreationDeposit: deposit,
		DormancyPeriod:  daysToSeconds(dormancyDays, ErrSetting),
		ExitDelay:       daysToSeconds(exitDelayDays, ErrSetting),
		BondHold:        daysToSeconds(bondHoldDays, ErrSetting),
	}
}

func between(n, min, max int) bool { return n >= min && n <= max }

// checkPresets returns the four amounts, or panics with ErrSetting unless they
// are positive and strictly ascending (API §3.6).
func checkPresets(a, b, c, d int64) [4]int64 {
	if a <= 0 || a >= b || b >= c || c >= d {
		panic(ErrSetting)
	}
	return [4]int64{a, b, c, d}
}

// checkOutsideBolo refuses, with ErrSetting, a malformed address (C12) and every
// address of Bolo's own (API §3.6): the realm's, where tips would stay (INV-3); the
// escrow and bond addresses derived so far, where an escrow would count tips as
// untracked money; slashed, where they would be burned; the storage-deposit
// address, the keeper's (Q8); and the registry, with its storage-deposit address.
// Tips must not go there, and none of them can ever accept the admin role.
func checkOutsideBolo(a address) {
	checkAddress(a, ErrSetting)
	if a == realmAddr() || a == slashedAddr() || a == depositAddr() || a == registryAddr() || a == registryDepositAddr() || derived.Has(a.String()) {
		panic(ErrSetting)
	}
}

// checkNewCategory refuses a code that isn't 3 to 20 lowercase letters, one already
// listed, or one past the cap (API §3.6).
func checkNewCategory(code string) {
	if len(code) < 3 || len(code) > 20 || categories.Has(code) || len(categoryOrder) >= maxCategories {
		panic(ErrSetting)
	}
	for i := 0; i < len(code); i++ {
		if code[i] < 'a' || code[i] > 'z' {
			panic(ErrSetting)
		}
	}
}
