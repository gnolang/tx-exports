// Package miner is the economy of GnoGame "Miner", a GPU mining game. It is
// the Gno twin of web/miner/economy.js: the season realm replays each
// player's logged actions with this package, so it must behave exactly like
// the JavaScript the browser runs.
//
// The golden vectors in z_vectors_test.gno are generated from economy.js by
// tools/miner-vectors.mjs. Change a rule in either file and regenerate them.
//
// Conventions kept from the JavaScript:
//   - Time is int64 milliseconds (now, Last, SeasonStart, ...).
//   - Money and value are float64, computed in the same order of operations.
//   - Math.round(x) is jsRound (nearest, ties toward +Inf), Math.floor is
//     math.Floor, `**` is math.Pow, Math.exp is math.Exp.
//   - JS throws Error(msg); here the same msg comes back as an error value.
//     As in JS, actions settle first, so on error the settle has already
//     been applied to the state.
//
// Differences on purpose:
//   - settle and Rates group installed cards by (model, overclock), so the
//     cost of one settle step grows with the number of distinct models, not
//     with the number of cards. Results equal the JS up to float rounding.
//   - Inputs that only crash the JS (unknown model, unknown card id for
//     overclock, unknown offer index) return errors here.
//   - migrate (save versions 1 and 2) and UI helpers are not ported; chain
//     state starts at version 3.
package miner

import "math"

// Token is the in-game currency name (working name).
const Token = "BLK"

// DisplayScale: network and block reward are shown scaled by this factor.
const DisplayScale = 1000

// Version of the state format (JS `v`).
const Version = 3

const (
	Hour int64 = 3600000
	Day  int64 = 24 * Hour
	// Step is the settle step: one hour, the same in JS.
	Step int64 = 60 * 60000
)

// Hot-path copies of the parameters below. Reading a package variable costs
// gas on every access, a constant costs nothing. Every use keeps a variable
// operand next to the constant, so no constant folding changes a result
// (1 + RGBCfg.Premium, for example, is left on the variable).
const (
	cR0           = 5.0
	cHalvingDays  = 7
	cN0           = 150.0
	cGrowth       = 0.07
	cCapitulation = 0.25
	cCapDays      = 3.0
	cSeasonDays   = 28

	cValuePerHalving = 1.8
	cValueRun        = 0.12
	cValueJitter     = 0.03

	cLaunch      = 0.35
	cLaunchDays  = 2.0
	cGenDiscount = 0.82
	cDemandLow   = 0.92
	cDemandRun   = 0.16
	cJitter      = 0.04

	cRigBase   = 400.0
	cRigGrowth = 1.9

	cOCMax  = 3
	cOCMH   = 0.12
	cOCW    = 0.22
	cOCCost = 0.3

	cRGBSellBack = 0.62
	cRGBMinCls   = 2

	cBoostX    = 3.0
	cBoostDays = 5.0
	cBoostFull = 14.0

	nSeries = 4
	nModels = 16
	nEvents = 6
)

// NetParams is JS NET.
type NetParams struct {
	R0           float64 // block reward (BLK / block), 1 block = 1 min
	HalvingDays  int
	N0           float64 // network hash at day 0 (MH/s)
	Growth       float64 // growth per day
	Capitulation float64 // share of the network that leaves after a halving
	CapDays      float64 // days to recover from the capitulation
	SeasonDays   int
}

var Net = NetParams{R0: cR0, HalvingDays: cHalvingDays, N0: cN0, Growth: cGrowth, Capitulation: cCapitulation, CapDays: cCapDays, SeasonDays: cSeasonDays}

// ValueParams is JS VALUE (the BLK value index).
type ValueParams struct{ PerHalving, Run, Jitter float64 }

var ValueCfg = ValueParams{PerHalving: cValuePerHalving, Run: cValueRun, Jitter: cValueJitter}

// MarketParams is JS MARKET.
type MarketParams struct {
	Launch, LaunchDays, GenDiscount, DemandLow, DemandRun, Jitter float64
}

var Market = MarketParams{Launch: cLaunch, LaunchDays: cLaunchDays, GenDiscount: cGenDiscount, DemandLow: cDemandLow, DemandRun: cDemandRun, Jitter: cJitter}

// SeriesInfo is one entry of JS SERIES (one card generation).
type SeriesInfo struct {
	Name  string
	Color int
}

var Series = []SeriesInfo{
	{"Spark", 0x9fb4c8},
	{"Volt", 0x6fbf8e},
	{"Storm", 0xb48ce0},
	{"Quasar", 0xf2a23a},
}

// ClassInfo is one entry of JS CLASSES.
type ClassInfo struct {
	Name   string
	MH     float64
	Eff    float64
	PPM    float64
	Unlock float64
}

var Classes = []ClassInfo{
	{"Lite", 8, 0.1, 3.1, 0},
	{"Core", 20, 0.15, 5.3, 300},
	{"Pro", 50, 0.22, 9.0, 3000},
	{"Max", 120, 0.32, 15.3, 20000},
}

// Per generation multipliers (JS GEN).
const (
	genMH     = 1.55
	genEff    = 1.6
	genUnlock = 3
)

// Model is one card model (an entry of JS CARDS). T = Gen*4 + Cls + 1.
type Model struct {
	T, Gen, Cls int
	Name        string
	MH          float64
	W           float64
	Price       float64
	Release     int // day the model is released
	Unlock      float64
	Color       int
	VT          int // visual size 1..7
}

// Models is JS CARDS: 16 models, index t-1.
var Models = genModels()

