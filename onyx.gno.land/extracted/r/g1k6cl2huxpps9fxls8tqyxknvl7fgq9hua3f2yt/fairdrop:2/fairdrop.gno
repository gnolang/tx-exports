package fairdrop

// FairDrop — a commit–reveal raffle board for gno.land.
//
// An organizer opens a draw with a prize and a number of winners. Entrants
// seal a ticket by submitting only a hash of a secret they generated locally;
// once entries close they reveal the secret, the realm re-hashes it against
// the seal, and when the reveal window ends anyone can trigger the draw. The
// seed is folded from the revealed secrets in address order, so every winner
// can be recomputed from public on-chain data — see Render("event/<id>/verify").
//
// The pure mechanics live in gno.land/p/fairdrop/fairness and are imported
// here; this realm owns the lifecycle, the storage and the pages.

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/fairness"
)

const (
	// RealmPath is this realm's own path and must equal the module line in
	// gnomod.toml (scripts/check.sh verifies that). It is part of every seal's
	// domain, so a seal made for this board cannot be replayed against another.
	RealmPath = "gno.land/r/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/fairdrop"

	// PackagePath is the reusable engine this realm imports.
	PackagePath = "gno.land/p/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/fairness"

	PhaseOpen      = "open"      // entries are being sealed
	PhaseReveal    = "reveal"    // entries closed, secrets being revealed
	PhaseDrawable  = "drawable"  // reveal window over, waiting for Draw
	PhaseDrawn     = "drawn"     // winners recorded
	PhaseCancelled = "cancelled" // voided by the organizer before entries closed

	// MaxSlots caps winners per event so a draw stays cheap to compute.
	MaxSlots = 100
	// MaxWeightCap caps organizer-granted ticket weight per address.
	MaxWeightCap = 100
	// MinWindowSeconds is the shortest window an event may open or reveal for.
	MinWindowSeconds = 30
	// MaxWindowSeconds is the longest window (30 days).
	MaxWindowSeconds = 30 * 24 * 60 * 60

	MaxTitleLen = 80
	MaxPrizeLen = 240
)

// Event is one draw.
type Event struct {
	ID           uint64
	Creator      address
	Title        string
	Prize        string
	Slots        int
	MaxWeight    uint64
	OpensAt      int64
	ClosesAt     int64
	RevealEndsAt int64

	// Roster holds the sealed tickets in canonical (ascending address) order;
	// fairness.Insert maintains that order and refuses a second ticket per
	// address. Secrets are filled in by Reveal and are public by design — they
	// are what makes the seed checkable.
	Roster []fairness.Ticket

	// vouches are organizer-granted ticket weights, address string -> weight.
	// A voucher must land before that address seals its ticket.
	vouches map[string]uint64

	Seed        string
	DrawnAt     int64
	DrawnHeight int64
	Cancelled   bool
}

var (
	events = []*Event{}
	byID   = map[uint64]*Event{}
	nextID uint64
)

// ---------------------------------------------------------------- lifecycle

// Create opens a draw and returns its id. The organizer pays nothing: FairDrop
// never holds funds, it only records the draw.
func Create(cur realm, title string, prize string, slots int, maxWeight int, regSeconds int, revealSeconds int) uint64 {
	runtime.AssertOriginCall()
	creator := unsafe.OriginCaller()

	title = trimSpace(title)
	prize = trimSpace(prize)
	require(title != "", "title is required")
	require(len(title) <= MaxTitleLen, "title is too long (max "+strconv.Itoa(MaxTitleLen)+" bytes)")
	require(prize != "", "prize is required")
	require(len(prize) <= MaxPrizeLen, "prize is too long (max "+strconv.Itoa(MaxPrizeLen)+" bytes)")
	require(slots >= 1 && slots <= MaxSlots, "winners must be between 1 and "+strconv.Itoa(MaxSlots))
	require(maxWeight >= 1 && maxWeight <= MaxWeightCap, "max weight must be between 1 and "+strconv.Itoa(MaxWeightCap))
	require(regSeconds >= MinWindowSeconds && regSeconds <= MaxWindowSeconds,
		"entry window must be between "+strconv.Itoa(MinWindowSeconds)+"s and "+strconv.Itoa(MaxWindowSeconds)+"s")
	require(revealSeconds >= MinWindowSeconds && revealSeconds <= MaxWindowSeconds,
		"reveal window must be between "+strconv.Itoa(MinWindowSeconds)+"s and "+strconv.Itoa(MaxWindowSeconds)+"s")

	now := time.Now().Unix()
	nextID++
	e := &Event{
		ID:           nextID,
		Creator:      creator,
		Title:        title,
		Prize:        prize,
		Slots:        slots,
		MaxWeight:    uint64(maxWeight),
		OpensAt:      now,
		ClosesAt:     now + int64(regSeconds),
		RevealEndsAt: now + int64(regSeconds) + int64(revealSeconds),
		Roster:       []fairness.Ticket{},
		vouches:      map[string]uint64{},
	}
	events = append(events, e)
	byID[e.ID] = e

	chain.Emit("EventCreated", "id", uitoa(e.ID), "creator", creator.String(), "slots", strconv.Itoa(slots))
	println("FairDrop event #" + uitoa(e.ID) + " opened: " + title)
	return e.ID
}

