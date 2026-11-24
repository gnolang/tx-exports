package heirloom

import "gno.land/p/nt/avl/v0"

type handover struct {
	To     address
	WillID int
}

type succession struct {
	handovers avl.Tree
	parent    avl.Tree
	rank      avl.Tree
	holder    avl.Tree
}

type adminOutcome int

const (
	adminPending adminOutcome = iota
	adminHandedOverHere
	adminHandedOverByAnother
	adminNoSuccessor
	adminStaysWithOwner
)

func handoverOf(owner address) (handover, bool) {
	h, ok := state.rights.handovers.Get(owner.String()).(handover)
	return h, ok
}

func groupOf(addr address) address {
	for {
		parent, ok := state.rights.parent.Get(addr.String()).(address)
		if !ok {
			return addr
		}
		addr = parent
	}
}

func groupRank(root address) int {
	rank, _ := state.rights.rank.Get(root.String()).(int)
	return rank
}

func holderOfGroup(root address) address {
	if holder, ok := state.rights.holder.Get(root.String()).(address); ok {
		return holder
	}
	return root
}

func holderOf(addr address) address {
	return holderOfGroup(groupOf(addr))
}

func joinGroups(from, to address) {
	holder := holderOfGroup(to)
	fromRank, toRank := groupRank(from), groupRank(to)
	if fromRank > toRank {
		from, to = to, from
	}
	if fromRank == toRank {
		state.rights.rank.Set(to.String(), toRank+1)
	}
	state.rights.parent.Set(from.String(), to)
	state.rights.holder.Remove(from.String())
	state.rights.holder.Set(to.String(), holder)
}

func handoverGroups(w *Will) (from, to address, ok bool) {
	if _, done := handoverOf(w.Owner); done || w.Successor == "" {
		return "", "", false
	}
	from, to = groupOf(w.Owner), groupOf(w.Successor)
	return from, to, from != to
}

func recordHandover(w *Will) bool {
	from, to, ok := handoverGroups(w)
	if !ok {
		return false
	}
	state.rights.handovers.Set(w.Owner.String(), handover{w.Successor, w.ID})
	joinGroups(from, to)
	return true
}

func adminOutcomeOf(w *Will) (adminOutcome, handover) {
	if h, done := handoverOf(w.Owner); done {
		if h.WillID == w.ID {
			return adminHandedOverHere, h
		}
		return adminHandedOverByAnother, h
	}
	if w.Successor == "" {
		return adminNoSuccessor, handover{}
	}
	if _, _, ok := handoverGroups(w); w.isReleased() || !ok {
		return adminStaysWithOwner, handover{}
	}
	return adminPending, handover{}
}
