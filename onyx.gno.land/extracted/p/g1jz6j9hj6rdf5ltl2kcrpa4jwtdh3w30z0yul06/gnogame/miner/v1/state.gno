package miner

import (
	"errors"
	"strconv"
	"strings"
)

// Card is one owned card. RGB: the RGB edition (Pro and Max only).
type Card struct {
	T   int
	OC  int
	RGB bool
}

// HistoryEntry is one finished season (JS history item). Badge and Event
// are "" for JS null.
type HistoryEntry struct {
	Season int
	Value  float64 // Math.round(value)
	Mined  float64 // Math.round(mined)
	Badge  string
	Room   int
	Event  string
}

// State is one player's game state (the JS save object, version 3).
//
// Rigs holds card ids per rig slot, 0 = empty slot (JS null). Cards maps
// card id to card; nothing here depends on map iteration order (rigs are
// walked in slot order, JSON sorts the ids).
type State struct {
	Wallet       float64
	Pool         float64
	Last         int64
	LastClaim    int64
	SeasonStart  int64
	Room         int
	Rigs         [][]int
	Cards        map[int]*Card
	NextID       int
	Watch        int
	Mined        float64
	Value        float64
	SpentElec    float64
	Born         int64
	Season       int
	History      []HistoryEntry
	OffersBought []string

	// Gas caches, never encoded or compared (see groups and dayCache).
	// The methods keep them right; code that edits Cards or Rigs directly
	// after the state has settled must call Touch.
	gs   []group // installed cards by (model, overclock); valid when gsOK
	gsOK bool
	dc   dayCache
}

// Touch drops the gas caches. Call it after editing Cards or Rigs directly
// (not through the methods) on a state that has already settled.
func (st *State) Touch() {
	st.gs = nil
	st.gsOK = false
}

var (
	ErrNotEnough   = errors.New("Not enough BLK")
	ErrNotReleased = errors.New("Not released yet")
	ErrNoRGB       = errors.New("No RGB edition for this model")
	ErrLocked      = errors.New("This card is still locked")
	ErrNoSlot      = errors.New("No free slot: buy a rig or sell a card")
	ErrNoCard      = errors.New("No such card")
	ErrMaxOC       = errors.New("Already at max overclock")
	ErrRoomFull    = errors.New("Room is full: move to a bigger facility")
	ErrLargestRoom = errors.New("Already in the largest facility")
	ErrTopWatch    = errors.New("Monitoring is already at the top tier")
	ErrOfferTaken  = errors.New("Offer already taken")
	ErrNoRig       = errors.New("No such rig")
	ErrSameModel   = errors.New("This rig already runs only this model")
	ErrNoOCGain    = errors.New("No card here gains from another overclock level")
	ErrNoModel     = errors.New("No such card model") // JS crashes instead
	ErrNoOffer     = errors.New("No such offer")      // JS crashes instead
)

// NewState is JS newState(now): a fresh season 1 player.
func NewState(now int64) *State {
	return &State{
		Wallet:       StartWallet,
		Last:         now,
		LastClaim:    now,
		SeasonStart:  now,
		Room:         0,
		Rigs:         [][]int{{1, 0, 0, 0}},
		Cards:        map[int]*Card{1: {T: 1, OC: 0}},
		NextID:       2,
		Watch:        0,
		Born:         now,
		Season:       1,
		History:      []HistoryEntry{},
		OffersBought: []string{},
	}
}

func (st *State) season() int {
	if st.Season == 0 {
		return 1
	}
	return st.Season
}

// DayOf is JS dayOf(st, now): fractional season day of now.
func (st *State) DayOf(now int64) float64 {
	return float64(now-st.SeasonStart) / float64(Day)
}

// Px converts a real price to BLK on the day of now (JS px).
func (st *State) Px(now int64, base float64) float64 {
	vi, _ := st.viEv(st.DayOf(now))
	return pxVI(vi, base)
}

// viEv is ValueIndex(day) and eventMul(day, season) through the day cache:
// a Collect prices cards, overclocks and offers on the same few days the
// settles walk.
func (st *State) viEv(day float64) (float64, Event) {
	return st.dayInputs(floor(day), day, st.season())
}

// pxVI is Px with the value index of the day already known.
func pxVI(vi, base float64) float64 {
	return fmax(1, jsRound(base/vi))
}