// Vouch grants an address extra ticket weight before it seals its ticket. One
// ticket per address is the floor; a vouch is how an organizer recognises a
// member who should carry more weight (a role holder, an allowlisted guest).
// Weight cannot be granted after the address has sealed, because the sealed
// digest commits to the weight.
func Vouch(cur realm, eventID uint64, who string, weight int) {
	runtime.AssertOriginCall()
	caller := unsafe.OriginCaller()
	e := mustEvent(eventID)

	require(!e.Cancelled, "event is cancelled")
	require(e.phase(nowUnix()) == PhaseOpen, "event is not open for entries")
	require(caller == e.Creator, "only the organizer can vouch")

	id := normalizeAddress(who)
	require(id != "", "address is required")
	require(weight >= 1 && uint64(weight) <= e.MaxWeight, "weight must be between 1 and "+uitoa(e.MaxWeight))
	require(fairness.Find(e.Roster, id) < 0, "address already sealed a ticket; weight is now fixed")

	e.vouches[id] = uint64(weight)
	chain.Emit("Vouched", "id", uitoa(e.ID), "who", id, "weight", strconv.Itoa(weight))
}

// Register seals a ticket: commit is the hex SHA-256 of the entrant's secret
// bound to their address, this event and their weight. Weight must be 1 unless
// the organizer vouched for more.
func Register(cur realm, eventID uint64, commit string, weight int) {
	runtime.AssertOriginCall()
	caller := unsafe.OriginCaller()
	e := mustEvent(eventID)

	require(!e.Cancelled, "event is cancelled")
	require(e.phase(nowUnix()) == PhaseOpen, "entries are closed")

	id := caller.String()
	commit = fairness.NormalizeDigest(commit)
	require(fairness.IsDigest(commit), "commit must be a 64-character hex sha256 digest")
	require(weight >= 1, "weight must be at least 1")

	w := uint64(weight)
	require(w <= e.MaxWeight, "weight exceeds this event's cap of "+uitoa(e.MaxWeight))
	if v, ok := e.vouches[id]; ok {
		require(w <= v, "weight exceeds the organizer's vouch of "+uitoa(v))
	} else {
		require(w == 1, "one ticket per address unless the organizer vouched for more")
	}

	roster, err := fairness.Insert(e.Roster, fairness.Ticket{
		ID:     id,
		Weight: w,
		Commit: commit,
	})
	require(err == nil, errString(err))
	e.Roster = roster

	chain.Emit("TicketSealed", "id", uitoa(e.ID), "entrant", id, "weight", uitoa(w))
	println("ticket sealed for event #" + uitoa(e.ID) + " by " + id)
}

