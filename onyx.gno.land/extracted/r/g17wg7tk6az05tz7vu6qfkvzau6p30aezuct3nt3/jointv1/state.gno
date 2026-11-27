// Package town is The Joint game realm: joints, params and admin.
// The realm has no background loop; time is read from the block (time.Now())
// and converted to game hours on demand.
package jointv1

import (
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
)

// Goods index into Tavern.Inv.
const (
	GoodAle   = 0
	GoodGrain = 1
	GoodHops  = 2
	GoodMead  = 3
)

// Starting values for a new tavern.
const (
	StartStock   int64 = 18
	StartPriceCg int64 = 600
	StartRep     int64 = 360
	StartSeats   int64 = 5
)

// Bounds for caller-set values.
const (
	MinNameLen                = 3
	MaxNameLen                = 24
	MinSecondsPerGameHour     = 10
	MaxSecondsPerGameHour     = 3600
	MinPotBps                 = 0
	MaxPotBps                 = 10000
	defaultSecondsPerGameHour = 60
	defaultPotBps             = 7000
	defaultStartGoldCg        = 24000
)

// noKeyAdmin is used only when init sees an empty deployer address, which
// happens in the gno test VM (package init runs with an empty caller) and never
// on chain, where addpkg always has a signer. It is the raw bytes
// "noadmin_____________", not derived from any public key, so nobody can sign
// as it: on chain the fallback would leave the realm with no usable admin.
// Tests act as admin through Admin().
const noKeyAdmin address = "g1dehkzerdd9h97h6lta047h6lta047h6l4mazdj"

// Params are the admin-tunable game settings.
type Params struct {
	SecondsPerGameHour, PotBps, StartGoldCg int64
	Paused                                  bool
}

// Business roles (Tavern.Role). One business per address across both roles.
const (
	RolePub  int64 = 0
	RoleFarm int64 = 1
)

// ReferencePriceCg is the fixed market price a pub's weight is measured
// against. It is fixed (not the moving town price) so the incrementally kept
// town totals stay valid when the market moves.
const ReferencePriceCg int64 = 600

// Starting values for a new farm. FarmStartPlots stays within
// townmath.MaxFarmPlots (checked by the roles tests).
const (
	FarmStartPlots int64 = 1
	FarmStartGrain int64 = 6
)

// Tavern is one player's business: a pub (Role RolePub) or a farm (Role
// RoleFarm). Money is in centigold (Cg).
// LastHour is the last game hour settled. ProfitTodayCg is the profit of the
// game day LastHour/24. LastTaxDay is 1 + the last game day taxed (0 = never).
// ScoreDayStart is SeasonScore when the current game day began; the day's
// score gain is capped from it.
// Plots is a farm's plot count. Weight is a pub's pull on the customer pool
// as counted in totalWeight (always 0 for a farm). Carry is, for a pub, the
// fraction of a customer (0..999 thousandths) its pool share carries to the
// next hour; for a farm, the fraction of a crop unit (0..9999 ten-thousandths)
// its harvest carries to the next settle. AdLevel and AdEndHour are reserved for ads (0 until then).
// Crop is what a farm grows (townmath.CropGrain or CropHops; 0, grain, by
// default). TFDay is the game day TFSold and TFBought count: the units this
// business sold to and bought from the Town Farm on that day.
// Dormant is 1 for a pub the idle pass removed from the town totals (0
// otherwise; farms are never dormant). LastActionHour is the game hour of
// the owner's last own action (creation, SetPrice, Hire, Brew, BuyGood,
// BuyListing, the crew actions, the owner's own Settle); a third party's Settle never moves it. OpenListings is the
// number of the seller's listings still open. Crew holds a pub's crew
// villager ids ("" = empty slot) and CrewRestUntil the game hour each slot's
// day off ends (see crew.gno).
// HasFloor is set by the GNOT floor item; it adds FloorSeatsBonus seats once.
// SeasonProd is the units a farm has harvested this season (its season
// score is that total, capped per day, not gold). ScoreGen is the season
// generation those season fields were scored in. StartSeason bumps the
// town's generation and the next settle clears a tavern whose ScoreGen is
// behind, so old scores are not walked at the start.
// Every field is a value type (no slices, maps or pointers), so the shallow
// copy GetTavern returns never aliases realm state. Keep it that way.
type Tavern struct {
	Owner                                                  address
	Name                                                   string
	GoldCg, Stock, PriceCg, Rep, Seats                     int64
	Inv                                                    [4]int64
	HasBarmaid, HasNeon, HasFloor                          bool
	LastHour                                               int64
	ProfitTodayCg, SeasonProfitCg, SeasonScore, LastTaxDay int64
	ScoreDayStart                                          int64
	Role, Plots, Weight, Carry, AdLevel, AdEndHour         int64
	Crop, TFDay, TFSold, TFBought                          int64
	Dormant, LastActionHour, OpenListings                  int64
	Crew                                                   [MaxCrew]string
	CrewRestUntil                                          [MaxCrew]int64
	SeasonProd, ScoreGen                                   int64
}

