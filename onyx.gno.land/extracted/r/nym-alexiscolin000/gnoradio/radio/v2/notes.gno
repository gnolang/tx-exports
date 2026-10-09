package radio

import (
	"chain"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

// Dedications: reports, strikes and mutes. A dedication's reports are
// radio/notes P(station)/T(start) -> the reporters' addresses, each followed
// by ","; once hidden, struckMark, the strike time it gave its author and
// the one before ("" none), so that RestoreNote takes back this strike only.

const struckMark = "struck:"

func noteKey(stationID int, start int64) string {
	return store.Pad(stationID) + "/" + store.TimeKey(start)
}

// ReportNote flags the dedication of the slot starting at start. Only a
// listener with the reputation sponsored picks need (a first pick a week
// old, 3 normal picks this 15-day period and the one before: sponsorBlock) may report, so
// throwaway wallets cannot; the third such listener hides it at once, with
// no moderator involved. A first hidden dedication is a strike; a second
// within muteFor pauses its author's dedications for muteFor (the admin can
// lift it: Unmute).
func ReportNote(cur realm, stationID int, start int64) {
	caller := userCaller(cur)
	noPayment()
	t := rd()
	st, s := noteSlot(t, stationID, start)
	if s.NoteHidden {
		panic("radio: no dedication at this time on this station")
	}
	if s.By == caller {
		panic("radio: you cannot report your own dedication")
	}
	if sponsorBlock(t, caller) != "" {
		panic("radio: reporting needs a first pick 7 days old and 3 normal picks in the last two 15-day periods")
	}
	key := noteKey(st.id, start)
	by := t.val(cNotes, key)
	if strings.Contains(by, caller.String()) {
		panic("radio: you already reported this dedication")
	}
	by += caller.String() + ","
	if strings.Count(by, ",") < hideAfter {
		t.set(cNotes, key, by)
		save(cur, t)
		chain.Emit("NoteReported", "station", text.Itoa(st.id), "start", text.Itoa64(start), "by", caller.String())
		return
	}
	s.NoteHidden, s.body, st.dirty = true, "", true
	ts, author := now(), s.By.String()
	last, struck := t.get(cStrikes, author)
	mute := struck && ts-text.MustAtoi64(last) < muteFor
	if mute {
		t.set(cMuted, author, text.Itoa64(ts+muteFor))
	}
	t.set(cStrikes, author, text.Itoa64(ts))
	t.set(cNotes, key, struckMark+text.Itoa64(ts)+":"+last)
	save(cur, t)
	chain.Emit("NoteHidden", "station", text.Itoa(st.id), "start", text.Itoa64(start), "author", author, "muted", strconv.FormatBool(mute))
}

// RestoreNote shows again a dedication hidden by reports by mistake and
// clears its author's strike (Unmute lifts a pause). Radio admin only.
func RestoreNote(cur realm, stationID int, start int64) {
	onlyAdmin(cur)
	t := rd()
	st, s := noteSlot(t, stationID, start)
	if !s.NoteHidden {
		panic("radio: this dedication is not hidden") // its pending reports stay
	}
	s.NoteHidden, s.body, st.dirty = false, "", true
	key := noteKey(st.id, start)
	// A wrong hide is no strike: take back the one it gave, if it is still
	// the author's last, and keep any earlier one.
	if rec := t.val(cNotes, key); strings.HasPrefix(rec, struckMark) {
		gave, before, _ := strings.Cut(rec[len(struckMark):], ":")
		author := s.By.String()
		if t.val(cStrikes, author) == gave {
			if before == "" {
				t.del(cStrikes, author)
			} else {
				t.set(cStrikes, author, before)
			}
		}
	}
	t.del(cNotes, key)
	save(cur, t)
	chain.Emit("NoteRestored", "station", text.Itoa(st.id), "start", text.Itoa64(start))
}

// SetModBot names the moderation robot by its Ed25519 public key in hex
// ("" turns dedications off). Radio admin only.
func SetModBot(cur realm, pubKeyHex string) {
	onlyAdmin(cur)
	key, err := hex.DecodeString(pubKeyHex)
	if err != nil || (len(key) != 0 && len(key) != 32) {
		panic("radio: the robot key is a 32-byte Ed25519 public key in hex")
	}
	t := rd()
	t.set(cConfig, "modbot", hex.EncodeToString(key))
	save(cur, t)
	chain.Emit("ModBotSet", "key", pubKeyHex)
}

// MutedUntil returns the unix time until which who's dedications are paused
// after reports, 0 when they are not: the moderation robot refuses to sign
// for a muted author.
func MutedUntil(who address) int64 {
	if v := rd().val(cMuted, who.String()); v != "" {
		if until := text.MustAtoi64(v); now() < until {
			return until
		}
	}
	return 0
}

// Unmute lets a muted listener dedicate again before the week ends, e.g.
// after reports by throwaway wallets. Radio admin only.
func Unmute(cur realm, who address) {
	onlyAdmin(cur)
	if !role.Canonical(who) {
		panic("radio: not an address (lower-case g1...)")
	}
	t := rd()
	if !t.del(cMuted, who.String()) {
		panic("radio: this address is not muted")
	}
	save(cur, t)
	chain.Emit("Unmuted", "address", who.String())
}

// noteSlot finds the dedicated slot starting at start. On Main between its
// own picks it is the genre station's slot Main simulcast: the genre of the
// hour the slot began in, or of now when the hour changed under it.
func noteSlot(t *tx, stationID int, start int64) (*station, *Slot) {
	st := t.station(stationID)
	cands := []*station{st}
	if _, own := st.playing(start); !own {
		cands = []*station{st.relay(start), st.relay(now())}
	}
	for _, c := range cands {
		sl := c.slots()
		for i := range sl {
			if s := &sl[i]; s.Start == start && s.Note != "" {
				return c, s
			}
		}
	}
	panic("radio: no dedication at this time on this station")
}
