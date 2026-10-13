package bolo

import (
	"chain"
	"chain/banker"
	"math"
	"strings"
	"testing"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

const testCID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"

// storeCampaign stores c as CreateCampaign leaves a campaign, in campaigns and the
// active indexes, and returns its ID and what removes it again. The organizer's
// writes are called straight from each test's body, as AssertOriginCall requires
// (plan §3.3); their refusals are in txtar (organizer.txtar).
func storeCampaign(c *campaign) (string, func()) {
	key := c.id.Binary()
	campaigns.Set(key, c)
	active.Set(key, true)
	activeByCategory.Set(c.category+"/"+key, true)
	return idString(c.id), func() {
		campaigns.Remove(key)
		dropActive(c)
	}
}

func TestPostBond(cur realm, t *testing.T) {
	c := testCampaign(9101, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	rb := banker.NewReadonlyBanker()
	bondBefore, realmBefore := rb.GetCoin(bondAddr(c.id), "ugnot"), rb.GetCoin(realmAddr(), "ugnot")

	testing.SetRealm(testing.NewUserRealm(c.organizer))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 500)))
	PostBond(cross(cur), id)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 300)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 300)))
	PostBond(cross(cur), id)

	// The bond grew by both envelopes, at the bond address; the realm keeps nothing
	// (INV-3).
	if c.state.bond != 800 || GetCampaign(id).Bond != 800 {
		t.Errorf("bond = %d, want 800", c.state.bond)
	}
	if got := rb.GetCoin(bondAddr(c.id), "ugnot") - bondBefore; got != 800 {
		t.Errorf("the bond address got %d, want 800", got)
	}
	if got := rb.GetCoin(realmAddr(), "ugnot"); got != realmBefore {
		t.Errorf("the realm holds %d, it held %d", got, realmBefore)
	}
}

func TestCheckBond(t *testing.T) {
	defer func(p bool) { paused = p }(paused)
	c := testCampaign(9102, modeEscrow, 0)
	checkBond(c, 1)
	c.state.bond = math.MaxInt64 - 5
	checkBond(c, 5)
	for name, k := range map[string]struct {
		status  string
		slashed bool
		paused  bool
		bond    int64
		amount  int64
		err     Error
	}{
		"nothing sent":             {statusOpen, false, false, 0, 0, ErrBadAmount},
		"a negative amount":        {statusOpen, false, false, 0, -1, ErrBadAmount},
		"closed":                   {statusClosed, false, false, 0, 1, ErrCampaignClosed},
		"settled":                  {statusSettled, false, false, 0, 1, ErrCampaignSettled},
		"slashed":                  {statusOpen, true, false, 0, 1, ErrBondSlashed},
		"paused":                   {statusOpen, false, true, 0, 1, ErrPaused},
		"past int64":               {statusOpen, false, false, math.MaxInt64 - 5, 6, ErrBadAmount},
		"nothing sent, and closed": {statusClosed, false, false, 0, 0, ErrBadAmount},
		"closed, and slashed":      {statusClosed, true, false, 0, 1, ErrCampaignClosed},
		"slashed, and paused":      {statusOpen, true, true, 0, 1, ErrBondSlashed},
	} {
		c.state.status, c.state.bondSlashed, c.state.bond = k.status, k.slashed, k.bond
		paused = k.paused
		if !panicsWith(func() { checkBond(c, k.amount) }, k.err) {
			t.Errorf("%s: not %s", name, k.err)
		}
	}
}

func TestAssertOpen(t *testing.T) {
	c := testCampaign(9103, modeEscrow, 0)
	assertOpen(c)
	for status, err := range map[string]Error{statusClosed: ErrCampaignClosed, statusSettled: ErrCampaignSettled} {
		c.state.status = status
		if !panicsWith(func() { assertOpen(c) }, err) {
			t.Errorf("%s: not %s", status, err)
		}
	}
}

