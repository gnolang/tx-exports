package engine

import (
	"strconv"
	"strings"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/cards/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
)

// Compact text encodings of the engine's values, for what a realm keeps
// per turn: a struct stored on chain costs every field its type and
// value, so a turn's events as structs weigh over ten kilobytes, as one
// string a tenth of that. Fields are joined with '|', records with ';',
// gun slots with ',' and gun fields with ':'; none of the values (codes,
// hex ids, numbers) contain those characters. Decoding is lenient: a
// malformed number reads as 0, so a damaged record never breaks a view.

// EncodeEvents packs events into one string; DecodeEvents unpacks it.
func EncodeEvents(evs []Event) string {
	var b strings.Builder
	for i, e := range evs {
		if i > 0 {
			b.WriteByte(';')
		}
		b.WriteString(strings.Join([]string{
			strconv.Itoa(e.Seg), strconv.Itoa(e.Player), e.Kind, string(e.Action), e.From, e.To,
			strconv.Itoa(int(e.Facing)), boolStr(e.Down), strconv.Itoa(e.N), strconv.Itoa(e.Delay),
			e.Reason, strconv.Itoa(e.Card), e.Result, strconv.Itoa(e.Endurance), strconv.Itoa(e.Target),
			e.Hit, strconv.Itoa(e.Range), string(e.Gun), strconv.Itoa(e.GunID), strconv.Itoa(e.Step),
			e.Chart, e.Status,
		}, "|"))
	}
	return b.String()
}

// DecodeEvents unpacks what EncodeEvents produced.
func DecodeEvents(s string) []Event {
	if s == "" {
		return nil
	}
	recs := strings.Split(s, ";")
	evs := make([]Event, 0, len(recs))
	for _, r := range recs {
		f := strings.Split(r, "|")
		if len(f) != 22 {
			continue
		}
		evs = append(evs, Event{
			Seg: atoi(f[0]), Player: atoi(f[1]), Kind: f[2], Action: cards.Code(f[3]), From: f[4], To: f[5],
			Facing: hex.Dir(atoi(f[6])), Down: f[7] == "1", N: atoi(f[8]), Delay: atoi(f[9]),
			Reason: f[10], Card: atoi(f[11]), Result: f[12], Endurance: atoi(f[13]), Target: atoi(f[14]),
			Hit: f[15], Range: atoi(f[16]), Gun: GunType(f[17]), GunID: atoi(f[18]), Step: atoi(f[19]),
			Chart: f[20], Status: f[21],
		})
	}
	return evs
}

// EncodeCharacter packs a character, guns included; DecodeCharacter unpacks it.
func EncodeCharacter(c Character) string {
	guns := make([]string, 0, MaxGuns)
	for _, g := range c.Guns {
		if g.Type != NoGun {
			guns = append(guns, encodeGun(g))
		}
	}
	var killers [MaxPlayers]int
	for q, k := range c.Killers {
		if k {
			killers[q] = 1
		}
	}
	return strings.Join([]string{
		c.Hex, strconv.Itoa(int(c.Facing)), boolStr(c.Down), strconv.Itoa(c.Delay), strconv.Itoa(int(c.Status)),
		boolStr(c.PlayedFoot), boolStr(c.PlayedRun), boolStr(c.RanLastTurn), boolStr(c.Dropped),
		strconv.Itoa(c.Aim), c.AimHex, strconv.Itoa(c.Endurance), strconv.Itoa(c.Exhausted),
		strconv.Itoa(c.Serious), strconv.Itoa(c.GunArm), strconv.Itoa(c.OtherArm), strconv.Itoa(c.Leg),
		strings.Join(guns, ","),
		strconv.Itoa(c.AimAt), perSeat(killers), perSeat(c.SeriousFrom), perSeat(c.LegFrom),
		perSeat(c.Hurt),
	}, "|")
}

// perSeat packs one number per seat, "/"-separated.
func perSeat(v [MaxPlayers]int) string {
	s := make([]string, len(v))
	for i, n := range v {
		s[i] = strconv.Itoa(n)
	}
	return strings.Join(s, "/")
}

// seatValues unpacks what perSeat packed.
func seatValues(f string) (out [MaxPlayers]int) {
	if f == "" {
		return out
	}
	for i, n := range strings.Split(f, "/") {
		if i < MaxPlayers {
			out[i] = atoi(n)
		}
	}
	return out
}

