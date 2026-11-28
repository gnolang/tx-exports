package torchbeat

import (
	"strconv"
	"strings"

	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
)

// Verify runs Reveal's checks and replay for a run without a commit and
// without writing anything. With owner set it also checks that owner holds the
// relic and has unlocked the room; with owner "" only the relic's range is
// checked. An owner that is not a valid lowercase address fails first with
// "owner". It never panics and returns
// {"ok":true,"beats":N,"damage":D,"stars":S,"route":"hex"}, S being the star
// bits this run earns, or {"ok":false,"reason":"<code>","beat":N} with Reveal's
// reason code (or "owner") and, for a failed run, the beat it failed on (else
// 0).
func Verify(roomID, log string, relic int, owner string) string {
	var res sim.Result
	var r *Room
	why := ""
	if owner != "" && (owner != strings.ToLower(owner) || !address(owner).IsValid()) {
		why = "owner"
	}
	if why == "" {
		r, why = playable(roomID, log)
	}
	if why == "" {
		res, why = replay(r, owner, log, relic)
	}
	if why != "" {
		b := []byte(`{"ok":false`)
		b = appendField(b, "reason", false)
		b = appendQuoted(b, why)
		b = appendField(b, "beat", false)
		b = appendInt(b, int(res.FailBeat))
		return string(append(b, '}'))
	}
	b := []byte(`{"ok":true`)
	b = appendField(b, "beats", false)
	b = appendInt(b, int(res.Beats))
	b = appendField(b, "damage", false)
	b = appendInt(b, int(res.Damage))
	b = appendField(b, "stars", false)
	b = appendInt(b, int(starsFor(r, res)))
	b = appendField(b, "route", false)
	b = appendQuoted(b, routeHex(res.RouteHash))
	return string(append(b, '}'))
}

// PlayerData returns a player's totals and per-room records as JSON:
// {"renown":..,"relics":..,"stars":..,"cleared":N,"rooms":[{"id":..,"best":..,"damage":..,"stars":..}]}
// with rooms sorted by ID. An unknown or invalid address reads as all zeros.
func PlayerData(addr string) string {
	var p Player
	valid := address(addr).IsValid()
	if valid {
		if v := playerOf(addr, false); v != nil {
			p = *v
		}
	}
	b := []byte{'{'}
	b = appendField(b, "renown", true)
	b = appendInt(b, p.Renown)
	b = appendField(b, "relics", false)
	b = appendInt(b, p.Relics)
	b = appendField(b, "stars", false)
	b = appendInt(b, p.Stars)
	b = appendField(b, "cleared", false)
	b = appendInt(b, p.Cleared)
	b = appendField(b, "rooms", false)
	b = append(b, '[')
	if valid && p.Cleared > 0 {
		prefix := progressKey(addr, "")
		// '}' is the byte after '|', so the range holds exactly this prefix.
		progress.Iterate(prefix, addr+"}", func(k string, v any) bool {
			pr := v.(*Progress)
			if b[len(b)-1] != '[' {
				b = append(b, ',')
			}
			b = append(b, '{')
			b = appendField(b, "id", true)
			b = appendQuoted(b, strings.TrimPrefix(k, prefix))
			b = appendField(b, "best", false)
			b = appendInt(b, int(pr.Best))
			b = appendField(b, "damage", false)
			b = appendInt(b, int(pr.Damage))
			b = appendField(b, "stars", false)
			b = appendInt(b, int(pr.Stars))
			b = append(b, '}')
			return false
		})
	}
	return string(append(b, ']', '}'))
}

// Board returns roomID's top runs, best first, as a JSON array:
// [{"owner":..,"beats":..,"damage":..,"route":"hex","log":..,"height":..,"relic":..}].
// An unknown room or an empty board is [].
func Board(roomID string) string {
	b := []byte{'['}
	if v := boards.Get(roomID); v != nil {
		for i, e := range v.([]Run) {
			if i > 0 {
				b = append(b, ',')
			}
			b = append(b, '{')
			b = appendField(b, "owner", true)
			b = appendQuoted(b, e.Owner.String())
			b = appendField(b, "beats", false)
			b = appendInt(b, int(e.Beats))
			b = appendField(b, "damage", false)
			b = appendInt(b, int(e.Damage))
			b = appendField(b, "route", false)
			b = appendQuoted(b, routeHex(e.Route))
			b = appendField(b, "log", false)
			b = appendQuoted(b, e.Log)
			b = appendField(b, "height", false)
			b = append(b, strconv.FormatInt(e.Height, 10)...)
			b = appendField(b, "relic", false)
			b = appendInt(b, int(e.Relic))
			b = append(b, '}')
		}
	}
	return string(append(b, ']'))
}

// HasCleared reports whether addr has cleared roomID.
func HasCleared(addr address, roomID string) bool {
	return progress.Has(progressKey(addr.String(), roomID))
}

// RoomsCleared returns how many rooms addr has cleared.
func RoomsCleared(addr address) int {
	if p := playerOf(addr.String(), false); p != nil {
		return p.Cleared
	}
	return 0
}

// Renown returns the number of unique clearers, addr itself excluded, over the
// rooms addr authored.
func Renown(addr address) int {
	if p := playerOf(addr.String(), false); p != nil {
		return p.Renown
	}
	return 0
}

// RoomCounts returns roomID's clears and unique clearers, or (0, 0) for an
// unknown room.
func RoomCounts(roomID string) (clears, uniques int) {
	if v := rooms.Get(roomID); v != nil {
		r := v.(*Room)
		return r.Clears, r.Uniques
	}
	return 0, 0
}
