package slotswitch

import (
	"chain/runtime"
	"time"
)

type transfer struct {
	clinics               [2]int
	slots                 [2]int
	before                [2]slot
	destinationGeneration [2]int
	approved              [4]bool
	expiry                int64
	terminal              string
	height                int64
	time                  int64
}

var transfers = make(map[int]*transfer)
var openTransfers = make(map[address][]int)
var nextTransferID = 1

const maxOpenTransfers = 4

// ProposeTransfer swaps two appointments across clinics. If the destination
// is vacant, the source holder moves there and the source becomes vacant.
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
	if first.holder == "" || first.holder != caller {
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
	p := &transfer{clinics: [2]int{fromClinic, toClinic}, slots: [2]int{fromSlot, toSlot},
		before: [2]slot{first, second}, expiry: expiry}
	for i, c := range [2]*clinic{from, to} {
		incoming := p.before[1-i].holder
		if incoming == "" {
			continue
		}
		if c.members[incoming] == "" {
			panic("every incoming holder must be enrolled in the destination clinic")
		}
		if c.activeByHolder[incoming] != 0 {
			panic("holder already has an active appointment in destination clinic")
		}
		p.destinationGeneration[i] = c.bookingGeneration[incoming]
	}
	if transferTimeConflict(p) {
		panic("holder has overlapping appointment")
	}
	open := keepOpenTransfers(caller, now)
	if len(open) >= maxOpenTransfers {
		panic("withdraw or complete an open transfer")
	}
	id := nextTransferID
	nextTransferID++
	transfers[id] = p
	openTransfers[caller] = append(open, id)
	return id
}

func keepOpenTransfers(proposer address, now int64) []int {
	previous := openTransfers[proposer]
	open := make([]int, 0, len(previous))
	for _, id := range previous {
		state := transferState(transfers[id], now)
		switch state {
		case "open", "blocked":
			open = append(open, id)
		case "settled":
		default:
			delete(transfers, id)
		}
	}
	return open
}

// ApproveTransfer records or revokes consent for one exact role. A wallet
// serving more than one role must send a separate approval for each role.
// Roles 0 and 1 are the current holders. Roles 2 and 3 are the slot issuers.
func ApproveTransfer(cur realm, id, role int, approved bool) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := requireTransfer(id, !approved)
	participants := transferAccounts(p)
	if role < 0 || role >= len(participants) || participants[role] == "" || participants[role] != caller {
		panic("transfer role signer required")
	}
	p.approved[role] = approved
}

func WithdrawTransfer(cur realm, id int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := requireTransfer(id, true)
	if p.before[0].holder != caller {
		panic("transfer proposer required")
	}
	p.terminal = "withdrawn"
}

func CancelTransfer(cur realm, id int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := requireTransfer(id, true)
	if p.before[0].issuer != caller && p.before[1].issuer != caller {
		panic("transfer issuer required")
	}
	p.terminal = "canceled"
}

func SettleTransfer(cur realm, id int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	p := requireTransfer(id, false)
	participating := false
	for role, account := range transferAccounts(p) {
		if account == "" {
			continue
		}
		if account == caller {
			participating = true
		}
		if !p.approved[role] {
			panic("all transfer participants must approve")
		}
	}
	if !participating {
		panic("transfer participant required")
	}
	for i, clinicID := range p.clinics {
		removeHolderBooking(clinics[clinicID], p.before[i])
	}
	// Both calendars have been rechecked. Issuers and times stay unchanged.
	for i, clinicID := range p.clinics {
		c := clinics[clinicID]
		slotID := p.slots[i]
		updated := transferredSlot(p, i)
		c.slots[slotID] = updated
		addHolderBooking(c, slotID, updated)
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

func transferTimeConflict(p *transfer) bool {
	for i, old := range p.before {
		released := bookingRef{p.clinics[i], p.slots[i], old.start}
		if old.holder != "" && scheduleConflict(holderSchedule, old.holder, p.before[1-i].start, released) {
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
		if c == nil || !c.accepted || c.slots[p.slots[i]] != p.before[i] {
			return "stale"
		}
		incoming := p.before[1-i].holder
		if incoming != "" && (c.members[incoming] == "" || c.activeByHolder[incoming] != 0 ||
			c.bookingGeneration[incoming] != p.destinationGeneration[i]) {
			return "stale"
		}
	}
	if transferTimeConflict(p) {
		return "blocked"
	}
	return "open"
}

func requireTransfer(id int, closing bool) *transfer {
	p := transfers[id]
	state := transferState(p, time.Now().Unix())
	if state != "open" && (!closing || (state != "blocked" && state != "stale")) {
		panic("transfer is " + state)
	}
	return p
}
