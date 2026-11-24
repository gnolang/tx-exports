package heirloom

import (
	"strconv"
	"time"

	"gno.land/p/nt/avl/pager/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const listPageLen = 20

func newWill(owner address, heirs []*Heir, silence time.Duration) *Will {
	w := &Will{
		ID:       int(state.lastID.Next()),
		Owner:    owner,
		Silence:  silence,
		LastSeen: time.Now(),
	}
	state.wills.Set(willKey(w.ID), w)
	state.activeByOwner.Set(owner.String(), w)
	indexWill(&state.ownerWills, owner, w.ID)
	indexHeirs(w, heirs)
	return w
}

func setSuccessor(w *Will, successor address) {
	if h, done := handoverOf(w.Owner); done && successor != "" {
		panic("will " + strconv.Itoa(h.WillID) + " already handed your admin rights to " + h.To.String())
	}
	if w.Successor != "" {
		unindexWill(&state.successorWills, w.Successor, w.ID)
	}
	w.Successor = successor
	if successor != "" {
		indexWill(&state.successorWills, successor, w.ID)
	}
}

func getWill(id int) *Will {
	w, _ := state.wills.Get(willKey(id)).(*Will)
	return w
}

func getActiveWill(owner address) *Will {
	w, _ := state.activeByOwner.Get(owner.String()).(*Will)
	return w
}

func willKey(id int) string {
	return seqid.ID(id).Binary()
}

func indexHeirs(w *Will, heirs []*Heir) {
	for _, h := range w.Heirs {
		unindexWill(&state.heirWills, h.Addr, w.ID)
	}
	w.Heirs = heirs
	for _, h := range heirs {
		indexWill(&state.heirWills, h.Addr, w.ID)
	}
}

func deactivate(w *Will) {
	state.activeByOwner.Remove(w.Owner.String())
}

func removeWill(w *Will) {
	for _, h := range w.Heirs {
		unindexWill(&state.heirWills, h.Addr, w.ID)
	}
	unindexWill(&state.ownerWills, w.Owner, w.ID)
	if w.Successor != "" {
		unindexWill(&state.successorWills, w.Successor, w.ID)
	}
	deactivate(w)
	state.wills.Remove(willKey(w.ID))
}

func willsMadeBy(addr address, page int) ([]*Will, bool) {
	return willPage(&state.ownerWills, addr, page)
}

func willsNaming(addr address, page int) ([]*Will, bool) {
	return willPage(&state.heirWills, addr, page)
}

func willsPassingRightsTo(addr address, page int) ([]*Will, bool) {
	return willPage(&state.successorWills, addr, page)
}

func willPage(index *avl.Tree, addr address, page int) ([]*Will, bool) {
	ids, ok := index.Get(addr.String()).(*avl.Tree)
	if !ok {
		return nil, false
	}
	p := pager.NewPager(ids, listPageLen, true).GetPage(page)
	ws := make([]*Will, 0, len(p.Items))
	for _, item := range p.Items {
		if w, ok := state.wills.Get(item.Key).(*Will); ok {
			ws = append(ws, w)
		}
	}
	return ws, p.HasNext
}

func activeCount() int {
	return state.activeByOwner.Size()
}

func indexWill(index *avl.Tree, addr address, id int) {
	ids, ok := index.Get(addr.String()).(*avl.Tree)
	if !ok {
		ids = &avl.Tree{}
		index.Set(addr.String(), ids)
	}
	ids.Set(willKey(id), true)
}

func unindexWill(index *avl.Tree, addr address, id int) {
	ids, ok := index.Get(addr.String()).(*avl.Tree)
	if !ok {
		return
	}
	ids.Remove(willKey(id))
	if ids.Size() == 0 {
		index.Remove(addr.String())
	}
}
