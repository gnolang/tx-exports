package bolo

import (
	"chain"
	"chain/runtime"
)

// Close closes campaign id to new donations. Its organizer can, at any time; anyone
// can, once it is past its deadline or inactive for long enough — the campaign's page
// says when. Closing stops gifts only: what the campaign holds still goes to the
// beneficiary, or back to its donors.
//
// Its branch follows state, never the caller (API §3.1, Q7). Past its deadline, Close
// records the close if nothing has yet, and never fails. A dormant campaign closes as
// dormant, whoever calls. Only an open campaign nobody else may close yet takes the
// organizer's branch, which checks how the call arrived (C11) before it reads who
// sent it.
func Close(cur realm, id string) {
	assertCurrent(cur)
	c := campaignOf(id)
	recordDeadline(cur, c)
	if c.deadline != 0 && now() >= c.deadline {
		return // recorded above, now or before: housekeeping, never an error
	}
	assertOpen(c)
	if now() >= dormantAt(c) {
		closeNow(c, reasonDormant, cur.Previous().Address())
		return
	}
	if !cur.Previous().IsUserCall() {
		panic(ErrNotUserCall)
	}
	runtime.AssertOriginCall()
	if cur.Previous().Address() != c.organizer {
		panic(ErrNotClosable)
	}
	closeNow(c, reasonOrganizer, c.organizer)
}

// closeNow closes the open campaign c now, for reason, and takes it out of the
// active indexes; Closed names by, who sent the call (API §3.1, §6).
func closeNow(c *campaign, reason string, by address) {
	s := c.state
	s.status, s.closedAt, s.closeReason = statusClosed, now(), reason
	stats.open--
	dropActive(c)
	chain.Emit(evClosed, "id", idString(c.id), "reason", reason, "by", by.String())
}

// closeNotYet is CanClose's reason while only the organizer may close.
const closeNotYet = "not_yet"

// CanClose says what Close(id), sent by caller from a wallet, would do now (API
// §4): true, with the reason it would record — "deadline" or "dormant" for anyone,
// "organizer" for the organizer alone — or false, with "closed" once closed or
// settled, and "not_yet" while only the organizer may close.
func CanClose(id string, caller address) (bool, string) {
	c := campaignOf(id)
	status, _, _ := effective(c)
	switch {
	case status != statusOpen && c.state.status == statusOpen:
		return true, reasonDeadline // passed, not yet recorded
	case status != statusOpen:
		return false, statusClosed
	case now() >= dormantAt(c):
		return true, reasonDormant
	case caller == c.organizer:
		return true, reasonOrganizer
	}
	return false, closeNotYet
}
