package jointv1

// CreateTavern opens a tavern (a pub) for the calling user. One business
// (pub or farm) per address. The name is 3 to 24 bytes of printable ASCII.
func CreateTavern(cur realm, name string) {
	prev := cur.Previous()
	// validate everything first; mutate only after
	if !prev.IsUserCall() {
		panic("town: CreateTavern must be a direct user call")
	}
	assertNotPaused()
	assertNoSend()
	validateName(name)
	owner := prev.Address()
	key := owner.String()
	assertNoBusiness(key)

	now := CurrentGameHour()
	t := &Tavern{
		Owner:          owner,
		Name:           name,
		GoldCg:         params.StartGoldCg,
		Stock:          StartStock,
		PriceCg:        StartPriceCg,
		Rep:            StartRep,
		Seats:          StartSeats,
		LastHour:       now,
		Role:           RolePub,
		LastActionHour: now,
		ScoreGen:       seasonGen,
	}
	taverns.Set(key, t)
	joinTotals(t)
	writeSnapshot(now)
}

// GetTavern returns a copy of owner's tavern, or nil if there is none.
// Changing the copy does not change realm state.
func GetTavern(owner string) *Tavern {
	v := taverns.Get(owner)
	if v == nil {
		return nil
	}
	c := *(v.(*Tavern))
	return &c
}

// TavernCount returns the number of pubs in the town totals: dormant pubs
// and farms are not counted. Use TownStats for both the pub and the farm
// count, and BusinessCount for every stored business.
func TavernCount() int {
	return int(pubCount)
}

func validateName(name string) {
	if len(name) < MinNameLen || len(name) > MaxNameLen {
		panic("town: name must be 3 to 24 bytes")
	}
	for i := 0; i < len(name); i++ { // bounded by MaxNameLen
		c := name[i]
		if c < 0x20 || c > 0x7e {
			panic("town: name must be printable ASCII")
		}
	}
}

// Bounds and costs for tavern actions.
const (
	MinPriceCg int64 = 200
	MaxPriceCg int64 = 1200
	HireCostCg int64 = 12000
	MaxStock   int64 = 60
	BrewGrain  int64 = 12 // grain used per brew
	BrewHops   int64 = 3  // hops used per brew
	BrewAle    int64 = 12 // ale stock made per brew
)

// Every gold-only action has a public crossing wrapper that takes the actor
// from the direct user call, and an internal function that takes the actor
// address and applies the rules: validate, settle, check, mutate.

// SetPrice sets the caller's menu price for ale, 200 to 1200 centigold.
func SetPrice(cur realm, priceCg int64) {
	setPrice(userActor(cur), priceCg)
}

func setPrice(actor address, priceCg int64) {
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	if priceCg < MinPriceCg || priceCg > MaxPriceCg {
		panic("town: price must be 200 to 1200 centigold")
	}
	settleTavern(t)
	ownerActs(t) // every check passed: a dormant pub rejoins here
	old := t.PriceCg
	t.PriceCg = priceCg
	reweigh(t, old)
}

// Hire hires a barmaid for 12000 centigold, once per tavern. A barmaid
// raises the pub's weight (its pull on the customer pool) by 25%.
func Hire(cur realm) {
	hire(userActor(cur))
}

func hire(actor address) {
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	settleTavern(t)
	if t.HasBarmaid {
		panic("town: joint already has a barmaid")
	}
	if t.GoldCg < HireCostCg {
		panic("town: not enough gold")
	}
	ownerActs(t)
	t.GoldCg -= HireCostCg
	goldDestroyedCg += HireCostCg
	t.ProfitTodayCg -= HireCostCg
	t.SeasonProfitCg -= HireCostCg
	t.HasBarmaid = true
	reweigh(t, t.PriceCg)
}

// Brew turns 12 grain and 3 hops from the caller's inventory into 12 ale
// stock. It is refused if grain (checked first) or hops are short, or if
// stock would pass 60.
func Brew(cur realm) {
	brew(userActor(cur))
}

func brew(actor address) {
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	settleTavern(t)
	if t.Inv[GoodGrain] < BrewGrain {
		panic("town: not enough grain (a brew needs 12)")
	}
	if t.Inv[GoodHops] < BrewHops {
		panic("town: not enough hops (a brew needs 3)")
	}
	if t.Stock+BrewAle > MaxStock {
		panic("town: stock full (max 60)")
	}
	ownerActs(t)
	t.Inv[GoodGrain] -= BrewGrain
	t.Inv[GoodHops] -= BrewHops
	t.Stock += BrewAle
}

// userActor returns the caller of a gold-only action after checking it is a
// direct user call with no coins attached.
func userActor(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("town: must be a direct user call")
	}
	assertNoSend()
	return prev.Address()
}
