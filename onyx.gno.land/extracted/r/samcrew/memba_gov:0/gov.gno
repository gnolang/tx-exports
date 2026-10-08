// Package memba_gov is the Memba DAO governance core. It holds the roster,
// proposals and votes, and grants nothing by itself: a governed realm asks
// for an approval by crossing-calling Consume before a privileged step, and
// the core checks that the caller is exactly the realm the proposal names,
// with exactly the arguments members voted on. The core never calls another
// realm.
//
// Rules (design note GOV-1, approved 2026-10-06):
//   - members propose, vote and execute by direct calls from their own
//     account, and an invited key joins by its own direct call; only a
//     governed realm's crossing call reaches Consume;
//   - a key counts toward the roster only after it signed Join itself;
//   - one action per proposal, stored by value; approvals are used once;
//   - every executed roster action and every Join invalidates every open
//     proposal, so votes always count against an unchanged roster;
//   - Consume invalidates the other open proposals of its (target, scope).
package memba_gov

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/samcrew/avl"
	"gno.land/p/samcrew/daoauth"
)

const (
	corePath  = "gno.land/r/samcrew/memba_gov"
	MaxSeats  = 25
	MinSeats  = 2
	MaxScope  = 160
	MaxNote   = 280
	MaxAction = 64

	actAddMember      = "AddMember"
	actRemoveMember   = "RemoveMember"
	actSetWeight      = "SetWeight"
	actRecover        = "Recover"
	actRemoveInactive = "RemoveInactive"
	actUninvite       = "Uninvite"

	voteYes     = "yes"
	voteNo      = "no"
	voteAbstain = "abstain"
)

type person struct {
	id         string
	addr       address
	weight     int
	lastActive int64  // unix seconds of the last Propose, Vote, Execute or Join
	rosterPid  uint64 // this person's open roster proposal, if any
}

// invite seats addr as id (a new person) or, for a recovery, gives the
// existing person id the new key addr, once addr itself calls Join.
type invite struct {
	id      string
	addr    address
	weight  int
	expires int64 // unix seconds
}

type ballot struct {
	person string
	vote   string
	since  int64 // unix start of the current uninterrupted YES streak
}

type proposal struct {
	id                    uint64
	target, action, args  string
	scope, note, proposer string
	subject               string // the person a roster action names
	class                 int
	scopeGen, globalGen   uint64
	created               int64 // unix seconds
	ballots               []ballot
	consumed              bool
}

var (
	seated    []*person
	invites   []*invite
	proposals = avl.NewTree() // padded id -> *proposal
	scopes    = avl.NewTree() // target + "\n" + scope -> uint64 generation
	lastID    uint64
	globalGen uint64
)

func init() { seedRoster() }

func seedRoster() {
	t := now()
	for _, s := range seedSeated {
		seated = append(seated, &person{id: s.id, addr: s.addr, weight: s.weight, lastActive: t})
	}
	for _, s := range seedInvited {
		invites = append(invites, &invite{id: s.id, addr: s.addr, weight: s.weight, expires: t + secs(SeedInviteTTL)})
	}
	checkRoster()
}

// now is the block time in unix seconds; every stored time uses it.
func now() int64 { return time.Now().Unix() }

func secs(d time.Duration) int64 { return int64(d / time.Second) }

// ── Writes (direct calls from a member's account) ──────────────────────

// Propose files one action. target is the realm that will consume it, or
// this realm for a roster action; scope is the invalidation key that realm
// computes for the action; class is at least the class it requires.
func Propose(cur realm, target, action, args, scope string, class int, note string) uint64 {
	m := member(cur)
	if !validTarget(target) || !validAction(action) || len(scope) > MaxScope || len(note) > MaxNote ||
		!daoauth.ValidText(scope) || !daoauth.ValidText(note) {
		panic("memba_gov: invalid target, action, scope or note")
	}
	fields, err := daoauth.Parse(args)
	if err != nil {
		panic(err.Error())
	}
	if target == corePath {
		if scope != "" || class != rosterClass(action) {
			panic("memba_gov: a roster action has no scope and a fixed class")
		}
		checkRosterAction(action, fields)
		if m.rosterPid != 0 && isOpen(m.rosterPid) {
			panic("memba_gov: you already have an open roster proposal")
		}
	} else if class < Routine || class > Critical {
		panic("memba_gov: unknown class")
	}
	lastID++
	p := &proposal{id: lastID, target: target, action: action, args: args, scope: scope, note: note,
		proposer: m.id, class: class, scopeGen: scopeGen(target, scope), globalGen: globalGen, created: now()}
	proposals.Set(key(p.id), p)
	if target == corePath {
		p.subject = fields[0].Value
		m.rosterPid = p.id
	}
	m.lastActive = p.created
	return p.id
}

