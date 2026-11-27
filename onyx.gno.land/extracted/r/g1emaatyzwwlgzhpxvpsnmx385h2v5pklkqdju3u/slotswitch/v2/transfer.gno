package slotswitch

import (
	"chain/runtime"
	"time"
)

type transfer struct {
	clinics  [2]int
	slots    [2]int
	before   [2]slot
	approved [4]bool
	expiry   int64
	terminal string
	height   int64
	time     int64
}

var transfers = make(map[int]*transfer)

// ProposeTransfer swaps two existing appointments in accepted v2 clinics.
// Both appointments have the same fixed duration. The affected issuers decide
// whether their appointments are suitable by approving the exact exchange.
func ProposeTransfer(cur realm, fromClinic, fromSlot, fromRevision, toClinic, toSlot, toRevision int, expiry int64) int {
	runtime.AssertOriginCall()
	caller := signer(cur)
	if fromClinic == toClinic {
		panic("distinct clinics required")
	}
	from := requireAcceptedClinic(fromClinic)
	to := requireAcceptedClinic(toClinic)
	first := from.slots[fromSlot]
	second := to.slots[toSlot]
	if !first.active || !second.active {
		panic("active appointments required")
	}
	if first.revision != fromRevision || second.revision != toRevision {
		panic("appointment changed since preview")
	}
	if first.holder != caller {
		panic("source holder must propose")
	}
	if first.issuer == second.issuer || first.holder == second.holder {
		panic("distinct issuing desks and holders required")
	}
	now := time.Now().Unix()
	if expiry <= now || expiry > now+maxClinicSeconds || expiry > from.cutoff || expiry > to.cutoff ||
		expiry >= first.start || expiry >= second.start {
		panic("invalid transfer expiry")
	}
	if from.members[second.holder] == "" || to.members[first.holder] == "" {
		panic("both holders must be enrolled in the destination clinics")
	}
	if hasActiveBooking(from, second.holder) || hasActiveBooking(to, first.holder) {
		panic("holder already has an active appointment in destination clinic")
	}
	id := len(transfers) + 1
	transfers[id] = &transfer{clinics: [2]int{fromClinic, toClinic}, slots: [2]int{fromSlot, toSlot},
		before: [2]slot{first, second}, expiry: expiry}
	return id
}

// ApproveTransfer records or revokes consent for one exact role. A wallet
// serving more than one role must send a separate approval for each role.
// Roles 0 and 1 are the current holders. Roles 2 and 3 are the slot issuers.
func ApproveTransfer(cur realm, id, role int, approved bool) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := readyTransfer(id)
	participants := transferAccounts(p)
	if role < 0 || role >= len(participants) || participants[role] != caller {
		panic("transfer role signer required")
	}
	p.approved[role] = approved
}

func WithdrawTransfer(cur realm, id int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := readyTransfer(id)
	if p.before[0].holder != caller {
		panic("transfer proposer required")
	}
	p.terminal = "withdrawn"
}

func CancelTransfer(cur realm, id int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := readyTransfer(id)
	if p.before[0].issuer != caller && p.before[1].issuer != caller {
		panic("transfer issuer required")
	}
	p.terminal = "canceled"
}

func SettleTransfer(cur realm, id int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := readyTransfer(id)
	participating := false
	for _, account := range transferAccounts(p) {
		if account == caller {
			participating = true
		}
	}
	if !participating {
		panic("transfer participant required")
	}
	for _, approved := range p.approved {
		if !approved {
			panic("both holders and both issuers must approve")
		}
	}
	// readyTransfer validated both clinics and every booking and holder before
	// either roster write. Slot ownership and times remain with the issuers.
	for i, clinicID := range p.clinics {
		clinics[clinicID].slots[p.slots[i]] = transferredSlot(p, i)
	}
	p.terminal = "settled"
	p.height = runtime.ChainHeight()
	p.time = time.Now().Unix()
}

func transferAccounts(p *transfer) [4]address {
	return [4]address{p.before[0].holder, p.before[1].holder, p.before[0].issuer, p.before[1].issuer}
}

func transferredSlot(p *transfer, index int) slot {
	s := p.before[index]
	s.holder = p.before[1-index].holder
	s.revision++
	return s
}

func hasActiveBooking(c *clinic, holder address) bool {
	for _, s := range c.slots {
		if s.active && s.holder == holder {
			return true
		}
	}
	return false
}

func transferState(p *transfer, now int64) string {
	if p == nil {
		return "closed"
	}
	if p.terminal != "" {
		return p.terminal
	}
	if now >= p.expiry {
		return "expired"
	}
	for i, clinicID := range p.clinics {
		c := clinics[clinicID]
		incoming := p.before[1-i].holder
		if c == nil || !c.accepted || c.slots[p.slots[i]] != p.before[i] ||
			c.members[incoming] == "" || hasActiveBooking(c, incoming) {
			return "stale"
		}
	}
	return "open"
}

func readyTransfer(id int) *transfer {
	p := transfers[id]
	state := transferState(p, time.Now().Unix())
	if state != "open" {
		panic("transfer is " + state)
	}
	return p
}
