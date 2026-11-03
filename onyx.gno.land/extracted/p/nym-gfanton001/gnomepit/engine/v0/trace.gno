package engine

// Vitals is one gnome's numbers during a round.
type Vitals struct {
	HP, Block, Counter, Vulnerable, Strength int
}

// Phase is the part of a beat an event belongs to.
type Phase int

const (
	InterruptPhase Phase = iota
	BlockPhase
	DamagePhase
)

type EventKind int

const (
	Cancelled         EventKind = iota // Card was cancelled by the opponent's Interrupt or Parry
	ParryEnded                         // Card made its last Parry cancel; its later beats stay empty
	BlockGained                        // Side gained N Block from Card
	CounterGained                      // Side gained Counter N from Card
	HitLanded                          // Card hit the opponent for N damage to HP, Blocked absorbed
	CounterHit                         // the opponent's Counter dealt N to Side's HP after Card hit
	VulnerableApplied                  // Card applied N Vulnerable to the opponent
	StrengthGained                     // Side gained N Strength from Card
	VulnerableMoved                    // Card moved Side's N Vulnerable to the opponent, who keeps up to the cap
	VulnerableGained                   // Side gained N Vulnerable from Card
	BlockStripped                      // Card took the opponent's N Block
)

// Event is one effect of a round's resolution. Side owns Card. A HitLanded, a
// VulnerableApplied or a BlockStripped lands on the other gnome, a VulnerableMoved changes
// both, and every other kind changes Side's own Vitals. N is the change after caps, the damage that
// reached HP, or the tokens that left the mover.
type Event struct {
	Beat    int // 1 to 3
	Phase   Phase
	Tier    Tier
	Step    int // from 1 within a beat, phase and tier; equal for effects that resolve together
	Kind    EventKind
	Side    Side
	Card    CardID
	N       int
	Blocked int       // HitLanded and CounterHit: damage absorbed by Block
	Doubled bool      // HitLanded: the defender's Vulnerable doubled it
	After   [2]Vitals // both gnomes once the whole step has resolved
}

// Trace resolves the round as Resolve does and also returns its events in order.
func (rs *Ruleset) Trace(s State, a, b Plan) (Outcome, []Event) {
	var events []Event
	o := rs.resolve(s, a, b, &events)
	return o, events
}

// tracer appends the events of one round. A nil events pointer records nothing.
type tracer struct {
	events *[]Event
	beat   int
	phase  Phase
	tier   Tier
	step   int
	first  int // index of the current step's first event
}

func (t *tracer) at(beat int, phase Phase, tier Tier, step int) {
	t.beat, t.phase, t.tier, t.step = beat, phase, tier, step
}

func (t *tracer) emit(kind EventKind, side Side, card CardID, n, blocked int, doubled bool) {
	if t.events == nil {
		return
	}
	*t.events = append(*t.events, Event{
		Beat: t.beat, Phase: t.phase, Tier: t.tier, Step: t.step,
		Kind: kind, Side: side, Card: card, N: n, Blocked: blocked, Doubled: doubled,
	})
}

// close stamps the state after the step on every event emitted since the last close.
func (t *tracer) close(f *[2]Vitals) {
	if t.events == nil {
		return
	}
	evs := *t.events
	for i := t.first; i < len(evs); i++ {
		evs[i].After = *f
	}
	t.first = len(evs)
}
