package slotswitch

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const (
	appointmentSeconds = 15 * 60
	maxClinicSeconds   = 24 * 60 * 60
	maxMembers         = 12
	maxIssuedSlots     = 32
)

type slot struct {
	issuer   address
	holder   address
	start    int64
	revision int
	active   bool
}

type plan struct {
	expiry      int64
	size        int
	slots       [3]int
	old         [3]slot
	approved    [3]bool
	settled     bool
	height      int64
	confirmedAt int64
}

type clinic struct {
	issuers        [2]address
	accepted       bool
	draftRevision  int
	startsAt       int64
	endsAt         int64
	cutoff         int64
	members        map[address]string
	enrolled       []address
	slots          map[int]slot
	plans          map[int]*plan
	openByProposer map[address]int
	nextPlanID     int
}

var clinics = make(map[int]*clinic)

func signer(cur realm) address {
	caller := cur.Previous()
	if !caller.IsUserCall() || len(unsafe.OriginSend()) != 0 {
		panic("use a direct wallet call with no attached funds")
	}
	return caller.Address()
}

// Create opens a draft clinic for the two desks to review.
func Create(cur realm, other address, startsAt, endsAt, cutoff int64) int {
	runtime.AssertOriginCall()
	issuer := signer(cur)
	if issuer == "" || other == "" || issuer == other {
		panic("distinct issuers required")
	}
	if now := time.Now().Unix(); cutoff <= now || cutoff > startsAt ||
		endsAt <= startsAt || endsAt-startsAt < appointmentSeconds || endsAt-startsAt > maxClinicSeconds {
		panic("invalid clinic window or cutoff")
	}
	id := len(clinics) + 1
	clinics[id] = &clinic{
		issuers:        [2]address{issuer, other},
		draftRevision:  1,
		startsAt:       startsAt,
		endsAt:         endsAt,
		cutoff:         cutoff,
		members:        make(map[address]string),
		slots:          make(map[int]slot),
		plans:          make(map[int]*plan),
		openByProposer: make(map[address]int),
		nextPlanID:     1,
	}
	return id
}

func Enroll(cur realm, clinicID int, member address, alias string) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireClinic(clinicID)
	if caller != c.issuers[0] || c.accepted || time.Now().Unix() >= c.cutoff {
		panic("only the first issuer may enroll in an open draft")
	}
	alias = strings.TrimSpace(alias)
	if member == "" || c.members[member] != "" || len(c.enrolled) >= maxMembers ||
		len(alias) == 0 || len(alias) > 24 {
		panic("invalid team enrollment")
	}
	for _, ch := range alias {
		if !((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == ' ' || ch == '-') {
			panic("use a short public alias")
		}
	}
	for _, enrolled := range c.enrolled {
		if strings.EqualFold(c.members[enrolled], alias) {
			panic("public alias already in use")
		}
	}
	c.members[member] = alias
	c.enrolled = append(c.enrolled, member)
	c.draftRevision++
}

func Accept(cur realm, clinicID, expectedRevision int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireClinic(clinicID)
	if caller != c.issuers[1] {
		panic("invited issuer required")
	}
	if c.draftRevision != expectedRevision {
		panic("clinic draft changed since preview")
	}
	if time.Now().Unix() >= c.cutoff || len(c.enrolled) < 2 {
		panic("clinic draft expired or has fewer than two teams")
	}
	c.accepted = true
}

func Issue(cur realm, clinicID int, start int64, member address) int {
	runtime.AssertOriginCall()
	issuer := signer(cur)
	c := requireAcceptedClinic(clinicID)
	if issuer != c.issuers[0] && issuer != c.issuers[1] {
		panic("issuer required")
	}
	if start <= time.Now().Unix() || start < c.startsAt || start > c.endsAt-appointmentSeconds ||
		c.members[member] == "" || len(c.slots) >= maxIssuedSlots {
		panic("invalid slot")
	}
	for _, existing := range c.slots {
		overlap := start > existing.start-appointmentSeconds && existing.start > start-appointmentSeconds
		if existing.active && (existing.holder == member || (existing.issuer == issuer && overlap)) {
			panic("active reservation conflicts with slot or holder")
		}
	}
	id := len(c.slots) + 1
	c.slots[id] = slot{issuer: issuer, holder: member, start: start, revision: 1, active: true}
	return id
}

