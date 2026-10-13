package bolo

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
)

// TestClose walks each of Close's branches. Before each call, CanClose names the
// reason Close then records (API §4); the refusals are in txtar (organizer.txtar).
func TestClose(cur realm, t *testing.T) {
	closed := func(c *campaign, reason string, at int64) bool {
		s := c.state
		return s.status == statusClosed && s.closeReason == reason && s.closedAt == at && !active.Has(c.id.Binary()) &&
			!activeByCategory.Has(c.category+"/"+c.id.Binary())
	}

	// The organizer closes an open campaign, now.
	c := testCampaign(9201, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	if ok, why := CanClose(id, c.organizer); !ok || why != reasonOrganizer {
		t.Errorf("CanClose(organizer) = %t, %q", ok, why)
	}
	testing.SetRealm(testing.NewUserRealm(c.organizer))
	Close(cross(cur), id)
	if !closed(c, reasonOrganizer, now()) {
		t.Errorf("organizer: %v", *c.state)
	}
	if ok, why := CanClose(id, c.organizer); ok || why != statusClosed {
		t.Errorf("CanClose once closed = %t, %q", ok, why)
	}

	// Past dormancy, anyone closes it for dormancy, its organizer too (Q7).
	d := testCampaign(9202, modeEscrow, 0)
	idD, unstoreD := storeCampaign(d)
	defer unstoreD()
	e := testCampaign(9203, modeEscrow, 0)
	idE, unstoreE := storeCampaign(e)
	defer unstoreE()
	testing.SkipHeights(90 * heightsPerDay)
	if ok, why := CanClose(idD, passerby); !ok || why != reasonDormant {
		t.Errorf("CanClose(passerby), dormant = %t, %q", ok, why)
	}
	testing.SetRealm(testing.NewUserRealm(passerby))
	Close(cross(cur), idD)
	if !closed(d, reasonDormant, now()) {
		t.Errorf("passerby, dormant: %v", *d.state)
	}
	if ok, why := CanClose(idE, e.organizer); !ok || why != reasonDormant {
		t.Errorf("CanClose(organizer), dormant = %t, %q", ok, why)
	}
	testing.SetRealm(testing.NewUserRealm(e.organizer))
	Close(cross(cur), idE)
	if !closed(e, reasonDormant, now()) {
		t.Errorf("organizer, dormant: %v", *e.state)
	}

	// Past its deadline: closed at the deadline by whoever calls first; a second
	// call changes nothing, and fails nothing.
	f := testCampaign(9204, modeEscrow, now()+2*secondsPerDay)
	idF, unstoreF := storeCampaign(f)
	defer unstoreF()
	g := testCampaign(9205, modeEscrow, now()+2*secondsPerDay)
	idG, unstoreG := storeCampaign(g)
	defer unstoreG()
	testing.SetRealm(testing.NewUserRealm(g.organizer))
	Close(cross(cur), idG)
	closedG := now()
	testing.SkipHeights(3 * heightsPerDay)
	if ok, why := CanClose(idF, passerby); !ok || why != reasonDeadline {
		t.Errorf("CanClose(passerby), deadline = %t, %q", ok, why)
	}
	testing.SetRealm(testing.NewUserRealm(passerby))
	Close(cross(cur), idF)
	if !closed(f, reasonDeadline, f.deadline) {
		t.Errorf("passerby, deadline: %v", *f.state)
	}
	Close(cross(cur), idF)
	if !closed(f, reasonDeadline, f.deadline) {
		t.Errorf("a second close changed it: %v", *f.state)
	}
	// One the organizer closed before its deadline keeps its close after it.
	Close(cross(cur), idG)
	if !closed(g, reasonOrganizer, closedG) {
		t.Errorf("closed before its deadline, then housekept: %v", *g.state)
	}
}

// TestDormancy: dormancy counts from the latest of creation, the last gift and the
// last update, so an update resets it (API §3.1).
func TestDormancy(cur realm, t *testing.T) {
	c := testCampaign(9206, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.SkipHeights(80 * heightsPerDay)
	testing.SetRealm(testing.NewUserRealm(c.organizer))
	PostUpdate(cross(cur), id, "Still here.")
	testing.SkipHeights(90*heightsPerDay - 1)
	if ok, why := CanClose(id, passerby); ok || why != closeNotYet {
		t.Errorf("a height before 90 days from the update: %t, %q", ok, why)
	}
	testing.SkipHeights(1)
	if ok, why := CanClose(id, passerby); !ok || why != reasonDormant {
		t.Errorf("90 days from the update: %t, %q", ok, why)
	}
	c.state.lastDonationAt = now()
	if ok, why := CanClose(id, passerby); ok || why != closeNotYet {
		t.Errorf("right after a gift: %t, %q", ok, why)
	}
}

func TestCanClose(t *testing.T) {
	organizer := testutils.TestAddress("organizer")
	open := testCampaign(9211, modeEscrow, 0)
	dormant := testCampaign(9212, modeEscrow, 0)
	dormant.createdAt = now() - 90*secondsPerDay
	passed := testCampaign(9213, modeEscrow, now()-1)
	both := testCampaign(9214, modeEscrow, now()-1)
	both.createdAt = now() - 91*secondsPerDay
	recorded := testCampaign(9215, modeEscrow, now()-1)
	recorded.state.status = statusClosed
	shut := testCampaign(9216, modeEscrow, 0)
	shut.state.status = statusClosed
	settled := testCampaign(9217, modeEscrow, 0)
	settled.state.status = statusSettled
	for _, k := range []struct {
		name   string
		c      *campaign
		caller address
		ok     bool
		why    string
	}{
		{"open, organizer", open, organizer, true, reasonOrganizer},
		{"open, passerby", open, passerby, false, closeNotYet},
		{"dormant, passerby", dormant, passerby, true, reasonDormant},
		{"dormant, organizer", dormant, organizer, true, reasonDormant},
		{"deadline passed, unrecorded", passed, passerby, true, reasonDeadline},
		{"deadline passed and dormant", both, organizer, true, reasonDeadline},
		{"deadline recorded", recorded, passerby, false, statusClosed},
		{"closed", shut, organizer, false, statusClosed},
		{"settled", settled, organizer, false, statusClosed},
	} {
		id, unstore := storeCampaign(k.c)
		ok, why := CanClose(id, k.caller)
		unstore()
		if ok != k.ok || why != k.why {
			t.Errorf("%s: CanClose = %t, %q, want %t, %q", k.name, ok, why, k.ok, k.why)
		}
	}
	if !panicsWith(func() { CanClose("042", organizer) }, ErrNotFound) {
		t.Errorf("CanClose(\"042\"): not ErrNotFound")
	}
}
