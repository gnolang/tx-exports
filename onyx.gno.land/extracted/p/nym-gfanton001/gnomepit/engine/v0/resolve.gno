package engine

// Result is how a round left the match.
type Result int

const (
	Ongoing Result = iota
	AWins
	BWins
	Draw
)

// Outcome is the state after a round, and the match result once it has one.
type Outcome struct {
	State  State
	Result Result
}

const (
	lastRound   = 3
	maxPlanSize = beatsPerRound
)

// slot is the card of one plan occupying one beat.
type slot struct {
	index  int  // position of the card in the plan
	lands  bool // the card's last beat, where its effects resolve
	active bool // lands, or a Parry card, which acts on every beat it occupies
}

func (rs *Ruleset) slotsOf(p Plan) [beatsPerRound]slot {
	var out [beatsPerRound]slot
	beat := 0
	for i, id := range p {
		c := &rs.Cards[id]
		for k := 0; k < c.Cost; k++ {
			lands := k == c.Cost-1
			out[beat] = slot{index: i, lands: lands, active: lands || c.Parry > 0}
			beat++
		}
	}
	return out
}

// take applies damage through Block and returns what Block absorbed.
func (v *Vitals) take(damage int) int {
	absorbed := damage
	if v.Block < absorbed {
		absorbed = v.Block
	}
	v.Block -= absorbed
	v.HP -= damage - absorbed
	return absorbed
}

// gain applies a Block-phase effect and returns the change after the cap.
func (v *Vitals) gain(rs *Ruleset, e Effect) int {
	switch e.Kind {
	case GainBlock, BlockPerVulnerable:
		n := e.N
		if e.Kind == BlockPerVulnerable {
			n *= 1 + v.Vulnerable
		}
		before := v.Block
		v.Block = capped(v.Block+n, rs.BlockCap)
		return v.Block - before
	case GainCounter:
		before := v.Counter
		v.Counter = capped(v.Counter+e.N, rs.CounterCap)
		return v.Counter - before
	}
	return 0
}

func (rs *Ruleset) gainAll(v *Vitals, effects []Effect, tr *tracer, side Side, card CardID) {
	for _, e := range effects {
		n := v.gain(rs, e)
		switch e.Kind {
		case GainBlock, BlockPerVulnerable:
			tr.emit(BlockGained, side, card, n, 0, false)
		case GainCounter:
			tr.emit(CounterGained, side, card, n, 0, false)
		}
	}
}

func movesVulnerable(effects []Effect) bool {
	for _, e := range effects {
		if e.Kind == MoveVulnerable {
			return true
		}
	}
	return false
}

// moveVulnerable puts all of each mover's Vulnerable on the other gnome; movers[side] is
// nil when that side moves nothing. Both amounts are read before either changes, so two
// moves on one beat swap the tokens. The receiver's cap applies.
func (rs *Ruleset) moveVulnerable(f *[2]Vitals, movers [2]*Card, cards [2]CardID, tr *tracer, beat int) {
	var held [2]int
	for side := 0; side < 2; side++ {
		if movers[side] != nil {
			held[side], f[side].Vulnerable = f[side].Vulnerable, 0
		}
	}
	for side := 0; side < 2; side++ {
		if movers[side] == nil {
			continue
		}
		o := 1 - side
		f[o].Vulnerable = capped(f[o].Vulnerable+held[side], rs.VulnerableCap)
		tr.at(beat, BlockPhase, movers[side].Tier, 1)
		tr.emit(VulnerableMoved, Side(side), cards[side], held[side], 0, false)
	}
}

func capped(v, limit int) int {
	if v > limit {
		return limit
	}
	return v
}

// Resolve plays round s.Round. Both plans must be legal for their side in s
// (LegalPlans); an illegal plan is a caller error.
func (rs *Ruleset) Resolve(s State, a, b Plan) Outcome {
	return rs.resolve(s, a, b, nil)
}