func CancelSlot(cur realm, clinicID, slotID int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	s := c.slots[slotID]
	if !s.active || s.issuer != caller {
		panic("active slot issuer required")
	}
	s.active = false
	s.revision++
	c.slots[slotID] = s
}

func Propose(cur realm, clinicID, first, second, third, firstRevision, secondRevision, thirdRevision int, expiry int64) int {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	now := time.Now().Unix()
	if now >= expiry || expiry > c.cutoff || expiry > now+maxClinicSeconds {
		panic("invalid expiry")
	}
	p := &plan{expiry: expiry, size: 2, slots: [3]int{first, second, third}}
	if third != 0 {
		p.size = 3
	}
	if first <= 0 || second <= 0 || first == second || first == third || second == third {
		panic("distinct slots required")
	}
	expected := [3]int{firstRevision, secondRevision, thirdRevision}
	for i := 0; i < p.size; i++ {
		s := c.slots[p.slots[i]]
		if !s.active || expiry >= s.start {
			panic("active future slots required")
		}
		if s.revision != expected[i] {
			panic("slot changed since preview")
		}
		p.old[i] = s
	}
	if p.old[0].holder != caller {
		panic("first holder must propose")
	}
	previousID := c.openByProposer[caller]
	if previousID != 0 {
		if planState(c, c.plans[previousID], now) == "open" {
			panic("withdraw or complete your open proposal")
		}
		delete(c.plans, previousID)
	}
	id := c.nextPlanID
	c.nextPlanID++
	c.plans[id] = p
	c.openByProposer[caller] = id
	return id
}

func Approve(cur realm, clinicID, planID int, approved bool) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	p := readyPlan(c, planID)
	for i := 0; i < p.size; i++ {
		if p.old[i].holder == caller {
			p.approved[i] = approved
			return
		}
	}
	panic("holder required")
}

func Withdraw(cur realm, clinicID, planID int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	if c.openByProposer[caller] != planID || planID == 0 {
		panic("open proposal owner required")
	}
	delete(c.openByProposer, caller)
	delete(c.plans, planID)
}

func Settle(cur realm, clinicID, planID int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	p := readyPlan(c, planID)
	isHolder := false
	for i := 0; i < p.size; i++ {
		if p.old[i].holder == caller {
			isHolder = true
		}
		if !p.approved[i] {
			panic("all holders must approve")
		}
	}
	if !isHolder {
		panic("holder required")
	}
	for i := 0; i < p.size; i++ {
		c.slots[p.slots[i]] = rotatedSlot(p, i)
	}
	p.settled = true
	p.height = runtime.ChainHeight()
	p.confirmedAt = time.Now().Unix()
	delete(c.openByProposer, p.old[0].holder)
}

func rotatedSlot(p *plan, destination int) slot {
	s := p.old[destination]
	source := (destination + p.size - 1) % p.size
	s.holder = p.old[source].holder
	s.revision++
	return s
}

func requireClinic(id int) *clinic {
	c := clinics[id]
	if c == nil {
		panic("unknown clinic")
	}
	return c
}

func requireAcceptedClinic(id int) *clinic {
	c := requireClinic(id)
	if !c.accepted {
		panic("second issuer has not accepted")
	}
	return c
}

func planState(c *clinic, p *plan, now int64) string {
	if p == nil {
		return "closed"
	}
	if p.settled {
		return "settled"
	}
	if now >= p.expiry {
		return "expired"
	}
	for i := 0; i < p.size; i++ {
		if c.slots[p.slots[i]] != p.old[i] {
			return "stale"
		}
	}
	return "open"
}

func readyPlan(c *clinic, id int) *plan {
	p := c.plans[id]
	state := planState(c, p, time.Now().Unix())
	if state != "open" {
		panic("proposal is " + state)
	}
	return p
}

func Reservation(clinicID, slotID int) string {
	s := requireClinic(clinicID).slots[slotID]
	return s.issuer.String() + "," + s.holder.String() + "," + strconv.Itoa(s.revision) + "," + strconv.FormatBool(s.active)
}
