package penalty

import (
	"errors"
	"strconv"
)

const (
	BallRadius = 110   // mm
	PostRadius = 60    // mm
	Distance   = 11000 // penalty spot to goal line, mm
	Gravity    = 9810  // mm/s²

	AimMaxX = 6000 // the aim point must lie within ±6 m of the goal centre
	AimMaxY = 4000 // and between the grass and 4 m up
)

// ShotInput is what a taker chooses: the five numbers a player sends.
type ShotInput struct {
	AimX     int64 // point on the goal plane the swing heads for, mm from the centre (+ = taker's right)
	AimY     int64 // its height, mm
	ContactX int64 // where the boot meets the ball, milli-radii from its centre (+ = right)
	ContactY int64 // milli-radii (+ = above centre)
	Power    int64 // per-mille
}

// ShotParams is a complete kick: the taker's five choices plus the 24-byte
// mishit seed that decides how far the boot lands from the chosen contact.
// These six, with a keeper's four, are the ten inputs of SimulateShot.
type ShotParams struct {
	AimX     int64
	AimY     int64
	ContactX int64
	ContactY int64
	Power    int64
	Mishit   [24]byte
}

// KeeperPlan is the keeper's commitment: four uint16 values that DecodePlan
// maps onto a dive using the game's Config.
type KeeperPlan struct {
	Direction uint16
	Speed     uint16
	Jump      uint16
	Reaction  uint16
}

var ErrShotRange = errors.New("penalty: shot parameter out of range")

// Validate checks a taker's choices against the game's constants.
func (s ShotInput) Validate(c Config) error {
	if s.AimX < -AimMaxX || s.AimX > AimMaxX {
		return errors.New(ErrShotRange.Error() + ": aimX must be within ±" + strconv.Itoa(AimMaxX) + " mm")
	}
	if s.AimY < 0 || s.AimY > AimMaxY {
		return errors.New(ErrShotRange.Error() + ": aimY must be within 0.." + strconv.Itoa(AimMaxY) + " mm")
	}
	if s.ContactX*s.ContactX+s.ContactY*s.ContactY > c.MaxContact*c.MaxContact {
		return errors.New(ErrShotRange.Error() + ": contact offset must be within " +
			strconv.FormatInt(c.MaxContact, 10) + " milli-radii of the centre")
	}
	if s.Power < 0 || s.Power > 1000 {
		return errors.New(ErrShotRange.Error() + ": power must be within 0..1000")
	}
	return nil
}

// WithMishit completes a taker's choices with a mishit seed.
func (s ShotInput) WithMishit(m [24]byte) ShotParams {
	return ShotParams{AimX: s.AimX, AimY: s.AimY, ContactX: s.ContactX, ContactY: s.ContactY, Power: s.Power, Mishit: m}
}

// Input returns the taker's five choices.
func (s ShotParams) Input() ShotInput {
	return ShotInput{AimX: s.AimX, AimY: s.AimY, ContactX: s.ContactX, ContactY: s.ContactY, Power: s.Power}
}

func (s ShotInput) String() string {
	return "aim=(" + strconv.FormatInt(s.AimX, 10) + "," + strconv.FormatInt(s.AimY, 10) + ")mm contact=(" +
		strconv.FormatInt(s.ContactX, 10) + "," + strconv.FormatInt(s.ContactY, 10) + ")mR power=" +
		strconv.FormatInt(s.Power, 10) + "‰"
}

func (p KeeperPlan) String() string {
	return "plan=(" + strconv.Itoa(int(p.Direction)) + "," + strconv.Itoa(int(p.Speed)) + "," +
		strconv.Itoa(int(p.Jump)) + "," + strconv.Itoa(int(p.Reaction)) + ")"
}
