package hat

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"strconv"
	"time"
)

// Size limits keep gas and storage small.
const (
	MinPeople = 3    // a circle of fewer than three is not a draw
	MaxPeople = 30   // upper bound on the roster
	MaxBlob   = 1024 // upper bound on any single onion or slip, in bytes

	KeySize      = 32 // slot keys, box keys, commitments and seeds
	SealOverhead = 48 // bytes crypto_box_seal adds per layer (ephemeral key + MAC)

	// Shufflers is how many shufflers a roster of five or more gets.
	// Rosters of three or four use everyone.
	Shufflers = 3
)

var (
	ErrPhase       = errors.New("hat: not allowed in this phase")
	ErrMember      = errors.New("hat: unknown member")
	ErrFull        = errors.New("hat: roster is full")
	ErrTooFew      = errors.New("hat: need at least 3 people")
	ErrDuplicate   = errors.New("hat: already done")
	ErrNotYourTurn = errors.New("hat: not your shuffle turn")
	ErrSize        = errors.New("hat: wrong size")
	ErrKeyTaken    = errors.New("hat: key already in this draw")
	ErrCommit      = errors.New("hat: seed does not match commitment")
	ErrExpired     = errors.New("hat: phase deadline has passed")
	ErrConfirmed   = errors.New("hat: everyone already confirmed")
)

// Options configure a hat.
type Options struct {
	// Rounds is 2 for a gift exchange (slots, then slips) or 1 when only the
	// anonymous slots are needed, as in a role deal.
	Rounds int
	// Slip is the size, in bytes, of each item the last shuffler of round two
	// outputs: a 32-byte slot key followed by an opaque sealed payload.
	// Ignored when Rounds is 1.
	Slip int
	// Step is how long each phase, and each shuffle turn, may take.
	Step time.Duration
	// JoinWindow is how long the roster stays open.
	JoinWindow time.Duration
}

type member struct {
	box    []byte // X25519 public key shufflers are reached with
	commit []byte // sha256 of the seed revealed in Locked
	seed   []byte
	done   bool // has acted in the current Ready, Seal or Confirm phase
}

// Hat is the full state of one draw, minus identities: members are numbered
// in join order and the caller (a realm) maps them to people and keys.
// A Hat never stores which slot belongs to which member.
type Hat struct {
	opts      Options
	phase     Phase
	deadline  time.Time
	members   []*member
	exclude   int // member never picked as shuffler in rosters of 5+, or -1
	seed      []byte
	shufflers []int
	turn      int      // shuffle turns done in the current mix phase
	contents  [][]byte // what is in the hat during Seal and Mix
	slots     [][]byte // the circle, after Mix1
	slips     [][]byte // after Mix2, slips[k] is addressed to slots[k]
	confirmed int      // confirmations in Check or Revealed
	reason    string   // why it was voided
}

// New opens a hat for joining at block time now.
func New(opts Options, now time.Time) *Hat {
	if opts.Rounds != 1 {
		opts.Rounds = 2
	}
	return &Hat{opts: opts, phase: Join, deadline: now.Add(opts.JoinWindow), exclude: -1}
}

// Phase returns the current phase.
func (h *Hat) Phase() Phase { return h.phase }

// Rounds returns 1 or 2.
func (h *Hat) Rounds() int { return h.opts.Rounds }

// Deadline returns the block time by which the current phase or turn must end.
func (h *Hat) Deadline() time.Time { return h.deadline }

// Size returns the number of members.
func (h *Hat) Size() int { return len(h.members) }

// BoxKey returns the box public key of member i.
func (h *Hat) BoxKey(i int) []byte { return h.members[i].box }

// Shufflers returns the members picked to shuffle, in turn order.
func (h *Hat) Shufflers() []int { return h.shufflers }

// Turn returns how many shuffle turns are done in the current mix phase.
func (h *Hat) Turn() int { return h.turn }

// Expected returns the member whose shuffle turn it is, or -1.
func (h *Hat) Expected() int {
	if (h.phase == Mix1 || h.phase == Mix2) && h.turn < len(h.shufflers) {
		return h.shufflers[h.turn]
	}
	return -1
}

// Contents returns what is in the hat right now: the onions waiting for the
// next shuffler during a mix phase.
func (h *Hat) Contents() [][]byte {
	if h.phase == Mix1 || h.phase == Mix2 {
		return h.contents
	}
	return nil
}

// Slots returns the circle: slot k gives to slot k+1, wrapping round.
func (h *Hat) Slots() [][]byte { return h.slots }