// Reveal opens a seal. It is accepted only inside the reveal window and only
// when the secret re-hashes to the seal already on chain.
func Reveal(cur realm, eventID uint64, secret string) {
	runtime.AssertOriginCall()
	caller := unsafe.OriginCaller()
	e := mustEvent(eventID)

	require(!e.Cancelled, "event is cancelled")
	require(e.phase(nowUnix()) == PhaseReveal, "reveal window is not open")

	idx := fairness.Find(e.Roster, caller.String())
	require(idx >= 0, "no sealed ticket for this address")

	t := e.Roster[idx]
	require(t.Secret == "", "ticket already revealed")
	require(fairness.ValidSecret(secret), "secret must be printable ASCII, "+
		strconv.Itoa(fairness.MinSecretLen)+"-"+strconv.Itoa(fairness.MaxSecretLen)+" bytes")

	require(fairness.VerifySeal(t.Commit, e.Domain(), t.ID, int64(t.Weight), secret),
		"secret does not open this ticket's seal")

	e.Roster[idx].Secret = secret
	chain.Emit("TicketRevealed", "id", uitoa(e.ID), "entrant", t.ID)
	println("ticket revealed for event #" + uitoa(e.ID) + " by " + t.ID)
}

// Draw records the winners. It is permissionless on purpose: once the reveal
// window is over the result is already determined by public data, so anyone —
// entrant, organizer or passer-by — may pay the gas to write it down.
func Draw(cur realm, eventID uint64) {
	runtime.AssertOriginCall()
	e := mustEvent(eventID)

	require(!e.Cancelled, "event is cancelled")
	require(e.Seed == "", "event already drawn")

	now := nowUnix()
	ph := e.phase(now)
	// The result is fixed as soon as everyone who sealed has revealed; waiting
	// for the deadline then would only delay a foregone conclusion.
	allRevealed := len(e.Roster) > 0 && revealedCount(e) == len(e.Roster)
	require(ph == PhaseDrawable || (ph == PhaseReveal && allRevealed),
		"draw opens after the reveal window (or once every sealed ticket has revealed)")

	eligible := make([]fairness.Ticket, 0, len(e.Roster))
	leaves := make([]string, 0, len(e.Roster))
	for i := 0; i < len(e.Roster); i++ {
		t := e.Roster[i]
		if t.Secret == "" {
			continue
		}
		eligible = append(eligible, t)
		leaves = append(leaves, fairness.Leaf(t.Commit, t.Secret))
	}

	seed := fairness.Seed(e.Domain(), runtime.ChainID(), e.ID, leaves)
	winners := fairness.Draw(seed, eligible, e.Slots)

	for rank := 0; rank < len(winners); rank++ {
		idx := fairness.Find(e.Roster, winners[rank])
		if idx >= 0 {
			e.Roster[idx].Rank = rank + 1
		}
	}

	e.Seed = seed
	e.DrawnAt = now
	e.DrawnHeight = runtime.ChainHeight()

	chain.Emit("Drawn", "id", uitoa(e.ID), "seed", seed, "winners", strconv.Itoa(len(winners)))
	println("event #" + uitoa(e.ID) + " drawn, seed " + seed)
}

// Cancel voids a draw before entries close. After close the entries are
// committed and only the draw can settle them.
func Cancel(cur realm, eventID uint64) {
	runtime.AssertOriginCall()
	caller := unsafe.OriginCaller()
	e := mustEvent(eventID)

	require(caller == e.Creator, "only the organizer can cancel")
	require(!e.Cancelled, "event already cancelled")
	require(e.Seed == "", "event already drawn")
	require(e.phase(nowUnix()) == PhaseOpen, "entries are closed; the draw must settle this event")

	e.Cancelled = true
	chain.Emit("EventCancelled", "id", uitoa(e.ID))
}

// ------------------------------------------------------------------- reads

// EventCount is the number of events ever opened.
func EventCount() int {
	return len(events)
}

// Domain is this event's seal domain. It is stamped into every seal, so a seal
// cannot be moved between events, and into the seed, so a seed cannot either.
func (e *Event) Domain() string {
	return RealmPath + "#" + uitoa(e.ID)
}

// IDString renders the event id.
func (e *Event) IDString() string {
	return uitoa(e.ID)
}

// Phase returns the lifecycle phase at the given unix time.
func (e *Event) Phase(now int64) string {
	return e.phase(now)
}