// Vote records yes, no or abstain until the voting deadline. After it, a
// YES can still be withdrawn while the proposal is not executed or expired,
// so members can stop an approval they no longer back.
func Vote(cur realm, pid uint64, choice string) {
	m := member(cur)
	if choice != voteYes && choice != voteNo && choice != voteAbstain {
		panic("memba_gov: vote yes, no or abstain")
	}
	p := mustGet(pid)
	t := now()
	mine := -1
	for i, b := range p.ballots {
		if b.person == m.id {
			mine = i
		}
	}
	st, _ := state(p)
	open := st == stVoting || st == stTimelocked || st == stReady
	withdrawing := mine >= 0 && p.ballots[mine].vote == voteYes && choice != voteYes
	if !open || (t >= p.created+secs(VotingPeriod) && !withdrawing) {
		panic("memba_gov: voting is closed")
	}
	m.lastActive = t
	switch {
	case mine < 0:
		p.ballots = append(p.ballots, ballot{person: m.id, vote: choice, since: t})
	case p.ballots[mine].vote != choice:
		p.ballots[mine] = ballot{person: m.id, vote: choice, since: t}
	}
}

// Join seats the caller's invitation: a new person, or a recovered key.
func Join(cur realm) {
	addr := user(cur)
	t := now()
	for i, inv := range invites {
		if inv.addr != addr || t > inv.expires {
			continue
		}
		invites = append(invites[:i:i], invites[i+1:]...)
		if p := personByID(inv.id); p != nil {
			p.addr = addr
			p.lastActive = t
		} else {
			if len(seated) >= MaxSeats {
				panic("memba_gov: the roster is full (" + strconv.Itoa(MaxSeats) + " seats)")
			}
			seated = append(seated, &person{id: inv.id, addr: addr, weight: inv.weight, lastActive: t})
		}
		globalGen++
		checkRoster()
		return
	}
	panic("memba_gov: no open invitation for " + string(addr))
}

// Execute runs a ready roster action of this realm. The roster it was
// checked against at Propose is unchanged: any change would have
// invalidated it.
func Execute(cur realm, pid uint64) {
	m := member(cur)
	p := mustGet(pid)
	if p.target != corePath {
		panic("memba_gov: only roster actions run here; the target realm consumes the others")
	}
	if st, _ := state(p); st != stReady {
		panic("memba_gov: proposal is " + st)
	}
	fields, _ := daoauth.Parse(p.args)
	id := p.subject
	switch p.action {
	case actAddMember:
		addInvite(id, address(fields[1].Value), weightField(fields[2]), VotedInviteTTL)
	case actRecover:
		addInvite(id, address(fields[1].Value), 0, VotedInviteTTL)
	case actSetWeight:
		personByID(id).weight = weightField(fields[1])
	case actRemoveMember, actRemoveInactive, actUninvite:
		removePerson(id)
	}
	p.consumed = true
	m.lastActive = now()
	globalGen++
	checkRoster()
}

// ── The only cross-realm entry ──────────────────────────────────────────