func TestPostUpdate(cur realm, t *testing.T) {
	defer func(p bool) { paused = p }(paused)
	c := testCampaign(9104, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.SkipHeights(10 * heightsPerDay)

	testing.SetRealm(testing.NewUserRealm(c.organizer))
	if seq := PostUpdate(cross(cur), id, "  Day one:\r\nthe pump is ordered.  "); seq != "1" {
		t.Fatalf("first update: seq %q, want \"1\"", seq)
	}
	u := c.updates.Get(seqid.ID(1).Binary()).(*update)
	if u.seq != 1 || u.at != now() || u.body != "Day one:\nthe pump is ordered." {
		t.Errorf("stored update = %v", *u)
	}
	// An update resets the dormancy clock.
	if s := c.state; s.updateCount != 1 || s.lastUpdateAt != now() || dormantAt(c) != now()+c.params.DormancyPeriod {
		t.Errorf("after an update: count %d, last %d, dormant at %d", s.updateCount, s.lastUpdateAt, dormantAt(c))
	}

	// In every status, and while paused.
	c.state.status = statusSettled
	paused = true
	if seq := PostUpdate(cross(cur), id, "The surgery went well."); seq != "2" {
		t.Errorf("update on a settled campaign, paused: seq %q, want \"2\"", seq)
	}
	if c.state.updateCount != 2 || c.updates.Size() != 2 {
		t.Errorf("%d updates counted, %d stored, want 2", c.state.updateCount, c.updates.Size())
	}
}

func TestCheckUpdate(t *testing.T) {
	if got := checkStory(" News ", updateMin, updateMax, ErrUpdate); got != "News" {
		t.Errorf("checkStory = %q", got)
	}
	for name, body := range map[string]string{
		"empty":            "",
		"spaces":           "   \n  ",
		"an accent alone":  "́",
		"one too many":     strings.Repeat("a", updateMax+1),
		"invisible filler": "ㅤ⠀",
	} {
		if !panicsWith(func() { checkStory(body, updateMin, updateMax, ErrUpdate) }, ErrUpdate) {
			t.Errorf("%s: not ErrUpdate", name)
		}
	}
	if !panicsWith(func() { checkStory("![x](https://example.com/x.png)", updateMin, updateMax, ErrUpdate) }, ErrMarkup) {
		t.Errorf("an image in an update: not ErrMarkup")
	}
}

func TestHideImage(cur realm, t *testing.T) {
	// The organizer hides the photo; the CID stays, and hiding again changes nothing.
	c := testCampaign(9105, modeEscrow, 0)
	c.text = &campaignText{title: "Clean water", imageCID: testCID, imageAlt: "The well"}
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.SetRealm(testing.NewUserRealm(c.organizer))
	HideImage(cross(cur), id)
	if !c.state.imageHidden || c.text.imageCID != testCID || !GetCampaign(id).ImageHidden {
		t.Errorf("organizer: hidden %t, CID %q", c.state.imageHidden, c.text.imageCID)
	}
	HideImage(cross(cur), id)
	if !c.state.imageHidden {
		t.Errorf("hiding again showed the photo")
	}

	// The moderator hides another campaign's photo.
	d := testCampaign(9106, modeEscrow, 0)
	d.text = &campaignText{title: "Clean water", imageCID: testCID, imageAlt: "The well"}
	idD, unstoreD := storeCampaign(d)
	defer unstoreD()
	testing.SetRealm(testing.NewUserRealm(admin))
	HideImage(cross(cur), idD)
	if !d.state.imageHidden {
		t.Errorf("moderator: the photo isn't hidden")
	}

	// A campaign without a photo has nothing to hide.
	e := testCampaign(9107, modeEscrow, 0)
	idE, unstoreE := storeCampaign(e)
	defer unstoreE()
	testing.SetRealm(testing.NewUserRealm(e.organizer))
	HideImage(cross(cur), idE)
	if e.state.imageHidden {
		t.Errorf("a campaign without a photo got one hidden")
	}
}

var passerby = testutils.TestAddress("passerby")
