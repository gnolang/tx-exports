// Package penalty holds everything about a penalty kick that is pure
// computation: the constants a game is played with, the ten parameters of a
// kick, how 32 bytes of entropy map onto them, the shootout rules, and
// SimulateShot.
//
// It has no state and no realm dependencies, so every version of the game
// realm agrees on these types, and a client can run the same code to check a
// result. All quantities are integers: millimetres, mm/s, milliseconds,
// per-mille (0..1000) and milli-radii (thousandths of the ball's radius), so
// the outcome is identical on every node.
package penalty

import (
	"errors"
	"strconv"
	"strings"
)

// Config is the set of keeper and ball constants a game is created with.
type Config struct {
	GoalWidth  int64 // inside width, mm
	GoalHeight int64 // inside height, mm

	KeeperScale int64 // keeper size relative to a ~1.85 m keeper, per-mille
	ReactionMin int64 // keeper reaction delay range, ms
	ReactionMax int64
	StarShare   int64 // share of the keeper's speed range that means "star jump", per-mille
	ReadShare   int64 // share that means "wait and read the shot", per-mille
	DiveMin     int64 // committed dive speed range, mm/s
	DiveMax     int64
	JumpMin     int64 // keeper vertical launch speed range, mm/s (negative = collapse low)
	JumpMax     int64

	BallMinSpeed int64 // ball speed at 0% power, mm/s
	BallMaxSpeed int64 // ball speed at 100% power, mm/s
	FuzzBase     int64 // std-dev of the mishit at 0% power, milli-radii
	FuzzPower    int64 // extra std-dev at 100% power, milli-radii
	MaxContact   int64 // farthest contact offset a taker may choose, milli-radii
}

// DefaultConfig returns the constants the reference simulation is tuned for.
func DefaultConfig() Config {
	return Config{
		GoalWidth:    6555,
		GoalHeight:   2424,
		KeeperScale:  1176,
		ReactionMin:  20,
		ReactionMax:  120,
		StarShare:    60,
		ReadShare:    240, // as the browser engine (PLAN.READ_SHARE)
		DiveMin:      2600,
		DiveMax:      5200,
		JumpMin:      -1400,
		JumpMax:      4000,
		BallMinSpeed: 10000,
		BallMaxSpeed: 34000,
		FuzzBase:     30,
		FuzzPower:    100,
		MaxContact:   500,
	}
}

type bound struct {
	name   string
	lo, hi int64
}

// The range each constant may be set to, so a game cannot be created with
// physics the simulation was never meant to handle. Order matches field().
var bounds = []bound{
	{"goalWidth", 5000, 7320},
	{"goalHeight", 1800, 2440},
	{"keeperScale", 900, 1300},
	{"reactionMin", 0, 300},
	{"reactionMax", 0, 400},
	{"starShare", 0, 300},
	{"readShare", 0, 700},
	{"diveMin", 1500, 7000},
	{"diveMax", 1500, 7000},
	{"jumpMin", -2500, 0},
	{"jumpMax", 0, 5000},
	{"ballMinSpeed", 5000, 40000},
	{"ballMaxSpeed", 5000, 40000},
	{"fuzzBase", 0, 150},
	{"fuzzPower", 0, 300},
	{"maxContact", 200, 800},
}

func (c *Config) field(i int) *int64 {
	switch i {
	case 0:
		return &c.GoalWidth
	case 1:
		return &c.GoalHeight
	case 2:
		return &c.KeeperScale
	case 3:
		return &c.ReactionMin
	case 4:
		return &c.ReactionMax
	case 5:
		return &c.StarShare
	case 6:
		return &c.ReadShare
	case 7:
		return &c.DiveMin
	case 8:
		return &c.DiveMax
	case 9:
		return &c.JumpMin
	case 10:
		return &c.JumpMax
	case 11:
		return &c.BallMinSpeed
	case 12:
		return &c.BallMaxSpeed
	case 13:
		return &c.FuzzBase
	case 14:
		return &c.FuzzPower
	case 15:
		return &c.MaxContact
	}
	panic("penalty: no config field " + strconv.Itoa(i))
}

var (
	ErrConfigRange   = errors.New("penalty: config value out of range")
	ErrConfigOrder   = errors.New("penalty: config range is inverted")
	ErrConfigShares  = errors.New("penalty: starShare + readShare must not exceed 900")
	ErrConfigUnknown = errors.New("penalty: unknown config key")
	ErrConfigSyntax  = errors.New("penalty: config must be key=value pairs separated by commas")
)

// Validate checks every constant against its allowed range.
func (c Config) Validate() error {
	for i, b := range bounds {
		v := *c.field(i)
		if v < b.lo || v > b.hi {
			return errors.New(ErrConfigRange.Error() + ": " + b.name + "=" + strconv.FormatInt(v, 10) +
				" (allowed " + strconv.FormatInt(b.lo, 10) + ".." + strconv.FormatInt(b.hi, 10) + ")")
		}
	}
	if c.ReactionMin > c.ReactionMax || c.DiveMin > c.DiveMax ||
		c.JumpMin > c.JumpMax || c.BallMinSpeed > c.BallMaxSpeed {
		return ErrConfigOrder
	}
	if c.StarShare+c.ReadShare > 900 {
		return ErrConfigShares
	}
	return nil
}

// ParseConfig applies "key=value,key=value" overrides to DefaultConfig and
// validates the result. An empty string gives the defaults. Keys are the
// lower-camel names String prints, e.g. "goalWidth=6400,reactionMax=150".
func ParseConfig(s string) (Config, error) {
	c := DefaultConfig()
	s = strings.TrimSpace(s)
	if s != "" {
		for _, kv := range strings.Split(s, ",") {
			parts := strings.Split(strings.TrimSpace(kv), "=")
			if len(parts) != 2 {
				return Config{}, ErrConfigSyntax
			}
			key := strings.TrimSpace(parts[0])
			v, err := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
			if err != nil {
				return Config{}, ErrConfigSyntax
			}
			found := false
			for i, b := range bounds {
				if b.name == key {
					*c.field(i) = v
					found = true
					break
				}
			}
			if !found {
				return Config{}, errors.New(ErrConfigUnknown.Error() + ": " + key)
			}
		}
	}
	if err := c.Validate(); err != nil {
		return Config{}, err
	}
	return c, nil
}

// String prints the config in the form ParseConfig accepts.
func (c Config) String() string {
	var b strings.Builder
	for i, bd := range bounds {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(bd.name + "=" + strconv.FormatInt(*c.field(i), 10))
	}
	return b.String()
}