func (e *Event) phase(now int64) string {
	if e.Cancelled {
		return PhaseCancelled
	}
	if e.Seed != "" {
		return PhaseDrawn
	}
	if now < e.ClosesAt {
		return PhaseOpen
	}
	if now < e.RevealEndsAt {
		return PhaseReveal
	}
	return PhaseDrawable
}

// Revealed returns how many sealed tickets have been revealed.
func (e *Event) Revealed() int {
	return revealedCount(e)
}

// Entries returns the number of sealed tickets.
func (e *Event) Entries() int {
	return len(e.Roster)
}

// Winner is one recorded winner, resolved from the roster at render time.
type Winner struct {
	Rank   int
	Entrant string
	Weight uint64
	Commit string
	Secret string
}

// Winners returns the recorded winners in rank order.
func (e *Event) Winners() []Winner {
	out := []Winner{}
	for i := 0; i < len(e.Roster); i++ {
		t := e.Roster[i]
		if t.Rank > 0 {
			out = append(out, Winner{
				Rank:    t.Rank,
				Entrant: t.ID,
				Weight:  t.Weight,
				Commit:  t.Commit,
				Secret:  t.Secret,
			})
		}
	}
	// Rank order: insertion sort, rosters are small and ranks are unique.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Rank < out[j-1].Rank; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

// Proof returns the draw's verifiable inputs as a JSON object, so an
// off-chain checker can recompute the seed and the winners from chain state
// without trusting this realm's pages. Every value is an address, a hex
// digest or a printable-ASCII secret, so the JSON needs no escaping.
func Proof(id uint64) string {
	e := mustEvent(id)

	out := "{\"event\":" + uitoa(e.ID)
	out += ",\"domain\":\"" + e.Domain() + "\""
	out += ",\"chain_id\":\"" + runtime.ChainID() + "\""
	out += ",\"slots\":" + strconv.Itoa(e.Slots)
	out += ",\"seed\":\"" + e.Seed + "\""
	out += ",\"entrants\":["
	for i := 0; i < len(e.Roster); i++ {
		t := e.Roster[i]
		if i > 0 {
			out += ","
		}
		out += "{\"address\":\"" + t.ID + "\""
		out += ",\"weight\":" + uitoa(t.Weight)
		out += ",\"seal\":\"" + t.Commit + "\""
		out += ",\"secret\":\"" + t.Secret + "\""
		out += ",\"rank\":" + strconv.Itoa(t.Rank) + "}"
	}
	out += "]}"
	return out
}

// AcceptedLeaves returns the seed inputs in fold order, for verification.
func (e *Event) AcceptedLeaves() []string {
	out := []string{}
	for i := 0; i < len(e.Roster); i++ {
		t := e.Roster[i]
		if t.Secret != "" {
			out = append(out, fairness.Leaf(t.Commit, t.Secret))
		}
	}
	return out
}

// GetEvent looks an event up by id, or nil.
func GetEvent(id uint64) *Event {
	e, ok := byID[id]
	if !ok {
		return nil
	}
	return e
}

// ---------------------------------------------------------------- internals

func revealedCount(e *Event) int {
	n := 0
	for i := 0; i < len(e.Roster); i++ {
		if e.Roster[i].Secret != "" {
			n++
		}
	}
	return n
}

func mustEvent(id uint64) *Event {
	e, ok := byID[id]
	if !ok {
		panic("event #" + uitoa(id) + " does not exist")
	}
	return e
}

func nowUnix() int64 {
	return time.Now().Unix()
}

func require(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func uitoa(u uint64) string {
	return strconv.FormatUint(u, 10)
}

func trimSpace(s string) string {
	start := 0
	end := len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r') {
		start++
	}
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r') {
		end--
	}
	return s[start:end]
}

// normalizeAddress accepts the shape of a bech32 gno address (g1 + 38
// lower-case alphanumerics) as typed. It deliberately does not convert through
// the address type: a bad checksum would panic, and vouching for an address
// nobody holds is harmless — the vouch just never matches a ticket.
func normalizeAddress(s string) string {
	s = trimSpace(s)
	if len(s) != 40 || s[0] != 'g' || s[1] != '1' {
		return ""
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') {
			continue
		}
		return ""
	}
	return s
}
