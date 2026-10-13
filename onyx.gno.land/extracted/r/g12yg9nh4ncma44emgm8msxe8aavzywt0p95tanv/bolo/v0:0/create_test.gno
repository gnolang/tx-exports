package bolo

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

// TestCreateCampaign creates campaigns as a user, straight from the test's body as
// AssertOriginCall requires (plan §3.3), with the envelope and the realm's coins a
// real transaction would bring. Its refusals are in txtar (create.txtar): a test
// can't recover a crossing call's panic.
func TestCreateCampaign(cur realm, t *testing.T) {
	defer restoreCampaigns(nextID)
	defer restoreSettings(admin, pendingAdmin, params, presets, minDonation, escrowCap, tipRecipient, paused, sunset, categoryOrder)

	organizer := testutils.TestAddress("organizer")
	beneficiary := testutils.TestAddress("beneficiary")
	deposit := params.CreationDeposit
	first := nextID + 1

	testing.SetRealm(testing.NewUserRealm(organizer))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", deposit)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", deposit)))
	id := CreateCampaign(cross(cur), "  Clean water for Ndiaganiao ", "A pump.", "water", "", "", beneficiary, 1_500_000_000, modeEscrow, 0)
	if id != idString(first) {
		t.Fatalf("CreateCampaign returned %q, want %q", id, idString(first))
	}

	// The deposit went to the bond address; the realm keeps nothing (INV-3).
	rb := banker.NewReadonlyBanker()
	if got := rb.GetCoin(bondAddr(first), "ugnot"); got != deposit {
		t.Errorf("bond address holds %d, want the deposit %d", got, deposit)
	}
	if got := rb.GetCoin(realmAddr(), "ugnot"); got != 0 {
		t.Errorf("the realm kept %d", got)
	}

	v := GetCampaign(id)
	want := CampaignView{
		ID: id, Title: "Clean water for Ndiaganiao", Description: "A pump.", Category: "water",
		Organizer: organizer, Beneficiary: beneficiary, Mode: modeEscrow, Status: statusOpen, Listed: true,
		Goal: 1_500_000_000, Deposit: deposit, CreatedAt: now(),
		ClosableByAnyoneAt: now() + params.DormancyPeriod,
		EscrowAddress:      escrowAddr(first), BondAddress: bondAddr(first), Params: params,
	}
	if v != want {
		t.Errorf("GetCampaign =\n%v\nwant\n%v", v, want)
	}
	key := first.Binary()
	for name, tree := range map[string]*avl.Tree{
		"campaigns":        &campaigns,
		"active":           &active,
		"activeByCategory": &activeByCategory,
		"byOrganizer":      &byOrganizer,
		"byBeneficiary":    &byBeneficiary,
	} {
		k := key
		switch name {
		case "activeByCategory":
			k = "water/" + key
		case "byOrganizer":
			k = organizer.String() + "/" + key
		case "byBeneficiary":
			k = beneficiary.String() + "/" + key
		}
		if !tree.Has(k) {
			t.Errorf("campaign %s is missing from %s", id, name)
		}
	}
	if !derived.Has(escrowAddr(first).String()) || !derived.Has(bondAddr(first).String()) {
		t.Errorf("campaign %s's escrow and bond addresses aren't recorded as derived", id)
	}

	// A change of Params applies to campaigns created afterwards only (INV-5).
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	SetParams(cross(cur), 3_000_000, 30, 14, 7)
	testing.SetRealm(testing.NewUserRealm(organizer))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 3_000_000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 3_000_000)))
	second := CreateCampaign(cross(cur), "A second campaign", "", "food", "", "", beneficiary, 0, modeDirect, 0)
	if v := GetCampaign(id); v.Params != want.Params || v.Deposit != deposit {
		t.Errorf("SetParams changed campaign %s: %v", id, v.Params)
	}
	if v := GetCampaign(second); v.Params != GetParams() || v.Deposit != 3_000_000 {
		t.Errorf("campaign %s didn't get the new Params: %v", second, v.Params)
	}
}

