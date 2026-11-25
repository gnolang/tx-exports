package miner

import "math"

// floor is math.Floor, cheaper in gas: math.Floor is interpreted Gno code
// (Modf on the bit pattern), a float->int conversion is one VM op. Exact
// for |x| < 2^52 (every value here); other inputs go to math.Floor.
func floor(x float64) float64 {
	if x > -4503599627370496 && x < 4503599627370496 {
		if x == 0 {
			return x // keep -0
		}
		f := float64(int64(x))
		if f > x {
			f--
		}
		return f
	}
	return math.Floor(x)
}

// modPos is math.Mod(x, m) for 0 <= x < 2^50 and m > 0, exact like fmod:
// q is corrected so that 0 <= x - q*m < m, and that subtraction is exact
// (Sterbenz). Other inputs go to math.Mod.
func modPos(x, m float64) float64 {
	if !(x >= 0 && x < 1125899906842624) {
		return math.Mod(x, m)
	}
	q := floor(x / m)
	r := x - q*m
	if r < 0 {
		r = x - (q-1)*m
	} else if r >= m {
		r = x - (q+1)*m
	}
	return r
}

// jsRound is JS Math.round: the nearest integer, ties toward +Inf.
// x - floor(x) is exact for |x| < 2^52, so this also gets
// 0.49999999999999994 right (unlike floor(x+0.5)).
func jsRound(x float64) float64 {
	f := floor(x)
	if x-f >= 0.5 {
		return f + 1
	}
	return f
}

// JSRound exposes jsRound for callers that must round like the client.
func JSRound(x float64) float64 { return jsRound(x) }