// DecodeCharacter unpacks what EncodeCharacter produced.
func DecodeCharacter(s string) Character {
	f := strings.Split(s, "|")
	if len(f) != 23 {
		return Character{}
	}
	c := Character{
		Hex: f[0], Facing: hex.Dir(atoi(f[1])), Down: f[2] == "1", Delay: atoi(f[3]), Status: Status(atoi(f[4])),
		PlayedFoot: f[5] == "1", PlayedRun: f[6] == "1", RanLastTurn: f[7] == "1", Dropped: f[8] == "1",
		Aim: atoi(f[9]), AimHex: f[10], Endurance: atoi(f[11]), Exhausted: atoi(f[12]),
		Serious: atoi(f[13]), GunArm: atoi(f[14]), OtherArm: atoi(f[15]), Leg: atoi(f[16]),
		AimAt: atoi(f[18]),
	}
	for q, k := range seatValues(f[19]) {
		c.Killers[q] = k != 0
	}
	c.SeriousFrom = seatValues(f[20])
	c.LegFrom = seatValues(f[21])
	c.Hurt = seatValues(f[22])
	if f[17] != "" {
		for i, rec := range strings.Split(f[17], ",") {
			g, ok := decodeGun(rec)
			if i >= MaxGuns || !ok {
				break
			}
			c.Guns[i] = g
		}
	}
	return c
}

// EncodeChars packs the characters of a state (a turn's starting
// snapshot), seats in order; DecodeChars unpacks them.
func EncodeChars(cs []Character) string {
	parts := make([]string, len(cs))
	for i, c := range cs {
		parts[i] = EncodeCharacter(c)
	}
	return strings.Join(parts, ";")
}

// DecodeChars unpacks what EncodeChars produced.
func DecodeChars(s string) []Character {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ";")
	cs := make([]Character, len(parts))
	for i, part := range parts {
		cs[i] = DecodeCharacter(part)
	}
	return cs
}

// encodeGun packs a gun's fields, ':'-separated; decodeGun unpacks them.
func encodeGun(g Gun) string {
	return strings.Join([]string{
		strconv.Itoa(g.ID), string(g.Type), strconv.Itoa(int(g.Location)), boolStr(g.Cocked),
		strconv.Itoa(g.Shells), boolStr(g.Jammed), boolStr(g.Exploded),
	}, ":")
}

func decodeGun(s string) (Gun, bool) {
	g := strings.Split(s, ":")
	if len(g) != 7 {
		return Gun{}, false
	}
	return Gun{
		ID: atoi(g[0]), Type: GunType(g[1]), Location: GunLocation(atoi(g[2])), Cocked: g[3] == "1",
		Shells: atoi(g[4]), Jammed: g[5] == "1", Exploded: g[6] == "1",
	}, true
}

// EncodeGround packs the weapons lying on the board (a turn's ground at its
// start), ';'-separated records of id, hex and gun ("1|A-G6|1:colt45:0:0:6:0:0");
// DecodeGround unpacks them, skipping a malformed record.
func EncodeGround(ground []GroundGun) string {
	recs := make([]string, len(ground))
	for i, gg := range ground {
		recs[i] = strconv.Itoa(gg.ID) + "|" + gg.Hex + "|" + encodeGun(gg.Gun)
	}
	return strings.Join(recs, ";")
}

// DecodeGround unpacks what EncodeGround produced.
func DecodeGround(s string) []GroundGun {
	if s == "" {
		return nil
	}
	var out []GroundGun
	for _, rec := range strings.Split(s, ";") {
		f := strings.SplitN(rec, "|", 3)
		if len(f) != 3 {
			continue
		}
		if g, ok := decodeGun(f[2]); ok {
			out = append(out, GroundGun{ID: atoi(f[0]), Hex: f[1], Gun: g})
		}
	}
	return out
}

// EncodeInts packs numbers (the cards drawn in a turn); DecodeInts unpacks them.
func EncodeInts(ns []int) string {
	parts := make([]string, len(ns))
	for i, n := range ns {
		parts[i] = strconv.Itoa(n)
	}
	return strings.Join(parts, ",")
}

// DecodeInts unpacks what EncodeInts produced.
func DecodeInts(s string) []int {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	ns := make([]int, len(parts))
	for i, p := range parts {
		ns[i] = atoi(p)
	}
	return ns
}

func boolStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
