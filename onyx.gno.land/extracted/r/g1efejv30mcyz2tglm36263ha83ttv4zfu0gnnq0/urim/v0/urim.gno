// Package urim draws Secret Santa names so nobody, not even the organiser,
// can peek or rig who gets whom.
//
// The realm stores each draw, checks every caller's Ed25519 signature
// itself, rejects replays, and drives a p/hat state machine. It never learns
// who gives to whom: see docs/PROTOCOL.md.
//
// Every state-changing function is signed by a participant's own key, so it
// can be submitted by anyone (a relay that pays gas, or the participant's own
// wallet) without giving the submitter any power.
package urim

import (
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1efejv30mcyz2tglm36263ha83ttv4zfu0gnnq0/hat/v0"
)

const (
	liveStep   = 10 * time.Minute // per phase and per shuffle turn, live draws
	asyncStep  = 24 * time.Hour   // same, for draws run over a few days
	joinWindow = 14 * 24 * time.Hour

	slipSize = hat.KeySize + 208 // slot key + sealed slip (see PROTOCOL.md step 6)

	reasonSlot = "my slot is missing"
	reasonSlip = "my slip is missing or duplicated"
)

type person struct {
	name    string
	signPub []byte
	boxPub  []byte
	nonce   int64
}

type draw struct {
	id        int64
	title     string
	budget    string
	date      string
	live      bool
	organiser []byte
	orgNonce  int64 // used only while the organiser has not joined
	people    []*person
	hat       *hat.Hat
	created   time.Time
	next      int64 // a fresh draw started from this voided one
	settled   bool  // already counted in the public counter
}

var (
	draws      avl.Tree // key(id) -> *draw
	organisers avl.Tree // hex organiser key -> true; one draw per key, so Create cannot be replayed
	lastID     int64

	// The public counter.
	completed int
	people    int
	voided    int
)

