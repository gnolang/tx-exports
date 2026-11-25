package heirloom

import (
	"strconv"
	"strings"
	"time"

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
	if successor != "" && !w.hiddenFor(successor) {
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
		if !w.hiddenFor(h.Addr) {
			indexWill(&state.heirWills, h.Addr, w.ID)
		}
	}
}

func hideWill(w *Will, addr address) {
	w.hidden.Set(addr.String(), true)
	unindexWill(&state.heirWills, addr, w.ID)
	unindexWill(&state.successorWills, addr, w.ID)
}

func unhideWill(w *Will, addr address) {
	w.hidden.Remove(addr.String())
	if w.heir(addr) != nil {
		indexWill(&state.heirWills, addr, w.ID)
	}
	if w.Successor == addr {
		indexWill(&state.successorWills, addr, w.ID)
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

func willPage(index *avl.Tree, addr address, before int) ([]*Will, bool) {
	prefix := addr.String() + "/"
	end := addr.String() + "0"
	if before > 0 {
		end = prefix + willKey(before)
	}
	var ws []*Will
	more := false
	index.ReverseIterate(prefix, end, func(key string, _ any) bool {
		if key == end {
			return false
		}
		if len(ws) == listPageLen {
			more = true
			return true
		}
		if w, ok := state.wills.Get(strings.TrimPrefix(key, prefix)).(*Will); ok {
			ws = append(ws, w)
		}
		return false
	})
	return ws, more
}

func activeCount() int {
	return state.activeByOwner.Size()
}

func indexWill(index *avl.Tree, addr address, id int) {
	index.Set(addr.String()+"/"+willKey(id), true)
}

func unindexWill(index *avl.Tree, addr address, id int) {
	index.Remove(addr.String() + "/" + willKey(id))
}