// CardPrice is JS cardPrice(st, t, now). It panics on an unknown model.
func (st *State) CardPrice(t int, now int64) float64 {
	day := st.DayOf(now)
	vi, ev := st.viEv(day) // eventMul(floor(max(0, day))) is ev for day >= 0, none before
	if day < 0 {
		ev = noEvent
	}
	return pxVI(vi, realPriceEv(t, day, ev.Price))
}

// EditionPrice is JS editionPrice(st, t, now, rgb).
func (st *State) EditionPrice(t int, now int64, rgb bool) float64 {
	if rgb {
		return jsRound(st.CardPrice(t, now) * (1 + RGBCfg.Premium))
	}
	return st.CardPrice(t, now)
}

// CardStats is JS cardStats(c): hash (MH/s) and power (W) with overclock.
func CardStats(c Card) (mh, w float64) {
	b := &Models[c.T-1] // a pointer: copying the Model costs gas
	return b.MH * (1 + cOCMH*float64(c.OC)), b.W * (1 + cOCW*float64(c.OC))
}

// Boost is JS boost(st, day): the newcomer boost for a player who joined
// the season late.
func (st *State) Boost(day float64) float64 {
	joined := st.DayOf(st.Born)
	age := day - joined
	return 1 + cBoostX*fmin(1, joined/cBoostFull)*fmax(0, 1-age/cBoostDays)
}

// ElecPrice is JS elecPrice(st, day): BLK per kWh.
func (st *State) ElecPrice(day float64) float64 {
	return (Rooms[st.Room].Elec / ValueIndex(day)) * eventMul(day, st.season()).Elec
}

// Installed is JS installed(st): card ids in rig/slot order.
func (st *State) Installed() []int {
	out := []int{}
	for _, rig := range st.Rigs {
		for _, id := range rig {
			if id != 0 {
				out = append(out, id)
			}
		}
	}
	return out
}

// group is the installed cards of one (model, overclock) pair.
type group struct {
	t, oc, n int
	mh, w    float64 // per card
	wk       float64 // w/1000 (kW per card), the same division settle did per step
	hn, wn   float64 // n*mh, n*w
}

// groups returns the installed cards counted per (model, overclock). The
// first call walks the rigs in slot order; the result is kept in the state
// and the card methods (buy, sell, overclock, rig swap) update it in place,
// so a Collect that replays many actions walks the 80 cards of a big farm
// once instead of once per settle. The order of the groups (first seen,
// then added at the end) only changes float rounding, as grouping itself
// does (see the package comment). It is kept only while every card is
// installed (the game's invariant): otherwise a later overclock of a card
// outside the rigs could not be told apart, so it is walked every time.
func (st *State) groups() []group {
	if st.gsOK {
		return st.gs
	}
	gs, installed := st.walkGroups()
	if installed == len(st.Cards) {
		st.gs, st.gsOK = gs, true
	}
	return gs
}

// gAdd changes the count of group (t, oc) by d (cache only).
func (st *State) gAdd(t, oc, d int) {
	if !st.gsOK {
		return
	}
	gs := st.gs
	for i := range gs {
		g := &gs[i]
		if g.t == t && g.oc == oc {
			g.n += d
			if g.n == 0 {
				st.gs = append(gs[:i], gs[i+1:]...)
				return
			}
			g.hn = float64(g.n) * g.mh
			g.wn = float64(g.n) * g.w
			return
		}
	}
	if d < 0 { // not counted: the cache is wrong, drop it
		st.Touch()
		return
	}
	g := group{t: t, oc: oc, n: d}
	g.mh, g.w = CardStats(Card{T: t, OC: oc})
	g.wk = g.w / 1000
	g.hn = float64(g.n) * g.mh
	g.wn = float64(g.n) * g.w
	st.gs = append(gs, g)
}