func key(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func mustDraw(id int64) *draw {
	v := draws.Get(key(id))
	if v == nil {
		panic("urim: no such draw")
	}
	return v.(*draw)
}

// Create opens a new draw and returns its id. The organiser is whoever holds
// the key orgPub; that key alone may later lock the roster.
// mode is "live" (everyone together, minutes per step) or "async" (a day per step).
func Create(_ realm, title, budget, date, mode, orgPub string, nonce int64, sig string) int64 {
	checkText("title", title, 1, 60)
	checkText("budget", budget, 0, 40)
	checkText("date", date, 0, 24)
	if mode != "live" && mode != "async" {
		panic("urim: mode must be live or async")
	}
	pub := mustHex("orgPub", orgPub, 32)
	if organisers.Has(orgPub) {
		panic("urim: this key already created a draw")
	}
	verifySig(pub, 0, hat.Join, nonce, sig, "create", title, budget, date, mode, orgPub)
	organisers.Set(orgPub, true)

	now := time.Now()
	step := asyncStep
	if mode == "live" {
		step = liveStep
	}
	lastID++
	d := &draw{
		id: lastID, title: title, budget: budget, date: date, live: mode == "live",
		organiser: pub, orgNonce: nonce, created: now,
		hat: hat.New(hat.Options{Rounds: 2, Slip: slipSize, Step: step, JoinWindow: joinWindow}, now),
	}
	draws.Set(key(d.id), d)
	return d.id
}

// Join adds the signer to the roster with a name, its signing and box public
// keys, and commit = sha256(seed) for the seed it will reveal after Lock.
func Join(_ realm, id int64, name, signPub, boxPub, commit string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	checkName(name)
	for _, p := range d.people {
		if sameName(p.name, name) {
			panic("urim: that name is taken in this draw")
		}
	}
	pub := mustHex("signPub", signPub, 32)
	if d.find(pub) >= 0 {
		panic("urim: already joined")
	}
	box := mustHex("boxPub", boxPub, 32)
	c := mustHex("commit", commit, 32)
	// The nonce sequence of a key that already signed (the organiser's) carries on.
	last := int64(0)
	if bytesEq(pub, d.organiser) {
		last = d.orgNonce
	}
	if nonce <= last {
		panic("urim: replayed or stale nonce")
	}
	verifySig(pub, d.id, hat.Join, nonce, sig, "join", name, signPub, boxPub, commit)
	if _, err := d.hat.Add(box, c, time.Now()); err != nil {
		panic(err.Error())
	}
	d.people = append(d.people, &person{name: name, signPub: pub, boxPub: box, nonce: nonce})
}

// Lock freezes the roster. Only the organiser's key may sign it.
func Lock(_ realm, id int64, signPub string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	pub := mustHex("signPub", signPub, 32)
	if !bytesEq(pub, d.organiser) {
		panic("urim: only the organiser can lock the roster")
	}
	d.auth(pub, nonce, sig, "lock")
	if err := d.hat.Lock(d.find(pub), time.Now()); err != nil {
		panic(err.Error())
	}
}

// Ready reveals the signer's seed. When the last one is in, the realm fixes
// the draw seed and picks the shufflers from it.
func Ready(_ realm, id int64, signPub, seed string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	i := d.member(signPub)
	s := mustHex("seed", seed, 32)
	d.auth(d.people[i].signPub, nonce, sig, "ready", seed)
	if err := d.hat.Ready(i, s, d.roster(), time.Now()); err != nil {
		panic(err.Error())
	}
}

// Seal posts the signer's onion for the current seal phase (Seal1 or Seal2).
func Seal(_ realm, id int64, signPub, onion string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	i := d.member(signPub)
	b := mustB64("onion", onion)
	d.auth(d.people[i].signPub, nonce, sig, "seal", onion)
	if err := d.hat.Seal(i, b, time.Now()); err != nil {
		panic(err.Error())
	}
}

// Mix posts one shuffle turn: the hat's contents with one layer peeled and
// shuffled, as comma-separated base64. Only the expected shuffler may sign
// it. Output that shows tampering voids the draw instead of being rejected.
func Mix(_ realm, id int64, signPub, items string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	i := d.member(signPub)
	out := splitB64(items, d.hat.Size())
	d.auth(d.people[i].signPub, nonce, sig, "mix", items)
	if err := d.hat.Mix(i, out, time.Now()); err != nil {
		panic(err.Error())
	}
	d.settle()
}

// Confirm says the signer's phone found its own slot (in Check) or opened a
// genuine slip (in Revealed).
func Confirm(_ realm, id int64, signPub string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	i := d.member(signPub)
	d.auth(d.people[i].signPub, nonce, sig, "confirm")
	if err := d.hat.Confirm(i, time.Now()); err != nil {
		panic(err.Error())
	}
	d.settle()
}

// Void calls the draw off for everyone, on the signer's claim that its slot
// is missing (in Check) or its slip is missing, duplicated or forged (after
// Mix2). The claim cannot reveal a pairing; it only cancels.
func Void(_ realm, id int64, signPub, reason string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.expire() {
		return
	}
	switch {
	case d.hat.Phase() == hat.Check && reason == reasonSlot:
	case d.hat.Phase() == hat.Revealed && reason == reasonSlip:
	default:
		panic("urim: Void takes \"" + reasonSlot + "\" in Check or \"" + reasonSlip + "\" after the reveal")
	}
	i := d.member(signPub)
	d.auth(d.people[i].signPub, nonce, sig, "void", reason)
	if err := d.hat.Void(i, d.people[i].name+": "+reason, time.Now()); err != nil {
		panic(err.Error())
	}
	d.settle()
}

// Expire voids a draw whose current phase or turn has run out of block time.
// Anyone may call it; it does nothing before the deadline.
func Expire(_ realm, id int64) {
	if !mustDraw(id).expire() {
		panic("urim: deadline has not passed")
	}
}

// Relink points a voided draw at the fresh draw that replaces it, so every
// phone that was in the old one can find the new one. Any participant of the
// old draw may sign it, once.
func Relink(_ realm, id, next int64, signPub string, nonce int64, sig string) {
	d := mustDraw(id)
	if d.hat.Phase() != hat.Voided {
		panic("urim: only a voided draw can be restarted")
	}
	if d.next != 0 {
		panic("urim: already restarted")
	}
	n := mustDraw(next)
	if n.created.Before(d.created) || n.hat.Phase() != hat.Join {
		panic("urim: the fresh draw must be newer and still open")
	}
	i := d.member(signPub)
	d.auth(d.people[i].signPub, nonce, sig, "relink", strconv.FormatInt(next, 10))
	d.next = next
}

// expire voids d if its deadline has passed and reports whether it did.
// Calls that arrive late commit the void instead of failing, so the draw
// never sits stuck in a phase nobody can finish.
func (d *draw) expire() bool {
	if !d.hat.Expire(time.Now()) {
		return false
	}
	d.settle()
	return true
}

// settle updates the public counter once a draw is completed or voided.
func (d *draw) settle() {
	if d.settled {
		return
	}
	switch {
	case d.hat.Phase() == hat.Voided:
		voided++
	case d.hat.Completed():
		completed++
		people += len(d.people)
	default:
		return
	}
	d.settled = true
}

func (d *draw) find(pub []byte) int {
	for i, p := range d.people {
		if bytesEq(p.signPub, pub) {
			return i
		}
	}
	return -1
}

// member returns the roster index of the hex signing key, or panics.
func (d *draw) member(signPub string) int {
	i := d.find(mustHex("signPub", signPub, 32))
	if i < 0 {
		panic("urim: not in this draw")
	}
	return i
}

// auth checks the signature and nonce of a call by pub on d, in the current
// phase, and records the nonce.
func (d *draw) auth(pub []byte, nonce int64, sig string, fields ...string) {
	ref := &d.orgNonce
	if i := d.find(pub); i >= 0 {
		ref = &d.people[i].nonce
	}
	if nonce <= *ref {
		panic("urim: replayed or stale nonce")
	}
	verifySig(pub, d.id, d.hat.Phase(), nonce, sig, fields...)
	*ref = nonce
}

// roster digests the names and signing keys, which the hat does not see,
// so the draw seed is bound to them too.
func (d *draw) roster() []byte {
	var buf []byte
	for _, p := range d.people {
		buf = append(buf, []byte(p.name)...)
		buf = append(buf, 0)
		buf = append(buf, p.signPub...)
	}
	return sha256Sum(buf)
}
