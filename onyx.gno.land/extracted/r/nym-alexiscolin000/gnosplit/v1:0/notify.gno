package gnosplit

import (
	"chain"

	"gno.land/p/nym-alexiscolin000/gnosplit/ledger/v0"
	gnotif "gno.land/r/nym-gfanton001/gnotif/v0"
)

// Events. The first ones say what changed, for indexers and apps. The notify
// ones each carry "to", a wallet: gnotif turns them into a browser
// notification for whoever opted in with that address. A notify event goes
// only to members with a wallet, never to the member who acted.
const (
	EventGroupCreated = "GroupCreated"
	EventMemberAdded  = "MemberAdded"
	EventMemberLinked = "MemberLinked"
	EventEntryAdded   = "EntryAdded"
	EventEntryDeleted = "EntryDeleted"
	EventGroupMoved   = "GroupMoved"
	EventOwnerOffered = "OwnerOffered"
	EventOwnerChanged = "OwnerChanged"
	EventSuccessorSet = "SuccessorSet"

	NotifyExpense  = "Expense"  // to, group, gname, by, title, share
	NotifyIncome   = "Income"   // to, group, gname, by, title, share
	NotifyTransfer = "Transfer" // to, group, gname, from, peer, amount
	NotifyReminder = "Reminder" // to, group, gname, by, amount
	NotifyJoined   = "Joined"   // to, group, gname, by
)

// declareTriggers registers the notify events with gnotif at deploy. The
// registry marks them verified, since this realm declares its own.
// ponytail: gnotif is a v0 on onyx; a new registry version means a new
// release of this realm, which is why every gnotif call lives in this file.
func declareTriggers(cur realm) {
	triggers := [][2]string{
		{NotifyExpense, "{by} added {title}. Your share: {share}"},
		{NotifyIncome, "{by} recorded {title}. You get back {share}"},
		{NotifyTransfer, "{from} paid {peer} {amount}"},
		{NotifyReminder, "{by} reminds you that you owe {amount}"},
		{NotifyJoined, "{by} added you to the group"},
	}
	for _, t := range triggers {
		gnotif.Declare(cross(cur), self, t[0], "", "to", "{gname}", t[1], hub+":{group}")
	}
}

func notifyEntry(g *Group, e *Entry, by int) {
	if e.Kind == KindTransfer {
		for _, i := range []int{e.Payer, e.Who[0]} {
			if to := g.Members[i].Addr; to != "" && i != by {
				chain.Emit(NotifyTransfer, "to", to.String(), "group", itoa(g.ID), "gname", g.Name,
					"from", g.Members[e.Payer].Name, "peer", g.Members[e.Who[0]].Name, "amount", g.money(e.Total))
			}
		}
		return
	}
	event := NotifyExpense
	if e.Kind == KindIncome {
		event = NotifyIncome
	}
	for k, i := range e.Who {
		if to := g.Members[i].Addr; to != "" && i != by {
			share := e.Owe[k]
			if share < 0 {
				share = -share
			}
			chain.Emit(event, "to", to.String(), "group", itoa(g.ID), "gname", g.Name,
				"by", g.Members[by].Name, "title", e.Title, "share", g.money(share))
		}
	}
}

func notifyReminder(g *Group, m *Member, by string) {
	chain.Emit(NotifyReminder, "to", m.Addr.String(), "group", itoa(g.ID), "gname", g.Name,
		"by", by, "amount", g.money(-m.Bal))
}

func notifyJoined(g *Group, a address, by string) {
	chain.Emit(NotifyJoined, "to", a.String(), "group", itoa(g.ID), "gname", g.Name, "by", by)
}

// money writes cents with the group's currency: "42.50 €".
func (g *Group) money(c int64) string { return ledger.Format(c) + " " + g.Currency }