// walkGroups walks the rigs in slot order and counts cards per (model,
// overclock); installed is the number of cards in the rigs. Gas: one map
// read and two field reads per card, no search.
func (st *State) walkGroups() (gs []group, installed int) {
	// Cards come from the actions, so 1 <= T <= 16 and OC >= 0; only OC
	// can leave the table (see OCMany), those cards go to the slow path.
	var cnt [8 * nModels]int
	order := make([]int, 0, 8)
	var odd []group
	for _, rig := range st.Rigs {
		for _, id := range rig {
			if id == 0 {
				continue
			}
			installed++
			c := st.Cards[id]
			oc := c.OC
			if oc < 8 {
				k := (c.T-1)*8 + oc
				if cnt[k] == 0 {
					order = append(order, k)
				}
				cnt[k]++
				continue
			}
			found := false
			for i := range odd {
				if odd[i].t == c.T && odd[i].oc == oc {
					odd[i].n++
					found = true
					break
				}
			}
			if !found {
				odd = append(odd, group{t: c.T, oc: oc, n: 1})
			}
		}
	}
	gs = make([]group, len(order), len(order)+len(odd))
	for i, k := range order {
		gs[i].t = k/8 + 1
		gs[i].oc = k % 8
		gs[i].n = cnt[k]
	}
	gs = append(gs, odd...)
	for i := range gs {
		g := &gs[i]
		g.mh, g.w = CardStats(Card{T: g.t, OC: g.oc})
		g.wk = g.w / 1000
		g.hn = float64(g.n) * g.mh
		g.wn = float64(g.n) * g.w
	}
	return gs, installed
}

// Rates is the result of JS rates(st, day). On lists the ids of the cards
// that run (profitable), in installed order.
type Rates struct {
	On    []int
	Hash  float64
	Watts float64
	Gross float64
	Elec  float64
	Net   float64
	PerMH float64
	R     float64
	N     float64
	Boost float64
}

// dayEnv holds the per-day inputs of a settle step.
type dayEnv struct {
	r, n, e, perMH, boost float64
}

// envAt: vi = ValueIndex(day), ev = the day's event multipliers,
// roomElec = Rooms[st.Room].Elec.
func (st *State) envAt(day, vi float64, ev Event, roomElec float64) dayEnv {
	ep := Epoch(day)
	r := cR0 / powInt(pow2Table, 2, ep)
	n := netHashAt(day, ep, ev)
	e := (roomElec / vi) * ev.Elec
	b := st.Boost(day)
	perMH := ((60 * r) / n) * b * ev.Hash
	return dayEnv{r: r, n: n, e: e, perMH: perMH, boost: b}
}

func (st *State) env(day float64) dayEnv {
	return st.envAt(day, ValueIndex(day), eventMul(day, st.season()), Rooms[st.Room].Elec)
}

// sumGroups adds up the running cards: total hash and watts.
func sumGroups(gs []group, env dayEnv) (h, w float64) {
	return sumGroupsAt(gs, env.perMH, env.e)
}

func sumGroupsAt(gs []group, perMH, e float64) (h, w float64) {
	for i := range gs {
		g := &gs[i]
		if g.mh*perMH > g.wk*e {
			h += g.hn
			w += g.wn
		}
	}
	return h, w
}

// Rates is JS rates(st, day).
func (st *State) Rates(day float64) Rates {
	env := st.env(day)
	gs := st.groups()
	h, w := sumGroups(gs, env)
	on := []int{}
	for _, id := range st.Installed() {
		mh, cw := CardStats(*st.Cards[id])
		if mh*env.perMH > (cw/1000)*env.e {
			on = append(on, id)
		}
	}
	gross := h * env.perMH
	elec := (w / 1000) * env.e
	return Rates{On: on, Hash: h, Watts: w, Gross: gross, Elec: elec, Net: gross - elec,
		PerMH: env.perMH, R: env.r, N: env.n, Boost: env.boost}
}

// Economics is the result of JS cardEconomics.
type Economics struct {
	Gross, Elec, Net float64
	Profitable       bool
}

// CardEconomics is JS cardEconomics(st, c, day): one card's hourly result.
func (st *State) CardEconomics(c Card, day float64) Economics {
	return cardEcon(c, st.env(day))
}

func cardEcon(c Card, env dayEnv) Economics {
	mh, w := CardStats(c)
	gross := mh * env.perMH
	elec := (w / 1000) * env.e
	return Economics{Gross: gross, Elec: elec, Net: gross - elec, Profitable: gross > elec}
}

// ---------- season ----------

// SeasonEnd is JS seasonEnd(st).
func (st *State) SeasonEnd() int64 {
	return st.SeasonStart + cSeasonDays*Day
}

// SeasonOver is JS seasonOver(st, now).
func (st *State) SeasonOver(now int64) bool { return now >= st.SeasonEnd() }

