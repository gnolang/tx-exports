// Package party is the Shoal crew book. Members share a fight and do not
// bite each other. This realm holds no ugnot. The fish realm pays a kill.
// Not deployed.
package party

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
)

const (
	partyCap = 8
	nameMax  = 16
)

type crew struct {
	id      int
	name    string
	leader  address
	members []address
	closed  bool
}

var (
	crews   []*crew
	seat    map[address]int
	invited map[address]int
	nextPID int
)

func Create(cur realm, name string) int {
	caller := requireUser(cur)
	takeExact(0)
	if seatOf(caller) != 0 {
		panic("party: seat")
	}
	clean := cleanName(name)
	if clean == "" || taken(clean) {
		panic("party: name")
	}
	ensure()
	nextPID++
	id := nextPID
	body := &crew{
		id:      id,
		name:    clean,
		leader:  caller,
		members: []address{caller},
	}
	for len(crews) <= id {
		crews = append(crews, nil)
	}
	crews[id] = body
	seat[caller] = id
	chain.Emit("Create", "id", strconv.Itoa(id), "leader", caller.String(), "name", clean)
	return id
}

func Invite(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	if !who.IsValid() {
		panic("party: addr")
	}
	if who == caller {
		panic("party: self")
	}
	id := seatOf(caller)
	body := openCrew(id)
	if seatOf(who) != 0 {
		panic("party: seat")
	}
	if len(body.members) >= partyCap {
		panic("party: full")
	}
	ensure()
	invited[who] = id
	chain.Emit("Invite", "id", strconv.Itoa(id), "who", who.String())
}

func Accept(cur realm) int {
	caller := requireUser(cur)
	takeExact(0)
	if seatOf(caller) != 0 {
		panic("party: seat")
	}
	id := 0
	if invited != nil {
		id = invited[caller]
	}
	body := openCrew(id)
	if len(body.members) >= partyCap {
		panic("party: full")
	}
	delete(invited, caller)
	body.members = append(body.members, caller)
	seat[caller] = id
	chain.Emit("Join", "id", strconv.Itoa(id), "who", caller.String())
	return id
}

func Leave(cur realm) {
	caller := requireUser(cur)
	takeExact(0)
	id := seatOf(caller)
	body := openCrew(id)
	dropMember(body, caller)
	chain.Emit("Leave", "id", strconv.Itoa(id), "who", caller.String())
}

func Kick(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	id := seatOf(caller)
	body := openCrew(id)
	if body.leader != caller {
		panic("party: leader")
	}
	if who == caller || seatOf(who) != id {
		panic("party: member")
	}
	dropMember(body, who)
	chain.Emit("Kick", "id", strconv.Itoa(id), "who", who.String())
}

func Disband(cur realm) {
	caller := requireUser(cur)
	takeExact(0)
	id := seatOf(caller)
	body := openCrew(id)
	if body.leader != caller {
		panic("party: leader")
	}
	for _, member := range body.members {
		delete(seat, member)
	}
	body.members = nil
	body.closed = true
	body.name = ""
	dropInvites(id)
	chain.Emit("Disband", "id", strconv.Itoa(id))
}

func PartyOf(cur realm, who address) int {
	takeExact(0)
	return seatOf(who)
}

func SameParty(cur realm, a, b address) bool {
	takeExact(0)
	id := seatOf(a)
	return id != 0 && id == seatOf(b)
}

func NameOf(cur realm, id int) string {
	takeExact(0)
	return openCrew(id).name
}

func LeaderOf(cur realm, id int) address {
	takeExact(0)
	return openCrew(id).leader
}

func MemberCount(cur realm, id int) int {
	takeExact(0)
	return len(openCrew(id).members)
}

func MemberAt(cur realm, id, index int) address {
	takeExact(0)
	body := openCrew(id)
	if index < 0 || index >= len(body.members) {
		panic("party: index")
	}
	return body.members[index]
}

func requireUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("party: eoa")
	}
	return cur.Previous().Address()
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("party: payment")
		}
		return
	}
	panic("party: payment")
}

func ensure() {
	if seat == nil {
		seat = make(map[address]int)
	}
	if invited == nil {
		invited = make(map[address]int)
	}
}

func seatOf(who address) int {
	if seat == nil || !who.IsValid() {
		return 0
	}
	return seat[who]
}

func openCrew(id int) *crew {
	if id < 1 || id >= len(crews) || crews[id] == nil || crews[id].closed {
		panic("party: none")
	}
	return crews[id]
}

func taken(name string) bool {
	for _, body := range crews {
		if body != nil && !body.closed && body.name == name {
			return true
		}
	}
	return false
}

func cleanName(name string) string {
	if len(name) < 1 || len(name) > nameMax {
		return ""
	}
	for _, c := range name {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != ' ' {
			return ""
		}
	}
	return name
}

func dropMember(body *crew, who address) {
	next := make([]address, 0, len(body.members))
	for _, member := range body.members {
		if member != who {
			next = append(next, member)
		}
	}
	delete(seat, who)
	if invited != nil {
		delete(invited, who)
	}
	if len(next) == 0 {
		body.members = nil
		body.closed = true
		body.name = ""
		dropInvites(body.id)
		return
	}
	body.members = next
	body.leader = next[0]
}

func dropInvites(id int) {
	if invited == nil {
		return
	}
	var drop []address
	for who, pid := range invited {
		if pid == id {
			drop = append(drop, who)
		}
	}
	for _, who := range drop {
		delete(invited, who)
	}
}