func fmax(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func fmin(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

// Gas: math.Pow and math.Exp are interpreted Gno code and cost a lot of
// gas. Their results for the small integer inputs the game uses are taken
// once at init from the same functions, so the values stay bit-identical.
const tableSize = 64

func powTable(base float64) []float64 {
	t := make([]float64, tableSize)
	for k := 0; k < tableSize; k++ {
		t[k] = math.Pow(base, float64(k))
	}
	return t
}

var (
	pow2Table      = powTable(2)
	powValueTable  = powTable(cValuePerHalving)
	powGenDisTable = powTable(cGenDiscount)
	powRigTable    = powTable(cRigGrowth)
	launchTable    = genLaunchTable()
)

// fexp is math.Exp, bit for bit, at about a third of the gas: the same
// argument reduction and polynomial (Go's exp, from FreeBSD's e_exp.c), but
// the final Ldexp(y, k) — interpreted bit fiddling — is a multiplication
// by 2^k, which is exact while the result is a normal number. Outside
// -708 < x < 709 (subnormal or overflowing results) and near zero it calls
// math.Exp itself. TestFexp checks the bits against math.Exp.
func fexp(x float64) float64 {
	const (
		ln2Hi    = 6.93147180369123816490e-01
		ln2Lo    = 1.90821492927058770002e-10
		log2e    = 1.44269504088896338700e+00
		nearZero = 1.0 / (1 << 28)
		p1       = 1.66666666666666657415e-01
		p2       = -2.77777777770155933842e-03
		p3       = 6.61375632143793436117e-05
		p4       = -1.65339022054652515390e-06
		p5       = 4.13813679705723846039e-08
	)
	if !(x > -708 && x < 709) || (x > -nearZero && x < nearZero) {
		return math.Exp(x)
	}
	var k int
	if x < 0 {
		k = int(log2e*x - 0.5)
	} else {
		k = int(log2e*x + 0.5)
	}
	hi := x - float64(k)*ln2Hi
	lo := float64(k) * ln2Lo
	r := hi - lo
	t := r * r
	c := r - t*(p1+t*(p2+t*(p3+t*(p4+t*p5))))
	y := 1 - ((lo - (r*c)/(2-c)) - hi)
	return y * math.Float64frombits(uint64(k+1023)<<52)
}

// powInt is math.Pow(base, k) for the bases above, read from table.
func powInt(table []float64, base float64, k int) float64 {
	if k >= 0 && k < len(table) {
		return table[k]
	}
	return math.Pow(base, float64(k))
}

// launchTable[age] = math.Exp(-age / LaunchDays) for integer ages.
func genLaunchTable() []float64 {
	t := make([]float64, tableSize)
	for a := 0; a < tableSize; a++ {
		t[a] = math.Exp(-float64(a) / cLaunchDays)
	}
	return t
}

func launchExp(age float64) float64 {
	if a := int(age); float64(a) == age && a >= 0 && a < len(launchTable) {
		return launchTable[a]
	}
	return fexp(-age / cLaunchDays)
}

// Noise is JS noise(day, salt): a pseudo random number in [-1, 1) that only
// depends on floor(day) and salt, the same for everyone. Bit-exact with the
// JS 32-bit integer math (Math.imul, >>> 0).
func Noise(day float64, salt int) float64 {
	d := int64(floor(day))
	// (floor(day)*374761393 + salt*668265263) >>> 0: exact in a double for
	// the inputs the game uses, then reduced modulo 2^32.
	v := (d*374761393 + int64(salt)*668265263) % 4294967296
	if v < 0 {
		v += 4294967296
	}
	s := uint64(v)
	// Math.imul(s ^ (s >>> 13), 1274126177) >>> 0
	s = ((s ^ (s >> 13)) * 1274126177) & 0xffffffff
	// (s ^ (s >>> 16)) >>> 0
	s = s ^ (s >> 16)
	return float64(s)/4294967296*2 - 1
}

// Epoch is the number of halvings before day (JS epoch).
func Epoch(day float64) int {
	return int(floor(fmax(0, day) / cHalvingDays))
}

// Phase is the position inside the halving cycle, 0..1 (JS phase).
func Phase(day float64) float64 {
	hd := float64(cHalvingDays)
	return modPos(fmax(0, day), hd) / hd
}

// Reward is the block reward on day (JS reward).
func Reward(day float64) float64 {
	return cR0 / powInt(pow2Table, 2, Epoch(day))
}

// NextHalving is the day of the next halving (JS nextHalving).
func NextHalving(day float64) float64 {
	return float64((Epoch(day) + 1) * cHalvingDays)
}

// CurrentGen is the newest released generation on day (JS currentGen).
func CurrentGen(day float64) int {
	e := Epoch(day)
	if e > nSeries-1 {
		return nSeries - 1
	}
	return e
}

// EventOf is JS eventOf(day, season): the event of that season day, if any.
// Each season has its own calendar.
func EventOf(day float64, season int) (Event, bool) {
	fd := floor(day)
	if fd < 2 || fd >= cSeasonDays {
		return Event{}, false
	}
	d := int(fd)
	if d%cHalvingDays == 0 {
		return Event{}, false
	}
	salt := 90 + (season%997)*13
	if Noise(fd, salt) < 0.3 {
		return Event{}, false
	}
	n := nEvents
	idx := int(floor((Noise(fd, salt+1)+1)/2*float64(n))) % n
	ev := Events[idx]
	ev.Day = d
	return ev, true
}

// eventMul returns the event of the day, or the neutral multipliers.
func eventMul(day float64, season int) Event {
	ev, ok := EventOf(day, season)
	if !ok {
		return noEvent
	}
	return ev
}

// NetHash is the network hash power on day (JS netHash).
func NetHash(day float64, season int) float64 {
	return netHashEv(day, eventMul(fmax(0, day), season))
}

func netHashEv(day float64, ev Event) float64 {
	return netHashAt(day, Epoch(day), ev)
}

// netHashAt: ep = Epoch(day) (Epoch already clamps at 0).
func netHashAt(day float64, e int, ev Event) float64 {
	d := fmax(0, day)
	n := cN0 * fexp(cGrowth*d)
	since := d - float64(e*cHalvingDays)
	if e > 0 && since < cCapDays {
		n *= 1 - cCapitulation*(1-since/cCapDays)
	}
	return n * ev.Net
}

// ValueIndex is the BLK value index on day (JS valueIndex).
func ValueIndex(day float64) float64 {
	d := floor(fmax(0, day))
	return powInt(powValueTable, cValuePerHalving, Epoch(d)) * (1 + cValueRun*Phase(d)) * (1 + cValueJitter*Noise(d, 1))
}

// Demand is the card demand multiplier on day (JS demand).
func Demand(day float64) float64 {
	return cDemandLow + cDemandRun*Phase(floor(fmax(0, day)))
}

// Released reports whether model t is on the market on day (JS released).
func Released(t int, day float64) bool {
	return validModel(t) && day >= float64(Models[t-1].Release)
}

// RealPrice is the real (pre value index) price of model t on day
// (JS realPrice). It panics on an unknown model, like JS does.
func RealPrice(t int, day float64, season int) float64 {
	return realPriceEv(t, day, eventMul(floor(fmax(0, day)), season).Price)
}

// realPriceEv is RealPrice with the day's event price multiplier given.
func realPriceEv(t int, day, evPrice float64) float64 {
	c := &Models[t-1]
	d := floor(fmax(0, day))
	age := d - float64(c.Release)
	launch := 1 + cLaunch*launchExp(fmax(0, age))
	behind := CurrentGen(d) - c.Gen
	if behind < 0 {
		behind = 0
	}
	return c.Price * launch * powInt(powGenDisTable, cGenDiscount, behind) * Demand(d) *
		(1 + cJitter*Noise(d, 10+t)) * evPrice
}