// BadgeOf is JS badgeOf(value): the highest badge reached, ok=false if none.
func BadgeOf(value float64) (Badge, bool) {
	var b Badge
	ok := false
	for _, x := range Badges {
		if value >= x.Min {
			b = x
			ok = true
		}
	}
	return b, ok
}

// NewSeason is JS newSeason(st, now, event): settles, writes the season to
// history and returns the next season's state (seasonStart = now, as in JS;
// a realm with shared seasons sets SeasonStart/Born itself). event "" is
// JS null.
func (st *State) NewSeason(now int64, event string) *State {
	st.Settle(now)
	badge, ok := BadgeOf(st.Value)
	name := ""
	start := []int{1}
	if ok {
		name = badge.Name
		start = badge.Start
	}
	history := []HistoryEntry{}
	history = append(history, st.History...)
	history = append(history, HistoryEntry{Season: st.season(), Value: jsRound(st.Value), Mined: jsRound(st.Mined),
		Badge: name, Room: st.Room, Event: event})
	next := NewState(now)
	next.Season = st.season() + 1
	next.History = history
	next.Cards = map[int]*Card{}
	next.Rigs = [][]int{{0, 0, 0, 0}}
	for k, t := range start {
		next.Cards[k+1] = &Card{T: t}
		next.Rigs[0][k] = k + 1
	}
	next.NextID = len(start) + 1
	return next
}

// ---------- time ----------

// WatchHours is JS watchHours(st).
func (st *State) WatchHours() int { return WatchTiers[st.Watch] }

// Settle is JS settle(st, now): mines from Last up to now, capped by the
// watch window after the last collect and by the season end, in one hour
// steps. Returns the BLK mined.
func (st *State) Settle(now int64) float64 {
	end := now
	if w := st.LastClaim + int64(st.WatchHours())*Hour; w < end {
		end = w
	}
	if se := st.SeasonEnd(); se < end {
		end = se
	}
	t := st.Last
	var got, elec, value float64
	if t < end {
		gs := st.groups()
		season := st.season()
		roomElec := Rooms[st.Room].Elec
		// boost(st, day) = 1 + X*min(1, joined/Full)*max(0, 1-(day-joined)/Days)
		joined := st.DayOf(st.Born)
		boostJ := cBoostX * fmin(1, joined/cBoostFull)
		ss := float64(st.SeasonStart)
		// The value index and the event change once a day (st.dc keeps
		// them across settles), the reward once an epoch. The day's bounds
		// [dayLo, dayHi) start empty so the first step fills them.
		dayLo, dayHi := 1.0, 0.0
		cacheEp := -1
		var vi, r, e, evHash, evNet float64
		// The step is netHashAt, boost and sumGroupsAt inlined (same
		// operations in the same order): function calls cost gas.
		for t < end {
			dt := Step
			if end-t < dt {
				dt = end - t
			}
			day := (float64(t) + float64(dt)/2 - ss) / float64(Day)
			if !(day >= dayLo && day < dayHi) {
				fd := floor(day)
				dayLo, dayHi = fd, fd+1
				var ev Event
				vi, ev = st.dayInputs(fd, day, season)
				e = (roomElec / vi) * ev.Elec
				evHash, evNet = ev.Hash, ev.Net
			}
			d := day // fmax(0, day)
			if 0 > day {
				d = 0
			}
			ep := int(d / cHalvingDays) // Epoch(day): d >= 0, so int() is floor
			if ep != cacheEp {
				cacheEp = ep
				r = cR0 / powInt(pow2Table, 2, ep)
			}
			n := cN0 * fexp(cGrowth*d)
			since := d - float64(ep*cHalvingDays)
			if ep > 0 && since < cCapDays {
				n *= 1 - cCapitulation*(1-since/cCapDays)
			}
			n = n * evNet
			x := 1 - (day-joined)/cBoostDays
			if 0 > x {
				x = 0
			}
			b := 1 + boostJ*x
			perMH := ((60 * r) / n) * b * evHash
			var h, w float64
			for i := range gs {
				g := &gs[i]
				if g.mh*perMH > g.wk*e {
					h += g.hn
					w += g.wn
				}
			}
			gross := h * perMH
			el := (w / 1000) * e
			net := gross - el
			fdt := float64(dt)
			q := (net * fdt) / float64(Hour)
			got += q
			value += q * vi
			elec += (el * fdt) / float64(Hour)
			t += dt
		}
	}
	st.Pool += got
	st.Mined += got
	st.Value = st.Value + value
	st.SpentElec += elec
	if now > st.Last {
		st.Last = now
	}
	return got
}

