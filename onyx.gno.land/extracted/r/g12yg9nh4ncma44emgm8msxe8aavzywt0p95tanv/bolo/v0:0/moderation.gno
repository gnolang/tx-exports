package bolo

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strconv"
)

// Moderation (API §3.5): visibility, and the organizer's own bond — nothing else.
// Every write here starts with C11's realm branch, then assertSigner: the master key,
// then the admin's address, before anything is read. Then the campaign and its passed
// deadline, since a slash's window runs from closedAt. The rules live in plain
// helpers, which unit tests drive directly; the writes keep the caller checks, the
// send and the events. Withdraw, Refund and Finalize never read what is written here
// (INV-4).

// Delist takes the campaign off the active lists, with a public notice, and with slash
// moves its bond to the slashed address, where nothing ever spends it (INV-8).
// Delisting again replaces the notice, and may slash a bond not yet slashed.
func Delist(cur realm, id, notice string, slash bool) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	c := campaignOf(id)
	recordDeadline(cur, c)
	notice = checkText(notice, noticeMin, noticeMax, false, ErrNotice)
	if slash {
		bond := bookSlash(c)
		banker.NewBanker(banker.BankerTypeRealmSend, bondSub(cur, c)).SendCoins(bondAddr(c.id), slashedAddr(), chain.NewCoins(chain.NewCoin("ugnot", bond)))
	}
	s := c.state
	s.listed, s.notice = false, notice
	dropActive(c)
	chain.Emit(evDelisted, "id", idString(c.id), "notice", notice, "slashed", strconv.FormatBool(slash))
}

// bookSlash checks a slash of c's bond and enters it in the books, before the coins
// move (API §3.5), and returns what moves: the bond, never the deposit. It refuses, in
// order, no bond posted, a bond already slashed, a hold that has ended — once closed,
// BondHold after closedAt, settled or not — and a bond address holding less than the
// bond (INV-7).
func bookSlash(c *campaign) int64 {
	s := c.state
	if s.bond == 0 {
		panic(ErrNoBond)
	}
	if s.bondSlashed {
		panic(ErrBondSlashed)
	}
	if s.status != statusOpen && now() >= s.closedAt+c.params.BondHold {
		panic(ErrHoldEnded)
	}
	if banker.NewReadonlyBanker().GetCoin(bondAddr(c.id), "ugnot") < s.bond {
		panic(ErrBooksMismatch)
	}
	s.bondSlashed = true
	return s.bond
}

// Relist puts a delisted campaign back on the lists, and into the active indexes if
// it is still open (API §3.5). Its notice stays, as does a slash. Relisting a listed
// campaign changes nothing.
func Relist(cur realm, id string) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	c := campaignOf(id)
	recordDeadline(cur, c)
	s := c.state
	if s.listed {
		return
	}
	s.listed = true
	if s.status == statusOpen {
		addActive(c)
	}
	chain.Emit(evRelisted, "id", idString(c.id))
}

// SetNotice attaches a public warning to the campaign without delisting it, or clears
// it with "" (API §3.5). An unchanged notice changes nothing.
func SetNotice(cur realm, id, notice string) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	c := campaignOf(id)
	recordDeadline(cur, c)
	notice = checkNotice(c, notice)
	if notice == c.state.notice {
		return
	}
	c.state.notice = notice
	chain.Emit(evNoticeSet, "id", idString(c.id), "notice", notice)
}

// checkNotice returns notice as SetNotice stores it (API §3.5): "" clears, except on a
// delisted campaign, which keeps a public reason; any other text is normalized, 1–280
// characters. It panics with ErrNotice otherwise.
func checkNotice(c *campaign, notice string) string {
	if notice != "" {
		return checkText(notice, noticeMin, noticeMax, false, ErrNotice)
	}
	if !c.state.listed {
		panic(ErrNotice)
	}
	return ""
}

// HideMessage hides one gift's message (API §3.5): visibility only. The receipt, its
// amount and its donor stay, and so does the stored text. Hiding a hidden message, or
// a receipt without one, changes nothing.
func HideMessage(cur realm, id string, seq int64) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	c := campaignOf(id)
	recordDeadline(cur, c)
	r := receiptOf(c, seq)
	if r.message == "" || r.messageHidden {
		return
	}
	r.messageHidden = true
	chain.Emit(evMessageHidden, "id", idString(c.id), "seq", itoa(seq))
}
