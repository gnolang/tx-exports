package bolo

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"math"
)

// Who hid a campaign's photo: ImageHidden's by (API §6).
const (
	hiderOrganizer = "organizer"
	hiderModerator = "moderator"
)

// PostBond adds what you send to campaign id's bond: a stake its organizer may post,
// lost if Bolo's moderator delists the campaign for fraud. It is not a guarantee. The
// organizer only, while the campaign is open.
//
// It adds the envelope to the campaign's bond (API §3.1): its organizer only, by a
// direct transaction, while the campaign is open, its bond unslashed and Bolo not
// paused. The bond only grows, and the coins go on to the bond address: the
// realm keeps nothing (INV-3).
func PostBond(cur realm, id string) {
	assertCurrent(cur)
	if !cur.Previous().IsUserCall() {
		panic(ErrNotUserCall)
	}
	runtime.AssertOriginCall()
	c := campaignOf(id)
	recordDeadline(cur, c)
	if cur.Previous().Address() != c.organizer {
		panic(ErrNotOrganizer)
	}
	amount := envelopeUgnot()
	checkBond(c, amount)
	c.state.bond += amount
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr(), bondAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", amount)))
	chain.Emit(evBondPosted, "id", idString(c.id), "amount", itoa(amount), "bond", itoa(c.state.bond))
}

// checkBond refuses amount as more bond for c (API §3.1), in this order: nothing
// sent, a campaign that isn't open, a slashed bond, a paused Bolo, and a bond that
// would pass int64.
func checkBond(c *campaign, amount int64) {
	if amount <= 0 {
		panic(ErrBadAmount)
	}
	assertOpen(c)
	if c.state.bondSlashed {
		panic(ErrBondSlashed)
	}
	if paused {
		panic(ErrPaused)
	}
	if amount > math.MaxInt64-c.state.bond {
		panic(ErrBadAmount)
	}
}

// assertOpen refuses a campaign that isn't open, by its stored status:
// ErrCampaignSettled once settled, ErrCampaignClosed otherwise. A passed deadline
// is recorded before (API §3.1).
func assertOpen(c *campaign) {
	switch c.state.status {
	case statusOpen:
	case statusSettled:
		panic(ErrCampaignSettled)
	default:
		panic(ErrCampaignClosed)
	}
}

// PostUpdate posts an update on campaign id, shown under its story, and returns the
// update's number: its organizer only. body may hold links, never an image.
//
// It appends an update to the campaign (API §3.1): its organizer only, by a direct
// transaction, in every status and while paused. Updates are append-only, and each
// resets the dormancy clock.
func PostUpdate(cur realm, id, body string) string {
	assertCurrent(cur)
	if !cur.Previous().IsUserCall() {
		panic(ErrNotUserCall)
	}
	runtime.AssertOriginCall()
	c := campaignOf(id)
	recordDeadline(cur, c)
	if cur.Previous().Address() != c.organizer {
		panic(ErrNotOrganizer)
	}
	body = checkStory(body, updateMin, updateMax, ErrUpdate)
	s := c.state
	seq := s.updateSeq.Next()
	c.updates.Set(seq.Binary(), &update{seq: uint64(seq), at: now(), body: body})
	s.updateCount++
	s.lastUpdateAt = now()
	chain.Emit(evUpdatePosted, "id", idString(c.id), "seq", idString(seq))
	return idString(seq)
}

// HideImage hides campaign id's photo, for good: its organizer can, and so can Bolo's
// moderator.
//
// Its organizer may, by a direct transaction, and so may the moderator, with the
// master key — a DAO realm, once one holds the role, through C11's realm branch (API
// §3.1, §3.5). The CID stays: it is a fingerprint, and never replaced. Hiding a
// hidden photo, or a campaign with none, changes nothing.
func HideImage(cur realm, id string) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	c := campaignOf(id)
	recordDeadline(cur, c)
	by := hiderOrganizer
	if cur.Previous().Address() != c.organizer { // an organizer is a user: CreateCampaign admits no other
		assertSigner(cur, admin)
		by = hiderModerator
	}
	if c.text.imageCID == "" || c.state.imageHidden {
		return
	}
	c.state.imageHidden = true
	chain.Emit(evImageHidden, "id", idString(c.id), "by", by)
}