var (
	admin       *ownable.Ownable
	params      Params
	genesisUnix int64
	// Game clock: CurrentGameHour = hourBase + (now - anchorUnix) / SecondsPerGameHour.
	// SetSecondsPerGameHour re-anchors so a speed change never re-maps past time.
	hourBase   int64
	anchorUnix int64
	taverns    avl.Tree // owner address string -> *Tavern (pubs and farms)
	// Town totals, kept incrementally (see reweigh in farm.gno).
	pubCount     int64
	farmCount    int64
	totalWeight  int64 // sum of Weight over pubs
	totalPriceCg int64 // sum of PriceCg over pubs
	// sum of PriceCg * Weight over pubs (at most 1200 * 5.6e6 per pub, so
	// safe in int64 for millions of pubs): the pool elasticity uses the
	// weight-weighted average price totalPriceWeight / totalWeight
	totalPriceWeight int64
	// Town Farm counters of game day tfDay: units it sold to pubs and
	// bought from farms. The first trade of another day resets them.
	tfDay          int64
	tfSoldGlobal   int64
	tfBoughtGlobal int64
	// Gold flow (centigold): all gold the game created (customer revenue,
	// Town Farm purchases from farms) and destroyed (tax, hires, Town Farm
	// sales to pubs). Start capital is the baseline and is not counted, so
	// the sum of all GoldCg = businesses * StartGoldCg + created - destroyed.
	goldCreatedCg   int64
	goldDestroyedCg int64
	// GNOT shop. potUgnot is the live pot (sales while a season is frozen
	// still add here, and become the next season's pot). treasuryUgnot is
	// what treasuryAddr may withdraw. packCounter is mixed into pack seeds.
	// pubPotBps is the pubs' share of a frozen pot; farms receive the rest.
	// seasonGen increments in StartSeason. season is the one frozen snapshot.
	potUgnot      int64
	treasuryUgnot int64
	treasuryAddr  address
	packCounter   uint64
	pubPotBps     int64 = 6000
	seasonGen     int64
	season        Season
)

func init(cur realm) {
	deployer := cur.Previous().Address()
	if deployer == "" {
		deployer = noKeyAdmin
	}
	admin = ownable.NewWithAddress(deployer)
	params = Params{
		SecondsPerGameHour: defaultSecondsPerGameHour,
		PotBps:             defaultPotBps,
		StartGoldCg:        defaultStartGoldCg,
	}
	genesisUnix = time.Now().Unix()
	hourBase = 0
	anchorUnix = genesisUnix
}

// GetParams returns a copy of the current params.
func GetParams() Params {
	return params
}

// CurrentGameHour is the number of whole game hours since deployment. Hours
// are continuous: a speed change applies only to time after the change.
// Never negative and never decreasing while block time moves forward.
func CurrentGameHour() int64 {
	elapsed := time.Now().Unix() - anchorUnix
	if elapsed < 0 {
		elapsed = 0
	}
	return hourBase + elapsed/params.SecondsPerGameHour
}

// GameClock returns the hour base and anchor time (unix seconds) that
// CurrentGameHour counts from.
func GameClock() (int64, int64) {
	return hourBase, anchorUnix
}

// GenesisUnix is the block time (unix seconds) at deployment.
func GenesisUnix() int64 {
	return genesisUnix
}