func (rs *Ruleset) resolve(s State, a, b Plan, events *[]Event) Outcome {
	plans := [2]Plan{a, b}
	next := s
	next.Round = s.Round + 1
	tr := tracer{events: events}
	var f [2]Vitals
	var slots [2][beatsPerRound]slot
	var gone [2][maxPlanSize]bool   // cancelled, or a Parry that used up its cancels
	var parried [2][maxPlanSize]int // cancels made by each Parry card this round
	var hardest [2]int              // the most HP one opponent hit took from each gnome this round
	for side := 0; side < 2; side++ {
		g := s.Gnomes[side]
		f[side] = Vitals{HP: g.HP, Vulnerable: g.Vulnerable, Strength: g.Strength}
		slots[side] = rs.slotsOf(plans[side])
		for _, id := range plans[side] {
			if rs.Cards[id].Special {
				next.Gnomes[side].Spent |= uint64(1) << uint(id)
			}
		}
	}

	for beat := 0; beat < beatsPerRound; beat++ {
		var cur [2]*Card // nil once cancelled or ended
		var sl [2]slot
		var cards [2]CardID
		for side := 0; side < 2; side++ {
			sl[side] = slots[side][beat]
			cards[side] = plans[side][sl[side].index]
			if !gone[side][sl[side].index] {
				cur[side] = &rs.Cards[cards[side]]
			}
		}

		// Interrupt phase
		var cancelledNow [2]*Card
		var didCancel [2]bool
		for tier := Quick; tier <= Slow; tier++ {
			var hit, parryDone [2]bool
			for side := 0; side < 2; side++ {
				o := 1 - side
				me, op := cur[side], cur[o]
				if me == nil || op == nil || me.Tier != tier {
					continue
				}
				switch {
				case me.Interrupt && sl[side].lands && !sl[o].active:
					hit[o], didCancel[side] = true, true
				case me.Parry > 0 && sl[side].active && sl[o].lands && op.Attack():
					hit[o], didCancel[side] = true, true
					parried[side][sl[side].index]++
					parryDone[side] = parried[side][sl[side].index] >= me.Parry
				}
			}
			tr.at(beat+1, InterruptPhase, tier, 1)
			for side := 0; side < 2; side++ {
				if hit[side] {
					cancelledNow[side] = cur[side]
					gone[side][sl[side].index] = true
					cur[side] = nil
					tr.emit(Cancelled, Side(side), cards[side], 0, 0, false)
				}
				if parryDone[side] && cur[side] != nil {
					// Its later beats stay empty; this beat's effects still resolve.
					gone[side][sl[side].index] = true
					tr.emit(ParryEnded, Side(side), cards[side], 0, 0, false)
				}
			}
			tr.close(&f)
		}

		facts := beatFacts{didCancel: didCancel}
		for side := 0; side < 2; side++ {
			o := 1 - side
			facts.attacked[side] = cur[o] != nil && sl[o].lands && cur[o].Attack()
		}

		// Block phase
		var movers [2]*Card
		for side := 0; side < 2; side++ {
			if cur[side] != nil && sl[side].lands {
				tr.at(beat+1, BlockPhase, cur[side].Tier, 1)
				rs.gainAll(&f[side], cur[side].Block, &tr, Side(side), cards[side])
				if movesVulnerable(cur[side].Block) {
					movers[side] = cur[side]
				}
			}
			if cancelledNow[side] != nil {
				tr.at(beat+1, BlockPhase, cancelledNow[side].Tier, 1)
				rs.gainAll(&f[side], cancelledNow[side].OnCancel, &tr, Side(side), cards[side])
			}
		}
		rs.moveVulnerable(&f, movers, cards, &tr, beat+1)
		tr.close(&f)

		// Damage phase
		for tier := Quick; tier <= Slow; tier++ {
			var effects [2][]Effect
			for side := 0; side < 2; side++ {
				switch c := cancelledNow[side]; {
				case cur[side] != nil && sl[side].lands && cur[side].Tier == tier:
					effects[side] = cur[side].Damage
				case c != nil && c.Tier == tier:
					effects[side] = c.CancelDamage
				}
			}
			tr.at(beat+1, DamagePhase, tier, 0)
			if result := rs.resolveDamageTier(&f, &hardest, effects, cards, facts, &tr); result != Ongoing {
				return Outcome{State: rs.settle(next, f), Result: result}
			}
		}
	}

	next = rs.settle(next, f)
	if s.Round < lastRound {
		return Outcome{State: next, Result: Ongoing}
	}
	return Outcome{State: next, Result: byHP(next.Gnomes[SideA].HP, next.Gnomes[SideB].HP)}
}

// settle copies the round's carried values into the next state.
func (rs *Ruleset) settle(next State, f [2]Vitals) State {
	for side := 0; side < 2; side++ {
		next.Gnomes[side].HP = f[side].HP
		next.Gnomes[side].Vulnerable = f[side].Vulnerable
		next.Gnomes[side].Strength = f[side].Strength
		if rs.StrengthLastsTheRound {
			next.Gnomes[side].Strength = 0
		}
		if rs.VulnerableLastsTheRound {
			next.Gnomes[side].Vulnerable = 0
		}
	}
	return next
}

func byHP(a, b int) Result {
	switch {
	case a > b:
		return AWins
	case b > a:
		return BWins
	}
	return Draw
}

// beatFacts are what a beat's Damage phase reads from its Interrupt phase.
type beatFacts struct {
	didCancel [2]bool // the gnome's card cancelled an opponent card this beat
	attacked  [2]bool // an opponent attack lands on the gnome this beat, not cancelled
}