func TestCheckCampaignTerms(t *testing.T) {
	checkCampaignTerms("water", modeDirect, 0, 0)
	checkCampaignTerms("water", modeEscrow, 1, now()+1)
	checkCampaignTerms("water", modeEscrow, 1, now()+maxDeadlineDays*secondsPerDay)
	for name, c := range map[string]struct {
		category, mode string
		goal, deadline int64
		err            Error
	}{
		"unknown category":  {"rockets", modeDirect, 0, 0, ErrCategory},
		"no mode":           {"water", "", 0, 0, ErrMode},
		"unknown mode":      {"water", "both", 0, 0, ErrMode},
		"negative goal":     {"water", modeDirect, -1, 0, ErrGoal},
		"deadline now":      {"water", modeDirect, 0, now(), ErrDeadline},
		"deadline past":     {"water", modeDirect, 0, now() - 1, ErrDeadline},
		"deadline too far":  {"water", modeDirect, 0, now() + maxDeadlineDays*secondsPerDay + 1, ErrDeadline},
		"deadline negative": {"water", modeDirect, 0, -1, ErrDeadline},
	} {
		if !panicsWith(func() { checkCampaignTerms(c.category, c.mode, c.goal, c.deadline) }, c.err) {
			t.Errorf("%s: not refused with %s", name, c.err)
		}
	}
}

func TestCheckCampaignText(t *testing.T) {
	text := checkCampaignText(" Clean water ", " A pump. ", "", "")
	if text.title != "Clean water" || text.description != "A pump." {
		t.Errorf("checkCampaignText = %v", text)
	}
	for name, c := range map[string]struct {
		title, description, cid, alt string
		err                          Error
	}{
		"short title":       {"abc", "", "", "", ErrTitle},
		"image in story":    {"Clean water", "![x](u)", "", "", ErrMarkup},
		"photo without alt": {"Clean water", "", "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", "", ErrImage},
	} {
		if !panicsWith(func() { checkCampaignText(c.title, c.description, c.cid, c.alt) }, c.err) {
			t.Errorf("%s: not refused with %s", name, c.err)
		}
	}
}

func TestCheckBeneficiary(t *testing.T) {
	next := seqid.ID(7)
	checkBeneficiary(testutils.TestAddress("beneficiary"), next)
	handedOut := escrowAddr(3)
	derived.Set(handedOut.String(), true)
	defer derived.Remove(handedOut.String())
	for name, a := range map[string]address{
		"malformed":                 "g1notanaddress",
		"in capitals":               address(strings.ToUpper(string(testutils.TestAddress("beneficiary")))),
		"the realm":                 realmAddr(),
		"slashed":                   slashedAddr(),
		"the storage deposit":       depositAddr(),
		"the registry":              registryAddr(),
		"the registry's deposit":    registryDepositAddr(),
		"an escrow handed out":      handedOut,
		"the new campaign's escrow": escrowAddr(next),
		"the new campaign's bond":   bondAddr(next),
	} {
		if !panicsWith(func() { checkBeneficiary(a, next) }, ErrBeneficiary) {
			t.Errorf("%s: not refused", name)
		}
	}
}

func TestGetCampaignNotFound(t *testing.T) {
	for _, id := range []string{"", "0", "042", "+1", " 1", "999999"} {
		if !panicsWith(func() { GetCampaign(id) }, ErrNotFound) {
			t.Errorf("GetCampaign(%q): not ErrNotFound", id)
		}
	}
}

// restoreCampaigns removes every campaign created after last from every tree. IDs
// keep counting: the bank keeps the coins those campaigns' addresses got, so a later
// test's campaigns get fresh addresses.
func restoreCampaigns(last seqid.ID) {
	for id := last + 1; id <= nextID; id++ {
		v := campaigns.Get(id.Binary())
		if v == nil {
			continue
		}
		c := v.(*campaign)
		key := id.Binary()
		campaigns.Remove(key)
		active.Remove(key)
		activeByCategory.Remove(c.category + "/" + key)
		byOrganizer.Remove(c.organizer.String() + "/" + key)
		byBeneficiary.Remove(c.beneficiary.String() + "/" + key)
		derived.Remove(escrowAddr(id).String())
		derived.Remove(bondAddr(id).String())
	}
}
