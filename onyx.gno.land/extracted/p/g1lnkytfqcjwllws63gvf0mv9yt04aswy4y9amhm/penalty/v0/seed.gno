package penalty

// Seed is the 32 bytes of entropy that complete a kick.
//
// When the player shoots, the seed supplies the computer's keeper and the
// player's mishit:
//
//	bytes 0-7    keeper plan: four big-endian uint16 (direction, speed, jump, reaction)
//	bytes 8-31   mishit seed (24 bytes)
//
// When the player keeps, the seed supplies the computer's whole kick:
//
//	bytes 0-1    aim x       uint16 -> ±(GoalWidth/2 - ChainAimInset) mm
//	bytes 2-3    aim y       uint16 -> ChainAimMinY .. GoalHeight + ChainAimOverY mm
//	bytes 4-5    power       uint16 -> ChainPowerMin .. 1000 per-mille
//	byte  6      contact x   int8   -> ±ChainContact milli-radii
//	byte  7      contact y   int8   -> ±ChainContact milli-radii
//	bytes 8-31   mishit seed (24 bytes)
//
// So the layout is the same either way: the first eight bytes are "the
// computer's move", the last twenty-four are the mishit.
type Seed [32]byte

// How the computer takes its kicks: inside the frame, aimed a little high to
// allow for the drop, struck with at least ChainPowerMin.
const (
	ChainAimInset = 250 // mm inside each post
	ChainAimMinY  = 300 // mm
	ChainAimOverY = 200 // mm above the bar at most
	ChainPowerMin = 450 // per-mille
	ChainContact  = 350 // milli-radii
)

func u16(b []byte) uint16 { return uint16(b[0])<<8 | uint16(b[1]) }

// span maps a uint16 linearly onto lo..hi.
func span(u uint16, lo, hi int64) int64 { return lo + (hi-lo)*int64(u)/65535 }

// KeeperPlan reads the computer's keeper plan from bytes 0-7.
func (s Seed) KeeperPlan() KeeperPlan {
	return KeeperPlan{
		Direction: u16(s[0:2]),
		Speed:     u16(s[2:4]),
		Jump:      u16(s[4:6]),
		Reaction:  u16(s[6:8]),
	}
}

// Mishit returns bytes 8-31.
func (s Seed) Mishit() [24]byte {
	var m [24]byte
	copy(m[:], s[8:32])
	return m
}

// ChainShot reads the computer's kick from bytes 0-7 (see Seed).
func (s Seed) ChainShot(c Config) ShotInput {
	halfW := c.GoalWidth/2 - ChainAimInset
	in := ShotInput{
		AimX:     span(u16(s[0:2]), -halfW, halfW),
		AimY:     span(u16(s[2:4]), ChainAimMinY, c.GoalHeight+ChainAimOverY),
		Power:    span(u16(s[4:6]), ChainPowerMin, 1000),
		ContactX: (int64(s[6]) - 128) * ChainContact / 128,
		ContactY: (int64(s[7]) - 128) * ChainContact / 128,
	}
	// Keep the contact inside this game's selectable disc.
	r2 := in.ContactX*in.ContactX + in.ContactY*in.ContactY
	if m := c.MaxContact; r2 > m*m {
		r := isqrt(r2)
		in.ContactX = in.ContactX * m / r
		in.ContactY = in.ContactY * m / r
	}
	return in
}

const hexDigits = "0123456789abcdef"

// Hex prints the seed as 64 hex characters.
func (s Seed) Hex() string { return toHex(s[:]) }

func toHex(b []byte) string {
	out := make([]byte, len(b)*2)
	for i, v := range b {
		out[2*i] = hexDigits[v>>4]
		out[2*i+1] = hexDigits[v&15]
	}
	return string(out)
}

// MishitHex prints a mishit seed as 48 hex characters.
func MishitHex(m [24]byte) string { return toHex(m[:]) }

// ParseMishitHex reads 48 hex characters.
func ParseMishitHex(s string) ([24]byte, bool) {
	var m [24]byte
	if len(s) != 48 {
		return m, false
	}
	for i := 0; i < 24; i++ {
		hi, ok1 := hexVal(s[2*i])
		lo, ok2 := hexVal(s[2*i+1])
		if !ok1 || !ok2 {
			return m, false
		}
		m[i] = hi<<4 | lo
	}
	return m, true
}

func hexVal(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// isqrt is the integer square root (floor).
func isqrt(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}