// Slips returns the sealed slips; Slips()[k] is addressed to Slots()[k].
func (h *Hat) Slips() [][]byte { return h.slips }

// Seed returns the draw seed fixed when the last phone checked in.
func (h *Hat) Seed() []byte { return h.seed }

// Done reports whether member i has acted in the current phase.
func (h *Hat) Done(i int) bool { return i >= 0 && i < len(h.members) && h.members[i].done }

// Count returns how many members have acted in the current phase.
func (h *Hat) Count() int {
	if h.phase == Check || h.phase == Revealed {
		return h.confirmed
	}
	c := 0
	for _, m := range h.members {
		if m.done {
			c++
		}
	}
	return c
}

// Completed reports whether every phone confirmed its slip after the reveal.
func (h *Hat) Completed() bool { return h.phase == Revealed && h.confirmed == len(h.members) }

// Reason returns why the hat was voided.
func (h *Hat) Reason() string { return h.reason }

// OnionSize returns how long an onion must be before shuffle turn t of the
// current or coming round (t == 0 is what phones seal).
func (h *Hat) OnionSize(round, t int) int {
	inner := KeySize
	if round == 2 {
		inner = h.opts.Slip
	}
	return inner + SealOverhead*(len(h.shufflers)-t)
}

// Add puts a new member in the hat and returns its number.
func (h *Hat) Add(box, commit []byte, now time.Time) (int, error) {
	if err := h.live(now, Join); err != nil {
		return -1, err
	}
	if len(h.members) >= MaxPeople {
		return -1, ErrFull
	}
	if len(box) != KeySize || len(commit) != KeySize {
		return -1, ErrSize
	}
	for _, m := range h.members {
		if bytes.Equal(m.box, box) {
			return -1, ErrKeyTaken
		}
	}
	h.members = append(h.members, &member{box: box, commit: commit})
	return len(h.members) - 1, nil
}

// Lock freezes the roster. exclude is the member who locked it (the
// organiser), or -1; in rosters of five or more it is never picked to shuffle.
func (h *Hat) Lock(exclude int, now time.Time) error {
	if err := h.live(now, Join); err != nil {
		return err
	}
	if len(h.members) < MinPeople {
		return ErrTooFew
	}
	h.exclude = exclude
	h.move(Locked, now)
	return nil
}

// Ready reveals member i's seed. When the last seed is in, the draw seed is
// fixed as sha256 of the roster digest and every member's key, commitment
// and seed, the shufflers are picked from it, and sealing starts.
// The roster digest lets the caller bind data the hat does not see, such as
// names and signing keys.
func (h *Hat) Ready(i int, seed, roster []byte, now time.Time) error {
	m, err := h.actor(i, now, Locked)
	if err != nil {
		return err
	}
	if len(seed) != KeySize {
		return ErrSize
	}
	sum := sha256.Sum256(seed)
	if !bytes.Equal(sum[:], m.commit) {
		return ErrCommit
	}
	m.seed = seed
	m.done = true
	if h.Count() < len(h.members) {
		return nil
	}
	buf := []byte("hat/seed/v1")
	buf = append(buf, roster...)
	for _, m := range h.members {
		buf = append(buf, m.box...)
		buf = append(buf, m.commit...)
		buf = append(buf, m.seed...)
	}
	s := sha256.Sum256(buf)
	h.seed = s[:]
	h.shufflers = PickShufflers(h.seed, len(h.members), h.exclude)
	h.move(Seal1, now)
	return nil
}

// Seal takes member i's onion for the current seal phase. Once every member
// has sealed, the onions go into the hat in member order and mixing starts.
func (h *Hat) Seal(i int, onion []byte, now time.Time) error {
	want := Seal1
	round := 1
	if h.phase == Seal2 {
		want, round = Seal2, 2
	}
	m, err := h.actor(i, now, want)
	if err != nil {
		return err
	}
	if len(onion) != h.OnionSize(round, 0) || len(onion) > MaxBlob {
		return ErrSize
	}
	if h.contents == nil {
		h.contents = make([][]byte, len(h.members))
	}
	h.contents[i] = onion
	m.done = true
	if h.Count() == len(h.members) {
		h.move(h.phase.next(h.opts.Rounds), now)
	}
	return nil
}

