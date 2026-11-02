package sugarproxy

import (
	"strconv"

	"gno.land/r/gov/dao"
)

// GovDAO's powers over sugar proxy, the last word over everything. Each Propose* below makes a GovDAO proposal
// request; a GovDAO member submits it (dao.MustCreateProposal), members vote, and when it executes, GovDAO's
// executor calls the sealed callback, which only r/gov/dao can do. A callback checks the state again (it may have
// changed since the proposal was made) and returns an error rather than panicking, so a stale proposal fails
// cleanly instead of sticking.

// ProposeAdd adds an item at once, with no veto window: GovDAO is the veto.
func ProposeAdd(cur realm, payload string) dao.ProposalRequest {
	if _, _, err := parse(payload); err != nil {
		panic(err.Error())
	}
	cb := func(cur realm) error {
		_, err := add(payload, "govdao")
		return err
	}
	return dao.NewProposalRequest("sugar proxy: add "+payload, "Adds `"+payload+"` to sugar proxy's rules, counting at once.",
		dao.NewSimpleExecutor(0, cur, cb, ""))
}

// ProposeVeto vetoes an item still in its veto window.
func ProposeVeto(cur realm, id int) dao.ProposalRequest {
	cb := func(cur realm) error { return end(id, true, "govdao") }
	return dao.NewProposalRequest("sugar proxy: veto item "+strconv.Itoa(id), describeItem(id)+" GovDAO vetoes it.",
		dao.NewSimpleExecutor(0, cur, cb, ""))
}

// ProposeRemove removes an item at once.
func ProposeRemove(cur realm, id int) dao.ProposalRequest {
	cb := func(cur realm) error { return end(id, false, "govdao") }
	return dao.NewProposalRequest("sugar proxy: remove item "+strconv.Itoa(id), describeItem(id)+" GovDAO removes it.",
		dao.NewSimpleExecutor(0, cur, cb, ""))
}

// ProposePause pauses sugar proxy (on) or resumes it: while paused, apps carry nothing and nothing new is added
// except by GovDAO.
func ProposePause(cur realm, on bool) dao.ProposalRequest {
	cb := func(cur realm) error {
		setPaused(on, "govdao")
		return nil
	}
	what := "resume"
	if on {
		what = "pause"
	}
	return dao.NewProposalRequest("sugar proxy: "+what, "GovDAO "+what+"s sugar proxy.", dao.NewSimpleExecutor(0, cur, cb, ""))
}

// ProposeDelegate names the realm that may add and remove sites ("" for none).
func ProposeDelegate(cur realm, path string) dao.ProposalRequest {
	cb := func(cur realm) error {
		delegate = path
		publish()
		return nil
	}
	return dao.NewProposalRequest("sugar proxy: delegate sites to "+path, "Names `"+path+"` as the realm that may add and "+
		"remove sugar proxy's sites (each waiting out the veto window). Empty names none.", dao.NewSimpleExecutor(0, cur, cb, ""))
}

// ProposeGuardian names the address that may veto and pause ("" for none).
func ProposeGuardian(cur realm, a address) dao.ProposalRequest {
	if a != "" && !a.IsValid() {
		panic("not an address")
	}
	cb := func(cur realm) error {
		guardian = a
		return nil
	}
	return dao.NewProposalRequest("sugar proxy: guardian "+a.String(), "Names "+a.String()+" sugar proxy's guardian, who may "+
		"veto items in their window and pause, never approve. Empty names none.", dao.NewSimpleExecutor(0, cur, cb, ""))
}

// ProposeVetoWindow sets how long an added item of a kind waits before it counts, in seconds (one hour to 60 days).
func ProposeVetoWindow(cur realm, kind string, seconds int64) dao.ProposalRequest {
	if _, ok := vetoWin[kind]; !ok || seconds < 3600 || seconds > 60*86400 {
		panic("a kind's veto window is 3600 to 5184000 seconds")
	}
	cb := func(cur realm) error {
		vetoWin[kind] = seconds
		return nil
	}
	return dao.NewProposalRequest("sugar proxy: "+kind+" veto window "+strconv.FormatInt(seconds, 10)+" s", "Sets the veto window "+
		"for a new "+kind+" to "+strconv.FormatInt(seconds, 10)+" seconds.", dao.NewSimpleExecutor(0, cur, cb, ""))
}

func describeItem(id int) string {
	it := find(id)
	if it == nil {
		return "Item " + strconv.Itoa(id) + " (none such yet)."
	}
	return "Item " + strconv.Itoa(id) + ": " + it.Kind + " `" + joinFields(it.Fields) + "`, " + it.State + "."
}

func joinFields(f []string) string {
	out := ""
	for i, x := range f {
		if i > 0 {
			out += "|"
		}
		out += x
	}
	return out
}
