package book

import (
	"strings"

	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"
)

func TerrainShort(code uint8) string {
	switch TerrainName(code) {
	case "ocean":
		return "sea"
	case "coastal":
		return "cst"
	case "moor":
		return "moo"
	case "forest":
		return "for"
	case "hills":
		return "hil"
	case "farm":
		return "frm"
	case "village":
		return "vil"
	case "monastery":
		return "mon"
	case "harbor":
		return "hbr"
	case "city":
		return "cty"
	case "mountain":
		return "mtn"
	case "fishing_village":
		return "fsh"
	case "mountain_village":
		return "mvl"
	case "city_north":
		return "nct"
	case "city_south":
		return "sct"
	case "meadow":
		return "mdw"
	default:
		return "?"
	}
}

func NormalizeKind(kind string) string {
	return strings.ToLower(strings.TrimSpace(kind))
}

func MustCreature(kind string) types.Creature {
	c, ok := Creature(NormalizeKind(kind))
	if !ok {
		panic("unknown creature: " + kind)
	}
	return c
}

func UnlimitedMints(kind string) bool {
	c, ok := Creature(NormalizeKind(kind))
	if !ok {
		return false
	}
	return c.MaxMints == 0
}
