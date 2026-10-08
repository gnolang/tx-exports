package radio

import (
	"chain"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Sponsored picks: an artist's promo budget (catalog/sponsor.gno) refunds a
// listener's pick of their track: by default what the pick and collecting
// its refund cost (0.2 GNOT, catalog/sponsor.gno). The listener
// chooses it (QueueSponsored) instead of a normal pick; the artist's refund is
// reserved at once in the data realm's vault, and the listener collects it
// (ClaimPickPayout, one signature, their gas) once the slot has aired in
// full. A slot dropped or cut before its end gives the reservation back; one
// not collected within 7 days lapses back to the budget by itself.
//
// Farming with throwaway wallets earns at most the pick cost back, and these
// rules keep it rare: a wallet needs a first pick 7 days old and 3 normal
// picks in the last two 15-day periods (two counters in the curator record: the
// current period and the one before, so the window is 15 to 30 days, never
// more);
// one sponsored pick per artist per station and hour; sponsored airtime at
// most a quarter of the 2 hours listeners may program; and per wallet one per
// artist and three a day (the catalog). They earn no curator point, do not
// join Listeners' choice and carry no dedication.

const (
	repPeriod     = 15 * 24 * 3600 // reputation counters roll over every 15 days
	repAge        = 7 * 24 * 3600  // a wallet's first pick must be this old
	repPicks      = 3              // normal picks this period and the one before
	sponsorShare  = maxAheadAir / 4
	sponsorWindow = 3600
)

// A sponsored pick not collected yet is radio/sponsor address/P(station) ->
// Rec(start, track, end, ugnot, held, reserved, gen): one open per
// wallet and station; held is the end the catalog reserved for, reserved
// when (unix), gen the budget's funding generation then.
//
// The vault pools an artist's holds per day, and a new owner's funding
// refunds the previous funder everything, holds included, and starts a new
// funding generation (catalog/sponsor.gno): a reservation made before is
// cancelled, never paid from (nor released into) a later listener's hold,
// even when the budget went back to the same funder.

func sponsorKey(stationID int, addr address) string {
	return addr.String() + "/" + store.Pad(stationID)
}

// QueueSponsored is Queue paid by the artist: once the pick has aired in
// full, ClaimPickPayout sends the picker the artist's refund (catalog
// PromoOffer). No dedication. A wallet has one sponsored pick open per
// station: it must be collected (or have lapsed) before the next.
func QueueSponsored(cur realm, stationID, trackID int) {
	queueSponsored(cur, stationID, trackID, 0)
}

// QueueSponsoredAt is QueueSponsored for a chosen time (see QueueAt; 0: now).
// The refund lapses 7 days after the booked time plus the track's length.
func QueueSponsoredAt(cur realm, stationID, trackID int, at int64) {
	queueSponsored(cur, stationID, trackID, at)
}

func queueSponsored(cur realm, stationID, trackID int, at int64) {
	caller := userCaller(cur)
	t := rd()
	if why := sponsorBlock(t, caller); why != "" {
		panic("radio: " + why)
	}
	mustStation(stationID)
	// One open per station until it lapses: collected, or nothing left to
	// pay (the catalog lapses it at the end of a UTC day, so a record past
	// end+7d may still pay).
	if rec, ok := data.Get(cSponsor, sponsorKey(stationID, caller)); ok {
		if payoutStatus(store.Fields(rec)) != "lapsed" {
			panic("radio: collect your last sponsored pick on this station first")
		}
	}
	queue(cur, caller, stationID, trackID, false, true, "", at)
}

// ClaimPickPayout sends the caller the refund of their sponsored pick that
// started at start on stationID, once it has aired in full.
func ClaimPickPayout(cur realm, stationID int, start int64) {
	caller := userCaller(cur)
	noPayment()
	mustStation(stationID)
	t := rd()
	k := sponsorKey(stationID, caller)
	rec, ok := t.get(cSponsor, k)
	if !ok || text.MustAtoi64(store.Field(rec, 0)) != start {
		panic("radio: no sponsored pick of yours to collect at this time")
	}
	f := store.Fields(rec)
	track, amt, held := text.MustAtoi(f[1]), text.MustAtoi64(f[3]), text.MustAtoi64(f[4])
	status := payoutStatus(f)
	if status == "airing" {
		panic("radio: your pick has not finished airing yet")
	}
	t.del(cSponsor, k)
	// A removed track, a cancelled sponsorship or a lapsed refund leaves
	// nothing to pay: the record goes, so the next sponsored pick is open.
	if status == "lapsed" {
		save(cur, t)
		chain.Emit("PickPayoutVoid", "station", text.Itoa(stationID), "start", text.Itoa64(start), "track", text.Itoa(track), "to", caller.String())
		return
	}
	catalog.PromoClaim(cross(cur), track, caller, held, amt, text.MustAtoi(f[6]))
	c, sts := curRec(t, caller.String())
	c[3] += amt
	putCur(t, caller.String(), c, sts)
	save(cur, t)
	chain.Emit("PickPaid", "station", text.Itoa(stationID), "start", text.Itoa64(start), "track", text.Itoa(track), "to", caller.String(), "amount", text.Itoa64(amt))
}

// sponsorBlock says why a wallet may not take sponsored picks yet ("" when it may).
func sponsorBlock(t *tx, addr address) string {
	c, _ := curRec(t, addr.String())
	ts := now()
	if c[4] == 0 || ts-c[4] < repAge {
		return "sponsored picks open 7 days after your first pick"
	}
	recent := int64(0)
	switch ts / repPeriod {
	case c[5]:
		recent = c[6] + c[7]
	case c[5] + 1:
		recent = c[6]
	}
	if recent < repPicks {
		return "sponsored picks need 3 normal picks in the last two 15-day periods"
	}
	return ""
}

// sponsorQuota: one sponsored pick per artist per station and hour, and
// sponsored airtime at most a quarter of the listener window, both around
// airs (now, or the time booked).
// The share counts the listener window from airs; the per-artist hour is
// checked around plays, when the pick really airs (review R31).
func sponsorQuota(st *station, artistID int, dur, airs, plays int64) {
	air := dur
	for _, s := range st.slots() {
		if s.Pay == 0 {
			continue
		}
		if end := s.Start + s.Dur; end > airs && s.Start < airs+maxAheadAir {
			air += end - max64(s.Start, airs)
		}
		if s.Start+s.Dur > plays-sponsorWindow && s.Start < plays+sponsorWindow && s.artist == artistID {
			panic("radio: this artist already has a sponsored pick this hour here, pick it normally")
		}
	}
	if air > sponsorShare {
		panic("radio: sponsored picks are full on this station for now, pick normally")
	}
}

// reserve books the artist's refund for a sponsored slot, lapsing after held.
func reserve(cur realm, t *tx, picker address, stationID, trackID int, start, dur, held int64) int64 {
	amt, gen := catalog.PromoReserve(cross(cur), trackID, picker, held)
	t.set(cSponsor, sponsorKey(stationID, picker), store.Rec(text.Itoa64(start), text.Itoa(trackID), text.Itoa64(start+dur), text.Itoa64(amt), text.Itoa64(held), text.Itoa64(now()), text.Itoa(gen)))
	return amt
}

// held is the end the catalog reserves a sponsored slot's refund for: a
// booked slot keeps the one of its time even if it moves to a boundary.
func (s Slot) held() int64 {
	if s.At > 0 {
		return s.At + s.Dur
	}
	return s.Start + s.Dur
}

// hold is a sponsored slot's reservation in the catalog: filed under the end
// it was reserved for (the slot may have moved since). reserved is when it
// was taken, 0 once the slot started airing: only a pick that never aired
// gives its daily counts back.
type hold struct {
	track                int
	picker               address
	held, paid, reserved int64
	gen                  int
}

// unsponsor forgets the open record of a sponsored slot cut at ts before it
// started, and returns its reservation; ok is false when there was none. A
// slot already on air keeps its record: whoever cut it (a hide, a genre edit,
// a drop), the picker earned the refund and collects it once its end passes.
func unsponsor(t *tx, stationID int, s Slot, ts int64) (hold, bool) {
	k := sponsorKey(stationID, s.By)
	rec, ok := t.get(cSponsor, k)
	if !ok || s.Start < ts || text.MustAtoi64(store.Field(rec, 0)) != s.Start {
		return hold{}, false
	}
	t.del(cSponsor, k)
	f := store.Fields(rec)
	return hold{s.Track, s.By, text.MustAtoi64(f[4]), s.Pay, text.MustAtoi64(f[5]), text.MustAtoi(f[6])}, true
}

// release gives the reservations of cut sponsored slots back to their
// artists. While the catalog is paused it gives nothing back, so the radio
// can still drop slots: each hold lapses back to its budget by itself.
func release(cur realm, cut []hold) {
	if data.Paused("catalog") {
		return
	}
	for _, h := range cut {
		catalog.PromoRelease(cross(cur), h.track, h.picker, h.held, h.paid, h.reserved, h.gen)
	}
}

// PickPayoutStatus says what ClaimPickPayout would do for addr's sponsored
// pick that started at start on stationID: "ok" (it pays), "airing" (not
// finished yet), "lapsed" (nothing to pay: lapsed or cancelled; collecting only clears it) or
// "none" (no such open pick).
func PickPayoutStatus(addr address, stationID int, start int64) string {
	rec, ok := data.Get(cSponsor, sponsorKey(stationID, addr))
	if !ok || text.Atoi64(store.Field(rec, 0)) != start {
		return "none"
	}
	return payoutStatus(store.Fields(rec))
}

func payoutStatus(f []string) string {
	track, end, amt, held := text.MustAtoi(f[1]), text.MustAtoi64(f[2]), text.MustAtoi64(f[3]), text.MustAtoi64(f[4])
	if now() < end {
		return "airing"
	}
	// An aired pick pays whatever happened to its track since: hiding it
	// must not let its artist take back a refund the picker earned.
	if !catalog.PromoClaimable(track, held, amt, text.MustAtoi(f[6])) {
		return "lapsed"
	}
	return "ok"
}

// SponsoredJSON lists a wallet's sponsored picks not collected yet, with
// whether it may take new ones and each one's PickPayoutStatus:
// {"block":"why not, or empty","open":[{"station","start","track","end","amount","status"}]}.
func SponsoredJSON(addr address) string {
	out := `{"block":` + text.Str(sponsorBlock(rd(), addr)) + `,"open":[`
	p := addr.String() + "/"
	keys, recs := store.Rows(data.Page(cSponsor, p, addr.String()+"0", numStations, false))
	for i, rec := range recs {
		f := store.Fields(rec)
		if i > 0 {
			out += ","
		}
		out += `{"station":` + text.Itoa(text.Atoi(keys[i][len(p):])) + `,"start":` + f[0] + `,"track":` + f[1] + `,"end":` + f[2] + `,"amount":` + f[3] + `,"status":"` + payoutStatus(f) + `"}`
	}
	return out + `]}`
}