// Mix takes shuffle turn output from member i. Only the expected shuffler may
// act, in order; anyone else gets ErrNotYourTurn and nothing changes.
// Output that shows tampering (a slip dropped, added or duplicated, or the
// wrong size) is not rejected: it voids the hat, for everyone, so the
// shuffler's own signed transaction is the public record of what went wrong.
func (h *Hat) Mix(i int, out [][]byte, now time.Time) error {
	if h.phase != Mix1 && h.phase != Mix2 {
		return ErrPhase
	}
	if h.Expire(now) {
		return ErrExpired
	}
	if i < 0 || i >= len(h.members) {
		return ErrMember
	}
	if i != h.Expected() {
		return ErrNotYourTurn
	}
	round := 1
	if h.phase == Mix2 {
		round = 2
	}
	turnName := h.phase.String() + " turn " + strconv.Itoa(h.turn+1)
	if reason := CheckMix(h.contents, out, h.OnionSize(round, h.turn+1)); reason != "" {
		h.void(turnName+": "+reason, now)
		return nil
	}
	h.contents = out
	h.turn++
	h.deadline = now.Add(h.opts.Step)
	if h.turn < len(h.shufflers) {
		return nil
	}
	// Last turn of the round.
	if round == 1 {
		h.slots = Circle(h.seed, out)
		h.contents = nil
		h.move(Check, now)
		return nil
	}
	slips, reason := MatchSlips(h.slots, out)
	if reason != "" {
		h.void(turnName+": "+reason, now)
		return nil
	}
	h.slips = slips
	h.contents = nil
	h.move(Revealed, now)
	return nil
}

// Confirm records that member i's phone checked its own slot (in Check) or
// its own slip (in Revealed) and found it right.
func (h *Hat) Confirm(i int, now time.Time) error {
	if h.phase != Check && h.phase != Revealed {
		return ErrPhase
	}
	m, err := h.actor(i, now, h.phase)
	if err != nil {
		return err
	}
	m.done = true
	h.confirmed++
	if h.phase == Check && h.confirmed == len(h.members) {
		h.move(h.phase.next(h.opts.Rounds), now)
	}
	return nil
}

// Void calls the draw off on member i's claim that its slot (in Check) or
// its slip (in Revealed) is missing, duplicated or forged.
func (h *Hat) Void(i int, reason string, now time.Time) error {
	if h.phase != Check && h.phase != Revealed {
		return ErrPhase
	}
	if h.Completed() {
		return ErrConfirmed
	}
	if h.Expire(now) {
		return ErrExpired
	}
	if i < 0 || i >= len(h.members) {
		return ErrMember
	}
	h.void(reason, now)
	return nil
}

// Expire voids the hat if the current phase or turn has run out of time and
// reports whether it did. A Revealed hat whose deadline passes is left as it
// is: every slip was delivered, only some confirmations are missing.
func (h *Hat) Expire(now time.Time) bool {
	if h.phase.Terminal() || !now.After(h.deadline) {
		return false
	}
	h.void("timed out in "+h.phase.String()+h.waitingFor(), now)
	return true
}

func (h *Hat) waitingFor() string {
	if h.phase == Join {
		return " (the roster was never locked)"
	}
	if h.Expected() >= 0 {
		return " waiting for shuffler " + strconv.Itoa(h.turn+1) + " of " + strconv.Itoa(len(h.shufflers))
	}
	return " waiting for " + strconv.Itoa(len(h.members)-h.Count()) + " phone(s)"
}

// actor checks that member i may act in phase p right now and has not yet.
func (h *Hat) actor(i int, now time.Time, p Phase) (*member, error) {
	if err := h.live(now, p); err != nil {
		return nil, err
	}
	if i < 0 || i >= len(h.members) {
		return nil, ErrMember
	}
	m := h.members[i]
	if m.done {
		return nil, ErrDuplicate
	}
	return m, nil
}

func (h *Hat) live(now time.Time, p Phase) error {
	if h.phase != p {
		return ErrPhase
	}
	// Revealed has no deadline: a late phone may still confirm or void.
	if p != Revealed && now.After(h.deadline) {
		return ErrExpired
	}
	return nil
}

func (h *Hat) move(to Phase, now time.Time) {
	if !CanMove(h.phase, to, h.opts.Rounds) {
		panic("hat: illegal move " + h.phase.String() + " -> " + to.String())
	}
	h.phase = to
	h.turn = 0
	h.confirmed = 0
	h.deadline = now.Add(h.opts.Step)
	for _, m := range h.members {
		m.done = false
	}
}

func (h *Hat) void(reason string, now time.Time) {
	h.move(Voided, now)
	h.reason = reason
	h.contents = nil
}
