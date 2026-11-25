package heirloom

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

type handover struct {
	To         address
	WillID     int
	ReturnedAt time.Time
}

type succession struct {
	handovers avl.Tree
	returns   avl.Tree
	declined  avl.Tree
}

type adminOutcome int

const (
	adminPending adminOutcome = iota
	adminHandedOverHere
	adminHandedOverByAnother
	adminReturned
	adminNoSuccessor
	adminStaysWithOwner
)

func handoverOf(owner address) (handover, bool) {
	h, ok := state.rights.handovers.Get(owner.String()).(handover)
	return h, ok
}

func holderOf(addr address) address {
	for {
		h, ok := handoverOf(addr)
		if !ok {
			return addr
		}
		addr = h.To
	}
}

func canHandOver(w *Will) bool {
	if _, done := handoverOf(w.Owner); done || w.Successor == "" {
		return false
	}
	return holderOf(w.Successor) != w.Owner
}

func recordHandover(w *Will) bool {
	if !canHandOver(w) {
		return false
	}
	state.rights.handovers.Set(w.Owner.String(), handover{To: w.Successor, WillID: w.ID})
	return true
}

func mustReturnRights(owner, by address) handover {
	h, ok := handoverOf(owner)
	if !ok || h.To != by {
		panic("you do not hold the admin rights of " + owner.String() + " by a handover from them")
	}
	state.rights.handovers.Remove(owner.String())
	h.ReturnedAt = time.Now()
	state.rights.returns.Set(willKey(h.WillID), h)
	return h
}

func declineKey(owner, successor address) string {
	return owner.String() + "/" + successor.String()
}

func hasDeclined(owner, successor address) bool {
	return state.rights.declined.Has(declineKey(owner, successor))
}

func recordDecline(owner, successor address) {
	state.rights.declined.Set(declineKey(owner, successor), true)
}

func adminOutcomeOf(w *Will) (adminOutcome, handover) {
	if h, ok := state.rights.returns.Get(willKey(w.ID)).(handover); ok {
		return adminReturned, h
	}
	if h, done := handoverOf(w.Owner); done {
		if h.WillID == w.ID {
			return adminHandedOverHere, h
		}
		return adminHandedOverByAnother, h
	}
	if w.Successor == "" {
		return adminNoSuccessor, handover{}
	}
	if w.isReleased() || !canHandOver(w) {
		return adminStaysWithOwner, handover{}
	}
	return adminPending, handover{}
}
