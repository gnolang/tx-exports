package bolo

import (
	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// maxDeadlineDays bounds how far ahead a deadline may be, so no timer computed from
// it can overflow (API §3.1).
const maxDeadlineDays = 3650

// CreateCampaign opens a campaign, which you organize, and returns its ID. Send the
// creation deposit with it — Bolo's "Start a campaign" link attaches it — and it comes
// back when the campaign completes. title and description are public, and the
// description may hold links, never an image. category is one of Bolo's categories.
// imageCID and imageAlt are a photo on IPFS and what it shows, or both empty.
// beneficiary is the address the money goes to, which can never change. goal is in
// ugnot, 0 for none. mode is "escrow" or "direct". deadline is a Unix time, 0 for
// none.
//
// It opens a campaign for its caller, the organizer (API §3.1). The envelope is
// exactly the creation deposit, which goes to the campaign's bond address: the realm
// keeps nothing (INV-3).
func CreateCampaign(cur realm, title, description, category, imageCID, imageAlt string, beneficiary address, goal int64, mode string, deadline int64) string {
	assertCurrent(cur)
	if !cur.Previous().IsUserCall() {
		panic(ErrNotUserCall)
	}
	runtime.AssertOriginCall()
	if envelopeUgnot() != params.CreationDeposit {
		panic(ErrDepositMismatch)
	}
	if paused {
		panic(ErrPaused)
	}
	if sunset {
		panic(ErrSunset)
	}
	text := checkCampaignText(title, description, imageCID, imageAlt)
	checkCampaignTerms(category, mode, goal, deadline)
	checkBeneficiary(beneficiary, nextID+1)

	id := nextID.Next()
	c := &campaign{
		id:          id,
		category:    category,
		organizer:   cur.Previous().Address(),
		beneficiary: beneficiary,
		mode:        mode,
		goal:        goal,
		deadline:    deadline,
		createdAt:   now(),
		params:      params,

		text:  text,
		state: &campaignState{status: statusOpen, listed: true},

		contributions: avl.NewTree(),
		receipts:      avl.NewTree(),
		withdrawals:   avl.NewTree(),
		refunds:       avl.NewTree(),
		updates:       avl.NewTree(),
	}
	key := id.Binary()
	campaigns.Set(key, c)
	stats.open++
	derived.Set(escrowAddr(id).String(), true)
	derived.Set(bondAddr(id).String(), true)
	addActive(c)
	byOrganizer.Set(c.organizer.String()+"/"+key, true)
	byBeneficiary.Set(beneficiary.String()+"/"+key, true)

	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr(), bondAddr(id), chain.NewCoins(chain.NewCoin("ugnot", c.params.CreationDeposit)))
	chain.Emit(evCampaignCreated,
		"id", idString(id),
		"organizer", c.organizer.String(),
		"beneficiary", beneficiary.String(),
		"mode", mode,
		"category", category,
		"goal", itoa(goal),
		"deadline", itoa(deadline),
	)
	return idString(id)
}

// checkCampaignText checks a campaign's text (API §2.3) and returns it normalized:
// the title, the story, and the photo with its description.
func checkCampaignText(title, description, imageCID, imageAlt string) *campaignText {
	title = checkText(title, titleMin, titleMax, false, ErrTitle)
	description = checkStory(description, 0, descriptionMax, ErrDescription)
	imageCID, imageAlt = checkImage(imageCID, imageAlt)
	return &campaignText{title: title, description: description, imageCID: imageCID, imageAlt: imageAlt}
}

// checkCampaignTerms refuses a category not listed, a mode that isn't one, a
// negative goal, and a deadline neither 0 nor in the future, at most maxDeadlineDays
// ahead (API §3.1).
func checkCampaignTerms(category, mode string, goal, deadline int64) {
	if !categories.Has(category) {
		panic(ErrCategory)
	}
	if mode != modeDirect && mode != modeEscrow {
		panic(ErrMode)
	}
	if goal < 0 {
		panic(ErrGoal)
	}
	if deadline != 0 && (deadline <= now() || deadline > now()+maxDeadlineDays*secondsPerDay) {
		panic(ErrDeadline)
	}
}

// checkBeneficiary refuses a malformed address (C12) and every address a campaign
// must never pay (API §1): the realm's, slashed, the storage-deposit address, the
// registry and its storage-deposit address, every escrow and bond address handed
// out — and those of id, the campaign about to be created, which paying itself
// would trap every gift.
func checkBeneficiary(b address, id seqid.ID) {
	checkAddress(b, ErrBeneficiary)
	if b == realmAddr() || b == slashedAddr() || b == depositAddr() || b == registryAddr() || b == registryDepositAddr() ||
		derived.Has(b.String()) || b == escrowAddr(id) || b == bondAddr(id) {
		panic(ErrBeneficiary)
	}
}