// dayCache keeps the inputs of one whole day (see dayInputs).
type dayCache struct {
	ok     bool
	fd     float64
	season int
	vi     float64
	ev     Event
}

// dayInputs returns ValueIndex(day) and eventMul(day, season), which only
// depend on fd = floor(day) and the season, from st.dc when that day was
// the last one asked for: the settle of each replayed action and the claim
// mostly fall on the same day.
func (st *State) dayInputs(fd, day float64, season int) (float64, Event) {
	c := &st.dc
	if c.ok && c.fd == fd && c.season == season {
		return c.vi, c.ev
	}
	vi, ev := ValueIndex(day), eventMul(day, season)
	*c = dayCache{ok: true, fd: fd, season: season, vi: vi, ev: ev}
	return vi, ev
}

// Stopped is JS stopped(st, now): mining has stopped until the next collect.
func (st *State) Stopped(now int64) bool {
	return now >= st.LastClaim+int64(st.WatchHours())*Hour
}

// Claim is JS claim(st, now): settles and moves the pool to the wallet.
func (st *State) Claim(now int64) float64 {
	st.Settle(now)
	got := st.Pool
	st.Wallet += got
	st.Pool = 0
	st.LastClaim = now
	return got
}

// ---------- market ----------

// Unlocked is JS unlocked(st, t).
func (st *State) Unlocked(t int) bool {
	return validModel(t) && st.Value >= Models[t-1].Unlock
}

// Available is JS available(st, t, now).
func (st *State) Available(t int, now int64) bool {
	return Released(t, st.DayOf(now)) && st.Unlocked(t)
}

func (st *State) spend(p float64) error {
	if st.Wallet < p {
		return ErrNotEnough
	}
	st.Wallet -= p
	return nil
}

// FreeSlot is JS freeSlot(st); ok=false when every slot is taken.
func (st *State) FreeSlot() (rig, slot int, ok bool) {
	for r, row := range st.Rigs {
		for s, id := range row {
			if id == 0 {
				return r, s, true
			}
		}
	}
	return 0, 0, false
}

// BuyCard is JS buyCard(st, t, now, null, false, rgb): buys model t at the
// market price into the first free slot. Returns the new card id.
func (st *State) BuyCard(t int, now int64, rgb bool) (int, error) {
	return st.buyCard(t, now, 0, false, false, rgb)
}

// BuyCardAt is JS buyCard with an explicit price (offer=true skips the lock).
func (st *State) BuyCardAt(t int, now int64, price float64, offer, rgb bool) (int, error) {
	return st.buyCard(t, now, price, true, offer, rgb)
}

func (st *State) buyCard(t int, now int64, price float64, hasPrice, offer, rgb bool) (int, error) {
	st.Settle(now)
	if !validModel(t) {
		return 0, ErrNoModel
	}
	if !Released(t, st.DayOf(now)) {
		return 0, ErrNotReleased
	}
	if rgb && !RGBOk(t) {
		return 0, ErrNoRGB
	}
	if !hasPrice {
		price = st.EditionPrice(t, now, rgb)
	}
	if !st.Unlocked(t) && !offer {
		return 0, ErrLocked
	}
	r, s, ok := st.FreeSlot()
	if !ok {
		return 0, ErrNoSlot
	}
	if err := st.spend(price); err != nil {
		return 0, err
	}
	id := st.NextID
	st.NextID++
	st.Cards[id] = &Card{T: t, RGB: rgb}
	st.Rigs[r][s] = id
	st.gAdd(t, 0, 1)
	return id, nil
}

// SellValue is JS sellValue(st, c, now).
func (st *State) SellValue(c Card, now int64) float64 {
	return sellValueAt(c, st.CardPrice(c.T, now))
}

func sellValueAt(c Card, cardPrice float64) float64 {
	back := SellBack
	if c.RGB {
		back = cRGBSellBack
	}
	return floor(cardPrice * back)
}