// Consume is crossing-called by a governed realm right before the step a
// proposal approved. It panics unless the caller is exactly the proposal's
// target, the action, arguments and scope are the voted ones byte for byte,
// the class is at least minClass, the proposal is ready, and executor, the
// account that called the target directly, is a seated member. It marks the
// proposal used and invalidates the other open proposals of (target, scope).
func Consume(cur realm, pid uint64, action, args, scope string, minClass int, executor address) {
	if !cur.IsCurrent() {
		panic("memba_gov: stale realm")
	}
	caller := cur.Previous().PkgPath()
	p := mustGet(pid)
	// A roster action runs only through Execute.
	if caller != p.target || p.target == corePath {
		panic("memba_gov: proposal " + strconv.FormatUint(pid, 10) + " is not for " + caller)
	}
	if action != p.action || args != p.args || scope != p.scope {
		panic("memba_gov: action, arguments or scope differ from the vote")
	}
	if p.class < minClass {
		panic("memba_gov: class below what the target requires")
	}
	if st, _ := state(p); st != stReady {
		panic("memba_gov: proposal is " + st)
	}
	// Being named executor is not activity: the target, not the member,
	// supplies that address.
	if personByAddr(executor) == nil {
		panic("memba_gov: executor is not a seated member")
	}
	p.consumed = true
	scopes.Set(p.target+"\n"+p.scope, scopeGen(p.target, p.scope)+1)
}

// IsMember reports whether addr is a seated member's current key.
func IsMember(addr address) bool { return personByAddr(addr) != nil }

// PersonOf returns the id of the seated member whose current key is addr,
// or "". The id survives a key recovery.
func PersonOf(addr address) string {
	if p := personByAddr(addr); p != nil {
		return p.id
	}
	return ""
}

// ── Helpers ─────────────────────────────────────────────────────────────

// user returns the account that called this realm directly.
func user(cur realm) address {
	if !cur.IsCurrent() {
		panic("memba_gov: stale realm")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("memba_gov: call directly from your account")
	}
	return prev.Address()
}

func member(cur realm) *person {
	addr := user(cur)
	m := personByAddr(addr)
	if m == nil {
		panic("memba_gov: not a seated member: " + string(addr))
	}
	return m
}

// rosterClass and rosterDelay fix how each roster action passes.
func rosterClass(action string) int {
	switch action {
	case actRemoveInactive:
		return Routine
	case actUninvite: // fast for a leaked invitee key, never a two-person lever
		return Financial
	}
	return Critical
}

func rosterDelay(action string) time.Duration {
	switch action {
	case actUninvite:
		return 0
	case actRemoveInactive:
		return InactiveDelay
	}
	return RosterDelay
}

// checkRosterAction validates a roster action's fields against the roster.
func checkRosterAction(action string, f []daoauth.Field) {
	shape := map[string]string{actAddMember: "sau", actRemoveMember: "s", actSetWeight: "su",
		actRecover: "sa", actRemoveInactive: "s", actUninvite: "s"}[action]
	if shape == "" || len(f) != len(shape) {
		panic("memba_gov: unknown roster action or wrong arguments")
	}
	for i := range f {
		if f[i].Tag != shape[i] {
			panic("memba_gov: wrong roster arguments")
		}
	}
	id := f[0].Value
	p := personByID(id)
	switch action {
	case actAddMember, actUninvite:
		if p != nil || !validID(id) {
			panic("memba_gov: person id taken or invalid")
		}
	default:
		if p == nil {
			panic("memba_gov: no seated person " + id)
		}
	}
	switch action {
	case actAddMember, actRecover:
		if addrTaken(address(f[1].Value), id) {
			panic("memba_gov: address already seated or invited")
		}
	case actUninvite:
		if !invited(id) {
			panic("memba_gov: no open invitation for " + id)
		}
	case actRemoveMember, actRemoveInactive:
		if len(seated) <= MinSeats {
			panic("memba_gov: the roster cannot shrink below " + strconv.Itoa(MinSeats))
		}
	}
	if action == actAddMember {
		weightField(f[2])
	}
	if action == actSetWeight && weightField(f[1]) == p.weight {
		panic("memba_gov: weight unchanged")
	}
	if action == actRemoveInactive && now() <= p.lastActive+secs(InactiveAfter) {
		panic("memba_gov: active within " + strconv.Itoa(int(secs(InactiveAfter)/86400)) + " days")
	}
}

func weightField(f daoauth.Field) int {
	if f.Value != "1" && f.Value != "2" {
		panic("memba_gov: weight is 1 or 2")
	}
	return int(f.Value[0] - '0')
}

func addInvite(id string, addr address, weight int, ttl time.Duration) {
	dropInvite(id)
	invites = append(invites, &invite{id: id, addr: addr, weight: weight, expires: now() + secs(ttl)})
}