// resolveDamageTier resolves both gnomes' effects of one tier in steps: step k applies
// effect k of each card together, every value read at the start of the step. A gnome
// takes the opponent's hit before the Counter damage its own hit triggered. hardest
// carries each gnome's hardest hit taken this round across tiers and beats. It returns
// the knockout result as soon as a step leaves a gnome at 0 HP or less.
func (rs *Ruleset) resolveDamageTier(f *[2]Vitals, hardest *[2]int, effects [2][]Effect, cards [2]CardID, facts beatFacts, tr *tracer) Result {
	var hitsTotal, hitsDone [2]int
	var doubled, doubleDecided [2]bool
	for side := 0; side < 2; side++ {
		for _, e := range effects[side] {
			if e.Kind.isHit() && !skipsHit(e, facts, side) {
				hitsTotal[side]++
			}
		}
	}
	steps := len(effects[0])
	if len(effects[1]) > steps {
		steps = len(effects[1])
	}

	for k := 0; k < steps; k++ {
		tr.step = k + 1
		var hitIn, counterIn, addVulnerable, selfVulnerable, addStrength, usedVulnerable [2]int
		var strip [2]bool
		for side := 0; side < 2; side++ {
			if k >= len(effects[side]) {
				continue
			}
			o := 1 - side
			e := effects[side][k]
			switch e.Kind {
			case Hit, HitBlock, HitPerVulnerable, HitHardest, HitIfNotAttacked:
				if skipsHit(e, facts, side) {
					continue
				}
				if rs.VulnerableDoublesOneHit {
					doubled[side] = f[o].Vulnerable > 0
				} else if !doubleDecided[side] {
					doubled[side], doubleDecided[side] = f[o].Vulnerable > 0, true
				}
				amount := e.N
				switch e.Kind {
				case HitBlock:
					amount = f[side].Block
				case HitPerVulnerable:
					amount = e.N * (1 + f[side].Vulnerable)
				case HitHardest:
					amount = hardest[side]
					if amount > e.N {
						amount = e.N
					}
				}
				amount += f[side].Strength
				if doubled[side] {
					amount *= 2
				}
				hitIn[o] += amount
				counterIn[side] += f[o].Counter
				hitsDone[side]++
				if doubled[side] && (rs.VulnerableDoublesOneHit || hitsDone[side] == hitsTotal[side]) {
					usedVulnerable[o]++
				}
			case ApplyVulnerable:
				addVulnerable[o] += e.N
			case GainVulnerable:
				selfVulnerable[side] += e.N
			case GainStrength:
				addStrength[side] += e.N
			case VulnerableIfCancelled:
				if facts.didCancel[side] {
					addVulnerable[o] += e.N
				}
			case StripBlock:
				strip[o] = true
			}
		}
		// vulnerableGained counts tokens from the opponent, selfGained a gnome's own; the
		// opponent's count against the cap first.
		var hitAbsorbed, counterAbsorbed, vulnerableGained, selfGained, strengthGained, stripped [2]int
		for side := 0; side < 2; side++ {
			hitAbsorbed[side] = f[side].take(hitIn[side])
			counterAbsorbed[side] = f[side].take(counterIn[side])
			if taken := hitIn[side] - hitAbsorbed[side]; taken > hardest[side] {
				hardest[side] = taken
			}
			if strip[side] {
				stripped[side], f[side].Block = f[side].Block, 0
			}
			v := f[side].Vulnerable - usedVulnerable[side]
			if v < 0 {
				v = 0
			}
			applied := capped(v+addVulnerable[side], rs.VulnerableCap)
			f[side].Vulnerable = capped(applied+selfVulnerable[side], rs.VulnerableCap)
			vulnerableGained[side] = applied - v
			selfGained[side] = f[side].Vulnerable - applied
			before := f[side].Strength
			f[side].Strength = capped(before+addStrength[side], rs.StrengthCap)
			strengthGained[side] = f[side].Strength - before
		}
		for side := 0; side < 2; side++ {
			if k >= len(effects[side]) {
				continue
			}
			o := 1 - side
			switch e := effects[side][k]; e.Kind {
			case Hit, HitBlock, HitPerVulnerable, HitHardest, HitIfNotAttacked:
				if skipsHit(e, facts, side) {
					break
				}
				tr.emit(HitLanded, Side(side), cards[side], hitIn[o]-hitAbsorbed[o], hitAbsorbed[o], doubled[side])
				if counterIn[side] > 0 {
					tr.emit(CounterHit, Side(side), cards[side], counterIn[side]-counterAbsorbed[side], counterAbsorbed[side], false)
				}
			case ApplyVulnerable:
				tr.emit(VulnerableApplied, Side(side), cards[side], vulnerableGained[o], 0, false)
			case GainVulnerable:
				tr.emit(VulnerableGained, Side(side), cards[side], selfGained[side], 0, false)
			case StripBlock:
				tr.emit(BlockStripped, Side(side), cards[side], stripped[o], 0, false)
			case VulnerableIfCancelled:
				if facts.didCancel[side] {
					tr.emit(VulnerableApplied, Side(side), cards[side], vulnerableGained[o], 0, false)
				}
			case GainStrength:
				tr.emit(StrengthGained, Side(side), cards[side], strengthGained[side], 0, false)
			}
		}
		tr.close(f)
		outA, outB := f[SideA].HP <= 0, f[SideB].HP <= 0
		switch {
		case outA && outB:
			return Draw
		case outB:
			return AWins
		case outA:
			return BWins
		}
	}
	return Ongoing
}

// skipsHit reports whether a conditional hit of side's card deals nothing this beat.
func skipsHit(e Effect, facts beatFacts, side int) bool {
	return e.Kind == HitIfNotAttacked && facts.attacked[side]
}