func genModels() []Model {
	out := []Model{}
	for g := 0; g < len(Series); g++ {
		s := Series[g]
		for k := 0; k < len(Classes); k++ {
			c := Classes[k]
			mh := jsRound(c.MH * math.Pow(genMH, float64(g)))
			eff := c.Eff * math.Pow(genEff, float64(g))
			vt := 1 + k + g
			if vt > 7 {
				vt = 7
			}
			out = append(out, Model{
				T:       g*4 + k + 1,
				Gen:     g,
				Cls:     k,
				Name:    s.Name + " " + c.Name,
				MH:      mh,
				W:       jsRound(mh / eff),
				Price:   jsRound(c.PPM * mh),
				Release: g * Net.HalvingDays,
				Unlock:  c.Unlock * math.Pow(genUnlock, float64(g)),
				Color:   s.Color,
				VT:      vt,
			})
		}
	}
	return out
}

// ModelOf is JS card(t); ok is false for an unknown model.
func ModelOf(t int) (Model, bool) {
	if t < 1 || t > len(Models) {
		return Model{}, false
	}
	return Models[t-1], true
}

func validModel(t int) bool { return t >= 1 && t <= nModels }

// Room is one entry of JS ROOMS. Key is the stable name used by the scene.
type Room struct {
	Key   string
	Name  string
	Rigs  int
	Slots int
	Elec  float64
	Price float64
}

var Rooms = []Room{
	{"bedroom", "Bedroom", 1, 4, 60, 0},
	{"garage", "Garage", 3, 6, 48, 3000},
	{"container", "Container Farm", 4, 8, 42, 12000},
	{"warehouse", "Warehouse", 6, 8, 36, 80000},
	{"datacenter", "Data Center", 10, 8, 25, 900000},
	{"arctic", "Arctic Hall", 14, 8, 15, 2000000},
}

// RigPriceParams is JS RIG_PRICE.
type RigPriceParams struct{ Base, Growth float64 }

var RigPriceCfg = RigPriceParams{Base: cRigBase, Growth: cRigGrowth}

// OCParams is JS OC (overclock).
type OCParams struct {
	Max         int
	MH, W, Cost float64
}

var OCCfg = OCParams{Max: cOCMax, MH: cOCMH, W: cOCW, Cost: cOCCost}

// WatchTiers is JS WATCH: hours mined after the last collect, per tier.
var WatchTiers = []int{12, 24, 48}

// WatchTierPrice is JS WATCH_PRICE.
var WatchTierPrice = []float64{0, 150, 2500}

// SellBack is JS SELL_BACK.
const SellBack = 0.4

// RGBParams is JS RGB: the optional RGB edition of Pro and Max models.
type RGBParams struct {
	Premium, SellBack float64
	MinCls            int
}

var RGBCfg = RGBParams{Premium: 0.08, SellBack: cRGBSellBack, MinCls: cRGBMinCls}

// RGBOk is JS rgbOk(t).
func RGBOk(t int) bool {
	return validModel(t) && Models[t-1].Cls >= RGBCfg.MinCls
}

// StartWallet is JS START_WALLET.
const StartWallet = 30

// BoostParams is JS BOOST (newcomer boost).
type BoostParams struct{ X, Days, Full float64 }

var BoostCfg = BoostParams{X: cBoostX, Days: cBoostDays, Full: cBoostFull}

// Badge is one entry of JS BADGES. Start: the cards it gives for the next
// season.
type Badge struct {
	Name  string
	Min   float64
	Start []int
}

var Badges = []Badge{
	{"Copper", 100000, []int{1, 1}},
	{"Bronze", 250000, []int{2}},
	{"Silver", 650000, []int{2, 1}},
	{"Gold", 1300000, []int{3}},
	{"Platinum", 2100000, []int{3, 2}},
	{"Onyx", 2700000, []int{4}},
	{"Topaz", 3000000, []int{4, 1}},
	{"Pearl", 3300000, []int{4, 2}},
	{"Sapphire", 4200000, []int{4, 3}},
	{"Diamond", 5200000, []int{4, 4}},
}

// Event is one daily event (JS EVENTS entry). Multipliers that the event
// does not set are 1. Day is set by EventOf.
type Event struct {
	Key   string
	Name  string
	Desc  string
	Elec  float64
	Hash  float64
	Net   float64
	Price float64
	Good  bool
	Day   int
}

// Events in JS EVENT_KEYS order (the order matters for EventOf).
var Events = []Event{
	{Key: "energy", Name: "Energy crisis", Desc: "Power costs ×1.5 today", Elec: 1.5, Hash: 1, Net: 1, Price: 1, Good: false},
	{Key: "heat", Name: "Heat wave", Desc: "Cards throttle in the heat: earnings −10%", Elec: 1, Hash: 0.9, Net: 1, Price: 1, Good: false},
	{Key: "rush", Name: "Hash rush", Desc: "New miners pile in: difficulty +12%", Elec: 1, Hash: 1, Net: 1.12, Price: 1, Good: false},
	{Key: "sale", Name: "Flash sale", Desc: "Every card is 25% off in the market today", Elec: 1, Hash: 1, Net: 1, Price: 0.75, Good: true},
	{Key: "exodus", Name: "Miner exodus", Desc: "A big farm went offline: difficulty −20%", Elec: 1, Hash: 1, Net: 0.8, Price: 1, Good: true},
	{Key: "wind", Name: "Windy day", Desc: "Surplus wind power: electricity −50%", Elec: 0.5, Hash: 1, Net: 1, Price: 1, Good: true},
}

// noEvent is the neutral multiplier set used on days without an event.
var noEvent = Event{Elec: 1, Hash: 1, Net: 1, Price: 1}