// SellCard is JS sellCard(st, id, now). Returns the BLK received.
func (st *State) SellCard(id int, now int64) (float64, error) {
	st.Settle(now)
	c, ok := st.Cards[id]
	if !ok {
		return 0, ErrNoCard
	}
	for _, rig := range st.Rigs {
		for i, x := range rig {
			if x == id {
				rig[i] = 0
				break
			}
		}
	}
	delete(st.Cards, id)
	st.gAdd(c.T, c.OC, -1)
	v := st.SellValue(*c, now)
	st.Wallet += v
	return v, nil
}

// OCPrice is JS ocPrice(st, c, now); ok=false at max overclock (JS null).
func (st *State) OCPrice(c Card, now int64) (float64, bool) {
	vi, _ := st.viEv(st.DayOf(now))
	return ocPriceVI(c, vi)
}

func ocPriceVI(c Card, vi float64) (float64, bool) {
	if c.OC >= cOCMax {
		return 0, false
	}
	return pxVI(vi, Models[c.T-1].Price*cOCCost*float64(c.OC+1)), true
}

// Overclock is JS overclock(st, id, now). Returns the price paid.
func (st *State) Overclock(id int, now int64) (float64, error) {
	st.Settle(now)
	c, ok := st.Cards[id]
	if !ok {
		return 0, ErrNoCard
	}
	p, ok := st.OCPrice(*c, now)
	if !ok {
		return 0, ErrMaxOC
	}
	if err := st.spend(p); err != nil {
		return 0, err
	}
	st.gAdd(c.T, c.OC, -1)
	c.OC++
	st.gAdd(c.T, c.OC, 1)
	return p, nil
}

// RigPrice is JS rigPrice(st, now); ok=false when the room is full.
func (st *State) RigPrice(now int64) (float64, bool) {
	if len(st.Rigs) >= Rooms[st.Room].Rigs {
		return 0, false
	}
	return st.Px(now, cRigBase*powInt(powRigTable, cRigGrowth, len(st.Rigs)-1)), true
}

// BuyRig is JS buyRig(st, now). Returns the price paid.
func (st *State) BuyRig(now int64) (float64, error) {
	st.Settle(now)
	p, ok := st.RigPrice(now)
	if !ok {
		return 0, ErrRoomFull
	}
	if err := st.spend(p); err != nil {
		return 0, err
	}
	st.Rigs = append(st.Rigs, make([]int, Rooms[st.Room].Slots))
	return p, nil
}

// RoomPrice is JS roomPrice(st, now); ok=false in the largest room.
func (st *State) RoomPrice(now int64) (float64, bool) {
	if st.Room+1 >= len(Rooms) {
		return 0, false
	}
	return st.Px(now, Rooms[st.Room+1].Price), true
}

// MoveRoom is JS moveRoom(st, now). Returns the price paid.
func (st *State) MoveRoom(now int64) (float64, error) {
	st.Settle(now)
	p, ok := st.RoomPrice(now)
	if !ok {
		return 0, ErrLargestRoom
	}
	if err := st.spend(p); err != nil {
		return 0, err
	}
	st.Room++
	slots := Rooms[st.Room].Slots
	for i, rig := range st.Rigs {
		for len(rig) < slots {
			rig = append(rig, 0)
		}
		st.Rigs[i] = rig
	}
	return p, nil
}

// WatchPrice is JS watchPrice(st, now); ok=false at the top tier.
func (st *State) WatchPrice(now int64) (float64, bool) {
	if st.Watch+1 >= len(WatchTierPrice) {
		return 0, false
	}
	return st.Px(now, WatchTierPrice[st.Watch+1]), true
}

// UpgradeWatch is JS upgradeWatch(st, now). Returns the price paid.
func (st *State) UpgradeWatch(now int64) (float64, error) {
	st.Settle(now)
	p, ok := st.WatchPrice(now)
	if !ok {
		return 0, ErrTopWatch
	}
	if err := st.spend(p); err != nil {
		return 0, err
	}
	st.Watch++
	return p, nil
}

// Offer is one daily offer (JS offers item).
type Offer struct {
	K     int
	Day   int
	T     int
	Price float64
	Early bool
	Off   float64
	RGB   bool
}