func dropInvite(id string) {
	kept := invites[:0:0]
	for _, inv := range invites {
		if inv.id != id {
			kept = append(kept, inv)
		}
	}
	invites = kept
}

func removePerson(id string) {
	kept := seated[:0:0]
	for _, p := range seated {
		if p.id != id {
			kept = append(kept, p)
		}
	}
	seated = kept
	dropInvite(id)
}

// checkRoster enforces the bounds, valid ids, addresses and weights, and the
// uniqueness of ids and of addresses across seats and open invitations. An
// invitation may name a seated id: that is a recovery, with no weight.
func checkRoster() {
	if len(seated) < MinSeats || len(seated) > MaxSeats {
		panic("memba_gov: roster size out of bounds")
	}
	seen := map[string]bool{}
	for _, p := range seated {
		if seen["i"+p.id] || seen["a"+string(p.addr)] || !validID(p.id) || !daoauth.ValidAddress(p.addr) || p.weight < 1 || p.weight > 2 {
			panic("memba_gov: invalid roster")
		}
		seen["i"+p.id], seen["a"+string(p.addr)] = true, true
	}
	t := now()
	for _, inv := range invites {
		if t > inv.expires {
			continue
		}
		recovery := personByID(inv.id) != nil
		if seen["v"+inv.id] || seen["a"+string(inv.addr)] || !validID(inv.id) || !daoauth.ValidAddress(inv.addr) ||
			(!recovery && (inv.weight < 1 || inv.weight > 2)) {
			panic("memba_gov: invalid invitation")
		}
		seen["v"+inv.id], seen["a"+string(inv.addr)] = true, true
	}
}

// addrTaken reports whether a is seated, or invited for someone other than
// id: a newer invitation for id replaces id's own.
func addrTaken(a address, id string) bool {
	if personByAddr(a) != nil {
		return true
	}
	for _, inv := range invites {
		if inv.addr == a && inv.id != id && now() <= inv.expires {
			return true
		}
	}
	return false
}

func invited(id string) bool {
	for _, inv := range invites {
		if inv.id == id && now() <= inv.expires {
			return true
		}
	}
	return false
}

func personByAddr(a address) *person {
	for _, p := range seated {
		if p.addr == a {
			return p
		}
	}
	return nil
}

func personByID(id string) *person {
	for _, p := range seated {
		if p.id == id {
			return p
		}
	}
	return nil
}

func weightOf(id string) int {
	if p := personByID(id); p != nil {
		return p.weight
	}
	return 0
}

func seatedTotals() (w, n int) {
	for _, p := range seated {
		w += p.weight
	}
	return w, len(seated)
}

func scopeGen(target, scope string) uint64 {
	if v, ok := scopes.Get(target + "\n" + scope); ok {
		return v.(uint64)
	}
	return 0
}

func isOpen(pid uint64) bool {
	st, _ := state(mustGet(pid))
	return st == stVoting || st == stTimelocked || st == stReady
}

func mustGet(pid uint64) *proposal {
	v, ok := proposals.Get(key(pid))
	if !ok {
		panic("memba_gov: no proposal " + strconv.FormatUint(pid, 10))
	}
	return v.(*proposal)
}

func key(id uint64) string {
	s := strconv.FormatUint(id, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

// validTarget accepts a realm path: no user ("") or MsgRun (gno.land/e/)
// identity, no sub-realm ("#"), lowercase path characters only.
func validTarget(t string) bool {
	return strings.HasPrefix(t, "gno.land/r/") && len(t) <= 256 && !strings.Contains(t, "//") &&
		!strings.HasSuffix(t, "/") && only(t, lower+digits+"_/.")
}

func validAction(a string) bool {
	return a != "" && len(a) <= MaxAction && only(a, lower+upper+digits+"_.")
}

func validID(id string) bool { return id != "" && len(id) <= 32 && only(id, lower+digits+"_-") }

const (
	lower  = "abcdefghijklmnopqrstuvwxyz"
	upper  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	digits = "0123456789"
)

// only reports whether every byte of s is in set.
func only(s, set string) bool {
	for i := 0; i < len(s); i++ {
		if strings.IndexByte(set, s[i]) < 0 {
			return false
		}
	}
	return true
}
