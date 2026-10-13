package bolo

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

// TestAdministration walks the admin's writes on a fresh deployment, each called
// straight from the test's body, as AssertOriginCall requires (plan §3.3): the
// launch values, then each write's effect, then the handover to a realm, which
// then administers through C11's realm branch. The writes' refusals are tested in
// txtar (admin.txtar): a crossing call's panic can't be recovered here.
func TestAdministration(cur realm, t *testing.T) {
	// The walk changes every setting and the admin: put them back, so later
	// tests start from the launch values.
	defer restoreSettings(admin, pendingAdmin, params, presets, minDonation, escrowCap, tipRecipient, paused, sunset, categoryOrder)

	// The launch values as API §2.2 states them: literals, not the constants under
	// test.
	if p := GetParams(); p != (Params{1_000_000, 90 * 86400, 60 * 86400, 30 * 86400}) {
		t.Errorf("launch params = %v", p)
	}
	s := GetSettings()
	if s.Version != "v0" || s.Presets != [4]int64{5_000_000, 10_000_000, 20_000_000, 50_000_000} ||
		s.MinDonation != 1_000_000 || s.MaxEscrowBalance != 1_000_000_000 ||
		s.TipRecipient != adminAddr || s.Paused || s.Sunset {
		t.Errorf("launch settings = %v", s)
	}
	launchSet := []string{
		"medical", "emergency", "disaster", "humanitarian", "water", "food",
		"education", "orphans", "animals", "funeral", "worship", "community",
		"sport", "celebration", "personal", "other",
	}
	if len(s.Categories) != len(launchSet) {
		t.Errorf("launch categories = %v", s.Categories)
	}
	for i, code := range launchSet {
		if i >= len(s.Categories) || s.Categories[i] != code || !categories.Has(code) {
			t.Errorf("launch category %d: want %s, listed and found", i, code)
		}
	}
	if a, p := GetAdmin(); a != adminAddr || p != "" {
		t.Errorf("GetAdmin() = %s, %q", a, p)
	}
	// GetSettings hands out a copy (C6).
	s.Categories[0] = "changed"
	if GetSettings().Categories[0] != "medical" {
		t.Errorf("GetSettings shares its categories with the realm")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	SetParams(cross(cur), 2_000_000, 30, 14, 0)
	SetMinDonation(cross(cur), 500_000)
	SetPresets(cross(cur), 1_000_000, 2_000_000, 3_000_000, 4_000_000)
	SetEscrowCap(cross(cur), 0)
	AddCategory(cross(cur), "garden")
	treasurer := testutils.TestAddress("treasurer")
	SetTipRecipient(cross(cur), treasurer)
	Pause(cross(cur))
	Sunset(cross(cur))
	if p := GetParams(); p != (Params{2_000_000, 30 * secondsPerDay, 14 * secondsPerDay, 0}) {
		t.Errorf("params = %v", p)
	}
	s = GetSettings()
	if s.MinDonation != 500_000 || s.Presets != [4]int64{1_000_000, 2_000_000, 3_000_000, 4_000_000} ||
		s.MaxEscrowBalance != 0 || s.TipRecipient != treasurer || !s.Paused || !s.Sunset ||
		len(s.Categories) != 17 || s.Categories[16] != "garden" || !categories.Has("garden") {
		t.Errorf("settings = %v", s)
	}
	Unpause(cross(cur))
	if GetSettings().Paused {
		t.Errorf("still paused")
	}

	// The handover (ADR D11): a second proposal replaces the first; accepting ends
	// the proposal, and the new admin is a realm.
	dao := chain.PackageAddress("gno.land/r/test/dao")
	ProposeAdmin(cross(cur), testutils.TestAddress("someone"))
	ProposeAdmin(cross(cur), dao)
	if a, p := GetAdmin(); a != adminAddr || p != dao {
		t.Errorf("after two proposals: GetAdmin() = %s, %s", a, p)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/dao"))
	AcceptAdmin(cross(cur))
	if a, p := GetAdmin(); a != dao || p != "" {
		t.Errorf("after accepting: GetAdmin() = %s, %q", a, p)
	}
	SetEscrowCap(cross(cur), 7)
	if GetSettings().MaxEscrowBalance != 7 {
		t.Errorf("the realm admin's write didn't apply")
	}
}

func TestCheckParams(t *testing.T) {
	if got := checkParams(1, 1, 7, 0); got != (Params{1, secondsPerDay, 7 * secondsPerDay, 0}) {
		t.Errorf("lower bounds: %v", got)
	}
	if got := checkParams(1, 3650, 3650, 3650); got != (Params{1, 3650 * secondsPerDay, 3650 * secondsPerDay, 3650 * secondsPerDay}) {
		t.Errorf("upper bounds: %v", got)
	}
	for name, c := range map[string]struct {
		deposit                   int64
		dormancy, exitDelay, hold int
	}{
		"no deposit":           {0, 90, 60, 30},
		"negative deposit":     {-1, 90, 60, 30},
		"no dormancy":          {1, 0, 60, 30},
		"dormancy too long":    {1, 3651, 60, 30},
		"exit delay too short": {1, 90, 6, 30},
		"exit delay too long":  {1, 90, 3651, 30},
		"negative bond hold":   {1, 90, 60, -1},
		"bond hold too long":   {1, 90, 60, 3651},
	} {
		if !panicsWith(func() { checkParams(c.deposit, c.dormancy, c.exitDelay, c.hold) }, ErrSetting) {
			t.Errorf("%s: not refused", name)
		}
	}
}

func TestCheckPresets(t *testing.T) {
	if got := checkPresets(1, 2, 3, 4); got != [4]int64{1, 2, 3, 4} {
		t.Errorf("checkPresets = %v", got)
	}
	for name, p := range map[string][4]int64{
		"zero":        {0, 2, 3, 4},
		"negative":    {-1, 2, 3, 4},
		"equal pair":  {1, 2, 2, 4},
		"last equal":  {1, 2, 3, 3},
		"first equal": {1, 1, 3, 4},
		"descending":  {4, 3, 2, 1},
	} {
		if !panicsWith(func() { checkPresets(p[0], p[1], p[2], p[3]) }, ErrSetting) {
			t.Errorf("%s: not refused", name)
		}
	}
}

func TestCheckOutsideBolo(t *testing.T) {
	checkOutsideBolo(testutils.TestAddress("treasurer"))
	campaign := escrowAddr(9)
	derived.Set(campaign.String(), true)
	defer derived.Remove(campaign.String())
	for name, a := range map[string]address{
		"the realm":              realmAddr(),
		"slashed":                slashedAddr(),
		"the storage deposit":    depositAddr(),
		"the registry":           registryAddr(),
		"the registry's deposit": registryDepositAddr(),
		"a campaign's escrow":    campaign,
		"malformed":              "g1notanaddress",
	} {
		if !panicsWith(func() { checkOutsideBolo(a) }, ErrSetting) {
			t.Errorf("%s: not refused", name)
		}
	}
}

func TestCheckNewCategory(t *testing.T) {
	checkNewCategory("orchard")
	checkNewCategory("abc")
	checkNewCategory("abcdefghijklmnopqrst")
	for name, code := range map[string]string{
		"too short":      "ab",
		"too long":       "abcdefghijklmnopqrstu",
		"capitals":       "Orchard",
		"a digit":        "orchard2",
		"a space":        "or chard",
		"already listed": "water",
	} {
		if !panicsWith(func() { checkNewCategory(code) }, ErrSetting) {
			t.Errorf("%s: not refused", name)
		}
	}
	// The 50th fits, the 51st doesn't (API §3.6, INV-9).
	saved := categoryOrder
	defer func() { categoryOrder = saved }()
	for len(categoryOrder) < 49 {
		categoryOrder = append(categoryOrder, "filler")
	}
	checkNewCategory("orchard")
	categoryOrder = append(categoryOrder, "orchard")
	if !panicsWith(func() { checkNewCategory("grove") }, ErrSetting) {
		t.Errorf("a 51st category: not refused")
	}
}

// restoreSettings puts back what TestAdministration changes.
func restoreSettings(a, pending address, p Params, pr [4]int64, minimum, ceiling int64, tips address, pause, sun bool, order []string) {
	admin, pendingAdmin, params, presets = a, pending, p, pr
	minDonation, escrowCap, tipRecipient, paused, sunset = minimum, ceiling, tips, pause, sun
	for _, code := range categoryOrder[len(order):] {
		categories.Remove(code)
	}
	categoryOrder = order
}