// Offers is JS offers(st, now): the same three offers for everyone each
// day; the third is early access to the next locked model when there is
// one. Returns nil before the season starts (JS crashes there).
func (st *State) Offers(now int64) []Offer {
	day := st.DayOf(now)
	fd := floor(day)
	d := int(fd)
	// available(st, t, now) and the first released locked model, in one
	// pass by index (copying each Model costs gas).
	open := []int{}
	next := 0
	for i := range Models {
		m := &Models[i]
		if day < float64(m.Release) {
			continue
		}
		if st.Value >= m.Unlock {
			open = append(open, m.T)
		} else if next == 0 {
			next = m.T
		}
	}
	if len(open) == 0 && next == 0 {
		return nil
	}
	pool := []int{}
	from := len(open) - 6
	if from < 0 {
		from = 0
	}
	pool = append(pool, open[from:]...)
	list := []Offer{}
	for k := 0; k < 3; k++ {
		early := k == 2 && next != 0
		div := len(pool)
		if div < 1 {
			div = 1
		}
		pick := int(floor((Noise(fd, 50+k)+1)/2*float64(len(pool)))) % div
		var t int
		if early {
			t = next
		} else if len(pool) > 0 {
			t = pool[pick]
			rest := []int{}
			for i, x := range pool {
				if i != pick {
					rest = append(rest, x)
				}
			}
			pool = rest
		} else if len(open) > 0 {
			t = open[0]
		} else {
			return nil
		}
		off := 0.0
		if !early {
			off = 0.15 + jsRound((Noise(fd, 60+k)+1)/2*4)*0.05
		}
		rgb := !early && RGBOk(t) && Noise(fd, 70+k) > 0.2
		mul := 1 - off
		if early {
			mul = 1.25
		}
		price := fmax(1, jsRound(st.EditionPrice(t, now, rgb)*mul))
		list = append(list, Offer{K: k, Day: d, T: t, Price: price, Early: early, Off: off, RGB: rgb})
	}
	return list
}

// BuyOffer is JS buyOffer(st, k, now). The offers are read before the
// settle, as in JS. Returns the new card id.
func (st *State) BuyOffer(k int, now int64) (int, error) {
	os := st.Offers(now)
	if k < 0 || k >= len(os) {
		return 0, ErrNoOffer
	}
	o := os[k]
	prefix := strconv.Itoa(o.Day) + ":"
	key := prefix + strconv.Itoa(k)
	for _, x := range st.OffersBought {
		if x == key {
			return 0, ErrOfferTaken
		}
	}
	id, err := st.buyCard(o.T, now, o.Price, true, true, o.RGB)
	if err != nil {
		return 0, err
	}
	kept := []string{}
	for _, x := range st.OffersBought {
		if strings.HasPrefix(x, prefix) {
			kept = append(kept, x)
		}
	}
	st.OffersBought = append(kept, key)
	return id, nil
}

// ---------- turn a rig into one model ----------

// RigPlan is the result of JS rigPlan (and rigSwap, with IDs).
type RigPlan struct {
	Buys   int
	Keep   int
	Sell   []int
	Refund float64
	Price  float64
	Cost   float64
	Net    float64
	LostOC int
	IDs    []int // new card ids (RigSwap only)
}

// RigPlan is JS rigPlan(st, r, t, now, rgb): fill rig r with model t.
func (st *State) RigPlan(r, t int, now int64, rgb bool) (RigPlan, error) {
	if r < 0 || r >= len(st.Rigs) {
		return RigPlan{}, ErrNoRig
	}
	if !validModel(t) {
		return RigPlan{}, ErrNoModel
	}
	if !Released(t, st.DayOf(now)) {
		return RigPlan{}, ErrNotReleased
	}
	if !st.Unlocked(t) {
		return RigPlan{}, ErrLocked
	}
	if rgb && !RGBOk(t) {
		return RigPlan{}, ErrNoRGB
	}
	price := st.EditionPrice(t, now, rgb)
	p := RigPlan{Sell: []int{}, Price: price}
	// card price per model, computed once (gas); same value every time
	var memo [17]float64
	for _, id := range st.Rigs[r] {
		var c *Card
		if id != 0 {
			c = st.Cards[id]
		}
		if c != nil && c.T == t && c.RGB == rgb {
			p.Keep++
			continue
		}
		if c != nil {
			if memo[c.T] == 0 {
				memo[c.T] = st.CardPrice(c.T, now)
			}
			p.Refund += sellValueAt(*c, memo[c.T])
			p.LostOC += c.OC
			p.Sell = append(p.Sell, id)
		}
		p.Buys++
	}
	p.Cost = float64(p.Buys) * price
	p.Net = float64(p.Buys)*price - p.Refund
	return p, nil
}

// RigSwap is JS rigSwap(st, r, t, now, rgb).
func (st *State) RigSwap(r, t int, now int64, rgb bool) (RigPlan, error) {
	st.Settle(now)
	p, err := st.RigPlan(r, t, now, rgb)
	if err != nil {
		return p, err
	}
	if p.Buys == 0 {
		return p, ErrSameModel
	}
	if st.Wallet < p.Net {
		return p, ErrNotEnough
	}
	rig := st.Rigs[r]
	for _, id := range p.Sell {
		for i, x := range rig {
			if x == id {
				rig[i] = 0
				break
			}
		}
		if c, ok := st.Cards[id]; ok {
			st.gAdd(c.T, c.OC, -1)
		}
		delete(st.Cards, id)
	}
	st.Wallet -= p.Net
	p.IDs = []int{}
	for k, id := range rig {
		if id != 0 {
			continue
		}
		nid := st.NextID
		st.NextID++
		st.Cards[nid] = &Card{T: t, RGB: rgb}
		st.gAdd(t, 0, 1)
		rig[k] = nid
		p.IDs = append(p.IDs, nid)
	}
	return p, nil
}

// ---------- overclock many ----------

// OCItem is one entry of an overclock plan.
type OCItem struct {
	ID    int
	Price float64
	Gain  float64
}

// OCPlan is the result of JS ocPlan.
type OCPlan struct {
	Items []OCItem
	Cost  float64
	Gain  float64
}

// OCPlan is JS ocPlan(st, ids, now): the cards whose next overclock level
// raises the hourly net, fastest payback first (stable, like JS sort).
// Duplicate ids are ignored after their first occurrence.
func (st *State) OCPlan(ids []int, now int64) OCPlan {
	day := st.DayOf(now)
	vi, ev := st.viEv(day)
	env := st.envAt(day, vi, ev, Rooms[st.Room].Elec)
	items := []OCItem{}
	// A card listed twice counts once (JS iterates new Set(ids): first
	// occurrence order).
	seen := make(map[int]bool, len(ids))
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		c, ok := st.Cards[id]
		if !ok {
			continue
		}
		price, ok := ocPriceVI(*c, vi)
		if !ok {
			continue
		}
		before := cardEcon(*c, env)
		up := *c
		up.OC++
		after := cardEcon(up, env)
		a, b := 0.0, 0.0
		if after.Profitable {
			a = after.Net
		}
		if before.Profitable {
			b = before.Net
		}
		gain := a - b
		if gain > 0 {
			items = append(items, OCItem{ID: id, Price: price, Gain: gain})
		}
	}
	// stable insertion sort by price/gain
	for i := 1; i < len(items); i++ {
		x := items[i]
		j := i
		for j > 0 && x.Price/x.Gain-items[j-1].Price/items[j-1].Gain < 0 {
			items[j] = items[j-1]
			j--
		}
		items[j] = x
	}
	p := OCPlan{Items: items}
	for _, x := range items {
		p.Cost += x.Price
	}
	for _, x := range items {
		p.Gain += x.Gain
	}
	return p
}

// OCResult is the result of JS ocMany.
type OCResult struct {
	N    int
	Cost float64
	Gain float64
	IDs  []int
	All  int
}

// OCMany is JS ocMany(st, ids, now): overclocks as many of the planned
// cards as the wallet allows, in plan order.
func (st *State) OCMany(ids []int, now int64) (OCResult, error) {
	st.Settle(now)
	p := st.OCPlan(ids, now)
	if len(p.Items) == 0 {
		return OCResult{}, ErrNoOCGain
	}
	res := OCResult{IDs: []int{}, All: len(p.Items)}
	for _, x := range p.Items {
		if st.Wallet < x.Price {
			continue
		}
		st.Wallet -= x.Price
		c := st.Cards[x.ID]
		st.gAdd(c.T, c.OC, -1)
		c.OC++
		st.gAdd(c.T, c.OC, 1)
		res.N++
		res.Cost += x.Price
		res.Gain += x.Gain
		res.IDs = append(res.IDs, x.ID)
	}
	if res.N == 0 {
		return res, ErrNotEnough
	}
	return res, nil
}
